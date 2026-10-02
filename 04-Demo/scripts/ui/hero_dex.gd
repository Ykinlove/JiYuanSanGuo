extends Control
class_name HeroDex
## 人物志浏览器（HeroDex）
## 遍历 heroes6（825 人），按姓名搜索，点击某位武将 → 回调 picked(hero)，
## 由调用方打开人物详情面板（CharacterPanel）。本面板不含任何数值公式。

signal picked(hero: Dictionary)
signal closed
## 【2026-09-28 用户反馈】标题行「返 回」按钮：关面板并要求场景重开轮盘菜单
signal menu_return_requested

const MAX_ROWS := 300      ## 单次最多渲染的结果数，避免一次性建 825 个节点卡顿
## 【第五十三轮】输入去抖间隔（秒）。text_changed 在手机输入法拼拼音过程中
## 会高频触发（每上一个声母/候选词都发一次），直连 _build_list 等于
## 「每敲一下重建最多 300 个按钮」——手机上会明显卡手。
## 0.22s 短于正常打字节奏（连打也感知不到延迟），但足以把一次拼音输入的
## 十几次触发合并成一次重建。
const SEARCH_DEBOUNCE := 0.22

var _search: LineEdit
var _list: VBoxContainer
var _title: Label
var _scroll: ScrollContainer
## 待执行的搜索词与去抖计时（-1 表示当前无待处理输入）
var _pending_q: String = ""
var _debounce_left: float = -1.0


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var m := UITheme.make_modal(self, "人物志 · 群英录", close, null, UITheme.CITY_PANEL_SIZE, _on_menu_return)
	_title = m["title"]
	_scroll = m["scroll"]
	# 点遮罩也能关（保留原交互）
	m["dim"].gui_input.connect(func(e: InputEvent):
		if (e is InputEventMouseButton and (e as InputEventMouseButton).pressed) \
				or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed):
			close())

	# 搜索框固定在滚动区之上（move_child 插到分隔线之后、滚动区之前）
	_search = LineEdit.new()
	_search.placeholder_text = "输入姓名搜索（如：赵云 / 曹操）"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.custom_minimum_size = Vector2(0, 64)
	_search.add_theme_font_size_override("font_size", UITheme.FS_HEAD)
	_search.text_submitted.connect(_on_search_submit)
	_search.text_changed.connect(_on_search_changed)
	m["outer"].add_child(_search)
	m["outer"].move_child(_search, 2)

	# 列表直接用模态的滚动内容区
	_list = m["body"]
	_list.add_theme_constant_override("separation", 6)


func open() -> void:
	visible = true
	_search.text = ""
	# 重开时清掉可能残留的去抖计时：否则面板关着的那段时间里 _process 仍在跑，
	# 醒来后会用旧 _pending_q 重建一次列表，白做一遍还可能把重开时的空态覆盖掉。
	_debounce_left = -1.0
	_build_list("")
	_scroll.scroll_vertical = 0   ## 【M1】打开复位滚动


func close() -> void:
	if not visible:
		return
	visible = false
	_debounce_left = -1.0
	closed.emit()


## 「返 回」按钮：隐藏面板并通知场景重开轮盘菜单
func _on_menu_return() -> void:
	visible = false
	_debounce_left = -1.0
	menu_return_requested.emit()


func is_open() -> bool:
	return visible


func _faction_name(fid: int) -> String:
	if fid <= 0:
		return ""
	var f := DataManager.get_faction6(fid)
	if f.is_empty():
		return ""
	return str(f.get("name", ""))


## 每帧推进去抖计时。
## 【为什么要帧驱动而不是 Timer】Timer 节点在面板关闭后仍在跑，
## 回调里若访问已释放的 _list 会报错；挂在 _process 上则随面板一起停。
func _process(delta: float) -> void:
	if _debounce_left < 0.0:
		return
	_debounce_left -= delta
	if _debounce_left > 0.0:
		return
	_debounce_left = -1.0
	_build_list(_pending_q)


## text_changed：只起一个去抖计时，不立即重建
func _on_search_changed(t: String) -> void:
	_pending_q = t
	_debounce_left = SEARCH_DEBOUNCE
	# 去抖窗口内先把旧结果换成「筛选中」，否则玩家看着完全不匹配的旧列表，
	# 会以为搜索没生效（每次输入都重建 300 个按钮的另一种表现是明显卡顿）。
	# 注意用 get_child_count() 判空：_list 是 VBoxContainer（Container 节点），
	# 不是数组，**不能调 is_empty()**（那是 Array 的方法，会直接报
	# "Nonexistent function 'is_empty' in base 'VBoxContainer'"）。
	if _list.get_child_count() > 0:
		for c in _list.get_children():
			_list.remove_child(c)
			c.queue_free()
		_list.add_child(UITheme.label("筛选中…", UITheme.FS_BODY, UITheme.DIM))


## 回车提交：立刻出结果，不等去抖
func _on_search_submit(t: String) -> void:
	_debounce_left = -1.0
	_pending_q = t
	_build_list(t)


func _build_list(q: String) -> void:
	for c in _list.get_children():
		# 先摘除再释放：queue_free 帧末才生效，旧按钮本帧仍可被点第二次
		_list.remove_child(c)
		c.queue_free()
	var heroes: Array = DataManager.get_heroes6()
	var shown := 0
	for h in heroes:
		var name := str(h.get("name", ""))
		if not q.is_empty() and not name.contains(q):
			continue
		_add_row(h, name)
		shown += 1
		if shown >= MAX_ROWS:
			break
	if shown == 0:
		_list.add_child(UITheme.label("未找到「%s」相关人物。" % q, UITheme.FS_BODY, UITheme.DIM))
	else:
		_list.add_child(UITheme.label("共 %d 人（最多显示 %d）" % [shown, MAX_ROWS],
			UITheme.FS_NOTE, UITheme.DIM))


func _add_row(h: Dictionary, name: String) -> void:
	var faction := _faction_name(int(h.get("faction_id", 0)))
	# 官职：用 title_id 反查官职名，绝不把原始数字（0/5/50…）当条目显示
	var title := CharacterService.title_text(h)
	var sub := ""
	if not title.is_empty():
		sub = title
	if not faction.is_empty():
		sub = (sub + "　" if not sub.is_empty() else "") + faction
	# 市场同款圆角行底：用行样式覆盖 Button 各状态，悬停金边高亮，触控高 ≥84px
	var b := Button.new()
	b.text = name if sub.is_empty() else "%s　·　%s" % [name, sub]
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(0, 84)
	b.add_theme_font_size_override("font_size", UITheme.FS_BODY)
	b.add_theme_color_override("font_color", UITheme.TEXT)
	b.add_theme_color_override("font_hover_color", UITheme.GOLD)
	b.add_theme_color_override("font_pressed_color", UITheme.GOLD)
	b.add_theme_stylebox_override("normal", UITheme.row_style())
	b.add_theme_stylebox_override("hover", UITheme.row_style(true))
	b.add_theme_stylebox_override("pressed", UITheme.row_style(true))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(func(): _on_pick(h))
	_list.add_child(b)


func _on_pick(h: Dictionary) -> void:
	# 【修复】close() 在已关闭时静默返回，但 picked 仍无条件发射（同 main_menu_wheel）
	if not visible:
		return
	AudioManager.sfx_confirm()
	close()
	picked.emit(h)


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
