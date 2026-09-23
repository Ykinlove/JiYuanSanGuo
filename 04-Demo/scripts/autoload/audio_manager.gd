extends Node
## 音频管理器（AudioManager）
## 职责：BGM 淡入淡出切换、SFX 播放、音量控制与持久化。
## 【占位音兜底】assets/audio 下暂无真实音频资源，缺失时用运行时合成的占位音顶上，
## 避免「全游戏静音」；真实资源放入对应路径后自动优先使用，无需改任何调用点。

const BGM_BUS := "Master"
const SETTINGS_PATH := "user://settings.cfg"

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
var _sfx_index: int = 0
## 占位音缓存：path -> AudioStream（同一条路径只合成一次）
var _placeholder_cache: Dictionary = {}
## 已告警过的缺失路径，避免每帧刷日志
var _missing_warned: Dictionary = {}


func _ready() -> void:
	bgm_player = AudioStreamPlayer.new()
	bgm_player.bus = BGM_BUS
	add_child(bgm_player)

	for i in range(SFX_POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.bus = BGM_BUS
		add_child(p)
		sfx_players.append(p)

	load_settings()


## 播放 BGM（若相同则不重播）
func play_bgm(path: String, fade: bool = true) -> void:
	if _current_bgm_path == path and bgm_player.playing:
		return
	var stream := _resolve_stream(path, true)
	if stream == null:
		return
	_current_bgm_path = path
	bgm_player.stream = stream
	bgm_player.volume_db = linear_to_db(bgm_volume)
	bgm_player.play()


func stop_bgm() -> void:
	bgm_player.stop()
	_current_bgm_path = ""


## 播放音效
func play_sfx(path: String, volume_scale: float = 1.0) -> void:
	var stream := _resolve_stream(path, false)
	if stream == null:
		return
	var p := sfx_players[_sfx_index]
	_sfx_index = (_sfx_index + 1) % SFX_POOL_SIZE
	p.stream = stream
	p.volume_db = linear_to_db(clampf(sfx_volume * volume_scale, 0.0, 1.0))
	p.play()


## 常用音效封装
func sfx_click() -> void:
	play_sfx("res://assets/audio/sfx/click.ogg")


func sfx_confirm() -> void:
	play_sfx("res://assets/audio/sfx/confirm.ogg")


func sfx_cancel() -> void:
	play_sfx("res://assets/audio/sfx/cancel.ogg")


func sfx_hit() -> void:
	play_sfx("res://assets/audio/sfx/hit.ogg")


## 设置
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
	save_settings()


func _apply_volumes() -> void:
	bgm_player.volume_db = linear_to_db(bgm_volume * master_volume)


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


## 由文件名推断音效种类（click / confirm / cancel / hit / 其它）
func _sfx_kind(path: String) -> String:
	var base := path.get_file().get_basename()
	if base in ["click", "confirm", "cancel", "hit"]:
		return base
	return "other"


## 合成短促音效占位音
func _make_placeholder_sfx(kind: String) -> AudioStreamWAV:
	var dur := 0.16
	var tones: Array = [880.0]
	var amp := 0.32
	var noise := 0.0
	match kind:
		"click":
			dur = 0.06
			tones = [1250.0]
			amp = 0.30
		"confirm":
			dur = 0.22
			tones = [660.0, 990.0]
		"cancel":
			dur = 0.22
			tones = [420.0, 280.0]
		"hit":
			dur = 0.12
			tones = [160.0]
			amp = 0.40
			noise = 0.5

	var n := int(PLACEHOLDER_MIX_RATE * dur)
	var seg := maxi(1, int(float(n) / float(tones.size())))
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260923
	var buf := PackedFloat32Array()
	buf.resize(n)
	for i in range(n):
		var ti: int = clampi(i / seg, 0, tones.size() - 1)
		var t := float(i) / float(PLACEHOLDER_MIX_RATE)
		var local_t := float(i - ti * seg) / float(PLACEHOLDER_MIX_RATE)
		var env := exp(-local_t * 12.0)
		var v: float = sin(TAU * float(tones[ti]) * t) * env
		if noise > 0.0:
			v = lerpf(v, rng.randf_range(-1.0, 1.0), noise * env)
		buf[i] = v * amp
	return _encode_wav(buf, false)


## 合成可无缝循环的低音铺底占位 BGM
func _make_placeholder_bgm() -> AudioStreamWAV:
	var dur := 4.0
	var n := int(PLACEHOLDER_MIX_RATE * dur)
	var buf := PackedFloat32Array()
	buf.resize(n)
	# 110Hz / 165Hz 在 4 秒内均为整数周期，起伏包络亦为 1 个周期 → 循环无爆音
	for i in range(n):
		var t := float(i) / float(PLACEHOLDER_MIX_RATE)
		var trem := 0.6 + 0.4 * sin(TAU * t / dur)
		var v := (sin(TAU * 110.0 * t) * 0.6 + sin(TAU * 165.0 * t) * 0.4) * trem
		buf[i] = v * 0.16
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
