extends Control
class_name WorldHUD
## 大地图顶部 HUD（资源栏 + 日期 + 区域 + 操作指引）
##
## 【横屏适配规则】（与 world_map.tscn 配套，改一处必须改另一处）
##   1. 本控件自身 anchors_preset = PRESET_TOP_WIDE（anchor_right = 1.0），
##      高度固定 BAR_H，宽度随视口伸缩 —— 20:9 / 21:9 机型上顶栏自动铺满。
##   2. 【2026-09-28 二次反馈】资源条右端收窄让位：右上「≡」菜单按钮占视口右缘
##      -170~-24 区间，资源条右边界收到 -186，日期文字不再被菜单按钮压住。
##      四个资源盒各占固定最小宽；日期/区域在条内右端，由弹性空隙（Spacer）推向右侧。
##   3. 所有纵向位置（offset_top/bottom）保持固定像素：横屏高度差异小，固定更稳。

const BAR_H := 92.0              ## 顶栏总高（含下方渐隐段）
const BAR_SOLID := 62.0          ## 实色段高度（资源文字所在区域）
const FADE := BAR_H - BAR_SOLID  ## 渐隐过渡段
## 【2026-09-28 用户反馈】顶栏底色调和：墨底加 12% 透明度，地图隐约透出，
## 资源图标抠掉白底后与顶栏融为一体，不再「图标白块 + 纯黑条」两张皮。
const C_BAR := Color(UITheme.INK, 0.88)
const C_ACCENT := UITheme.GOLD_LINE               ## 描金分隔线
const C_SHADOW := Color(0, 0, 0, 0.35)            ## 纯黑阴影叠层，非主题色

@onready var _gold: Label = $ResourceBar/GoldBox/GoldLabel
@onready var _food: Label = $ResourceBar/FoodBox/FoodLabel
@onready var _wood: Label = $ResourceBar/WoodBox/WoodLabel
@onready var _troop: Label = $ResourceBar/TroopBox/TroopLabel
## 【2026-09-28】日期/区域并入资源条右端（弹性空隙推开）
## 【二次反馈】资源条右端让位菜单按钮：底板与文字统一收到 -186
const BAR_RIGHT_MARGIN := 186.0  ## 右侧让位宽度（≡ 菜单按钮区 -170~-24 + 16px 间隙）
@onready var _date: Label = $ResourceBar/DateLabel
@onready var _hint: Label = $HintLabel
@onready var _region: Label = $ResourceBar/RegionLabel

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
## 右端收到 BAR_RIGHT_MARGIN，不延伸到「≡」菜单按钮底下。
func _draw() -> void:
	var w := size.x - BAR_RIGHT_MARGIN
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


## 响应式（平板 4:3 / 16:10 等非 16:9 横屏）：
## 【2026-09-28 二次反馈】资源条右端收窄到 -186，给右上「≡」菜单按钮
## （ActionButtons 占 -170~-24）让位，日期不再与其重叠；四项资源盒
## 各占 210px（紧凑态 170px）不再挤压；日期/区域在条内右端（弹性空隙推开）。
func _apply_responsive() -> void:
	var compact := size.x < 1800.0
	var bar := get_node_or_null("ResourceBar") as HBoxContainer
	if bar != null:
		bar.add_theme_constant_override("separation", 12 if compact else 36)
		bar.offset_right = -186.0
		for box in bar.get_children():
			var c := box as Control
			if c == null:
				continue
			var n := str(c.name)
			if n.begins_with("Gold") or n.begins_with("Food") \
					or n.begins_with("Wood") or n.begins_with("Troop"):
				c.custom_minimum_size.x = 170.0 if compact else 210.0
				for child in c.get_children():
					if child is Label:
						(child as Label).add_theme_font_size_override("font_size",
							UITheme.FS_BODY if compact else UITheme.FS_HEAD)
	if _date != null:
		_date.add_theme_font_size_override("font_size", UITheme.FS_BODY if compact else UITheme.FS_HEAD)
	if _region != null:
		_region.add_theme_font_size_override("font_size", UITheme.FS_BODY if compact else UITheme.FS_HEAD)


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
