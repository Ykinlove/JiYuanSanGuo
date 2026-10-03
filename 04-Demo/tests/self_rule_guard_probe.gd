extends Node
## 【第六十三轮】自立建国二次确认 headless 探针
## 缺陷：SelfRulePanel 点「自立建国」一点即过，无任何确认。
## 而建国是本工程最重的不可逆操作（is_self_rule 单向锁死 / 全势力关系 -10 / join_intent 作废 /
## 失败结局线自此开启），同屏却已有三处同级确认（处死俘虏、解散部队、读档）。
##
## A–I 为行为层判定；J1–J7 为源码锚定层（由 _verify_self_rule_guard.py 承担）。
## 零写盘：不碰任何存档槽位，仅在内存态上操作并复原。

const OUT := "res://self_rule_guard_result.txt"

var _lines: Array[String] = []
var _panel: SelfRulePanel = null
var _host: Control = null


func _ready() -> void:
	# 【探针夹具坑·重要】_run() 与每个 _check_* 都是协程（含 await），必须**逐个 await**：
	# 不加 await 时它们各自跑到第一个 await 就返回控制权，9 个检查并发执行，
	# 而 _make_panel() 只有一个 _host 成员 —— 后一个检查会把前一个的 host queue_free，
	# 前一个检查恢复后拿到的是已释放对象（"previously freed"），且判据会互相污染。
	await _run()
	_write_out()


func _run() -> void:
	await _check_a_guard_and_no_side_effect()
	await _check_b_cancel_keeps_unfounded()
	await _check_c_confirm_actually_founds()
	await _check_d_rename_no_confirm()
	await _check_e_text_states_irreversible()
	await _check_f_snapshot_not_live_widget()
	await _check_g_double_click_no_stack()
	await _check_h_close_cb_only_closes()
	await _check_i_precondition_fail_no_modal()


# ---------- 公共夹具 ----------

## 布置一个「前置全满足但尚未自立」的状态
func _prime_ready() -> void:
	GameState.reset()
	GameState.is_self_rule = false
	GameState.affiliation = 0
	GameState.has_jade_seal = true
	GameState.has_tiger_tally = true
	GameState.fame = 100
	GameState.infamy = 0
	GameState.village_reputation = { "lu_yue": 100 }
	GameState.faction_relations = { 1: 30, 2: 20, 3: 40 }
	GameState.join_intent = 2
	GameState.story_flags = ["self_rule_unlocked"]


func _make_panel() -> SelfRulePanel:
	if _host != null and is_instance_valid(_host):
		_host.queue_free()
	_host = Control.new()
	_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_host)
	_panel = SelfRulePanel.new()
	_host.add_child(_panel)
	return _panel


func _founding_snapshot() -> Dictionary:
	return {
		"is_self_rule": GameState.is_self_rule,
		"name": GameState.self_rule_name,
		"flag": GameState.self_rule_flag,
		"city": GameState.self_rule_city,
		"relations": GameState.faction_relations.duplicate(true),
		"join_intent": GameState.join_intent,
	}


# ---------- A：点「自立建国」必须被拦，且拦截期内存态零改动 ----------

func _check_a_guard_and_no_side_effect() -> void:
	_prime_ready()
	var p := _make_panel()
	p.open("lu_yue")
	await get_tree().process_frame
	var before := _founding_snapshot()

	p._name_edit.text = "大燕"
	p._flag_selected = 3
	# 【关键闸门】必须走 _on_confirm（玩家点按钮的路径），而非直接调 _do_found
	p._on_confirm()
	await get_tree().process_frame

	var modal := p._found_confirm
	var ok := modal != null and is_instance_valid(modal) and modal.visible
	_line("A", "点「自立建国」→ 弹确认遮罩", ok)

	var after := _founding_snapshot()
	# 注意：Dictionary 下标取值无静态类型，var x := 必须显式写 bool，否则
	# GDScript 报 "Cannot infer the type of ... because the value doesn't have a set type"
	var same: bool = before["is_self_rule"] == after["is_self_rule"] \
		and before["name"] == after["name"] \
		and before["flag"] == after["flag"] \
		and before["city"] == after["city"] \
		and before["relations"] == after["relations"] \
		and before["join_intent"] == after["join_intent"]
	_line("A2", "拦截期 is_self_rule/国号/旗帜/都城/势力关系/投靠意向全零改动", same)

	_p_close(p)


