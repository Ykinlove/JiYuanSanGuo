extends Control
class_name MainMenuWheel
## 圆形图标主菜单（MainMenuWheel）
## 全屏遮罩 + 中心关闭键 + 六枚环绕图标按钮。
## 只负责「展示菜单并回报玩家选了哪一项」，具体打开哪个面板由调用方决定（解耦）。
##
## 菜单项：任务中心 / 人物志 / 主角 / 成就 / 外交 / 背包 / 系统
##   —— 任务中心只是其中一项，点开后才是任务界面，不再「去掉其他按钮」。

signal selected(action: String)
signal closed

## 每项 col 是"区分七个入口"的功能色（属数据，不是配色规范），故保留在此；
## 其余底色/字色/遮罩一律走 UITheme。
const ENTRIES := [
	{ "action": "quest",   "label": "任务中心", "glyph": "役", "col": Color(0.93, 0.80, 0.45) },
	{ "action": "heroes",  "label": "人物志",   "glyph": "将", "col": Color(0.62, 0.86, 0.62) },
	{ "action": "player",  "label": "主角",     "glyph": "主", "col": Color(0.82, 0.70, 0.92) },
	{ "action": "achieve", "label": "成就",     "glyph": "勋", "col": Color(0.72, 0.86, 0.98) },
	{ "action": "diplo",   "label": "外交",     "glyph": "交", "col": Color(0.95, 0.72, 0.55) },
	{ "action": "bag",     "label": "背包",     "glyph": "囊", "col": Color(0.72, 0.78, 0.95) },
	# 【2026-09-28 用户反馈】去掉「自立」入口（7 项）；自立流程仍可经名士托付任务链触发，
	# 各场景 _on_wheel_selected 的 self_rule 分支保留为兼容死分支
	{ "action": "system",  "label": "系统",     "glyph": "系", "col": Color(0.80, 0.80, 0.82) },
]

const RADIUS_BASE := 318.0
const BTN_SIZE := 170.0
## 美术图标目录（AI 批次：六子项各一张 128×128 透明底，见 03-美术资源/tools/_menu_icon_process.py）
const ICON_DIR := "res://assets/sprites/menu_icons/"
const ICON_EXTS: Array[String] = [".png", ".webp", ".jpg"]

var _entries: Array[Button] = []   ## 动态创建的入口按钮（用于按视口重新居中）
var _close_btn: Button            ## 中心关闭键


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# 全屏遮罩：点空白处关闭
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = UITheme.SCRIM
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(func(e: InputEvent):
		if (e is InputEventMouseButton and (e as InputEventMouseButton).pressed) \
				or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed):
			close())
	add_child(dim)

	_build()

	# 中心关闭键
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.custom_minimum_size = Vector2(112, 112)
	close_btn.add_theme_font_size_override("font_size", UITheme.FS_NUM)
	UITheme.style_button(close_btn)
	# 中心关闭键是圆的（圆角 = 半径），在统一按钮样式之上单独改圆角
	var csb := UITheme.btn_style(UITheme.GOLD_FILL, UITheme.GOLD_DIM)
	csb.set_corner_radius_all(56)
	close_btn.add_theme_stylebox_override("normal", csb)
	close_btn.pressed.connect(close)
	add_child(close_btn)
	_close_btn = close_btn


## 把整盘图标定位到当前视口中心。
## 【修复】旧代码圆心写死 (960,540)、半径 318，在非 1920×1080 视口（stretch/aspect=expand
## 会随设备变宽/变高）下整盘偏上偏左，靠下/靠边的按钮（如底部「系统/自理」）会掉出
## 可视区域或压到 HUD 上点不到 —— 表现为「点击某项无响应」。改为每次打开时按真实
## 视口尺寸居中，并保证半径 + 按钮半径落在视口内。
func open() -> void:
	_center_geometry()
	visible = true


func _center_geometry() -> void:
	if _entries.is_empty():
		return
	var vp := get_viewport_rect().size
	var cx := vp.x * 0.5
	var cy := vp.y * 0.5
	var radius := RADIUS_BASE
	# 留安全边，确保整盘不被裁切（圆心到边缘距离 - 按钮半径）
	var margin := BTN_SIZE * 0.5 + 24.0
	radius = minf(radius, minf(cx, cy) - margin)
	radius = maxf(radius, 140.0)
	var n := _entries.size()
	for i in range(n):
		var ang := deg_to_rad(-90.0 + i * 360.0 / n)
		var px := cx + cos(ang) * radius
		var py := cy + sin(ang) * radius
		var btn: Button = _entries[i]
		btn.position = Vector2(px - BTN_SIZE * 0.5, py - BTN_SIZE * 0.5)
	if _close_btn != null:
		_close_btn.position = Vector2(cx - 56.0, cy - 56.0)


func _build() -> void:
	var n := ENTRIES.size()
	for i in range(n):
		var btn := _make_entry(ENTRIES[i])
		_entries.append(btn)


func _make_entry(ent: Dictionary) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(BTN_SIZE, BTN_SIZE)
	btn.size = Vector2(BTN_SIZE, BTN_SIZE)
	var sb := UITheme.btn_style(UITheme.GOLD_FILL, Color(ent["col"]))
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(30)
	sb.set_content_margin_all(6)
	btn.add_theme_stylebox_override("normal", sb)
	var hsb := UITheme.btn_style(UITheme.GOLD_HOVER, Color(ent["col"]))
	hsb.set_border_width_all(3)
	hsb.set_corner_radius_all(30)
	hsb.set_content_margin_all(6)
	btn.add_theme_stylebox_override("hover", hsb)
	btn.add_theme_stylebox_override("pressed", hsb)

	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 【美术图标】优先用 AI 图标贴图；缺图回退到原来的单字方（役/将/主…）
	var icon := _load_icon(str(ent["action"]))
	if icon != null:
		var tr := TextureRect.new()
		tr.texture = icon
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.custom_minimum_size = Vector2(104, 104)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(tr)
	else:
		var g := Label.new()
		g.text = str(ent["glyph"])
		g.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		g.add_theme_font_size_override("font_size", UITheme.FS_NUM)
		g.add_theme_color_override("font_color", Color(ent["col"]))
		g.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(g)
	var l := Label.new()
	l.text = str(ent["label"])
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", UITheme.FS_BODY)
	l.add_theme_color_override("font_color", UITheme.TEXT)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(l)
	btn.add_child(v)
	# 关键：让内容盒铺满按钮并垂直居中，否则 VBox 停在左上角，文字整体偏左
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 6
	v.offset_right = -6
	v.offset_top = 6
	v.offset_bottom = -6
	btn.pressed.connect(func(): _on_pick(str(ent["action"])))
	add_child(btn)
	return btn


func _load_icon(action: String) -> Texture2D:
	for ext in ICON_EXTS:
		var path := ICON_DIR + action + ext
		if ResourceLoader.exists(path):
			var res := load(path)
			if res is Texture2D:
				return res
	return null


func _on_pick(action: String) -> void:
	# 【修复】close() 在已关闭时静默返回，但 selected 仍无条件发射：
	# 触摸 + 模拟鼠标双事件（或快速连点）会让同一入口被触发两次。
	if not visible:
		return
	AudioManager.sfx_click()
	close()
	selected.emit(action)


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
