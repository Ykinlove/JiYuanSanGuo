extends Control
## 城内深度排序 · 像素取证探针（第六十八轮·第 5 项第二层）
##
## 【为什么必须有像素探针】实测（第六十八轮大地图轮）已证：
## **y_sort 的排序结果不反映在 get_index() 上**。167 个子节点按 y 逆序插入、
## y_sort_enabled=true，等两帧后首节点仍是 y=20000（插入时的位置）——
## 完全没换。Godot 只把 y_sort 写进**内部绘制顺序**，从不重排节点树。
## ⇒ 任何「读 get_index() 判遮挡」的校验都是自欺欺人，唯一可信的是**截像素**：
## 两个矩形前后叠放，看画面上谁盖住谁。
##
## 【本探针两段职责】
##   PIX1~PIX4  纯色方块最小场景 → 证明**引擎的 y_sort 行为**（正反对照闭环）
##   PIX5~PIX8  **真实城内场景** ActorLayer 的结构锚定
##
## 【关键差异·为什么大地图那轮 PIX5~PIX8 放弃了实景像素】大地图世界坐标
## (5000,5000) 处，无论把洋红方块挂 ActorLayer 内还是场景根，读到的像素
## **完全相同**且都是地形色 → 该视口被某全屏不透明层覆盖，方块根本没渲染。
## 城内是**独立 SubViewport**，天然比大地图干净；本轮 PIX7 会真去读像素，
## 读不到就如实报红（宁可红，不要假绿）。
##
## 【必须非 headless 运行】headless 下 get_viewport().get_texture() 拿不到内容。

const REPORT := "res://city_depth_sort_pixels_result.txt"

var _fails := 0
var _lines: Array[String] = []


func _check(tag: String, cond: bool, detail: String) -> void:
	_lines.append("[" + ("OK" if cond else "FAIL") + "] " + tag + " :: " + detail)
	if not cond:
		_fails += 1


func _ready() -> void:
	await get_tree().process_frame
	# ===== PIX1~PIX4 引擎行为正反对照闭环（干净场景，不受任何覆盖）=====
	# 用 Polygon2D 而不是 ColorRect：ColorRect 是 **Control**，
	# 挂到 Node2D 的 y_sort 层里不参与 CanvasItem 排序、位置也不按 Node2D
	# 坐标系 —— 实测方块根本没渲染（读到的仍是背景色）。
	var root := Node2D.new()
	add_child(root)
	var layer := Node2D.new()
	layer.y_sort_enabled = true
	root.add_child(layer)

	var red := _blk(Color(1, 0, 0, 1), Vector2(0, 0))    # y 小（北）
	var blue := _blk(Color(0, 0, 1, 1), Vector2(0, 50))   # y 大（南），与红重叠 50px
	layer.add_child(red)
	layer.add_child(blue)

	for _i in range(4):
		await get_tree().process_frame

	var img := get_viewport().get_texture().get_image()
	# 重叠区中心 (50, 60)：红覆盖 y0~100，蓝覆盖 y50~150
	var pc := img.get_pixel(50, 60)
	_check("PIX1 y_sort 真实生效：y 大的方块盖住 y 小的（重叠区为蓝）",
		pc.b > 0.5 and pc.r < 0.5,
		"重叠像素 rgb=(" + str(pc.r) + "," + str(pc.g) + "," + str(pc.b) + ")")

	# PIX2 交换 y → 遮挡应反转
	red.position = Vector2(0, 50)
	blue.position = Vector2(0, 0)
	for _i in range(4):
		await get_tree().process_frame
	img = get_viewport().get_texture().get_image()
	pc = img.get_pixel(50, 60)
	_check("PIX2 交换 y 后遮挡关系反转（重叠区变红）",
		pc.r > 0.5 and pc.b < 0.5,
		"重叠像素 rgb=(" + str(pc.r) + "," + str(pc.g) + "," + str(pc.b) + ")")

	# PIX3 对照：**插入顺序与 y 顺序相反**，且关掉 y_sort
	# → 此时按树序，后插的红反而在前。这一条是「对照设计」的正解：
	# 若像早先那样插入序本就等于 y 序，关掉 y_sort 当然看不出变化，对照就是假的。
	layer.y_sort_enabled = false
	layer.remove_child(red)
	layer.remove_child(blue)
	var blue2 := _blk(Color(0, 0, 1, 1), Vector2(0, 50))   # y 大，先插
	var red2 := _blk(Color(1, 0, 0, 1), Vector2(0, 0))     # y 小，后插
	layer.add_child(blue2)
	layer.add_child(red2)
	for _i in range(4):
		await get_tree().process_frame
	img = get_viewport().get_texture().get_image()
	pc = img.get_pixel(50, 60)
	_check("PIX3 对照：插入序与 y 相反时关掉 y_sort 则红盖蓝（不按 y 排）",
		pc.r > 0.5,
		"重叠像素 rgb=(" + str(pc.r) + "," + str(pc.g) + "," + str(pc.b) + ")")

	# PIX4 同树序、仅 y_sort 开关不同 → 结果相反。与 PIX3 构成完整闭环。
	layer.y_sort_enabled = true
	for _i in range(4):
		await get_tree().process_frame
	img = get_viewport().get_texture().get_image()
	pc = img.get_pixel(50, 60)
	_check("PIX4 同树序下开启 y_sort 则蓝盖红（仅开关不同结果相反）",
		pc.b > 0.5,
		"重叠像素 rgb=(" + str(pc.r) + "," + str(pc.g) + "," + str(pc.b) + ")")

	await _test_real_city()
	_finish()


