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
const BONE := Color(0.96, 0.92, 0.80)              ## 暖白（世界物件描边 / 摇杆观感，R3-09 入表）
const DIM := Color(0.63, 0.58, 0.50)               ## 辅助 / 次要
const GOOD := Color(0.62, 0.86, 0.62)              ## 正向（增益 / 完成）
const BAD := Color(0.92, 0.54, 0.48)               ## 负向（失败 / 敌对）
const POINT := Color(0.96, 0.82, 0.40)             ## 点数 / 可分配
const WARN := Color(0.95, 0.72, 0.35)              ## 警示
## 外交状态五色（有业务语义，别再内联）
const REL_ALLY := Color(0.72, 0.92, 0.75)          ## 同盟
const REL_FRIEND := Color(0.72, 0.86, 0.98)        ## 友好
const REL_NEUTRAL := Color(0.85, 0.82, 0.78)       ## 中立
const REL_HOSTILE := Color(0.98, 0.60, 0.55)       ## 敌对
const REL_MORTAL := Color(0.95, 0.35, 0.35)        ## 死敌
const SCRIM := Color(0.02, 0.02, 0.03, 0.72)       ## 全屏遮罩
const SCRIM_DEEP := Color(0.02, 0.02, 0.03, 0.62)  ## 二级弹层遮罩

# ================= 三级字号表 =================
## 只许用这五个。原先散着 21 种字号（17~150），一律就近归位。
const FS_TITLE := 32   ## 面板标题
const FS_HEAD := 26    ## 分区标题 / 关键数值
const FS_BODY := 21    ## 正文行 / 按钮
const FS_NOTE := 18    ## 辅助说明
const FS_TINY := 16    ## 角标 / 最小注
## 两个例外（只在"强调位"用，普通文本不许碰）：
const FS_NUM := 40         ## 大数值位（人物四维、城池城防这类一屏四个的巨字）
const FS_WATERMARK := 96   ## 立绘/头像缺图时的首字水印
const FS_TITLE_DISPLAY := 44  ## 大标题位（面板主标题，R3-10 由硬编码 44 入表）
## 世界内文字两档（大地图 marker / 世界物件标签，R3-10 收敛 17/18/20 碎档）
const FS_MARKER_NAME := 20 ## 世界名称标签（城池 / 遭遇 / NPC 名）
const FS_MARKER_NOTE := 17 ## 世界内辅助提示（操作提示 / ▲ 可交互标记）

# ================= 尺寸 =================
const CARD_MARGIN := 40.0                  ## 视口留白
const CARD_RADIUS := 14
const ROW_RADIUS := 10
const BTN_RADIUS := 8
const CLOSE_SIZE := Vector2(84, 84)   ## 【R3-04】触控目标 ≥84px 铁律，模态关闭键同步放大
const TOUCH_H := 84                   ## 【触控铁律】主操作按钮最小高度（button() 工厂内强制执行，宽度不抬）

# ================= 基础控件工厂 =================

## 统一 Label（自动居中/换行交给调用方）
## ================= 屏幕矩形（贴边 UI 的唯一坐标基准）=================
## 【实测结论 2026-09-29，别再想当然】本作是 1920×1080 + canvas_items/**expand**，
## 引擎取的是 **MIN** 缩放：视口尺寸 = 窗口 ÷ min(sx, sy)，恒 ≥ 1920×1080。
## 也就是说 **expand 永远不会裁切设计画布**，多出来的空间长在**右边和/或下边**，
## 原点固定在 (0,0)。真机实测：
##     1280×720  → VP 1920×1080（正好铺满）
##     1024×768  → VP 1920×1440（下方多出 360）
##     2340×1080 → VP 1969×1080（右边多出 49）
##     20:9 手机 → VP ≈ 2400×1080（右边多出约 480）
##
## 【旧版踩坑】早先这里按「居中裁切」反算（把可视区算成 1536×864 之类），
## 既缩小了可用区、又把贴边按钮往屏幕中间推 —— 宽屏上交互钮离右缘 700px，
## 竖屏上还会被顶到摇杆上方，正是用户报的「按钮超出屏幕之外 / 跟摇杆对不齐」。
##
## 用法：贴边控件一律按 `screen.size.x - 边距` 取右缘，不要写死 1920。
## 返回：设计坐标系下「整块屏幕」的矩形（恒 ≥ 1920×1080，原点 (0,0)）。
static func screen_rect(viewport: Node) -> Rect2:
	var sz := Vector2(1920.0, 1080.0)
	var vp := viewport.get_viewport() if viewport != null else null
	if vp != null:
		sz = Vector2(vp.get_visible_rect().size)
	return Rect2(Vector2.ZERO, Vector2(maxf(sz.x, 1920.0), maxf(sz.y, 1080.0)))


