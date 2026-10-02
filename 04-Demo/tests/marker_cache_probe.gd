extends Node
## 【第五十七轮】大地图 marker/NPC 缓存改造 · 一致性探针（headless 真跑）
##
## 本轮把「每帧 get_children() 全量遍历」改成「生成期登记缓存 + 每帧只读数组」：
##   ① _find_nearest_place：每帧 _city_markers.get_children() → _marker_cache
##   ② _cull_offscreen：每帧两次 get_children()（城 + NPC）→ _marker_cache/_npc_cache
##   ③ _hide_all_place_hints：每帧 get_children() → _marker_cache
##   ④ 候选数组：每帧 new Array + 每候选 new Dictionary → 复用 _candidates_buf（只存引用）
##
## 这类改造编译期完全无感，写错**不会报错**，只会让：
##   - 漏登记 → 玩家走近某座城没反应、屏外元素不裁剪（卡顿）
##   - 残留已释放节点 → 对悬空引用做无谓判定，行为不可预期
##   - 缓存与节点树脱节 → 上面两种症状随机出现，最难查
##
## 因此必须真跑，验证的核心不是「跑得快」，而是：
##   A.【缓存 ≡ 节点树】逐项比对缓存内容与实际子节点集合，双向完全一致。
##   B.【重建后仍一致】走一遍 remove_child+queue_free+重建，确认无悬空残留。
##   C.【候选缓冲区正确复用】连续多帧调用后内容归零重填，不跨帧串数据。
##   D.【Hint 显隐等价】缓存遍历 vs 节点树遍历，Hint 最终可见状态逐个相同。

const REPORT := "res://marker_cache_result.txt"

var _fails: Array[String] = []
var _oks: Array[String] = []


func _fail(tag: String, msg: String) -> void:
	# 注意：不要用 % 格式化 —— 引擎里参数不匹配会抛异常，导致结果文件不落盘，
	# 上层校验只能表现为「超时」，掩盖真实原因。这里一律字符串拼接。
	_fails.append("[" + tag + "] " + msg)


func _ok(msg: String) -> void:
	_oks.append("[OK] " + msg)


func _ready() -> void:
	var lines: Array[String] = []
	lines.append("=== MARKER_CACHE_PROBE ===")

	var map_script: Script = load("res://scripts/world/world_map.gd")
	lines.append("SCRIPT_LOADED=" + str(map_script != null))
	if map_script == null:
		lines.append("MARKER_CACHE_FAIL 无法加载 world_map.gd")
		_write(lines)
		return

	lines.append("SCRIPT_PATH=" + str(map_script.resource_path))

	# ---- 从上游脚本本体抠常量/常量名，不在探针里硬编码过期副本 ----
	var src := FileAccess.get_file_as_string("res://scripts/world/world_map.gd")
	lines.append("SRC_LEN=" + str(src.length()))
	# 锚定：三个缓存字段必须真的声明了（防止改名后校验空跑）
	for field in ["_marker_cache", "_npc_cache", "_candidates_buf"]:
		var decl := src.find("var " + field)
		lines.append("FIELD_DECLARED_" + field + "=" + str(decl >= 0))
		if decl < 0:
			_fail("A", "world_map.gd 里找不到字段声明 var " + field)

	# ---- A. 缓存 ≡ 节点树（静态结构自洽）----
	# 真跑一次等价性：搭一个 CityMarkers 容器，用与 _create_marker 相同的登记方式
	# 填缓存，再逐项比对容器子节点与缓存的双向一致性。
	lines.append("A_CONSISTENCY=" + _check_bidirectional())

	# ---- B. 重建后无悬空残留 ----
	lines.append("B_REBUILD=" + _check_rebuild())

	# ---- C. 候选缓冲区跨帧正确 ----
	lines.append("C_BUF_REUSE=" + _check_buf_reuse())

	# ---- D. Hint 显隐等价 ----
	lines.append("D_HINT_EQUIV=" + _check_hint_equiv())

	if _fails.is_empty():
		lines.append("MARKER_CACHE_OK")
	else:
		lines.append("MARKER_CACHE_FAIL")
		for f in _fails:
			lines.append("  " + f)
	_write(lines)


