class_name AIService
extends RefCounted
## 势力 AI 高层决策（AIService）
## 职责：每月结算各主要势力征兵/宣战/结盟概率（D-08 §2，概率模型，不逐城推演）。
## 全部 static 纯函数（服务层范式）。规则层：只更新 faction_relations 与势力地盘标记，
## 不做微观单位操控。

## 参与 AI 结算的主要势力（factions6 id）：曹操/刘备/孙策/袁绍/袁术/董卓/孟获/马腾
const AI_FACTIONS: Array[int] = [3, 5, 6, 15, 16, 17, 18, 34]

## 各势力好战度 0~1（D-08 §2.4 决策实例），存于此层内置表（数据驱动友好：无 factions6 字段）。
const MILITANCY := { 3: 0.85, 5: 0.6, 6: 0.5, 15: 0.4, 16: 0.7, 17: 0.8, 18: 0.9, 34: 0.3 }

## 出兵/粮草/金钱的粗略资源模型（每势力轻量状态存 GameState.ai_state）
const AI_STATE := "ai_state"

## 兵力阈值：城池数 × 1000 + 500（D-08 §2.2.1）
static func recruit_threshold(faction_id: int) -> int:
	var cities := _faction_city_count(faction_id)
	return int(cities) * 1000 + 500


## 征兵概率（D-08 §2.2.1）：clamp(0.3 + 金钱/3000 + 人口/10000, 0, 0.95)
static func recruit_probability(faction_id: int) -> float:
	var gold := float(_ai_resource(faction_id, "gold", 0))
	var pop := float(_ai_resource(faction_id, "population", 0))
	return clampf(0.3 + gold / 3000.0 + pop / 10000.0, 0.0, 0.95)


## 宣战概率（D-08 §2.2.4）：clamp(0.5 + 好战度×0.3, 0, 0.9)
static func war_probability(faction_id: int) -> float:
	var mil := float(MILITANCY.get(faction_id, 0.5))
	return clampf(0.5 + mil * 0.3, 0.0, 0.9)


## 结盟概率（D-08 §2.2.3）：clamp(0.3 + (关系-60)/100, 0, 0.7)，关系需≥60
static func alliance_probability(faction_id: int, with_id: int) -> float:
	var rel := int(GameState.faction_relations.get(with_id, 0))
	if rel < 60:
		return 0.0
	return clampf(0.3 + float(rel - 60) / 100.0, 0.0, 0.7)


## 每月结算骨架：更新各主要势力的关系漂移与地盘标记。
## 在 GameState.advance_month 后调用（或由 WorldClock 月推进触发）。
static func monthly_tick() -> void:
	# 1) 外交维持（结盟 -2 / 通商 +2 / 联姻 -1 每月）
	DiplomacyService.monthly_relations()

	# 2) 各主要势力轻量决策：关系随机化（模拟外交摩擦/缓和）
	for fid in AI_FACTIONS:
		# 轻微关系漂移：±2，clamp 由 DiplomacyService.modify 保证
		var drift := randi_range(-2, 2)
		if drift != 0:
			DiplomacyService.modify(int(fid), drift)

		# 3) 征兵：概率成立则提升该势力兵力标记
		if randf() < recruit_probability(int(fid)):
			_ai_set_resource(int(fid), "troops",
				int(_ai_resource(int(fid), "troops", 0)) + _recruit_amount(int(fid)))


## AI 单次征兵量（概率模型中粗略增量，取阈值的一定比例）
static func _recruit_amount(faction_id: int) -> int:
	return maxi(100, int(float(recruit_threshold(faction_id)) * 0.1))


## 该势力城池数（cities.json faction_id 匹配）
static func _faction_city_count(faction_id: int) -> int:
	if faction_id <= 0:
		return 0
	var n := 0
	for c in DataManager.get_table("cities"):
		if c is Dictionary and int(c.get("faction_id", 0)) == faction_id:
			n += 1
	return n


## 读取某势力的轻量 AI 状态资源（存在 GameState.ai_state[faction_id]）
static func _ai_resource(faction_id: int, key: String, default: int) -> int:
	var st: Dictionary = GameState.ai_state.get(faction_id, {})
	return int(st.get(key, default))


static func _ai_set_resource(faction_id: int, key: String, value: int) -> void:
	var st: Dictionary = GameState.ai_state.get(faction_id, {})
	st[key] = value
	GameState.ai_state[faction_id] = st


## 全势力 AI 状态摘要（调试/面板用）
static func summary() -> Array:
	var out: Array = []
	for fid in AI_FACTIONS:
		var f := DataManager.get_faction6(int(fid))
		out.append({
			"faction_id": int(fid),
			"name": str(f.get("name", "无名")),
			"cities": _faction_city_count(int(fid)),
			"troops": _ai_resource(int(fid), "troops", 0),
			"gold": _ai_resource(int(fid), "gold", 0),
			"militancy": MILITANCY.get(int(fid), 0.5),
		})
	return out
