extends Node
## 音频管理器（AudioManager）
## 职责：BGM 淡入淡出切换、SFX 播放、音量控制与持久化。
## 【占位音兜底】assets/audio 下暂无真实音频资源时，缺失路径用运行时合成的占位音顶上，
## 避免「全游戏静音」；真实资源放入对应路径后自动优先使用，无需改任何调用点。
## 【分轨】Master → BGM / SFX 双子 bus（default_bus_layout.tres）；
## 三通道音量全部走 AudioServer bus（物理分轨），player 自身 volume_db 仅用于 fade。

const BGM_BUS := "BGM"
const SFX_BUS := "SFX"
const SETTINGS_PATH := "user://settings.cfg"

## BGM 淡入淡出时长（秒）与淡出静音底 db
const FADE_TIME := 0.7
const FADE_DB := -40.0

## 占位音开关：真实音频齐备后可置 false，只保留「缺失即静音」行为
const PLACEHOLDER_AUDIO := true
## 占位音采样率（16bit 单声道，体积小、合成快）
const PLACEHOLDER_MIX_RATE := 22050

var bgm_player: AudioStreamPlayer
var sfx_players: Array[AudioStreamPlayer] = []
const SFX_POOL_SIZE := 6

var master_volume: float = 1.0
var bgm_volume: float = 0.8
var sfx_volume: float = 0.9

var _current_bgm_path: String = ""
var _bgm_tween: Tween
var _sfx_index: int = 0
## 占位音缓存：path -> AudioStream（同一条路径只合成一次）
var _placeholder_cache: Dictionary = {}
## 已告警过的缺失路径，避免每帧刷日志
var _missing_warned: Dictionary = {}


