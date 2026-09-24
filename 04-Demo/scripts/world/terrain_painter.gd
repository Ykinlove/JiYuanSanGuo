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

## 地形贴图路径（存在则优先使用贴图，否则程序化绘制）
const TERRAIN_TEX_DIR := "res://assets/sprites/terrain/"

var _region_data: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _tex_cache: Dictionary = {}    ## 地形类型 -> Texture2D 或 null
var _view_rect := Rect2()          ## 当前区域窗口的世界坐标矩形（由 world_map 设置）


func _ready() -> void:
	_rng.seed = RNG_SEED
	load_region("china")
	# 预热远景全图（分块模式的垫底图也用它）：延迟到首帧生成，
	# 避免玩家第一次走近城池时垫底图本身才懒加载造成一次性顿挫。
	call_deferred("_get_lowres_world_tex")


## 载入区域数据
func load_region(region_id: String) -> void:
	var table: Array = DataManager.get_table("terrain")
	for r in table:
		if str(r.get("id", "")) == region_id:
			_region_data = r
			break
	_tex_cache.clear()
	queue_redraw()


## 设置当前区域窗口（由 world_map._ready 调用，用于装饰物定位）
func set_view_rect(rect: Rect2) -> void:
	_view_rect = rect
	queue_redraw()


## 【虚拟纹理 LOD】world_map._process 每帧传入相机世界可视矩形。
## 远景（可视宽度大）画一张低清全图；近景按 2048 世界像素分块画高清纹理，
## 两级拉伸都只有 ~2 倍 —— 彻底替代「一张 1024 图拉 21 倍」的马赛克。
var _cam_view := Rect2()

## 重绘节流：相机挪动不足 96 世界像素且缩放未变时不重录绘制命令
## （旧行为是每帧 queue_redraw，一次重录 = 121 个区域多边形 + 道路河流折线，
## 是「移动一卡一卡」的主要来源之一）。
const REDRAW_MOVE_MIN := 96.0
var _last_drawn_view := Rect2()

func set_camera_view(rect: Rect2) -> void:
	var size_changed := rect.size != _cam_view.size
	var moved := _last_drawn_view.size == Vector2.ZERO \
		or rect.position.distance_to(_last_drawn_view.position) > REDRAW_MOVE_MIN
	_cam_view = rect
	if size_changed or moved:
		_last_drawn_view = rect
		queue_redraw()


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

## 远景：低清全图（缩放到全图可见时，1024 纹理 ≈ 屏宽 2 倍内，清晰）
var _lowres_world_tex: Texture2D = null

func _get_lowres_world_tex() -> Texture2D:
	if _lowres_world_tex == null:
		_lowres_world_tex = _make_geo_tex_for_rect(Rect2(Vector2.ZERO, _world_size()), 512, true)
	return _lowres_world_tex


## 近景：按 CHUNK_WORLD 世界像素分块，每块生成 CHUNK_TEX 纹理
## （2048 世界 → 1024 纹理 = 2 倍拉伸，特写清晰）。
## 【卡顿修复】单块生成 ~34ms，绝不能在 _draw 里同步补块（跨块边界一次补 2~3 块
## = 60~100ms 尖峰，玩家观感就是「一卡一卡」）。改为：_draw 只画已缓存块，
## 缺块先由远景全图垫底，_process 每帧最多生成 1 块补上。
const CHUNK_WORLD := 2048.0
const CHUNK_TEX := 1024
## 视口（1920×1080，缩放 0.62~2.4）最多同时覆盖 3×3=9 块，16 块缓存足够。
## 旧值 40 = 160MB 显存，是「走近城池贴图消失」的显存压力嫌疑来源之一。
const CHUNK_CACHE_MAX := 16
var _chunk_cache: Dictionary = {}   ## Vector2i -> Texture2D
var _chunk_order: Array = []        ## LRU 访问顺序
var _pending_chunks: Array = []     ## 待生成块队列（_process 每帧消费 1 个）

func _get_chunk_tex(ci: Vector2i) -> Texture2D:
	if _chunk_cache.has(ci):
		_chunk_order.erase(ci)
		_chunk_order.append(ci)
		return _chunk_cache[ci]
	var rect := Rect2(
		Vector2(float(ci.x), float(ci.y)) * CHUNK_WORLD,
		Vector2(CHUNK_WORLD, CHUNK_WORLD))
	# 内部按 512 逐像素算噪声再 lanczos 放大到 1024：成本降 4 倍，
	# 噪声最小特征 ~380 世界像素（= 95 纹素@512）不受损，观感依旧细腻。
	var tex := _make_geo_tex_for_rect(rect, 512, true)
	_chunk_cache[ci] = tex
	_chunk_order.append(ci)
	if _chunk_order.size() > CHUNK_CACHE_MAX:
		var old: Vector2i = _chunk_order.pop_front()
		_chunk_cache.erase(old)
	return tex