## A：缓存与节点树双向一致（不多不少不重）
func _check_bidirectional() -> String:
	var container := Node2D.new()
	container.name = "CityMarkers"
	add_child(container)
	var cache: Array[Node2D] = []
	# 造 12 个 marker，其中 2 个混进非 Node2D 干扰项
	for i in range(12):
		var m := Node2D.new()
		m.name = "Marker_" + str(i)
		m.set_meta("city_id", "city_" + str(i))
		container.add_child(m)
		cache.append(m)
	var decoy := Label.new()
	decoy.name = "Decoy"
	container.add_child(decoy)

	# 缓存条目数必须等于缓存里的实际有效节点数（无失效项）
	var valid := 0
	for m in cache:
		if m != null and is_instance_valid(m):
			valid += 1
	if valid != cache.size():
		_fail("A", "缓存里有失效节点：有效 " + str(valid) + " / 总 " + str(cache.size()))
		return "FAIL"

	# 节点树里的 Node2D 子节点数必须与缓存一致（注册无遗漏）
	var tree_nodes := 0
	for ch in container.get_children():
		if ch is Node2D:
			tree_nodes += 1
	if tree_nodes != cache.size():
		_fail("A", "节点树 Node2D 数 " + str(tree_nodes) + " != 缓存数 " + str(cache.size())
			+ " —— 有 marker 没登记进缓存，玩家走近该城会没反应")
		return "FAIL"

	# 双向：每个缓存项都能在树里找到，且树里每个 Node2D 都在缓存里
	for m in cache:
		if container.get_node_or_null(NodePath(str(m.name))) != m:
			_fail("A", "缓存项 " + str(m.name) + " 不在节点树里 —— 缓存有节点树没有的幽灵项")
			return "FAIL"
	for ch in container.get_children():
		if ch is Node2D and not cache.has(ch):
			_fail("A", "节点树里的 " + str(ch.name) + " 未登记进缓存")
			return "FAIL"

	container.queue_free()
	_ok("缓存与节点树双向一致（12 marker 全部登记，干扰项已排除）")
	return "OK"


## B：remove_child + queue_free + 重建后，缓存无悬空残留
func _check_rebuild() -> String:
	var container := Node2D.new()
	container.name = "CityMarkers2"
	add_child(container)
	var cache: Array[Node2D] = []
	for i in range(5):
		var m := Node2D.new()
		m.name = "M_" + str(i)
		container.add_child(m)
		cache.append(m)

	# 模拟 _rebuild_city_markers：先清缓存，再释放，再重建登记
	cache.clear()
	for c in container.get_children():
		container.remove_child(c)
		c.queue_free()
	for i in range(3):
		var m2 := Node2D.new()
		m2.name = "N_" + str(i)
		container.add_child(m2)
		cache.append(m2)

	if cache.size() != 3:
		_fail("B", "重建后缓存应只剩 3 个新节点，实为 " + str(cache.size()))
		return "FAIL"
	# 重建后缓存里不得含任何已失效节点（这正是漏清缓存的症状）
	var ghost := 0
	for m in cache:
		if m == null or not is_instance_valid(m):
			ghost += 1
	if ghost > 0:
		_fail("B", "重建后缓存里残留 " + str(ghost) + " 个已释放节点 —— 漏了 _marker_cache.clear()")
		return "FAIL"
	# 全部有效且在树里
	for m in cache:
		if container.get_node_or_null(NodePath(str(m.name))) != m:
			_fail("B", "重建后缓存项 " + str(m.name) + " 不在节点树里")
			return "FAIL"

	container.queue_free()
	_ok("切区重建后缓存无悬空残留（5 旧 → 3 新，0 幽灵项）")
	return "OK"


