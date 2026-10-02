extends CanvasLayer
## 全局 Toast 层（ToastLayer）
## EventBus.toast 信号的唯一全局消费方：场景无关地展示所有服务层弹出的提示。
##
## 【2026-09-27 竖排 bug 重写】旧实现给 Label 开 AUTOWRAP_WORD_SMART 且不定宽——
## 中文里**每个字都是可断行点**，带 autowrap 的 Label 最小宽度就是最长的不可断单元 ≈ 1 个字，
## 于是 PanelContainer 收缩成一个字宽，提示变成一列竖字、超出屏幕外。
## 正解：先按「不换行」量出文本自然宽度——
##   窄于上限 → 面板随内容收缩（短提示不拖一条大横幅）；
##   超过上限 → 封顶并开启换行（长提示横向多行，绝不竖排）。
## 时长按内容长度自适应 3~5 秒（2026-09-27 用户需求：太长看不完、太短干等）。
## 场景内部原来自带 show_toast() 的调用点也已统一转发到本层（杜绝四处样式漂移）。
##
## 【第五十一轮·多 toast 队列】旧实现是**单 Label + 单 Tween + 单 Panel**：
## 新提示直接改写同一个 Label 的 text 并 kill 掉上一个 Tween，于是
## 「后一条把前一条顶掉」——story_director.gd 一次章节结算就连发两条
## （【史官】终 + 主线推进），玩家只读得到最后一条，前面那条白弹。
## 改为：每条提示一个独立 Panel 实例，VBox 纵向堆叠、各自独立淡出，
## 互不打断。超过 MAX_VISIBLE 条时挤掉最旧的一条（防刷屏糊屏）。

const FADE_TIME := 0.4
## 提示盒的最大行宽：超过就换行。1920 横屏下约六成屏宽，
## 手机窄屏按视口比例再收（_max_width() 里动态夹取）。
const MAX_LINE_WIDTH := 1150.0
## 内边距：文本宽 → 面板宽的余量（与 inner_style 的 content margin 呼应）
const PAD_X := 48.0
## 同时最多显示几条：再多就挤掉最旧的（玩家读不过来也是信息丢失）
const MAX_VISIBLE := 4
## 两条提示之间的间距
const STACK_GAP := 10.0

## 存活中的提示：{panel: PanelContainer, tween: Tween}
var _live: Array[Dictionary] = []
var _stack: VBoxContainer


func _ready() -> void:
	layer = 100
	_build_ui()
	EventBus.toast.connect(_on_toast)


func _build_ui() -> void:
	# 全屏边距容器只负责摆放（顶部居中，避开顶栏资源条），不吃任何输入
	var wrap := MarginContainer.new()
	wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_theme_constant_override("margin_top", 104)
	wrap.add_theme_constant_override("margin_left", 40)
	wrap.add_theme_constant_override("margin_right", 40)
	add_child(wrap)

	# 【第五十一轮】VBox 纵向堆叠多条提示；旧版这里直接放单个 Panel，
	# 导致后一条覆盖前一条（story_director 一次结算连发两条，玩家只看到一条）。
	_stack = VBoxContainer.new()
	_stack.name = "Stack"
	_stack.alignment = BoxContainer.ALIGNMENT_BEGIN
	_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stack.add_theme_constant_override("separation", int(STACK_GAP))
	wrap.add_child(_stack)


## 为一条提示新建独立面板（不换行/换行判定沿用旧逻辑，只是换成按条构建）
func _make_entry(message: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITheme.inner_style())
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.modulate.a = 1.0

	var label := UITheme.label(message, UITheme.FS_BODY, UITheme.TEXT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(label)

	# 先按「不换行」量自然宽度：拿不到字体（极端情况）就退回固定宽，宁可宽不可竖
	var natural := -1.0
	var font := label.get_theme_font("font")
	var fsize := label.get_theme_font_size("font_size")
	if font != null:
		natural = float(font.get_string_size(
			message, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fsize).x)
	var cap := _max_width()
	if natural >= 0.0 and natural < cap:
		# 短提示：关掉换行、清掉最小宽约束 → 面板随内容收缩，水平居中
		label.autowrap_mode = TextServer.AUTOWRAP_OFF
		label.custom_minimum_size = Vector2.ZERO
	else:
		# 长提示：封顶换行 → 横向多行，绝不竖排
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(cap - PAD_X, 0.0)
	panel.reset_size()   # 让 PanelContainer 按新文本重新收缩，别沿用上一次的尺寸
	return panel


## 本帧视口下的最大行宽：小屏按比例收，最少保 480（再窄可读性就没了）
func _max_width() -> float:
	var vw := get_viewport().get_visible_rect().size.x
	return maxf(480.0, minf(MAX_LINE_WIDTH, vw - 120.0))


## 时长按内容长度自适应 3~5 秒：12 字内 3 秒封底，每多 8 字 +0.25 秒，5 秒封顶
func _hold_time(message: String) -> float:
	return clampf(3.0 + float(maxi(0, message.length() - 12)) / 8.0 * 0.25, 3.0, 5.0)


func _on_toast(message: String) -> void:
	# 超过上限：挤掉最旧的一条（连点/批量结算时防糊屏）。
	# 注意是「立刻移除」而非等它淡出——玩家已经读不到了，继续占位只会挡住新的。
	while _live.size() >= MAX_VISIBLE:
		_drop_oldest()

	var panel := _make_entry(message)
	_stack.add_child(panel)

	# 每条提示一个独立 Tween：到点各自淡出、各自移除，互不 kill 对方。
	var tw := create_tween()
	tw.tween_interval(_hold_time(message))
	tw.tween_property(panel, "modulate:a", 0.0, FADE_TIME)
	tw.tween_callback(func() -> void: _retire(panel))
	_live.append({"panel": panel, "tween": tw})


## 移除最旧的一条（连同其 Tween）
func _drop_oldest() -> void:
	if _live.is_empty():
		return
	var first: Dictionary = _live[0]
	_live.remove_at(0)
	var p: PanelContainer = first["panel"]
	var t: Tween = first["tween"]
	if t != null and t.is_valid():
		t.kill()
	if is_instance_valid(p):
		p.queue_free()


## 自然消亡（淡出结束）：从存活表摘除并释放。
## 线性扫 _live 找到该面板后 remove_at，避免回调里重复删同一条。
func _retire(panel: PanelContainer) -> void:
	for i in range(_live.size()):
		var entry: Dictionary = _live[i]
		if entry["panel"] == panel:
			_live.remove_at(i)
			break
	if is_instance_valid(panel):
		panel.queue_free()
