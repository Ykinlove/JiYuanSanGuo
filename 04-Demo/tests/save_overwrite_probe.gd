extends Node
## 【第六十一轮·探针】存档覆盖防误触：不可逆操作必须二次确认
##
## 真实缺口（取证自 scripts/main/save_menu.gd）：
##   - 删除槽位 → `_show_del_confirm()` 有二次确认；
##   - 保存模式点**已存在**的槽位 → 旧版直接 `SaveManager.save_game(slot)` 一点即过。
## 两者代价等价（都不可逆地丢掉一整局进度），却一个拦一个放行 —— 同屏两个按钮
## 行为不对称，是真实的防误触缺口，不是理论风险。
##
## 修复：`_mode == "save"` 且 `exists == true` 时先走 `_show_overwrite_confirm()`，
##确认才写盘；空槽保持直达（不凭空给新档加一步）。
##
## 判定：
##   A 空槽保存 → 直达写盘，**不得**弹覆盖确认（不凭空加步骤）
##   B 已有档保存 → 必须先弹确认，且此刻**不得写盘**（拦截生效）
##   C 取消确认 → 弹窗关闭、pending 复位、**不得写盘**
##   D 确认覆盖 → 写盘生效、弹窗关闭、列表刷新
##   E 旧档信息同源 → 弹窗文案取入参快照，不重查 SaveManager（防同屏两个版本）
##   F 读档模式点已存在档 → 同样直达 load，不弹覆盖确认（读是不可逆的反面，不拦）
##   G 幂等 → 弹窗已开时重复调用不再叠第二层（否则一次点击叠两个遮罩）
##   H 遮罩/关闭回调 → 只关窗不写盘
##   I 槽位信息完整性自检 → 快照字段确实来自 get_save_slots 真实摘要
##
## 【测试副作用管控】本探针真实读写 user://saves/。为不碰玩家存档：
##   - 只使用 3 号槽（当前为空槽；0 号为自动档、1 号有真实存档）；
##   - 开跑前快照 _meta.json 与 3 号槽原内容，收尾时逐一还原。

const REPORT := "res://save_overwrite_result.txt"

const PROBE_SLOT := 3          ## 专供探针的空闲手动槽
const PROBE_OLD_NAME := "旧将·甲"

var _fails: Array[String] = []
var _detail: Array[String] = []
var _meta_backup := ""         ## _meta.json 原文本（空串 = 原本不存在）
var _metabak_backup := ""     ## _meta.json.bak 原文本（原子写的副产品，漏还原会留探针槽位记录）
var _slot_backup := ""         ## 3 号槽原文本（空串 = 原本不存在）


func _fail(tag: String, msg: String) -> void:
	_fails.append("[" + tag + "] " + msg)


func _okd(msg: String) -> void:
	_detail.append("OK " + msg)


func _ready() -> void:
	var lines: Array[String] = []
	lines.append("=== SAVE_OVERWRITE_PROBE ===")

	var src := FileAccess.get_file_as_string("res://scripts/main/save_menu.gd")
	lines.append("SRC_LEN=" + str(src.length()))
	lines.append("FUNC_FOUND_show_ovr=" + str(src.find("func _show_overwrite_confirm") >= 0))
	lines.append("FUNC_FOUND_close_ovr=" + str(src.find("func _close_overwrite_confirm") >= 0))

	_backup_state()

	# 【铁律·一】含 await 的判定调用处必须写 await，否则 Parse Error → 场景空跑挂死。
	# 【铁律·二】判定函数统一返回 String（"true"/"false"），bool 与 String 不能用 + 拼接。
	lines.append("A_EMPTY_DIRECT=" + await _check_empty_slot())
	lines.append("B_EXIST_BLOCKED=" + await _check_existing_blocked())
	lines.append("C_CANCEL_NOWRITE=" + await _check_cancel())
	lines.append("D_CONFIRM_WRITES=" + await _check_confirm())
	lines.append("E_SNAPSHOT_SOURCE=" + await _check_snapshot_source())
	lines.append("F_LOAD_MODE_DIRECT=" + await _check_load_mode())
	lines.append("G_NO_DOUBLE_MODAL=" + await _check_no_double())
	lines.append("H_CLOSE_NOWRITE=" + await _check_close_callback())

	_restore_state()

	lines.append_array(_detail)
	if _fails.is_empty():
		lines.append("SAVE_OVERWRITE_OK")
	else:
		lines.append("SAVE_OVERWRITE_FAIL")
		for f in _fails:
			lines.append("  " + f)
	_write(lines)


