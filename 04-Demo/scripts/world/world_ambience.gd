extends Node2D
class_name WorldAmbience
## 大地图氛围层（第二十九轮「身临其境」）
## 三件零新资源活物：云影掠地 / 城池炊烟 / 飞鸟掠空
##
## 性能纪律（第二十八轮教训）：
##   - 云影 = 1 张 CPU 预烘焙噪声图 ×2 层 region 滚动，巨图 Sprite 必须
##     显式 TEXTURE_FILTER_LINEAR（同 terrain_painter 的过滤时序怪癖）
##   - 炊烟只给「相机附近」城市装发射器（MAX_SMOKE 上限），110 城全挂
##     CPUParticles2D 会拖垮 CPU
##   - 飞鸟 = _draw 程序化折线翅膀，零贴图零粒子

const CLOUD_ALPHA := 0.13          ## 云影最深不透明度（乘性压暗）
## 【填充率红锁】云影层数=1：沙箱实测每加一层全屏 alpha 混合掉 ~4 FPS
## （弱 GPU 填充率瓶颈），双层视差的观感收益不值 4 帧。
const CLOUD_LAYERS := 1
const CLOUD_TEXTURE_SIZE := 1024   ## 噪声图边长（一次性 CPU 烘焙）
const CLOUD_TILE_SCALE := 4.0      ## 噪声图平铺放大倍率（单块 4096 世界像素）
const CLOUD_SPEED := Vector2(26.0, 14.0)     ## 第一层风向（世界像素/秒）
const CLOUD_SPEED_2 := Vector2(-15.0, 22.0)  ## 第二层反向视差

const SMOKE_MAX := 6               ## 同时存在的炊烟发射器上限（近城优先）
const SMOKE_RANGE := 2600.0        ## 城市进入该半径才起炊烟
const SMOKE_SCAN_INTERVAL := 0.5   ## 炊烟扫描周期（秒）

const BIRD_FLOCKS := 2             ## 鸟群数
const BIRDS_PER_FLOCK := 6         ## 每群鸟数

var _camera: Camera2D = null
var _clouds: Array[Sprite2D] = []
var _cloud_wind: Array[Vector2] = []    ## 各层风程累计（世界像素）
var _cloud_wind_t: Array[float] = []    ## 各层存活时间
var _smoke_emitters: Dictionary = {}   ## city_id -> CPUParticles2D
var _smoke_scan_t := 0.0
var _flocks: Array[Node2D] = []
var _bird_t := 0.0


func setup(camera: Camera2D) -> void:
	_camera = camera


func _ready() -> void:
	z_index = 0   ## Terrain(-100) 之上、CityMarkers(10) 之下：云影只压大地
	_build_clouds()
	_build_flocks()


## —— 云影层：CPU 烘焙一张软噪声 alpha 图，双层视差滚动 ——
## 【性能】sprite 跟随相机、region 只盖「视野÷缩放 + 2 块平铺」——
## 不许出现覆盖十几屏的巨型 quad（Compatibility 光栅化不划算）。
## 世界锚定：region 源 = (相机中心+风程)/scale，与相机位置相消，
## 图案稳定锚在世界坐标上随风飘。
func _build_clouds() -> void:
	var tex := _bake_cloud_texture()
	for i in range(CLOUD_LAYERS):
		var sp := Sprite2D.new()
		sp.name = "CloudShadow%d" % (i + 1)
		sp.texture = tex
		sp.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR  ## 巨图性能红锁
		sp.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		sp.region_enabled = true
		sp.modulate = Color(0.05, 0.08, 0.10, CLOUD_ALPHA * (1.0 - 0.3 * i))
		add_child(sp)
		_clouds.append(sp)
	_cloud_wind.append(CLOUD_SPEED * 3.0)    ## 起始风程错开两层
	_cloud_wind.append(CLOUD_SPEED_2 * 7.0)
	_cloud_wind_t = [0.0, 0.0]


func _update_clouds(delta: float) -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	var center := _camera.get_screen_center_position()
	var view := get_viewport_rect().size / maxf(_camera.zoom.x, 0.001)
	for i in range(_clouds.size()):
		var sp := _clouds[i]
		var s := CLOUD_TILE_SCALE * (1.0 + 0.6 * i)
		sp.scale = Vector2.ONE * s
		sp.position = center
		_cloud_wind_t[i] += delta
		_cloud_wind[i] += (CLOUD_SPEED if i == 0 else CLOUD_SPEED_2) * delta
		var region := view / s + Vector2.ONE * (2.0 * CLOUD_TEXTURE_SIZE)
		sp.region_rect = Rect2((center + _cloud_wind[i]) / s - region * 0.5, region)


## 噪声 → 黑色 + 柔和 alpha（一次 ~40ms，加载期无感）
## 无缝平铺：FastNoiseLite 无 4D，用 3D 环面采样（u/v 各绕环一周，接缝天然连续）
func _bake_cloud_texture() -> ImageTexture:
	var n := FastNoiseLite.new()
	n.seed = 20261001
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 1.0
	n.fractal_octaves = 3
	var img := Image.create(CLOUD_TEXTURE_SIZE, CLOUD_TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
	for y in range(CLOUD_TEXTURE_SIZE):
		var v := TAU * float(y) / float(CLOUD_TEXTURE_SIZE)
		for x in range(CLOUD_TEXTURE_SIZE):
			var u := TAU * float(x) / float(CLOUD_TEXTURE_SIZE)
			# 环面参数化：u 经度、v 纬度，各绕一圈回到起点 → 平铺无缝
			var px := (1.6 + 0.55 * cos(v)) * cos(u) * 200.0
			var py := (1.6 + 0.55 * cos(v)) * sin(u) * 200.0
			var pz := 0.55 * sin(v) * 200.0
			var val := n.get_noise_3d(px, py, pz)   # -1..1
			var a := clampf((val - 0.08) / 0.55, 0.0, 1.0)   # 只留云块，谷底全透
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)


