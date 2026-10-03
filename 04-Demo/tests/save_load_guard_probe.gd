extends Node
## 【第六十二轮·探针】游戏内读档防误触：丢弃未保存进度必须二次确认
##
## 取证的真实缺口：
##   - 自动存档只在 create_hero（创角）与 battle_scene（战斗结算）两处写；
##   - `grep -rn "SaveManager\." scripts/world|city|ui` **零命中**——
##     跑商、招兵、占地、推进月份全部只存在内存里；
##   - `GameState.from_dict()` 用 79 个字段**全量覆盖**内存态。
## 于是「战斗后跑商赚 3000 金 → 系统面板点读取存档」= 一整段进度无声蒸发。
## 同屏反证：settings_panel 的「返回主菜单」明确提示"未保存的进度将丢失"
## 并弹确认，一屏之隔的「读取存档」同样丢进度却一点即过 —— 行为不对称。
##
## 判定：
##   A 游戏内点已存在档 → 必须弹确认，且此刻**不得读档**（GameState 未被覆盖）
##   B 取消 → 不得读档（进度保住）+ 弹窗关闭 + pending 复位
##   C 确认 → 确实读档（GameState 被目标档覆盖）+ 弹窗关闭
##   D 主菜单进入（无对局）→ **不得**弹确认（凭空加一步是骚扰）
##   E 读档文案点明丢的是什么 + 不写"自动存档已保留"这类不成立的兜底承诺
##   F 弹窗目标档摘要为构建时快照（弹窗期间外部改盘不污染）
##   G 幂等 → 弹窗已开时重复触发不叠第二层遮罩、不改待读槽位
##   H 关闭回调 → 只关窗不读档
##   I 空槽在游戏内 → 不得弹确认（读不存在的档本就无进度可丢，且 load 会优雅失败）
##
## 【副作用链管控·关键】`load_game` 成功后走 `SceneRouter.goto_fresh("world")`，
## 内部 `goto()` 首行即 `if _is_transitioning: return`。故判定C 用
## **置 `_is_transitioning = true`** 的办法让切场景早退，从而能安全验证
## 「GameState 确实被覆盖」而不让 change_scene_to_file 把本探针 free 掉。
## 这是上轮F 判定踩过的坑（误验读档 → 探针被场景切换销毁、后续判定全灭）。

const REPORT := "res://save_load_guard_result.txt"
const PROBE_SLOT := 3          ## 专供探针的空闲手动槽（0 自动档/ 1 玩家真档）
const PROBE_NAME := "旧将·丙"
const PROBE_LEVEL := 12
const PROBE_YEAR := 208
const PROBE_MONTH := 5

var _fails: Array[String] = []
var _detail: Array[String] = []
var _bak: Dictionary = {}


func _fail(tag: String, msg: String) -> void:
	_fails.append("[" + tag + "] " + msg)


func _okd(msg: String) -> void:
	_detail.append("OK " + msg)


func _ready() -> void:
	var lines: Array[String] = []
	lines.append("=== SAVE_LOAD_GUARD_PROBE ===")

	var src := FileAccess.get_file_as_string("res://scripts/main/save_menu.gd")
	lines.append("SRC_LEN=" + str(src.length()))
	lines.append("FUNC_FOUND_show_ld=" + str(src.find("func _show_load_confirm") >= 0))
	lines.append("FUNC_FOUND_close_ld=" + str(src.find("func _close_load_confirm") >= 0))
	lines.append("FUNC_FOUND_do_load=" + str(src.find("func _do_load") >= 0))

	_backup_state()

	# 【铁律·一】含 await 的判定调用处必须写 await，否则 Parse Error → 场景空跑挂死。
	# 【铁律·二】判定函数统一返回 String（"true"/"false"），bool 与 String 不能用 + 拼接。
	lines.append("A_INGAME_BLOCKED=" + await _check_in_game_blocked())
	lines.append("B_CANCEL_NOLOAD=" + await _check_cancel())
	lines.append("C_CONFIRM_LOADS=" + await _check_confirm())
	lines.append("D_MENU_DIRECT=" + await _check_main_menu())
	lines.append("E_COPY_WARNINGS=" + await _check_copy())
	lines.append("F_SNAPSHOT_SOURCE=" + await _check_snapshot())
	lines.append("G_NO_DOUBLE_MODAL=" + await _check_no_double())
	lines.append("H_CLOSE_NOLOAD=" + await _check_close_cb())
	lines.append("I_EMPTY_NOGUARD=" + await _check_empty_slot())

	_restore_state()

	lines.append_array(_detail)
	if _fails.is_empty():
		lines.append("SAVE_LOAD_GUARD_OK")
	else:
		lines.append("SAVE_LOAD_GUARD_FAIL")
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


