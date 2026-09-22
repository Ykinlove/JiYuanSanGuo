extends RefCounted
class_name CityMarkerArt
## 地图地点标记美术模块（CityMarkerArt）
## ------------------------------------------------------------------
## 职责：为一类地点生成有辨识度的程序化图形，替代原先「统一方框」的做法。
## 全部用 Polygon2D / Line2D 绘制，不依赖外部贴图；若日后放了贴图，
## 由 `_try_texture()` 自动改用贴图（约定路径 assets/sprites/map/<id>.png）。
##
## 造型约定（一眼可辨）：
##   city    —— 城墙 + 垛口 + 城楼 + 旗（大）
##   village —— 茅屋群 + 篱笆（小）
##   pass    —— 两侧山崖 + 中间隘口
##   ruin    —— 断柱 + 残垣
##   capital —— 更高城楼 + 双旗 + 金色描边
## ------------------------------------------------------------------

## 调色板（二次元国风：偏暖的土黄/青灰 + 金色描边）
const C_WALL := Color(0.76, 0.66, 0.47)
const C_WALL_DARK := Color(0.52, 0.43, 0.29)
const C_ROOF := Color(0.62, 0.28, 0.24)
const C_ROOF_DARK := Color(0.42, 0.18, 0.16)
const C_WOOD := Color(0.58, 0.44, 0.29)
const C_STONE := Color(0.60, 0.60, 0.63)
const C_STONE_DARK := Color(0.40, 0.40, 0.44)
const C_GOLD := Color(0.88, 0.74, 0.40)
const C_FLAG := Color(0.82, 0.30, 0.26)


## 类型图标目录与各类型缩放（新美术批次：AI 手绘城池图标 128×128）
const TYPE_ICON_DIR := "res://assets/sprites/city_icons/"
const TYPE_ICON_SCALE := {
	"city": 0.80,
	"village": 0.66,
	"pass": 0.68,
	"ruin": 0.60,
	"landmark": 0.70,
}
## 图标素材的基准边长（AI 批次类型图标为 128×128）。
## 有了它就能按「目标世界宽度」反算缩放，素材换成 256/512 都不会走样。
const ICON_BASE_PX := 128.0
## 专属贴图（map/<id>.png）相对类型贴图的放大倍数，让名城更醒目
const UNIQUE_BOOST := 1.14


## 构建一个地点的全部图形，挂到 marker 下
## 优先级：专属贴图（map/<id>.png）→ 类型贴图（city_icons/<type>.png）→ 程序化绘制
static func build(marker: Node2D, city: Dictionary) -> void:
	var t := str(city.get("type", "city"))
	var is_capital := bool(city.get("is_capital", false))
	var base_scale := float(TYPE_ICON_SCALE.get(t, 0.8))

	var tex := _try_texture(str(city.get("id", "")))
	var is_unique := tex != null
	if not is_unique:
		tex = _type_texture(t)
	if tex != null:
		# 目标世界宽度：类型基准 × 128px；专属贴图再放大一档
		var target := base_scale * ICON_BASE_PX
		if is_unique:
			target *= UNIQUE_BOOST
		if is_capital:
			target *= 1.18          # 都城整体放大，更醒目
		var sc := target / maxf(1.0, float(tex.get_width()))
		var sp := Sprite2D.new()
		sp.texture = tex
		sp.scale = Vector2(sc, sc)
		marker.add_child(sp)
		_add_shadow(marker, target * 0.30, 0.5)
		return

	match t:
		"city":
			_draw_city(marker, is_capital)
		"village":
			_draw_village(marker)
		"pass":
			_draw_pass(marker)
		"ruin":
			_draw_ruin(marker)
		_:
			_draw_city(marker, false)


## 若放了贴图则优先用贴图（约定：assets/sprites/map/<id>.png|webp|jpg）
static func _try_texture(city_id: String) -> Texture2D:
	if city_id.is_empty():
		return null
	var exts: Array[String] = [".png", ".webp", ".jpg"]
	for ext in exts:
		var path := "res://assets/sprites/map/" + city_id + ext
		if ResourceLoader.exists(path):
			var res := load(path)
			if res is Texture2D:
				return res
	return null


## 类型贴图：assets/sprites/city_icons/<type>.png（AI 美术批次）
static func _type_texture(city_type: String) -> Texture2D:
	var t := city_type if not city_type.is_empty() else "city"
	var path := TYPE_ICON_DIR + t + ".png"
	if ResourceLoader.exists(path):
		var res := load(path)
		if res is Texture2D:
			return res
	return null


