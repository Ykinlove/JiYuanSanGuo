extends Node
## 游戏状态（GameState）
## 职责：持有当前存档的全部运行时数据，是所有界面读取数据的唯一来源。
## 结构变更时请同步更新 to_dict() / from_dict()。

# ---------- 世界时间 ----------
var year: int = 184
var month: int = 1
var day: int = 1

## 季节（由月份推导，资源闭环用）：0春 1夏 2秋 3冬
const SEASON_SPRING: int = 0
const SEASON_SUMMER: int = 1
const SEASON_AUTUMN: int = 2
const SEASON_WINTER: int = 3

## 当前季节（1-3春 / 4-6夏 / 7-9秋 / 10-12冬）
func get_season() -> int:
	return clampi(int((month - 1) / 3), 0, 3)

## 季节显示名
static func season_name(s: int) -> String:
	match s:
		0: return "春"
		1: return "夏"
		2: return "秋"
		3: return "冬"
	return "春"

# ---------- 资源 ----------
var gold: int = 1500
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
## 战场装配的个人技 id（talents6，1-6；默认 1 雷霆击）
var personal_skill: int = 1
## 创角掷点时随机生成的资质加成（生命/精力/攻击/防御，可负）：
## 与四维联动叠加 —— 基础公式吃四维实时变化，加成是先天定死的部分
var player_derived_bonus := {
	"hp": 0, "mp": 0, "attack": 0, "defense": 0,
}
## 主角外观立绘 id（与 create_hero 选择的形象对应）
var player_portrait: String = "portrait_male_01"

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
## 装备强化等级：items6 数字 id（字符串键）-> 等级（0~max_level），同 id 装备共享
var equip_levels: Dictionary = {}

# ---------- 城池经营（M5） ----------
## 各城民心覆盖值：city_id -> morale（未记录则用城市表默认值）
var city_morale: Dictionary = {}
## 各城当日已征兵数：city_id -> 人数（每日重置）
var city_recruited_today: Dictionary = {}
## 各城当日已购入物资批数：city_id -> 批数（每日重置，跑商限流用）
var city_trade_today: Dictionary = {}
## 各城已修缮的城防：city_id -> 增量
var city_defense_bonus: Dictionary = {}
## 演练用标记：true 时战斗不消耗存档兵力、不给奖励
var drill_mode: bool = false
## 最近一次演练结果
var last_drill_result: Dictionary = {}
## 本场战斗是否「空阵赴敌」：布阵界面一支部队都没上时为 true。
## 战场据此跳过部队战 —— 直接打一场主角单挑（DuelService）就结算整场遭遇，
## 免得玩家带着 0 支部队去看一场必败的兵力对冲。
var duel_only: bool = false

# ---------- 世界 ----------
var current_city_id: String = ""
var current_region: String = "nanzhong"
var current_encounter: Dictionary = {}   ## 当前触发的遭遇（传入战斗场景用）
## 场景返回位置（跨场景暂存，不入存档）：
## 进战斗 / 进城前记录玩家所在场景与坐标，场景重载时恢复，避免「战斗完回到出生点」
var return_scene: String = ""            ## "" / "world" / "city"
var return_pos: Vector2 = Vector2.ZERO
## 【R1-13】史官锚点播报去重戳（story_director 用）；入档防读档当天重弹
var story_fired: Array[String] = []
## 【R1-03】玩家在大地图上的实时位置（world_map 每帧同步，入存档）。
## 读档时恢复到存档瞬间的位置；Vector2.ZERO 表示「尚无有效位置」（真·新档随机出生）。
var last_world_pos: Vector2 = Vector2.ZERO
var unlocked_regions: Array = ["nanzhong"]
## 本局已解决（战斗/宝箱/商队）的遭遇 id 集合。EncounterManager 是 world_map 子节点，
## 每次从战斗返回整场景会重载、_triggered_ids 被清空、遭遇物用固定种子原地重生；
## 若不记录，玩家撤离后下一帧会原地再次触发，死循环。记进 autoload 跨重载存活即可根除。
var encounter_resolved: Dictionary = {}
## 势力关系：faction_id -> 关系值 -100~100
var faction_relations: Dictionary = {}
## 已攻占城池：city_id -> faction_id
var captured_cities: Dictionary = {}
## 【治下城池 #65/#67】城池原属势力：city_id -> faction_id（攻下前的归属，原属势力据此派兵来夺）
var city_original_owner: Dictionary = {}
## 【#67】排期中的收复军：city_id -> { faction:int, due:int, army:int }
##   due/相关月序一律用「游戏月序」= (year-1)*12 + (month-1)，与 faction_wars 同口径
var city_claims: Dictionary = {}
## 【#67】击退收复军后的冷却：city_id -> 可再次排期的游戏月序
var city_retake_cooldown: Dictionary = {}
## 【#66】征兵额度加成：city_id -> { amount:int, until:int }（until = 失效的游戏月序）
var city_recruit_bonus: Dictionary = {}
## 【#66】治理指令冷却：city_id -> { order_id -> 可再次施行的游戏月序 }
var city_order_cooldown: Dictionary = {}
## 【#65】守军戒备：city_id -> 城防临时增量（攻城失败被反扑后累加，逐月衰减）
##   表现为「守军有了防备」，下次攻城或收复战时守军规模按此膨胀
var city_alert: Dictionary = {}
## 投靠封地：已封地城池 id 列表（将军封1县 / 太守封1郡）
var feudal_cities: Array = []
## 外交活跃状态：faction_id -> { alliance/trade/war/marriage : bool }
var diplomacy: Dictionary = {}
## 势力 AI 轻量状态：faction_id -> { troops/gold/population }
var ai_state: Dictionary = {}
## 势力×势力战争矩阵：pair_key("小|大") -> 开战游戏月（int，公元年*12+月）；
## 仅记录处于战争的两两势力对，供 AI 互伐与「群雄征伐」面板读取。键为字符串，勿走 _restore_int_keys。
var faction_wars: Dictionary = {}

