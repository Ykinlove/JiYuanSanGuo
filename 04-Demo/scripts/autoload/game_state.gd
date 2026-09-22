extends Node
## 游戏状态（GameState）
## 职责：持有当前存档的全部运行时数据，是所有界面读取数据的唯一来源。
## 结构变更时请同步更新 to_dict() / from_dict()。

# ---------- 世界时间 ----------
var year: int = 184
var month: int = 1
var day: int = 1

# ---------- 资源 ----------
var gold: int = 1000
var food: int = 2000
var wood: int = 500
var iron: int = 200

# ---------- 主角 ----------
var player_name: String = "无名"
var player_hero_id: String = "player_male"
var player_level: int = 1
var player_exp: int = 0
var player_stats := {
	"constitution": 10,   # 体质
	"strength": 10,       # 力量
	"intelligence": 10,   # 智力
	"charisma": 10,       # 魅力
}
var player_attr_points: int = 5   # 可分配属性点
var player_talent_points: int = 0 # 可分配天赋点
var player_talent: String = "genius"  # 特技：奇才

# ---------- 部队 ----------
## 武将队伍：[{ "hero_id": "...", "level": 1, "exp": 0, "intimacy": 0 }, ...]
var party: Array = []
## 部队编制：[{ "unit_id": "infantry", "count": 100, "hero_id": "", "exp": 0 }, ...]
## hero_id 为统兵武将（可选），由酒馆招募后编入；为空则无武将加成
var troops: Array = []
## 阵型配置：阵位 -> 部队索引
var formation_id: String = "yu_lin"
var formation_slots: Array = []   # 长度 15（3行×5列），值为部队索引或 -1

# ---------- 俘虏 ----------
## 监牢中的敌将：[{ "hero_id": "181", "captured_day": 12, "intimacy": 0 }, ...]
## intimacy 独立于 party，专给俘虏用（招降前累积好感）
var prisoners: Array = []

# ---------- 背包（M5） ----------
## 道具库存：item_id -> 数量
var inventory: Dictionary = {}
## 已装备（6 槽，与 heroes6 表同构）：槽位 -> items6 数字 id（0=空）
var equipment: Dictionary = { "weapon1": 0, "weapon2": 0, "helmet": 0, "armor": 0, "treasure": 0, "mount": 0 }

# ---------- 城池经营（M5） ----------
## 各城民心覆盖值：city_id -> morale（未记录则用城市表默认值）
var city_morale: Dictionary = {}
## 各城当日已征兵数：city_id -> 人数（每日重置）
var city_recruited_today: Dictionary = {}
## 各城已修缮的城防：city_id -> 增量
var city_defense_bonus: Dictionary = {}
## 演练用标记：true 时战斗不消耗存档兵力、不给奖励
var drill_mode: bool = false
## 最近一次演练结果
var last_drill_result: Dictionary = {}

# ---------- 世界 ----------
var current_city_id: String = ""
var current_region: String = "nanzhong"
var current_encounter: Dictionary = {}   ## 当前触发的遭遇（传入战斗场景用）
## 场景返回位置（跨场景暂存，不入存档）：
## 进战斗 / 进城前记录玩家所在场景与坐标，场景重载时恢复，避免「战斗完回到出生点」
var return_scene: String = ""            ## "" / "world" / "city"
var return_pos: Vector2 = Vector2.ZERO
var unlocked_regions: Array = ["nanzhong"]
## 本局已解决（战斗/宝箱/商队）的遭遇 id 集合。EncounterManager 是 world_map 子节点，
## 每次从战斗返回整场景会重载、_triggered_ids 被清空、遭遇物用固定种子原地重生；
## 若不记录，玩家撤离后下一帧会原地再次触发，死循环。记进 autoload 跨重载存活即可根除。
var encounter_resolved: Dictionary = {}
## 势力关系：faction_id -> 关系值 -100~100
var faction_relations: Dictionary = {}
## 已攻占城池：city_id -> faction_id
var captured_cities: Dictionary = {}

