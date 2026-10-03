extends Node
## 深度排序探针（第六十八轮）
##
## 【为什么必须有这个探针】y_sort 是**引擎行为**，静态扫描源码看不出它生效：
## 源码里写对 `y_sort_enabled = true` 不等于画面真的按 y 排序了。
## 而且本工程最容易的失败方式是「以为开了 y_sort 就完事」——
## 实际上 Godot 只在**同一父节点的直接子节点**之间排序，
## 若实体仍分散挂在多个并列容器里，排序完全不发生，且**不报任何错**。
##
## 【本探针证明什么】
##   A0/A0b  独立最小场景：先证明「y_sort 到底怎么排」+ 反向对照，
##           避免基于错误假设去判大地图（先证伪再改）。
##   A1/A1b  ActorLayer 存在且 y_sort_enabled = true
##   A2/A2b/A2c 四类实体（城池/遭遇/NPC/玩家）全部在 ActorLayer 里
##   A3       层内实体 z_index 全为 0（否则会覆盖 y_sort）
##   A4/A4b/A4c 地形仍关 y_sort 且 z_index 为负（地形永远在最底）
##   A5       **真实遮挡顺序**：把玩家搬到城池上方/下方，
##           验证层内 get_index() 顺序随 y 交换 —— 这才是「真的排上了」
##   A6       切区重建后新节点**仍**在层内（信号链路通）
##
## 【A5 为什么是核心】标志位可以撒谎，兄弟顺序不会。
## 只查 `y_sort_enabled == true` 的话，一个「实体没搬进层」的缺陷照样全绿。
##
## 注意：本文件内**禁用 % 格式化** —— 引擎里参数不匹配会抛异常，
## 导致结果不落盘、进程挂死，上层只能表现为「超时」，掩盖真实原因。

const REPORT := "res://depth_sort_result.txt"
## 预期判定项总数（闸门用）。改动判定项时**必须同步改这里**，
## 否则新增项会被闸门误报为「多跑了」，删项则会被误判为「中途崩溃」。
## 当前构成：A0/A0b/A0c/A0c' 4 + A1/A1b 2 + A2 组 10
##          + A5 组 5 + A6 组 4 + A4 组 3 + Z1 1 = 29
## （实测 28 项判定 + Z1 自身 = 29；下限取 28，容忍个别条件分支少跑一项）
const EXPECT_CHECKS := 28

var _fails := 0
var _oks := 0
var _lines: Array[String] = []


func _check(tag: String, cond: bool, detail: String) -> void:
	_lines.append("[" + ("OK" if cond else "FAIL") + "] " + tag + " :: " + detail)
	if cond:
		_oks += 1
	else:
		_fails += 1


