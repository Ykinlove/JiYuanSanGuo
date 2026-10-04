extends Node2D
class_name TerrainPainter
## 地形绘制器（TerrainPainter）
## 职责：根据 terrain.json 数据，用 Godot 原生绘制 API 在大地图上画出分层地貌。
## M2 阶段用程序化绘制替代美术贴图；接入贴图后本脚本改读 Texture 即可。
##
## 绘制层次（从下到上）：
##   1. 底色（草地）
##   2. 区域地貌（平原/山地/森林/水泽，带柔边）
##   3. 区域纹理细节（山脊线 / 树丛 / 水波纹）
##   4. 道路
##   5. 装饰（树 / 石 / 草丛）

const TERRAIN_COLORS := {
	"grass":    Color(0.24, 0.34, 0.22),
	"plain":    Color(0.36, 0.44, 0.24),
	"mountain": Color(0.34, 0.30, 0.26),
	"forest":   Color(0.16, 0.28, 0.16),
	"swamp":    Color(0.20, 0.30, 0.30),
	"desert":   Color(0.50, 0.44, 0.28),
	"snow":     Color(0.78, 0.80, 0.82),
	"road":     Color(0.42, 0.36, 0.24),
}

const RNG_SEED := 20260921        ## 固定随机种子，保证每次生成一致

## 近景下 world_static 烘焙图的最大叠加透明度（仅作色彩补充不盖底图，
## 见 _draw 1.5 段说明）
const NEAR_STATIC_ALPHA := 0.35

## 地形贴图路径（存在则优先使用贴图，否则程序化绘制）
const TERRAIN_TEX_DIR := "res://assets/sprites/terrain/"

## 【四十二轮】四季地形氛围罩（normal 叠加，低透）：0春嫩绿 / 1夏浓绿 / 2秋暖橙 / 3冬冷蓝白。
## 仅作色彩氛围补充，不改底层 AI 写实图/程序化底图，零新增美术资源。
const SEASON_MOOD := {
	0: Color(0.55, 0.85, 0.45, 0.10),   # 春 嫩绿回春
	1: Color(0.30, 0.70, 0.25, 0.08),   # 夏 浓绿饱和
	2: Color(0.95, 0.55, 0.20, 0.16),   # 秋 暖橙黄
	3: Color(0.80, 0.88, 1.00, 0.18),   # 冬 冷蓝白
}
## 季节切换检测缓存 + 冬季积雪渐变纹理（懒生成）
var _last_season := -1
var _snow_grad: Texture2D = null

var _region_data: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _tex_cache: Dictionary = {}    ## 地形类型 -> Texture2D 或 null
var _view_rect := Rect2()          ## 当前区域窗口的世界坐标矩形（由 world_map 设置）


func _ready() -> void:
	_rng.seed = RNG_SEED
	# 【性能红锁 2026-10-01】4096² 底图在 Compatibility 渲染器下有个渲染状态
	# 缓存怪癖：filter 在首帧绘制「前」声明（哪怕值就是 LINEAR）实测 3.5~4 FPS，
	# 首帧「后」再赋同值则 16.5 FPS（4.5 倍）。故延迟两帧再设——
	# 用户端「卡得直接不能玩」即此所致。改后必须跑 FPS 探针回归。
	_apply_linear_filter_later.call_deferred()
	load_region("china")


func _apply_linear_filter_later() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	# 城池蒙版预建（主线程，供兜底远景图同步生成使用）。
	_get_city_mask()
	# 【R3-03】world_static 改为懒加载： china_geo 系作底图时它只作
	# 「近景细节层回退」（首选 china_geo_4096 锐化图）或底图兜底，
	# 首次真正需要时才 load（见 _get_static_tex_lazy / _get_near_detail_tex）。


## 【四十二轮】季节切换检测：仅当 GameState 季节变化时才 queue_redraw()，
## 避免每帧重绘静态地形（_draw 只在重绘时执行一次，开销可忽略）。
func _process(_d: float) -> void:
	if GameState == null:
		return
	var s := GameState.get_season()
	if s != _last_season:
		_last_season = s
		queue_redraw()