static func label(text: String, size: int = FS_BODY, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


## 统一 Button（已套好描金描边与三态配色）
## 触控高度兜底：历史上有多处按钮（对话选项 62、买卖 64、行内小钮 44-52）低于
## 84px 铁律，手指点中相邻项概率高。工厂层统一抬高，杜绝「改一处漏一处」。
static func _touch_size(v: Vector2) -> Vector2:
	if v.y < TOUCH_H:
		return Vector2(v.x, TOUCH_H)
	return v


static func button(text: String, size: int = FS_BODY, min_size := Vector2.ZERO) -> Button:
	var b := Button.new()
	b.text = text
	if min_size != Vector2.ZERO:
		b.custom_minimum_size = _touch_size(min_size)
	b.add_theme_font_size_override("font_size", size)
	style_button(b)
	# 【四十一轮】全局按键音：全工程按钮都从本工厂出，一处接线即可全覆盖
	# （此前只有战斗场景的少数按钮有音，其余点了没反馈）。
	# 注意只挂在工厂里：style_button() 可被调用多次（补套样式），挂那里会叠 N 层
	# 连接 → 一次点击播 N 声。
	# 【H1 同型】autoload 信号一律方法绑定：这里连的是 AudioManager 的方法，
	# 不捕获 self，按钮释放后连接随之失效，不叠僵尸 handler。
	b.pressed.connect(AudioManager.ui_click)
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
	# 【第五十一轮】补置灰文字色：此前只设了 disabled 的 stylebox，文字色仍回落
	# Godot 默认禁用色（暗灰），在墨底 #171B26 上几乎读不出来——「为什么置灰」
	# 这一信息本身就是玩家需要读的提示（对话条件不满足、无货可交易等）。
	b.add_theme_color_override("font_disabled_color", Color(0.62, 0.60, 0.55, 1.0))


# ================= 样式盒 =================

## 卡片外框（墨底 + 描金边 + 柔和投影——面板从背景浮起，水墨质感）
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
	sb.shadow_color = Color(0, 0, 0, 0.45)   ## 【精美】柔和投影：面板与遮罩之间拉开层次
	sb.shadow_size = 22
	sb.shadow_offset = Vector2(0, 6)
	return sb


## 卡片内嵌容器（行、侧栏）—— 与创角界面 _inner_style 同参数（16/12 边距）
static func inner_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = INK_DEEP
	sb.border_color = GOLD_DIM
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(ROW_RADIUS)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	return sb


## 列表行；selected=true 时用金边高亮 —— 与创角界面 _row_style 同参数
## （选中行暖金底 + 3px 金边 + 12 圆角，观感与创角选人/选天赋一致）
static func row_style(selected: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.13, 0.08, 0.95) if selected else INK_DEEP
	sb.border_color = GOLD_LINE if selected else GOLD_DIM
	sb.set_border_width_all(3 if selected else 1)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	return sb


static func btn_style(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(BTN_RADIUS)
	return sb


## 描金分隔线（替代素灰默认 HSeparator，标题行下的金色细线）
static func gold_separator() -> HSeparator:
	var s := HSeparator.new()
	var line := StyleBoxLine.new()
	line.color = Color(GOLD_DIM, 0.55)
	line.thickness = 1
	s.add_theme_stylebox_override("separator", line)
	return s


## 【精美】给 ScrollContainer 套水墨描金细滚动条——引擎默认滚动条粗灰抢眼
static func style_scrollbar(sc: ScrollContainer) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.22)
	bg.set_corner_radius_all(4)
	for bar: ScrollBar in [sc.get_v_scroll_bar(), sc.get_h_scroll_bar()]:
		bar.add_theme_stylebox_override("scroll", bg)
		bar.add_theme_stylebox_override("grabber", _thumb_style(Color(GOLD_DIM, 0.55)))
		bar.add_theme_stylebox_override("grabber_highlight", _thumb_style(Color(GOLD_LINE, 0.9)))
		bar.add_theme_stylebox_override("grabber_pressed", _thumb_style(GOLD))


static func _thumb_style(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(4.0)   ## 视觉宽度 8px 细条
	return sb


## 【精美】面板出现淡入（遮罩先暗下、卡片随后浮现的水墨节奏）。
## tween 绑定在 dim 自身，0.2s 自然结束，无泄漏面。
static func _fade_in(dim: ColorRect, card: PanelContainer) -> void:
	dim.modulate.a = 0.0
	card.modulate.a = 0.0
	var tw := dim.create_tween()
	tw.set_parallel(true)
	tw.tween_property(dim, "modulate:a", 1.0, 0.16)
	tw.tween_property(card, "modulate:a", 1.0, 0.22).set_delay(0.04)


## 面板进入动画（由 open() 显式重播）。
## make_modal 底部那次 _fade_in 发生在 _ready 阶段（面板还 visible=false），
## 动画早已播完才轮到 open() 显形，玩家从未见过 —— 统一改由 open() 调本函数驱动，
## 确保每次打开都看得见「遮罩先暗、卡片随后浮现」的水墨节奏。返回 tween 供调用方 kill
## （防快速重开时旧退出 tween 的 finished 把已重开的面板又关掉）。
## 【四十一轮】面板进出顺带出声：展开=卷轴上扫，收起=合拢下扫。
## 放在这里是因为所有模态面板的进出动画都走这两个函数（一处接线，全工程覆盖）。
static func modal_enter(m: Dictionary) -> Tween:
	var dim: ColorRect = m["dim"]
	var card: PanelContainer = m["card"]
	dim.modulate.a = 0.0
	card.modulate.a = 0.0
	# 【四十一轮】开合音不在这里播：本函数只有 3 个面板调用，且与面板自身
	# visible 翻转的双通道会叠成两声。统一走 make_modal 里绑的 visible 钩子。
	var tw := dim.create_tween()
	tw.set_parallel(true)
	tw.tween_property(dim, "modulate:a", 1.0, 0.16)
	tw.tween_property(card, "modulate:a", 1.0, 0.22).set_delay(0.04)
	return tw


## 面板退出动画：遮罩与卡片同步淡出，结束后回调 on_done（真正隐藏 + 发信号）。
## 反向节奏略快，收束利落。返回 tween 供调用方 kill。
static func modal_exit(m: Dictionary, on_done: Callable) -> Tween:
	var dim: ColorRect = m["dim"]
	var card: PanelContainer = m["card"]
	dim.modulate.a = 1.0
	card.modulate.a = 1.0
	# 【四十一轮】合拢音同理走 visible 钩子（见 make_modal._bind_panel_sound）
	var tw := dim.create_tween()
	tw.set_parallel(true)
	tw.tween_property(dim, "modulate:a", 0.0, 0.14)
	tw.tween_property(card, "modulate:a", 0.0, 0.18)
	if on_done.is_valid():
		tw.finished.connect(on_done)
	return tw


# ================= 卡片尺寸（响应式，与创角界面同一公式） =================

## 卡片尺寸：与创角界面（create_hero）同一比例公式 —— 至少 1200×700，
## 平时占视口 86%/88%，手机大屏上一致的饱满观感；留 CARD_MARGIN 防溢出。
static func card_size(vp: Vector2) -> Vector2:
	return Vector2(
		minf(vp.x - CARD_MARGIN, maxf(1200.0, vp.x * 0.86)),
		minf(vp.y - CARD_MARGIN, maxf(700.0, vp.y * 0.88)))

## 【2026-09-24 用户拍板】菜单面板统一尺寸 = 城内面板（PanelLayer）1040×780。
## 六菜单面板 + 城池详情 + 行商交易一律传给 make_modal 的 size 参数，
## 不再用响应式 card_size()（86% 视口在 1920 屏上太大，用户反馈「占比过大」）。
const CITY_PANEL_SIZE := Vector2(1040.0, 780.0)


# ================= 组合容器 =================

## 全屏模态：遮罩 + 居中卡片 + 标题行（含 ✕）+ 可滚动内容区
## 返回 { "dim", "card", "body", "title", "outer" }
##   body   可滚动内容区（往里 add_child）
##   outer  卡片内的根 VBox —— 要放「固定在底部、不随滚动」的东西（按钮区、状态栏）
##          就 add_child 到 outer，它会排在滚动区之后
##   title  默认标题行的 Label（成就面板这类要动态改写标题的用得上）；传了 head_node 时为 null
## head_node：自定义头部（头像 + 双行标题这类）。给了它就不再生成默认标题行，
##            关闭按钮也得由它自己带 —— 见 attribute_panel / character_panel。
## size：自定义卡片尺寸（小弹窗用，如单挑 860×640）；留空则用响应式 card_size()。
## menu_cb：【2026-09-28 用户反馈】有效时标题行 ✕ 左侧多一枚「返 回」按钮 ——
##          从轮盘菜单进来的面板用它「返回菜单」；面板自己决定回调行为（隐藏自身 + 发信号）。
static func make_modal(owner: Control, title: String, close_cb: Callable = Callable(),
		head_node: Control = null, size := Vector2.ZERO, menu_cb: Callable = Callable()) -> Dictionary:
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = SCRIM
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	owner.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.add_child(center)

	var card := PanelContainer.new()
	# owner 尚未入树时 get_viewport_rect() 不可靠，故传了 size 就不去读视口
	card.custom_minimum_size = size if size != Vector2.ZERO else card_size(owner.get_viewport_rect().size)
	card.add_theme_stylebox_override("panel", card_style())
	center.add_child(card)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 14)
	card.add_child(outer)

	# 头部：自定义头优先，否则生成标准标题行 + ✕
	# 【对齐创角】大标题用创角同款 44px 描金（旧 32px 偏小气），标题行更醒目
	var title_label: Label = null
	if head_node != null:
		outer.add_child(head_node)
	else:
		var head := HBoxContainer.new()
		head.add_theme_constant_override("separation", 16)
		var t := label(title, FS_TITLE_DISPLAY, GOLD)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# 【第五十一轮】标题居中：SIZE_EXPAND_FILL 只让标题占据剩余宽度，
		# 不设 alignment 时 Label 仍按左对齐渲染，导致除创角/属性面板（自定义头
		# 显式设了 CENTER）外的全部 make_modal 面板标题都贴左边，违反「标题居中」。
		t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		head.add_child(t)
		title_label = t
		if menu_cb.is_valid():
			var back := button("返 回", FS_HEAD, Vector2(168, CLOSE_SIZE.y))
			back.pressed.connect(menu_cb)
			head.add_child(back)
		if close_cb.is_valid():
			var close := button("✕", FS_HEAD, CLOSE_SIZE)
			close.pressed.connect(close_cb)
			head.add_child(close)
		outer.add_child(head)
	outer.add_child(gold_separator())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	style_scrollbar(scroll)
	outer.add_child(scroll)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)

	_fade_in(dim, card)
	_bind_panel_sound(owner)
	return { "dim": dim, "card": card, "body": body, "title": title_label, "outer": outer, "scroll": scroll }