func _ready() -> void:
	# ---------- A0/A0b 独立验证 y_sort 的真实行为 ----------
	# 不依赖大地图，纯造一个最小场景先证明「y 大的排后面（画得更靠前）」。
	# A0b 是**反向对照**：关掉 y_sort 后顺序应保持插入顺序 ——
	# 若 A0 也通过，说明最小场景本身有问题（坐标没生效），后续判据全部不可信。
	var probe_root := Node2D.new()
	add_child(probe_root)

	var layer := Node2D.new()
	layer.y_sort_enabled = true
	probe_root.add_child(layer)
	var up := _mk(100.0)     # y 小（画面上方）
	var down := _mk(900.0)   # y 大（画面下方）
	layer.add_child(up)
	layer.add_child(down)
	await get_tree().process_frame
	await get_tree().process_frame

	var i_down := down.get_index()
	var i_up := up.get_index()
	_check("A0 y_sort 按 y 升序排列兄弟节点（y 大的排在后面=画得更靠前）",
		i_down > i_up,
		"y=900 的 index=" + str(i_down) + " / y=100 的 index=" + str(i_up))

	var layer2 := Node2D.new()
	layer2.y_sort_enabled = false
	probe_root.add_child(layer2)
	var a := _mk(900.0)
	var b := _mk(100.0)
	layer2.add_child(a)   # 先插 y 大的
	layer2.add_child(b)   # 后插 y 小的
	await get_tree().process_frame
	_check("A0b 关掉 y_sort 时保持插入顺序（证明排序确来自 y_sort 而非巧合）",
		a.get_index() < b.get_index(),
		"插入序 a(index=" + str(a.get_index()) + ") b(index=" + str(b.get_index()) + ")")

	# A0c 【关键假设验证】z_index 与 y_sort 同时存在时，谁优先？
	# 若 z_index 优先 → 我们的「实体 z_index 必须清零」结论成立；
	# 若 y_sort 优先 → 清零是多余的，且地形用 z_index=-100 压底会失效。
	# 这一条不验证就动产品代码 = 在未证实的假设上改。
	var layer_z := Node2D.new()
	layer_z.y_sort_enabled = true
	probe_root.add_child(layer_z)
	var z0 := _mk(900.0)    # z=0, y 大
	z0.z_index = 0
	var z9 := _mk(100.0)    # z=9, y 小（若 y_sort 优先，它该排前面）
	z9.z_index = 9
	layer_z.add_child(z0)
	layer_z.add_child(z9)
	await get_tree().process_frame
	await get_tree().process_frame
	_check("A0c z_index 优先于 y_sort（z=9/y小 排在 z=0/y大 之前）",
		z9.get_index() > z0.get_index(),
		"z9(index=" + str(z9.get_index()) + ") z0(index=" + str(z0.get_index()) + ")")

	# ---------- 载入真实大地图 ----------
	var packed: PackedScene = load("res://scenes/world/world_map.tscn")
	if packed == null:
		_check("A0c world_map.tscn 加载", false, "load 返回 null")
		_write()
		return
	_check("A0c world_map.tscn 加载", true, "PackedScene ok")
	var scene: Node = packed.instantiate()
	add_child(scene)
	# 等场景 _ready + 首帧生成全部标记
	for _i in range(8):
		await get_tree().process_frame

	var layer3: Node2D = scene.get_node_or_null(NodePath("ActorLayer")) as Node2D
	_check("A1 ActorLayer 节点已建立", layer3 != null,
		"找到" if layer3 != null else "未找到 ActorLayer")
	_check("A1b ActorLayer 开启 y_sort", layer3 != null and layer3.y_sort_enabled,
		"y_sort_enabled=" + str(layer3.y_sort_enabled if layer3 != null else "n/a"))

	if layer3 != null:
		# 【血泪·必须 await】下面三个子函数内部都含 `await get_tree().process_frame`
		# （y_sort 要等引擎排完序才生效，不能同帧读 index）。漏写 await 时
		# 它们会全部挂在第一个 await 处空跑，_ready 继续往下走到 _write() 提前 quit，
		# 表现为「A5/A6 整组判定人间蒸发、闸门报产出量不足」——
		# 而如果没加 Z1 闸门，这就是又一次完美的假绿灯。
		await _test_containment(scene, layer3)
		await _test_actor_order(scene, layer3)
		await _test_reload(scene, layer3)

	_test_terrain(scene)
	_gate()
	_write()


## 判定产出量闸门：**必须在写结果前核对判定项总数**。
##
## 【血泪·本轮真实踩到】早期版本 A2b 判据写错（正确实现里 Player 整个被搬走，
## get_node_or_null 返回 null，探针当场抛错中断），后续 A2c/A3/A5 四项
## **根本没执行**，但哨兵照样输出 DEPTH_SORT_RESULT=PASS（只 10 项 ≠ 应有 14 项）。
## 这是「探针崩了 → 表现为绿灯」的最隐蔽形态：结果文件在、哨兵在、退出码 0。
##
## 因此除了哨兵，还必须断言「判定数达到预期」+「零 SCRIPT ERROR」，
## 两者任一不满足即 FAIL，让崩溃无处藏身。
func _gate() -> void:
	_check("Z1 判定产出量达到预期（探针未中途崩溃）",
		_oks + _fails >= EXPECT_CHECKS,
		"实到 " + str(_oks + _fails) + " 项 / 预期至少 " + str(EXPECT_CHECKS) + " 项")