## 【四十二轮】冬季北方积雪渐变：顶(北, ny 小)雪厚 → 底(南)无雪。缓存复用。
func _get_snow_gradient() -> Texture2D:
	if _snow_grad != null:
		return _snow_grad
	var grad := Gradient.new()
	grad.add_point(0.0, Color(1, 1, 1, 1.0))
	grad.add_point(0.5, Color(1, 1, 1, 0.45))
	grad.add_point(1.0, Color(1, 1, 1, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 256
	tex.height = 256
	_snow_grad = tex
	return _snow_grad


## 载入区域数据
func load_region(region_id: String) -> void:
	var table: Array = DataManager.get_table("terrain")
	for r in table:
		if str(r.get("id", "")) == region_id:
			_region_data = r
			break
	_tex_cache.clear()
	_poly_cache.clear()
	_organic_cache.clear()
	queue_redraw()


## 设置当前区域窗口（由 world_map._ready 调用，用于装饰物定位）
func set_view_rect(rect: Rect2) -> void:
	_view_rect = rect
	queue_redraw()


## 相机可视矩形（由 world_map 每帧传入，仅作记录；地形为静态整图，
## 由 Camera2D 变换自动平移/缩放，无需因相机移动触发重绘）。
## 【R3-02】zoom 一并传入：近景细节层按缩放渐入，避免远观时噪声糊满全图。
var _cam_view := Rect2()
var _cam_zoom := 1.0

func set_camera_view(rect: Rect2, zoom: float = 1.0) -> void:
	_cam_view = rect
	_cam_zoom = maxf(zoom, 0.001)


## 【R3-02】近景细节系数：zoom 0.25 以下（天下全景）为 0，0.4 起全开。
## 底图 2048 → 1 纹素≈10.4 屏幕像素（zoom 1.0），近景偏糊；
## china_geo_4096 细节层 1 纹素≈5.2，叠加噪声 tile 后近景为
## 「5 倍细颗粒 + 锐化边缘 + 地表噪声」。
func _near_detail_factor() -> float:
	return clampf((_cam_zoom - 0.25) / (0.4 - 0.25), 0.0, 1.0)


## 获取地形贴图。
## 优先读外部贴图（res://assets/sprites/terrain/{terrain}.png），
## 不存在则用 FastNoiseLite 程序化生成带自然纹理变化的贴图（替代纯色块）。
## gen_size：程序化生成的贴图边长（区域用 256，底图用 1024 减少平铺次数）。
func _get_terrain_texture(terrain: String, gen_size: int = 256) -> Texture2D:
	var cache_key := terrain + "_" + str(gen_size)
	if _tex_cache.has(cache_key):
		return _tex_cache[cache_key]
	var path: String = TERRAIN_TEX_DIR + terrain + ".png"
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path)
	if tex == null:
		tex = _make_procedural_terrain_tex(terrain, gen_size)
	_tex_cache[cache_key] = tex
	return tex


# ================= 虚拟纹理：远景全图 + 近景分块 =================

## 远景：低清全图（缩放到全图可见时，1024 纹理 ≈ 屏宽 2 倍内，清晰）。
## 【同步生成说明】512 纹理（smooth 实际算 256²）≈ 30ms —— 一次性无感；
## 不进后台任务：WorkerThreadPool 任务队列是 LIFO，先入队的 lowres 会被
## 持续派发的分块任务饿死在栈底（探针实测 wait 死锁），且避免 freed 竞态。
var _lowres_world_tex: Texture2D = null

## 静态地图整图（离线烘焙 world_static.png）。
## 【R3-02/R3-03】不再 _ready 无条件加载：china_geo 作底图时它只作「近景细节层」，
## 首次需要（zoom 进入近景带 / china_geo 缺失回退）才真正 load。
var _static_tex: Texture2D = null
var _static_checked := false

func _get_static_tex_lazy() -> Texture2D:
	if not _static_checked:
		_static_checked = true
		var p := TERRAIN_TEX_DIR + "world_static.png"
		if ResourceLoader.exists(p):
			_static_tex = load(p)
			print("[TerrainPainter] 静态地图已加载（懒加载）：", p)
		else:
			push_warning("[TerrainPainter] 未找到 world_static.png，将回退程序化远景图（请运行 tools/bake_world_map.gd 烘焙）")
	return _static_tex


var _near_tex: Texture2D = null
var _near_tex_checked := false

## 近景细节整图：china_geo_4096.png（AI 图 lanczos 放大 + USM 锐化离线烘焙，
## 管线见 03-美术资源/tools/_china_geo_4096_bake.py）。
## 【为什么不用 world_static 当细节层】它是程序化噪声烘焙图，没有山川水系，
## 近景全开会把 AI 底图盖平（2026-10-01 主视图纯绿的根因）；锐化 AI 图与
## 底图同源同色，近景等于「把同一张画拉近看」。懒加载：首次进近景才付显存。
func _get_near_detail_tex() -> Texture2D:
	if not _near_tex_checked:
		_near_tex_checked = true
		var p := TERRAIN_TEX_DIR + "china_geo_4096.png"
		if ResourceLoader.exists(p):
			_near_tex = load(p)
	return _near_tex

func _get_lowres_world_tex() -> Texture2D:
	if _lowres_world_tex == null:
		_lowres_world_tex = _make_geo_tex_for_rect(Rect2(Vector2.ZERO, _world_size()), 512, true)
	return _lowres_world_tex


var _art_geo_tex: Texture2D = null
var _art_geo_checked := false

## AI 写实全景图（assets/sprites/terrain/china_geo.png，用户拍板恢复用于远景展示）。
## 只当**远景底图**：近景分块仍是城池锚定的程序化地形——AI 整图拉近看是马赛克，
## 此前被否决的是「当唯一地形」，不是「当背景」。
func _get_art_geo_tex() -> Texture2D:
	if not _art_geo_checked:
		_art_geo_checked = true
		var p := TERRAIN_TEX_DIR + "china_geo.png"
		if ResourceLoader.exists(p):
			_art_geo_tex = load(p)
	return _art_geo_tex


## 小地图/天下地图专用 2048 版（R3-11）：小地图「局部模式」控件仅 ~300px 宽却
## 要显示 ≈2900 世界宽 ≈ 只采样 140 纹素，1024 源图 2.1px/纹素明显糊。2048 版
## 纹素密度翻倍、插值更平滑；大地图远景继续用 1024 版（1.87px/纹素无感），
## 不额外吃 4096×4206 那张的显存。生成管线见 03-美术资源/tools/_minimap_tex_upscale.py。
var _art_geo_2048: Texture2D = null
var _art_geo_2048_checked := false


func _get_art_geo_2048_tex() -> Texture2D:
	if not _art_geo_2048_checked:
		_art_geo_2048_checked = true
		var p := TERRAIN_TEX_DIR + "china_geo_2048.png"
		if ResourceLoader.exists(p):
			_art_geo_2048 = load(p)
	return _art_geo_2048


## 小地图/天下地图注入：用户拍板统一用 AI 写实全景图（china_geo 系），
## 与大地图底图一致；静态烘焙整图作为回退（懒加载），再回退程序化远景。
func _get_minimap_tex() -> Texture2D:
	var art := _get_art_geo_2048_tex()
	if art == null:
		art = _get_art_geo_tex()
	if art != null:
		return art
	var st := _get_static_tex_lazy()
	if st != null:
		return st
	return _get_lowres_world_tex()


## ================= 分块虚拟纹理（已废弃 / 2026-09-24） =================
## 原「近景按 1024 世界像素分块、后台 WorkerThreadPool 逐块生成纹理」机制已整体移除。
## 替代方案：离线烘焙整图 world_static.png（tools/bake_world_map.gd），由 _draw 直接
## 铺底 —— 进游戏即完整地图、无加载模糊、无后台线程竞态（用户明确要求「静态地图」）。
## 下方保留的 _make_geo_image_for_rect / _get_city_mask 仅作兜底远景图（_get_lowres_world_tex）使用。


# （静态地图：地形为一次性绘制的静态整图，无需逐帧 _process 重绘。）


## ================= 城池影响蒙版：地貌随三国点位走 =================
## 【为什么需要】纯噪声生成的山川与 110 座城的三国点位毫无对应，
## 用户观感是「城池位置和地图对不上」。预生成一张低分辨率蒙版：
## 每座城周围一圈「平坦田园区」（压低海拔、染农田绿），山脉噪声自动避开城池
## —— 城在哪、平原来的哪，地貌格局由点位锚定。
const MASK_SIZE := 512
const CITY_FLAT_WORLD_R := 950.0   ## 城池周边平坦区半径（世界像素）
var _city_mask: PackedFloat32Array = []
var _mask_dim := Vector2i.ZERO

func _get_city_mask() -> PackedFloat32Array:
	if not _city_mask.is_empty():
		return _city_mask
	var world := _world_size()
	_mask_dim = Vector2i(
		clampi(int(world.x / 42.0), 128, MASK_SIZE),
		clampi(int(world.y / 42.0), 128, MASK_SIZE))
	_city_mask.resize(_mask_dim.x * _mask_dim.y)
	var cities: Array = DataManager.get_table("cities")
	var scale := Vector2(
		float(_mask_dim.x) / maxf(world.x, 1.0),
		float(_mask_dim.y) / maxf(world.y, 1.0))
	var r_px := CITY_FLAT_WORLD_R * scale.x   # 蒙版上的半径
	for city in cities:
		if not (city is Dictionary):
			continue
		var c := Vector2(
			float(city.get("map_x", 0.0)) * scale.x,
			float(city.get("map_y", 0.0)) * scale.y)
		var level := maxi(int(city.get("level", 1)), 1)
		var rr := r_px * (1.0 + 0.12 * level)   # 大城辐射更远
		var r2 := rr * rr
		var x0 := maxi(int(c.x - rr), 0)
		var x1 := mini(int(c.x + rr), _mask_dim.x - 1)
		var y0 := maxi(int(c.y - rr), 0)
		var y1 := mini(int(c.y + rr), _mask_dim.y - 1)
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var dx := float(x) - c.x
				var dy := float(y) - c.y
				var d2 := dx * dx + dy * dy
				if d2 >= r2:
					continue
				# 平滑衰减 0→1（城中心 1，边缘 0），取 max 叠加多城影响
				var v := 1.0 - sqrt(d2) / rr
				var idx := y * _mask_dim.x + x
				if v > _city_mask[idx]:
					_city_mask[idx] = v
	return _city_mask


## 采样城池影响值（最近邻足够：平坦圈半径很大，无需插值）
func _sample_city_mask(wx: float, wy: float) -> float:
	if _city_mask.is_empty():
		return 0.0
	var world := _world_size()
	var x := clampi(int(wx / maxf(world.x, 1.0) * float(_mask_dim.x)), 0, _mask_dim.x - 1)
	var y := clampi(int(wy / maxf(world.y, 1.0) * float(_mask_dim.y)), 0, _mask_dim.y - 1)
	return _city_mask[y * _mask_dim.x + x]


## 【第六十八轮第三层】对外暴露：世界全图尺寸（高度场归一化用）。
## 【为什么需要】高度场公式要按「世界尺寸」把 x/y 归一化到 0~1，
## 而全图尺寸的真源在 terrain.json。world_map 若自己存一份副本，
## 就会与 terrain_painter 漂移（改数据表后角色高度与底图对不上）。
## 故一律从这里取。
func get_world_size() -> Vector2:
	return _world_size()


## 【第六十八轮第三层】对外暴露：某世界坐标的海拔 + 绘制抬升。
## 【为什么必须走这里而不是各自实现】`_sample_city_mask` 是城池压平的**唯一**
## 实现；若角色侧另写一份，角色站位就会与底图的山势/城周平地对不上
## （画上是山，角色按平原高度站）。故由本方法统一出口。
##
## 【第七十一轮·性能·消除重复计算】原式是
##   `elevation_at(wx,wy,world,m)` 算一次拿 elev，紧接着
##   `lift_at(wx,wy,world,m)` **又算一次** elev（lift_at 内部就是
##   `elevation_at(...) * 常数`）—— 而 `base_elevation` 内含两次
##   FastNoiseLite.get_noise_2d，是本工程最贵的单次计算。
##   ⇒ 每格的噪声采样被**翻倍执行**，而结果 bit 级相同。
## headless 插桩实测：world_map._ready 里 `mesh.setup` 单项 **226ms**
## （4095 格 × 2 次噪声 = 8190 次采样，~55μs/格）。
## 现改为**只算一次 elev，再由它导出 lift**，语义逐位等价。
## 同时 `_sample_city_mask` / `_world_size` 各只调一次（原式 mask 调了 2 次）。
## @returns {elev: float 0~1, lift: float 向上抬升的世界像素}
func sample_height(wx: float, wy: float) -> Dictionary:
	var world := _world_size()
	var m := _sample_city_mask(wx, wy)
	var e := TerrainHeight.elevation_at(wx, wy, world, m)
	# 【单一真源】lift 由**已算好的 e** 线性导出，不再重算一次 elevation_at。
	# 常数与 TerrainHeight.lift_at 内部完全一致（HEIGHT_SCALE × VERT_EXAGGERATE）。
	return {
		"elev": e,
		"lift": e * TerrainHeight.HEIGHT_SCALE * TerrainHeight.VERT_EXAGGERATE,
		"band": TerrainHeight.band_name(e),
	}


## 世界全图尺寸（宏观地理归一化用）
func _world_size() -> Vector2:
	return Vector2(
		float(_region_data.get("width", 21256)),
		float(_region_data.get("height", 21826)))


## 程序化生成「中国古代地势图」**Image**（写实风格）——按指定世界矩形生成。
## 包含：西部山脉与高原、西北沙漠、北方草原、中原平原、南方森林（西高东低三级阶梯）。
## 河流不在纹理内画，由 draw_polyline 单独绘制（清晰、可缩放）。
## 坐标约定：x=西→东，y=北→南；噪声按世界坐标采样，任意矩形生成结果连续一致。
## smooth=true：内部按 sz/2 逐像素计算后 lanczos 放大到 sz。
## 【线程约定】本函数只读成员（_region_data/_city_mask/噪声局部变量），可安全在
## WorkerThreadPool 工作线程执行；唯一的前置条件：主线程已先建好 _city_mask。
func _make_geo_image_for_rect(rect: Rect2, sz: int, smooth := false) -> Image:
	var gen := maxi(2, sz / 2) if smooth else sz
	var img := Image.create(gen, gen, false, Image.FORMAT_RGBA8)
	var world := _world_size()

	# 多层噪声（世界坐标采样）：大尺度地势 + 中尺度起伏 + 细节。
	# frequency 为「每世界单位」频率，特征尺度约 3000 / 1100 / 380 世界像素。
	var n_elev := FastNoiseLite.new()
	n_elev.seed = 2026
	n_elev.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_elev.frequency = 1.0 / 3000.0

	var n_mid := FastNoiseLite.new()
	n_mid.seed = 7788
	n_mid.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_mid.frequency = 1.0 / 1100.0

	var n_detail := FastNoiseLite.new()
	n_detail.seed = 3344
	n_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_detail.frequency = 1.0 / 380.0

	# 湿度噪声：植被带按「海拔+湿度」平滑过渡，替代生硬的纬度分带
	# （旧版纬度一刀切 + 高山色过暗，区域接缝处出现大片近黑色斑块，
	# 用户观感是「地图中间有空隙/黑块」）。
	var n_humid := FastNoiseLite.new()
	n_humid.seed = 5566
	n_humid.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_humid.frequency = 1.0 / 2200.0

	# 预取城池影响蒙版（每座城周围一圈平坦田园区，地貌随三国点位走）
	var mask: PackedFloat32Array = _get_city_mask()

	for y in range(gen):
		# 纹素 → 世界坐标
		var wy: float = rect.position.y + (float(y) + 0.5) / float(gen) * rect.size.y
		var ny: float = wy / maxf(world.y, 1.0)   # 0=北, 1=南
		# 纬度带：北方干燥、南方湿润
		var south_factor: float = ny
		for x in range(gen):
			var wx: float = rect.position.x + (float(x) + 0.5) / float(gen) * rect.size.x
			var nx: float = wx / maxf(world.x, 1.0)   # 0=西, 1=东

			# 海拔：西高东低（中国地势三级阶梯），叠加噪声
			var west_factor: float = 1.0 - nx          # 1在西, 0在东
			var elev_base: float = west_factor * west_factor * 0.8   # 西部隆起
			var elev: float = elev_base \
				+ n_elev.get_noise_2d(wx, wy) * 0.4 \
				+ n_mid.get_noise_2d(wx, wy) * 0.18
			elev = clampf(elev, 0.0, 1.0)
			var humid: float = clampf(
				south_factor * 0.7 + n_humid.get_noise_2d(wx, wy) * 0.45, 0.0, 1.0)

			# 【城池点锚定】靠近城池 → 压平为低海拔田园平原（山脉避开城池）
			var m: float = _sample_city_mask(wx, wy)
			if m > 0.0:
				elev = lerpf(elev, 0.28, m * 0.85)

			# 确定基础色（按海拔/湿度连续混合，无硬分界）
			var col: Color
			if elev > 0.80:
				# 高山：岩石灰棕，只留极高峰雪顶（旧版 0.72 起判山、色过暗，显成黑块）
				col = Color(0.50, 0.45, 0.39)
				if elev > 0.90:
					col = col.lerp(Color(0.90, 0.90, 0.93), (elev - 0.90) / 0.10)
			elif elev > 0.62:
				# 低山丘陵：黄绿过渡带
				col = Color(0.36, 0.42, 0.26).lerp(Color(0.50, 0.45, 0.39),
					(elev - 0.62) / 0.18)
			elif humid < 0.35:
				# 干旱区：草原偏黄 / 西北沙化
				col = Color(0.52, 0.50, 0.30) if nx < 0.30 else Color(0.46, 0.48, 0.26)
			elif humid < 0.60:
				# 半湿润：平原农田绿
				col = Color(0.34, 0.46, 0.22)
			else:
				# 湿润：亚热带常绿林（比旧版亮两档，消除近黑观感）
				col = Color(0.24, 0.40, 0.18)

			# 城池周边染田园聚落色（比野地亮、偏农田黄绿）
			if m > 0.0:
				col = col.lerp(Color(0.46, 0.52, 0.30), m * 0.55)

			# 细节噪声微调色明度
			var d: float = n_detail.get_noise_2d(wx, wy) * 0.10
			col = col.lightened(d)

			img.set_pixel(x, y, col)

	# 半分辨率计算后平滑放大（噪声高频细节已在 512 尺度下完整保留）
	if smooth and gen != sz:
		img.resize(sz, sz, Image.INTERPOLATE_LANCZOS)

	return img


## 同步生成纹理（Image + GPU 上传）。仅供非热路径使用（分块/远景都已后台化）。
func _make_geo_tex_for_rect(rect: Rect2, sz: int, smooth := false) -> Texture2D:
	return ImageTexture.create_from_image(_make_geo_image_for_rect(rect, sz, smooth))


## 程序化生成地形贴图（外部贴图不可用时的兜底）。
## 用 FastNoiseLite 生成噪声，按地形底色做明暗变化，让地貌有自然纹理而非纯色块。
func _make_procedural_terrain_tex(terrain: String, sz: int = 256) -> Texture2D:
	var base: Color = TERRAIN_COLORS.get(terrain, TERRAIN_COLORS["plain"])
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = hash(terrain)
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 4.0 / float(sz)
	var noise2 := FastNoiseLite.new()
	noise2.seed = hash(terrain) + 99
	noise2.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise2.frequency = 12.0 / float(sz)
	for y in range(sz):
		for x in range(sz):
			var n: float = noise.get_noise_2d(x, y)        # -1..1 大尺度起伏
			var n2: float = noise2.get_noise_2d(x, y)       # -1..1 细节
			var v: float = n * 0.6 + n2 * 0.4               # 混合
			# 按噪声微调明度：亮处 +0.12，暗处 -0.12
			var c: Color = base.lightened(v * 0.12)
			# 山地：暗部加岩石灰斑
			if terrain == "mountain" and v < -0.3:
				c = c.lerp(Color(0.55, 0.50, 0.45), 0.35)
			# 森林：亮部加树冠深绿点
			elif terrain == "forest" and v > 0.25:
				c = c.lerp(Color(0.08, 0.18, 0.08), 0.45)
			# 沙漠：亮部加沙金高光
			elif terrain == "desert" and v > 0.2:
				c = c.lerp(Color(0.66, 0.56, 0.34), 0.3)
			# 雪地：暗部加灰蓝阴影
			elif terrain == "snow" and v < -0.2:
				c = c.lerp(Color(0.62, 0.66, 0.72), 0.3)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


func get_map_size() -> Vector2:
	return Vector2(
		float(_region_data.get("width", 2400)),
		float(_region_data.get("height", 1400))
	)


func _draw() -> void:
	if _region_data.is_empty():
		return

	var size := get_map_size()

	# 1. 地势底图 —— 用户拍板换回 AI 写实全景图作大地图底图，
	#    小地图同步用同一张（见 _get_minimap_tex）。静态烘焙整图降为回退，
	#    程序化远景再回退，保证永不黑屏。
	#    【地貌细节修复 2026-10-01】优先用 china_geo_2048（与 minimap 同源）：
	#    1024 版 1 纹素≈21 世界像素，近景糊成色块；2048 版减半到 ≈10，
	#    行走视角能看清山体/河谷的走向，且远景更锐、显存零新增（minimap 已加载）。
	# 底图：china_geo_4096 优先（zoom=1.0 默认即近景，放大从 ~10x 降到 ~5x，锐度翻倍）
	var art := _get_near_detail_tex()
	if art == null:
		art = _get_art_geo_2048_tex()
	if art == null:
		art = _get_art_geo_tex()
	if art != null:
		draw_texture_rect(art, Rect2(Vector2.ZERO, size), false)
	else:
		var st_fallback := _get_static_tex_lazy()
		if st_fallback != null:
			draw_texture_rect(st_fallback, Rect2(Vector2.ZERO, size), false)
		else:
			draw_texture_rect(_get_lowres_world_tex(), Rect2(Vector2.ZERO, size), false)

	# 1.5 【R3-02】近景细节层（仅 AI 底图路径，远观系数=0 不画）：
	#     256 程序化噪声 tile 平铺提供屏级频率地表颗粒；
	#     高清整图 α 渐入把近景从「10 纹素放大糊」提到「5 纹素+锐化边缘」。
	#     【地貌细节修复 2026-10-01】高清层改用 china_geo_4096（AI 图 lanczos
	#     放大 + USM 锐化离线烘焙，管线见 03-美术资源/tools/_china_geo_4096_bake.py）
	#     —— 与底图同源同色，近景等于「把同一张画拉近看」，山脊/河谷走向清晰；
	#     旧 world_static 是程序化噪声烘焙图，没有山川水系，α=1.0 全开会把
	#     AI 底图整个盖平（主视图纯绿的元凶），降级为 4096 缺失时的低透明度回退。
	if art != null:
		var near := _near_detail_factor()
		if near > 0.001:
			# 【重复绘制守卫】底图已是 4096 细节图时不再重画（同一张纹理二次
			# 混合纯属浪费）；仅当底图是 2048/1024 回退时才把 4096 渐入叠加。
			var hi_near := _get_near_detail_tex()
			if hi_near != null and hi_near != art:
				draw_texture_rect(hi_near, Rect2(Vector2.ZERO, size), false,
					Color(1, 1, 1, near))
			else:
				var st_near := _get_static_tex_lazy()
				if st_near != null and hi_near == null:
					draw_texture_rect(st_near, Rect2(Vector2.ZERO, size), false,
						Color(1, 1, 1, NEAR_STATIC_ALPHA * near))
			# 【质感 2026-10-01】detail.png 稀疏白噪点降 α 0.42→0.15：512 纹素
			# tile 平铺全图后每噪点被拉成 40~120px 软白团，0.42 时满屏「脏糊」
			# 观感；0.15 只留细微星点肌理，锐利度交给 4096 多尺度锐化烘焙。
		var grain := _get_terrain_texture("detail", 512)
		draw_texture_rect(grain, Rect2(Vector2.ZERO, size), true, Color(1, 1, 1, 0.15 * near))

	# 2. 区域地貌（在地势图上叠加，低透明度，不破坏整体感）
	#    有机多边形必须「每区域重置种子」保证逐帧形状一致；
	#    旧写法共享 _rng 连续消耗，两次重绘形状不同 —— 叠加层会轻微抖动。
	#    【卡顿修复】形状是静态的：算一次进缓存，重绘只发 draw 命令不再重算。
	#    【精细感 2026-10-01】清晰几何细节随 zoom 淡入（_detail_fade=near）：
	#    远景时几千个小点会缩成亚像素噪点闪烁，近景才全开。
	_detail_fade = _near_detail_factor()
	var regions: Array = _region_data.get("regions", [])
	for i in range(regions.size()):
		_draw_region_ground(regions[i], i)
		if _detail_fade > 0.02:
			_draw_region_detail(regions[i], i)
	_detail_fade = 1.0

	# 3. 道路 / 4. 河流 —— 仅当没有任何真实地貌纹理（纯程序化 lowres 回退）时才绘制：
	#    china_geo 写实图与烘焙静态图自带地理水系，region_data 的虚构坐标折线叠上去
	#    与图内真实河流互相错位打架 —— 即用户反馈的「大地图蓝色多余线条」。
	var has_real_tex := art != null or _static_tex != null
	if not has_real_tex:
		var roads: Array = _region_data.get("roads", [])
		for i in range(roads.size()):
			_draw_road(roads[i], 91001 + i * 131)
		# 河流仅视觉，无阻挡
		var rivers: Array = _region_data.get("rivers", [])
		for i in range(rivers.size()):
			_draw_river(rivers[i], 71003 + i * 137)

	# 【四十二轮】四季地形变色：随 GameState 季节给整图叠一层氛围罩 + 冬季北方积雪。
	# 纯叠加（normal blend，低透明度），不改底层 AI 写实图/程序化底图，零新增美术资源；
	# 季节切换由 _process 检测并 queue_redraw()，本函数只重绘时执行一次。
	var season := GameState.get_season()
	var mood := (SEASON_MOOD.get(season, SEASON_MOOD[3])) as Color
	draw_rect(Rect2(Vector2.ZERO, size), mood, true)
	if season == 3:   # SEASON_WINTER：北方(地图顶, ny 小)雪厚、南方无雪
		var sg := _get_snow_gradient()
		draw_texture_rect(sg, Rect2(Vector2.ZERO, size), false, Color(1, 1, 1, 0.30))

	# 【装饰层已删除】旧的 _draw_decor 把随机树/石/草撒在「相机可视区」里，
	# 相机每动一帧整批点跟着视口漂移（玩家观感：小点贴着人物漂浮），
	# 且每帧最多 400 个圆点重录，加剧卡顿。噪声明暗纹理已足够表现地表，
	# 不再叠加几何装饰。


## 【已移除】_draw_geo_chunks（近景分块绘制）—— 静态地图模式下不再需要，
## 整图由 _draw 的 world_static.png 一次性铺底（见 _static_tex）。


## 绘制一块区域的地貌底色（在全局地势图上叠加淡淡的地形色，不覆盖地势细节）
## 【卡顿修复】静态几何缓存：河流/道路折线、区域有机多边形都是静态数据，
## 每次重绘重算（Catmull-Rom 细分 + 121 个多边形）是行走卡顿主因之一。
var _poly_cache := {}      ## 种子 -> PackedVector2Array（道路/河流）
var _organic_cache := {}   ## 区域索引 -> PackedVector2Array
## 区域细节几何的全局淡入系数（= 近景细节系数；远景 0 不画，防亚像素噪点闪烁）
var _detail_fade := 1.0


func _draw_region_ground(region: Dictionary, idx: int) -> void:
	var rect: Array = region.get("rect", [0, 0, 100, 100])
	var terrain := str(region.get("terrain", "plain"))
	var base := Rect2(float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3]))

	# 区域只叠一层低透明度的地形色（10%），让全局地势图透出来，
	# 同时保留区域间的微妙色彩差异，不再整块贴图盖住背景
	# （旧版 22% 叠出深色斑块；【质感 2026-10-01】14%→10%，大色块
	# 柔边多边形叠多了会洗掉底图锐度，精细度优先）。
	var color: Color = TERRAIN_COLORS.get(terrain, TERRAIN_COLORS["plain"])
	color.a = 0.10
	var points: PackedVector2Array
	if _organic_cache.has(idx):
		points = _organic_cache[idx]
	else:
		_rng.seed = RNG_SEED + idx * 7919
		points = _make_organic_polygon(base, 10, 0.12)
		_organic_cache[idx] = points
	draw_colored_polygon(points, color)


