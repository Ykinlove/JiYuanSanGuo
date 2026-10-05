extends RefCounted
class_name QuestService
## 任务规则层：读取 quests.json，接取、事件计数、目标进度、交付结算。
## UI 只调 accept()/record_event()/progress()/can_turn_in()/turn_in()，不写任何进度公式。
##
## 目标类型（objectives[].type）：
## - talk        与 NPC 对话（target 为 npc id，兼容 npc_ 前缀/下划线差异）
## - battle      战胜指定敌人（target 对应遭遇表 quest_target；"any" 任意战斗）
## - reach       抵达地点（target 对应城池 visit_target / 特殊地点）
## - collect    收集物品（target 为物品 id，采集与宝箱自动记账）
## - fish        钓鱼（target "any"，钓鱼点采集触发）
## - give_gold   累计赠金（count 为累计金额，对话 give_gold 动作记账）
## - recruit_troop  新增兵力（接任务时快照 base_troops，增量计数）
##
## 事件计数持久化在 GameState.quest_progress[qid]["ev_<type>:<canon_target>"]。

const RANDOM_REWARD_CATEGORY := "material"


## 取任务记录（quests 表为数组/对象型均兼容）
static func get_quest(quest_id: String) -> Dictionary:
	if quest_id.is_empty():
		return {}
	return DataManager.get_record("quests", quest_id)


## id 归一化：去 npc_ 前缀、去下划线，解决 "zhu_rong" 与 "npc_zhurong" 类差异
static func _canon(raw: String) -> String:
	var s := str(raw)
	if s.begins_with("npc_"):
		s = s.substr(4)
	return s.replace("_", "").to_lower()


## 目标是否匹配事件目标（target 为 "any" 时通吃）
static func _target_matches(obj_target: String, ev_target: String) -> bool:
	if obj_target == "any":
		return true
	return _canon(obj_target) == _canon(ev_target)


static func _counter_key(ev_type: String, target: String) -> String:
	return "ev_%s:%s" % [ev_type, _canon(target)]


## 接取任务：初始化快照与计数。返回 {ok, msg}
static func accept(quest_id: String) -> Dictionary:
	var q := get_quest(quest_id)
	if q.is_empty():
		return { "ok": false, "msg": "任务数据缺失。" }
	if GameState.completed_quests.has(quest_id):
		return { "ok": false, "msg": "该任务已完成。" }
	if GameState.active_quests.has(quest_id):
		return { "ok": false, "msg": "任务已在进行中。" }
	# 【阵营任务门控】type=faction 的任务只为指定势力效力（fa_caoxu→曹操 16、
	# fa_lujiang→刘备 15）。原版只查章节门控：投靠刘备也能接「为曹取徐州」，
	# 交付后功勋 +20 计入刘备线的升官门槛——跨势力功勋记账直接失衡。
	if str(q.get("type", "")) == "faction":
		var need_fid := int(q.get("faction_id", 0))
		if need_fid > 0 and GameState.affiliation != need_fid:
			var fname := "该势力"
			var f := DataManager.get_faction6(need_fid)
			if not f.is_empty():
				fname = str(f.get("name", fname))
			if GameState.affiliation != 0:
				return { "ok": false, "msg": "你已投靠 %s，不可为 %s 效力。" % [FactionService.faction_name(), fname] }
			return { "ok": false, "msg": "须先投靠「%s」方可承接其军令。" % fname }

	GameState.active_quests.append(quest_id)
	var snap := { "base_troops": GameState.get_total_troops() }
	# 接取时已身处 reach 目标城池内 → 直接视为已抵达（在城内接到寻人/抵达类任务）
	if not GameState.current_city_id.is_empty():
		var city := DataManager.get_record("cities", GameState.current_city_id)
		var vt := str(city.get("visit_target", ""))
		if not vt.is_empty():
			for obj in q.get("objectives", []):
				if str(obj.get("type", "")) == "reach" \
						and _target_matches(str(obj.get("target", "")), vt):
					snap[_counter_key("reach", vt)] = int(obj.get("count", 1))
	GameState.quest_progress[quest_id] = snap

	EventBus.quest_accepted.emit(quest_id)
	return { "ok": true, "msg": "接受任务：%s" % str(q.get("title", quest_id)) }