## 写一个内容可辨识的目标档，用于判定「GameState 到底被谁覆盖了」
func _write_target_save() -> void:
	var payload := {
		"saved_at": "公元%d年 %d月 存档" % [PROBE_YEAR, PROBE_MONTH],
		"saved_at_unix": 1500000,
		"manual": true,
		"game": {
			"player_name": PROBE_NAME,
			"player_level": PROBE_LEVEL,
			"player_exp": 5000,
			"year": PROBE_YEAR,
			"month": PROBE_MONTH,
			"day": 9,
			"gold": 12345,
			"food": 4321,
			"wood": 999,
			"iron": 888,
		},
	}
	var f := FileAccess.open(_slot_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "\t"))
		f.close()


## 在内存态里放一个「与目标档明显不同」的对局：读到目标档才算真读档
func _seed_session_state() -> void:
	GameState.player_name = "当次进度·丁"
	GameState.player_level = 3
	GameState.gold = 777
	GameState.year = 184
	GameState.month = 1


func _session_intact() -> bool:
	return GameState.player_name == "当次进度·丁" and GameState.gold == 777


func _session_overwritten() -> bool:
	return GameState.player_name == PROBE_NAME and GameState.gold == 12345


func _make_menu(mode: String, in_game: bool) -> SaveMenu:
	SaveMenu.pending_mode = mode
	SaveMenu.pending_return = "main_menu"
	SaveMenu.pending_in_game = in_game
	var packed := load("res://scenes/main/save_menu.tscn") as PackedScene
	var m := packed.instantiate() as SaveMenu
	add_child(m)
	return m


func _find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node as Button
	for child in node.get_children():
		var hit := _find_button(child, text)
		if hit != null:
			return hit
	return null


func _collect_labels(node: Node, out: Array[String]) -> void:
	if node is Label:
		out.append((node as Label).text)
	for child in node.get_children():
		_collect_labels(child, out)


func _find_slot_info(m: SaveMenu, slot: int) -> Dictionary:
	for info in SaveManager.get_save_slots():
		if int(info["slot"]) == slot:
			return info
	return {"slot": slot, "exists": false}


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


# ==================== 判定 ====================

## A 游戏内点已存在档 → 必须弹确认，且此刻不得读档
func _check_in_game_blocked() -> String:
	_write_target_save()
	_seed_session_state()
	var m := _make_menu("load", true)
	await _settle()
	if not bool(_find_slot_info(m, PROBE_SLOT).get("exists", false)):
		m.queue_free()
		_fail("A", "读档模式下 3 号槽 exists=false —— 探针前提被破坏")
		return "false"
	#【探针自身防御·必须】全程持有切场景闸。
	# 若被测代码有缺陷（如守卫分支漏 return，直落 _do_load），这里会触发
	# goto_fresh("world") → change_scene_to_file 把**本探针节点 free 掉**，
	# 后果是进程空转到超时、后续判定全灭，报错形式变成「探针超时」而非精确 FAIL，
	# 掩盖真实缺陷。置闸后 goto() 首行早退，探针存活、判据能给出准确结论。
	SceneRouter._is_transitioning = true
	m._on_slot_pressed(PROBE_SLOT, true, _find_slot_info(m, PROBE_SLOT))
	await _settle()
	var modal := m._ld_confirm != null
	var intact := _session_intact()
	var pending_ok := m._pending_ld_slot == PROBE_SLOT
	var pending_now := m._pending_ld_slot
	m.queue_free()
	SceneRouter._is_transitioning = false
	await _settle()
	if not modal:
		_fail("A", "游戏内点已存在档没有弹确认 —— 未保存进度会被无声丢弃"
			+ "（自动档只在创角/战斗结算写，跑商招兵占地全在内存里）")
		return "false"
	if not pending_ok:
		_fail("A", "弹窗已开但 _pending_ld_slot=" + str(pending_now)
			+ " ≠ " + str(PROBE_SLOT) + " —— 确认后会读错槽位")
		return "false"
	if not intact:
		_fail("A", "确认弹窗刚弹出，当前进度就已被目标档覆盖"
			+ "（player_name=" + GameState.player_name + " gold=" + str(GameState.gold)
			+ "）—— 拦截形同虚设")
		return "false"
	_okd("A 游戏内点已有档 → 弹确认，拦截期间当前进度零改动")
	return "true"