## 点是否在椭圆内（用于裁剪纹理平铺范围）
func _in_ellipse(p: Vector2, center: Vector2, half: Vector2) -> bool:
	var dx := (p.x - center.x) / maxf(half.x, 1.0)
	var dy := (p.y - center.y) / maxf(half.y, 1.0)
	return dx * dx + dy * dy <= 1.0


## 生成有机形状的边界（模拟自然地貌不规则轮廓）
func _make_organic_polygon(rect: Rect2, segments: int, jitter: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var center := rect.position + rect.size * 0.5
	var half := rect.size * 0.5

	for i in range(segments):
		var t := float(i) / float(segments) * TAU
		# 椭圆基底 + 噪声扰动
		var radius_scale := 1.0 + _rng.randf_range(-jitter, jitter)
		var p := center + Vector2(cos(t) * half.x, sin(t) * half.y) * radius_scale
		pts.append(p)
	return pts


## 绘制区域内部的纹理细节（清晰几何，固定世界尺寸 → 任意缩放都锐利，
## 补足 AI 底图在近景被放大发虚的观感）。
## 确定性：每区域重置种子，重绘形状一致不闪；密度按区域面积自适应
## （region 为世界坐标大块，原固定 26/30 在大区上稀疏得看不见）。
## 视觉：半透明叠在 AI 底图之上，只透出底图地理色，补「近景才看清」的
## 山脊 / 林木 / 草丛 / 沙斑 —— 这一步是「精细感」的主来源。
func _draw_region_detail(region: Dictionary, idx: int) -> void:
	var terrain := str(region.get("terrain", "plain"))
	var rect: Array = region.get("rect", [0, 0, 100, 100])
	var base := Rect2(float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3]))
	# 【加密不卡顿】视口裁剪：相机可视矩形外的区域整块跳过，
	# 这样密度可翻倍而不增加离屏 draw 调用（_cam_view 由 world_map 每帧 set_camera_view 更新）
	if _cam_view.size.x > 0.001 and _cam_view.size.y > 0.001:
		if not base.intersects(_cam_view.grow(260.0)):
			return
	_rng.seed = RNG_SEED + idx * 104729
	var area := base.size.x * base.size.y
	match terrain:
		"mountain":
			_draw_mountains(base)
		"forest":
			_draw_trees(base, int(clampf(area / 22000.0, 8, 2200)))
		"swamp":
			_draw_water_ripples(base)
		"plain":
			_draw_grass_tufts(base, int(clampf(area / 18000.0, 10, 2600)))
		"desert":
			_draw_desert_specks(base, int(clampf(area / 28000.0, 6, 1800)))