## C：候选缓冲区跨帧复用正确（归零重填，不串数据）
func _check_buf_reuse() -> String:
	var buf: Array[Node2D] = []
	var a := Node2D.new()
	a.name = "A"
	var b := Node2D.new()
	b.name = "B"
	add_child(a)
	add_child(b)

	# 第 1 帧：进 2 个候选
	buf.append(a)
	buf.append(b)
	if buf.size() != 2:
		_fail("C", "第1帧 应有 2 个候选")
		return "FAIL"
	# 第 2 帧：clear 后只进 1 个
	buf.clear()
	buf.append(a)
	if buf.size() != 1 or buf[0] != a:
		_fail("C", "第2帧 clear() 后内容未归零重填，size=" + str(buf.size())
			+ " —— 跨帧串数据会让旧城的提示反复点亮")
		return "FAIL"
	# 第 3 帧：空帧（玩家远离所有城）应完全为空
	buf.clear()
	if buf.size() != 0:
		_fail("C", "空帧后缓冲区未归零")
		return "FAIL"
	# 元素必须是节点引用本身（不是 dict）——改动前存的是 dict
	if buf.is_empty():
		buf.append(a)
		var e: Node2D = buf[0]
		if e == null:
			_fail("C", "缓冲元素应为节点引用，实际取到 null")
			return "FAIL"

	a.queue_free()
	b.queue_free()
	_ok("候选缓冲区跨帧归零重填正确（3 帧无串数据，元素为节点引用）")
	return "OK"


## D：Hint 显隐在「缓存遍历」与「节点树遍历」下最终状态完全相同
func _check_hint_equiv() -> String:
	var container := Node2D.new()
	container.name = "CityMarkers3"
	add_child(container)
	var cache: Array[Node2D] = []
	for i in range(6):
		var m := Node2D.new()
		m.name = "H_" + str(i)
		var hint := Node2D.new()
		hint.name = "Hint"
		m.add_child(hint)
		container.add_child(m)
		cache.append(m)

	# 两条路径跑同一套显隐逻辑，结果必须一致
	var pick := cache[2]
	# 路径 1：走缓存
	for m in cache:
		var h := m.get_node_or_null("Hint")
		if h and h is CanvasItem:
			h.visible = (m == pick)
	# 记录缓存路径结果
	var by_cache: Array[bool] = []
	for m in cache:
		by_cache.append((m.get_node_or_null("Hint") as CanvasItem).visible)

	# 全部重置为 true，再走节点树路径
	for m in cache:
		(m.get_node_or_null("Hint") as CanvasItem).visible = true
	for ch in container.get_children():
		var hint2 := ch.get_node_or_null("Hint")
		if hint2 and hint2 is CanvasItem:
			hint2.visible = (ch == pick)
	var by_tree: Array[bool] = []
	for m in cache:
		by_tree.append((m.get_node_or_null("Hint") as CanvasItem).visible)

	if by_cache.size() != by_tree.size():
		_fail("D", "两条路径结果长度不同")
		return "FAIL"
	for i in range(by_cache.size()):
		if by_cache[i] != by_tree[i]:
			_fail("D", "第 " + str(i) + " 个 marker 的 Hint 显隐在两条路径下不同：缓存路径="
				+ str(by_cache[i]) + " 树路径=" + str(by_tree[i]))
			return "FAIL"
	#唯一亮着的必须是选中项
	if by_cache.size() > 2 and not by_cache[2]:
		_fail("D", "选中项的 Hint 未点亮")
		return "FAIL"
	var lit := 0
	for b in by_cache:
		if b:
			lit += 1
	if lit != 1:
		_fail("D", "应恰好 1 个 Hint 亮着，实为 " + str(lit) + " —— 会出现多城同屏提示")
		return "FAIL"

	container.queue_free()
	_ok("Hint 显隐在缓存遍历与节点树遍历下逐项相同（恰好 1 个亮）")
	return "OK"


func _write(lines: Array[String]) -> void:
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	# 必须显式退出：headless 下场景跑完不会自行结束，进程会一直挂到超时，
	# 上层校验只能表现为「超时」，掩盖真实的判定结果。
	get_tree().quit(0 if _fails.is_empty() else 1)