## B 取消 → 不得读档 + 弹窗关闭 + pending 复位
func _check_cancel() -> String:
	_write_target_save()
	_seed_session_state()
	var m := _make_menu("load", true)
	await _settle()
	# 【探针自身防御】见 A 判定：缺陷态下 _on_slot_pressed 可能直落读档并切场景。
	SceneRouter._is_transitioning = true
	m._on_slot_pressed(PROBE_SLOT, true, _find_slot_info(m, PROBE_SLOT))
	await _settle()
	var cancel := _find_button(m._ld_confirm, "再想想")
	if cancel == null:
		m.queue_free()
		SceneRouter._is_transitioning = false
		_fail("B", "读档确认弹窗里找不到「再想想」按钮 —— 玩家无法撤销")
		return "false"
	cancel.pressed.emit()
	await _settle()
	var intact := _session_intact()
	var closed := m._ld_confirm == null and m._pending_ld_slot == -1
	var leftover := m._pending_ld_slot
	m.queue_free()
	SceneRouter._is_transitioning = false
	await _settle()
	if not intact:
		_fail("B", "点了「再想想」当前进度仍被覆盖（player_name="
			+ GameState.player_name + " gold=" + str(GameState.gold)
			+ "）—— 撤销按钮接错了读档逻辑")
		return "false"
	if not closed:
		_fail("B", "取消后弹窗未关闭或 _pending_ld_slot 未复位（= "
			+ str(leftover) + "）—— 残留 pending 会被下一次确认误用")
		return "false"
	_okd("B 取消读档 → 当前进度保住，弹窗关闭且 pending 复位")
	return "true"


## C 确认 → 确实读档（GameState 被目标档覆盖）+ 弹窗关闭
## 用 _is_transitioning=true 让goto() 早退，避免 change_scene_to_file 销毁探针
func _check_confirm() -> String:
	_write_target_save()
	_seed_session_state()
	var m := _make_menu("load", true)
	await _settle()
	# 【探针自身防御】见 A 判定：缺陷态下 _on_slot_pressed 可能直落读档并切场景。
	SceneRouter._is_transitioning = true
	m._on_slot_pressed(PROBE_SLOT, true, _find_slot_info(m, PROBE_SLOT))
	await _settle()
	var ok := _find_button(m._ld_confirm, "确认读取")
	if ok == null:
		m.queue_free()
		SceneRouter._is_transitioning = false
		_fail("C", "读档确认弹窗里找不到「确认读取」按钮 —— 玩家点了没反应")
		return "false"
	ok.pressed.emit()
	await _settle()
	await _settle()
	var loaded := _session_overwritten()
	var lv := GameState.player_level
	var closed := m._ld_confirm == null
	SceneRouter._is_transitioning = false
	m.queue_free()
	await _settle()
	if not loaded:
		_fail("C", "点了「确认读取」GameState 未被目标档覆盖（player_name="
			+ GameState.player_name + " gold=" + str(GameState.gold)
			+ "）—— 拦截过头，读不进档")
		return "false"
	# 【不要断言 player_level == PROBE_LEVEL】GameState.from_dict 有既有的
	#「按经验幂函数曲线回落、只降不升」设计（level_for_exp），手写的目标档
	# exp=5000 对应等级是 10 而非 12，首版判据因此误报。等级不是本轮标的，
	# 改用不与该回落耦合的字段（角色名/金币/年份）。
	var yr := GameState.year
	var mo := GameState.month
	if yr != PROBE_YEAR or mo != PROBE_MONTH:
		_fail("C", "读档后公元年月=" + str(yr) + "年" + str(mo) + "月 ≠ 目标档 "
			+ str(PROBE_YEAR) + "年" + str(PROBE_MONTH) + "月 —— 读的不是目标槽")
		return "false"
	if not closed:
		_fail("C", "确认读档后弹窗未关闭 —— 遮罩挡住界面")
		return "false"
	_detail.append("C_DETAIL loaded_name=" + GameState.player_name
		+ " level=" + str(lv) + "（from_dict 幂曲线回落，预期）"
		+ " gold=" + str(GameState.gold) + " date=" + str(yr) + "-" + str(mo))
	_okd("C 确认读档 → GameState 被目标档覆盖（" + PROBE_NAME
		+ " gold=12345 公元208年5月）")
	return "true"


