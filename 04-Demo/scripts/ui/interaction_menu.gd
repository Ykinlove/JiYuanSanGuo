extends Control
class_name InteractionMenu
## 贴脸交互菜单（InteractionMenu）
## ------------------------------------------------------------------
## 设计意图：玩家**靠近** NPC / 城池 / 关隘时，在对象**旁边**弹出交互选项菜单，
## 选项按对象类型与标签动态生成（对话 / 交易 / 招募 / 查看详情 / 进入 …）。
## 远离时自动消失。这样玩家不用记「哪个键是干嘛的」，一切交互都从「走近 → 选」开始。
##
## 数据驱动：选项规则全部在 `assets/data/interaction_menu.json` 的 rules 里，
## 改配置即可增删选项，不需要动这个脚本。
##
## 与旧方案的区别：旧方案是屏幕右下角一个固定的「进入」按钮，
## 含义随目标变化（对话/进入/交涉），玩家看不出来能做什么。
## 现在改成贴着对象弹出的多选项菜单 —— 选项即能力，一眼可见。
## ------------------------------------------------------------------

signal action_chosen(action: String, target: Dictionary)

const MENU_CFG_KEY := "menu_style"

## 世界坐标 → 屏幕坐标用的相机
var _camera: Camera2D

## 配置（从 JSON 读入）
var _cfg: Dictionary = {}
var _actions: Dictionary = {}
var _rules: Array = []
var _defaults: Dictionary = {}
var _style: Dictionary = {}

## 当前状态
var _target: Dictionary = {}
var _target_world_pos: Vector2 = Vector2.ZERO
var _is_open := false

## 节点引用（动态创建）
var _bubble: PanelContainer
var _vbox: VBoxContainer
var _name_label: Label
var _title_label: Label
var _arrow: Polygon2D

## 交互半径（由外部与对象各自配置的和决定）
var _radius := 118.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_load_config()
	_build_visual()


# ------------------------------------------------------------------
# 配置
# ------------------------------------------------------------------

func _load_config() -> void:
	_cfg = DataManager.get_record("interaction_menu", "root")
	if _cfg.is_empty():
		push_warning("[InteractionMenu] interaction_menu.json 未加载，使用内置兜底")
		_cfg = {}
	_style = _cfg.get("menu_style", {})
	_actions = _cfg.get("actions", {})
	_rules = _cfg.get("rules", [])
	_defaults = _cfg.get("defaults", {})
	_radius = float(_style.get("radius", 118.0))


# ------------------------------------------------------------------
# 视觉构建
# ------------------------------------------------------------------

func _build_visual() -> void:
	# 指向对象的小三角
	_arrow = Polygon2D.new()
	_arrow.polygon = PackedVector2Array([
		Vector2(-11, 0), Vector2(11, 0), Vector2(0, 26)
	])
	_arrow.color = Color(0.09, 0.11, 0.16, 0.93)
	add_child(_arrow)

	# 菜单卡片
	_bubble = PanelContainer.new()
	_bubble.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.11, 0.16, 0.94)
	sb.border_color = Color(0.78, 0.64, 0.36, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 10
	sb.content_margin_bottom = 12
	_bubble.add_theme_stylebox_override("panel", sb)
	add_child(_bubble)

	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", int(_style.get("gap", 10)))
	_bubble.add_child(_vbox)

	# 标题（对象名）
	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 22)
	_name_label.add_theme_color_override("font_color", Color(0.96, 0.84, 0.52))
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(_name_label)

	# 副标题（身份/说明）
	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 16)
	_title_label.add_theme_color_override("font_color", Color(0.68, 0.72, 0.78))
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(_title_label)

	# 分隔线
	var sep := HSeparator.new()
	var sep_sb := StyleBoxFlat.new()
	sep_sb.bg_color = Color(0.78, 0.64, 0.36, 0.35)
	sep_sb.content_margin_top = 4
	sep_sb.content_margin_bottom = 4
	sep.add_theme_stylebox_override("separator", sep_sb)
	_vbox.add_child(sep)

	set_open(false)


## 世界坐标 → 屏幕坐标
func _world_to_screen(world: Vector2) -> Vector2:
	if _camera == null:
		return world
	# 屏幕坐标 = (世界坐标 - 相机中心) * 缩放 + 视口中心
	var vp := get_viewport_rect().size
	return (world - _camera.global_position) * _camera.zoom + vp * 0.5


func set_camera(cam: Camera2D) -> void:
	_camera = cam


