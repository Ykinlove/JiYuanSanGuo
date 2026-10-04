extends Node
class_name WorldAmbientAudio
## 大地图环境音层（三十一轮 2026-10-01，零外部素材：全程序化合成）
##
## 三层声音，全部离线运行时合成 AudioStreamWAV：
##   ① 风：低通粉噪 × 整周期慢包络（阵风起伏），6s 无缝循环常驻；
##   ② 白天鸟鸣：随机 5~11s 一次，2~4 音节上扫频啁啾，随机音高/音量防复读机；
##   ③ 夜间虫鸣：同触发位换 4.4kHz 振幅调制虫声，更密更轻。
## 昼夜相位 = WorldClock.day_fraction()（0..1，与 DayNightTint 同源同节奏）。
##
## 【轨位】走 BGM bus——环境音属持续背景层，随用户 BGM 音量一起缩放；
## 自身再压 WIND_DB/BIRD_DB，保证不与音乐打架。
## 【性能】合成只在 _ready 与每次触发时发生（单帧几万样本乘加，毫秒级），
## _process 只做倒计时，无每帧音频运算。

const MIX_RATE := 22050
const WIND_DUR := 6.0
const WIND_DB := -17.0
const BIRD_DB := -11.0
const CALL_PLAYERS := 2

## 白天相位区间（对齐 DayNightTint.DAY_KEYS：清晨 0.12 ~ 黄昏尾 0.78）
const DAY_PHASE_LO := 0.10
const DAY_PHASE_HI := 0.78

const BIRD_INTERVAL := Vector2(5.0, 11.0)   ## 白天鸟鸣间隔（秒）
const CRICKET_INTERVAL := Vector2(3.0, 8.0) ## 夜间虫鸣间隔（秒）

var clock: Node = null   ## world_map 注入 WorldClock；缺省按白天处理

## 【三十八轮】雨天/雪天安静位（WorldWeather 写入）：强度 >0.25 时静鸟鸣/虫鸣
var weather_quiet := false

var _wind: AudioStreamPlayer
var _callers: Array[AudioStreamPlayer] = []
var _caller_idx := 0
var _next_call := 2.0

## 【第七十二轮·性能】风声是**常驻循环**且合成完全确定性：
## rng.seed 写死 20261001，MIX_RATE / WIND_DUR 是常量，循环里无外部输入
## ⇒ 每次算出的采样逐位相同，进城/回图/战斗反复重建本节点都是重做同一件事。
## 已加进程内缓存，第二次起 _ready 不再付这13 万采样的合成代价。
##
## 【但鸟鸣/虫鸣**不可**照抄此法】_synth_bird_song() / _synth_cricket() 里
## 是 rng.randomize() —— 「随机音高/音量防复读机」是它们的设计意图，
## 缓存下来就变成每5~11s 重复同一个音，玩家会立刻听出循环感。
## 那一层合成量小（每次几千采样）且不在 _ready 上，保留每次合成是对的。
static var _wind_cache: AudioStreamWAV = null


func setup(clock_ref: Node) -> void:
	clock = clock_ref


func _ready() -> void:
	_wind = AudioStreamPlayer.new()
	_wind.name = "WindLoop"
	_wind.stream = _make_wind()
	_wind.bus = "BGM"
	_wind.volume_db = WIND_DB
	add_child(_wind)
	_wind.play()
	for i in range(CALL_PLAYERS):
		var p := AudioStreamPlayer.new()
		p.bus = "BGM"
		add_child(p)
		_callers.append(p)
	_next_call = randf_range(1.5, 3.5)


func _process(delta: float) -> void:
	_next_call -= delta
	if _next_call > 0.0:
		return
	if weather_quiet:   # 雨雪天鸟虫静默（雨声由 WorldWeather 自带）
		return
	if _is_day():
		_play_bird()
		_next_call = randf_range(BIRD_INTERVAL.x, BIRD_INTERVAL.y)
	else:
		_play_cricket()
		_next_call = randf_range(CRICKET_INTERVAL.x, CRICKET_INTERVAL.y)


## 昼夜判断：clock 缺失/无效按白天（鸟鸣）处理，不报错
func _is_day() -> bool:
	if clock == null or not is_instance_valid(clock):
		return true
	var f := float(clock.day_fraction())
	return f >= DAY_PHASE_LO and f <= DAY_PHASE_HI


## 取空闲发声器（环形兜底）
func _pick_caller() -> AudioStreamPlayer:
	for c in _callers:
		if not c.playing:
			return c
	var p := _callers[_caller_idx]
	_caller_idx = (_caller_idx + 1) % _callers.size()
	return p


