extends Control
class_name WorldHUD
## 大地图顶部 HUD（资源栏 + 日期）

@onready var _gold: Label = $ResourceBar/GoldLabel
@onready var _food: Label = $ResourceBar/FoodLabel
@onready var _wood: Label = $ResourceBar/WoodLabel
@onready var _troop: Label = $ResourceBar/TroopLabel
@onready var _date: Label = $DateLabel


func _ready() -> void:
	update_resources()


## 刷新全部资源显示
func update_resources() -> void:
	_gold.text = "金钱 %d" % GameState.gold
	_food.text = "粮草 %d" % GameState.food
	_wood.text = "木材 %d" % GameState.wood
	_troop.text = "兵力 %d" % GameState.get_total_troops()
	_date.text = GameState.get_date_text()
