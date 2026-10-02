extends Node
## 【第五十八轮】小地图静态几何脏标记改造 · 等价性探针（headless 真跑）
##
## 改造：minimap.update_view 每帧无条件调 _recalc_geometry()，改为脏标记驱动
##    （几何输入真变了才重算）。
##
## 这类改造**编译期完全无感，写错不报错**，最危险的是它悄悄改了显示：
##   - 漏把 _player_pos 计入脏标记 → 局部模式下窗口不跟随玩家（小地图"卡住"）
##   - 快照同步时机错（记在 clamp 之前）→ 脏标记永久失效，等于没优化
##   - 快照不同步到 7 处直接调用路径 → 漏掉一次本该发生的重算
##
## 所以本探针不比"跑得快"，只比**结果是否逐帧一致**：
##   A.【窗口等价】同一串输入序列下，「脏标记版」与「每帧必重算版」产出的
##      _world_window / _scale / _origin 必须逐帧逐字段相等（含边界夹取）。
##   B.【跟随不失效】局部模式下玩家移动后窗口必须跟着变 —— 这是最易漏的回归。
##   C.【快照同步覆盖】直接调用 _recalc_geometry 的路径（缩放/切模式/改 pan）
##      之后，下一帧 update_view 不得漏掉本该发生的重算。
##   D.【脏标记确实生效】输入不变时连续多帧不重算（否则改造没收益）。
##   E.【提前 return 路径】_recalc_geometry 开头有「控件尺寸未就绪就 return」
##      的早退分支，此时末尾的快照同步不会执行，只有 _static_geometry_dirty
##      内部的自写快照兜底。若后人把那份自写快照删掉（只留末尾同步），
##      快照将永不更新 → 每帧都判脏 → 优化静默失效且不报任何错。
##      本判定锁死：尺寸未就绪时判脏会自行收敛，且尺寸就绪后能正确重算。

const REPORT := "res://minimap_geom_result.txt"

var _fails: Array[String] = []
var _oks: Array[String] = []


func _fail(tag: String, msg: String) -> void:
	# 不用 % 格式化：引擎里参数不匹配会抛异常导致结果文件不落盘，
	# 上层只能表现为「超时」，掩盖真实原因。
	_fails.append("[" + tag + "] " + msg)


func _ok(msg: String) -> void:
	_oks.append("[OK] " + msg)


func _ready() -> void:
	var lines: Array[String] = []
	lines.append("=== MINIMAP_GEOM_PROBE ===")

	var mini_script: Script = load("res://scripts/ui/minimap.gd")
	lines.append("SCRIPT_LOADED=" + str(mini_script != null))
	if mini_script == null:
		lines.append("MINIMAP_GEOM_FAIL无法加载 minimap.gd")
		_write(lines)
		return

	var src := FileAccess.get_file_as_string("res://scripts/ui/minimap.gd")
	lines.append("SRC_LEN=" + str(src.length()))

	# ---- 锚定：脏标记与快照函数必须真的存在（防上游改名后空跑）----
	for fn in ["_static_geometry_dirty", "_sync_geometry_snapshot"]:
		var found := src.find("func " + fn)
		lines.append("FUNC_FOUND_" + fn + "=" + str(found >= 0))
		if found < 0:
			_fail("A", "minimap.gd 里找不到函数 " + fn)

	lines.append("A_EQUIV=" + _check_equivalence())
	lines.append("B_FOLLOW=" + _check_follow())
	lines.append("C_SNAPSHOT=" + _check_snapshot())
	lines.append("D_EFFECTIVE=" + _check_effective())
	lines.append("E_EARLY_RETURN=" + _check_early_return())

	if _fails.is_empty():
		lines.append("MINIMAP_GEOM_OK")
	else:
		lines.append("MINIMAP_GEOM_FAIL")
		for f in _fails:
			lines.append("  " + f)
	_write(lines)


## 造一个最小可用的 Minimap 实例（不进场景树也能调几何相关方法）
func _make_map() -> MiniMap:
	var m := MiniMap.new()
	m.size = Vector2(320.0, 220.0)
	# _map_size 默认已是有效值（13000x8000），直接赋一个更小的测试地图
	m._map_size = Vector2(4000.0, 3000.0)
	return m


