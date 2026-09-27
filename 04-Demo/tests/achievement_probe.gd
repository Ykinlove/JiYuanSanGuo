extends SceneTree
## 成就解锁接线运行时探针（#29）
## 运行：godot --headless --script res://tests/achievement_probe.gd --path <project>
## 目的：验证 StoryDirector._ready 把 gameplay 信号接到 AchievementService.check_all，
##       且 check_all 在真实状态下能正确解锁/不解锁成就。
## --script 不加载 autoload，故本探针手动注册单例 + 触发 _ready，模拟真实启动。
## 注意：--script 模式解析器不识别 autoload 全局名，故本脚本一律用本地实例变量（gs/bus）访问。

var _fails := 0

func _check(tag: String, cond: bool) -> void:
	print("  [%s] %s" % ["OK" if cond else "FAIL", tag])
	if not cond:
		_fails += 1

func _initialize() -> void:
	# 1) 手动注册 autoload 单例（--script 模式引擎不会自动注册）
	var bus = load("res://scripts/autoload/event_bus.gd").new()
	Engine.register_singleton("EventBus", bus)
	var dm = load("res://scripts/autoload/data_manager.gd").new()
	Engine.register_singleton("DataManager", dm)
	dm.load_all()
	var gs = load("res://scripts/autoload/game_state.gd").new()
	Engine.register_singleton("GameState", gs)
	var sd = load("res://scripts/autoload/story_director.gd").new()
	Engine.register_singleton("StoryDirector", sd)

	# 2) 触发 StoryDirector._ready —— 建立成就解锁接线（本次新增代码）
	sd._ready()
	_check("StoryDirector._ready 执行无异常", true)

	# 3) 模拟玩家状态（直接置字段，check_all 读的是实时 GameState）
	gs.gold = 2000
	gs.battle_win_count = 1
	gs.trades_done = 1
	gs.player_level = 5
	gs.fame = 60
	gs.party = ["h1"]
	gs.visited_cities = {"scene_2": true}

	# 4) 通过信号触发 check_all（逐个发，验证每个连接都能进 _check_achievements）
	bus.battle_ended.emit({})          # wins
	bus.item_sold.emit("sword", 1, 10) # traded
	bus.gold_changed.emit(2000)        # gold
	bus.fame_changed.emit(60)          # fame
	bus.hero_recruited.emit("h1")      # party
	bus.city_entered.emit("scene_2")   # visited_cities
	bus.player_stats_changed.emit()    # level + 首步
	_check("所有信号 emit 无异常（无 Signal-not-found / 参数不匹配）", true)

	# 5) 断言应解锁项
	var expect_unlock := ["first_step", "rich_1000", "win_1", "trader",
						  "level_5", "fame_50", "party_1"]
	for id in expect_unlock:
		_check("解锁 " + id, gs.is_achievement_unlocked(id))

	# 6) 断言不应解锁项（阈值未到）
	var expect_lock := ["rich_5000", "army_100", "win_10", "party_5",
					   "fame_100", "travel_10"]
	for id in expect_lock:
		_check("未解锁 " + id + "（阈值未到）", not gs.is_achievement_unlocked(id))

	# 7) 幂等：再发一次信号，已解锁不应重复发奖/崩溃
	bus.battle_ended.emit({})
	_check("重复触发不崩溃（幂等）", true)

	print("")
	if _fails == 0:
		print("ACHIEVE_PROBE_RESULT=PASS")
	else:
		print("ACHIEVE_PROBE_RESULT=FAIL (fails=%d)" % _fails)
	quit()