# ---------- 任务 ----------
var active_quests: Array = []
var completed_quests: Array = []
## 任务进度快照：quest_id -> Dictionary（如 {"base_troops": 12} 接任务时的兵力）
var quest_progress: Dictionary = {}
## 剧情标记位（任务奖励 unlock/promise 等写入，供对话条件与后续剧情判定）
var story_flags: Array = []

# ---------- 声望 ----------
var fame: int = 0       # 名声 0~100
var infamy: int = 0     # 恶名 0~100

# ---------- 主线剧情（M11+） ----------
var mainline_chapter: int = 1   ## 主线章节 1-7（黄巾→董卓→群雄→官渡→赤壁→鼎立→一统）
var affiliation: int = 0        ## 投靠势力 id（0=无/平民）
## 投靠意向（两段式投靠）：外交面板表明意向后记录目标势力 id，
## 需亲自前往其都城面见主公、献上投名状才算正式加入。0=无意向。
var join_intent: int = 0
var official_rank: int = 0      ## 官阶 0平民 / 1兵长 / 2校尉 / 3将军 / 4太守
var merit: int = 0              ## 累积功勋（投靠升官门槛）
var merit_today: int = 0        ## 【P1-5】今日捐金已得功勋（日上限用，跨日惰性重置）
var merit_today_day: int = -1   ## 【P1-5】功勋日计数所属游戏日（-1=未开始）
var has_jade_seal: bool = false ## 建国信物·玉玺
var has_tiger_tally: bool = false ## 建国信物·虎符
var is_self_rule: bool = false  ## 是否已自立建国
var self_rule_name: String = "" ## 自立国号
var self_rule_flag: int = 0     ## 自立旗帜纹样 id
var self_rule_city: String = "" ## 自立都城（城池 id）
var ending_triggered: bool = false ## 是否已触发失败结局（D-09 §5.4，避免重复触发）
## 主线进度辅助记账（MainlineService 读写，如黄巾残党清剿计数等）。不入 UI 展示。
var mainline_data: Dictionary = {}

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
			# 【修复】JSON 解析把所有数字一律还原成 float，旧代码只认 TYPE_INT / TYPE_STRING，
			# 于是读档时装备槽全部归零；而穿戴时物品已从背包扣除 —— 装备凭空消失。
			if typeof(v) == TYPE_STRING:
				if String(v).is_valid_int() and int(String(v)) > 0:
					fresh[slot] = int(String(v))
			elif typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
				if int(v) > 0:
					fresh[slot] = int(v)
	return fresh


## 数组元素归一为 int（读档用：JSON 数字一律是 float）
static func _to_int_array(raw: Variant) -> Array:
	var out: Array = []
	if raw is Array:
		for v in raw:
			out.append(int(v))
	return out


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


## 今日该城已购入物资批数（跑商限流）
func get_trade_today(city_id: String) -> int:
	return int(city_trade_today.get(city_id, 0))


func add_trade_today(city_id: String, amount: int) -> void:
	city_trade_today[city_id] = get_trade_today(city_id) + amount


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


