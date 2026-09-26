extends Node
## 世界时钟（WorldClock）
## 职责：驱动游戏内时间流动。挂在世界地图上，每秒推进一定游戏时间。
## 用法：在场景中实例化，或作为 autoload 常驻。

@export var seconds_per_day: float = 15.0   ## 现实多少秒 = 游戏内 1 天（R2-10：8 秒/天使日约束失真，15 秒恢复日循环意义）

## 单帧最多补推进的天数（防止长时间挂后台后一次性跳过大段日期）
const MAX_CATCHUP_DAYS := 30

var _accumulator := 0.0
var _paused := false


func _ready() -> void:
	EventBus.monthly_militia.connect(_on_monthly_militia)
	# 【修复】pause() 原本全工程无调用者，玩家看对话/翻面板时日期照跑
	# （15 秒一天，看完一段长对话可能已跨月并触发月度结算）。改为自动暂停。
	# 【H1 同型】autoload 信号一律方法绑定：捕获 self 的 lambda 不随场景释放断连，
	# 进城/回图 N 次会叠 N 层僵尸 handler 对已释放实例调 pause()/resume()
	EventBus.dialogue_started.connect(_on_dialogue_started)
	EventBus.dialogue_ended.connect(_on_dialogue_ended)
	EventBus.scene_loading_started.connect(_on_scene_loading_started)
	EventBus.scene_loading_finished.connect(_on_scene_loading_finished)


func _on_dialogue_started(_id: String) -> void:
	pause()


func _on_dialogue_ended(_id: String) -> void:
	resume()


func _on_scene_loading_started(_p: String) -> void:
	pause()


func _on_scene_loading_finished(_p: String) -> void:
	resume()


func _on_monthly_militia(unit_id: String, count: int) -> void:
	var unit := DataManager.get_unit(unit_id)
	var uname := str(unit.get("name", unit_id)) if not unit.is_empty() else unit_id
	EventBus.show_toast("本月义兵来投：%s ×%d" % [uname, count])


func _process(delta: float) -> void:
	if _paused:
		return
	_accumulator += delta
	# 【修复】旧代码跨天后把累加器清零：掉帧或切场景时单帧 delta 可能远超
	# seconds_per_day，多出来的时间被整段丢弃，日期推进慢于配置。改为扣减循环，
	# 余数保留；同时限制单帧最多推进天数，避免后台挂机回来一次性跳过大量日期。
	var guard := 0
	while _accumulator >= seconds_per_day and guard < MAX_CATCHUP_DAYS:
		_accumulator -= seconds_per_day
		GameState.advance_day(1)
		guard += 1
	if guard >= MAX_CATCHUP_DAYS:
		_accumulator = 0.0


func pause() -> void:
	_paused = true


func resume() -> void:
	_paused = false
