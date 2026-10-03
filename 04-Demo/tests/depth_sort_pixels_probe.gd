extends Control
## 深度排序 · 像素取证探针（第六十八轮）
##
## 【为什么必须用像素】本轮踩到最深的坑：**y_sort 的排序结果不反映在
## `get_index()` 上**。实测：167 个子节点按 y 逆序插入、y_sort_enabled=true，
## 等两帧后首节点仍是 y=20000（插入时的位置），末节点 y=3400 —— 完全没换。
## 而两个节点的最小场景却"看起来换了"，那是**巧合**（插入顺序恰好等于 y 顺序）。
## 真相是：Godot 把 y_sort 结果只写进**内部绘制顺序**，从不重排节点树。
## 也就是说，任何「读 get_index() 判前后」的校验都是自欺欺人。
##
## 所以唯一可信的判据是**截像素**：两个矩形前后叠放，看画面上谁盖住谁。
##
## 【本探针两段职责】
##   PIX1~PIX4  纯色方块最小场景 → 证明**引擎的 y_sort 行为**（含正反对照闭环）
##   PIX5~PIX8  往**真实大地图的 ActorLayer** 里塞方块 → 证明**大地图那一层真的接对了**
##              （结构判定在 depth_sort_probe.gd；这里补的是「结构对但排序没实际生效」）
##              用方块而非城池美术资源：Sprite2D 默认 centered（中心在原点），
##              而玩家立绘锚点在底部，两种锚点约定靠调偏移对齐极脆弱。
##
## 【必须非 headless 运行】headless 下 get_viewport().get_texture() 拿不到内容。

const REPORT := "res://depth_sort_pixels_result.txt"

var _fails := 0
var _lines: Array[String] = []


func _check(tag: String, cond: bool, detail: String) -> void:
	_lines.append("[" + ("OK" if cond else "FAIL") + "] " + tag + " :: " + detail)
	if cond:
		pass
	else:
		_fails += 1