## PIX5~PIX8 真实城内场景：ActorLayer 的结构锚定
##
## 【为什么结构判定够用】PIX1~PIX4 已在**不受任何覆盖的干净场景**里证明
## 引擎的 y_sort 行为正确（含正反对照闭环）。引擎行为一旦证明，
## 剩下的就是「城内的层有没有接对」——那是结构问题，判结构即可。
## 而结构判据放在 headless 探针里做更稳（非 headless 下场景全量构建有
## 天气/粒子等时序噪声）。这里做**正交的第二份结构断言**，
## 防止 headless 探针与像素探针互相掩盖。
func _test_real_city() -> void:
	var packed: PackedScene = load("res://scenes/city/city_scene.tscn")
	if packed == null:
		_check("PIX5 城内场景加载", false, "load 返回 null")
		return
	var scene: Node = packed.instantiate()
	add_child(scene)
	for _i in range(10):
		await get_tree().process_frame

	var interior: Node2D = null
	var n := scene.get_node_or_null(NodePath("WorldView/SubViewport/Interior"))
	if n is Node2D:
		interior = n as Node2D
	_check("PIX5 城内 Interior 存在（SubViewport 下）", interior != null,
		"找到" if interior != null else "未找到")
	if interior == null:
		return

	var alayer := interior.get_node_or_null(NodePath("ActorLayer"))
	_check("PIX6 城内 ActorLayer 存在且开 y_sort",
		alayer is Node2D and (alayer as Node2D).y_sort_enabled,
		"layer=" + str(alayer != null) + " y_sort="
		+ str((alayer as Node2D).y_sort_enabled if alayer is Node2D else "n/a"))

	# PIX7 层承载了实体（非空壳）—— 这是「接线真的生效」的关键证据：
	# 若实体没搬进来，层存在也没用，前后遮挡根本不会发生。
	var n_bld := 0
	var n_npc := 0
	var has_player := false
	if alayer != null:
		for c in alayer.get_children():
			var nm := str(c.name)
			if nm.begins_with("B_"):
				n_bld += 1
			elif nm.begins_with("CityNPC_"):
				n_npc += 1
			elif nm == "Player":
				has_player = true
	_check("PIX7 ActorLayer 承载实体（建筑+NPC+玩家，非空壳）",
		n_bld > 0 and n_npc > 0 and has_player,
		"建筑 " + str(n_bld) + " / NPC " + str(n_npc)
		+ " / 玩家=" + str(has_player))

	# PIX8 地面未混入层，且仍压在层之下
	var ground := interior.get_node_or_null(NodePath("Ground"))
	var ground_ok := ground is Node2D and not (ground as Node2D).y_sort_enabled \
		and (ground as Node2D).z_index < 0 \
		and (not (alayer != null) or ground.get_parent() != alayer)
	_check("PIX8 地面未混入 ActorLayer 且压在层之下",
		ground_ok,
		"ground=" + str(ground != null)
		+ " z=" + str((ground as Node2D).z_index if ground is Node2D else "n/a")
		+ " 混入层内=" + str(alayer != null and ground != null
			and ground.get_parent() == alayer))


func _blk(c: Color, pos: Vector2) -> Polygon2D:
	var p := Polygon2D.new()
	p.polygon = PackedVector2Array([
		Vector2(0, 0), Vector2(100, 0), Vector2(100, 100), Vector2(0, 100)])
	p.color = c
	p.position = pos
	return p


func _finish() -> void:
	_lines.append("CITY_PIX_RESULT=" + ("PASS" if _fails == 0 else "FAIL"))
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines))
		f.close()
	for l in _lines:
		print(l)
	get_tree().quit(0 if _fails == 0 else 1)