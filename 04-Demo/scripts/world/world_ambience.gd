extends Node2D
class_name WorldAmbience
## 大地图氛围层（第二十九轮「身临其境」）
## 三件零新资源活物：云影掠地 / 城池炊烟 / 飞鸟掠空
##
## 性能纪律（第二十八/三十四轮教训）：
##   - 【三十四轮】云影由「全屏 region 平铺」改为 **3 朵独立云斑**：弱 GPU
##     每个全屏 alpha 混合层 ~15ms（实测矩阵：云影+城图标全开 12 FPS，
##     任一隐藏 31 FPS），全屏平铺 + ×5 大图标直接叠爆填充率；
##     独立云斑混合面积 ~25% 屏，且一朵朵飘过比平铺噪声更像真云。
##   - 巨图 Sprite 必须 显式 TEXTURE_FILTER_LINEAR（过滤时序怪癖，28 轮）
##   - 炊烟只给「相机附近」城市装发射器（SMOKE_MAX 上限）
##   - 飞鸟 = _draw 程序化折线翅膀，零贴图零粒子

const CLOUD_ALPHA := 0.15          ## 云影最深不透明度
const CLOUD_BLOBS := 3             ## 独立云斑数（混合面积 ~25% 屏，填充率红锁）
const CLOUD_TEXTURE_SIZE := 512    ## 噪声图边长（一次性 CPU 烘焙）
const CLOUD_TEX_WINDOW := 300.0    ## 每朵云斑取噪声明暗窗（纹理像素）
const CLOUD_BLOB_WORLD := 700.0    ## 云斑世界直径
const CLOUD_SPEED := Vector2(30.0, 16.0)     ## 云移动风向（世界像素/秒）
const CLOUD_DRIFT_DEG := 14.0      ## 每朵云的漂移角扰动（度）

const SMOKE_MAX := 6               ## 同时存在的炊烟发射器上限（近城优先）
const SMOKE_RANGE := 2600.0        ## 城市进入该半径才起炊烟
const SMOKE_SCAN_INTERVAL := 0.5   ## 炊烟扫描周期（秒）

const BIRD_FLOCKS := 2             ## 鸟群数
const BIRDS_PER_FLOCK := 6         ## 每群鸟数

var _camera: Camera2D = null
var _clouds: Array[Sprite2D] = []
var _cloud_vel: Array[Vector2] = []     ## 每朵云斑速度（含漂移角扰动）
var _smoke_emitters: Dictionary = {}   ## city_id -> CPUParticles2D
var _smoke_scan_t := 0.0
var _flocks: Array[Node2D] = []
var _bird_t := 0.0


func setup(camera: Camera2D) -> void:
	_camera = camera


func _ready() -> void:
	z_index = -50   ## Terrain(-100) 之上、CityMarkers(10) 之下：云影只压大地。
	_build_clouds()
	_build_flocks()


## —— 云影层：CPU 烘焙一张软噪声 alpha 图，3 朵独立云斑随风飘 ——
## 【三十四轮×5 性能改造】全屏平铺 → 独立云斑（见文件头性能纪律）。
## 每朵 = 同一噪声纹理上 300×300 纹素窗口（一朵云的形状），世界 ~700px；
## 相机视口内随机出生，随风漂移，出视野从对侧回卷（与飞鸟同策略）。
## 世界锚定：region 源 = (相机中心+风程)/scale，与相机位置相消，
## 图案稳定锚在世界坐标上随风飘。
func _build_clouds() -> void:
	var tex := _bake_cloud_texture()
	for i in range(CLOUD_BLOBS):
		var sp := Sprite2D.new()
		sp.name = "CloudShadow%d" % (i + 1)
		sp.texture = tex
		# 每朵取噪声图不同窗口：窗口位置错开 → 云形各不相同（不越界 512）
		var wx := 60.0 + 70.0 * i
		var wy := 40.0 + float((i * 57) % 130)
		sp.region_enabled = true
		sp.region_rect = Rect2(wx, wy, CLOUD_TEX_WINDOW, CLOUD_TEX_WINDOW)
		var s := CLOUD_BLOB_WORLD / CLOUD_TEX_WINDOW
		sp.scale = Vector2.ONE * s
		sp.modulate = Color(0.05, 0.08, 0.10, CLOUD_ALPHA)
		add_child(sp)
		_clouds.append(sp)
		_apply_cloud_filter_later.call_deferred(sp)
		# 出生在相机视野内随机位置（setup 在 world_map._ready 中先于本调用）
		if _camera != null and is_instance_valid(_camera):
			var c := _camera.get_screen_center_position()
			var half := get_viewport_rect().size * 0.5 / maxf(_camera.zoom.x, 0.001)
			sp.position = c + Vector2(randf_range(-half.x, half.x) * 0.8,
				randf_range(-half.y, half.y) * 0.8)
		_cloud_vel.append(CLOUD_SPEED.rotated(randf_range(-1.0, 1.0) * deg_to_rad(CLOUD_DRIFT_DEG)))


## 云影 filter 延迟声明（避开 Compatibility 首帧前慢路径，28 轮教训）
func _apply_cloud_filter_later(sp: Sprite2D) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(sp):
		sp.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		sp.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED


func _update_clouds(delta: float) -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	var center := _camera.get_screen_center_position()
	var half := get_viewport_rect().size * 0.5 / maxf(_camera.zoom.x, 0.001) \
		+ Vector2.ONE * (CLOUD_BLOB_WORLD * 0.6)
	for i in range(_clouds.size()):
		var sp := _clouds[i]
		sp.position += _cloud_vel[i] * delta
		# 出视野 → 从对侧回卷（相对相机，保证总在屏附近游走）
		var rel := sp.position - center
		if absf(rel.x) > half.x or absf(rel.y) > half.y:
			sp.position = center + Vector2(-rel.x * 0.9, -rel.y * 0.9)
			_cloud_vel[i] = CLOUD_SPEED.rotated(randf_range(-1.0, 1.0) * deg_to_rad(CLOUD_DRIFT_DEG))


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