## 记录一个游戏事件，自动累加到所有进行中且目标匹配的任务。
## ev_type: talk/battle/reach/collect/fish/give_gold
## amount: 事件数量（give_gold 传金额；采集传数量；其余默认 1）
static func record_event(ev_type: String, target: String, amount: int = 1) -> void:
	if amount <= 0:
		return
	for qid in GameState.active_quests:
		var q := get_quest(str(qid))
		if q.is_empty():
			continue
		var touched := false
		var snap: Dictionary = GameState.quest_progress.get(str(qid), {})
		for obj in q.get("objectives", []):
			if str(obj.get("type", "")) != ev_type:
				continue
			if not _target_matches(str(obj.get("target", "")), target):
				continue
			# 【修复】目标写 "any" 时通吃任意事件 target，但读取侧 objective_progress()
			# 用的是目标自身的 target 建键；两边必须落在同一个键上，否则进度永远读到 0，
			# 含 "any" 目标的任务（如「赢得一场战斗」「钓 3 条鱼」）永远无法交付。
			var obj_t := str(obj.get("target", ""))
			var key := _counter_key(ev_type, "any" if obj_t == "any" else target)
			snap[key] = int(snap.get(key, 0)) + amount
			touched = true
		if touched:
			GameState.quest_progress[str(qid)] = snap


## R2-09：目标位置副标签「（XX城·XX区域）」——找人找城不再全图瞎跑。
## talk/give_gold → npcs.city_id；reach → cities.visit_target 反查。查不到返回空串。
static func _location_hint(otype: String, target: String) -> String:
	var city := {}
	match otype:
		"talk", "give_gold":
			var npc := DataManager.get_record("npcs", target)
			if not npc.is_empty():
				city = DataManager.get_record("cities", str(npc.get("city_id", "")))
		"reach":
			# 【修复】cities.json 并无 visit_target 字段，只按它匹配会让所有
			# 「北上抵达许昌」这类 reach 目标拿不到位置指引（R2-09 形同虚设）。
			# 先按城池 id 匹配（reach target 写作 city_xxx），visit_target 保留作兼容。
			for c in DataManager.get_table("cities"):
				if not c is Dictionary:
					continue
				if str(c.get("id", "")) == target or str(c.get("visit_target", "")) == target:
					city = c
					break
	if city.is_empty():
		return ""
	var cname := str(city.get("name", ""))
	var rname := str(city.get("region_name", ""))
	if cname.is_empty():
		return ""
	if rname.is_empty():
		return "（%s）" % cname
	return "（%s·%s）" % [cname, rname]


## 单个目标进度：{desc, cur, need, done}
static func objective_progress(q: Dictionary, obj: Dictionary) -> Dictionary:
	var need := int(obj.get("count", 1))
	var otype := str(obj.get("type", ""))
	var target := str(obj.get("target", ""))
	var cur := 0

	match otype:
		"recruit_troop":
			var snap: Dictionary = GameState.quest_progress.get(str(q.get("id", "")), {})
			var base := int(snap.get("base_troops", 0))
			cur = maxi(0, GameState.get_total_troops() - base)
		"give_gold", "talk", "battle", "reach", "collect", "fish":
			var snap2: Dictionary = GameState.quest_progress.get(str(q.get("id", "")), {})
			cur = int(snap2.get(_counter_key(otype, target), 0))
		_:
			cur = 0

	return {
		"desc": str(obj.get("desc", otype)) + _location_hint(otype, target),
		"cur": mini(cur, need),
		"need": need,
		"done": cur >= need,
	}


## 整单进度列表
static func progress(q: Dictionary) -> Array:
	var out: Array = []
	for obj in q.get("objectives", []):
		out.append(objective_progress(q, obj))
	return out