## 按比例减员（粮草软锁逃兵用）：从最大编制依次扣除，扣满 amount 为止。
## 返回实际减员数。
func lose_troops(amount: int) -> int:
	if amount <= 0 or troops.is_empty():
		return 0
	var remaining := amount
	while remaining > 0 and not troops.is_empty():
		# 找当前最大编制的部队
		var mi := -1
		var mv := -1
		for i in troops.size():
			var c := int(troops[i].get("count", 0))
			if c > mv:
				mv = c
				mi = i
		if mi < 0:
			break
		var have := int(troops[mi].get("count", 0))
		var take := mini(have, remaining)
		troops[mi]["count"] = have - take
		remaining -= take
		if int(troops[mi].get("count", 0)) <= 0:
			troops.remove_at(mi)
			formation_slots = []   # 编制引用随部队移除整体失效，稳妥重置
	EventBus.troop_changed.emit(get_total_troops())
	return amount - remaining


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
## 【可玩性调优 2026-09-24】升级需求改幂函数累计曲线：升到 Lv.n 累计需 115 × n^1.625 经验。
## 原常数 100 exp/级扛不住按章节指数增长的经验收入（全程约 2.4 万经验 → 旧公式 Lv246，
## 而最强剧情遭遇仅 Lv33-38，数字崩坏且属性点无限堆积）。
## 新曲线模拟（每章约 8 场战斗）：章末1≈Lv9 / 章末4≈Lv16 / 全收集终章≈Lv35，
## 与遭遇难度曲线（lv8-12 → lv33-38）逐章咬合；后期需靠支线/羁绊/自由战斗补足，形成玩法牵引。
func add_player_exp(amount: int) -> void:
	if amount <= 0:
		return
	player_exp += amount
	var new_level := level_for_exp(player_exp)
	var leveled := false
	while player_level < new_level:
		player_level += 1
		player_attr_points += 3
		leveled = true
	# 旧档兼容：旧常数曲线的等级虚高，读档/获得经验时按新曲线回落（属性点不回收，玩家不亏）
	if player_level > new_level:
		player_level = new_level
	EventBus.player_stats_changed.emit()
	if leveled:
		AchievementService.check_all()


## 升级需求曲线：升到 Lv.n 的累计经验 = 115 × n^1.625（幂函数，边际递增平滑）
func level_for_exp(exp: int) -> int:
	var lv := 1
	while float(115 * pow(float(lv + 1), 1.625)) <= float(exp):
		lv += 1
		if lv >= 120:
			break
	return lv


## 四维单项硬上限（体质/力量/智力/魅力）：全局唯一真源，
## 创角加点（create_hero）与游戏内加点（spend_attr_point）都以此为准。
## 【2026-09-27 修复】此前创角把「加点上限」直接别名成「随机掷点上限」80，
## 而四维随机掷点（现为 20~80）、另有自由分配点数（现为 5）—— 掷到接近 80
## 再点「猛将 +5」就撞 80 被拦，玩家看到「超出上限不能分配」。
## 上限 100 与掷点上限 80 是两回事，必须解耦。
const STAT_CAP := 100

## 消耗 1 点属性点，投入某个主角属性（体质/力量/智力/魅力）
## stat 取 player_stats 的键：constitution / strength / intelligence / charisma
func spend_attr_point(stat: String) -> bool:
	var keys := {
		"constitution": "体质", "strength": "力量",
		"intelligence": "智力", "charisma": "魅力",
	}
	if not player_stats.has(stat) or not keys.has(stat):
		return false
	# 【补缺口】游戏内加点原本没有任何上限判定，属性可以一路加到天上去，
	# 与「四维单项上限 100」的设计不符。触顶时明确告知，别让按钮点了没反应。
	if int(player_stats[stat]) >= STAT_CAP:
		EventBus.show_toast("%s 已达上限 %d 点。" % [str(keys[stat]), STAT_CAP])
		return false
	if player_attr_points <= 0:
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
		# 每日重置各城征兵计数与跑商进货额度
		city_recruited_today.clear()
		city_trade_today.clear()
		EventBus.day_passed.emit(year, month, day)
	EventBus.date_changed.emit(year, month, day)


func advance_month() -> void:
	month += 1
	if month > 12:
		month = 1
		year += 1
	EventBus.month_passed.emit(year, month)
	var season := get_season()
	# 每月消耗粮草：每 100 兵月耗 30 粮；冬季行军艰难，维护 +20%
	var troop_total := get_total_troops()
	var upkeep := int(troop_total / 100.0 * 30.0)
	if season == SEASON_WINTER:
		upkeep = int(upkeep * 1.2)
	# 粮草软锁：存粮不足以支付维护 → 余粮清空 + 士兵按比例逃散（逼玩家经营城池）
	var deserted := 0
	if food < upkeep:
		var shortfall := upkeep - food
		add_food(-food)   # 余粮清空（add_food 夹 0）
		if troop_total > 0:
			var ratio := float(shortfall) / float(maxi(1, upkeep))
			deserted = lose_troops(maxi(1, int(round(float(troop_total) * ratio))))
			EventBus.show_toast("粮草不济！%d 名士兵逃散。" % deserted)
	else:
		add_food(-upkeep)
	_grant_monthly_militia()   # 内部按民心：饥荒期民心低则无义兵
	_grant_city_tax()          # 治下城池月度赋税（#64）
	_drift_city_morale(season)
	_tick_city_ownership()     # 治下城池：收复军到期 / 民心叛乱 / 加成衰减（#65/#67）
	AIService.monthly_tick()
	# 自立失败结局判定（D-09 §5.5）：恶名过高触发天下共击，逐月检查，幂等
	SelfRuleService.check_ending()