# ---------- 任务 ----------
var active_quests: Array = []
var completed_quests: Array = []
## 任务进度快照：quest_id -> Dictionary（如 {"base_troops": 12} 接任务时的兵力）
var quest_progress: Dictionary = {}

# ---------- 声望 ----------
var fame: int = 0       # 名声 0~100
var infamy: int = 0     # 恶名 0~100

# ---------- 引导 ----------
var intro_seen: bool = false   ## 开场剧情是否已看过（新档=false→首次进入时演开场；读档按存档恢复）
## 村庄声望：village_id -> 值
var village_reputation: Dictionary = {}

# ---------- 成就 ----------
## 已解锁成就：achievement_id -> 解锁描述串（记录何时/来自何处）
var achievements_unlocked: Dictionary = {}
## 累计完成交易次数（NPC 交易结算一次 +1）
var trades_done: int = 0
## NPC 背包库存：key("npc_id|item_id") -> { "left": 剩余, "restock_at": 补货日总天数 }
var npc_stock_state: Dictionary = {}
## 已造访城池：city_id -> true（进过一次城即记录）
var visited_cities: Dictionary = {}

# ---------- 统计 ----------
var play_time_seconds: float = 0.0
var battle_count: int = 0
var battle_win_count: int = 0


func _ready() -> void:
	# 每分钟结算一次游戏内时间推进由 WorldClock 驱动；此处仅统计游玩时长
	set_process(true)


func _process(delta: float) -> void:
	play_time_seconds += delta


## ---------- 资源增减（统一入口，自动广播信号） ----------

func add_gold(delta: int) -> void:
	gold = maxi(0, gold + delta)
	EventBus.gold_changed.emit(gold)


func add_food(delta: int) -> void:
	food = maxi(0, food + delta)
	EventBus.food_changed.emit(food)


func add_wood(delta: int) -> void:
	wood = maxi(0, wood + delta)
	EventBus.wood_changed.emit(wood)


func add_iron(delta: int) -> void:
	iron = maxi(0, iron + delta)
	EventBus.iron_changed.emit(iron)


## 名声 / 恶名（唯一入口，自动裁剪到 0~100）
func add_fame(delta: int) -> void:
	fame = clampi(fame + delta, 0, 100)
	EventBus.fame_changed.emit(fame)


func add_infamy(delta: int) -> void:
	infamy = clampi(infamy + delta, 0, 100)
	EventBus.infamy_changed.emit(infamy)


## 获取总兵力
func get_total_troops() -> int:
	var total := 0
	for t in troops:
		total += int(t.get("count", 0))
	return total


## ---------- 背包（M5） ----------

func add_item(item_id: String, amount: int = 1) -> void:
	if item_id.is_empty() or amount == 0:
		return
	var cur := int(inventory.get(item_id, 0)) + amount
	if cur <= 0:
		inventory.erase(item_id)
	else:
		inventory[item_id] = cur
	EventBus.inventory_changed.emit(item_id, cur)


func get_item_count(item_id: String) -> int:
	return int(inventory.get(item_id, 0))


func has_item(item_id: String, amount: int = 1) -> bool:
	return get_item_count(item_id) >= amount


## 花费道具，成功返回 true
func consume_item(item_id: String, amount: int = 1) -> bool:
	if not has_item(item_id, amount):
		return false
	add_item(item_id, -amount)
	return true


## ---------- 装备穿戴（6 槽，items6 数字 id） ----------

## 物品是否可装入指定槽（items6 cat_major 匹配，或旧 items.json id 有兼容映射）
func can_equip(slot: String, item_id: String) -> bool:
	if not CharacterService.EQUIP_SLOTS.has(slot):
		return false
	var item := CharacterService.resolve_item6(item_id)
	if item.is_empty():
		return false
	return int(item.get("cat_major", -1)) == int(CharacterService.SLOT_CAT_MAJOR.get(slot, -1))


