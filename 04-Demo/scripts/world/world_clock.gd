extends Node
## 世界时钟（WorldClock）
## 职责：驱动游戏内时间流动。挂在世界地图上，每秒推进一定游戏时间。
## 用法：在场景中实例化，或作为 autoload 常驻。

@export var seconds_per_day: float = 15.0   ## 现实多少秒 = 游戏内 1 天（R2-10：8 秒/天使日约束失真，15 秒恢复日循环意义）

var _accumulator := 0.0
var _paused := false


func _ready() -> void:
	EventBus.monthly_militia.connect(_on_monthly_militia)


func _on_monthly_militia(unit_id: String, count: int) -> void:
	var unit := DataManager.get_unit(unit_id)
	var uname := str(unit.get("name", unit_id)) if not unit.is_empty() else unit_id
	EventBus.show_toast("本月义兵来投：%s ×%d" % [uname, count])


func _process(delta: float) -> void:
	if _paused:
		return
	_accumulator += delta
	if _accumulator >= seconds_per_day:
		_accumulator = 0.0
		GameState.advance_day(1)


func pause() -> void:
	_paused = true


func resume() -> void:
	_paused = false