func _process(delta: float) -> void:
	# 云影视差滚动（视口自适应 region，见 _build_clouds 性能说明）
	_update_clouds(delta)

	_bird_t += delta
	_tick_birds(delta)

	# 炊烟低频扫描
	_smoke_scan_t += delta
	if _smoke_scan_t >= SMOKE_SCAN_INTERVAL:
		_smoke_scan_t = 0.0
		_update_smoke()


## —— 城池炊烟：只给相机附近城市挂发射器 ——
func _update_smoke() -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	var center := _camera.get_screen_center_position()
	# 收集半径内城市（cities 表 map_x/map_y 即世界坐标）
	var near: Array = []
	var cities: Array = DataManager.get_table("cities")
	for c in cities:
		if not (c is Dictionary):
			continue
		var pos := Vector2(float(c.get("map_x", 0.0)), float(c.get("map_y", 0.0)))
		if pos.distance_to(center) <= SMOKE_RANGE:
			near.append([str(c.get("id", "")), pos])
	near.sort_custom(func(a, b): return (a[1] as Vector2).distance_to(center) \
		< (b[1] as Vector2).distance_to(center))

	# 挂新发射器（上限内）
	for i in range(mini(near.size(), SMOKE_MAX)):
		var cid: String = near[i][0]
		if _smoke_emitters.has(cid):
			continue
		var p := CPUParticles2D.new()
		p.name = "Smoke_" + cid
		p.position = near[i][1]
		p.amount = 3
		p.lifetime = 2.6
		p.preprocess = 2.0
		p.emitting = true
		p.local_coords = false          # 世界坐标：烟随风飘、与城脱离
		p.direction = Vector2(0.15, -1)
		p.spread = 14.0
		p.gravity = Vector2(7.0, -9.0)  # 负 y = 热浮力向上 + 微风
		p.initial_velocity_min = 5.0
		p.initial_velocity_max = 9.0
		p.scale_amount_min = 5.0
		p.scale_amount_max = 11.0
		p.color = Color(0.88, 0.88, 0.85, 0.16)
		p.color_ramp = _smoke_ramp()
		add_child(p)
		_smoke_emitters[cid] = p
	# 撤走离远的
	for cid in _smoke_emitters.keys():
		var p: CPUParticles2D = _smoke_emitters[cid]
		if not is_instance_valid(p):
			_smoke_emitters.erase(cid)
			continue
		if p.position.distance_to(center) > SMOKE_RANGE * 1.15:
			p.queue_free()
			_smoke_emitters.erase(cid)


func _smoke_ramp() -> Gradient:
	var g := Gradient.new()
	g.set_color(0, Color(0.9, 0.9, 0.87, 0.0))    # 出生淡入
	g.add_point(0.25, Color(0.9, 0.9, 0.87, 0.16))
	g.set_color(1, Color(0.95, 0.95, 0.93, 0.0))  # 消散
	return g


## —— 飞鸟群：程序化 V 翅，绕相机区域巡航 ——
func _build_flocks() -> void:
	for i in range(BIRD_FLOCKS):
		var flock := Node2D.new()
		flock.name = "BirdFlock%d" % (i + 1)
		add_child(flock)
		flock.set_meta("vel", Vector2.from_angle(randf() * TAU) * (46.0 + 20.0 * i))
		# 每只鸟的相对位置（雁形散布）
		var offs := PackedVector2Array()
		for j in range(BIRDS_PER_FLOCK):
			offs.append(Vector2(-j * 17.0, (j % 2) * 12.0 - 6.0 + randf_range(-4, 4)))
		flock.set_meta("offs", offs)
		flock.set_meta("phase", randf() * TAU)
		flock.draw.connect(_draw_flock.bind(flock))
		_flocks.append(flock)


func _tick_birds(delta: float) -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	var center := _camera.get_screen_center_position()
	var half := get_viewport_rect().size * 0.5 / maxf(_camera.zoom.x, 0.001) + Vector2(900, 900)
	for flock in _flocks:
		var vel: Vector2 = flock.get_meta("vel")
		flock.position += vel * delta
		flock.queue_redraw()   # 扇翅动画：每帧重录折线
		# 飞出视野外圈 → 从对侧重生，换个方向
		var rel := flock.position - center
		if absf(rel.x) > half.x or absf(rel.y) > half.y:
			flock.position = center + Vector2(
				-rel.x * 0.9 + randf_range(-200, 200),
				-rel.y * 0.9 + randf_range(-200, 200))
			flock.set_meta("vel", vel.rotated(randf_range(-0.6, 0.6)))


func _draw_flock(flock: Node2D) -> void:
	var offs: PackedVector2Array = flock.get_meta("offs")
	var phase: float = flock.get_meta("phase")
	var vel: Vector2 = flock.get_meta("vel")
	var col := Color(0.16, 0.14, 0.12, 0.65)
	for j in range(offs.size()):
		var flap := sin(_bird_t * 9.0 + phase + j * 0.7)   # -1..1 扇翅
		var w := 5.0 + 2.0 * flap
		var p := offs[j]
		# 【坑】draw 信号回调里的 draw_line 解析到 self（WorldAmbience）而非 flock，
		# 不在自身 draw 上下文 → 全部被拒、飞鸟隐形。必须对 flock 调用。
		flock.draw_line(p + Vector2(-w, -3.0 * flap), p, col, 1.8, true)
		flock.draw_line(p, p + Vector2(w, -3.0 * flap), col, 1.8, true)
