extends Node
class_name WeatherFx
## 跨场景天气演出层（四十轮 2026-10-02）
##
## 【为什么要单独抽一个静态类】
## WorldWeather 只活在世界地图那棵场景树里，战斗 / 城内是另外两棵树，拿不到它
## 的实例。所以分成两层：
##   事实层 —— GameState.weather_id / weather_intensity / day_fraction（autoload）
##   演出层 —— 本类：读事实 → 造粒子 / 染色 / 雨声。
## 各场景只调本类的静态函数，彼此不互相依赖，也不需要把 WorldWeather 塞进 autoload。
##
## 【Godot 4.7 headless 大坑（三十八轮实测，详见 WorldWeather 顶部注释）】
## CPUParticles2D 在 headless 下"实际发射中"会挂死引擎帧（await process_frame
## 永不返回）。故 is_headless() 为真时 build_precip() 一律返回 null：逻辑状态
## （GameState 里的天气事实）照常可被探针验证，视觉取证走带窗口探针。
##
## 【填充率铁律（三十四轮实证）】粒子全用小 quad，绝不新增全屏 alpha 混合层；
## 雪地泛白那一层 ColorRect 只在下雪时才建（晴天零层）。

const CLEAR := 0
const RAIN := 1
const SNOW := 2

## 粒子红锁（与 WorldWeather 同口径：雨 ≤200 / 雪 ≤150）
const RAIN_AMOUNT := 150
const SNOW_AMOUNT := 120

const RAIN_COLOR := Color(0.72, 0.80, 0.92, 0.55)
const SNOW_COLOR := Color(0.96, 0.97, 1.00, 0.80)

## 雪天地面泛白（冷白薄染，只铺地面所在的下半屏，不盖单位）
const SNOW_GROUND_COLOR := Color(0.90, 0.94, 1.00, 0.14)

## 雨声默认音量：战斗有 BGM + 打击音，压得比大地图更低，避免糊成一团
const RAIN_DB_WORLD := -14.0
const RAIN_DB_BATTLE := -19.0
const RAIN_DB_CITY := -21.0

## 雨声合成参数（与 WorldWeather 共用同一套，避免两处各写一份）
const MIX_RATE := 22050
const RAIN_DUR := 7.0


## 当前天气事实（越界/异常一律回落晴天，绝不让演出层崩）
static func current() -> int:
	var w: int = int(GameState.weather_id)
	if w < CLEAR or w > SNOW:
		return CLEAR
	return w


## 天气强度（0..1）
static func intensity() -> float:
	return clampf(float(GameState.weather_intensity), 0.0, 1.0)


static func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


## 夜色系数 0..1（0 = 白天灯火全灭，1 = 深夜灯火全亮）。
## 与 DayNightTint 同相位口径（WorldClock.day_fraction）：
##   0.00 拂晓 → 0.12 清晨（灯火渐熄）→ 0.66 黄昏（渐亮）→ 0.82 入夜（全亮）
##   → 0.94 之后回落到 0.55，与次日 0.00 衔接，跨日无跳变。
static func night_factor(f: float) -> float:
	var x := clampf(f, 0.0, 1.0)
	if x < 0.12:
		return 0.55 * (1.0 - x / 0.12)          # 拂晓：0.55 → 0
	if x < 0.66:
		return 0.0                               # 白天：不点灯
	if x < 0.82:
		return (x - 0.66) / 0.16                 # 黄昏：0 → 1
	if x < 0.94:
		return 1.0                               # 夜里：全亮
	return 1.0 - 0.45 * (x - 0.94) / 0.06       # 后半夜 → 0.55，接次日拂晓


## 夜色系数（直接读 GameState 快照；城内/战斗时钟暂停，故是"进入时的时辰"）
static func night_factor_now() -> float:
	return night_factor(float(GameState.day_fraction))


# ---------- 粒子层 ----------