func _ready() -> void:
	_ensure_buses()
	bgm_player = AudioStreamPlayer.new()
	bgm_player.bus = BGM_BUS
	add_child(bgm_player)

	for i in range(SFX_POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.bus = SFX_BUS
		add_child(p)
		sfx_players.append(p)

	load_settings()


## 退出树（游戏关闭）时立即停 BGM（不 fade）：让 AudioServer 的 playback
## 随树正常释放，否则 AudioStreamPlaybackWAV/AudioStreamWAV 会被 ObjectDB
## 记为退出泄漏（verbose 冒烟实证 2 instances leaked）。
func _exit_tree() -> void:
	stop_bgm(false)


## 确保 BGM/SFX 子 bus 存在。正常由 default_bus_layout.tres 提供；
## 布局文件缺失/加载失败时在此兜底创建，保证分轨永不失效。
func _ensure_buses() -> void:
	for bus_name: String in [BGM_BUS, SFX_BUS]:
		if AudioServer.get_bus_index(bus_name) != -1:
			continue
		var idx := AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")


## 播放 BGM（同曲不重播）；fade=true 时旧曲淡出 → 新曲淡入，拒绝瞬间砸入
func play_bgm(path: String, fade: bool = true) -> void:
	if _current_bgm_path == path and bgm_player.playing:
		return
	var stream := _resolve_stream(path, true)
	if stream == null:
		return
	_current_bgm_path = path
	if _bgm_tween and _bgm_tween.is_valid():
		_bgm_tween.kill()
	if not fade:
		_start_bgm(stream)
		bgm_player.volume_db = 0.0
		return
	if bgm_player.playing:
		# 淡出旧曲 → 回调里才换流起新曲（避免新曲在淡出段提前漏出）→ 淡入
		_bgm_tween = create_tween()
		_bgm_tween.tween_property(bgm_player, "volume_db", FADE_DB, FADE_TIME)
		_bgm_tween.tween_callback(_start_bgm.bind(stream))
		_bgm_tween.tween_property(bgm_player, "volume_db", 0.0, FADE_TIME)
	else:
		_start_bgm(stream)
		bgm_player.volume_db = FADE_DB
		_bgm_tween = create_tween()
		_bgm_tween.tween_property(bgm_player, "volume_db", 0.0, FADE_TIME)


func _start_bgm(stream: AudioStream) -> void:
	bgm_player.stream = stream
	bgm_player.play()


func stop_bgm(fade: bool = true) -> void:
	_current_bgm_path = ""
	if _bgm_tween and _bgm_tween.is_valid():
		_bgm_tween.kill()
	if not fade or not bgm_player.playing:
		_finish_stop()
		return
	_bgm_tween = create_tween()
	_bgm_tween.tween_property(bgm_player, "volume_db", FADE_DB, FADE_TIME)
	_bgm_tween.tween_callback(_finish_stop)


func _finish_stop() -> void:
	bgm_player.stop()
	bgm_player.volume_db = 0.0


## 播放音效：优先取空闲 player，池满才按环形顶替（真实长音效不被未播完的短音截断）
func play_sfx(path: String, volume_scale: float = 1.0) -> void:
	var stream := _resolve_stream(path, false)
	if stream == null:
		return
	var p := _pick_sfx_player()
	p.stream = stream
	# 单发独立增益（如 victory 压低）走 player 自身 db；通道音量由 SFX/Master bus 承担
	p.volume_db = linear_to_db(clampf(volume_scale, 0.0, 1.0))
	p.play()


func _pick_sfx_player() -> AudioStreamPlayer:
	for cand in sfx_players:
		if not cand.playing:
			return cand
	var p := sfx_players[_sfx_index]
	_sfx_index = (_sfx_index + 1) % SFX_POOL_SIZE
	return p


## 常用音效封装
func sfx_click() -> void:
	play_sfx("res://assets/audio/sfx/click.ogg")


func sfx_confirm() -> void:
	play_sfx("res://assets/audio/sfx/confirm.ogg")


func sfx_cancel() -> void:
	play_sfx("res://assets/audio/sfx/cancel.ogg")


func sfx_hit() -> void:
	play_sfx("res://assets/audio/sfx/hit.ogg")


## 设置（三通道全部即时生效，走 bus）
func set_master_volume(v: float) -> void:
	master_volume = clampf(v, 0.0, 1.0)
	_apply_volumes()
	save_settings()


func set_bgm_volume(v: float) -> void:
	bgm_volume = clampf(v, 0.0, 1.0)
	_apply_volumes()
	save_settings()


func set_sfx_volume(v: float) -> void:
	sfx_volume = clampf(v, 0.0, 1.0)
	_apply_volumes()
	save_settings()


func _apply_volumes() -> void:
	_set_bus_volume("Master", master_volume)
	_set_bus_volume(BGM_BUS, bgm_volume)
	_set_bus_volume(SFX_BUS, sfx_volume)


func _set_bus_volume(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(linear, 0.0001)))
	AudioServer.set_bus_mute(idx, linear <= 0.001)


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master", master_volume)
	cfg.set_value("audio", "bgm", bgm_volume)
	cfg.set_value("audio", "sfx", sfx_volume)
	cfg.save(SETTINGS_PATH)


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	master_volume = cfg.get_value("audio", "master", 1.0)
	bgm_volume = cfg.get_value("audio", "bgm", 0.8)
	sfx_volume = cfg.get_value("audio", "sfx", 0.9)
	_apply_volumes()


# ------------------------------------------------------------------
# 占位音兜底（真实资源缺失时使用）
# ------------------------------------------------------------------

## 取音频流：优先真实资源；缺失则回退运行时合成的占位音；再不行返回 null（静音）
func _resolve_stream(path: String, is_bgm: bool) -> AudioStream:
	if ResourceLoader.exists(path):
		var real := load(path)
		if real is AudioStream:
			return real as AudioStream
	_warn_missing(path)
	if not PLACEHOLDER_AUDIO:
		return null
	if _placeholder_cache.has(path):
		return _placeholder_cache[path]
	var st: AudioStreamWAV = _make_placeholder_bgm() if is_bgm else _make_placeholder_sfx(_sfx_kind(path))
	_placeholder_cache[path] = st
	return st


## 缺失路径只告警一次，避免刷屏
func _warn_missing(path: String) -> void:
	if _missing_warned.has(path):
		return
	_missing_warned[path] = true
	push_warning("[AudioManager] 音频资源缺失，已用占位音兜底：%s" % path)


## 由文件名推断音效种类（占位合成器选型用；真实资产到位后自动失效）
func _sfx_kind(path: String) -> String:
	var base := path.get_file().get_basename()
	if base in ["click", "confirm", "cancel", "hit", "battle_skill",
			"encounter_battle", "battle_win", "coin_trade"]:
		return base
	return "other"


