extends RefCounted
class_name UITheme
## 全局 UI 规范（水墨描金暗色）
## ------------------------------------------------------------------
## P3-6 的基石。所有面板统一从这里取色、取字号、取容器，**不许再各自 const C_XXX**。
##
## 三条硬规矩：
##   1. 颜色只能用本文件的语义色（INK / CARD / GOLD / TEXT / DIM / GOOD / BAD / POINT / WARN …）
##   2. 字号只能用三级表（FS_TITLE / FS_HEAD / FS_BODY / FS_NOTE / FS_TINY）
##   3. 全屏面板一律走 make_modal()，"遮罩 + 居中卡片 + 标题行 + 关闭 + 滚动区" 不再手写第二遍
##
## 用法：
##   var m := UITheme.make_modal(self, "主角成长", close_panel)
##   var body: VBoxContainer = m["body"]      # 往里 add_child 即可
##   _card = m["card"]

# ================= 调色板（水墨描金暗色） =================
const INK := Color(0.09, 0.11, 0.15, 1.0)          ## 墨底 #171B26（页面/内层底）
const INK_DEEP := Color(0.06, 0.07, 0.10, 1.0)     ## 深墨（行底 / 二级容器）
const CARD := Color(0.12, 0.11, 0.09, 0.97)        ## 卡片底（棕墨）
const CARD_DEEP := Color(0.09, 0.08, 0.07, 0.96)   ## 卡片内嵌底
const GOLD := Color(0.93, 0.80, 0.45)              ## 描金亮（标题 / 强调）
const GOLD_LINE := Color(0.78, 0.64, 0.36)         ## 描金边 #C7A45C
const GOLD_DIM := Color(0.62, 0.52, 0.32)          ## 描金暗（分隔 / 弱化边）
const GOLD_FILL := Color(0.20, 0.17, 0.11, 0.98)   ## 按钮常态填充
const GOLD_HOVER := Color(0.32, 0.25, 0.12, 1.0)   ## 按钮悬停/选中
const TEXT := Color(0.92, 0.88, 0.80)              ## 正文
const DIM := Color(0.63, 0.58, 0.50)               ## 辅助 / 次要
const GOOD := Color(0.62, 0.86, 0.62)              ## 正向（增益 / 完成）
const BAD := Color(0.92, 0.54, 0.48)               ## 负向（失败 / 敌对）
const POINT := Color(0.96, 0.82, 0.40)             ## 点数 / 可分配
const WARN := Color(0.95, 0.72, 0.35)              ## 警示
const SCRIM := Color(0.02, 0.02, 0.03, 0.72)       ## 全屏遮罩
const SCRIM_DEEP := Color(0.02, 0.02, 0.03, 0.62)  ## 二级弹层遮罩

# ================= 三级字号表 =================
## 只许用这五个。原先散着 21 种字号（17~150），一律就近归位。
const FS_TITLE := 32   ## 面板标题
const FS_HEAD := 26    ## 分区标题 / 关键数值
const FS_BODY := 21    ## 正文行 / 按钮
const FS_NOTE := 18    ## 辅助说明
const FS_TINY := 16    ## 角标 / 最小注

# ================= 尺寸 =================
const CARD_MAX := Vector2(1400.0, 860.0)   ## 卡片上限（沿用现有 7 个面板的一致公式）
const CARD_MIN := Vector2(800.0, 500.0)    ## 卡片下限
const CARD_MARGIN := 40.0                  ## 视口留白
const CARD_RADIUS := 14
const ROW_RADIUS := 10
const BTN_RADIUS := 8
const CLOSE_SIZE := Vector2(64, 64)

# ================= 基础控件工厂 =================