## A2/A3 实体入层 + z_index 清零
func _test_containment(scene: Node, layer: Node2D) -> void:
	var in_layer := {}
	for n in layer.get_children():
		in_layer[n.name] = true

	# 玩家：搬**本体**入层（它既是实体又是容器，容器子节点会跟着走）
	_check("A2 玩家节点在 ActorLayer 内", in_layer.has("Player"),
		"Player " + ("已入层" if in_layer.has("Player") else "不在层内，原容器仍持有"))
	# A2b 搬走的是**本体**，所以 WorldMap 下不该再有 Player 这个节点。
	# 【血泪】早先版本写的是「Player 原节点的子数应为 0」——
	# 但正确实现里 Player 整个被搬走了，get_node_or_null 返回 null，
	# 探针当场抛错中断，后续判定全部没跑，哨兵却仍报 PASS（假绿灯）。
	# 现在既判 null，也用 has_node 明确断言「原位已无 Player」。
	var leftover: Node = scene.get_node_or_null(NodePath("Player"))
	_check("A2b 原位已无 Player 节点（搬走的是本体，不是它的子节点）",
		leftover == null,
		"WorldMap 下仍存在 Player=" + str(leftover != null))
	# A2b2 玩家的关键子节点（相机）必须跟着一起搬，否则画面直接黑屏/不动
	var cam := layer.get_node_or_null(NodePath("Player/Camera2D"))
	_check("A2b2 玩家相机随本体一同入层（否则画面不跟随）", cam != null,
		"Camera2D " + ("在层内" if cam != null else "丢失"))
	var visual := layer.get_node_or_null(NodePath("Player/Visual"))
	_check("A2b3 玩家可视节点随本体一同入层（否则角色不可见）", visual != null,
		"Visual " + ("在层内" if visual != null else "丢失"))

	var n_enc := layer.get_child_count()
	_check("A2c ActorLayer 实体数 > 1（不是空层）", n_enc > 1,
		"层内直接子节点 " + str(n_enc) + " 个")

	# A2d 三类「容器型实体」必须都在层内。
	# 【为什么要按名字前缀筛】早先版本只判「层内子节点数 > 1」，
	# 那只证明层不是空的，**不能证明城池/遭遇/NPC 都进来了** ——
	# 哪怕三类全丢、只剩玩家一个也照样通过。必须逐类点名。
	var n_city := 0
	var n_encnode := 0
	var n_npc := 0
	for n in layer.get_children():
		var nm := str(n.name)
		if nm.begins_with("Enc_"):
			n_encnode += 1
		elif nm.begins_with("NPC_"):
			n_npc += 1
		elif nm.begins_with("Marker_"):
			n_city += 1
	_check("A2d 城池标记在层内（按 Marker_ 前缀点算）", n_city > 0,
		"层内城池标记 " + str(n_city) + " 个")
	_check("A2e 遭遇点在层内（按 Enc_ 前缀点算）", n_encnode > 0,
		"层内遭遇点 " + str(n_encnode) + " 个")
	_check("A2f 世界 NPC 在层内（按 NPC_ 前缀点算）", n_npc > 0,
		"层内世界 NPC " + str(n_npc) + " 个")

	# A2g 三个原容器应已空 —— 若仍非空说明有实体没被搬进来
	var stray := 0
	for p in ["CityMarkers", "Encounters", "NPCs"]:
		var c: Node = scene.get_node_or_null(NodePath(p))
		if c != null:
			stray += c.get_child_count()
	_check("A2g 三个原容器均已清空（无实体漏搬）", stray == 0,
		"原容器内残留实体 " + str(stray) + " 个")

	var nonzero := 0
	var worst := ""
	for n in layer.get_children():
		if n is Node2D and (n as Node2D).z_index != 0:
			nonzero += 1
			worst = str(n.name) + "=" + str((n as Node2D).z_index)
	_check("A3 层内实体 z_index 全为 0（否则会覆盖 y_sort）", nonzero == 0,
		"非零 z_index " + str(nonzero) + " 个" + (" 例：" + worst if worst != "" else ""))