static func _add_shadow(p: Node2D, r: float, squash: float) -> void:
	var sh := Polygon2D.new()
	sh.polygon = _ellipse(r, r * squash, 18)
	sh.color = Color(0, 0, 0, 0.20)
	sh.position = Vector2(0, 8)
	p.add_child(sh)
	p.move_child(sh, 0)


static func _ellipse(rx: float, ry: float, seg: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(seg):
		var a := float(i) / float(seg) * TAU
		pts.append(Vector2(cos(a) * rx, sin(a) * ry))
	return pts


static func _poly(parent: Node2D, pts: Array, color: Color) -> Polygon2D:
	var p := Polygon2D.new()
	p.polygon = PackedVector2Array(pts)
	p.color = color
	parent.add_child(p)
	return p


static func _line(parent: Node2D, pts: Array, color: Color, w: float) -> Line2D:
	var l := Line2D.new()
	var pv := PackedVector2Array()
	for v in pts:
		pv.append(v)
	l.points = pv
	l.width = w
	l.default_color = color
	l.joint_mode = Line2D.LINE_JOINT_ROUND
	parent.add_child(l)
	return l


# ------------------------------------------------------------------
# 城池：城墙 + 垛口 + 城楼 + 旗
# ------------------------------------------------------------------

static func _draw_city(marker: Node2D, is_capital: bool) -> void:
	var w := 62.0 if is_capital else 50.0
	var h := 30.0 if is_capital else 25.0

	_add_shadow(marker, w * 0.62, 0.38)

	# 城墙主体
	_poly(marker, [
		Vector2(-w, 10), Vector2(w, 10), Vector2(w, 10 - h),
		Vector2(-w, 10 - h)
	], C_WALL)

	# 垛口（城头锯齿）
	var merlon := 4 if is_capital else 3
	var step := (w * 2) / float(merlon * 2 - 1)
	var top := 10 - h
	var pts: Array = []
	for i in range(merlon):
		var x0 := -w + i * step * 2
		pts.append(Vector2(x0, top))
		pts.append(Vector2(x0, top - 8))
		pts.append(Vector2(x0 + step, top - 8))
		pts.append(Vector2(x0 + step, top))
	_poly(marker, pts, C_WALL)

	# 城门
	_poly(marker, [
		Vector2(-9, 10), Vector2(9, 10), Vector2(9, -6), Vector2(-9, -6)
	], C_WALL_DARK)

	# 城楼（中央）
	var tw := 15.0 if is_capital else 12.0
	var th := 16.0 if is_capital else 12.0
	_poly(marker, [
		Vector2(-tw, top - 8), Vector2(tw, top - 8),
		Vector2(tw, top - 8 - th), Vector2(-tw, top - 8 - th)
	], C_WOOD)

	# 屋檐
	_poly(marker, [
		Vector2(-tw - 7, top - 8 - th),
		Vector2(tw + 7, top - 8 - th),
		Vector2(tw + 2, top - 8 - th - 9),
		Vector2(-tw - 2, top - 8 - th - 9)
	], C_ROOF)

	# 旗帜
	var fx := tw + 4
	var fy := top - 8 - th - 16
	_line(marker, [Vector2(fx, fy), Vector2(fx, fy + 20)], C_WOOD, 2.0)
	_poly(marker, [
		Vector2(fx, fy), Vector2(fx + 15, fy + 5), Vector2(fx, fy + 11)
	], C_FLAG)

	# 都城：加一圈金边 + 第二面旗
	if is_capital:
		_line(marker, [
			Vector2(-w, 10), Vector2(w, 10), Vector2(w, top),
			Vector2(-w, top), Vector2(-w, 10)
		], C_GOLD, 2.0)
		var fx2 := -tw - 4
		_line(marker, [Vector2(fx2, fy), Vector2(fx2, fy + 20)], C_WOOD, 2.0)
		_poly(marker, [
			Vector2(fx2, fy), Vector2(fx2 - 15, fy + 5), Vector2(fx2, fy + 11)
		], C_FLAG)
	else:
		_line(marker, [
			Vector2(-w, 10), Vector2(w, 10), Vector2(w, top),
			Vector2(-w, top), Vector2(-w, 10)
		], C_WALL_DARK, 1.6)


# ------------------------------------------------------------------
# 村落：茅屋群 + 篱笆
# ------------------------------------------------------------------

static func _draw_village(marker: Node2D) -> void:
	_add_shadow(marker, 40.0, 0.36)

	# 三间茅屋，中间大两侧小
	_hut(marker, Vector2(0, 6), 20.0, 15.0)
	_hut(marker, Vector2(-24, 12), 13.0, 10.0)
	_hut(marker, Vector2(24, 12), 13.0, 10.0)

	# 篱笆
	_line(marker, [
		Vector2(-42, 18), Vector2(42, 18)
	], C_WOOD.darkened(0.25), 1.6)


static func _hut(parent: Node2D, pos: Vector2, hw: float, hh: float) -> void:
	var n := Node2D.new()
	n.position = pos
	parent.add_child(n)
	# 屋身
	_poly(n, [
		Vector2(-hw, 0), Vector2(hw, 0), Vector2(hw, -hh), Vector2(-hw, -hh)
	], Color(0.72, 0.64, 0.48))
	# 茅顶
	_poly(n, [
		Vector2(-hw - 5, -hh), Vector2(hw + 5, -hh),
		Vector2(hw * 0.35, -hh - 12), Vector2(-hw * 0.35, -hh - 12)
	], Color(0.60, 0.48, 0.28))
	# 门
	_poly(n, [
		Vector2(-3.5, 0), Vector2(3.5, 0), Vector2(3.5, -6), Vector2(-3.5, -6)
	], Color(0.34, 0.26, 0.18))


# ------------------------------------------------------------------
# 关隘：两侧山崖 + 中间隘口
# ------------------------------------------------------------------

static func _draw_pass(marker: Node2D) -> void:
	_add_shadow(marker, 44.0, 0.30)

	# 左崖
	_poly(marker, [
		Vector2(-44, 16), Vector2(-10, 16),
		Vector2(-16, -26), Vector2(-30, -34), Vector2(-44, -20)
	], C_STONE)
	# 右崖
	_poly(marker, [
		Vector2(10, 16), Vector2(44, 16),
		Vector2(44, -20), Vector2(30, -34), Vector2(16, -26)
	], C_STONE)
	# 崖顶积雪/高光
	_poly(marker, [
		Vector2(-30, -34), Vector2(-16, -26), Vector2(-24, -22)
	], Color(0.92, 0.94, 0.97, 0.8))
	_poly(marker, [
		Vector2(30, -34), Vector2(16, -26), Vector2(24, -22)
	], Color(0.92, 0.94, 0.97, 0.8))

	# 隘口门架
	var posts := [Vector2(-10, 16), Vector2(-10, -14)]
	_line(marker, posts, C_WOOD, 4.0)
	_line(marker, [Vector2(10, 16), Vector2(10, -14)], C_WOOD, 4.0)
	_line(marker, [Vector2(-13, -14), Vector2(13, -14)], C_WOOD, 4.0)
	_line(marker, [Vector2(-44, 16), Vector2(44, 16)], C_STONE_DARK, 1.6)

	# 栅栏横木
	_line(marker, [Vector2(-10, -2), Vector2(10, -2)], C_WOOD.darkened(0.2), 2.0)


# ------------------------------------------------------------------
# 遗迹：断柱 + 残垣
# ------------------------------------------------------------------

static func _draw_ruin(marker: Node2D) -> void:
	_add_shadow(marker, 38.0, 0.32)

	# 残破基座
	_poly(marker, [
		Vector2(-36, 14), Vector2(36, 14), Vector2(30, 4), Vector2(-30, 4)
	], Color(0.50, 0.47, 0.45))
	_line(marker, [
		Vector2(-36, 14), Vector2(36, 14), Vector2(30, 4),
		Vector2(-30, 4), Vector2(-36, 14)
	], Color(0.30, 0.28, 0.28), 1.6)

	# 断柱（高低不一，显得残破）
	_pillar(marker, Vector2(-22, 4), 9.0, 34.0)
	_pillar(marker, Vector2(-4, 4), 9.0, 20.0)
	_pillar(marker, Vector2(14, 4), 9.0, 42.0)

	# 坍塌的石块
	_poly(marker, [Vector2(24, 14), Vector2(36, 14), Vector2(32, 8)], Color(0.46, 0.44, 0.42))


static func _pillar(parent: Node2D, base: Vector2, hw: float, h: float) -> void:
	_poly(parent, [
		base + Vector2(-hw, 0), base + Vector2(hw, 0),
		base + Vector2(hw * 0.85, -h), base + Vector2(-hw * 0.85, -h)
	], Color(0.66, 0.63, 0.60))
	# 柱头
	_poly(parent, [
		base + Vector2(-hw - 2, -h), base + Vector2(hw + 2, -h),
		base + Vector2(hw + 2, -h - 4), base + Vector2(-hw - 2, -h - 4)
	], Color(0.58, 0.55, 0.52))
