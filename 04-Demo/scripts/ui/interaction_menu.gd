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

## 设计空间裁切修正：菜单挂在被 stretch 等比放大的根 Control（设计坐标系）时置 true，
## _reposition 改夹「可见设计带」而非整张 1920×1080，避免 aspect=expand 宽屏裁底。
## 大地图菜单在 CanvasLayer（窗口空间）不需此修正（保持默认 false）。
var _design_space_clamp := false

## 【第六十六轮·用户反馈】卡片定位模式。
## 原实现一律「贴着目标显示」：目标走到屏幕左侧时，整张卡片就跑到左边，
## 用户需要扭头去找。反馈原话是「弹出的交互框在屏幕的左边，应该是原先的在中间」。
## 置 true 后卡片固定水平居中（垂直仍贴目标上方，避免挡住交互对象），
## 箭头仍指向目标，兼顾「位置稳定」与「知道在跟谁说话」。
var center_on_screen := true

## 居中模式下卡片中心所在的屏幕高度比例（0=顶 1=底）。
## 0.62 是「中央偏下」：既符合「在中间」的观感，又不压住屏幕中心一带的
## 玩家与交互对象。改这个值即可整体上下挪，不必动定位公式。
const CENTER_ANCHOR_Y := 0.62


## 由外部开关（大地图/城内各自决定要不要居中）
func set_center_on_screen(v: bool) -> void:
	center_on_screen = v

func set_design_space_clamp(v: bool) -> void:
	_design_space_clamp = v


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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
	# 指向对象的小三角（描金墨底，与卡片同色系）
	_arrow = Polygon2D.new()
	_arrow.polygon = PackedVector2Array([
		Vector2(-12, 0), Vector2(12, 0), Vector2(0, 28)
	])
	_arrow.color = Color(0.09, 0.11, 0.16, 0.94)
	add_child(_arrow)

	# 菜单卡片（水墨描金风：墨底 + 金边 + 12 圆角 + 上沿高亮描边）
	# 注：所有颜色集中在这里，便于横屏美化时一处调整。
	_bubble = PanelContainer.new()
	_bubble.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.11, 0.16, 0.96)        ## 墨底 #171B26
	sb.border_color = Color(0.78, 0.64, 0.36, 0.95)    ## 描金 #C7A45C
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(12)
	# 高光描边（上沿 1px 内嵌亮线）让卡片有金属感
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 5
	sb.shadow_offset = Vector2(0, 2)
	# 【压缩】内边距整体收一档：用户反馈「弹出的黑色长条太长」，
	# 菜单卡片 = 内边距 + 标题两行 + 分割线 + 按钮网格，四处一起收紧才有效。
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 9
	sb.content_margin_bottom = 11
	_bubble.add_theme_stylebox_override("panel", sb)
	add_child(_bubble)

	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", int(_style.get("gap", 8)))
	_bubble.add_child(_vbox)

	# 标题（对象名）+ 描金描边：菜单卡片的视觉焦点
	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 22)
	_name_label.add_theme_color_override("font_color", Color(0.98, 0.86, 0.54))
	_name_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	_name_label.add_theme_constant_override("shadow_offset_x", 1)
	_name_label.add_theme_constant_override("shadow_offset_y", 1)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(_name_label)

	# 副标题（身份/说明）
	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 15)
	_title_label.add_theme_color_override("font_color", Color(0.72, 0.76, 0.82))
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(_title_label)

	# 细分割线：让标题区与按钮区分开（视觉节奏）
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 6)
	var sep_sb := StyleBoxLine.new()
	sep_sb.color = Color(0.78, 0.64, 0.36, 0.45)
	sep_sb.thickness = 1
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
	var pos: Vector2
	if center_on_screen:
		# 【第六十六轮】固定居中：水平取屏幕中央，垂直固定在「中央偏下」
		# （卡片中心落在屏幕高度 62% 处）——玩家与目标通常在屏幕中心一带，
		# 卡片压在正中会挡住交互对象，偏下既稳定又不遮挡。
		# 箭头仍指向目标所在方向，玩家照样知道在跟谁说话。
		var vp_c: Vector2 = get_viewport_rect().size
		pos = Vector2((vp_c.x - card_size.x) * 0.5,
			vp_c.y * CENTER_ANCHOR_Y - card_size.y * 0.5)
		# 仍夹在可见区内：小屏/矮屏下不至于顶到顶栏或掉出屏幕
		pos.y = clampf(pos.y, 64.0, maxf(64.0, vp_c.y - card_size.y - 12.0))
	else:
		pos = sp + Vector2(-card_size.x * 0.5, offset_y - card_size.y)

	# 夹在可见区内：目标走到屏幕边缘时，卡片不会被切掉一半，也不会跑到屏外。
	# 【避让顶栏】顶部最小 y 抬到 64：贴着画面上沿的 NPC 弹菜单时，
	# 卡片不再盖住顶栏的金钱/粮草/木材/兵力资源条（0..53px）。
	# 【设计空间裁切修正】菜单挂被 stretch 等比放大的根 Control（设计坐标系）时，
	# aspect=expand 会把设计图的上/下（宽屏）或左/右（竖屏）裁掉；直接夹 1920×1080
	# 会让卡片落进裁切带而「超屏」。改按视口实际像素与设计分辨率反算「可见设计带」
	# 再夹，宽屏下也不被裁底（set_design_space_clamp(true) 时生效；大地图走 CanvasLayer 不需）。
	var margin_x := 12.0
	var margin_top := 64.0
	var bx0 := margin_x
	var by0 := margin_top
	var bx1 := get_viewport_rect().size.x - card_size.x - margin_x
	var by1 := get_viewport_rect().size.y - card_size.y - 12.0
	if _design_space_clamp:
		var win: Vector2 = get_viewport_rect().size
		var sc := maxf(win.x / 1920.0, win.y / 1080.0)
		var vis_w := 1920.0 / sc
		var vis_h := 1080.0 / sc
		var ox := (1920.0 - vis_w) * 0.5
		var oy := (1080.0 - vis_h) * 0.5
		bx0 = ox + margin_x
		by0 = oy + margin_top
		bx1 = ox + vis_w - card_size.x - margin_x
		by1 = oy + vis_h - card_size.y - 12.0
	pos.x = clampf(pos.x, bx0, maxf(bx0, bx1))
	pos.y = clampf(pos.y, by0, maxf(by0, by1))

	_bubble.position = pos
	_arrow.position = Vector2(clampf(sp.x, bx0, bx1), pos.y + card_size.y)