## 山脊线
func _draw_mountains(rect: Rect2) -> void:
	var color := Color(0.46, 0.42, 0.38, 0.75 * _detail_fade)
	var shadow := Color(0.22, 0.20, 0.18, 0.5 * _detail_fade)
	var count := int(rect.size.x / 64.0)
	for i in range(count):
		var bx := rect.position.x + 40 + i * 110.0 + _rng.randf_range(-24, 24)
		var by := rect.position.y + _rng.randf_range(rect.size.y * 0.12, rect.size.y * 0.88)
		var h := _rng.randf_range(50.0, 95.0)
		var w := _rng.randf_range(50.0, 80.0)
		# 山体
		var peak := PackedVector2Array([
			Vector2(bx - w, by),
			Vector2(bx, by - h),
			Vector2(bx + w, by),
		])
		draw_colored_polygon(peak, color)
		# 暗面
		var dark := PackedVector2Array([
			Vector2(bx, by - h),
			Vector2(bx + w, by),
			Vector2(bx, by),
		])
		draw_colored_polygon(dark, shadow)


## 树丛
func _draw_trees(rect: Rect2, count: int) -> void:
	for i in range(count):
		var p := Vector2(
			rect.position.x + _rng.randf_range(0, rect.size.x),
			rect.position.y + _rng.randf_range(0, rect.size.y)
		)
		var r := _rng.randf_range(9.0, 17.0)
		var c := Color(0.10, 0.22, 0.12, 0.85 * _detail_fade)
		draw_circle(p, r, c)
		draw_circle(p - Vector2(r * 0.3, r * 0.3), r * 0.6, Color(c.lightened(0.18), c.a))