## 穿戴：从背包取一件装入槽位，槽上旧物退回背包。
## item_id 允许旧 items.json 字符串 id（自动转换为 items6 数字 id）。
func equip_item(slot: String, item_id: String) -> bool:
	if not can_equip(slot, item_id):
		return false
	# 旧 id → items6 数字 id
	var resolved := CharacterService.resolve_item6(item_id)
	var new_id := int(resolved.get("id", 0))
	if new_id <= 0:
		return false
	if not has_item(item_id, 1):
		return false
	# 先退旧物
	var old_id := int(equipment.get(slot, 0))
	if old_id > 0:
		add_item(str(old_id), 1)
	# 再扣新物并入槽
	add_item(item_id, -1)
	equipment[slot] = new_id
	EventBus.equipment_changed.emit()
	return true


## 卸下：槽位物品退回背包
func unequip_item(slot: String) -> void:
	if not CharacterService.EQUIP_SLOTS.has(slot):
		return
	var old_id := int(equipment.get(slot, 0))
	if old_id <= 0:
		return
	add_item(str(old_id), 1)
	equipment[slot] = 0
	EventBus.equipment_changed.emit()


## 旧档装备迁移：仅认 items6 数字 id（6 槽）；旧字符串槽位置空（物品仍在背包）
func _migrate_equipment(raw: Variant) -> Dictionary:
	var fresh: Dictionary = {}
	for slot in CharacterService.EQUIP_SLOTS:
		fresh[slot] = 0
	if raw is Dictionary:
		for slot in CharacterService.EQUIP_SLOTS:
			var v: Variant = raw.get(slot, 0)
			if typeof(v) == TYPE_INT and int(v) > 0:
				fresh[slot] = int(v)
			elif typeof(v) == TYPE_STRING and String(v).is_valid_int() and int(String(v)) > 0:
				fresh[slot] = int(String(v))
	return fresh


## ---------- 城池经营（M5） ----------

## 取城池当前民心（优先用运行时覆盖值）
func get_city_morale(city_id: String) -> int:
	if city_morale.has(city_id):
		return int(city_morale[city_id])
	var city := DataManager.get_city(city_id)
	return int(city.get("morale", 50))


func set_city_morale(city_id: String, value: int) -> void:
	city_morale[city_id] = clampi(value, 0, 100)


func get_city_defense(city_id: String) -> int:
	var city := DataManager.get_city(city_id)
	var base := int(city.get("defense", 0))
	return base + int(city_defense_bonus.get(city_id, 0))


## 今日该城已征兵数
func get_recruited_today(city_id: String) -> int:
	return int(city_recruited_today.get(city_id, 0))


func add_recruited_today(city_id: String, amount: int) -> void:
	city_recruited_today[city_id] = get_recruited_today(city_id) + amount


## ---------- 部队操作（M5） ----------

## 征兵：向部队中加入兵力（已有同兵种则累加）
func add_troop(unit_id: String, count: int, hero_id: String = "") -> void:
	if count <= 0:
		return
	for t in troops:
		if str(t.get("unit_id", "")) == unit_id and str(t.get("hero_id", "")) == hero_id:
			t["count"] = int(t.get("count", 0)) + count
			EventBus.troop_changed.emit(get_total_troops())
			return
	troops.append({
		"unit_id": unit_id,
		"count": count,
		"hero_id": hero_id,
		"exp": 0,
	})
	EventBus.troop_changed.emit(get_total_troops())


## 解散一支部队
func remove_troop(index: int) -> bool:
	if index < 0 or index >= troops.size():
		return false
	troops.remove_at(index)
	# 清理布阵中对该部队的引用（索引会整体偏移，稳妥起见全部失效重置）
	formation_slots = []
	EventBus.troop_changed.emit(get_total_troops())
	return true


## 给部队绑定统兵武将
func assign_hero_to_troop(troop_index: int, hero_id: String) -> bool:
	if troop_index < 0 or troop_index >= troops.size():
		return false
	troops[troop_index]["hero_id"] = hero_id
	return true


