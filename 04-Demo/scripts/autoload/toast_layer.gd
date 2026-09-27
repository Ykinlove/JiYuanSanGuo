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

const FADE_TIME := 0.4
## 提示盒的最大行宽：超过就换行。1920 横屏下约六成屏宽，
## 手机窄屏按视口比例再收（_max_width() 里动态夹取）。
const MAX_LINE_WIDTH := 1150.0
## 内边距：文本宽 → 面板宽的余量（与 inner_style 的 content margin 呼应）
const PAD_X := 48.0

var _panel: PanelContainer
var _label: Label
var _tween: Tween


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

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.inner_style())
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	wrap.add_child(_panel)

	_label = UITheme.label("", UITheme.FS_BODY, UITheme.TEXT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel.add_child(_label)


## 本帧视口下的最大行宽：小屏按比例收，最少保 480（再窄可读性就没了）
func _max_width() -> float:
	var vw := get_viewport().get_visible_rect().size.x
	return maxf(480.0, minf(MAX_LINE_WIDTH, vw - 120.0))


## 时长按内容长度自适应 3~5 秒：12 字内 3 秒封底，每多 8 字 +0.25 秒，5 秒封顶
func _hold_time(message: String) -> float:
	return clampf(3.0 + float(maxi(0, message.length() - 12)) / 8.0 * 0.25, 3.0, 5.0)


func _on_toast(message: String) -> void:
	_label.text = message
	var font := _label.get_theme_font("font")
	var fsize := _label.get_theme_font_size("font_size")
	# 先按「不换行」量自然宽度：拿不到字体（极端情况）就退回固定宽，宁可宽不可竖
	var natural := -1.0
	if font != null:
		natural = float(font.get_string_size(message, HORIZONTAL_ALIGNMENT_LEFT, -1.0, fsize).x)
	var cap := _max_width()
	if natural >= 0.0 and natural < cap:
		# 短提示：关掉换行、清掉最小宽约束 → 面板随内容收缩，水平居中
		_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		_label.custom_minimum_size = Vector2.ZERO
	else:
		# 长提示：封顶换行 → 横向多行，绝不竖排
		_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_label.custom_minimum_size = Vector2(cap - PAD_X, 0.0)
	_panel.visible = true
	_panel.modulate.a = 1.0
	_panel.reset_size()   # 让 PanelContainer 按新文本重新收缩，别沿用上一次的尺寸
	if _tween and _tween.is_valid():
		_tween.kill()
	# 新建补间必须写在 if 之外：写在 if 内会因前一次补间已失效而永不创建，
	# 提示文字因此永不淡出（一直糊在屏幕上）——与大地图就地 toast 同款坑位防回归。
	_tween = create_tween()
	_tween.tween_interval(_hold_time(message))
	_tween.tween_property(_panel, "modulate:a", 0.0, FADE_TIME)
	_tween.tween_callback(func() -> void: _panel.visible = false)