# ---------- B：取消后不得建国 ----------

func _check_b_cancel_keeps_unfounded() -> void:
	_prime_ready()
	var p := _make_panel()
	p.open("lu_yue")
	await get_tree().process_frame
	p._name_edit.text = "大燕"
	p._on_confirm()
	await get_tree().process_frame

	var cancel := _find_button(p, "再想想")
	_line("B1", "确认窗存在「再想想」撤销按钮", cancel != null)
	if cancel != null:
		cancel.pressed.emit()
		await get_tree().process_frame

	var closed := p._found_confirm == null or not is_instance_valid(p._found_confirm)
	_line("B2", "撤销后遮罩已释放", closed)
	_line("B3", "撤销后未自立（is_self_rule 仍 false）", GameState.is_self_rule == false)
	_line("B4", "撤销后国号未写入", GameState.self_rule_name == "")
	_line("B5", "撤销后势力关系未降（RIVAL_RELATION_DELTA 未生效）",
		int(GameState.faction_relations.get(1, 0)) == 30)
	_line("B6", "撤销后投靠意向未作废", GameState.join_intent == 2)
	_p_close(p)


# ---------- C：确认后才真正建国，代价逐项生效 ----------

func _check_c_confirm_actually_founds() -> void:
	_prime_ready()
	var p := _make_panel()
	p.open("lu_yue")
	await get_tree().process_frame
	p._name_edit.text = "大燕"
	p._flag_selected = 3
	p._on_confirm()
	await get_tree().process_frame

	var ok := _find_button(p, "确认建国")
	_line("C1", "确认窗存在「确认建国」按钮", ok != null)
	if ok != null:
		ok.pressed.emit()
		await get_tree().process_frame

	_line("C2", "确认后 is_self_rule 置真", GameState.is_self_rule == true)
	_line("C3", "确认后国号写入", GameState.self_rule_name == "大燕")
	_line("C4", "确认后旗帜写入（取构建时快照）", GameState.self_rule_flag == 3)
	_line("C5", "确认后都城写入", GameState.self_rule_city == "lu_yue")
	# 代价链：全势力关系 -10（不可逆）
	var all_down := int(GameState.faction_relations.get(1, 0)) == 20 \
		and int(GameState.faction_relations.get(2, 0)) == 10 \
		and int(GameState.faction_relations.get(3, 0)) == 30
	_line("C6", "确认后全势力关系各降 10（3/3 家生效）", all_down)
	_line("C7", "确认后投靠意向作废", GameState.join_intent == 0)
	_p_close(p)


# ---------- D：改国号是**可逆**操作，不得加确认（避免矫枉过正） ----------

func _check_d_rename_no_confirm() -> void:
	_prime_ready()
	# 先真建国
	SelfRuleService.found_self_rule("lu_yue", "大燕", 1)
	var p := _make_panel()
	p.open("lu_yue")
	await get_tree().process_frame
	_line("D0", "前置：已自立", GameState.is_self_rule == true)

	p._name_edit.text = "大周"
	p._on_confirm()
	await get_tree().process_frame

	var no_modal := p._found_confirm == null or not is_instance_valid(p._found_confirm)
	_line("D1", "已自立后改国号不弹确认（可逆操作不加步骤）", no_modal)
	_line("D2", "改国号即时生效", GameState.self_rule_name == "大周")
	_p_close(p)


# ---------- E：文案必须点明不可逆代价，且不含虚假兜底承诺 ----------