## ---------- 武将队伍（M5） ----------

func has_hero(hero_id: String) -> bool:
	for h in party:
		if str(h.get("hero_id", "")) == hero_id:
			return true
	return false


## 招募武将入队
func recruit_hero(hero_id: String) -> bool:
	if has_hero(hero_id):
		return false
	var cap := int(DataManager.get_recruit_settings().get("max_party_size", 8))
	if party.size() >= cap:
		return false
	party.append({
		"hero_id": hero_id,
		"level": 1,
		"exp": 0,
		"intimacy": 0,
	})
	EventBus.party_changed.emit()
	return true


## ---------- 俘虏（监牢） ----------

func has_prisoner(hero_id: String) -> bool:
	for p in prisoners:
		if str(p.get("hero_id", "")) == hero_id:
			return true
	return false


## 俘虏入监牢。已在队伍/已俘虏则忽略。
func add_prisoner(hero_id: String) -> bool:
	if hero_id.is_empty():
		return false
	if has_hero(hero_id) or has_prisoner(hero_id):
		return false
	prisoners.append({
		"hero_id": hero_id,
		"captured_day": day,
		"intimacy": 0,
	})
	EventBus.prisoner_changed.emit()
	return true


## 从监牢移除（招降成功 / 处死）
func remove_prisoner(hero_id: String) -> bool:
	for i in range(prisoners.size()):
		if str(prisoners[i].get("hero_id", "")) == hero_id:
			prisoners.remove_at(i)
			EventBus.prisoner_changed.emit()
			return true
	return false


func get_prisoner(hero_id: String) -> Dictionary:
	for p in prisoners:
		if str(p.get("hero_id", "")) == hero_id:
			return p
	return {}


func add_prisoner_intimacy(hero_id: String, delta: int) -> void:
	var p := get_prisoner(hero_id)
	if p.is_empty():
		return
	p["intimacy"] = clampi(int(p.get("intimacy", 0)) + delta, 0, 100)
	EventBus.prisoner_changed.emit()


## ---------- 结义 ----------

## 该武将是否已结义
func is_sworn(hero_id: String) -> bool:
	for h in party:
		if str(h.get("hero_id", "")) == hero_id:
			return bool(h.get("sworn", false))
	return false


## 设置结义标记
func set_sworn(hero_id: String, v: bool) -> void:
	for h in party:
		if str(h.get("hero_id", "")) == hero_id:
			h["sworn"] = v
			EventBus.party_changed.emit()
			return


## 统兵武将经验获取（升级增加加成）
func add_hero_exp(hero_id: String, amount: int) -> void:
	if hero_id.is_empty() or amount <= 0:
		return
	for h in party:
		if str(h.get("hero_id", "")) == hero_id:
			h["exp"] = int(h.get("exp", 0)) + amount
			# 每 100 经验升 1 级，最高 10 级
			var lv := 1 + int(int(h["exp"]) / 100)
			h["level"] = mini(10, lv)
			EventBus.party_changed.emit()
			return


## 主角经验（升级自动奖励属性点，供属性加点系统使用）
## 每 100 经验升 1 级，每升 1 级奖励 3 点可分配属性点。
func add_player_exp(amount: int) -> void:
	if amount <= 0:
		return
	player_exp += amount
	var new_level := 1 + int(player_exp / 100)
	while player_level < new_level:
		player_level += 1
		player_attr_points += 3
	EventBus.player_stats_changed.emit()


## 消耗 1 点属性点，投入某个主角属性（体质/力量/智力/魅力）
## stat 取 player_stats 的键：constitution / strength / intelligence / charisma
func spend_attr_point(stat: String) -> bool:
	if player_attr_points <= 0:
		return false
	var keys := {
		"constitution": "体质", "strength": "力量",
		"intelligence": "智力", "charisma": "魅力",
	}
	if not player_stats.has(stat) or not keys.has(stat):
		return false
	player_attr_points -= 1
	player_stats[stat] = int(player_stats[stat]) + 1
	EventBus.player_stats_changed.emit()
	return true