## 民心思政：每月向基线 50 轻微回归（用则存、不用则缓降）；季节修正（冬苛 -2 / 秋丰 +1）。
## 仅漂移玩家曾治理（有覆盖值）的城，未治理城恒用 cities.json 默认值。
func _drift_city_morale(season: int) -> void:
	var mod := 0
	if season == SEASON_WINTER:
		mod = -2
	elif season == SEASON_AUTUMN:
		mod = 1
	var target := 50 + mod
	for cid in city_morale.keys():
		var mv := int(city_morale[cid])
		if mv < target:
			mv = mini(target, mv + 1)
		elif mv > target:
			mv = maxi(target, mv - 1)
		else:
			continue
		city_morale[cid] = mv


## 游戏月序：把 (年, 月) 压成一个单调递增整数，供收复排期 / 征兵加成到期比较。
## 口径与 faction_wars 的开战月一致：公元 year 年 month 月 → (year-1)*12 + (month-1)
func month_index() -> int:
	return (year - 1) * 12 + (month - 1)


## 玩家攻占城池（#64）：写入 captured_cities 并同步翻转静态城池表归属，
## 让势力配色 / AI 归属 / 城池经济三处口径统一（此前该字段只读不写，等于空转）。
## faction_id 为接管方（通常为玩家所属势力）。
## 【#67】同时记下这座城的原归属，并给原属势力排一次「收复」——打下不等于永远拥有。
func capture_city(city_id: String, faction_id: int) -> void:
	if city_id.is_empty():
		return
	captured_cities[city_id] = faction_id
	var old_owner := 0
	for c in DataManager.get_table("cities"):
		if c is Dictionary and str(c.get("id", "")) == city_id:
			old_owner = int(c.get("faction_id", 0))
			c["faction_id"] = faction_id
			break
	# 原归属只在首次攻取时记录：被夺回后再打回来，仍记最早的主人（怨仇最深的那家）
	if old_owner > 0 and not city_original_owner.has(city_id):
		city_original_owner[city_id] = old_owner
	EventBus.city_captured.emit(city_id, str(faction_id))
	# 归属翻转 → 大地图重绘势力配色底盘
	EventBus.world_territory_changed.emit()
	if old_owner > 0:
		_schedule_retake(city_id, old_owner)


## 为某座已占城排一次收复军（#67）。原属势力不甘失城，延宕数月后兵临城下。
## 已排期 / 处于冷却期 / 原主已无号令之力（id<=0）时不排。
func _schedule_retake(city_id: String, faction_id: int) -> void:
	if faction_id <= 0 or not captured_cities.has(city_id):
		return
	if city_claims.has(city_id):
		return
	var cfg: Dictionary = CityService.retake_settings()
	var now := month_index()
	if now < int(city_retake_cooldown.get(city_id, 0)):
		return
	var lo := maxi(1, int(cfg.get("min_delay_months", 2)))
	var hi := maxi(lo, int(cfg.get("max_delay_months", 5)))
	var city := DataManager.get_city(city_id)
	var army := CityService.retake_army_size(city)
	city_claims[city_id] = {
		"faction": faction_id,
		"due": now + randi_range(lo, hi),
		"army": army,
	}


## 治下城池失守（#65 失地机制）：从 captured_cities 摘除、静态表归属还原给夺回方，
## 并清掉该城所有玩家侧加成（征兵额度 / 治理冷却 / 守军戒备 / 排期）。
## faction_id = 0 表示无人接管（叛乱后自立为乱民，城池暂归中立）。
func lose_city(city_id: String, faction_id: int) -> void:
	if not captured_cities.has(city_id):
		return
	captured_cities.erase(city_id)
	city_claims.erase(city_id)
	city_recruit_bonus.erase(city_id)
	city_order_cooldown.erase(city_id)
	city_alert.erase(city_id)
	for c in DataManager.get_table("cities"):
		if c is Dictionary and str(c.get("id", "")) == city_id:
			c["faction_id"] = faction_id
			break
	EventBus.city_lost.emit(city_id, faction_id)
	EventBus.world_territory_changed.emit()