func _check_e_text_states_irreversible() -> void:
	_prime_ready()
	var p := _make_panel()
	p.open("lu_yue")
	await get_tree().process_frame
	p._name_edit.text = "大燕"
	p._on_confirm()
	await get_tree().process_frame

	var txt := _collect_text(p._found_confirm)
	_line("E1", "文案点明「不可反悔/不可撤」", txt.contains("不可") )
	_line("E2", "文案点明势力关系下降", txt.contains("势力关系"))
	_line("E3", "文案点明投靠意向作废", txt.contains("投靠"))
	_line("E4", "文案点明覆灭结局不可重开", txt.contains("覆灭"))
	_line("E5", "文案点明国号快照", txt.contains("大燕"))
	_line("E6", "文案无「可撤销/可回退/稍后再想即可」类虚假兜底",
		not (txt.contains("可撤销") or txt.contains("可回退")))
	_p_close(p)


# ---------- F：弹窗信息是**构建时快照**，不随外部状态漂移 ----------

func _check_f_snapshot_not_live_widget() -> void:
	_prime_ready()
	var p := _make_panel()
	p.open("lu_yue")
	await get_tree().process_frame
	# 必须先定死旗号再开弹窗，否则快照取到的是默认 1，判据会误判。
	# 且判据不能写裸 contains("3")：文案里「天下 3 家势力」也含 "3"，
	# 那是 faction_relations.size() 的巧合命中，属假绿灯（判据形态必须对齐实现形态）。
	p._name_edit.text = "大燕"
	p._flag_selected = 3
	p._on_confirm()
	await get_tree().process_frame

	# 弹窗打开后把输入框与选中态全改掉，弹窗文案不应随之变化
	p._name_edit.text = "已篡改"
	p._flag_selected = 5
	await get_tree().process_frame

	var txt := _collect_text(p._found_confirm)
	_line("F1", "弹窗国号为构建时快照，不随 _name_edit 变化", txt.contains("大燕") and not txt.contains("已篡改"))
	_line("F2", "弹窗旗帜为构建时快照（含「旗帜纹样 3」且不含「旗帜纹样 5」）",
		txt.contains("旗帜纹样 3") and not txt.contains("旗帜纹样 5"))
	_line("F3", "待建参数仍是构建时快照", p._pending_found_name == "大燕" and p._pending_found_flag == 3)
	_p_close(p)


# ---------- G：连点不叠遮罩、不改待建国参数 ----------

func _check_g_double_click_no_stack() -> void:
	_prime_ready()
	var p := _make_panel()
	p.open("lu_yue")
	await get_tree().process_frame
	p._name_edit.text = "大燕"
	p._flag_selected = 2
	p._on_confirm()
	await get_tree().process_frame
	var first := p._found_confirm
	var dims := _count_sub_modal_dims(p)

	# 弹窗期间连点 3 次
	p._name_edit.text = "被改国号"
	p._flag_selected = 5
	p._on_confirm()
	p._on_confirm()
	p._on_confirm()
	await get_tree().process_frame

	_line("G1", "连点 3 次后仍只有 1 层遮罩", _count_sub_modal_dims(p) == dims and dims == 1)
	_line("G2", "连点不改待建国参数", p._pending_found_name == "大燕" and p._pending_found_flag == 2)
	_line("G3", "连点不换掉原遮罩实例", p._found_confirm == first)
	_p_close(p)


# ---------- H：关闭回调只关窗，不得建国 ----------

func _check_h_close_cb_only_closes() -> void:
	_prime_ready()
	var p := _make_panel()
	p.open("lu_yue")
	await get_tree().process_frame
	p._name_edit.text = "大燕"
	p._on_confirm()
	await get_tree().process_frame

	# 模拟点遮罩空白处（make_sub_modal 把 close_cb 接到 dim.gui_input）
	p._close_found_confirm()
	await get_tree().process_frame

	_line("H1", "遮罩关闭回调后遮罩已释放", p._found_confirm == null)
	_line("H2", "遮罩关闭回调未触发建国", GameState.is_self_rule == false)
	_line("H3", "遮罩关闭回调后国号未写入", GameState.self_rule_name == "")
	_line("H4", "遮罩关闭回调后待建参数已清空", p._pending_found_city == "" and p._pending_found_name == "")
	_p_close(p)


# ---------- I：前置不满足 / 国号为空，不得弹不可逆确认窗（不制造无效步骤） ----------

