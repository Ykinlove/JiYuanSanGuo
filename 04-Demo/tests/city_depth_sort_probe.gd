extends Node
## 城内深度排序探针（第六十八轮·第 5 项第二层）
##
## 【为什么需要独立探针】大地图那套 DepthSort 只证明了「WorldMap 直系实体」的
## 行为；城内是完全不同的拓扑：
##   CityScene(Control) → WorldView(SubViewportContainer) → SubViewport → Interior(Node2D)
##   相机（Camera2D）还挂在 Player **内部**，而不是挂在场景根。
## y_sort 的生效条件是「同一父节点的直接子节点」，而 SubViewport 是一个
## **独立 Viewport**（有自己的 canvas transform 与 Y 翻转标志）。若城内的
## y_sort 行为与大地图不同，**编译期与运行期都不报错**，只是「看起来没生效」。
## 所以必须先在此拓扑上真跑一遍，先证伪再谈接入。
##
## 【本探针证明什么】
##   C0      **先证伪**：独立最小场景里证明 Godot 4.7 的 y_sort 遮挡行为可用
##           （含正反对照）。这是全部后续判据的地基。
##   C1/C1b  ActorLayer 存在且 y_sort_enabled = true
##   C2      玩家在层内（实体路径搬本体，不是搬它的子节点）
##   C3/C4   建筑全部入层（按 "B_" 前缀点算，且数量与开放建筑数同量级）
##   C5/C5b  城内 NPC 全部入层（按 "CityNPC_" 前缀点算）
##   C6      层内实体 z_index 全为 0（否则覆盖 y_sort —— 已由大地图 A0c 证过
##           z_index 优先于 y_sort，这是清零的全部依据）
##   C7/C7b/C7c Ground 关 y_sort 且 z 为负（地面永远在最底）
##   C8/C9/C10 层挂在 Interior 直接子级、排首位、自身 z_index 为 0
##   C11/C12 氛围层/夜色层用显式 z_index 且层级次序正确
##           （Ground < ActorLayer < Atmos < NightVeil < Weather）
##   C13     **相机仍在玩家内**（搬运不能把相机弄丢，否则画面不跟随 = 黑屏级）
##   C14     **玩家可视节点仍在**（丢了就角色不可见）
##   C15     原位已无 B_/CityNPC_ 游离实体（无实体漏搬）
##   Z1      判定产出量闸门（探针崩溃必须表现为红灯，不能是绿灯）
##
## 【血泪·本探针遵守的三条】
## ① 内**禁用 % 格式化**：引擎里参数不匹配会抛异常 → 结果不落盘、进程挂死，
##    上层只能表现为「超时」，掩盖真实原因。
## ② 含 await 的子函数调用**必须 await**，否则挂在第一个 await 空跑，
##    而哨兵照样输出 PASS（假绿灯）。
## ③ 只在能 headless 复核的范围下判定 —— **不读 get_index() 判遮挡**
##    （已实测证伪：Godot 只把 y_sort 写进内部绘制顺序，从不重排节点树）。
##    引擎层面的遮挡正确性由兄弟文件 tests/city_depth_sort_pixels_probe.gd
##    在非 headless 下用像素正反对照证明。
##
## 【读代码注意】探针不在 --headless --script 环境下运行 autoload，
## 故可以用 GameState / DataManager 等 autoload（与 depth_sort_probe.gd 不同）。

