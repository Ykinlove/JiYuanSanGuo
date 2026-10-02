extends Node2D
class_name WorldWeather
## 大地图天气层（三十八轮 2026-10-02，零外部素材：程序化雨/雪 + 雨声合成）
##
## 职责：按季节概率驱动 晴/雨/雪 三态（每游戏日到期重掷，持续 1~3 天），
## 粒子强度与阴天染色随目标平滑渐变；雨天联动程序化雨声 + 静音鸟鸣虫鸣。
##
## 【填充率铁律（三十四轮实证）】绝不新增全屏 alpha 混合层：
##   阴天变暗复用 DayNightTint 现有那层（tint.weather_dim 因子参与其合成链），
##   本节点只挂两只 CPUParticles2D（小 quad 粒子，非全屏层）。
##   粒子数红锁：雨 ≤200 / 雪 ≤150（超出必须先过 FPS 探针回归）。
##
## 【Godot 4.7 headless 大坑（本轮探针实测）】CPUParticles2D 在 headless 下
## "实际发射中"会死循环挂死引擎帧（await process_frame 永不返回）；
## amount_ratio 任何赋值（0.0/0.02）同样挂死；连构建后立即 set_process(false)
## 都可能挂。对策：headless（DisplayServer.get_name()=="headless"）一律不构建
## 粒子（逻辑层照常，概率/状态机/染色/联动全可探针验证）；强度渐变用粒子
## 颜色 alpha（amount_ratio 全工程禁用）；晴天沿切换冻结发射器 set_process(false)。
## 带窗口环境不受影响，视觉/帧率取证走 weather_shot 探针。

const WEATHER_CLEAR := 0
const WEATHER_RAIN := 1
const WEATHER_SNOW := 2

const RAIN_AMOUNT := 170      ## 红锁 ≤200
const SNOW_AMOUNT := 130      ## 红锁 ≤150
const INTENSITY_RATE := 0.35  ## 强度渐变速度（每秒）

## 粒子基色（强度=1；渐变时只缩放 alpha——amount_ratio 禁用，见顶部坑注）
const RAIN_COLOR := Color(0.72, 0.80, 0.92, 0.55)
const SNOW_COLOR := Color(0.96, 0.97, 1.00, 0.80)

## 阴天染色底色（alpha 为强度=1 时的染色强度；参与 DayNightTint 合成链）
const RAIN_DIM := Color(0.44, 0.50, 0.62, 0.13)
const SNOW_DIM := Color(0.78, 0.84, 0.95, 0.09)

## 程序化雨声
const MIX_RATE := 22050
const RAIN_DUR := 7.0
const RAIN_DB := -14.0

var camera: Camera2D = null
var tint: DayNightTint = null          ## world_map 注入；阴天因子写其 weather_dim
var amb_audio: WorldAmbientAudio = null ## world_map 注入；雨天静鸟鸣/虫鸣

var weather := WEATHER_CLEAR
var _days_left := 0
var _intensity := 0.0       ## 当前粒子/染色强度 0..1
var _target := 0.0          ## 目标强度
var _rain_audio: AudioStreamPlayer

var _rain: CPUParticles2D = null        ## headless 下恒 null（坑注：构建即挂）
var _snow: CPUParticles2D = null
var _emit_prev := false     ## emit_on 上帧值（沿切换冻结发射器，不每帧覆盖）
var _headless := false      ## headless 运行：不建粒子（见顶部坑注）

var _diag_norain := false   ## DIAG_NORAIN=1：锁定晴天（二分取证用）
var _force := -1            ## DIAG_FORCE_WEATHER=0/1/2：强制天气（带窗口取证用）


func setup(camera_ref: Camera2D, tint_ref: DayNightTint, amb_audio_ref: WorldAmbientAudio) -> void:
	camera = camera_ref
	tint = tint_ref
	amb_audio = amb_audio_ref


func _ready() -> void:
	z_index = 30
	_diag_norain = OS.get_environment("DIAG_NORAIN") == "1"
	_headless = DisplayServer.get_name() == "headless"
	var fw := OS.get_environment("DIAG_FORCE_WEATHER")
	if fw != "":
		_force = clampi(int(fw), 0, 2)

	if not _headless:
		_ensure_particles()
		# 晴天冻结粒子更新（CPUParticles2D 内部 _process 停转，零开销）
		_rain.set_process(false)
		_snow.set_process(false)

	_rain_audio = AudioStreamPlayer.new()
	_rain_audio.name = "RainLoop"
	_rain_audio.stream = _make_rain()
	_rain_audio.bus = "BGM"
	_rain_audio.volume_db = -60.0
	add_child(_rain_audio)

	# 首次进入即掷天气（存档读档后 GameState.month 已就绪）
	_reroll()
	EventBus.day_passed.connect(_on_day_passed)