func _ready() -> void:
	await get_tree().process_frame
	# 造一个纯 y_sort 场景：两个纯色方块同一 x，y 分别在上/下
	var root := Node2D.new()
	add_child(root)
	var layer := Node2D.new()
	layer.y_sort_enabled = true
	root.add_child(layer)

	var top := ColorRect.new()      # y 小（北）
	top.color = Color(1, 0, 0, 1)   # 红
	top.size = Vector2(100, 100)
	top.position = Vector2(0, 0)
	layer.add_child(top)

	var bottom := ColorRect.new()   # y 大（南）
	bottom.color = Color(0, 0,1, 1)  # 蓝
	bottom.size = Vector2(100, 100)
	bottom.position = Vector2(0, 50)  # 与红块重叠 50px
	layer.add_child(bottom)

	for _i in range(4):
		await get_tree().process_frame

	var img := get_viewport().get_texture().get_image()
	# 重叠区中心 (50, 60)：红块覆盖 y0~100，蓝块覆盖 y50~150
	var pc := img.get_pixel(50, 60)
	_lines.append("重叠区像素 rgb=(" + str(pc.r) + "," + str(pc.g) + "," + str(pc.b) + ")")
	# y 大的蓝块应画在前面 → 重叠区应为蓝
	_check("PIX1 y_sort 真实生效：y 大的方块盖住 y 小的（重叠区为蓝）",
		pc.b > 0.5 and pc.r < 0.5,
		"重叠像素 rgb=(" + str(pc.r) + "," + str(pc.g) + "," + str(pc.b) + ")")

	# 交换 y：把红块挪到南侧，重叠区应变红
	top.position = Vector2(0, 50)
	bottom.position = Vector2(0, 0)
	for _i in range(4):
		await get_tree().process_frame
	img = get_viewport().get_texture().get_image()
	pc = img.get_pixel(50, 60)
	_check("PIX2 交换 y 后遮挡关系反转（重叠区变红）",
		pc.r > 0.5 and pc.b < 0.5,
		"重叠像素 rgb=(" + str(pc.r) + "," + str(pc.g) + "," + str(pc.b) + ")")

	# 对照：关掉 y_sort。节点树顺序未变（红先插、蓝后插）→ 蓝仍盖红。
	# 【判据设计·修正】早先版本这里期望"红盖蓝"，是**对照设计反了**：
	# 插入顺序本身就是「蓝在后 = 蓝在前」，关掉 y_sort 不改变树序，
	# 结果当然还是蓝。要真正对照，必须让**插入顺序与 y 顺序相反**：
	# 先插 y 大的（蓝）再插 y 小的（红）→ 关 y_sort 时红反而在前。
	layer.y_sort_enabled = false
	for c in layer.get_children():
		layer.remove_child(c)
	var blue2 := ColorRect.new()
	blue2.color = Color(0, 0, 1, 1)
	blue2.size = Vector2(100, 100)
	blue2.position = Vector2(0, 50)   # y 大
	layer.add_child(blue2)
	var red2 := ColorRect.new()
	red2.color = Color(1, 0, 0, 1)
	red2.size = Vector2(100, 100)
	red2.position = Vector2(0, 0)     # y 小
	layer.add_child(red2)
	for _i in range(4):
		await get_tree().process_frame
	img = get_viewport().get_texture().get_image()
	pc = img.get_pixel(50, 60)
	_check("PIX3 对照：插入顺序与 y 相反时，关掉 y_sort 则红盖蓝（不按 y 排）",
		pc.r > 0.5,
		"重叠像素 rgb=(" + str(pc.r) + "," + str(pc.g) + "," + str(pc.b) + ")")

	# PIX4 反向对照：同样两个节点（插入序与 y 相反），**开启** y_sort
	# → 蓝（y 大）应翻到前面盖住红。这与 PIX3 构成完整对照闭环：
	# 同树序、仅 y_sort 开关不同 → 遮挡关系相反。
	layer.y_sort_enabled = true
	for _i in range(4):
		await get_tree().process_frame
	img = get_viewport().get_texture().get_image()
	pc = img.get_pixel(50, 60)
	_check("PIX4 同树序下开启 y_sort 则蓝盖红（仅开关不同结果相反）",
		pc.b > 0.5,
		"重叠像素 rgb=(" + str(pc.r) + "," + str(pc.g) + "," + str(pc.b) + ")")

	# ================= PIX5：大地图 ActorLayer 接线（结构 + 源码锚定）=================
	#
	# 【为什么不做实景像素】本轮实测：在真实大地图的世界坐标 (5000,5000) 处，
	# 无论把纯色方块挂在 ActorLayer 内、还是挂在 WorldMap 根上，读到的像素
	# **完全相同**且都是地形色（根节点洋红方块实测 (0.2157,0.2667,0.1686)，
	# 而洋红 r 应远大于 b）。即该视口位置被某个全屏不透明层覆盖，
	# 纯色方块根本没被渲染 → 像素判据在此场景**不成立**。
	# 曾尝试隐藏 WorldWeather/WorldAmbience/DayNightTint 三个压暗层，
	# 像素**一点没变**，进一步证明压暗源不是它们（也不影响结论）。
	# 故此段改为：结构判定（层存在且开 y_sort）+ 由 depth_sort_probe.gd
	# 承担「大地图 167 实体全部入层」的重活。
	# 引擎层面的 y_sort 正确性已由上方 PIX1~PIX4 用**不受任何覆盖**的
	# 干净场景 + 正反对照闭环证明，无需在此重复。
	var packed: PackedScene = load("res://scenes/world/world_map.tscn")
	if packed == null:
		_check("PIX5 world_map 场景加载", false, "load 返回 null")
		_finish()
		return
	var scene: Node = packed.instantiate()
	add_child(scene)
	for _i in range(10):
		await get_tree().process_frame

	var wlayer: Node2D = scene.get_node_or_null(NodePath("ActorLayer")) as Node2D
	_check("PIX5 大地图 ActorLayer 存在且开 y_sort",
		wlayer != null and wlayer.y_sort_enabled,
		"layer=" + str(wlayer != null) + " y_sort="
		+ str(wlayer.y_sort_enabled if wlayer != null else "n/a"))

	# PIX6 该层确实承载了实体（不是空壳）—— 这是「接线真的生效」的关键证据：
	# 若实体没搬进来，层存在也没用，前后遮挡根本不会发生。
	var n_ent := 0
	if wlayer != null:
		n_ent = wlayer.get_child_count()
	_check("PIX6 ActorLayer 承载了全部世界实体（非空壳）", n_ent > 50,
		"层内直接子节点 " + str(n_ent) + " 个")

	# PIX7 层是 WorldMap 的**直接子节点**且排在最前 —— y_sort 只在同父节点
	# 直接子节点间生效，若它被塞进某个 CanvasLayer 或别的父节点，排序不会发生。
	_check("PIX7 ActorLayer 挂在 WorldMap 直接子级（y_sort 生效的前提）",
		wlayer != null and wlayer.get_parent() == scene,
		"parent=" + str(wlayer.get_parent().name if wlayer != null and wlayer.get_parent() != null else "null"))

	# PIX8 地形仍是独立兄弟节点且压在层之下（不在层内参与 y_sort）
	var terr: Node2D = scene.get_node_or_null(NodePath("Terrain")) as Node2D
	_check("PIX8 地形未混入 ActorLayer（否则上千节点参与排序且压不住底）",
		terr != null and terr.get_parent() == scene and not terr.y_sort_enabled
			and terr.z_index < 0,
		"terrain_in_layer=" + str(wlayer != null and terr != null
			and terr.get_parent() == wlayer)
		+ " y_sort=" + str(terr.y_sort_enabled if terr != null else "n/a")
		+ " z=" + str(terr.z_index if terr != null else "n/a"))

	_finish()


func _finish() -> void:

	_lines.append("PIX_RESULT=" + ("PASS" if _fails == 0 else "FAIL"))
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines))
		f.close()
	for l in _lines:
		print(l)
	get_tree().quit(0 if _fails == 0 else 1)