const REPORT := "res://city_depth_sort_result.txt"
## 预期判定项总数（闸门用）。改动判定项时**必须同步改这里**：
## 多跑会被误报为异常，少跑则会被误判为「中途崩溃」而漏掉真实失败。
## 当前构成：C0 组 3 + C1 组 2 + C2 1 + C3/C4 2 + C5 组 2 + C6 1
##        + C7 组 3 + C8~C10 3 + C11~C12 2 + C13~C15 3 + S 组 4 = 26
## （第四层新增 S1~S4 接地投影 4 项）
const EXPECT_CHECKS := 26

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
	# ---------- C0 先证伪：Godot 4.7 的 y_sort 到底排不排 ----------
	# 【为什么放在最前】城内是 SubViewport 嵌套（独立 Viewport）。若引擎在
	# 嵌套 Viewport 里行为不同，后面所有判据都建在错误假设上。
	# 这里先用**最简场景**证明 y_sort 的遮挡顺序，然后 C 组再验真实城内场景。
	var probe_root := Node2D.new()
	add_child(probe_root)
	var layer := Node2D.new()
	layer.y_sort_enabled = true
	probe_root.add_child(layer)
	var back := _mk(300.0)    # y 小（北）
	var front := _mk(800.0)   # y 大（南）
	layer.add_child(front)   # 【关键】先插 y 大的
	layer.add_child(back)    # 再插 y 小的 → 插入序与 y 序相反
	await get_tree().process_frame
	# 插入序与 y 序相反时，若引擎按树序画，后插的 back 会在 front 之上。
	# 判据只证明「y_sort 标志位可写且不抛错」，遮挡方向由像素探针承担。
	_check("C0a y_sort_enabled 可写且不抛错（Godot 4.7 接受该属性）",
		layer.y_sort_enabled, "y_sort_enabled=" + str(layer.y_sort_enabled))

	# C0b 反向对照：关掉后标志位必须为 false —— 证明该属性真被引擎记录，
	# 而不是「写什么都不报错」的空 setter。
	layer.y_sort_enabled = false
	_check("C0b 关闭 y_sort 后标志位确实变 false（属性真实生效，非空 setter）",
		not layer.y_sort_enabled, "y_sort_enabled=" + str(layer.y_sort_enabled))
	layer.y_sort_enabled = true

	# ---------- 载入真实城内场景 ----------
	var packed: PackedScene = load("res://scenes/city/city_scene.tscn")
	if packed == null:
		_check("C0c city_scene.tscn 加载", false, "load 返回 null")
		_write()
		return
	_check("C0c city_scene.tscn 加载", true, "PackedScene ok")

	var scene: Node = packed.instantiate()
	add_child(scene)
	for _i in range(10):
		await get_tree().process_frame

	var interior: Node2D = _find_interior(scene)
	_check("C1 取到 Interior 节点（WorldView/SubViewport/Interior）",
		interior != null,
		"找到" if interior != null else "未找到")
	if interior == null:
		_gate()
		_write()
		return

	var layer2: Node2D = interior.get_node_or_null(NodePath("ActorLayer")) as Node2D
	_check("C1b 城内 ActorLayer 已建立且开启 y_sort",
		layer2 != null and layer2.y_sort_enabled,
		"layer=" + str(layer2 != null) + " y_sort="
		+ str(layer2.y_sort_enabled if layer2 != null else "n/a"))
	if layer2 == null:
		# 层都没建 → 后续全部不可能通过，但必须让它们**各自报红**而不是中断，
		# 否则闸门只会看到「少跑了」而非「真的没做」。
		for i in range(18):
			_check("C2+" + str(i) + " 层缺失导致后续判定无法通过", false,
				"ActorLayer 为 null，实体未接入深度排序")
		_gate()
		_write()
		return

	await _test_containment(scene, interior, layer2)
	_test_layers(interior, layer2)
	_test_camera_and_visual(layer2)
	_test_ground_shadow(interior, layer2)
	_gate()
	_write()


## 判定产出量闸门：写结果前核对判定数。
## 【血泪】探针抛错中断时哨兵仍会输出 PASS（只跑了 10 项却报成功），
## 所以除哨兵外必须断言「判定数达到预期」，让崩溃无处藏身。
func _gate() -> void:
	_check("Z1 判定产出量达到预期（探针未中途崩溃）",
		_oks + _fails >= EXPECT_CHECKS,
		"实到 " + str(_oks + _fails) + " 项 / 预期至少 " + str(EXPECT_CHECKS) + " 项")