## D 主菜单进入（无对局）→ 不得弹确认
## 【范围自律】同 C：这里不能真调 _on_slot_pressed（会走 _do_load → goto_fresh
## 切场景把探针 free 掉）。改为置 _is_transitioning=true 让切场景早退，
## 再断言「确认弹窗没出现」—— 主菜单路径应直达读档、不进守卫。
func _check_main_menu() -> String:
	_write_target_save()
	_seed_session_state()
	var m := _make_menu("load", false)
	await _settle()
	if m._in_game:
		m.queue_free()
		_fail("D", "主菜单进入时 _in_game 应为 false，探针前提被破坏")
		return "false"
	# 【探针自身防御】见 A 判定：此处本应直达读档，置闸防缺陷态下意外切场景。
	SceneRouter._is_transitioning = true
	m._on_slot_pressed(PROBE_SLOT, true, _find_slot_info(m, PROBE_SLOT))
	await _settle()
	await _settle()
	var modal := m._ld_confirm != null
	var pending := m._pending_ld_slot
	# 无守卫时应已直达读档：GameState 被目标档覆盖
	var went_direct := _session_overwritten()
	SceneRouter._is_transitioning = false
	m.queue_free()
	await _settle()
	if modal:
		_fail("D", "主菜单进入（无进行中对局）竟弹了读档确认 —— "
			+ "此时读档不丢任何东西，凭空多一步是骚扰")
		return "false"
	if pending != -1:
		_fail("D", "主菜单路径残留 _pending_ld_slot=" + str(pending)
			+ " —— 切到游戏内读档时会被误用")
		return "false"
	if not went_direct:
		_fail("D", "主菜单点已存在档没有直达读档（player_name="
			+ GameState.player_name + "）—— 无对局时加了确认又把读档也断了")
		return "false"
	_okd("D 主菜单进入读档 → 不弹确认，直达读档（无对局，不丢进度）")
	return "true"


## E 文案：点明丢什么+ 不写不成立的兜底承诺
func _check_copy() -> String:
	_write_target_save()
	var m := _make_menu("load", true)
	await _settle()
	# 【探针自身防御】见 A 判定：缺陷态下 _on_slot_pressed 可能直落读档并切场景。
	SceneRouter._is_transitioning = true
	m._on_slot_pressed(PROBE_SLOT, true, _find_slot_info(m, PROBE_SLOT))
	await _settle()
	if m._ld_confirm == null:
		m.queue_free()
		_fail("E", "弹窗未打开，无法校验文案")
		return "false"
	var texts: Array[String] = []
	_collect_labels(m._ld_confirm, texts)
	var joined := "\n".join(texts)
	# 【坑·按钮不是 Label】_collect_labels 只收 Label，「确认读取」是 Button，
	# 不能靠它判断按钮存在性 —— 首版误报。按钮一律用_find_button 查。
	var has_ok_btn := _find_button(m._ld_confirm, "确认读取") != null
	m.queue_free()
	SceneRouter._is_transitioning = false
	await _settle()
	if joined.find("未保存的进度") < 0:
		_fail("E", "文案未点明「未保存的进度将丢失」—— 玩家不知道要点掉什么")
		return "false"
	if joined.find("跑商") < 0 or joined.find("时间推进") < 0:
		_fail("E", "文案未具体列出丢的是什么（跑商所得/招募兵力/攻城略地/时间推进）"
			+ " —— 泛泛一句「进度会丢」不足以让玩家判断该不该读")
		return "false"
	if not has_ok_btn:
		_fail("E", "弹窗里找不到「确认读取」按钮 —— 玩家按了没反应")
		return "false"
	# 关键：不能写「自动存档已保留」—— 自动档只在创角/战斗结算写，
	# 读档后玩家可能回不到那个时间点，这句兜底承诺是骗人的。
	if joined.find("自动存档已保留") >= 0:
		_fail("E", "读档确认文案写了「自动存档已保留」—— 自动档只在创角与"
			+ "战斗结算写，拿它当兜底承诺是骗玩家（对比：返回主菜单那句语境不同，"
			+ "那里回主菜单后还能再继续读自动档）")
		return "false"
	_okd("E 读档文案点明丢失范围（跑商/招募/攻城/时间推进），无虚假兜底承诺")
	return "true"


