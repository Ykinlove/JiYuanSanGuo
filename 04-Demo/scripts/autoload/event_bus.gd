extends Node
## 全局事件总线（EventBus）
## 所有模块之间通过信号解耦通信，避免直接引用。
## 用法：
##   EventBus.gold_changed.emit(100)
##   EventBus.gold_changed.connect(_on_gold_changed)

# ---------- 资源 / 数值 ----------
signal gold_changed(value: int)
signal food_changed(value: int)
signal wood_changed(value: int)
signal iron_changed(value: int)
signal troop_changed(value: int)
signal player_stats_changed()

# ---------- 时间 ----------
signal date_changed(year: int, month: int, day: int)
signal day_passed(year: int, month: int, day: int)
signal month_passed(year: int, month: int)
## 月度义兵来投：unit_id, count
signal monthly_militia(unit_id: String, count: int)

# ---------- 角色 / 部队 ----------
signal hero_recruited(hero_id: String)
signal hero_level_up(hero_id: String, new_level: int)
signal unit_added(unit_id: String, count: int)
signal unit_removed(unit_id: String, count: int)
signal party_changed()
signal prisoner_changed()
signal prisoner_captured(hero_id: String)

# ---------- 背包 / 交易（M5） ----------
signal inventory_changed(item_id: String, count: int)
signal equipment_changed()
signal item_bought(item_id: String, count: int, cost: int)
signal item_sold(item_id: String, count: int, gain: int)
signal troop_recruited(unit_id: String, count: int, cost: int)

# ---------- 城池经营（M5） ----------
signal city_morale_changed(city_id: String, value: int)
signal city_defense_changed(city_id: String, value: int)

# ---------- 声望 ----------
signal fame_changed(value: int)
signal infamy_changed(value: int)

# ---------- 演练（M5） ----------
signal drill_started(drill_id: String)
signal drill_finished(drill_id: String, result: Dictionary)

# ---------- 地图 / 城池 ----------
signal city_entered(city_id: String)
signal city_left(city_id: String)
signal city_captured(city_id: String, faction_id: String)
signal faction_relation_changed(faction_id: String, value: int)

# ---------- 战斗 ----------
signal battle_started(battle_config: Dictionary)
signal battle_ended(result: Dictionary)

# ---------- 任务 / 对话 ----------
signal quest_accepted(quest_id: String)
signal quest_completed(quest_id: String)
signal dialogue_started(dialogue_id: String)
signal dialogue_ended(dialogue_id: String)

# ---------- 成就 ----------
signal achievement_unlocked(achievement_id: String)

# ---------- UI / 系统 ----------
signal toast(message: String)
signal npc_shop_requested(npc_data: Dictionary)   ## 对话 open_shop 动作：请求打开该 NPC 的随身货单（R2-05a）
signal scene_loading_started(scene_path: String)
signal scene_loading_finished(scene_path: String)
signal game_saved(slot: int)
signal game_loaded(slot: int)


## 便捷方法：弹出一条提示
func show_toast(message: String) -> void:
	toast.emit(message)