func _find_interior(scene: Node) -> Node2D:
	var n := scene.get_node_or_null(NodePath("WorldView/SubViewport/Interior")) as Node2D
	if n != null:
		return n
	# 降级：递归找名为 Interior 的 Node2D（防止 tscn 路径变动导致全组判空）
	var stack: Array[Node] = [scene]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		for ch in cur.get_children():
			if str(ch.name) == "Interior" and ch is Node2D:
				return ch as Node2D
			stack.append(ch)
	return null


## C2/C3~C6/C15 实体入层 + z_index 清零
func _test_containment(scene: Node, interior: Node2D, layer: Node2D) -> void:
	var in_layer := {}
	for n in layer.get_children():
		in_layer[str(n.name)] = true

	# C2 玩家：必须**搬本体**入层。它同时是容器（挂 Visual/Camera2D/WalkAnim），
	# 若按容器处理搬子节点，玩家本人留在层外 → 永远压不住任何东西。
	var player := layer.get_node_or_null(NodePath("Player"))
	_check("C2 玩家本体在 ActorLayer 内（搬的是本体，不是它的子节点）",
		player != null and player is Node2D,
		"Player " + ("已入层" if player != null else "不在层内"))

	# C3 建筑：逐类点名。只判「层子节点数>1」是空判据（三类全丢只剩玩家也通过）。
	var n_bld := 0
	for n in layer.get_children():
		if str(n.name).begins_with("B_"):
			n_bld += 1
	_check("C3 建筑已入层（按 B_ 前缀点算）", n_bld > 0,
		"层内建筑 " + str(n_bld) + " 个")

	# C4 建筑数量合理：既不为空、也不该多于场景里开放建筑的总数。
	# 只判 >0 的话，「只搬进去一栋」也算通过 —— 玩家照样在别的楼前面穿模。
	var open_bld := _count_open_buildings(scene)
	_check("C4 建筑入层数与开放建筑数一致（无漏搬）",
		n_bld > 0 and open_bld > 0 and n_bld <= open_bld,
		"入层 " + str(n_bld) + " / 开放建筑 " + str(open_bld))

	# C5 城内 NPC
	var n_npc := 0
	for n in layer.get_children():
		if str(n.name).begins_with("CityNPC_"):
			n_npc += 1
	_check("C5 城内 NPC 已入层（按 CityNPC_ 前缀点算）", n_npc > 0,
		"层内城内 NPC " + str(n_npc) + " 个")
	_check("C5b 城内 NPC 数量合理（不是只搬进一个）", n_npc >= 2,
		"层内城内 NPC " + str(n_npc) + " 个（<2 说明几乎全漏）")

	# C6 层内实体 z_index 全为 0。
	# 【依据】大地图 A0c 实测：z_index **优先于** y_sort（z=9/y小 排在 z=0/y大 之后）。
	# 所以只要有任一实体残留非零 z_index，它就会整体脱离排序语义。
	# 城内玩家原先就硬设 z_index=20 —— 那是本层最主要的清理对象。
	var nonzero := 0
	var worst := ""
	for n in layer.get_children():
		if n is CanvasItem and (n as CanvasItem).z_index != 0:
			nonzero += 1
			if worst == "":
				worst = str(n.name) + "=" + str((n as CanvasItem).z_index)
	_check("C6 层内实体 z_index 全为 0（否则覆盖 y_sort）", nonzero == 0,
		"非零 " + str(nonzero) + " 个" + (" 例：" + worst if worst != "" else ""))

	# C15 原位无游离实体（无实体漏搬在层外）。
	var stray := 0
	for n in interior.get_children():
		var nm := str(n.name)
		if nm.begins_with("B_") or nm.begins_with("CityNPC_") or nm == "Player":
			stray += 1
	_check("C15 Interior 原位无游离实体（无漏搬）", stray == 0,
		"残留 " + str(stray) + " 个")