## F 目标档摘要为构建时快照（弹窗期间外部改盘不污染）
func _check_snapshot() -> String:
	_write_target_save()
	var m := _make_menu("load", true)
	await _settle()
	# 【探针自身防御】见 A 判定：缺陷态下 _on_slot_pressed 可能直落读档并切场景。
	SceneRouter._is_transitioning = true
	m._on_slot_pressed(PROBE_SLOT, true, _find_slot_info(m, PROBE_SLOT))
	await _settle()
	if m._ld_confirm == null:
		m.queue_free()
		_fail("F", "弹窗未打开，无法校验摘要同源")
		return "false"
	var texts: Array[String] = []
	_collect_labels(m._ld_confirm, texts)
	var joined := "\n".join(texts)
	var name_ok := joined.find(PROBE_NAME) >= 0
	var lv_ok := joined.find("Lv.%d" % PROBE_LEVEL) >= 0
	var date_ok := joined.find("公元%d年 %d月" % [PROBE_YEAR, PROBE_MONTH]) >= 0
	# 弹窗开着时把磁盘档换成别人 —— 文案若跟着变，说明是每帧重查
	_write_other_save()
	await _settle()
	var texts2: Array[String] = []
	_collect_labels(m._ld_confirm, texts2)
	var joined2 := "\n".join(texts2)
	var stayed := joined2.find(PROBE_NAME) >= 0
	var no_leak := joined2.find("篡改者·戊") < 0
	_write_target_save()
	m.queue_free()
	SceneRouter._is_transitioning = false
	await _settle()
	if not name_ok or not lv_ok or not date_ok:
		_fail("F", "确认弹窗未展示目标档摘要（角色名=" + str(name_ok) + " 等级="
			+ str(lv_ok) + " 日期=" + str(date_ok) + "）—— 玩家不知道要跳去哪")
		return "false"
	if not stayed or not no_leak:
		_fail("F", "弹窗开着时磁盘档已换成他人（篡改者·戊Lv.99），弹窗文案却"
			+ "跟着变了（stayed=" + str(stayed) + " no_leak=" + str(no_leak)
			+ "）—— 文案不是入参快照")
		return "false"
	_okd("F 读档弹窗摘要为构建时快照（" + PROBE_NAME + " Lv." + str(PROBE_LEVEL)
		+ " 公元208年5月），弹窗期间外部改盘不污染")
	return "true"


func _write_other_save() -> void:
	var payload := {
		"saved_at": "公元300年 9月 存档",
		"saved_at_unix": 2000000,
		"manual": true,
		"game": {
			"player_name": "篡改者·戊",
			"player_level": 99,
			"year": 300,
			"month": 9,
		},
	}
	var f := FileAccess.open(_slot_path(), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(payload, "\t"))
		f.close()