## 建造雨雪粒子层。
## screen：要覆盖的区域尺寸（世界单位；通常 = 视口尺寸 / 相机 zoom）。
## 根节点 local 原点在覆盖区左上角，调用方只需摆根节点位置。
## 晴天 / headless → null（调用方判空即可）。
static func build_precip(kind: int, screen: Vector2, scale: float = 1.0) -> Node2D:
	if kind == CLEAR or is_headless():
		return null
	var root := Node2D.new()
	root.name = "WeatherPrecip"
	var p := _build_rain(screen, scale) if kind == RAIN else _build_snow(screen, scale)
	root.add_child(p)
	return root


static func _build_rain(screen: Vector2, s: float) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.name = "Rain"
	p.texture = _rain_streak_tex()
	p.amount = maxi(1, int(float(RAIN_AMOUNT) * maxf(0.1, s)))
	p.lifetime = 0.85
	# 【属性名坑】CPUParticles2D 只有 local_coords（无 global_coords，赋值会抛错
	# 并使构建函数返回 null → 粒子静默消失；headless 探针测不出）
	p.local_coords = false
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(0.22, 1.0).normalized()
	p.spread = 1.5
	p.gravity = Vector2.ZERO
	p.initial_velocity_min = 2600.0
	p.initial_velocity_max = 3200.0
	p.scale_amount_min = 0.85
	p.scale_amount_max = 1.25
	p.color = _scaled(RAIN_COLOR)
	# 发射盒逆着落速上移半程：雨丝从视野上方落进来，而不是在屏幕内凭空出现
	var fall := 2900.0 * p.lifetime
	p.position = screen * 0.5 - Vector2(0.22, 1.0).normalized() * fall * 0.5
	p.emission_rect_extents = screen * 0.5 + Vector2(140.0, fall * 0.5 + 140.0)
	return p


static func _build_snow(screen: Vector2, s: float) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.name = "Snow"
	p.texture = _snow_dot_tex()
	p.amount = maxi(1, int(float(SNOW_AMOUNT) * maxf(0.1, s)))
	p.lifetime = 9.0
	p.local_coords = false          ## 同雨：无 global_coords
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.direction = Vector2(0.0, 1.0)
	p.spread = 18.0
	p.gravity = Vector2(4.0, 16.0)
	p.initial_velocity_min = 70.0
	p.initial_velocity_max = 150.0
	p.scale_amount_min = 0.7
	p.scale_amount_max = 1.4
	p.color = _scaled(SNOW_COLOR)
	# 雪从上边界之上飘进来（lifetime 长、落速慢，只需抬半个屏高）
	p.position = Vector2(screen.x * 0.5, -80.0)
	p.emission_rect_extents = Vector2(screen.x * 0.5 + 220.0, 160.0)
	return p


## 雪天地面泛白层（下雪才建，晴天零层）。
## 只染地面所在区域（传入矩形），不盖单位与 HUD。
static func build_snow_ground(rect: Rect2) -> ColorRect:
	var cr := ColorRect.new()
	cr.name = "SnowGround"
	cr.color = SNOW_GROUND_COLOR
	cr.position = rect.position
	cr.size = rect.size
	cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return cr


## 基色按当前强度缩放 alpha（amount_ratio 禁用，见 WorldWeather 顶部坑注）
static func _scaled(base: Color) -> Color:
	return Color(base.r, base.g, base.b, base.a * clampf(intensity(), 0.15, 1.0))


## 雨丝纹理：6×28 竖线，顶透明 → 底近白（下落方向亮尾）
static func _rain_streak_tex() -> ImageTexture:
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
static func _snow_dot_tex() -> ImageTexture:
	var d := 7
	var r := float(d) * 0.5
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	for y in range(d):
		for x in range(d):
			var dist := Vector2(x - r + 0.5, y - r + 0.5).length() / r
			var a := maxf(0.0, 1.0 - dist)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	return ImageTexture.create_from_image(img)


# ---------- 程序化雨声（大地图 / 战斗 / 城内共用一份） ----------

## 雨：双路低通噪声（a=0.30 亮"沙沙" + a=0.05 低频底）× 慢起伏包络，
## 噪声首尾不连续 → 末段 0.4s 环形交叉淡化补无缝。峰值归一 0.42。
static func make_rain_stream() -> AudioStreamWAV:
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
static func _encode_wav(samples: PackedFloat32Array) -> AudioStreamWAV:
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