# ==================== 工具 ====================

func _slot_path() -> String:
	return "user://saves/slot_%d.json" % PROBE_SLOT


func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


func _sha(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "<none>"
	return FileAccess.get_sha256(path)


func _file_exists(path: String) -> bool:
	return FileAccess.file_exists(path)


## 写入一个内容可辨识的「旧档」，用于判定「有没有被覆盖写」
func _write_fake_old_save() -> void:
	var payload := {
		"saved_at": "公元184年 1月 存档",
		"saved_at_unix": 1000000,
		"manual": true,
		"game": {
			"player_name": PROBE_OLD_NAME,
			"player_level": 7,
			"year": 184,
			"month": 3,
		},
	}
	var f := FileAccess.open(_slot_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "\t"))
		f.close()


## 造一个 SaveMenu 实例。mode 必须在 add_child **之前**写 pending_mode，
## 因为 _ready() 进来第一件事就是把 pending_mode 取走并复位。
func _make_menu(mode: String) -> SaveMenu:
	SaveMenu.pending_mode = mode
	SaveMenu.pending_return = "main_menu"
	var packed := load("res://scenes/main/save_menu.tscn") as PackedScene
	var m := packed.instantiate() as SaveMenu
	add_child(m)
	return m


## 递归找出指定文案的 Button（弹窗按钮埋在 ColorRect→Center→Panel→VBox→HBox 里）
func _find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node as Button
	for child in node.get_children():
		var hit := _find_button(child, text)
		if hit != null:
			return hit
	return null


## 收集弹窗内所有 Label 文案拼接（用于校验旧档信息是否同源）
func _collect_labels(node: Node, out: Array[String]) -> void:
	if node is Label:
		out.append((node as Label).text)
	for child in node.get_children():
		_collect_labels(child, out)


func _menu_await_ready(m: SaveMenu) -> void:
	await get_tree().process_frame
	await get_tree().process_frame


# ==================== 判定 ====================

## A 空槽保存：直达写盘，不得凭空弹确认
func _check_empty_slot() -> String:
	if _file_exists(_slot_path()):
		_fail("A", "3 号槽开局就非空（exists=" + str(_file_exists(_slot_path()))
			+ "），探针前提被破坏 —— 不能测「空槽直达」")
		return "false"
	var m := _make_menu("save")
	await _menu_await_ready(m)
	m._on_slot_pressed(PROBE_SLOT, false, {"slot": PROBE_SLOT, "exists": false})
	await get_tree().process_frame
	var wrote := _file_exists(_slot_path())
	var modal := m._ovr_confirm != null
	m.queue_free()
	await get_tree().process_frame
	if modal:
		_fail("A", "空槽保存竟弹出了覆盖确认 —— 新档不可逆性为零，凭空多一步确认")
		return "false"
	if not wrote:
		_fail("A", "空槽保存后 3 号槽仍不存在 —— 直达路径断了，玩家点空槽没反应")
		return "false"
	_okd("A 空槽保存 → 直达写盘，未弹确认")
	return "true"


## B 已有档保存：必须先弹确认，且此刻不得写盘
func _check_existing_blocked() -> String:
	_write_fake_old_save()
	var before := _sha(_slot_path())
	var m := _make_menu("save")
	await _menu_await_ready(m)
	var info := _find_slot_info(m, PROBE_SLOT)
	m._on_slot_pressed(PROBE_SLOT, true, info)
	await get_tree().process_frame
	var modal := m._ovr_confirm != null
	var after := _sha(_slot_path())
	var pending_ok := m._pending_ovr_slot == PROBE_SLOT
	m.queue_free()
	await get_tree().process_frame
	if not modal:
		_fail("B", "点已存在的槽位没有弹覆盖确认 —— 这正是本轮要修的缺口（"
			+ "与同屏「删除」的二次确认不对称）")
		return "false"
	if not pending_ok:
		_fail("B", "弹窗已开但 _pending_ovr_slot=" + str(m._pending_ovr_slot)
			+ " ≠ " + str(PROBE_SLOT) + " —— 确认后会写错槽位")
		return "false"
	if after != before:
		_fail("B", "确认弹窗刚弹出旧档就已被改写（sha " + str(before) + " → "
			+ str(after) + "）—— 拦截形同虚设")
		return "false"
	_okd("B 已有档保存 → 弹确认，拦截期间旧档零改动")
	return "true"


