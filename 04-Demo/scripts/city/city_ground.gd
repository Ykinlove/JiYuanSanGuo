extends Node2D
class_name CityGround
## 城内地面绘制器
## 职责：画出城内场景的地表 —— 城墙与城门、主干道、建筑地基、草地点缀。
## 与 TerrainPainter 同思路：程序化绘制，检测到贴图则优先贴图（暂未接）。

const C_SOIL := Color(0.42, 0.36, 0.27)
const C_PATH := Color(0.55, 0.48, 0.36)
const C_PATH_EDGE := Color(0.42, 0.36, 0.26)
const C_WALL := Color(0.50, 0.44, 0.36)
const C_WALL_TOP := Color(0.58, 0.52, 0.43)
const C_WALL_DARK := Color(0.36, 0.31, 0.25)
const C_GRASS := Color(0.34, 0.44, 0.24, 0.55)

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

	# 2. 草地斑块（随机自然分布）
	for i in range(46):
		var p := Vector2(rng.randf_range(60, ground_size.x - 60),
			rng.randf_range(160, ground_size.y - 60))
		var r := rng.randf_range(40, 120)
		draw_circle(p, r, C_GRASS)
		draw_circle(p + Vector2(r * 0.4, rng.randf_range(-30, 30)), r * 0.55, C_GRASS)

	# 3. 主干道：城门 → 官府，以及横向环路
	_draw_path(gate_pos + Vector2(0, -40), Vector2(1200, 700), 110.0)
	_draw_path(Vector2(700, 700), Vector2(1700, 700), 90.0)
	_draw_path(Vector2(700, 700), Vector2(520, 1000), 70.0)
	_draw_path(Vector2(1700, 700), Vector2(1880, 1000), 70.0)
	_draw_path(Vector2(700, 700), Vector2(430, 560), 70.0)
	_draw_path(Vector2(1700, 700), Vector2(1970, 560), 70.0)
	_draw_path(Vector2(1200, 700), Vector2(1200, 460), 90.0)

	# 4. 建筑地基
	for pad in pads:
		var rect: Rect2 = pad["rect"]
		draw_rect(rect.grow(14), C_PATH_EDGE, true)
		draw_rect(rect, C_PATH, true)

	# 5. 城墙（顶部一整道，带垛口）+ 两侧
	_draw_wall(Rect2(0, 0, ground_size.x, 96))
	_draw_wall(Rect2(0, 0, 64, ground_size.y), true)
	_draw_wall(Rect2(ground_size.x - 64, 0, 64, ground_size.y), true)


func _draw_path(from: Vector2, to: Vector2, w: float) -> void:
	var pts := PackedVector2Array([from, (from + to) * 0.5 + Vector2(0, -14), to])
	draw_polyline(pts, C_PATH_EDGE, w + 10.0, true)
	draw_polyline(pts, C_PATH, w, true)


func _draw_wall(rect: Rect2, side := false) -> void:
	draw_rect(rect, C_WALL, true)
	# 垛口（顶边锯齿）
	if not side:
		var step := 56.0
		var x := rect.position.x
		while x < rect.position.x + rect.size.x:
			draw_rect(Rect2(x, rect.position.y - 18, step * 0.55, 18), C_WALL_TOP, true)
			x += step
	else:
		var step2 := 56.0
		var y := rect.position.y
		while y < rect.position.y + rect.size.y:
			draw_rect(Rect2(rect.position.x - 18 if rect.position.x < 100
				else rect.position.x + rect.size.x, y, 18, step2 * 0.55), C_WALL_TOP, true)
			y += step2
	# 内侧阴影线
	draw_rect(Rect2(rect.position + Vector2(0, rect.size.y - 10), Vector2(rect.size.x, 10)),
		C_WALL_DARK, true)
