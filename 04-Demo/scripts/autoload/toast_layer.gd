extends CanvasLayer
## 全局 Toast 层（ToastLayer）
## EventBus.toast 信号的唯一全局消费方：场景无关地展示所有服务层弹出的提示。
## 【B2/B4/B11 一揽子修复】此前 main_menu / create_hero / save_menu 三处场景未连接
## toast 信号，「读档失败」「创角点数拦截」「存档菜单点坏档」的提示全部发进虚空；
## 四个场景（world_map/city_scene/battle_scene/formation_editor）的本地 connect 已摘除，
## 由本层统一消费——所有场景都有消费者，且同一提示不再双显。
## 场景内部直接调自身 show_toast() 的调用点不受影响（就地提示保持原位原样式）。

const HOLD_TIME := 7.6   # 与大地图/城内就地 toast 同口径（2026-09-24 用户反馈延长后）
const FADE_TIME := 0.5

var _panel: PanelContainer
var _label: Label
var _tween: Tween


func _ready() -> void:
	layer = 100
	_build_ui()
	EventBus.toast.connect(_on_toast)


func _build_ui() -> void:
	# 全屏边距容器只负责摆放（顶部居中、两侧留白收窄行宽），不吃任何输入
	var wrap := MarginContainer.new()
	wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.add_theme_constant_override("margin_top", 120)
	wrap.add_theme_constant_override("margin_left", 280)
	wrap.add_theme_constant_override("margin_right", 280)
	add_child(wrap)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.inner_style())
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = false
	wrap.add_child(_panel)

	_label = UITheme.label("", UITheme.FS_BODY, UITheme.TEXT)
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel.add_child(_label)


func _on_toast(message: String) -> void:
	_label.text = message
	_panel.visible = true
	_panel.modulate.a = 1.0
	if _tween and _tween.is_valid():
		_tween.kill()
	# 新建补间必须写在 if 之外：写在 if 内会因前一次补间已失效而永不创建，
	# 提示文字因此永不淡出（一直糊在屏幕上）——与大地图就地 toast 同款坑位防回归。
	_tween = create_tween()
	_tween.tween_interval(HOLD_TIME)
	_tween.tween_property(_panel, "modulate:a", 0.0, FADE_TIME)
	_tween.tween_callback(func() -> void: _panel.visible = false)