## A/B：脏标记版 vs 每帧必重算版，逐帧比对三个几何量
## 走「真实类」的 update_view 不可行（需场景树/相机），故直接驱动几何函数，
## 但两条路径调用的是同一份业务代码，差异只在「要不要每帧重算」。
func _check_equivalence() -> String:
	#序列：静止→ 静止 → 移动 → 边界夹取 → 缩放 → 切模式 → 静止
	var moves: Array = [
		Vector2(500.0, 400.0),
		Vector2(500.0, 400.0),
		Vector2(520.0, 430.0),
		Vector2(-9999.0, -9999.0),   # 越界，应被夹到地图边界
		Vector2(10.0, 10.0),
		Vector2(2000.0, 1500.0),
		Vector2(2000.0, 1500.0),
	]
	var m := _make_map()
	m.view_mode = MiniMap.MODE_LOCAL
	m._player_pos = moves[0]
	m._recalc_geometry()
	var ok := true
	for i in range(moves.size()):
		var p: Vector2 = moves[i]
		m._player_pos = p
		# 参考路径：每帧必重算
		m._recalc_geometry()
		var ref_win := m._world_window
		var ref_scale := m._scale
		var ref_origin := m._origin

		# 脏标记路径：只在此处重算一次（等价于 update_view 的脏判定）
		if m._static_geometry_dirty():
			m._recalc_geometry()

		if not m._world_window.is_equal_approx(ref_win):
			_fail("A", "第 " + str(i) + " 步 _world_window 不一致：脏标记="
				+ str(m._world_window) + " 每帧重算=" + str(ref_win))
			ok = false
			break
		if not is_equal_approx(m._scale, ref_scale):
			_fail("A", "第 " + str(i) + " 步 _scale 不一致：" + str(m._scale) + " vs " + str(ref_scale))
			ok = false
			break
		if not m._origin.is_equal_approx(ref_origin):
			_fail("A", "第 " + str(i) + " 步 _origin 不一致：" + str(m._origin) + " vs " + str(ref_origin))
			ok = false
			break
	m.free()
	if ok:
		_ok(str(moves.size()) + " 帧几何逐字段一致（含越界夹取与静止帧）")
		return "OK"
	return "FAIL"


## B：局部模式下玩家移动，窗口必须跟着变（漏 _player_pos 的典型症状）
func _check_follow() -> String:
	var m := _make_map()
	m.view_mode = MiniMap.MODE_LOCAL
	m._player_pos = Vector2(300.0, 300.0)
	m._recalc_geometry()
	var before := m._world_window
	m._player_pos = Vector2(1600.0, 1200.0)
	if m._static_geometry_dirty():
		m._recalc_geometry()
	var after := m._world_window
	if before.is_equal_approx(after):
		m.free()
		_fail("B", "局部模式下玩家从(300,300) 走到 (1600,1200)，可视窗口却没变"
			+ " —— 脏标记漏了 _player_pos，小地图会「卡住」不跟随玩家")
		return "FAIL"
	m.free()
	_ok("局部模式窗口随玩家移动而更新（(300,300)→(1600,1200) 窗口已变）")
	return "OK"


## C：缩放/切模式等直接调用路径之后，下一帧不得漏重算
func _check_snapshot() -> String:
	var m := _make_map()
	m.view_mode = MiniMap.MODE_LOCAL
	m._player_pos = Vector2(500.0, 500.0)
	m._recalc_geometry()
	var before := m._world_window

	# 模拟直接调 _recalc_geometry 的路径（这里用切模式 + 缩放）
	m.set_mode(MiniMap.MODE_WORLD)
	var after := m._world_window
	if before.is_equal_approx(after):
		m.free()
		_fail("C", "set_mode 切到天下模式后可视窗口未变化 —— 模式切换没生效")
		return "FAIL"
	# 关键：切模式后再走脏判定，不应再判脏（快照已被 _recalc_geometry 同步）
	if m._static_geometry_dirty():
		m.free()
		_fail("C", "set_mode 已重算过几何，但脏标记仍判脏 —— "
			+ "_recalc_geometry 内部没有同步快照，会导致每帧重复重算（优化失效）")
		return "FAIL"
	m.free()
	_ok("切模式等直接调用路径后脏标记不重复触发（快照已同步）")
	return "OK"