## 【四十一轮】面板开合音：一处接线覆盖全部 make_modal 面板。
## 【为什么绑 owner 而不是 dim/card】父节点 visible 翻转只改子节点的
## is_visible_in_tree()，不改子节点自己的 visible 标志 —— 子节点的
## visibility_changed 根本不触发。必须绑面板（owner）自身。
## 【防重复】make_modal 可能被重建调用多次，用 meta 标记去重，否则连 N 次
## → 一次开合播 N 声。
static func _bind_panel_sound(panel: Control) -> void:
	if panel == null or panel.has_meta("ui_panel_sfx"):
		return
	panel.set_meta("ui_panel_sfx", true)
	panel.visibility_changed.connect(_on_panel_visibility.bind(panel))


static func _on_panel_visibility(panel: Control) -> void:
	if panel.visible:
		AudioManager.ui_panel_open()
	else:
		AudioManager.ui_panel_close()


## 二级弹层（在已有遮罩之上再叠一层，如"更换装备""确认框"）
## 返回 { "dim": ColorRect, "card": PanelContainer, "body": VBoxContainer }
static func make_sub_modal(owner: Control, title: String, close_cb: Callable,
		size := Vector2(840.0, 760.0)) -> Dictionary:
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = SCRIM_DEEP
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed:
			if close_cb.is_valid():
				close_cb.call())
	owner.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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
	# 【第五十一轮】二级弹层标题同样居中（与 make_modal 一致，见该函数内注释）
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_child(t)
	if close_cb.is_valid():
		var close := button("✕", FS_BODY, CLOSE_SIZE)   ## 【R3-04】二级弹层关闭键 56×52 → 84×84
		close.pressed.connect(close_cb)
		head.add_child(close)
	outer.add_child(head)
	outer.add_child(gold_separator())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	style_scrollbar(scroll)
	outer.add_child(scroll)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)

	_fade_in(dim, card)
	_bind_panel_sound(owner)
	return { "dim": dim, "card": card, "body": body, "scroll": scroll }


## 一行「标签 + 弹性 + 按钮」的通用行（列表项、装备槽、天赋行都用它搭）
## 【2026-09-24 统一】行内容包进市场同款深色圆角行（row_style），与城内市场面板观感一致
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
	return row_wrap(row)


## 把任意行容器包进市场同款深色圆角行底（六菜单面板与市场 UI 统一的基准件）
## 【精美】行悬停淡金描边反馈——连接挂在行自身信号上，行释放连接同亡，无泄漏
static func row_wrap(inner: Control) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", row_style())
	p.mouse_entered.connect(func(): p.add_theme_stylebox_override("panel", row_hover_style()))
	p.mouse_exited.connect(func(): p.add_theme_stylebox_override("panel", row_style()))
	p.add_child(inner)
	return p


## 行悬停态：底色微亮 + 描金边半透（非选中行的 hover 反馈）
static func row_hover_style() -> StyleBoxFlat:
	var sb := row_style()
	sb.bg_color = Color(0.13, 0.11, 0.08, 0.95)
	sb.border_color = Color(GOLD_LINE, 0.7)
	return sb