## ---------- 成就 ----------

func is_achievement_unlocked(id: String) -> bool:
	return achievements_unlocked.has(id)


func unlock_achievement(id: String, note: String = "") -> void:
	if id.is_empty() or is_achievement_unlocked(id):
		return
	achievements_unlocked[id] = note if not note.is_empty() else "达成"
	EventBus.achievement_unlocked.emit(id)


## ---------- 时间推进 ----------

func advance_day(days: int = 1) -> void:
	for i in range(days):
		day += 1
		if day > 30:
			day = 1
			advance_month()
		# 每日重置各城征兵计数
		city_recruited_today.clear()
		EventBus.day_passed.emit(year, month, day)
	EventBus.date_changed.emit(year, month, day)


func advance_month() -> void:
	month += 1
	if month > 12:
		month = 1
		year += 1
	EventBus.month_passed.emit(year, month)
	# 每月消耗粮草：每 100 兵日耗 1 粮 → 每月 30
	var troop_total := get_total_troops()
	var upkeep := int(troop_total / 100.0 * 30.0)
	if upkeep > 0:
		add_food(-upkeep)
	_grant_monthly_militia()


## 月度义兵：在城中时按当前所在城民心免费征召一批基础兵
func _grant_monthly_militia() -> void:
	if current_city_id.is_empty():
		return  # 野外行伍，无城邑兵源
	var settings := DataManager.get_barracks_settings()
	var morale := get_city_morale(current_city_id)
	var m := MonthlyService.militia(settings, morale)
	var count := int(m["count"])
	if count <= 0:
		return
	var unit_id := String(m["unit_id"])
	add_troop(unit_id, count)
	EventBus.monthly_militia.emit(unit_id, count)


## 游戏内总天数（184年1月1日 = 第 0 天），用于补货计时等
func total_days() -> int:
	return (year - 184) * 360 + (month - 1) * 30 + (day - 1)


## 格式化日期文本
func get_date_text() -> String:
	return "公元%d年 %d月" % [year, month]


## ---------- 存档序列化 ----------

func to_dict() -> Dictionary:
	return {
		"version": 1,
		"year": year, "month": month, "day": day,
		"gold": gold, "food": food, "wood": wood, "iron": iron,
		"player_name": player_name,
		"player_hero_id": player_hero_id,
		"player_level": player_level,
		"player_exp": player_exp,
		"player_stats": player_stats,
		"player_attr_points": player_attr_points,
		"player_talent_points": player_talent_points,
		"player_talent": player_talent,
		"party": party,
		"troops": troops,
		"inventory": inventory,
		"equipment": equipment,
		"city_morale": city_morale,
		"city_recruited_today": city_recruited_today,
		"city_defense_bonus": city_defense_bonus,
		"formation_id": formation_id,
		"formation_slots": formation_slots,
		"prisoners": prisoners,
		"current_city_id": current_city_id,
		"current_region": current_region,
		"current_encounter": current_encounter,
		"unlocked_regions": unlocked_regions,
		"faction_relations": faction_relations,
		"captured_cities": captured_cities,
		"active_quests": active_quests,
		"completed_quests": completed_quests,
		"fame": fame,
		"infamy": infamy,
		"village_reputation": village_reputation,
		"play_time_seconds": play_time_seconds,
		"battle_count": battle_count,
		"battle_win_count": battle_win_count,
		"achievements_unlocked": achievements_unlocked,
		"trades_done": trades_done,
		"visited_cities": visited_cities,
		"npc_stock_state": npc_stock_state,
		"quest_progress": quest_progress,
		"intro_seen": intro_seen,
	}


