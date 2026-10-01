extends Node2D
class_name WorldCaravans
## 大地图商队层（三十二轮 2026-10-01，零新资源：程序化小队伍）
##
## 沿 terrain.json 的官道折线往返的行进商队——近景看得见小人迈腿、货车
## 颠簸，远景是官道上蠕动的小黑点队列（「活的大地图」拼图最后一块）。
##
## 【数据】DataManager.get_table("terrain") 中 id=="china" 行的 roads
## （与 minimap / terrain_painter 官道同源，保证商队走在画出来的路上）。
## 【性能红锁】常驻上限 CARAVAN_MAX=3，每队 4 个绘制单元，全部一次 _draw
## 批量矢量绘制（无节点、无粒子）；离屏 grow(400) 只跳绘制不跳推进。
## 【行为】沿折线插值推进（SPEED=26 世界像素/秒），到端点进城歇脚
## （REST 2.5~5s，消失于城边）再折返——与跑商系统一样「城对城」。

const CARAVAN_MAX := 3
const SPEED := 30.0
const REST_MIN := 2.5
const REST_MAX := 5.0
const MIN_ROAD_LEN := 2200.0   ## 太短的官道不派队（两步到头没有「在路上」感）
const CULL_GROW := 400.0       ## 视口外扩余量（绘制裁剪）
const PARTY_GAP := 34.0        ## 队列间距（世界像素）

## 队伍配色（暗褐布衣 + 深木货车，远看是低调的小点）
const COL_BODY := Color(0.34, 0.27, 0.19)
const COL_HEAD := Color(0.42, 0.33, 0.24)
const COL_CART := Color(0.45, 0.33, 0.20)
const COL_GOODS := Color(0.62, 0.50, 0.30)
const COL_SHADOW := Color(0.0, 0.0, 0.0, 0.16)

var _caravans: Array[Dictionary] = []
var _cam: Camera2D = null


func setup(camera: Camera2D) -> void:
	_cam = camera


func _ready() -> void:
	z_index = 0
	_spawn_from_data()
	if _caravans.is_empty():
		set_process(false)


## 从 terrain.json 挑长官道派驻商队；数据缺失/过短则整层静默退场
func _spawn_from_data() -> void:
	var roads: Array = []
	for row in DataManager.get_table("terrain"):
		if str(row.get("id", "")) == "china":
			roads = row.get("roads", [])
			break
	if roads.is_empty():
		return
	# 打乱后取前 N 条合格长路（每轮种子不同，路线分布随存档变化）
	var idxs: Array[int] = []
	for i in range(roads.size()):
		idxs.append(i)
	idxs.shuffle()
	for i in idxs:
		if _caravans.size() >= CARAVAN_MAX:
			break
		var pts := _to_polyline(roads[i].get("points", []))
		if _polyline_len(pts) >= MIN_ROAD_LEN:
			_caravans.append(_make_caravan(pts))
			if _caravans.size() >= CARAVAN_MAX:
				break


## 探针/测试用：手工派一队
func spawn_manual(points: PackedVector2Array) -> void:
	_caravans.append(_make_caravan(points))
	set_process(true)


func _make_caravan(pts: PackedVector2Array) -> Dictionary:
	var lens: Array[float] = []
	var total := 0.0
	for i in range(pts.size() - 1):
		var d := pts[i].distance_to(pts[i + 1])
		lens.append(d)
		total += d
	return {
		"pts": pts,
		"lens": lens,
		"total": total,
		"dist": randf_range(total * 0.2, total * 0.8),
		"dir": 1 if randf() < 0.5 else -1,
		"rest": 0.0,
		"phase": randf() * TAU,
	}


## [[x,y],...] → PackedVector2Array
func _to_polyline(raw: Array) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for p in raw:
		if p is Array and p.size() >= 2:
			pts.append(Vector2(float(p[0]), float(p[1])))
	return pts