func _check_i_precondition_fail_no_modal() -> void:
	# I1：信物未齐
	_prime_ready()
	GameState.has_tiger_tally = false
	var p := _make_panel()
	p.open("lu_yue")
	await get_tree().process_frame
	p._name_edit.text = "大燕"
	p._on_confirm()
	await get_tree().process_frame
	var no_modal := p._found_confirm == null or not is_instance_valid(p._found_confirm)
	_line("I1", "信物未齐 → 不弹不可逆确认窗", no_modal)
	_line("I2", "信物未齐 → 未自立", GameState.is_self_rule == false)
	_p_close(p)

	# I3：国号为空
	_prime_ready()
	var p2 := _make_panel()
	p2.open("lu_yue")
	await get_tree().process_frame
	p2._name_edit.text = "   "
	p2._on_confirm()
	await get_tree().process_frame
	var no_modal2 := p2._found_confirm == null or not is_instance_valid(p2._found_confirm)
	_line("I3", "国号全空白 → 不弹确认窗（strip_edges 后视为空）", no_modal2)
	_line("I4", "国号全空白 → 未自立", GameState.is_self_rule == false)
	_p_close(p2)

	# I5：已加入势力（affiliation != 0）
	_prime_ready()
	GameState.affiliation = 2
	var p3 := _make_panel()
	p3.open("lu_yue")
	await get_tree().process_frame
	p3._name_edit.text = "大燕"
	p3._on_confirm()
	await get_tree().process_frame
	var no_modal3 := p3._found_confirm == null or not is_instance_valid(p3._found_confirm)
	_line("I5", "已投靠势力 → 不弹确认窗", no_modal3)
	_p_close(p3)


# ---------- 工具 ----------

func _p_close(p: SelfRulePanel) -> void:
	# 【探针夹具坑】queue_free 是**延迟**的：不在此处等一帧，下一个 _check 里的
	# _make_panel() 会在上一批节点尚未真正释放时读它们，出现
	# "Invalid access to property or key '_name_edit' on a base object of type 'previously freed'"。
	# 故释放后必须 await 一帧再返回（调用方全部在 await 上下文里，无副作用）。
	if is_instance_valid(p):
		p.queue_free()
	if is_instance_valid(_host):
		_host.queue_free()
	_panel = null
	_host = null
	await get_tree().process_frame
	await get_tree().process_frame


func _find_button(node: Node, text: String) -> Button:
	if node == null or not is_instance_valid(node):
		return null
	if node is Button and (node as Button).text == text:
		return node as Button
	for c in node.get_children():
		var r := _find_button(c, text)
		if r != null:
			return r
	return null


func _collect_text(node: Node) -> String:
	var out := ""
	if node == null or not is_instance_valid(node):
		return out
	if node is Label or node is Button:
		out += (node as Control).text + "\n"
	for c in node.get_children():
		out += _collect_text(c)
	return out


## 统计 SelfRulePanel 下 make_sub_modal 生成的**二级遮罩**层数。
## 判据用 alpha 区分两级遮罩，不能用 size：headless 下 ColorRect 的 size 可能尚未完成
## 布局，用尺寸会把外层 make_modal 的 SCRIM(0.72) 一起数进来或漏掉，判定不可靠。
## UITheme.SCRIM = a0.72（外层 make_modal）／ SCRIM_DEEP = a0.62（二层 make_sub_modal）。
func _count_sub_modal_dims(node: Node) -> int:
	if node == null or not is_instance_valid(node):
		return 0
	var n := 0
	if node is ColorRect:
		var cr := node as ColorRect
		if cr.mouse_filter == Control.MOUSE_FILTER_STOP \
				and absf(cr.color.a - 0.62) < 0.001:
			n += 1
	for c in node.get_children():
		n += _count_sub_modal_dims(c)
	return n


func _line(id: String, desc: String, ok: bool) -> void:
	_lines.append("[%s] %s %s" % [id, "PASS" if ok else "FAIL", desc])


func _write_out() -> void:
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f == null:
		return
	for s in _lines:
		f.store_line(s)
	f.store_line("TOTAL %d" % _lines.size())
	f.close()
	print("SELF_RULE_GUARD_PROBE_DONE %d" % _lines.size())
