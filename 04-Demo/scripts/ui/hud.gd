extends Control
class_name WorldHUD
## 大地图顶部 HUD（资源栏 + 日期 + 区域 + 操作指引）
##
## 【横屏适配规则】（与 world_map.tscn 配套，改一处必须改另一处）
##   1. 本控件自身 anchors_preset = PRESET_TOP_WIDE（anchor_right = 1.0），
##      高度固定 BAR_H，宽度随视口伸缩 —— 20:9 / 21:9 机型上顶栏自动铺满。
##   2. 左侧资源区（ResourceBar）左上锚定，右侧日期/区域右上锚定（anchor = 1.0），
##      「左 + 右」双向锚定后中间自然留白，任何宽度下都不会互相压叠。
##      历史 bug：三者全部用 1920 基准的绝对 offset（30~1180 / 1040~1430 / 1440~1900），
##      资源区与日期区间有 140px 重叠区，且视口一变宽右侧就整体错位。
##   3. 所有纵向位置（offset_top/bottom）保持固定像素：横屏高度差异小，固定更稳。

const BAR_H := 92.0              ## 顶栏总高（含下方渐隐段）
const BAR_SOLID := 62.0          ## 实色段高度（资源文字所在区域）
const FADE := BAR_H - BAR_SOLID  ## 渐隐过渡段
const C_BAR := Color(0.043, 0.055, 0.078, 0.86)   ## 顶栏底色 #0B0E14
const C_ACCENT := Color(0.78, 0.64, 0.36, 0.55)   ## 描金分隔线
const C_SHADOW := Color(0, 0, 0, 0.35)

@onready var _gold: Label = $ResourceBar/GoldBox/GoldLabel
@onready var _food: Label = $ResourceBar/FoodBox/FoodLabel
@onready var _wood: Label = $ResourceBar/WoodBox/WoodLabel
@onready var _troop: Label = $ResourceBar/TroopBox/TroopLabel
@onready var _date: Label = $DateLabel
@onready var _hint: Label = $HintLabel
@onready var _region: Label = $RegionLabel

var _hint_tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	update_resources()
	if _hint:
		_hint.modulate.a = 0.0
	# 首次布局的 RESIZED 通知发生在 @onready 变量赋值之前，
	# 因此就绪后再主动执行一次响应式排版，保证日期/区域标签必然完成适配。
	_apply_responsive()


## 顶栏底板：实色段 + 渐隐段 + 一条描金分隔线。
## 用 Control 自绘而不是往场景里加 Panel —— 少一个节点，且天然跟随锚点伸缩。
func _draw() -> void:
	var w := size.x
	if w <= 0.0:
		return
	draw_rect(Rect2(0.0, 0.0, w, BAR_SOLID), C_BAR)
	# 渐隐段：逐条 2px 细带做 alpha 过渡（Compatibility 渲染器下最省的方式）
	var steps := int(FADE / 2.0)
	for i in range(steps):
		var t := float(i) / float(steps)
		var a := C_BAR.a * (1.0 - t)
		draw_rect(Rect2(0.0, BAR_SOLID + i * 2.0, w, 2.0), Color(C_BAR.r, C_BAR.g, C_BAR.b, a))
	draw_line(Vector2(0.0, BAR_SOLID), Vector2(w, BAR_SOLID), C_ACCENT, 2.0)
	draw_line(Vector2(0.0, BAR_SOLID + 2.0), Vector2(w, BAR_SOLID + 2.0), C_SHADOW, 2.0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
		_apply_responsive()


## 窄视口响应式（平板 4:3 / 16:10 等非 16:9 横屏）：
## 视口宽度不足 1800 时压缩资源条与日期/区域字号并收窄各自占位，
## 避免「左侧资源 ⇄ 中部区域名 ⇄ 右侧日期」三段互相压叠。
## 16:9 及以上（全部主流手机横屏）视口 ≥1920，走默认布局。
func _apply_responsive() -> void:
	var compact := size.x < 1800.0
	var bar := get_node_or_null("ResourceBar") as HBoxContainer
	if bar != null:
		bar.add_theme_constant_override("separation", 12 if compact else 20)
		# 资源条右边界 = 居中的区域标签左边缘 - 间距，避免两段重叠。
		# 区域标签宽度 380（normal）/ 300（compact），居中。
		var region_half := 190.0 if not compact else 150.0
		var region_left := size.x * 0.5 - region_half
		bar.offset_right = -(size.x - region_left + 20.0)   # +20 间距
		for box in bar.get_children():
			for child in (box as Control).get_children():
				if child is Label:
					(child as Label).add_theme_font_size_override("font_size", 21 if compact else 26)
	if _date != null:
		_date.add_theme_font_size_override("font_size", 20 if compact else 24)
		_date.offset_left = -560.0 if compact else -700.0
		_date.offset_right = -320.0 if compact else -340.0
	if _region != null:
		_region.add_theme_font_size_override("font_size", 20 if compact else 24)
		_region.offset_left = -150.0 if compact else -190.0
		_region.offset_right = 150.0 if compact else 190.0


## 刷新全部资源显示
func update_resources() -> void:
	_gold.text = "金钱 %d" % GameState.gold
	_food.text = "粮草 %d" % GameState.food
	_wood.text = "木材 %d" % GameState.wood
	_troop.text = "兵力 %d" % GameState.get_total_troops()
	_date.text = GameState.get_date_text()


## 左上角常驻操作指引（淡入，几秒后淡出，不长期遮挡画面）
## 显示当前游戏区域名（分区加载多区域适配）
func update_region(game_region: String) -> void:
	if _region == null:
		return
	_region.text = "区域 · %s" % RegionService.region_name(game_region)


func set_hint(text: String) -> void:
	if _hint == null or text.is_empty():
		return
	_hint.text = text
	if _hint_tween and _hint_tween.is_valid():
		_hint_tween.kill()
	_hint.modulate.a = 0.0
	_hint_tween = create_tween()
	_hint_tween.tween_property(_hint, "modulate:a", 1.0, 0.25)
	_hint_tween.tween_interval(4.0)
	_hint_tween.tween_property(_hint, "modulate:a", 0.0, 0.8)