# ------------------------------------------------------------------
# 对外接口
# ------------------------------------------------------------------

## 显示交互菜单
## target 需含：type（npc/city/village/pass/ruin）、name、可选 tags[]、data{}
## world_pos：对象在世界里的位置（菜单贴着它显示）
func show_for(target: Dictionary, world_pos: Vector2) -> void:
	if target.is_empty():
		hide_menu()
		return

	# 同一个目标重复调用：只更新位置，不重建按钮（避免闪烁与丢失点击）
	var same := _is_open \
		and str(_target.get("type", "")) == str(target.get("type", "")) \
		and str(_target.get("id", "")) == str(target.get("id", ""))

	_target = target
	_target_world_pos = world_pos

	if not same:
		_rebuild_items()
		set_open(true)

	_reposition()
	_arrow.visible = true


## 隐藏菜单
func hide_menu() -> void:
	if not _is_open:
		return
	_target = {}
	set_open(false)


func is_open() -> bool:
	return _is_open


func get_target() -> Dictionary:
	return _target


func _set_open_state(v: bool) -> void:
	_is_open = v


func set_open(v: bool) -> void:
	_set_open_state(v)
	_bubble.visible = v
	_arrow.visible = v
	visible = true   # 控件本身常驻，由子节点控制显隐
	if v:
		_bubble.modulate.a = 0.0
		var tw := create_tween()
		tw.tween_property(_bubble, "modulate:a", 1.0,
			float(_style.get("appear_time", 0.14)))


func _process(_delta: float) -> void:
	if _is_open and _camera != null:
		_reposition()


## 让菜单贴在目标旁边
func _reposition() -> void:
	var sp := _world_to_screen(_target_world_pos)
	var offset_y := float(_style.get("offset_y", -74))
	# 卡片以目标上方为中心
	var card_size := _bubble.get_combined_minimum_size()
	var pos := sp + Vector2(-card_size.x * 0.5, offset_y - card_size.y)

	# 夹在视口内：目标走到屏幕边缘时，卡片不会被切掉一半，
	# 也不会跑到屏幕外去（玩家表现为「菜单错位 / 点不到选项」）。
	var vp := get_viewport_rect().size
	var margin := 12.0
	pos.x = clampf(pos.x, margin, maxf(margin, vp.x - card_size.x - margin))
	pos.y = clampf(pos.y, margin, maxf(margin, vp.y - card_size.y - margin))

	_bubble.position = pos
	_arrow.position = Vector2(clampf(sp.x, margin, vp.x - margin), pos.y + card_size.y)


# ------------------------------------------------------------------
# 选项生成
# ------------------------------------------------------------------

## 按规则匹配出该对象应显示的选项 key 列表
func resolve_items(target: Dictionary) -> Array[String]:
	var ttype := str(target.get("type", "npc"))
	var tags: Array = target.get("tags", [])

	var out: Array[String] = []
	for rule in _rules:
		var m: Dictionary = rule.get("match", {})
		if str(m.get("target_type", "")) != ttype:
			continue
		var need: Array = m.get("tags_all", [])
		var all_have := true
		for t in need:
			if not tags.has(t):
				all_have = false
				break
		if not all_have:
			continue
		for k in rule.get("items", []):
			out.append(str(k))
		break   # 第一条命中即用

	# 规则没匹配到 → 用 defaults
	if out.is_empty():
		for k in _defaults.get(ttype, ["info"]):
			out.append(str(k))

	# 过滤掉配置里不存在的 action
	var valid: Array[String] = []
	for k in out:
		if _actions.has(k):
			valid.append(k)
	return valid


func _rebuild_items() -> void:
	# 清掉除标题/副标题/分隔线以外的旧按钮。
	# 【必须 remove_child 后再 free】queue_free 是「本帧末才释放」的延迟操作，
	# 若只 queue_free，旧按钮在本帧剩余时间里仍挂在容器上：
	#   1) GridContainer 的最小尺寸按「新旧两套按钮」算 → 菜单当帧突然变大再缩回（闪跳）；
	#   2) 旧按钮仍可被点击 → 同一次点击可能命中两个重复选项，表现为「交互被触发两次」。
	for c in _vbox.get_children():
		if c is Button:
			_vbox.remove_child(c)
			c.queue_free()

	_name_label.text = str(_target.get("name", ""))
	_title_label.text = str(_target.get("title", ""))
	_title_label.visible = not _title_label.text.is_empty()

	var keys := resolve_items(_target)
	var max_cols := int(_style.get("max_columns", 2))
	# 选项 ≤2 时横排一行，更贴合"贴着对象"的紧凑感
	var cols := clampi(keys.size(), 1, max_cols)

	var flow := _get_or_make_flow(cols)
	for k in keys:
		flow.add_child(_make_button(k))