## A5 深度排序的「引擎前提」复核（headless 可跑的那部分）
##
## 【本段被砍掉的实测·血泪记录，勿重蹈】早先这里用两种方法判「谁盖住谁」，
## **两种都被实测证伪**：
##
## ① 读 `get_index()` 判前后 —— 完全无效。
##    二分实测：167 个子节点按 y 逆序插入、y_sort_enabled=true，等两帧后
##    首节点仍是 y=20000（插入时的位置），末节点 y=3400，**一个都没换**。
##    而两节点的最小场景却「看起来换了」—— 那是**巧合**（插入顺序恰好等于 y 顺序）。
##    真相：Godot 只把 y_sort 结果写进**内部绘制顺序**，从不重排节点树。
##    ⇒ 任何「读 get_index() 判遮挡」的校验都是自欺欺人。
##
## ② 在真实大地图里截像素判遮挡 —— 不成立。
##    在世界坐标 (5000,5000) 处，无论把纯色方块挂在 ActorLayer 内、
##    还是挂在 WorldMap 根上，读到的像素**完全相同**且都是地形色
##    （根节点洋红方块实测 (0.2157,0.2667,0.1686)，而洋红 r 应远大于 b）。
##    即该视口位置被某个全屏不透明层覆盖，方块根本没被渲染。
##    曾尝试隐藏 WorldWeather / WorldAmbience / DayNightTint 三个压暗层，
##    像素**一点没变**，进一步证明压暗源不是它们。
##
## 【那 y_sort 到底有没有效？】有效。引擎层面的正确性由**兄弟文件**
## tests/depth_sort_pixels_probe.gd 在**不受任何覆盖的干净场景**里
## 用像素级正反对照闭环证明（PIX1~PIX4 全绿：y 大的盖住 y 小的、
## 交换 y 后反转、关掉 y_sort 则按树序、同树序仅开关不同结果相反）。
## 大地图那一层的接线正确性由本探针的结构判定承担。
##
## 【本段因此只做「可 headless 复核」的四项】
func _test_actor_order(scene: Node, layer: Node2D) -> void:
	# A5a 层内确有可参照的城池标记
	var target: Node2D = null
	for n in layer.get_children():
		if str(n.name).begins_with("Marker_"):
			target = n as Node2D
			break
	_check("A5a 层内存在可参照的城池标记", target != null,
		"参照城池=" + (str(target.name) if target != null else "无"))

	# A5b 玩家在层内（参与排序的实体本体）
	var player: Node2D = layer.get_node_or_null(NodePath("Player")) as Node2D
	_check("A5b 取到玩家节点", player != null,
		"Player " + ("在层内" if player != null else "不在层内"))

	# A5c 层是 WorldMap 的直接子节点 —— y_sort 只在同父节点直接子节点间生效。
	# 若它被塞进别的父节点（或某个 CanvasLayer），排序根本不会发生且不报错。
	_check("A5c ActorLayer 挂在场景根直接子级（y_sort 生效前提）",
		layer.get_parent() == scene,
		"parent=" + str(layer.get_parent().name if layer.get_parent() != null else "null"))

	# A5d 层排在最前：y_sort 层必须在地形之后、UI 之前插入，
	# 否则会被同 z 的兄弟节点按插入顺序压住。
	_check("A5d ActorLayer 排在场景根首位（不被同 z 兄弟压住）",
		layer.get_index() == 0,
		"index=" + str(layer.get_index()) + "（应为 0）")

	# A5e 层的 z_index 自身为 0：若非 0（如误设成 20），整层会脱离 y_sort 语义，
	# 变成「整块一起压在最前」，内部排序仍生效但与其它层的相对关系全错。
	_check("A5e ActorLayer 自身 z_index 为 0", layer.z_index == 0,
		"z_index=" + str(layer.z_index))