## 是否可交付：所有目标都达成
static func can_turn_in(q: Dictionary) -> bool:
	var ps := progress(q)
	if ps.is_empty():
		return false
	for p in ps:
		if not bool(p["done"]):
			return false
	return true


## 交付：active → completed，发奖励。返回 {ok, msg}
static func turn_in(quest_id: String) -> Dictionary:
	var q := get_quest(quest_id)
	if q.is_empty():
		return { "ok": false, "msg": "任务数据缺失。" }
	if not GameState.active_quests.has(quest_id):
		return { "ok": false, "msg": "该任务不在进行中。" }
	if not can_turn_in(q):
		return { "ok": false, "msg": "目标尚未全部完成。" }

	GameState.active_quests.erase(quest_id)
	if not GameState.completed_quests.has(quest_id):
		GameState.completed_quests.append(quest_id)

	var parts: Array[String] = []
	var rewards: Dictionary = q.get("rewards", {})

	var gold := int(rewards.get("gold", 0))
	if gold > 0:
		GameState.add_gold(gold)
		parts.append("金 %d" % gold)
	var food := int(rewards.get("food", 0))
	if food > 0:
		GameState.add_food(food)
		parts.append("粮 %d" % food)
	var exp_amt := int(rewards.get("exp", 0))
	if exp_amt > 0:
		GameState.add_player_exp(exp_amt)
		parts.append("经验 %d" % exp_amt)
	var fame := int(rewards.get("fame", 0))
	if fame > 0:
		GameState.add_fame(fame)
		parts.append("名声 %d" % fame)
	var merit := int(rewards.get("merit", 0))
	if merit > 0:
		GameState.merit += merit
		parts.append("功勋 %d" % merit)

	# 武将好感：{ "zhu_rong": 20 }
	var intimacy: Dictionary = rewards.get("intimacy", {})
	for hero_id in intimacy:
		var delta := int(intimacy[hero_id])
		if _add_party_intimacy(str(hero_id), delta):
			var hero := DataManager.get_character(str(hero_id))
			parts.append("%s 好感 +%d" % [str(hero.get("name", hero_id)), delta])

	# 兵种支援：{ "unit": "infantry", "count": 50 }
	var unit_id := str(rewards.get("unit", ""))
	var unit_count := int(rewards.get("count", 0))
	if not unit_id.is_empty() and unit_count > 0:
		GameState.add_troop(unit_id, unit_count)
		EventBus.unit_added.emit(unit_id, unit_count)
		var uname := unit_id
		var urec := DataManager.get_record("units", unit_id)
		if not urec.is_empty():
			uname = str(urec.get("name", unit_id))
		parts.append("%s ×%d" % [uname, unit_count])

	# 随机物品（生活类任务彩蛋）
	if bool(rewards.get("random_item", false)):
		var pick_id := _random_material_id()
		if not pick_id.is_empty():
			GameState.add_item(pick_id, 1)
			var item := DataManager.get_item(pick_id)
			parts.append("%s ×1" % str(item.get("name", pick_id)))

	# 【第七十五轮·接通的第二条物品发放路径】
	# 改动前：73 个任务的 rewards 里 **items 键 0 次、materials 键 1 次但本函数不消费**，
	# 玩家做完任务只能拿钱和经验，一把刀一件甲都没有 —— 与用户报告完全吻合。
	# materials 与 items 两键并存的原因：materials 是上游 battle_rewards 表的既有键名
	# （battle_reward_service 一直在用），quests 沿用了同一命名。两键都收，materials 优先。
	_grant_reward_items(rewards, parts)

	# 剧情标记：unlock / promise（unlock 兼容字符串或字符串数组）
	apply_unlock_value(rewards.get("unlock", ""))
	apply_unlock_value(rewards.get("promise", ""))

	GameState.quest_progress.erase(quest_id)
	EventBus.quest_completed.emit(quest_id)
	var title := str(q.get("title", quest_id))
	var msg := "任务完成：%s" % title
	if not parts.is_empty():
		msg += "（奖励：%s）" % "、".join(parts)
	# 任务链自动衔接：next 指向下一环；重复接取/已完成会被 accept 内部拒绝，不误报
	var nxt := str(q.get("next", ""))
	if not nxt.is_empty():
		var ar := accept(nxt)
		if bool(ar.get("ok", false)):
			msg += "\n" + str(ar.get("msg", ""))
	return { "ok": true, "msg": msg }