func from_dict(data: Dictionary) -> void:
	year = int(data.get("year", 184))
	month = int(data.get("month", 1))
	day = int(data.get("day", 1))
	gold = int(data.get("gold", 1000))
	food = int(data.get("food", 2000))
	wood = int(data.get("wood", 500))
	iron = int(data.get("iron", 200))
	player_name = str(data.get("player_name", "无名"))
	player_hero_id = str(data.get("player_hero_id", "player_male"))
	player_level = int(data.get("player_level", 1))
	player_exp = int(data.get("player_exp", 0))
	player_stats = data.get("player_stats", player_stats)
	player_attr_points = int(data.get("player_attr_points", 5))
	player_talent_points = int(data.get("player_talent_points", 0))
	player_talent = str(data.get("player_talent", "genius"))
	party = data.get("party", [])
	troops = data.get("troops", [])
	inventory = data.get("inventory", {})
	equipment = _migrate_equipment(data.get("equipment", {}))
	city_morale = data.get("city_morale", {})
	city_recruited_today = data.get("city_recruited_today", {})
	city_defense_bonus = data.get("city_defense_bonus", {})
	formation_id = str(data.get("formation_id", "yu_lin"))
	formation_slots = data.get("formation_slots", [])
	prisoners = data.get("prisoners", [])
	current_city_id = str(data.get("current_city_id", ""))
	current_region = str(data.get("current_region", "nanzhong"))
	current_encounter = data.get("current_encounter", {})
	unlocked_regions = data.get("unlocked_regions", ["nanzhong"])
	faction_relations = data.get("faction_relations", {})
	captured_cities = data.get("captured_cities", {})
	active_quests = data.get("active_quests", [])
	completed_quests = data.get("completed_quests", [])
	fame = int(data.get("fame", 0))
	infamy = int(data.get("infamy", 0))
	village_reputation = data.get("village_reputation", {})
	play_time_seconds = float(data.get("play_time_seconds", 0.0))
	battle_count = int(data.get("battle_count", 0))
	battle_win_count = int(data.get("battle_win_count", 0))
	achievements_unlocked = data.get("achievements_unlocked", {})
	trades_done = int(data.get("trades_done", 0))
	visited_cities = data.get("visited_cities", {})
	npc_stock_state = data.get("npc_stock_state", {})
	quest_progress = data.get("quest_progress", {})
	# 旧档无此字段：默认视为已看过（不打扰老玩家重放开场）。
	# 新档走 reset() 会置 false，按字段显式设 false 也会触发开场。
	intro_seen = bool(data.get("intro_seen", true))
	EventBus.player_stats_changed.emit()
	EventBus.date_changed.emit(year, month, day)


## 重置为初始状态（开新档用）
func reset() -> void:
	year = 184
	month = 1
	day = 1
	gold = 1000
	food = 2000
	wood = 500
	iron = 200
	player_name = "无名"
	player_hero_id = "player_male"
	player_level = 1
	player_exp = 0
	player_stats = {"constitution": 10, "strength": 10, "intelligence": 10, "charisma": 10}
	player_attr_points = 5
	player_talent_points = 0
	player_talent = "genius"
	party = []
	troops = []
	prisoners = []
	inventory = {}
	equipment = { "weapon1": 0, "weapon2": 0, "helmet": 0, "armor": 0, "treasure": 0, "mount": 0 }
	city_morale = {}
	city_recruited_today = {}
	city_defense_bonus = {}
	drill_mode = false
	last_drill_result = {}
	formation_id = "yu_lin"
	formation_slots = []
	current_city_id = ""
	current_region = "nanzhong"
	unlocked_regions = ["nanzhong"]
	encounter_resolved = {}
	faction_relations = {}
	captured_cities = {}
	active_quests = []
	completed_quests = []
	quest_progress = {}
	fame = 0
	infamy = 0
	village_reputation = {}
	intro_seen = false   # 新档：开场剧情未看过，首次进入演开场
	play_time_seconds = 0.0
	battle_count = 0
	battle_win_count = 0
	achievements_unlocked = {}
	trades_done = 0
	visited_cities = {}
	npc_stock_state = {}
	