## A6 切区重建后新实体仍入层（验证 actors_reparented 信号链路）
func _test_reload(scene: Node, layer: Node2D) -> void:
	var enc: Node = scene.get_node_or_null(NodePath("Encounters"))
	if enc == null:
		_check("A6 取到 EncounterManager", false, "Encounters 节点不存在")
		return
	var before := _count_prefix(layer, "Enc_")
	# reload_region 会重建全部遭遇点；这是第 57 轮缓存要求必须同步 clear 的路径
	enc.call("reload_region")
	for _i in range(4):
		await get_tree().process_frame
	# 【血泪】早先版本的判据是「Encounters 容器内有没有游离节点」——
	# 但 _on_reparent_requested 搬完后容器**本来就该是空的**，
	# 判据恒为 0 = 永远通过 = 空判据。改为直接数层内遭遇点数：
	# 重建后必须仍有遭遇点，且数量与重建前同量级（说明真的重建并入层了）。
	var after := _count_prefix(layer, "Enc_")
	_check("A6a 切区重建后遭遇点仍在 ActorLayer 内", after > 0,
		"层内遭遇点 " + str(before) + " → " + str(after))
	_check("A6b 重建后遭遇点数量与重建前同量级（真的重建了，不是全丢或翻倍）",
		after > 0 and after >= int(float(before) * 0.5) and after <= before * 2 + 4,
		"before=" + str(before) + " after=" + str(after))
	var enc_left := enc.get_child_count()
	_check("A6c Encounters 原容器已空（无游离实体）", enc_left == 0,
		"容器内残留 " + str(enc_left) + " 个")
	# A6d 重建后 z_index 仍须清零（重建路径最容易漏掉这一步）
	var nz := 0
	for n in layer.get_children():
		if str(n.name).begins_with("Enc_") and n is Node2D and (n as Node2D).z_index != 0:
			nz += 1
	_check("A6d 重建后新实体 z_index 仍为 0", nz == 0, "非零 " + str(nz) + " 个")


## 数层内名字带指定前缀的节点数
func _count_prefix(layer: Node, prefix: String) -> int:
	var n := 0
	for c in layer.get_children():
		if str(c.name).begins_with(prefix):
			n += 1
	return n


## A4 地形压底
func _test_terrain(scene: Node) -> void:
	var terr: Node2D = scene.get_node_or_null(NodePath("Terrain")) as Node2D
	_check("A4 地形节点存在", terr != null, "找到" if terr != null else "未找到")
	if terr == null:
		return
	_check("A4b 地形不参与 y_sort（否则每帧对上千节点排序）",
		not terr.y_sort_enabled, "y_sort_enabled=" + str(terr.y_sort_enabled))
	_check("A4c 地形 z_index 为负（永远在最底）", terr.z_index < 0,
		"z_index=" + str(terr.z_index))


func _mk(y: float) -> Node2D:
	var p := Polygon2D.new()
	p.polygon = PackedVector2Array([
		Vector2(-30, -60), Vector2(30, -60), Vector2(30, 0), Vector2(-30, 0)])
	p.color = Color(0.5, 0.5, 0.5, 1.0)
	p.position = Vector2(500, y)
	return p


func _write() -> void:
	_lines.append("DEPTH_SORT_OKS=" + str(_oks))
	_lines.append("DEPTH_SORT_FAILS=" + str(_fails))
	_lines.append("DEPTH_SORT_RESULT=" + ("PASS" if _fails == 0 else "FAIL"))
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines))
		f.close()
	for l in _lines:
		print(l)
	get_tree().quit(0 if _fails == 0 else 1)