# ------------------------------------------------------------------
# 选项生成
# ------------------------------------------------------------------

## 按规则匹配出该对象应显示的选项 key 列表
func resolve_items(target: Dictionary) -> Array[String]:
	var ttype := str(target.get("type", "npc"))
	var tags: Array = target.get("tags", [])

	# 【显式 items 优先】target 自带 items（如城内 NPC 由代码按 npc_type 决定
	# 「交谈/交易」）时直接用，不再走 rules 匹配 —— 大地图 target 无此字段不受影响。
	if target.has("items"):
		var explicit: Array[String] = []
		for k in target.get("items", []):
			explicit.append(str(k))
		var valid_explicit: Array[String] = []
		for k in explicit:
			if _actions.has(k):
				valid_explicit.append(k)
		if not valid_explicit.is_empty():
			return valid_explicit

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
	_flow.add_theme_constant_override("h_separation", 6)
	_flow.add_theme_constant_override("v_separation", 6)
	_vbox.add_child(_flow)
	return _flow


func _make_button(key: String) -> Button:
	var a: Dictionary = _actions.get(key, {})
	var btn := Button.new()
	btn.text = str(a.get("label", key))
	btn.custom_minimum_size = Vector2(
		float(_style.get("item_min_width", 146)),
		float(_style.get("item_height", 50)))
	btn.add_theme_font_size_override("font_size", 21)

	var tint := Color(str(a.get("color", "#7A8CA0")))

	# 用 StyleBox 做出「描边 + 半透明底」的选项质感，并区分可用/置灰。
	# 描边 + 阴影让按钮在「贴着对象的紧凑菜单」里也能被一眼分辨。
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(tint.r * 0.30, tint.g * 0.30, tint.b * 0.30, 0.95)
	normal.border_color = tint
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(10)
	normal.content_margin_left = 12
	normal.content_margin_right = 12
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(tint.r * 0.58, tint.g * 0.58, tint.b * 0.58, 1.0)
	hover.border_color = Color(1.0, 0.96, 0.82, 1.0)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = tint
	pressed.border_color = Color(1.0, 0.96, 0.82, 1.0)
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(0.18, 0.19, 0.22, 0.9)
	disabled.border_color = Color(0.38, 0.4, 0.44)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_stylebox_override("disabled", disabled)
	btn.add_theme_color_override("font_color", Color(0.97, 0.95, 0.88))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 0.97, 0.85))
	btn.add_theme_color_override("font_pressed_color", Color(0.12, 0.10, 0.07))
	btn.add_theme_color_override("font_disabled_color", Color(0.55, 0.57, 0.62))

	# 条件校验
	var reason := _check_availability(key)
	if not reason.is_empty():
		btn.disabled = true
		btn.tooltip_text = reason

	# 【第五十二轮·触控铁律】抬起触控高度 + 补点击音。
	# ① 高度：数据表 item_height=50（旧注释写「触摸目标 ≥ 56dp」，
	#    但 50 < 56，本身就没达标；更别说全工程铁律是 UITheme.TOUCH_H=84），
	#    这个菜单是「走近 NPC 弹出的第一手交互」，手指最容易误触相邻项。
	#    走 UITheme._touch_size() 同款兜底：按传入值抬到 TOUCH_H。
	# ② 点击音：本按钮是裸 Button.new()，绕过了 UITheme 工厂（工厂内置
	#    AudioManager.ui_click），此前点了没有任何声音反馈。
	# 保留原有的按 action 着色样式（这是菜单的视觉识别，不能被工厂描金覆盖）。
	btn.custom_minimum_size.y = UITheme.TOUCH_H
	# 【H1 同型】方法绑定，不捕获 self——菜单销毁后连接随之失效，不叠僵尸 handler
	btn.pressed.connect(AudioManager.ui_click)
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