## 水波纹
func _draw_water_ripples(rect: Rect2) -> void:
	var color := Color(0.45, 0.62, 0.65, 0.5 * _detail_fade)
	var rows := int(rect.size.y / 18.0)
	for r in range(rows):
		var y := rect.position.y + 15 + r * 30.0
		var x := rect.position.x + _rng.randf_range(0, 40)
		while x < rect.position.x + rect.size.x - 20:
			var seg := _rng.randf_range(18.0, 44.0)
			draw_line(Vector2(x, y), Vector2(x + seg, y), color, 2.0, true)
			x += seg + _rng.randf_range(20.0, 60.0)


## 草丛
func _draw_grass_tufts(rect: Rect2, count: int) -> void:
	var color := Color(0.42, 0.52, 0.26, 0.6 * _detail_fade)
	for i in range(count):
		var p := Vector2(
			rect.position.x + _rng.randf_range(0, rect.size.x),
			rect.position.y + _rng.randf_range(0, rect.size.y)
		)
		for j in range(3):
			var ox := _rng.randf_range(-6, 6)
			draw_line(p, p + Vector2(ox, -_rng.randf_range(5, 11)), color, 1.5, true)


## 沙漠沙斑（细密浅色点，半透明叠出沙地质感）
func _draw_desert_specks(rect: Rect2, count: int) -> void:
	var light := Color(0.72, 0.66, 0.42, 0.45 * _detail_fade)
	var dark := Color(0.40, 0.36, 0.22, 0.40 * _detail_fade)
	for i in range(count):
		var p := Vector2(
			rect.position.x + _rng.randf_range(0, rect.size.x),
			rect.position.y + _rng.randf_range(0, rect.size.y))
		var r := _rng.randf_range(6.0, 16.0)
		draw_circle(p, r, dark if _rng.randf() < 0.5 else light)