## 统一 Label（自动居中/换行交给调用方）
static func label(text: String, size: int = FS_BODY, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


## 统一 Button（已套好描金描边与三态配色）
static func button(text: String, size: int = FS_BODY, min_size := Vector2.ZERO) -> Button:
	var b := Button.new()
	b.text = text
	if min_size != Vector2.ZERO:
		b.custom_minimum_size = min_size
	b.add_theme_font_size_override("font_size", size)
	style_button(b)
	return b


## 给任意 Button 套上描金样式（已存在的按钮也能补套）
static func style_button(b: Button) -> void:
	b.add_theme_stylebox_override("normal", btn_style(GOLD_FILL, GOLD_DIM))
	b.add_theme_stylebox_override("hover", btn_style(GOLD_HOVER, GOLD_LINE))
	b.add_theme_stylebox_override("pressed", btn_style(Color(0.44, 0.33, 0.14, 1.0), GOLD))
	b.add_theme_stylebox_override("focus", btn_style(GOLD_HOVER, GOLD_LINE))
	b.add_theme_stylebox_override("disabled", btn_style(Color(0.10, 0.09, 0.08, 0.9), Color(0.35, 0.32, 0.26, 0.7)))
	b.add_theme_color_override("font_color", TEXT)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	b.add_theme_color_override("font_pressed_color", Color(1, 0.98, 0.90, 1))
	b.add_theme_color_override("font_focus_color", Color(1, 0.98, 0.90, 1))


# ================= 样式盒 =================

## 卡片外框（墨底 + 描金边）
static func card_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = CARD
	sb.border_color = GOLD_LINE
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(CARD_RADIUS)
	sb.content_margin_left = 26.0
	sb.content_margin_right = 26.0
	sb.content_margin_top = 18.0
	sb.content_margin_bottom = 18.0
	return sb


## 卡片内嵌容器（行、侧栏）
static func inner_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = INK_DEEP
	sb.border_color = GOLD_DIM
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(ROW_RADIUS)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	return sb


## 列表行；selected=true 时用金边高亮
static func row_style(selected: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = GOLD_HOVER if selected else INK_DEEP
	sb.border_color = GOLD_LINE if selected else GOLD_DIM
	sb.set_border_width_all(2 if selected else 1)
	sb.set_corner_radius_all(ROW_RADIUS)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb


static func btn_style(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(BTN_RADIUS)
	return sb


# ================= 卡片尺寸（响应式） =================

## 卡片尺寸：沿用原 7 个面板一致的公式，视口不足时按比例缩，不溢出也不过小
static func card_size(vp: Vector2) -> Vector2:
	return Vector2(
		minf(CARD_MAX.x, maxf(CARD_MIN.x, vp.x - CARD_MARGIN)),
		minf(CARD_MAX.y, maxf(CARD_MIN.y, vp.y - CARD_MARGIN)))


# ================= 组合容器 =================

## 全屏模态：遮罩 + 居中卡片 + 标题行（含 ✕）+ 可滚动内容区
## 返回 { "dim": ColorRect, "card": PanelContainer, "body": VBoxContainer, "title": Label }
##   title：默认标题行的 Label（成就面板这类要动态改写标题的用得上）；
##          传了 head_node 时为 null。
## head_node：自定义头部（头像 + 双行标题这类）。给了它就不再生成默认标题行，
##            关闭按钮也得由它自己带 —— 见 attribute_panel / character_panel。
static func make_modal(owner: Control, title: String, close_cb: Callable = Callable(),
		head_node: Control = null) -> Dictionary:
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = SCRIM
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	owner.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.add_child(center)

	var card := PanelContainer.new()
	card.custom_minimum_size = card_size(owner.get_viewport_rect().size)
	card.add_theme_stylebox_override("panel", card_style())
	center.add_child(card)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 14)
	card.add_child(outer)

	# 头部：自定义头优先，否则生成标准标题行 + ✕
	var title_label: Label = null
	if head_node != null:
		outer.add_child(head_node)
	else:
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 16)
		var t := label(title, FS_TITLE, GOLD)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(t)
		title_label = t
		if close_cb.is_valid():
			var close := button("✕", FS_HEAD, CLOSE_SIZE)
			close.pressed.connect(close_cb)
			head.add_child(close)
		outer.add_child(head)
	outer.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)

	return { "dim": dim, "card": card, "body": body, "title": title_label }


## 二级弹层（在已有遮罩之上再叠一层，如"更换装备""确认框"）
## 返回 { "dim": ColorRect, "card": PanelContainer, "body": VBoxContainer }
static func make_sub_modal(owner: Control, title: String, close_cb: Callable,
		size := Vector2(840.0, 760.0)) -> Dictionary:
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = SCRIM_DEEP
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed:
			if close_cb.is_valid():
				close_cb.call())
	owner.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.add_child(center)

	var card := PanelContainer.new()
	card.custom_minimum_size = size
	card.add_theme_stylebox_override("panel", card_style())
	center.add_child(card)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	card.add_child(outer)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	var t := label(title, FS_HEAD, GOLD)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	if close_cb.is_valid():
		var close := button("✕", FS_BODY, Vector2(56, 52))
		close.pressed.connect(close_cb)
		head.add_child(close)
	outer.add_child(head)
	outer.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)

	return { "dim": dim, "card": card, "body": body }


## 一行「标签 + 弹性 + 按钮」的通用行（列表项、装备槽、天赋行都用它搭）
static func make_row(text: String, btn_text: String, on_pressed: Callable,
		text_size: int = FS_BODY) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	var lab := label(text, text_size)
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lab)
	var btn := button(btn_text, FS_BODY, Vector2(120, 48))
	btn.pressed.connect(on_pressed)
	row.add_child(btn)
	return row
