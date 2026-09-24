extends Node2D
class_name CityGround
## 城内地面绘制器
## 职责：画出城内场景的地表 —— 城墙与城门、主干道、建筑地基、草地点缀。
## 与 TerrainPainter 同思路：程序化绘制，检测到贴图则优先贴图（暂未接）。
##
## 【2026-09-24 风格重做】旧版 = 平涂棕底 + 几个绿色正圆斑，观感单薄（用户
## 反馈「调整城池内地图风格」）。现在分七层：
##   暖土底色 → 大尺度明暗土斑（有机形）→ 双色草地斑 → 官府前石板广场 →
##   道路（带车辙）→ 建筑地基 → 砖缝城墙。
## 全部形状用固定种子确定性生成，重绘零成本、逐帧一致。

const C_SOIL := Color(0.44, 0.38, 0.28)
const C_SOIL_LIGHT := Color(0.53, 0.47, 0.35, 0.45)
const C_SOIL_DARK := Color(0.36, 0.31, 0.23, 0.40)
const C_PATH := Color(0.58, 0.51, 0.38)
const C_PATH_EDGE := Color(0.43, 0.37, 0.27)
const C_RUT := Color(0.40, 0.34, 0.24, 0.55)
const C_PLAZA := Color(0.56, 0.51, 0.43)
const C_PLAZA_LINE := Color(0.42, 0.38, 0.31, 0.55)
const C_WALL := Color(0.52, 0.46, 0.38)
const C_WALL_TOP := Color(0.60, 0.54, 0.45)
const C_WALL_DARK := Color(0.37, 0.32, 0.26)
const C_GRASS := Color(0.35, 0.45, 0.24, 0.50)
const C_GRASS_DARK := Color(0.28, 0.38, 0.20, 0.45)

const RNG_SEED := 20260922

var ground_size := Vector2(2400, 1500)
## 建筑地基（与 city_scene 的 BUILDING_SPOTS 对应）
var pads: Array = []   # [{rect: Rect2}, ...]
## 城门位置（底部中央）
var gate_pos := Vector2(1200, ground_size.y)


func _draw() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = RNG_SEED

	# 1. 泥土底色
	draw_rect(Rect2(Vector2.ZERO, ground_size), C_SOIL, true)

	# 2. 大尺度明暗土斑（有机形，模拟夯土地面被踩踏/雨水冲刷出的自然色差）
	for i in range(18):
		var p := Vector2(rng.randf_range(0, ground_size.x),
			rng.randf_range(0, ground_size.y))
		var rx := rng.randf_range(160, 380)
		var ry := rx * rng.randf_range(0.55, 0.85)
		_draw_ellipse(p, Vector2(rx, ry), C_SOIL_LIGHT if i % 2 == 0 else C_SOIL_DARK)

	# 3. 草地斑块（有机形 + 双色层次，比旧版正圆柔和）
	for i in range(30):
		var p := Vector2(rng.randf_range(60, ground_size.x - 60),
			rng.randf_range(160, ground_size.y - 60))
		var r := rng.randf_range(46, 130)
		_draw_ellipse(p, Vector2(r, r * rng.randf_range(0.6, 0.9)), C_GRASS)
		_draw_ellipse(p + Vector2(r * 0.35, rng.randf_range(-24, 24)),
			Vector2(r * 0.5, r * 0.4), C_GRASS_DARK)

	# 4. 官府前石板广场（主干道与官府之间的玩家主要活动区；
	#    先画广场再画道路，路面自然压过广场边缘）
	_draw_plaza(Vector2(1200, 860), 210.0)

	# 5. 主干道：城门 → 官府，以及横向环路
	_draw_path(gate_pos + Vector2(0, -40), Vector2(1200, 700), 110.0)
	_draw_path(Vector2(700, 700), Vector2(1700, 700), 90.0)
	_draw_path(Vector2(700, 700), Vector2(520, 1000), 70.0)
	_draw_path(Vector2(1700, 700), Vector2(1880, 1000), 70.0)
	_draw_path(Vector2(700, 700), Vector2(430, 560), 70.0)
	_draw_path(Vector2(1700, 700), Vector2(1970, 560), 70.0)
	_draw_path(Vector2(1200, 700), Vector2(1200, 460), 90.0)

	# 6. 建筑地基
	for pad in pads:
		var rect: Rect2 = pad["rect"]
		draw_rect(rect.grow(14), C_PATH_EDGE, true)
		draw_rect(rect, C_PATH, true)

	# 7. 城墙（顶部一整道，带垛口与砖缝）+ 两侧
	_draw_wall(Rect2(0, 0, ground_size.x, 96))
	_draw_wall(Rect2(0, 0, 64, ground_size.y), true)
	_draw_wall(Rect2(ground_size.x - 64, 0, 64, ground_size.y), true)


