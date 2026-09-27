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

		# 4) 互伐：处于战争则攻取最弱敌方/中立城（真正的互伐，翻转归属）；
		#    未处战争则按好战度概率向有城宿敌宣战（见 _ai_war_step）。
		_ai_war_step(int(fid))

	# 5) 清掉一方已被全灭的陈旧战争（无法再与亡势交战）
	DiplomacyService.auto_resolve_wars()


## AI 单次征兵量（概率模型中粗略增量，取阈值的一定比例）
static func _recruit_amount(faction_id: int) -> int:
	return maxi(100, int(float(recruit_threshold(faction_id)) * 0.1))


## 单势力每月战争决策（互伐核心）
static func _ai_war_step(attacker: int) -> void:
	if attacker <= 0:
		return
	var enemies := DiplomacyService.enemy_factions(attacker)
	# 1) 史实版图内扩张（主力，与战争状态解耦）：吞并版图内尚不归己之城。
	#    这条是史实演化的关键 —— 江东在刘繇、益州在刘璋、荆州在刘表等静态势力名下，
	#    AI 之间开战带不来这些城；旧版把它挂在「未开战」分支，
	#    导致长期处于战争状态的曹操/刘备被锁死，20 年只涨到 5 城 / 8 城。
	if randf() < war_probability(attacker) * 0.5:
		_capture_in_sphere(attacker)
	# 2) 处于战争：按好战度攻敌城（史实争夺 = 真正的互伐）；敌城吃尽则回版图内扩张
	if not enemies.is_empty():
		if randf() < war_probability(attacker):
			if not _capture_weakest(attacker, enemies):
				_capture_in_sphere(attacker)
		return
	# 3) 未处战争：伺机向有城宿敌宣战（驱动「群雄征伐」面板）
	if randf() < war_probability(attacker) * 0.4:
		_maybe_declare_war(attacker)


## 向随机有城且未交战的对手宣战，返回是否宣战成功
static func _maybe_declare_war(attacker: int) -> bool:
	var pool: Array[int] = []
	for other in AI_FACTIONS:
		var o := int(other)
		if o == attacker:
			continue
		if DiplomacyService.is_at_war(attacker, o):
			continue
		if _faction_city_count(o) <= 0:
			continue
		pool.append(o)
	if pool.is_empty():
		return false
	var target := pool[randi_range(0, pool.size() - 1)]
	return DiplomacyService.declare_war(attacker, target)


## 在自身史实版图内扩张：夺取版图内尚不归己的最弱城。
## 这是史实演化的主力（刘备取益州、孙策定江东、曹操并荆州汉中/幽并），
## 同样受版图闸门约束 —— 版图为空则直接返回 false，保证绝不越界雪球。
##
## 【只吞并未被同等主张者持有的城】若现属势力本身也把该城划进自己的版图，
## 说明这是史实争夺区（如邺/冀州曹袁皆主张），此处跳过、留给「宣战」解决。
## 不跳过的话：AI 按固定顺序行动，后手势力当月就能把城抢回去，
## 争夺城月月易手、谁也守不住 —— 实测曹操 20 年只剩 5 城（史实上他该是北方霸主）。
static func _capture_in_sphere(attacker: int) -> bool:
	var sphere := _sphere_cities(attacker)
	if sphere.is_empty():
		return false
	var cities: Array = DataManager.get_table("cities")
	var best: Dictionary = {}
	var best_score := 999999
	for c in cities:
		if not (c is Dictionary):
			continue
		var cid := str(c.get("id", ""))
		if not (cid in sphere):
			continue
		var owner := int(c.get("faction_id", 0))
		if owner == attacker:
			continue
		# 争夺区：现属势力同样主张此城 → 留给宣战解决，避免月月易手
		if owner > 0 and (cid in _sphere_cities(owner)):
			continue
		var score := int(c.get("defense", 0)) * 2 + int(c.get("morale", 50))
		if score < best_score:
			best_score = score
			best = c
	if best.is_empty():
		return false
	best["faction_id"] = attacker
	EventBus.world_territory_changed.emit()
	return true


## 势力历史版图（faction_territory.json）：该势力史实上拥有/争夺过的城池 id 全集。
## AI 攻城只准夺取本表范围内的城 —— 这是「反雪球」的核心闸门：
## 旧逻辑无边界随机攻城，攻城概率只由好战度决定且与势力大小无关，
## 于是高好战度势力（袁术 0.9）月月拿城、只增不减 → 单调膨胀到 52/110 城（一家独大）。
## 加上版图闸门后，各势力最多吃到自己的史实版图，重叠区形成史实争夺，最终演化为三国鼎立。
## 无本表数据（空）时不限制，兼容回退到旧行为。
static func _sphere_cities(fid: int) -> Array[String]:
	var out: Array[String] = []
	var rec := DataManager.get_record("faction_territory", "root")
	if rec.is_empty():
		return out
	var entry: Dictionary = rec.get(str(fid), {})
	if entry.is_empty():
		return out
	for cid in entry.get("cities", []):
		out.append(str(cid))
	return out


## 攻取最弱的可选受害城：victims 为可接受归属的势力 id 列表（含 0=中立）。
## 防御×2 + 民心 综合最弱者优先；翻转归属给 attacker，发 world_territory_changed。
## 受 _sphere_cities 版图闸门约束：只攻本势力史实版图内的城。
## 返回是否成功夺取一城（敌方城打光后可用于回退吃中立城）。
static func _capture_weakest(attacker: int, victims: Array) -> bool:
	if attacker <= 0:
		return false
	var sphere := _sphere_cities(attacker)
	var cities: Array = DataManager.get_table("cities")
	var best: Dictionary = {}
	var best_score := 999999
	for c in cities:
		if not (c is Dictionary):
			continue
		# 版图闸门：有版图数据时，城不在版图内就不许打（杜绝越界雪球）
		var cid := str(c.get("id", ""))
		if not sphere.is_empty() and not (cid in sphere):
			continue
		var fid := int(c.get("faction_id", 0))
		if fid == attacker:
			continue
		if fid != 0 and not (fid in victims):
			continue
		var score := int(c.get("defense", 0)) * 2 + int(c.get("morale", 50))
		if score < best_score:
			best_score = score
			best = c
	if best.is_empty():
		return false
	best["faction_id"] = attacker
	# 归属翻转让 AI 攻城/互伐肉眼可见：通知大地图重绘势力配色底盘
	EventBus.world_territory_changed.emit()
	return true


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