## ------------------------------------------------------------------
## 国风占位合成器：拨弦（Karplus-Strong）/ 木鱼 / 兵刃 / 锣 / 战鼓 / 铜钱。
## 全部确定性（固定种子），同一路径每次合成结果一致。
## 真实 ogg 资产落入 assets/audio 后自动取代本节产物。
## ------------------------------------------------------------------

## 合成短促音效占位音
func _make_placeholder_sfx(kind: String) -> AudioStreamWAV:
	var samples := PackedFloat32Array()
	match kind:
		"click":
			samples = _synth_woodfish(0.05, 900.0, 0.5)
		"confirm":
			samples = _synth_pluck_seq([523.25, 659.25], 0.18, 0.42)
		"cancel":
			samples = _synth_pluck_seq([392.0, 293.66], 0.2, 0.4)
		"hit":
			samples = _synth_metal(0.14, 0.55)
		"battle_skill":
			samples = _synth_gong(0.7, 0.5)
		"encounter_battle":
			samples = _synth_drums(3, 0.17, 0.55)
		"battle_win":
			samples = _synth_gong(0.5, 0.4)
			samples.append_array(_synth_pluck_seq([523.25, 659.25, 783.99], 0.24, 0.34))
		"coin_trade":
			samples = _synth_coins(0.32, 0.4)
		_:
			samples = _synth_pluck_seq([440.0], 0.18, 0.35)
	return _encode_wav(samples, false)