## 绘制河流（分层水面 + 渡口浅滩）。
## 【美化】原始折线点稀疏且直，粗描边画出来像"蓝色胶带"（用户反馈"太丑"）。
## 现在：控制点先做低幅垂直扰动（确定性种子，逐帧一致）→ Catmull-Rom 细分成
## 自然蜿蜒曲线 → 三层半透明描边（河床/水面/中央亮水），宽度也收窄一档。
func _draw_river(river: Dictionary, seed: int) -> void:
	var pts: PackedVector2Array
	if _poly_cache.has(seed):
		pts = _poly_cache[seed]
	else:
		pts = _natural_polyline(river.get("points", []), 22.0, seed)
		_poly_cache[seed] = pts
	if pts.size() < 2:
		return

	# 分层水面（半透明叠色比实色柔和得多）
	draw_polyline(pts, Color(0.16, 0.24, 0.30, 0.50), 30.0, true)   # 河床暗边
	draw_polyline(pts, Color(0.30, 0.47, 0.55, 0.78), 22.0, true)   # 水面
	draw_polyline(pts, Color(0.55, 0.70, 0.74, 0.45), 7.0, true)    # 中央亮水

	# 渡口浅滩（沙色椭圆，提示此处可过河）
	for f in river.get("fords", []):
		var fp := Vector2(float(f[0]), float(f[1]))
		draw_circle(fp, 30.0, Color(0.62, 0.56, 0.40, 0.75))
		draw_circle(fp, 21.0, Color(0.72, 0.66, 0.48, 0.88))