## 懒构建：首次进入雨/雪才建粒子节点（晴天零节点零开销）
func _ensure_particles() -> void:
	if _rain != null:
		return
	_rain = _build_rain()
	add_child(_rain)
	_snow = _build_snow()
	add_child(_snow)


func _on_day_passed(_y: int, _m: int, _d: int) -> void:
	_days_left -= 1
	if _days_left <= 0:
		_reroll()


## 按季节概率重掷天气与持续天数（1-3 月春 / 4-6 夏 / 7-9 秋 / 10-12 冬）
func _reroll() -> void:
	_days_left = 1 + randi() % 3
	if _force >= 0:
		_apply(_force)
		return
	if _diag_norain:
		_apply(WEATHER_CLEAR)
		return
	var m := GameState.month
	var p_rain := 0.0
	var p_snow := 0.0
	if m <= 3:
		p_rain = 0.30
	elif m <= 6:
		p_rain = 0.38
	elif m <= 9:
		p_rain = 0.22
	else:
		p_snow = 0.32
		p_rain = 0.04
	var r := randf()
	if r < p_snow:
		_apply(WEATHER_SNOW)
	elif r < p_snow + p_rain:
		_apply(WEATHER_RAIN)
	else:
		_apply(WEATHER_CLEAR)


func _apply(w: int) -> void:
	weather = w
	match w:
		WEATHER_RAIN:
			_target = randf_range(0.65, 1.0)
		WEATHER_SNOW:
			_target = randf_range(0.5, 0.85)
		_:
			_target = 0.0


func _process(delta: float) -> void:
	# 强度渐变（淡入淡出）
	if _intensity < _target:
		_intensity = minf(_target, _intensity + INTENSITY_RATE * delta)
	elif _intensity > _target:
		_intensity = maxf(_target, _intensity - INTENSITY_RATE * delta)

	var emit_on := _intensity > 0.005
	var is_rain := weather == WEATHER_RAIN
	var is_snow := weather == WEATHER_SNOW

	# 粒子层（headless 下 _rain/_snow 恒 null，坑注：构建即挂）
	if not _headless:
		if emit_on and _rain == null:
			_ensure_particles()
		if _rain != null:
			_rain.visible = emit_on and is_rain
			_snow.visible = emit_on and is_snow
			# 只在 emit_on 沿上切换 set_process——外部冻结不被每帧覆盖
			if emit_on != _emit_prev:
				_emit_prev = emit_on
				_rain.set_process(emit_on)
				_snow.set_process(emit_on)
			# 粒子强度：颜色 alpha 渐变（amount_ratio 禁用，见顶部坑注）
			var it := _intensity
			_rain.color = Color(RAIN_COLOR.r, RAIN_COLOR.g, RAIN_COLOR.b, RAIN_COLOR.a * it)
			_snow.color = Color(SNOW_COLOR.r, SNOW_COLOR.g, SNOW_COLOR.b, SNOW_COLOR.a * it)
			if emit_on:
				_track_camera()

	# 阴天染色因子（复用 DayNightTint 现有层，零新增全屏混合）
	if tint != null:
		if emit_on:
			var base := RAIN_DIM if is_rain else SNOW_DIM
			tint.weather_dim = Color(base.r, base.g, base.b, base.a * _intensity)
		else:
			tint.weather_dim = Color(0, 0, 0, 0)

	# 雨声与鸟鸣联动（雪天同样安静）
	if emit_on and is_rain:
		_rain_audio.volume_db = lerpf(-60.0, RAIN_DB, _intensity)
	else:
		_rain_audio.volume_db = -60.0
	if amb_audio != null:
		amb_audio.weather_quiet = emit_on and _intensity > 0.25


## 发射盒跟随相机视野（按 zoom 换算世界尺寸，外扩余量防边缘穿帮）
func _track_camera() -> void:
	var zoom := 1.0
	var center := Vector2.ZERO
	if camera != null and is_instance_valid(camera):
		zoom = maxf(0.05, camera.zoom.x)
		center = camera.get_screen_center_position()
	var half := get_viewport_rect().size / zoom * 0.5

	# 雨：发射盒中心逆着落速上移半程（lifetime 内平均下落距离的一半）
	var rdir := Vector2(0.22, 1.0).normalized()
	var rfall := 2900.0 * _rain.lifetime
	_rain.position = center - rdir * rfall * 0.5
	_rain.emission_rect_extents = half + Vector2(240.0, rfall * 0.5 + 120.0)

	# 雪：发射盒中心上移半个屏高（雪从视野上方飘进来），左右各加一屏余量供斜飘
	_snow.position = center - Vector2(0.0, half.y + 80.0)
	_snow.emission_rect_extents = half + Vector2(half.x + 300.0, 160.0)


