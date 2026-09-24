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

const DECOR_DENSITY := 0.0000032  ## 装饰物密度（约 1500 个，降低 draw call 提升帧率）
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


## 载入区域数据
func load_region(region_id: String) -> void:
	var table: Array = DataManager.get_table("terrain")
	for r in table:
		if str(r.get("id", "")) == region_id:
			_region_data = r
			break
	_tex_cache.clear()
	queue_redraw()


## 设置当前区域窗口（由 world_map._ready 调用，用于区域级高清纹理和装饰物定位）
func set_view_rect(rect: Rect2) -> void:
	_view_rect = rect
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


## 获取中国古代地势图（全图兜底版，缓存，首次生成）
var _china_geo_tex: Texture2D = null

func _get_china_geography_tex() -> Texture2D:
	if _china_geo_tex != null:
		return _china_geo_tex
	# 512×512 全图底图：只用于区域窗口外的边缘兜底（相机 10% 露白处可见）。
	# 玩家主要看到的区域窗口由 _get_region_geo_tex 高清纹理负责。
	_china_geo_tex = _make_geo_tex_for_rect(Rect2(Vector2.ZERO, _world_size()), 512)
	return _china_geo_tex


## 区域级高清地势纹理（解决背景模糊的核心）。
## 【背景模糊根源】全图 21256×21826 只生成一张 512 纹理拉伸铺满（41 倍），
## 区域窗口只显示纹理的一小角被拉到整屏 → 一片马赛克。
## 现在按「当前区域矩形」单独生成 512 纹理只铺区域（拉伸比降到 ~9 倍），
## 噪声用世界坐标采样 —— 与全图底图逐点一致，切换区域时地貌无缝衔接。
var _region_geo_tex: Texture2D = null
var _region_geo_rect := Rect2()

func _get_region_geo_tex(rect: Rect2) -> Texture2D:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return null
	if _region_geo_tex != null and _region_geo_rect == rect:
		return _region_geo_tex
	_region_geo_rect = rect
	_region_geo_tex = _make_geo_tex_for_rect(rect, 512)
	return _region_geo_tex


## 世界全图尺寸（宏观地理归一化用）
func _world_size() -> Vector2:
	return Vector2(
		float(_region_data.get("width", 21256)),
		float(_region_data.get("height", 21826)))


## 程序化生成「中国古代地势图」纹理（写实风格）——按指定世界矩形生成。
## 包含：西部山脉与高原、西北沙漠、北方草原、中原平原、南方森林（西高东低三级阶梯）。
## 河流不在纹理内画，由 draw_polyline 单独绘制（清晰、可缩放）。
## 坐标约定：x=西→东，y=北→南；噪声按世界坐标采样，任意矩形生成结果连续一致。
func _make_geo_tex_for_rect(rect: Rect2, sz: int) -> Texture2D:
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
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

	for y in range(sz):
		# 纹素 → 世界坐标
		var wy: float = rect.position.y + (float(y) + 0.5) / float(sz) * rect.size.y
		var ny: float = wy / maxf(world.y, 1.0)   # 0=北, 1=南
		# 纬度带：北方干燥、南方湿润
		var south_factor: float = ny
		for x in range(sz):
			var wx: float = rect.position.x + (float(x) + 0.5) / float(sz) * rect.size.x
			var nx: float = wx / maxf(world.x, 1.0)   # 0=西, 1=东

			# 海拔：西高东低（中国地势三级阶梯），叠加噪声
			var west_factor: float = 1.0 - nx          # 1在西, 0在东
			var elev_base: float = west_factor * west_factor * 0.8   # 西部隆起
			var elev: float = elev_base \
				+ n_elev.get_noise_2d(wx, wy) * 0.4 \
				+ n_mid.get_noise_2d(wx, wy) * 0.18
			elev = clampf(elev, 0.0, 1.0)

			# 确定基础色
			var col: Color
			if elev > 0.72:
				# 高山：岩石棕灰，高海拔加雪顶
				col = Color(0.42, 0.36, 0.30)
				if elev > 0.85:
					col = col.lerp(Color(0.92, 0.92, 0.94), (elev - 0.85) / 0.15)
			elif nx < 0.28 and elev > 0.35:
				# 西北沙漠
				col = Color(0.56, 0.47, 0.30)
			elif south_factor < 0.35:
				# 北方草原
				col = Color(0.42, 0.46, 0.24)
			elif south_factor < 0.55:
				# 中原平原
				col = Color(0.30, 0.44, 0.20)
			else:
				# 南方森林
				col = Color(0.16, 0.30, 0.14)

			# 细节噪声微调色明度
			var d: float = n_detail.get_noise_2d(wx, wy) * 0.12
			col = col.lightened(d)

			img.set_pixel(x, y, col)

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
	# 装饰物数量按区域窗口面积自适应（区域窗口约 5000×9000 → ~230 个）
	var decor_count := int(_view_rect.size.x * _view_rect.size.y * DECOR_DENSITY) if _view_rect.size.x > 0.0 else int(size.x * size.y * DECOR_DENSITY)

	# 1. 底色：全图兜底地势图（512 纹理拉伸铺满 21256×21826，仅在区域窗口外边缘露白处可见）
	var geo_tex := _get_china_geography_tex()
	if geo_tex != null:
		draw_texture_rect(geo_tex, Rect2(Vector2.ZERO, size), false)
	else:
		var base_terrain := str(_region_data.get("base_terrain", "grass"))
		draw_rect(Rect2(Vector2.ZERO, size), TERRAIN_COLORS.get(base_terrain, TERRAIN_COLORS["grass"]))

	# 1b. 区域级高清地势纹理（512 纹理只铺区域矩形，拉伸比 ~9 倍，解决背景模糊核心）
	var region_tex := _get_region_geo_tex(_view_rect)
	if region_tex != null:
		draw_texture_rect(region_tex, _view_rect, false)

	# 2. 区域地貌（在地势图上叠加，低透明度，不破坏整体感）
	var regions: Array = _region_data.get("regions", [])
	for region in regions:
		_draw_region_ground(region)

	# 3. 道路
	for road in _region_data.get("roads", []):
		_draw_road(road)

	# 4. 河流（仅视觉，无阻挡）——按名称分级加宽 + Catmull-Rom 平滑
	for river in _region_data.get("rivers", []):
		_draw_river(river)

	# 5. 装饰物（只在区域窗口内密植，避免全图铺浪费 draw call）
	_draw_decor(_view_rect.size if _view_rect.size.x > 0.0 else size, decor_count)


