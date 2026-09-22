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

const DECOR_DENSITY := 0.0000085  ## 装饰物密度（每平方像素的个数，13000×8000 ≈ 880 个）
const RNG_SEED := 20260921        ## 固定随机种子，保证每次生成一致

## 地形贴图路径（存在则优先使用贴图，否则程序化绘制）
const TERRAIN_TEX_DIR := "res://assets/sprites/terrain/"

var _region_data: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _tex_cache: Dictionary = {}    ## 地形类型 -> Texture2D 或 null


func _ready() -> void:
	_rng.seed = RNG_SEED
	load_region("china")


## 载入区域数据
func load_region(region_id: String) -> void:
	var table := DataManager.get_table("terrain")
	for r in table:
		if str(r.get("id", "")) == region_id:
			_region_data = r
			break
	_tex_cache.clear()
	queue_redraw()


## 获取地形贴图（不存在则返回 null，走程序化绘制）
func _get_terrain_texture(terrain: String) -> Texture2D:
	if _tex_cache.has(terrain):
		return _tex_cache[terrain]
	var path: String = TERRAIN_TEX_DIR + terrain + ".png"
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path)
	_tex_cache[terrain] = tex
	return tex


func get_map_size() -> Vector2:
	return Vector2(
		float(_region_data.get("width", 2400)),
		float(_region_data.get("height", 1400))
	)


func _draw() -> void:
	if _region_data.is_empty():
		return

	var size := get_map_size()
	# 装饰物数量按地图面积自适应（大地图多铺，小地图不糊）
	var decor_count := int(size.x * size.y * DECOR_DENSITY)

	# 1. 底色
	draw_rect(Rect2(Vector2.ZERO, size), TERRAIN_COLORS.get(
		str(_region_data.get("base_terrain", "grass")), TERRAIN_COLORS["grass"]))

	# 2. 区域地貌
	var regions: Array = _region_data.get("regions", [])
	for region in regions:
		_draw_region_ground(region)

	# 3. 区域纹理细节
	for region in regions:
		_draw_region_detail(region)

	# 4. 道路
	for road in _region_data.get("roads", []):
		_draw_road(road)

	# 5. 装饰物
	_draw_decor(size, decor_count)


## 绘制一块区域的地貌底色
func _draw_region_ground(region: Dictionary) -> void:
	var rect: Array = region.get("rect", [0, 0, 100, 100])
	var terrain := str(region.get("terrain", "plain"))
	var base := Rect2(float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3]))

	# 优先使用贴图，平铺填充
	var tex := _get_terrain_texture(terrain)
	if tex != null:
		var ts := Vector2(tex.get_width(), tex.get_height())
		var x := base.position.x
		while x < base.position.x + base.size.x:
			var y := base.position.y
			while y < base.position.y + base.size.y:
				draw_texture(tex, Vector2(x, y))
				y += ts.y
			x += ts.x
		return

	# 回退：程序化绘制
	var color: Color = TERRAIN_COLORS.get(terrain, TERRAIN_COLORS["plain"])

	# 用不规则多边形柔化边缘，避免生硬的矩形
	var points := _make_organic_polygon(base, 10, 0.12)
	draw_colored_polygon(points, color)

	# 边缘加深，增强层次
	var edge_color := color.darkened(0.15)
	edge_color.a = 0.5
	draw_polyline(points + PackedVector2Array([points[0]]), edge_color, 3.0, true)


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
func _draw_river(river: Dictionary) -> void:
	var pts_raw: Array = river.get("points", [])
	if pts_raw.size() < 2:
		return
	var pts := PackedVector2Array()
	for p in pts_raw:
		pts.append(Vector2(float(p[0]), float(p[1])))

	# 河床（深色描边，略宽于水面）
	draw_polyline(pts, Color(0.13, 0.20, 0.26, 0.85), 46.0, true)
	# 水面
	draw_polyline(pts, Color(0.26, 0.44, 0.52, 0.95), 36.0, true)
	# 中央亮水线
	draw_polyline(pts, Color(0.42, 0.60, 0.66, 0.45), 12.0, true)

	# 渡口浅滩（沙色椭圆，提示此处可过河）
	for f in river.get("fords", []):
		var fp := Vector2(float(f[0]), float(f[1]))
		draw_circle(fp, 34.0, Color(0.62, 0.56, 0.40, 0.9))
		draw_circle(fp, 24.0, Color(0.72, 0.66, 0.48, 0.95))


## 绘制道路（带描边的折线）
func _draw_road(road: Dictionary) -> void:
	var pts_raw: Array = road.get("points", [])
	if pts_raw.size() < 2:
		return
	var pts := PackedVector2Array()
	for p in pts_raw:
		pts.append(Vector2(float(p[0]), float(p[1])))

	# 路基（深色描边）
	draw_polyline(pts, Color(0.28, 0.24, 0.16, 0.9), 18.0, true)
	# 路面
	draw_polyline(pts, TERRAIN_COLORS["road"], 12.0, true)
	# 中线亮色
	draw_polyline(pts, Color(0.52, 0.45, 0.30, 0.7), 3.0, true)


## 全图随机装饰（树 / 石 / 草）
func _draw_decor(size: Vector2, count: int) -> void:
	for i in range(count):
		var p := Vector2(_rng.randf_range(20, size.x - 20), _rng.randf_range(20, size.y - 20))
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