## 月度治下城池结算（#65/#67）：按固定顺序处理——
##   ① 过期加成/戒备衰减  ② 收复军到期判定（告急 → 逾期失守）③ 重新排期  ④ 民心叛乱
## 顺序讲究：先清过期状态，再判收复，最后判叛乱，避免同月里「刚被夺回又叛乱」的连环。
func _tick_city_ownership() -> void:
	if captured_cities.is_empty():
		return
	var now := month_index()
	var cfg: Dictionary = CityService.ownership_settings()
	var decay := int(CityService.siege_settings().get("counterattack", {}).get("alert_decay_per_month", 1))

	# ① 征兵加成到期 / 守军戒备衰减
	for cid in city_recruit_bonus.keys():
		var b: Dictionary = city_recruit_bonus[cid]
		if now >= int(b.get("until", 0)):
			city_recruit_bonus.erase(cid)
	for cid in city_alert.keys():
		var left := int(city_alert[cid]) - decay
		if left <= 0:
			city_alert.erase(cid)
		else:
			city_alert[cid] = left

	# ② 收复军到期：先告急（宽限月内可赶回迎战），逾期则守军独力难支、城池失守
	var grace := maxi(0, int(CityService.retake_settings().get("grace_months", 1)))
	for cid in city_claims.keys():
		var claim: Dictionary = city_claims[cid]
		var overdue := now - int(claim.get("due", now))
		if overdue < 0:
			continue
		if overdue >= grace:
			var fid := int(claim.get("faction", 0))
			lose_city(str(cid), fid)
			EventBus.show_toast("%s 守军独力难支，已被 %s 夺回！" % [
				str(DataManager.get_city(str(cid)).get("name", cid)),
				FactionService.faction_name(fid)])
		else:
			# 每月只惊一次：由 world_map 决定是就地开战还是只发告警
			EventBus.city_retake_incoming.emit(str(cid), int(claim.get("faction", 0)))

	# ③ 冷却已过 → 原属势力再次图谋（打下不等于一劳永逸）
	for cid in captured_cities.keys():
		if city_claims.has(cid):
			continue
		var owner := int(city_original_owner.get(cid, 0))
		if owner > 0:
			_schedule_retake(str(cid), owner)

	# ④ 民心叛乱：治理（安抚民心）是唯一对冲手段，否则低民心的城迟早丢
	var rv: Dictionary = cfg.get("revolt", {})
	var threshold := int(rv.get("morale_threshold", 20))
	var chance := float(rv.get("monthly_chance", 0.12))
	if chance <= 0.0:
		return
	for cid in captured_cities.keys():
		if get_city_morale(str(cid)) >= threshold:
			continue
		if randf() >= chance:
			continue
		var prev := int(city_original_owner.get(cid, 0))
		lose_city(str(cid), prev)
		EventBus.show_toast("%s 民心尽失，守军倒戈，城池易主！" % [
			str(DataManager.get_city(str(cid)).get("name", cid))])


## 该城当前由「整饬军备」带来的征兵额度加成（#66）
func get_recruit_quota_bonus(city_id: String) -> int:
	var b: Dictionary = city_recruit_bonus.get(city_id, {})
	if b.is_empty():
		return 0
	if month_index() >= int(b.get("until", 0)):
		city_recruit_bonus.erase(city_id)
		return 0
	return int(b.get("amount", 0))


## 治下城池月度赋税（#64）：每座已占城按 defense 产出金钱
## （系数 owned_city_tax_per_defense 来自 barracks settings，数据驱动）
func _grant_city_tax() -> void:
	if captured_cities.is_empty():
		return
	var per := int(DataManager.get_barracks_settings().get("owned_city_tax_per_defense", 2))
	var total := 0
	for cid in captured_cities.keys():
		var city := DataManager.get_city(str(cid))
		total += int(city.get("defense", 10)) * per
	if total <= 0:
		return
	add_gold(total)
	EventBus.show_toast("治下城邑赋税 +%d 金。" % total)


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


## 章节跳时间（剧本导演专用）：
## 主线章节完成后把日期直接推进到下一章史实起点（如 184.11 → 189.4）。
## 只派发 month_passed / date_changed 事件，**跳过逐月经济结算**
## （军粮扣减/义兵/AI tick）——否则跳 50 年会被月度军粮吃光家底。
func advance_to_date(target_year: int, target_month: int) -> void:
	if target_year * 12 + target_month <= year * 12 + month:
		return
	year = target_year
	month = target_month
	day = 1
	# 跳章跨越了数十天，两本「每日重置」字典必须同 day=1 对齐清零：
	# 不清的话新时代首日的征兵额度/跑商进货批数还顶着跳章前的旧计数
	city_recruited_today.clear()
	city_trade_today.clear()
	# 【M-1 修复】跳章也要发 day_passed：其唯一消费者 EncounterManager 靠它
	# 清采集/刷怪每日配额并复活采集点——不发的话新时代首日这些每日重置全被绕过。
	# （注释里「跳过逐月经济结算」的口径不变，day_passed 无经济结算逻辑。）
	EventBus.day_passed.emit(year, month, day)
	EventBus.month_passed.emit(year, month)
	EventBus.date_changed.emit(year, month, day)