## Karplus-Strong 拨弦：噪声激励 + 环形延迟线滑动平均（古琴/琵琶拨弦质感）
func _synth_pluck(freq: float, dur: float, amp: float, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var sr := float(PLACEHOLDER_MIX_RATE)
	var n := int(sr * dur)
	var period := maxi(2, int(sr / freq))
	var buf := PackedFloat32Array()
	buf.resize(period)
	for i in range(period):
		buf[i] = rng.randf_range(-1.0, 1.0)
	var out := PackedFloat32Array()
	out.resize(n)
	var idx := 0
	var decay := exp(-7.0 / sr)   # 每 0.14s 衰减到 ~37%，拨弦余韵
	var level := 1.0
	for i in range(n):
		var nxt := buf[(idx + 1) % period]
		buf[idx] = (buf[idx] + nxt) * 0.499
		out[i] = buf[idx] * level
		level *= decay
		idx = (idx + 1) % period
	return out


## 拨弦短语：依次拨一串音（上行=确认/胜利，下行=取消）
func _synth_pluck_seq(freqs: Array, dur_each: float, amp: float) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260925
	var out := PackedFloat32Array()
	for f in freqs:
		out.append_array(_synth_pluck(float(f), dur_each, amp, rng))
	return out


## 木鱼/梆子：高频木质感正弦 + 短噪声瞬态
func _synth_woodfish(dur: float, freq: float, amp: float) -> PackedFloat32Array:
	var sr := float(PLACEHOLDER_MIX_RATE)
	var n := int(sr * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260925
	for i in range(n):
		var t := float(i) / sr
		var env := exp(-t * 90.0)
		var v := sin(TAU * freq * t) * 0.7 + rng.randf_range(-1.0, 1.0) * 0.3
		out[i] = v * env * amp
	return out


## 兵刃相击：非谐金属泛音簇 + 噪声瞬态
func _synth_metal(dur: float, amp: float) -> PackedFloat32Array:
	var sr := float(PLACEHOLDER_MIX_RATE)
	var n := int(sr * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260925
	var partials: Array = [1900.0, 3170.0, 4750.0, 6300.0]
	var p_amp: Array = [1.0, 0.6, 0.4, 0.25]
	for i in range(n):
		var t := float(i) / sr
		var env := exp(-t * 34.0)
		var v := 0.0
		for k in range(partials.size()):
			v += sin(TAU * float(partials[k]) * t) * float(p_amp[k])
		v = v * 0.3 + rng.randf_range(-1.0, 1.0) * 0.35 * exp(-t * 60.0)
		out[i] = v * env * amp
	return out


## 锣：低基频 + 非谐分音长衰减 + 起音噪声
func _synth_gong(dur: float, amp: float) -> PackedFloat32Array:
	var sr := float(PLACEHOLDER_MIX_RATE)
	var n := int(sr * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260925
	var partials: Array = [82.0, 131.0, 197.0, 293.0, 431.0]
	var p_amp: Array = [1.0, 0.7, 0.5, 0.35, 0.2]
	for i in range(n):
		var t := float(i) / sr
		var env := exp(-t * 3.5)
		var v := 0.0
		for k in range(partials.size()):
			v += sin(TAU * float(partials[k]) * t) * float(p_amp[k])
		v = v * 0.22 + rng.randf_range(-1.0, 1.0) * 0.3 * exp(-t * 40.0)
		out[i] = v * env * amp
	return out


## 战鼓连击：膜振动正弦（频率快速下滑）+ 皮革噪声
func _synth_drums(count: int, gap: float, amp: float) -> PackedFloat32Array:
	var sr := float(PLACEHOLDER_MIX_RATE)
	var seg := int(sr * 0.16)
	var step := int(sr * gap)
	var out := PackedFloat32Array()
	out.resize(int(sr * (0.16 + gap * (count - 1)) + 0.05 * sr))
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260925
	for d in range(count):
		for i in range(seg):
			var t := float(i) / sr
			var f := 170.0 - 90.0 * (t / 0.16)   # 170→80Hz 下滑 = 鼓面振动
			var env := exp(-t * 26.0)
			var v := sin(TAU * f * t) * 0.8 + rng.randf_range(-1.0, 1.0) * 0.3 * exp(-t * 70.0)
			var dst := d * step + i
			if dst < out.size():
				out[dst] += v * env * amp
	return out


## 铜钱叮当：三声高频非谐金属短音
func _synth_coins(dur: float, amp: float) -> PackedFloat32Array:
	var sr := float(PLACEHOLDER_MIX_RATE)
	var out := PackedFloat32Array()
	out.resize(int(sr * dur))
	var pings: Array = [[0.0, 4200.0], [0.09, 5600.0], [0.19, 3800.0]]
	for p in pings:
		var t0 := float(p[0])
		var f := float(p[1])
		var n := int(sr * 0.1)
		for i in range(n):
			var t := float(i) / sr
			var dst := int((t0 + t) * sr)
			if dst >= out.size():
				break
			var env := exp(-t * 55.0)
			out[dst] += (sin(TAU * f * t) * 0.7 + sin(TAU * f * 1.41 * t) * 0.3) * env * amp
	return out


## 合成可无缝循环的占位 BGM：低音 drone（整周期）+ 五声音阶拨弦琶音（8s 循环）
func _make_placeholder_bgm() -> AudioStreamWAV:
	var sr := float(PLACEHOLDER_MIX_RATE)
	var dur := 8.0
	var n := int(sr * dur)
	var buf := PackedFloat32Array()
	buf.resize(n)
	# drone：56/84Hz 在 8s 内均为整数周期，起伏包络 1 周期 → 循环无爆音
	for i in range(n):
		var t := float(i) / sr
		var trem := 0.85 + 0.15 * sin(TAU * t / dur)
		var v := (sin(TAU * 56.0 * t) * 0.10 + sin(TAU * 84.0 * t) * 0.06) * trem
		buf[i] = v
	# 五声琶音（C 宫）：固定乐句，每音 1s 一拨，拨弦尾音在循环点前自然衰减完
	var phrase: Array = [261.63, 329.63, 392.0, 329.63, 293.66, 392.0, 440.0, 329.63]
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260925
	for k in range(phrase.size()):
		var note := _synth_pluck(float(phrase[k]), 1.1, 0.16, rng)
		var offset := int(k * sr)   # 每秒一音；1.1s 尾音压到下一音头上，末音 7s 起于 8s 前衰减完
		for i in range(note.size()):
			var dst := offset + i
			if dst < n:
				buf[dst] += note[i]
	return _encode_wav(buf, true)


## float 采样 → 16bit 单声道 AudioStreamWAV
func _encode_wav(samples: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var n := samples.size()
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in range(n):
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = PLACEHOLDER_MIX_RATE
	st.stereo = false
	st.data = data
	if loop:
		st.loop_mode = AudioStreamWAV.LOOP_FORWARD
		st.loop_begin = 0
		st.loop_end = n
	return st