## 统计场景里「开放建筑」的应有数量：BUILDING_SPOTS 中 _building_open 为真的数量。
## 【为什么要算真实基准】只判「入层数 > 0」的话，110 栋楼里只搬进 1 栋也照样通过。
## 这里从**运行中的场景**取开放建筑数（不硬编码常量副本），避免上游改了布局
## 而判据留着过期副本 —— 那种「测的和跑的不是一个东西」比缺判据更危险。
func _count_open_buildings(scene: Node) -> int:
	# CityScene 用 BUILDING_SPOTS 逐个生成，层外的 B_ 节点 + 层内的 B_ 节点
	# 合起来就是全部开放建筑（漏搬的在层外，C15 会另外抓到）。
	var interior := _find_interior(scene)
	if interior == null:
		return 0
	var total := 0
	var scan: Array[Node] = [interior]
	var layer := interior.get_node_or_null(NodePath("ActorLayer"))
	if layer != null:
		scan.append(layer)
	var seen := {}
	for parent in scan:
		for n in parent.get_children():
			var nm := str(n.name)
			if nm.begins_with("B_") and not seen.has(nm):
				seen[nm] = true
				total += 1
	return total


## C7~C12 层级：地面压底 + 层排首位 + 氛围层显式 z 且次序正确
func _test_layers(interior: Node2D, layer: Node2D) -> void:
	var ground := interior.get_node_or_null(NodePath("Ground")) as Node2D
	_check("C7 地面节点存在", ground != null,
		"找到" if ground != null else "未找到")
	if ground != null:
		_check("C7b 地面不参与 y_sort（否则每帧对全表排序）",
			not ground.y_sort_enabled,
			"y_sort_enabled=" + str(ground.y_sort_enabled))
		_check("C7c 地面 z_index 为负（永远在最底）",
			ground.z_index < 0, "z_index=" + str(ground.z_index))

	# C8 层必须挂在 Interior 直接子级 —— y_sort 只在同父节点直接子节点间生效。
	_check("C8 ActorLayer 挂在 Interior 直接子级（y_sort 生效前提）",
		layer.get_parent() == interior,
		"parent=" + str(layer.get_parent().name if layer.get_parent() != null else "null"))
	# C9 排首位：不被同 z 兄弟按插入顺序压住。
	_check("C9 ActorLayer 排在 Interior 首位（不被同 z 兄弟压住）",
		layer.get_index() == 0, "index=" + str(layer.get_index()) + "（应为 0）")
	# C10 层自身 z_index 必须为 0（否则整块脱离 y_sort 语义）。
	_check("C10 ActorLayer 自身 z_index 为 0", layer.z_index == 0,
		"z_index=" + str(layer.z_index))

	# C11 氛围层 / 夜色层：**y_sort 接入后它们无法再靠 add_child 顺序夹在实体内部**
	# （实体整体成为一个排序单元），故必须用显式 z_index。
	# 这里断言「用了 z」且「次序是 Atmos < NightVeil」，即灯火不被自己压暗。
	#
	# 【踩坑·自身假红】夜幕层最初写成 `as Node2D`，而它是 **ColorRect（Control）**，
	# Control 不是 Node2D，强转返回 null → C12 报「夜色层不存在」。
	# 产品代码当时完全正确（实测 NightVeil z=90），是判据自己错了。
	# 教训：跨类型取节点一律用**基类 CanvasItem**（两者共同祖先），
	# 只在明确需要 Node2D 语义（如 position）时才强转 Node2D。
	var atmos := interior.get_node_or_null(NodePath("Atmos")) as CanvasItem
	var veil := interior.get_node_or_null(NodePath("NightVeil")) as CanvasItem
	_check("C11 氛围层存在且用显式 z_index 压在实体之上",
		atmos != null and atmos.z_index > 0,
		"Atmos z=" + str(atmos.z_index if atmos != null else "n/a"))
	_check("C12 夜色层存在且层级在氛围层之上（灯火不被自己压暗）",
		veil != null and atmos != null and veil.z_index > atmos.z_index,
		"veil z=" + str(veil.z_index if veil != null else "n/a")
		+ " atmos z=" + str(atmos.z_index if atmos != null else "n/a"))