## 每帧最多补 1 块：34ms 成本摊到单帧，消除移动尖峰
func _process(_delta: float) -> void:
	if _pending_chunks.is_empty():
		return
	var ci: Vector2i = _pending_chunks.pop_front()
	if not _chunk_cache.has(ci):
		_get_chunk_tex(ci)
		queue_redraw()


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


## 世界全图尺寸（宏观地理归一化用）
func _world_size() -> Vector2:
	return Vector2(
		float(_region_data.get("width", 21256)),
		float(_region_data.get("height", 21826)))


## 程序化生成「中国古代地势图」纹理（写实风格）——按指定世界矩形生成。
## 包含：西部山脉与高原、西北沙漠、北方草原、中原平原、南方森林（西高东低三级阶梯）。
## 河流不在纹理内画，由 draw_polyline 单独绘制（清晰、可缩放）。
## 坐标约定：x=西→东，y=北→南；噪声按世界坐标采样，任意矩形生成结果连续一致。
## smooth=true：内部按 sz/2 逐像素计算后 lanczos 放大到 sz —— 成本降 4 倍，
## 噪声最小特征 ~380 世界像素不受损（分块纹理/远景全图都走此模式）。
func _make_geo_tex_for_rect(rect: Rect2, sz: int, smooth := false) -> Texture2D:
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

	return ImageTexture.create_from_image(img)


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

	# 1. 地势底图 —— 虚拟纹理 LOD：
	#    远景（可视世界宽 > 2 块）：一张 512→1024 全图，屏上仅 ~2 倍拉伸，清晰；
	#    近景（特写）：按 2048 世界像素分块逐块铺 1024 纹理（2 倍拉伸），
	#    彻底替代「一张 1024 图拉 21 倍」的马赛克。
	#    【贴图消失兜底】分块模式先铺一层远景全图垫底：某块纹理尚未生成
	#    （或显存压力下被回收）时，该处显示的是清晰度略低的地表而不是黑底虚空
	#    ——「走到城池旁边贴图没了」的直接对策。
	var view := _cam_view if _cam_view.size.x > 0.0 else Rect2(Vector2.ZERO, size)
	if view.size.x > CHUNK_WORLD * 2.0:
		draw_texture_rect(_get_lowres_world_tex(), Rect2(Vector2.ZERO, size), false)
	else:
		draw_texture_rect(_get_lowres_world_tex(), Rect2(Vector2.ZERO, size), false)
		_draw_geo_chunks(view, size)

	# 2. 区域地貌（在地势图上叠加，低透明度，不破坏整体感）
	#    有机多边形必须「每区域重置种子」保证逐帧形状一致；
	#    旧写法共享 _rng 连续消耗，两次重绘形状不同 —— 叠加层会轻微抖动。
	var regions: Array = _region_data.get("regions", [])
	for i in range(regions.size()):
		_rng.seed = RNG_SEED + i * 7919
		_draw_region_ground(regions[i])

	# 3. 道路（种子取索引，形状逐帧一致）
	var roads: Array = _region_data.get("roads", [])
	for i in range(roads.size()):
		_draw_road(roads[i], 91001 + i * 131)

	# 4. 河流（仅视觉，无阻挡）——平滑蜿蜒 + 分层半透明水面
	var rivers: Array = _region_data.get("rivers", [])
	for i in range(rivers.size()):
		_draw_river(rivers[i], 71003 + i * 137)

	# 【装饰层已删除】旧的 _draw_decor 把随机树/石/草撒在「相机可视区」里，
	# 相机每动一帧整批点跟着视口漂移（玩家观感：小点贴着人物漂浮），
	# 且每帧最多 400 个圆点重录，加剧卡顿。噪声明暗纹理已足够表现地表，
	# 不再叠加几何装饰。