## C 取消确认：不得写盘
func _check_cancel() -> String:
	var before := _sha(_slot_path())
	var m := _make_menu("save")
	await _menu_await_ready(m)
	var info := _find_slot_info(m, PROBE_SLOT)
	m._on_slot_pressed(PROBE_SLOT, true, info)
	await get_tree().process_frame
	var cancel := _find_button(m._ovr_confirm, "再想想")
	if cancel == null:
		m.queue_free()
		_fail("C", "覆盖确认弹窗里找不到「再想想」按钮 —— 玩家无法撤销，"
			+ "确认成了唯一出路")
		return "false"
	cancel.pressed.emit()
	await get_tree().process_frame
	var after := _sha(_slot_path())
	var closed := m._ovr_confirm == null and m._pending_ovr_slot == -1
	var leftover := m._pending_ovr_slot
	m.queue_free()
	await get_tree().process_frame
	if after != before:
		_fail("C", "点了「再想想」旧档仍被覆盖（sha " + str(before) + " → "
			+ str(after) + "）—— 撤销按钮接错了写盘逻辑")
		return "false"
	if not closed:
		_fail("C", "取消后弹窗未关闭或 _pending_ovr_slot 未复位（= "
			+ str(leftover) + "）—— 残留 pending 会被下一次确认误用")
		return "false"
	_okd("C 取消覆盖 → 旧档零改动，弹窗关闭且 pending 复位")
	return "true"


## D 确认覆盖：写盘生效 + 弹窗关闭
func _check_confirm() -> String:
	_write_fake_old_save()
	var before := _sha(_slot_path())
	var m := _make_menu("save")
	await _menu_await_ready(m)
	var info := _find_slot_info(m, PROBE_SLOT)
	m._on_slot_pressed(PROBE_SLOT, true, info)
	await get_tree().process_frame
	var ok := _find_button(m._ovr_confirm, "确认覆盖")
	if ok == null:
		m.queue_free()
		_fail("D", "覆盖确认弹窗里找不到「确认覆盖」按钮 —— 玩家点了没反应")
		return "false"
	ok.pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	var after := _sha(_slot_path())
	var closed := m._ovr_confirm == null
	var rewritten := _read_text(_slot_path())
	var name_gone := rewritten.find(PROBE_OLD_NAME) < 0
	m.queue_free()
	await get_tree().process_frame
	if after == before or not name_gone:
		_fail("D", "点了「确认覆盖」旧档仍未被替换（sha 未变=" + str(after == before)
			+ "，旧档角色名仍在=" + str(not name_gone) + "）—— 拦截过头，存不进档")
		return "false"
	if not closed:
		_fail("D", "确认写盘后弹窗未关闭 —— 遮罩挡住列表，玩家以为界面卡死")
		return "false"
	_okd("D 确认覆盖 → 写盘生效（sha " + str(before) + " → " + str(after) + "）")
	return "true"