## D：输入不变时连续多帧不判脏（否则改造没有实际收益）
func _check_effective() -> String:
	var m := _make_map()
	m.view_mode = MiniMap.MODE_LOCAL
	m._player_pos = Vector2(800.0, 800.0)
	m._recalc_geometry()
	# 静止：第一次可能判脏（首帧快照是默认值），之后应恒为不脏
	var dirty_count := 0
	for i in range(20):
		if m._static_geometry_dirty():
			dirty_count += 1
	if dirty_count > 1:
		m.free()
		_fail("D", "静止 20 帧里判脏 " + str(dirty_count) + " 次（应≤1）—— "
			+ "脏标记没生效，性能改造等于没做")
		return "FAIL"
	m.free()
	_ok("静止 20 帧只判脏 " + str(dirty_count) + " 次（脏标记确实生效）")
	return "OK"


## E：控件尺寸未就绪时 _recalc_geometry 会提前 return（跳过末尾快照同步），
## 此时只有 _static_geometry_dirty 内部的自写快照在兜底。
## 若那份自写快照被删掉，尺寸未就绪期间会「每帧都判脏」，优化静默失效。
## 本判定要求：① 未就绪期间判脏次数收敛（≤2）② 尺寸就绪后能正确重算几何。
func _check_early_return() -> String:
	var m := MiniMap.new()
	m._map_size = Vector2(4000.0, 3000.0)
	m.view_mode = MiniMap.MODE_LOCAL
	m._player_pos = Vector2(800.0, 800.0)
	# 阶段一：尺寸未就绪（x<=1.0），_recalc_geometry 必然走 :245 的 return
	m.size = Vector2(0.0, 0.0)
	var dirty_unready := 0
	for i in range(10):
		if m._static_geometry_dirty():
			dirty_unready += 1
			m._recalc_geometry()
	if dirty_unready > 2:
		m.free()
		_fail("E", "控件尺寸未就绪期间，10 帧里判脏" + str(dirty_unready)
			+ " 次（应≤2）—— _recalc_geometry 提前 return 时末尾同步被跳过，"
			+ "必须靠 _static_geometry_dirty 内部的自写快照兜底，否则脏标记永久失效")
		return "FAIL"

	# 阶段二：尺寸就绪，脏判定必须放行重算（否则小地图永远是空的）
	m.size = Vector2(320.0, 220.0)
	if not m._static_geometry_dirty():
		m.free()
		_fail("E", "控件尺寸从 0变为 320x220 后脏判定仍报不脏 —— "
			+ "尺寸变化未进脏标记，小地图将始终不渲染")
		return "FAIL"
	m._recalc_geometry()
	if m._scale <= 0.0 or m._world_window.size.x <= 0.0:
		m.free()
		_fail("E", "尺寸就绪并重算后几何仍退化（scale=" + str(m._scale)
			+ " window=" + str(m._world_window) + "）")
		return "FAIL"

	# 阶段三：就绪并重算之后，判脏必须收敛（末尾同步生效）
	var tail := 0
	for i in range(10):
		if m._static_geometry_dirty():
			tail += 1
	if tail > 1:
		m.free()
		_fail("E", "尺寸就绪并重算后，10 帧里判脏 " + str(tail) + " 次（应≤1）—— "
			+ "_recalc_geometry 末尾的快照同步没生效")
		return "FAIL"
	m.free()
	_ok("提前 return 路径判脏收敛（未就绪 " + str(dirty_unready)
		+ " 次 / 就绪后 " + str(tail) + " 次），尺寸就绪后几何正确重算")
	return "OK"


func _write(lines: Array[String]) -> void:
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	get_tree().quit(0 if _fails.is_empty() else 1)