## 近景分块：只画相机可视矩形覆盖到的块（只画已缓存块，缺块进队列异步补）。
## 生成成本 ~34ms/块，绝不在绘制路径里同步生成（卡顿尖峰来源）。
func _draw_geo_chunks(view: Rect2, world: Vector2) -> void:
	var nx := int(ceil(world.x / CHUNK_WORLD))
	var ny := int(ceil(world.y / CHUNK_WORLD))
	var cx0 := clampi(int(floor(view.position.x / CHUNK_WORLD)), 0, nx - 1)
	var cy0 := clampi(int(floor(view.position.y / CHUNK_WORLD)), 0, ny - 1)
	var cx1 := clampi(int(floor(view.end.x / CHUNK_WORLD)), 0, nx - 1)
	var cy1 := clampi(int(floor(view.end.y / CHUNK_WORLD)), 0, ny - 1)
	for cy in range(cy0, cy1 + 1):
		for cx in range(cx0, cx1 + 1):
			var ci := Vector2i(cx, cy)
			if not _chunk_cache.has(ci):
				# 缺块：远景全图已垫底，先排队下帧补生成
				if not _pending_chunks.has(ci):
					_pending_chunks.append(ci)
				continue
			var tex: Texture2D = _chunk_cache[ci]
			var rect := Rect2(
				Vector2(float(cx), float(cy)) * CHUNK_WORLD,
				Vector2(CHUNK_WORLD, CHUNK_WORLD))
			draw_texture_rect(tex, rect, false)


## 绘制一块区域的地貌底色（在全局地势图上叠加淡淡的地形色，不覆盖地势细节）
func _draw_region_ground(region: Dictionary) -> void:
	var rect: Array = region.get("rect", [0, 0, 100, 100])
	var terrain := str(region.get("terrain", "plain"))
	var base := Rect2(float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3]))

	# 区域只叠一层低透明度的地形色（~14%），让全局地势图透出来，
	# 同时保留区域间的微妙色彩差异，不再整块贴图盖住背景
	# （旧版 22% 叠出深色斑块，是「地图黑隙」观感的另一半来源）。
	var color: Color = TERRAIN_COLORS.get(terrain, TERRAIN_COLORS["plain"])
	color.a = 0.14
	var points := _make_organic_polygon(base, 10, 0.12)
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


## 绘制区域内部的纹理细节
func _draw_region_detail(region: Dictionary) -> void:
	var terrain := str(region.get("terrain", "plain"))
	var rect: Array = region.get("rect", [0, 0, 100, 100])
	var base := Rect2(float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3]))

	match terrain:
		"mountain":
			_draw_mountains(base)
		"forest":
			_draw_trees(base, 26)
		"swamp":
			_draw_water_ripples(base)
		"plain":
			_draw_grass_tufts(base, 30)


## 山脊线
func _draw_mountains(rect: Rect2) -> void:
	var color := Color(0.46, 0.42, 0.38, 0.75)
	var shadow := Color(0.22, 0.20, 0.18, 0.5)
	var count := int(rect.size.x / 90.0)
	for i in range(count):
		var bx := rect.position.x + 40 + i * 90.0 + _rng.randf_range(-18, 18)
		var by := rect.position.y + rect.size.y * 0.5 + _rng.randf_range(-rect.size.y * 0.25, rect.size.y * 0.25)
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
		var c := Color(0.10, 0.22, 0.12, 0.85)
		draw_circle(p, r, c)
		draw_circle(p - Vector2(r * 0.3, r * 0.3), r * 0.6, c.lightened(0.18))


## 水波纹
func _draw_water_ripples(rect: Rect2) -> void:
	var color := Color(0.45, 0.62, 0.65, 0.5)
	var rows := int(rect.size.y / 30.0)
	for r in range(rows):
		var y := rect.position.y + 15 + r * 30.0
		var x := rect.position.x + _rng.randf_range(0, 40)
		while x < rect.position.x + rect.size.x - 20:
			var seg := _rng.randf_range(18.0, 44.0)
			draw_line(Vector2(x, y), Vector2(x + seg, y), color, 2.0, true)
			x += seg + _rng.randf_range(20.0, 60.0)


## 草丛
func _draw_grass_tufts(rect: Rect2, count: int) -> void:
	var color := Color(0.42, 0.52, 0.26, 0.6)
	for i in range(count):
		var p := Vector2(
			rect.position.x + _rng.randf_range(0, rect.size.x),
			rect.position.y + _rng.randf_range(0, rect.size.y)
		)
		for j in range(3):
			var ox := _rng.randf_range(-6, 6)
			draw_line(p, p + Vector2(ox, -_rng.randf_range(5, 11)), color, 1.5, true)


## 绘制河流（分层水面 + 渡口浅滩）。
## 【美化】原始折线点稀疏且直，粗描边画出来像"蓝色胶带"（用户反馈"太丑"）。
## 现在：控制点先做低幅垂直扰动（确定性种子，逐帧一致）→ Catmull-Rom 细分成
## 自然蜿蜒曲线 → 三层半透明描边（河床/水面/中央亮水），宽度也收窄一档。
func _draw_river(river: Dictionary, seed: int) -> void:
	var pts := _natural_polyline(river.get("points", []), 22.0, seed)
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
	var pts := _natural_polyline(road.get("points", []), 30.0, seed)
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