## E 旧档信息同源：文案是**构建那一刻的入参快照**，不是每帧重查 SaveManager。
## 做法：弹窗打开后当场把磁盘旧档换成另一个角色，再读弹窗文案 —— 仍必须是旧的那个。
## （早期版本在 close 之后读 _ovr_old_name，而 close 并不重置该字段，
##   判据恒真 → 假绿灯。已废弃那种写法。）
func _check_snapshot_source() -> String:
	_write_fake_old_save()
	var m := _make_menu("save")
	await _menu_await_ready(m)
	var info := _find_slot_info(m, PROBE_SLOT)
	m._on_slot_pressed(PROBE_SLOT, true, info)
	await get_tree().process_frame
	if m._ovr_confirm == null:
		m.queue_free()
		_fail("E", "弹窗未打开，无法校验旧档摘要同源")
		return "false"
	var texts: Array[String] = []
	_collect_labels(m._ovr_confirm, texts)
	var joined := "\n".join(texts)
	var name_ok := joined.find(PROBE_OLD_NAME) >= 0
	var lv_ok := joined.find("Lv.7") >= 0
	var date_ok := joined.find("公元184年 3月") >= 0
	# 弹窗开着的时候把磁盘旧档换成别人 —— 若文案跟着变，说明是每帧重查
	_write_tampered_other_save()
	await get_tree().process_frame
	var texts2: Array[String] = []
	_collect_labels(m._ovr_confirm, texts2)
	var joined2 := "\n".join(texts2)
	var stayed := joined2.find(PROBE_OLD_NAME) >= 0
	var no_leak := joined2.find("篡改者·乙") < 0
	# 还原成探针基准档，避免影响后续判定
	_write_fake_old_save()
	m.queue_free()
	await get_tree().process_frame
	if not name_ok or not lv_ok or not date_ok:
		_fail("E", "确认弹窗未展示旧档摘要（角色名=" + str(name_ok) + " 等级="
			+ str(lv_ok) + " 日期=" + str(date_ok) + "）—— 玩家不知道要覆盖掉什么，"
			+ "确认只是形式")
		return "false"
	if not stayed or not no_leak:
		_fail("E", "弹窗开着时磁盘旧档已换成他人（篡改者·乙Lv.99），弹窗文案却"
			+ "跟着变了（stayed=" + str(stayed) + " no_leak=" + str(no_leak)
			+ "）—— 文案不是入参快照，确认态与列表行会显示两个版本的旧档")
		return "false"
	_okd("E 弹窗旧档摘要为构建时快照（" + PROBE_OLD_NAME + " Lv.7 公元184年3月），"
		+ "弹窗期间外部改盘不污染")
	return "true"


## 写一个「另一个旧档」，用来检验弹窗文案是否被外部状态带偏
func _write_tampered_other_save() -> void:
	var payload := {
		"saved_at": "公元300年 9月 存档",
		"saved_at_unix": 2000000,
		"manual": true,
		"game": {
			"player_name": "篡改者·乙",
			"player_level": 99,
			"year": 300,
			"month": 9,
		},
	}
	var f := FileAccess.open(_slot_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "\t"))
		f.close()


## F 读档模式不弹覆盖确认（读档不销毁数据，拦它属于矫枉过正）。
##
## 【范围自律·重要】本判定只点**空槽**：load_game 对不存在的档直接 return false，
## 零副作用。若点「已存在档」，load_game 成功后会 SceneRouter.goto_fresh("world")
## 切场景，探针节点当场被 free —— 后续判定全灭且会被误读成「E/G/H 挂了」。
## 「load 模式 + 已存在档 必不进覆盖分支」这一命题的**完备性**由 Python 侧
## 静态锚定 F 级锁（`_mode == "load"` 分支内的 return 必须早于 `if exists:`）。
func _check_load_mode() -> String:
	if _file_exists(_slot_path()):
		DirAccess.remove_absolute(_slot_path())
	var m := _make_menu("load")
	await _menu_await_ready(m)
	var info := _find_slot_info(m, PROBE_SLOT)
	if bool(info.get("exists", false)):
		m.queue_free()
		_fail("F", "读档模式下3 号槽摘要 exists=true —— 探针前提被破坏")
		return "false"
	m._on_slot_pressed(PROBE_SLOT, false, info)
	await get_tree().process_frame
	var modal := m._ovr_confirm != null
	var pending := m._pending_ovr_slot
	var wrote := _file_exists(_slot_path())
	m.queue_free()
	await get_tree().process_frame
	if modal:
		_fail("F", "读档模式竟弹出了覆盖确认 —— 读档不销毁任何数据，拦它属于矫枉过正")
		return "false"
	if pending != -1:
		_fail("F", "读档模式残留 _pending_ovr_slot=" + str(pending)
			+ " —— 后续切到保存模式时会被误用")
		return "false"
	if wrote:
		_fail("F", "读档模式竟然写了档 —— 覆盖确认的守卫被击穿")
		return "false"
	_okd("F 读档模式 → 不弹覆盖确认、不写盘、不残留 pending")
	return "true"