## 消费 unlock/promise 类剧情标记：写入 story_flags；建国信物标记转交 SelfRuleService。
## value 支持单个字符串或字符串数组（quests / encounters 两表通用）。
static func apply_unlock_value(value: Variant) -> void:
	var flags: Array = []
	if value is Array:
		flags = value
	elif value is String and not str(value).is_empty():
		flags = [str(value)]
	for f in flags:
		var flag := str(f)
		if flag.is_empty():
			continue
		if SelfRuleService.grant_by_flag(flag):
			continue
		if not GameState.story_flags.has(flag):
			GameState.story_flags.append(flag)


## 增加在队武将好感（按 hero_id 精确匹配），命中返回 true
static func _add_party_intimacy(hero_id: String, delta: int) -> bool:
	if delta == 0:
		return false
	for h in GameState.party:
		# 【防御】正常元素恒为 Dictionary；老存档/异常数据混入字符串时跳过而不是抛错
		if not (h is Dictionary):
			continue
		if str(h.get("hero_id", "")) == hero_id:
			h["intimacy"] = clampi(int(h.get("intimacy", 0)) + delta, 0, 100)
			EventBus.party_changed.emit()
			return true
	return false


## 从物品表中随机取一个材料 id（无材料返回空串）
## 发放任务物品奖励。**两个键都收，materials 优先**：
## - materials: ["treasure_pearl"]（上游 battle_rewards 既有键名，战斗奖励一直在用）
## - items:     [{"item_id":126,"count":1}] 或 {"126":2}（本轮新增的规范写法）
##
## 【为什么不只认一种键名】quests.json 与 combat.json 是同一套上游生成器产出的，
## 材料奖励字段在战斗表里叫 materials、在任务表里历史上没人写 —— 现在两种都支持，
## 以后上游往任一表补物品奖励都能落到背包，不需要再改代码。
##
## id 解析走 CharacterService.resolve_item6：纯数字 id 查 items6，
## 旧字符串 id（treasure_pearl 这类）先过 LEGACY_ITEM_MAP 兼容映射。
## 查不到的 id 跳过并在 parts 里留说明 —— 不能静默吞掉，那会让数据侧的错误永远查不出来。
static func _grant_reward_items(rewards: Dictionary, parts: Array[String]) -> void:
	var raw: Variant = rewards.get("materials", [])
	if not (raw is Array) or raw.is_empty():
		raw = rewards.get("items", [])
	if not (raw is Array):
		return
	for entry in raw:
		var iid := ""
		var cnt := 1
		if entry is Dictionary:
			iid = str(entry.get("item_id", entry.get("id", "")))
			cnt = maxi(1, int(entry.get("count", 1)))
		elif entry is String or entry is int or entry is float:
			iid = str(entry)
		else:
			continue
		if iid.is_empty():
			continue
		var rec := CharacterService.resolve_item6(iid)
		if rec.is_empty():
			parts.append("（物品数据缺失：%s）" % iid)
			continue
		var real_id := int(rec.get("id", 0))
		if real_id <= 0:
			parts.append("（物品数据缺失：%s）" % iid)
			continue
		GameState.add_item(str(real_id), cnt)
		parts.append("%s ×%d" % [str(rec.get("name", iid)), cnt])


static func _random_material_id() -> String:
	var pool: Array = []
	for item in DataManager.get_table("items"):
		if str(item.get("category", "")) == RANDOM_REWARD_CATEGORY:
			pool.append(str(item.get("id", "")))
	if pool.is_empty():
		return ""
	return str(pool[randi_range(0, pool.size() - 1)])