## 有机椭圆（16 段多边形近似，比 draw_circle 的正圆更自然）
func _draw_ellipse(center: Vector2, half: Vector2, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in range(16):
		var t := TAU * float(i) / 16.0
		pts.append(center + Vector2(cos(t) * half.x, sin(t) * half.y))
	draw_colored_polygon(pts, col)


## 石板广场：椭圆底 + 同心砖圈 + 放射缝
func _draw_plaza(center: Vector2, r: float) -> void:
	_draw_ellipse(center, Vector2(r, r * 0.8), C_PLAZA)
	var rings := 4
	for i in range(1, rings + 1):
		var rr := r * float(i) / float(rings)
		var pts := PackedVector2Array()
		for j in range(24):
			var t := TAU * float(j) / 24.0
			pts.append(center + Vector2(cos(t) * rr, sin(t) * rr * 0.8))
		draw_polyline(pts, C_PLAZA_LINE, 2.0, true)
	for j in range(8):
		var t2 := TAU * float(j) / 8.0 + 0.2
		draw_line(center,
			center + Vector2(cos(t2) * r, sin(t2) * r * 0.8), C_PLAZA_LINE, 2.0, true)


## 绘制城内道路（开放折线，不要闭合）+ 车辙。
## draw_polyline 的 closed 必须为 false；误设为 true 会从终点连回起点，
## 在城内画出一条横切的幽灵三角线（与大地图河流/道路同一类 bug）。
func _draw_path(from: Vector2, to: Vector2, w: float) -> void:
	var pts := PackedVector2Array([from, (from + to) * 0.5 + Vector2(0, -14), to])
	draw_polyline(pts, C_PATH_EDGE, w + 10.0, false)
	draw_polyline(pts, C_PATH, w, false)
	# 车辙：路两侧各一条平行细线，中间微微拱起
	var dir := (to - from).normalized()
	var n := Vector2(-dir.y, dir.x)
	for s: float in [-1.0, 1.0]:
		var off := n * s * w * 0.18
		var a := from + dir * 30.0 + off
		var b := to - dir * 30.0 + off
		draw_polyline(PackedVector2Array([a, (a + b) * 0.5 + Vector2(0, -8), b]),
			C_RUT, 3.0, false)


func _draw_wall(rect: Rect2, side := false) -> void:
	draw_rect(rect, C_WALL, true)
	# 砖缝（横缝 + 逐行错位的竖缝，确定性生成）
	if not side:
		var row := 0
		var y := rect.position.y + 24.0
		while y < rect.end.y - 8.0:
			draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y),
				C_WALL_DARK, 1.5)
			var x := rect.position.x + (28.0 if row % 2 == 0 else 56.0)
			while x < rect.end.x:
				draw_line(Vector2(x, y - 24.0), Vector2(x, y), C_WALL_DARK, 1.5)
				x += 56.0
			row += 1
			y += 24.0
	else:
		# 侧墙：横缝 + 两列竖缝
		var sy := rect.position.y + 24.0
		while sy < rect.end.y:
			draw_line(Vector2(rect.position.x + 4, sy),
				Vector2(rect.end.x - 4, sy), C_WALL_DARK, 1.5)
			sy += 24.0
		for sx in [rect.position.x + 21.0, rect.end.x - 21.0]:
			draw_line(Vector2(sx, rect.position.y), Vector2(sx, rect.end.y),
				C_WALL_DARK, 1.5)
	# 垛口（顶边锯齿）
	if not side:
		var step := 56.0
		var mx := rect.position.x
		while mx < rect.position.x + rect.size.x:
			draw_rect(Rect2(mx, rect.position.y - 18, step * 0.55, 18), C_WALL_TOP, true)
			mx += step
	else:
		var step2 := 56.0
		var my := rect.position.y
		while my < rect.position.y + rect.size.y:
			draw_rect(Rect2(rect.position.x - 18 if rect.position.x < 100
				else rect.position.x + rect.size.x, my, 18, step2 * 0.55), C_WALL_TOP, true)
			my += step2
	# 内侧阴影线
	draw_rect(Rect2(rect.position + Vector2(0, rect.size.y - 10), Vector2(rect.size.x, 10)),
		C_WALL_DARK, true)