func _play_bird() -> void:
	var p := _pick_caller()
	p.stream = _synth_bird_song()
	p.volume_db = BIRD_DB + randf_range(-4.0, 0.0)
	p.pitch_scale = randf_range(0.9, 1.15)
	p.play()


func _play_cricket() -> void:
	var p := _pick_caller()
	p.stream = _synth_cricket()
	p.volume_db = BIRD_DB - 3.0 + randf_range(-2.0, 2.0)
	p.pitch_scale = randf_range(0.95, 1.1)
	p.play()


# ---------- 合成器 ----------

## 风：白噪声一阶低通成粉噪 × 双整周期正弦慢包络（首尾自然衔接）；
## 噪声本体首尾不连续 → 末段 0.35s 与开头交叉淡化补无缝。
func _make_wind() -> AudioStreamWAV:
	# 【单一真源】进程内只合成一次（理由见 _wind_cache 处的注释）
	if _wind_cache != null:
		return _wind_cache
	var sr := float(MIX_RATE)
	var n := int(sr * WIND_DUR)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261001
	var lp := 0.0
	var buf := PackedFloat32Array()
	buf.resize(n)
	var a := 0.045   ## 一阶低通系数（越小越闷=越像远风）
	var ph1 := rng.randf() * TAU
	var ph2 := rng.randf() * TAU
	for i in range(n):
		var t := float(i) / sr
		lp += a * (rng.randf_range(-1.0, 1.0) - lp)
		# 包络用「dur 内整数周期」正弦：循环点首尾斜率/幅值连续
		var env := 0.62 + 0.22 * sin(TAU * 2.0 * t / WIND_DUR + ph1) \
			+ 0.16 * sin(TAU * 3.0 * t / WIND_DUR + ph2)
		buf[i] = lp * env
	# 环形交叉淡化：末尾 X 秒与开头 X 秒重叠加权（w: 0→1 用开头样本，1-w 用原样本）
	var xw := int(sr * 0.35)
	for k in range(xw):
		var w := float(k) / float(xw)
		var head := buf[k]
		buf[n - xw + k] = buf[n - xw + k] * (1.0 - w) + head * w
	# 归一化到峰值 0.5（留足 headroom，音量交给 bus 与 volume_db）
	var peak := 0.0001
	for v in buf:
		peak = maxf(peak, absf(v))
	for i in range(n):
		buf[i] = buf[i] / peak * 0.5
	_wind_cache = _encode_wav(buf, true)
	return _wind_cache


## 白天鸟鸣：2~4 音节上扫频啁啾（f0 2.6~3.8kHz ×1.25 上扫，正弦窗）
func _synth_bird_song() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var syllables := 2 + rng.randi() % 3
	var buf := PackedFloat32Array()
	for s in range(syllables):
		var f0 := rng.randf_range(2600.0, 3800.0)
		var dur := rng.randf_range(0.07, 0.13)
		var nn := int(MIX_RATE * dur)
		var phase := rng.randf() * TAU
		for i in range(nn):
			var u := float(i) / float(nn)
			var f := f0 * (1.0 + 0.25 * u)
			var env := sin(PI * u)   # 平滑起落，无咔嗒
			buf.append(sin(phase + TAU * f * (float(i) / MIX_RATE)) * env * 0.42)
		if s < syllables - 1:
			var gap := int(MIX_RATE * rng.randf_range(0.09, 0.16))
			for i in range(gap):
				buf.append(0.0)
	return _encode_wav(buf, false)


## 夜间虫鸣：2~3 声 4.4kHz 载波 × 26Hz 振幅调制 × 快衰减（蟋蟀复翅摩擦感）
func _synth_cricket() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var chirps := 2 + rng.randi() % 2
	var buf := PackedFloat32Array()
	for c in range(chirps):
		var dur := rng.randf_range(0.26, 0.4)
		var nn := int(MIX_RATE * dur)
		for i in range(nn):
			var t := float(i) / MIX_RATE
			var u := float(i) / float(nn)
			var am := 0.55 + 0.45 * sin(TAU * 26.0 * t)
			var env := minf(1.0, u * 6.0) * (1.0 - u)   # 快起缓落
			buf.append(sin(TAU * 4400.0 * t) * am * env * 0.22)
		if c < chirps - 1:
			var gap := int(MIX_RATE * rng.randf_range(0.12, 0.2))
			for i in range(gap):
				buf.append(0.0)
	return _encode_wav(buf, false)


## PackedFloat32 → 16bit 单声道 WAV（循环由调用方决定；同 audio_manager 范式）
func _encode_wav(samples: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var n := samples.size()
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in range(n):
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = MIX_RATE
	st.stereo = false
	st.data = data
	if loop:
		st.loop_mode = AudioStreamWAV.LOOP_FORWARD
		st.loop_begin = 0
		st.loop_end = n
	return st
