class_name CityGovernPanel
extends Control
## 治下城池治理面板（CityGovernPanel）
## 职责：对玩家已攻占的城池下达政令 —— 修缮城防 / 安抚民心 / 整饬军备（#66）。
##       面板只显示 CityService 算好的文案与成本，不含任何公式。
##
## 设计要点：
##   1. 动态构建（不往 tscn 堆控件），UITheme 模态 + 行底统一风格
##   2. 每次 open() 都重建指令行：政令冷却 / 资源变化后按钮状态必须实时
##   3. 点击后走 CityService.govern_city，msg 直接 toast（四层纪律）

signal closed

var _title: Label
var _status: Label
var _body: VBoxContainer
var _svc: CityService
var _city_id := ""


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()


func _build_ui() -> void:
	var m := UITheme.make_modal(self, "治 理 城 邑", close, null, UITheme.CITY_PANEL_SIZE)
	_title = m["title"]
	_body = m["body"]

	_status = UITheme.label("", UITheme.FS_BODY, UITheme.DIM)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(_status)


func close() -> void:
	visible = false
	queue_free()


## 打开面板：传入治下城池 id
func open(city_id: String) -> void:
	_city_id = city_id
	if _svc == null:
		_svc = CityService.new()
	var city := DataManager.get_city(city_id)
	_title.text = "治 理 · %s" % str(city.get("name", city_id))
	_rebuild()
	visible = true


func _rebuild() -> void:
	for c in _body.get_children():
		if c == _status:
			continue
		_body.remove_child(c)
		c.queue_free()

	var city := DataManager.get_city(_city_id)
	var morale := GameState.get_city_morale(_city_id)
	var defense := GameState.get_city_defense(_city_id)
	var quota := GameState.get_recruit_quota_bonus(_city_id)
	var alert := int(GameState.city_alert.get(_city_id, 0))
	var alert_txt := "，守军戒备 +%d" % alert if alert > 0 else ""
	_status.text = "城防 %d　民心 %d　征兵额度 +%d%s" % [defense, morale, quota, alert_txt]
	_status.visible = true

	# 收复军告警：让玩家明白「治理」不是锦上添花，而是守城的必要投入
	var claim: Dictionary = GameState.city_claims.get(_city_id, {})
	if not claim.is_empty():
		var warn := UITheme.label("⚠ %s 已起兵来夺，须早作防备。" % FactionService.faction_name(int(claim.get("faction", 0))),
			UITheme.FS_BODY, UITheme.WARN)
		warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_body.add_child(warn)

	# 民心告警：低于叛乱阈值会丢城
	var rv: Dictionary = CityService.ownership_settings().get("revolt", {})
	var threshold := int(rv.get("morale_threshold", 20))
	if morale < threshold:
		var warn2 := UITheme.label("⚠ 民心低于 %d，随时可能生变（叛乱失守）。" % threshold,
			UITheme.FS_BODY, UITheme.BAD)
		warn2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_body.add_child(warn2)

	for o in CityService.governance_orders():
		_body.add_child(_make_order_row(str(o.get("id", ""))))


## 单条政令行（抽成函数，避免 lambda 捕获循环变量的老坑）
func _make_order_row(order_id: String) -> Control:
	var o := CityService.governance_order(order_id)
	if o.is_empty():
		return Control.new()
	var cost := CityService.governance_cost(_city_id, order_id)
	var chk := _svc.can_govern(_city_id, order_id)
	var ok := bool(chk.get("ok", false))

	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	var name_l := UITheme.label(str(o.get("name", order_id)), UITheme.FS_HEAD, UITheme.GOLD)
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_l)
	var btn := UITheme.button("施 行", UITheme.FS_BODY, Vector2(120, UITheme.TOUCH_H))
	btn.disabled = not ok
	if ok:
		btn.pressed.connect(func(): _on_govern(order_id))
	head.add_child(btn)
	row.add_child(head)

	var eff := UITheme.label(CityService.governance_effect_text(order_id), UITheme.FS_BODY, UITheme.TEXT)
	eff.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(eff)

	var cost_txt := "耗费：金 %d" % int(cost.get("gold", 0))
	if int(cost.get("wood", 0)) > 0:
		cost_txt += "　木 %d" % int(cost.get("wood", 0))
	if not ok:
		cost_txt += "　（%s）" % str(chk.get("reason", "不可施行"))
	var cost_l := UITheme.label(cost_txt, UITheme.FS_NOTE,
		UITheme.DIM if ok else UITheme.BAD)
	cost_l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(cost_l)

	return UITheme.row_wrap(row)


func _on_govern(order_id: String) -> void:
	var r := _svc.govern_city(_city_id, order_id)
	EventBus.show_toast(str(r.get("msg", "")))
	if bool(r.get("ok", false)):
		_rebuild()