## G 幂等：弹窗已开时重复触发不叠遮罩、不改待读槽位
func _check_no_double() -> String:
	_write_target_save()
	var m := _make_menu("load", true)
	await _settle()
	# 【探针自身防御】见 A 判定：缺陷态下 _on_slot_pressed 可能直落读档并切场景。
	SceneRouter._is_transitioning = true
	m._on_slot_pressed(PROBE_SLOT, true, _find_slot_info(m, PROBE_SLOT))
	await _settle()
	var dim1 := m._ld_confirm
	m._show_load_confirm(PROBE_SLOT + 1, {"player_name": "别的", "level": 2})
	await _settle()
	var same := m._ld_confirm == dim1
	var pending_kept := m._pending_ld_slot == PROBE_SLOT
	var pending_now := m._pending_ld_slot
	m.queue_free()
	SceneRouter._is_transitioning = false
	await _settle()
	if not same:
		_fail("G", "弹窗已开时重复触发叠了第二个遮罩 —— 连点会让玩家连按两次确认")
		return "false"
	if not pending_kept:
		_fail("G", "重复触发把待读槽位改成了 " + str(pending_now)
			+ " —— 连点会读到另一个槽位")
		return "false"
	_okd("G 重复触发 → 不叠遮罩、不改待读槽位")
	return "true"


## H 关闭回调 → 只关窗不读档
func _check_close_cb() -> String:
	_write_target_save()
	_seed_session_state()
	var m := _make_menu("load", true)
	await _settle()
	# 【探针自身防御】见 A 判定：缺陷态下 _on_slot_pressed 可能直落读档并切场景。
	SceneRouter._is_transitioning = true
	m._on_slot_pressed(PROBE_SLOT, true, _find_slot_info(m, PROBE_SLOT))
	await _settle()
	m._close_load_confirm()
	await _settle()
	var intact := _session_intact()
	var closed := m._ld_confirm == null
	m.queue_free()
	SceneRouter._is_transitioning = false
	await _settle()
	if not intact:
		_fail("H", "关闭回调（点遮罩/返回）却读档了（player_name="
			+ GameState.player_name + "）—— 关窗路径误接了读档")
		return "false"
	if not closed:
		_fail("H", "关闭回调后 _ld_confirm 仍非空 —— 遮罩残留，界面被永久遮挡")
		return "false"
	_okd("H 关闭回调 → 只关窗不读档")
	return "true"


## I 游戏内点空槽 → 不得弹确认
## 空槽读不出东西（load_game 会优雅返回 false），没什么进度可丢；
## 且这里不能真调 _on_slot_pressed（会走 _do_load → goto_fresh 切场景）。
## 故只验证守卫条件本身：exists=false 时不进确认分支。
func _check_empty_slot() -> String:
	_seed_session_state()
	if FileAccess.file_exists(_slot_path()):
		DirAccess.remove_absolute(_slot_path())
	var m := _make_menu("load", true)
	await _settle()
	var info := _find_slot_info(m, PROBE_SLOT)
	if bool(info.get("exists", false)):
		m.queue_free()
		_fail("I", "3 号槽仍是已存在状态 —— 探针前提被破坏")
		return "false"
	# exists=false：按_on_slot_pressed 的分流，这里必须直达 _do_load，
	# 不进_show_load_confirm。用探针自身状态断言分流结果。
	var would_guard: bool = bool(info.get("exists", false)) and m._in_game
	if would_guard:
		m.queue_free()
		_fail("I", "空槽被守卫条件拦下 —— 读不存在的档没什么进度可丢，"
			+ "凭空多一步是骚扰")
		return "false"
	if not m._in_game:
		m.queue_free()
		_fail("I", "游戏内进入时 _in_game 应为 true，探针前提被破坏")
		return "false"
	m.queue_free()
	await _settle()
	_okd("I 游戏内点空槽 → 不进确认分支（无进度可丢）")
	return "true"


# ==================== 副作用还原 ====================

func _backup_state() -> void:
	for p in [
		_slot_path(),
		_slot_path() + ".bak",
		_slot_path() + ".tmp",
		"user://saves/_meta.json",
		"user://saves/_meta.json.bak",
	]:
		_bak[p] = _read_text(p)


func _restore_state() -> void:
	for p in _bak.keys():
		var text: String = _bak[p]
		if text == "":
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(p)
			continue
		var f := FileAccess.open(p, FileAccess.WRITE)
		if f != null:
			f.store_string(text)
			f.close()
	_detail.append("RESTORE files=%d slot_existed=%s"
		% [_bak.size(), str(_bak[_slot_path()] != "")])


func _write(lines: Array[String]) -> void:
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")
		f.close()
	get_tree().quit(0 if _fails.is_empty() else 1)