## 绘制道路（土路双层细描）。
## 【美化】同河流：扰动+平滑后蜿蜒自然，颜色调淡、宽度收窄，不再压过地貌。
func _draw_road(road: Dictionary, seed: int) -> void:
	var pts: PackedVector2Array
	if _poly_cache.has(seed):
		pts = _poly_cache[seed]
	else:
		pts = _natural_polyline(road.get("points", []), 30.0, seed)
		_poly_cache[seed] = pts
	if pts.size() < 2:
		return

	# 路基（略宽的暗土色，半透明）+ 路面（亮土色）
	draw_polyline(pts, Color(0.30, 0.26, 0.18, 0.45), 11.0, true)
	draw_polyline(pts, Color(0.55, 0.48, 0.34, 0.65), 6.0, true)


## 把稀疏控制点折线变成自然曲线：
## 1) 控制点沿法线做低幅扰动（种子确定性 —— 每次重绘形状一致）；
## 2) Catmull-Rom 细分（每段 6 步），得到平滑蜿蜒的路径。
func _natural_polyline(pts_raw: Array, jitter: float, seed: int) -> PackedVector2Array:
	var ctrl := PackedVector2Array()
	for p in pts_raw:
		ctrl.append(Vector2(float(p[0]), float(p[1])))
	if ctrl.size() < 2:
		return ctrl

	# 控制点垂直扰动（首尾不扰动，保持与城池/渡口的连接关系）
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for i in range(1, ctrl.size() - 1):
		var prev := ctrl[i - 1]
		var next := ctrl[i + 1]
		var dir := (next - prev).normalized()
		var normal := Vector2(-dir.y, dir.x)
		ctrl[i] += normal * rng.randf_range(-jitter, jitter)

	# Catmull-Rom 细分
	var out := PackedVector2Array()
	var n := ctrl.size()
	for i in range(n - 1):
		var p0 := ctrl[maxi(i - 1, 0)]
		var p1 := ctrl[i]
		var p2 := ctrl[i + 1]
		var p3 := ctrl[mini(i + 2, n - 1)]
		for s in range(6):
			var t := float(s) / 6.0
			var t2 := t * t
			var t3 := t2 * t
			out.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t
				+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
				+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	out.append(ctrl[n - 1])
	return out


## 【已删除 _draw_decor / _draw_decor_tree / _draw_decor_rock / _draw_decor_bush】
## 装饰圆点以相机可视区为基准撒点，随镜头漂移（「小点贴着人物漂浮」），
## 且每帧数百个 draw_circle 加剧重绘成本。地表细节由噪声纹理承担。