func _polyline_len(pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(pts.size() - 1):
		total += pts[i].distance_to(pts[i + 1])
	return total


## 折线弧长 → 世界坐标 + 段方向角（atan2）
func _sample(cv: Dictionary, s: float) -> Dictionary:
	var pts: PackedVector2Array = cv["pts"]
	var lens: Array = cv["lens"]
	var acc := 0.0
	for i in range(lens.size()):
		var d: float = lens[i]
		if s <= acc + d or i == lens.size() - 1:
			var t := clampf((s - acc) / maxf(d, 0.001), 0.0, 1.0)
			var a := pts[i]
			var b := pts[i + 1]
			return {"pos": a.lerp(b, t), "angle": (b - a).angle()}
		acc += d
	return {"pos": pts[pts.size() - 1], "angle": 0.0}


func _process(delta: float) -> void:
	for cv in _caravans:
		if float(cv["rest"]) > 0.0:
			cv["rest"] = float(cv["rest"]) - delta
			continue
		cv["dist"] = float(cv["dist"]) + SPEED * float(cv["dir"]) * delta
		var total := float(cv["total"])
		if cv["dist"] >= total:
			cv["dist"] = total
			cv["dir"] = -1
			cv["rest"] = randf_range(REST_MIN, REST_MAX)
		elif cv["dist"] <= 0.0:
			cv["dist"] = 0.0
			cv["dir"] = 1
			cv["rest"] = randf_range(REST_MIN, REST_MAX)
		cv["phase"] = float(cv["phase"]) + delta * 7.0
	queue_redraw()


func _draw() -> void:
	var view := Rect2()
	if _cam != null and is_instance_valid(_cam):
		var half := get_viewport_rect().size * 0.5 / maxf(_cam.zoom.x, 0.001)
		view = Rect2(_cam.get_screen_center_position() - half, half * 2.0)
	for cv in _caravans:
		_draw_party(cv, view)


## 一支商队：货车居中，前后各一名行商（队列沿行进方向拉开间距）
func _draw_party(cv: Dictionary, view: Rect2) -> void:
	var ang: float = _sample(cv, float(cv["dist"]))["angle"]
	var fwd := Vector2.from_angle(ang)
	# 成员弧长位：前人 +gap*dir、货车 0、后人 -gap*dir（dir 决定谁是"头"）
	var offsets := [PARTY_GAP * float(cv["dir"]), 0.0, -PARTY_GAP * float(cv["dir"])]
	for k in range(offsets.size()):
		var s := clampf(float(cv["dist"]) + offsets[k], 0.0, float(cv["total"]))
		var info := _sample(cv, s)
		var pos: Vector2 = info["pos"]
		var a: float = info["angle"]
		if view.size.x > 0.001 and not view.grow(CULL_GROW).has_point(pos):
			continue
		if k == 1:
			_draw_cart(pos, a, float(cv["phase"]))
		else:
			_draw_walker(pos, a, float(cv["phase"]) + (PI if k == 0 else 0.0))


## 行商小人：影子/双腿/身/头（世界尺度 ~18px 高，近景可见迈步）
func _draw_walker(pos: Vector2, _ang: float, phase: float) -> void:
	var swing := sin(phase) * 6.3
	draw_circle(pos + Vector2(0, 1.8), 5.2, COL_SHADOW)
	draw_line(pos + Vector2(-swing * 0.4, -9.0), pos + Vector2(swing, 0.0), COL_BODY, 3.2)
	draw_line(pos + Vector2(swing * 0.4, -9.0), pos + Vector2(-swing, 0.0), COL_BODY, 3.2)
	draw_line(pos + Vector2(0, -19.5), pos + Vector2(0, -7.5), COL_BODY, 4.4)
	draw_circle(pos + Vector2(0, -22.5), 4.5, COL_HEAD)
	# 扁担/行囊：肩上一横杆 + 端头小包
	draw_line(pos + Vector2(-8.2, -17.2), pos + Vector2(8.2, -16.5), COL_CART, 2.2)
	draw_circle(pos + Vector2(-8.7, -15.6), 3.6, COL_GOODS)


## 货车：车斗矩形（随路向旋转）+ 两轮 + 货包 + 影子
func _draw_cart(pos: Vector2, ang: float, phase: float) -> void:
	var bump := sin(phase * 0.5) * 1.2   ## 颠簸
	draw_circle(pos + Vector2(0, 2.4), 8.0, COL_SHADOW)
	draw_set_transform(pos + Vector2(0, bump), ang, Vector2.ONE)
	draw_rect(Rect2(-10.5, -18.0, 21.0, 12.0), COL_CART)
	draw_rect(Rect2(-6.8, -22.5, 13.5, 5.4), COL_GOODS)
	draw_circle(Vector2(-6.6, -4.8), 3.3, COL_BODY)
	draw_circle(Vector2(6.6, -4.8), 3.3, COL_BODY)
	draw_line(Vector2(10.5, -7.5), Vector2(16.5, -3.8), COL_BODY, 2.6)  # 辕杆
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