## 游戏内总天数（184年1月1日 = 第 0 天），用于补货计时等
func total_days() -> int:
	return (year - 184) * 360 + (month - 1) * 30 + (day - 1)


## 格式化日期文本（含季节，HUD 顶栏日期显示用）
func get_date_text() -> String:
	return "公元%d年 %s·%d月" % [year, season_name(get_season()), month]


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
		"personal_skill": personal_skill,
		"player_derived_bonus": player_derived_bonus,
		"player_portrait": player_portrait,
		"party": party,
		"troops": troops,
		"inventory": inventory,
		"equipment": equipment,
		"equip_levels": equip_levels,
		"city_morale": city_morale,
		"city_recruited_today": city_recruited_today,
		"city_trade_today": city_trade_today,
		"city_defense_bonus": city_defense_bonus,
		"formation_id": formation_id,
		"formation_slots": formation_slots,
		"prisoners": prisoners,
		"current_city_id": current_city_id,
		"current_region": current_region,
		"last_world_pos": [last_world_pos.x, last_world_pos.y],
		"story_fired": story_fired,
		"current_encounter": current_encounter,
		"unlocked_regions": unlocked_regions,
		"faction_relations": faction_relations,
		"captured_cities": captured_cities,
		"city_original_owner": city_original_owner,
		"city_claims": city_claims,
		"city_retake_cooldown": city_retake_cooldown,
		"city_recruit_bonus": city_recruit_bonus,
		"city_order_cooldown": city_order_cooldown,
		"city_alert": city_alert,
		"feudal_cities": feudal_cities,
		"diplomacy": diplomacy,
		"ai_state": ai_state,
		"faction_wars": faction_wars,
		"active_quests": active_quests,
		"completed_quests": completed_quests,
		"fame": fame,
		"infamy": infamy,
		"mainline_chapter": mainline_chapter,
		"affiliation": affiliation,
		"join_intent": join_intent,
		"official_rank": official_rank,
		"merit": merit,
		"has_jade_seal": has_jade_seal,
		"has_tiger_tally": has_tiger_tally,
		"is_self_rule": is_self_rule,
		"self_rule_name": self_rule_name,
		"self_rule_flag": self_rule_flag,
		"self_rule_city": self_rule_city,
		"ending_triggered": ending_triggered,
		"mainline_data": mainline_data,
		"village_reputation": village_reputation,
		"play_time_seconds": play_time_seconds,
		"battle_count": battle_count,
		"battle_win_count": battle_win_count,
		"achievements_unlocked": achievements_unlocked,
		"trades_done": trades_done,
		"merit_today": merit_today,
		"merit_today_day": merit_today_day,
		"visited_cities": visited_cities,
		"npc_stock_state": npc_stock_state,
		"quest_progress": quest_progress,
		"story_flags": story_flags,
		"intro_seen": intro_seen,
		"encounter_resolved": encounter_resolved,
	}


