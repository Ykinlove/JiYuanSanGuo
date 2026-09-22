extends RefCounted
class_name QuestService
## 任务规则层：读取 quests.json，计算目标进度、判定可否交付、执行交付结算。
## UI 只调 progress()/can_turn_in()/turn_in()，不在此之外写任何进度公式。
##
## 进度口径（本批次）：
## - recruit_troop：当前总兵力 - 接任务时快照（quest_progress[quest_id].base_troops）
## - 其余类型（talk/battle/reach/collect/give_gold/fish）暂无事件源，显示 0/need 待后续接入

## 取任务记录（quests 表为对象型时由 get_record 兜底 root）
static func get_quest(quest_id: String) -> Dictionary:
	if quest_id.is_empty():
		return {}
	return DataManager.get_record("quests", quest_id)


## 单个目标进度：{desc, cur, need, done}
static func objective_progress(q: Dictionary, obj: Dictionary) -> Dictionary:
	var need := int(obj.get("count", 1))
	var cur := 0
	match str(obj.get("type", "")):
		"recruit_troop":
			var snap: Dictionary = GameState.quest_progress.get(str(q.get("id", "")), {})
			var base := int(snap.get("base_troops", 0))
			cur = maxi(0, GameState.get_total_troops() - base)
		_:
			cur = 0
	return {
		"desc": str(obj.get("desc", obj.get("type", "?"))),
		"cur": cur,
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

	# 奖励结算
	var rewards: Dictionary = q.get("rewards", {})
	var parts: Array[String] = []
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

	GameState.quest_progress.erase(quest_id)
	EventBus.quest_completed.emit(quest_id)
	var title := str(q.get("title", quest_id))
	var msg := "任务完成：%s" % title
	if not parts.is_empty():
		msg += "（奖励：%s）" % "、".join(parts)
	return { "ok": true, "msg": msg }