## G 幂等：弹窗已开时重复调用不再叠第二层遮罩
func _check_no_double() -> String:
	_write_fake_old_save()
	var m := _make_menu("save")
	await _menu_await_ready(m)
	var info := _find_slot_info(m, PROBE_SLOT)
	m._on_slot_pressed(PROBE_SLOT, true, info)
	await get_tree().process_frame
	var dim1 := m._ovr_confirm
	m._show_overwrite_confirm(PROBE_SLOT + 1, {"player_name": "别的", "level": 2})
	await get_tree().process_frame
	var same := m._ovr_confirm == dim1
	var pending_kept := m._pending_ovr_slot == PROBE_SLOT
	var pending_now := m._pending_ovr_slot
	m.queue_free()
	await get_tree().process_frame
	if not same:
		_fail("G", "弹窗已开时重复触发叠了第二个遮罩 —— 双击/连点会让玩家连按两次确认")
		return "false"
	if not pending_kept:
		_fail("G", "重复触发把待写槽位改成了 " + str(pending_now)
			+ " —— 连点会写到另一个槽位")
		return "false"
	_okd("G 重复触发 → 不叠遮罩、不改待写槽位")
	return "true"


## H 遮罩关闭回调：只关窗不写盘
func _check_close_callback() -> String:
	_write_fake_old_save()
	var before := _sha(_slot_path())
	var m := _make_menu("save")
	await _menu_await_ready(m)
	var info := _find_slot_info(m, PROBE_SLOT)
	m._on_slot_pressed(PROBE_SLOT, true, info)
	await get_tree().process_frame
	m._close_overwrite_confirm()
	await get_tree().process_frame
	var after := _sha(_slot_path())
	var closed := m._ovr_confirm == null
	m.queue_free()
	await get_tree().process_frame
	if after != before:
		_fail("H", "关闭回调（点遮罩/返回）却改写了旧档 —— 关窗路径误接了写盘")
		return "false"
	if not closed:
		_fail("H", "关闭回调后 _ovr_confirm 仍非空 —— 遮罩残留，界面被永久遮挡")
		return "false"
	_okd("H 关闭回调 → 只关窗不写盘")
	return "true"


# ==================== 副作用还原 ====================

func _find_slot_info(m: SaveMenu, slot: int) -> Dictionary:
	for info in SaveManager.get_save_slots():
		if int(info["slot"]) == slot:
			return info
	return {"slot": slot, "exists": false}


func _backup_state() -> void:
	_meta_backup = _read_text("user://saves/_meta.json")
	_metabak_backup = _read_text("user://saves/_meta.json.bak")
	_slot_backup = _read_text(_slot_path())


func _restore_state() -> void:
	# 3 号槽还原
	if _slot_backup == "":
		if _file_exists(_slot_path()):
			DirAccess.remove_absolute(_slot_path())
		if _file_exists(_slot_path() + ".bak"):
			DirAccess.remove_absolute(_slot_path() + ".bak")
		if _file_exists(_slot_path() + ".tmp"):
			DirAccess.remove_absolute(_slot_path() + ".tmp")
	else:
		var f := FileAccess.open(_slot_path(), FileAccess.WRITE)
		if f != null:
			f.store_string(_slot_backup)
			f.close()
	_restore_text("user://saves/_meta.json", _meta_backup)
	# 【实测踩坑】SaveManager 原子写会顺手生成 _meta.json.bak。第一次跑完只还原了
	# _meta.json，.bak 里留着探针的 "3" 号槽记录 —— 玩家存档目录被测试污染。
	_restore_text("user://saves/_meta.json.bak", _metabak_backup)
	_detail.append("RESTORE slot3_existed=" + str(_slot_backup != "")
		+ " meta_existed=" + str(_meta_backup != "")
		+ " metabak_existed=" + str(_metabak_backup != ""))


func _restore_text(path: String, backup: String) -> void:
	if backup == "":
		if _file_exists(path):
			DirAccess.remove_absolute(path)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(backup)
		f.close()


func _write(lines: Array[String]) -> void:
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	get_tree().quit(0 if _fails.is_empty() else 1)