var _flow: GridContainer

func _get_or_make_flow(cols: int) -> GridContainer:
	if _flow != null and is_instance_valid(_flow):
		_flow.columns = cols
		# 清空旧内容：理由同 _rebuild_items —— 必须先摘除再释放，
		# 否则旧按钮与新按钮同帧共存，容器里会出现两套重复选项。
		for c in _flow.get_children():
			_flow.remove_child(c)
			c.queue_free()
		return _flow
	_flow = GridContainer.new()
	_flow.columns = cols
	_flow.add_theme_constant_override("h_separation", 8)
	_flow.add_theme_constant_override("v_separation", 8)
	_vbox.add_child(_flow)
	return _flow


func _make_button(key: String) -> Button:
	var a: Dictionary = _actions.get(key, {})
	var btn := Button.new()
	btn.text = str(a.get("label", key))
	btn.custom_minimum_size = Vector2(
		float(_style.get("item_min_width", 156)),
		float(_style.get("item_height", 58)))
	btn.add_theme_font_size_override("font_size", 23)

	var tint := Color(str(a.get("color", "#7A8CA0")))

	# 用 StyleBox 做出「描边 + 半透明底」的选项质感，并区分可用/置灰
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(tint.r * 0.28, tint.g * 0.28, tint.b * 0.28, 0.95)
	normal.border_color = tint
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(8)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(tint.r * 0.55, tint.g * 0.55, tint.b * 0.55, 1.0)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = tint
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(0.18, 0.19, 0.22, 0.9)
	disabled.border_color = Color(0.38, 0.4, 0.44)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_stylebox_override("disabled", disabled)
	btn.add_theme_color_override("font_color", Color(0.96, 0.97, 1.0))
	btn.add_theme_color_override("font_disabled_color", Color(0.55, 0.57, 0.62))

	# 条件校验
	var reason := _check_availability(key)
	if not reason.is_empty():
		btn.disabled = true
		btn.tooltip_text = reason

	btn.pressed.connect(_on_item_pressed.bind(key))
	return btn


## 返回空串表示可用，否则返回不可用原因
func _check_availability(key: String) -> String:
	var data: Dictionary = _target.get("data", {})
	match key:
		"recruit":
			var cost := int(data.get("recruit_cost", 0))
			if cost > 0 and GameState.gold < cost:
				return "需金钱 %d（现有 %d）" % [cost, GameState.gold]
			var need_fame := int(data.get("recruit_fame", 0))
			if need_fame > 0 and GameState.fame < need_fame:
				return "需名声 %d（现有 %d）" % [need_fame, GameState.fame]
		"trade":
			if GameState.gold < 10:
				return "金钱不足"
		"gift":
			if not _has_any_gift():
				return "没有可赠之物"
		"attack":
			if GameState.troops.is_empty():
				return "麾下无兵"
	return ""


## 背包里是否有可赠之物：
## 遗留 items.json 的 kind=="gift"，或任意 items6 物品（int id 可解析且查得到）。
## 注意：GameState 没有名为 items 的变量（背包叫 inventory），此前误用导致靠近 NPC 即崩溃。
func _has_any_gift() -> bool:
	for raw in GameState.inventory.keys():
		var key := str(raw)
		var it := DataManager.get_item(key)
		if str(it.get("kind", "")) == "gift":
			return true
		if key.is_valid_int() and not DataManager.get_item6(int(key)).is_empty():
			return true
	return false


func _on_item_pressed(key: String) -> void:
	# 【幂等保护】一次点击只允许触发一个选项。
	# 触摸/鼠标双事件（emulate_touch_from_mouse）或同帧残留按钮都可能让 pressed
	# 触发多次；菜单收起后 _is_open 为 false，后续重复触发在此被直接丢弃，
	# 从根上杜绝「点一次交互，对话/进城被触发两次」。
	if not _is_open:
		return
	AudioManager.sfx_confirm()
	var t := _target.duplicate(true)
	# 选中后立刻收起菜单，把画面让给后续界面（对话/城池等）
	hide_menu()
	action_chosen.emit(key, t)