## 【R1-01】JSON 存档会把 Dictionary 的 int 键变成 str 键（JSON 规范只有字符串键），
## 读档后按 int 取值全部落空（外交关系/外交状态/AI 状态集体失忆）。
## 读档时把「纯数字字符串键」归一化回 int 键，恢复与运行期一致的键型。
static func _restore_int_keys(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in d:
		if k is String and str(k).is_valid_int():
			out[int(k)] = d[k]
		else:
			out[k] = d[k]
	return out


func from_dict(data: Dictionary) -> void:
	# 【读档先清瞬态】drill/duel/return_* 不入档，游戏内读档（系统面板→读档）时
	# 上一局的战斗态会原样泄漏进新档：drill_mode 残留=新档首战不耗兵无奖励、
	# return_pos 残留=读档落点被上一局坐标覆盖。这些字段的合法值只有「干净态」。
	drill_mode = false
	last_drill_result = {}
	duel_only = false
	return_scene = ""
	return_pos = Vector2.ZERO
	year = int(data.get("year", 184))
	month = int(data.get("month", 1))
	day = int(data.get("day", 1))
	gold = int(data.get("gold", 1500))
	food = int(data.get("food", 2000))
	wood = int(data.get("wood", 500))
	iron = int(data.get("iron", 200))
	player_name = str(data.get("player_name", "无名"))
	player_hero_id = str(data.get("player_hero_id", "player_male"))
	player_level = int(data.get("player_level", 1))
	player_exp = int(data.get("player_exp", 0))
	# 【可玩性调优】旧常数曲线存档的等级虚高，读档即按新幂函数曲线回落（只降不升，属性点不回收）
	var lv_by_curve := level_for_exp(player_exp)
	if player_level > lv_by_curve:
		player_level = lv_by_curve
	# 四维逐键归一：手工编辑/异常档缺键时，不同消费方的 get 缺省值口径不一
	#（battle 按 10、对话/外交按 0、reset 按 60），这里统一按新档基准 60 兜底
	var ps: Dictionary = data.get("player_stats", {})
	player_stats = {
		"constitution": int(ps.get("constitution", 60)),
		"strength": int(ps.get("strength", 60)),
		"intelligence": int(ps.get("intelligence", 60)),
		"charisma": int(ps.get("charisma", 60)),
	}
	player_attr_points = int(data.get("player_attr_points", 5))
	player_talent_points = int(data.get("player_talent_points", 0))
	player_talent = str(data.get("player_talent", "genius"))
	personal_skill = int(data.get("personal_skill", 1))
	if not SkillService.is_personal_skill(personal_skill):
		personal_skill = 1
	# 资质加成逐键归一：旧档无此字段按 0 兜底（= 纯公式派生，行为与旧版一致）
	var pdb: Dictionary = data.get("player_derived_bonus", {})
	player_derived_bonus = {
		"hp": int(pdb.get("hp", 0)),
		"mp": int(pdb.get("mp", 0)),
		"attack": int(pdb.get("attack", 0)),
		"defense": int(pdb.get("defense", 0)),
	}
	player_portrait = str(data.get("player_portrait", "portrait_male_01"))
	party = data.get("party", [])
	troops = data.get("troops", [])
	inventory = data.get("inventory", {})
	equipment = _migrate_equipment(data.get("equipment", {}))
	equip_levels = data.get("equip_levels", {})
	city_morale = data.get("city_morale", {})
	city_recruited_today = data.get("city_recruited_today", {})
	city_trade_today = data.get("city_trade_today", {})
	merit_today = int(data.get("merit_today", 0))
	merit_today_day = int(data.get("merit_today_day", -1))
	city_defense_bonus = data.get("city_defense_bonus", {})
	formation_id = str(data.get("formation_id", "yu_lin"))
	# 【修复】JSON 数字一律解析为 float，布阵索引必须是 int（拿 float 当数组下标取
	# troops 会出岔子）。读取侧 formation_editor 虽有 int() 兜底，这里从源头归一。
	formation_slots = _to_int_array(data.get("formation_slots", []))
	prisoners = data.get("prisoners", [])
	current_city_id = str(data.get("current_city_id", ""))
	current_region = str(data.get("current_region", "nanzhong"))
	# 【R1-03】恢复存档瞬间的大地图位置（旧档无此字段 → 保持 ZERO，走随机出生兼容路径）
	var lwp: Array = data.get("last_world_pos", [])
	if lwp.size() == 2:
		last_world_pos = Vector2(float(lwp[0]), float(lwp[1]))
	# 【R1-13】恢复史官播报去重戳（旧档无此字段 → 空，锚点重弹一次后即归位）
	story_fired.clear()
	for s in data.get("story_fired", []):
		story_fired.append(str(s))
	current_encounter = data.get("current_encounter", {})
	unlocked_regions = data.get("unlocked_regions", ["nanzhong"])
	# 势力相关三字典以 faction id（int）为键，必须归一化（R1-01）
	faction_relations = _restore_int_keys(data.get("faction_relations", {}))
	captured_cities = data.get("captured_cities", {})
	# 【旧档迁移 2026-09-29】早期版本把自由身 / 自立时攻下的城记为势力 1，
	# 但 factions6.json 并无 id=1，归属会显示成「无名势力」，占城统计也匹配不上。
	# 统一归一为「玩家」条目 888888（与 MainlineService.PLAYER_FACTION_ID 同值）。
	for _cc in captured_cities.keys():
		if int(captured_cities[_cc]) == 1:
			captured_cities[_cc] = 888888
	city_original_owner = data.get("city_original_owner", {})
	city_claims = data.get("city_claims", {})
	city_retake_cooldown = data.get("city_retake_cooldown", {})
	city_recruit_bonus = data.get("city_recruit_bonus", {})
	city_order_cooldown = data.get("city_order_cooldown", {})
	city_alert = data.get("city_alert", {})
	feudal_cities = data.get("feudal_cities", [])
	diplomacy = _restore_int_keys(data.get("diplomacy", {}))
	ai_state = _restore_int_keys(data.get("ai_state", {}))
	faction_wars = data.get("faction_wars", {})
	active_quests = data.get("active_quests", [])
	completed_quests = data.get("completed_quests", [])
	fame = int(data.get("fame", 0))
	infamy = int(data.get("infamy", 0))
	mainline_chapter = int(data.get("mainline_chapter", 1))
	affiliation = int(data.get("affiliation", 0))
	join_intent = int(data.get("join_intent", 0))
	official_rank = int(data.get("official_rank", 0))
	merit = int(data.get("merit", 0))
	has_jade_seal = bool(data.get("has_jade_seal", false))
	has_tiger_tally = bool(data.get("has_tiger_tally", false))
	is_self_rule = bool(data.get("is_self_rule", false))
	self_rule_name = str(data.get("self_rule_name", ""))
	self_rule_flag = int(data.get("self_rule_flag", 0))
	self_rule_city = str(data.get("self_rule_city", ""))
	ending_triggered = bool(data.get("ending_triggered", false))
	mainline_data = data.get("mainline_data", {})
	village_reputation = data.get("village_reputation", {})
	play_time_seconds = float(data.get("play_time_seconds", 0.0))
	battle_count = int(data.get("battle_count", 0))
	battle_win_count = int(data.get("battle_win_count", 0))
	achievements_unlocked = data.get("achievements_unlocked", {})
	trades_done = int(data.get("trades_done", 0))
	visited_cities = data.get("visited_cities", {})
	npc_stock_state = data.get("npc_stock_state", {})
	quest_progress = data.get("quest_progress", {})
	story_flags = data.get("story_flags", [])
	# 已解决遭遇标记必须随档恢复：否则读档后 EncounterManager 重载、_triggered_ids 清空，
	# 之前打过的遭遇物（宝箱/商队/战斗）会原地重生，可无限刷奖励。
	encounter_resolved = data.get("encounter_resolved", {})
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
	gold = 1500
	food = 2000
	wood = 500
	iron = 200
	player_name = "无名"
	player_hero_id = "player_male"
	player_level = 1
	player_exp = 0
	player_stats = {"constitution": 60, "strength": 60, "intelligence": 60, "charisma": 60}
	player_attr_points = 5
	player_talent_points = 0
	player_talent = "genius"
	personal_skill = 1
	player_derived_bonus = {"hp": 0, "mp": 0, "attack": 0, "defense": 0}
	player_portrait = "portrait_male_01"
	party = []
	troops = []
	prisoners = []
	inventory = {}
	equipment = { "weapon1": 0, "weapon2": 0, "helmet": 0, "armor": 0, "treasure": 0, "mount": 0 }
	equip_levels = {}
	city_morale = {}
	city_recruited_today = {}
	city_trade_today = {}
	merit_today = 0          # 【R1-06】开新档清空捐金功勋日额度（旧值残留会顶掉新档首日额度）
	merit_today_day = -1
	city_defense_bonus = {}
	drill_mode = false
	last_drill_result = {}
	duel_only = false
	formation_id = "yu_lin"
	formation_slots = []
	current_city_id = ""
	current_region = "nanzhong"
	story_fired = []                # 【R1-13】新档史官播报全部重新可触发
	last_world_pos = Vector2.ZERO   # 【R1-03】新档无大地图位置 → 随机出生
	current_encounter = {}
	unlocked_regions = ["nanzhong"]
	encounter_resolved = {}
	faction_relations = {}
	captured_cities = {}
	city_original_owner = {}
	city_claims = {}
	city_retake_cooldown = {}
	city_recruit_bonus = {}
	city_order_cooldown = {}
	city_alert = {}
	feudal_cities = []
	diplomacy = {}
	ai_state = {}
	faction_wars = {}
	active_quests = []
	completed_quests = []
	quest_progress = {}
	story_flags = []
	fame = 0
	infamy = 0
	mainline_chapter = 1
	affiliation = 0
	join_intent = 0
	official_rank = 0
	merit = 0
	has_jade_seal = false
	has_tiger_tally = false
	is_self_rule = false
	self_rule_name = ""
	self_rule_flag = 0
	self_rule_city = ""
	ending_triggered = false
	mainline_data = {}
	village_reputation = {}
	intro_seen = false   # 新档：开场剧情未看过，首次进入演开场
	play_time_seconds = 0.0
	battle_count = 0
	battle_win_count = 0
	achievements_unlocked = {}
	trades_done = 0
	visited_cities = {}
	npc_stock_state = {}
	# 跨场景暂存位同样要清：不清的话主菜单开新档后首次进城，
	# return_scene=="city" 会把玩家瞬移到上一局旧城的旧坐标
	return_scene = ""
	return_pos = Vector2.ZERO
	