# ---------- 粒子构造 ----------

func _build_rain() -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.name = "RainEmitter"
	p.texture = _make_rain_streak_tex()
	p.amount = RAIN_AMOUNT
	p.lifetime = 0.85
	# 【属性名坑】CPUParticles2D 只有 local_coords（无 global_coords，赋值会抛错
	# 并使构建函数返回 null → 粒子静默消失；headless 探针测不出，带窗口才报）
	p.local_coords = false
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(0.22, 1.0).normalized()
	p.spread = 1.5
	p.gravity = Vector2.ZERO
	p.initial_velocity_min = 2600.0
	p.initial_velocity_max = 3200.0
	p.scale_amount_min = 0.85
	p.scale_amount_max = 1.25
	p.color = RAIN_COLOR
	return p


func _build_snow() -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.name = "SnowEmitter"
	p.texture = _make_snow_dot_tex()
	p.amount = SNOW_AMOUNT
	p.lifetime = 11.0
	p.local_coords = false   ## 同雨：CPUParticles2D 无 global_coords
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(0.0, 1.0)
	p.spread = 18.0
	p.gravity = Vector2(4.0, 16.0)
	p.initial_velocity_min = 70.0
	p.initial_velocity_max = 150.0
	p.scale_amount_min = 0.7
	p.scale_amount_max = 1.4
	p.color = SNOW_COLOR
	return p


## 雨丝纹理：6×28 竖线，顶透明→底近白（下落方向亮尾）
func _make_rain_streak_tex() -> ImageTexture:
	var w := 6
	var h := 28
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in range(h):
		var a := float(y) / float(h - 1)   # 0 顶 → 1 底
		for x in range(w):
			var fx := absf(float(x) / float(w - 1) - 0.5) * 2.0
			img.set_pixel(x, y, Color(1, 1, 1, a * a * (1.0 - fx * fx)))
	return ImageTexture.create_from_image(img)


## 雪点纹理：7×7 径向柔白点
func _make_snow_dot_tex() -> ImageTexture:
	var d := 7
	var r := float(d) * 0.5
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	for y in range(d):
		for x in range(d):
			var dist := Vector2(x - r + 0.5, y - r + 0.5).length() / r
			var a := maxf(0.0, 1.0 - dist)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	return ImageTexture.create_from_image(img)


# ---------- 程序化雨声（同 world_ambient_audio 合成范式） ----------

## 雨：双路低通噪声（a=0.30 亮"沙沙" + a=0.05 低频底）× 慢起伏包络，
## 噪声首尾不连续 → 末段 0.4s 环形交叉淡化补无缝。峰值归一 0.42。
func _make_rain() -> AudioStreamWAV:
	var sr := float(MIX_RATE)
	var n := int(sr * RAIN_DUR)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261002
	var lp_hi := 0.0
	var lp_lo := 0.0
	var buf := PackedFloat32Array()
	buf.resize(n)
	var ph := rng.randf() * TAU
	for i in range(n):
		var t := float(i) / sr
		var s := rng.randf_range(-1.0, 1.0)
		lp_hi += 0.30 * (s - lp_hi)
		lp_lo += 0.05 * (s - lp_lo)
		var env := 0.85 + 0.15 * sin(TAU * 2.0 * t / RAIN_DUR + ph)
		buf[i] = (lp_hi * 0.8 + lp_lo * 0.2) * env
	var xw := int(sr * 0.4)
	for k in range(xw):
		var w := float(k) / float(xw)
		var head := buf[k]
		buf[n - xw + k] = buf[n - xw + k] * (1.0 - w) + head * w
	var peak := 0.0001
	for v in buf:
		peak = maxf(peak, absf(v))
	for i in range(n):
		buf[i] = buf[i] / peak * 0.42
	return _encode_wav(buf)


## PackedFloat32 → 16bit 单声道循环 WAV（同 audio_manager / world_ambient_audio 范式）
func _encode_wav(samples: PackedFloat32Array) -> AudioStreamWAV:
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
	st.loop_mode = AudioStreamWAV.LOOP_FORWARD
	st.loop_begin = 0
	st.loop_end = n
	return st