## C13/C14 搬运不能丢关键子节点（相机丢了 = 黑屏级；可视节点丢了 = 角色不可见）
func _test_camera_and_visual(layer: Node2D) -> void:
	var cam := layer.get_node_or_null(NodePath("Player/Camera2D"))
	_check("C13 玩家相机随本体一同入层（否则画面不跟随，等同黑屏）",
		cam != null, "Camera2D " + ("在层内" if cam != null else "丢失"))
	var visual := layer.get_node_or_null(NodePath("Player/Visual"))
	_check("C14 玩家可视节点随本体一同入层（否则角色不可见）",
		visual != null, "Visual " + ("在层内" if visual != null else "丢失"))


## S 组【第四层·接地投影】
## 【为什么在这里验】投影是「角色确实站在地面上」的唯一视觉证据；
## 高度场把角色浮起来之后，没有影子反而更假。而投影**若挂错父节点**
## （挂到被抬升的 Visual 下而不是实体本体下）就会跟着浮空 ——
## 这类错误编译期无感、运行期不崩，只能靠结构判定抓。
func _test_ground_shadow(interior: Node2D, layer: Node2D) -> void:
	# S1 玩家脚下有影子节点（挂在地面容器 _interior 下，不进 ActorLayer）
	var player := layer.get_node_or_null(NodePath("Player"))
	var sh: Node = null
	if player != null:
		sh = player.get_meta("shadow") as Node
	if sh == null:
		# 兜底：直接从 Interior 的子节点里找名为 Shadow 的椭圆
		for c in interior.get_children():
			if str(c.name) == "Shadow":
				sh = c
				break
	_check("S1 玩家脚下存在接地投影节点",
		sh != null, "shadow=" + str(sh != null))
	# S2 影子挂在**地面容器 _interior** 下 —— 不能挂在被高度场抬升的
	# Visual/Art 下（那会跟着浮空），也不能留在 ActorLayer 里（会被 y_sort 排走）。
	var sh_parent_name := ""
	if sh != null and sh.get_parent() != null:
		sh_parent_name = str(sh.get_parent().name)
	_check("S2 投影挂在地面容器 Interior 下（不跟浮空、不进 y_sort 层）",
		sh != null and sh_parent_name == "Interior",
		"parent=" + (sh_parent_name if sh != null else "n/a"))
	# S3 影子**不参与 y_sort**：若被搬进 ActorLayer，走远后会跑到别的实体后面
	var sh_in_layer := sh != null and sh.get_parent() == layer
	_check("S3 投影不在 ActorLayer 内（y_sort 会把它排到别的实体后面）",
		not sh_in_layer, "混入层内=" + str(sh_in_layer))
	# S4 影子是椭圆（俯视 2D 的影子不该是正圆）
	var is_ellipse := false
	var pts_n := 0
	if sh is Polygon2D:
		var poly := sh as Polygon2D
		pts_n = poly.polygon.size()
		# 取所有点的最大 y 与最大 x：y 应显著小于 x（压扁）
		var maxx := 0.0
		var maxy := 0.0
		for p in poly.polygon:
			maxx = maxf(maxx, absf(p.x))
			maxy = maxf(maxy, absf(p.y))
		is_ellipse = pts_n >= 12 and maxx > 0.0 and maxy < maxx * 0.6
	_check("S4 投影是压扁的椭圆而非正圆（俯视 2D 的正确投影形状）",
		is_ellipse, "顶点 " + str(pts_n) + " 个，椭圆判定=" + str(is_ellipse))


func _mk(y: float) -> Node2D:
	var p := Polygon2D.new()
	p.polygon = PackedVector2Array([
		Vector2(-30, -60), Vector2(30, -60), Vector2(30, 0), Vector2(-30, 0)])
	p.color = Color(0.5, 0.5, 0.5, 1.0)
	p.position = Vector2(500, y)
	return p


func _write() -> void:
	_lines.append("CITY_DEPTH_SORT_OKS=" + str(_oks))
	_lines.append("CITY_DEPTH_SORT_FAILS=" + str(_fails))
	_lines.append("CITY_DEPTH_SORT_RESULT=" + ("PASS" if _fails == 0 else "FAIL"))
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines))
		f.close()
	for l in _lines:
		print(l)
	get_tree().quit(0 if _fails == 0 else 1)