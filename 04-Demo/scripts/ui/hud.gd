extends Control
class_name WorldHUD
## 大地图顶部 HUD（资源栏 + 日期 + 操作指引）

@onready var _gold: Label = $ResourceBar/GoldBox/GoldLabel
@onready var _food: Label = $ResourceBar/FoodBox/FoodLabel
@onready var _wood: Label = $ResourceBar/WoodBox/WoodLabel
@onready var _troop: Label = $ResourceBar/TroopBox/TroopLabel
@onready var _date: Label = $DateLabel
@onready var _hint: Label = $HintLabel

var _hint_tween: Tween


func _ready() -> void:
	update_resources()
	if _hint:
		_hint.modulate.a = 0.0


## 刷新全部资源显示
func update_resources() -> void:
	_gold.text = "金钱 %d" % GameState.gold
	_food.text = "粮草 %d" % GameState.food
	_wood.text = "木材 %d" % GameState.wood
	_troop.text = "兵力 %d" % GameState.get_total_troops()
	_date.text = GameState.get_date_text()


## 左上角常驻操作指引（淡入，几秒后淡出，不长期遮挡画面）
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