## 绘制一块区域的地貌底色（在全局地势图上叠加淡淡的地形色，不覆盖地势细节）
func _draw_region_ground(region: Dictionary) -> void:
	var rect: Array = region.get("rect", [0, 0, 100, 100])
	var terrain := str(region.get("terrain", "plain"))
	var base := Rect2(float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3]))

	# 区域只叠一层低透明度的地形色（~22%），让全局地势图透出来，
	# 同时保留区域间的微妙色彩差异，不再整块贴图盖住背景。
	var color: Color = TERRAIN_COLORS.get(terrain, TERRAIN_COLORS["plain"])
	color.a = 0.22
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


## 绘制河流（河床描边 + 水面 + 渡口浅滩）
## 河流是「开放折线」，draw_polyline 的 closed 必须为 false；
## 误设为 true 会从终点连回起点，画出一条横贯地图的幽灵蓝线（即用户反馈的「多余蓝线」）。
func _draw_river(river: Dictionary) -> void:
	var pts_raw: Array = river.get("points", [])
	if pts_raw.size() < 2:
		return
	var pts := PackedVector2Array()
	for p in pts_raw:
		pts.append(Vector2(float(p[0]), float(p[1])))

	# 河床（深色描边，略宽于水面）
	draw_polyline(pts, Color(0.13, 0.20, 0.26, 0.85), 46.0, false)
	# 水面
	draw_polyline(pts, Color(0.26, 0.44, 0.52, 0.95), 36.0, false)
	# 中央亮水线
	draw_polyline(pts, Color(0.42, 0.60, 0.66, 0.45), 12.0, false)

	# 渡口浅滩（沙色椭圆，提示此处可过河）
	for f in river.get("fords", []):
		var fp := Vector2(float(f[0]), float(f[1]))
		draw_circle(fp, 34.0, Color(0.62, 0.56, 0.40, 0.9))
		draw_circle(fp, 24.0, Color(0.72, 0.66, 0.48, 0.95))


## 绘制道路（带描边的折线）
## 道路同样是开放折线，closed 必须为 false；否则终点连回起点出现幽灵棕线。
func _draw_road(road: Dictionary) -> void:
	var pts_raw: Array = road.get("points", [])
	if pts_raw.size() < 2:
		return
	var pts := PackedVector2Array()
	for p in pts_raw:
		pts.append(Vector2(float(p[0]), float(p[1])))

	# 路基（深色描边）
	draw_polyline(pts, Color(0.28, 0.24, 0.16, 0.9), 18.0, false)
	# 路面
	draw_polyline(pts, TERRAIN_COLORS["road"], 12.0, false)
	# 中线亮色
	draw_polyline(pts, Color(0.52, 0.45, 0.30, 0.7), 3.0, false)


## 区域窗口内随机装饰（树 / 石 / 草）
func _draw_decor(size: Vector2, count: int) -> void:
	# 装饰物绘制在区域窗口内（_view_rect 的世界坐标偏移）
	var offset := _view_rect.position if _view_rect.size.x > 0.0 else Vector2.ZERO
	for i in range(count):
		var p := offset + Vector2(_rng.randf_range(20, size.x - 20), _rng.randf_range(20, size.y - 20))
		var kind := _rng.randi_range(0, 3)
		match kind:
			0:
				_draw_decor_tree(p, _rng.randf_range(12.0, 20.0))
			1:
				_draw_decor_rock(p, _rng.randf_range(6.0, 11.0))
			2:
				_draw_decor_bush(p, _rng.randf_range(7.0, 12.0))
			_:
				pass


func _draw_decor_tree(p: Vector2, r: float) -> void:
	draw_circle(p, r, Color(0.12, 0.24, 0.13, 0.9))
	draw_circle(p - Vector2(r * 0.35, r * 0.35), r * 0.55, Color(0.20, 0.36, 0.20, 0.9))


func _draw_decor_rock(p: Vector2, r: float) -> void:
	draw_circle(p, r, Color(0.40, 0.38, 0.35, 0.85))
	draw_circle(p - Vector2(r * 0.3, r * 0.3), r * 0.5, Color(0.50, 0.48, 0.45, 0.85))


func _draw_decor_bush(p: Vector2, r: float) -> void:
	draw_circle(p, r, Color(0.24, 0.34, 0.18, 0.7))
