class_name DiplomacyService
extends RefCounted
## 外交规则层（DiplomacyService）
## 职责：M12「势力外交」—— 关系值状态机 + 7 手段（结盟/通商/宣战/联姻/离间/造谣/破坏）。
## 全部 static 纯函数（服务层范式），概率公式与前置校验集中在此层，UI 禁止内联公式。
## 关系值 -100~100：同盟[80,100] 友好[30,79] 中立[-29,29] 敌对[-79,-30] 死敌[-100,-80]。

## 外交活跃状态键（存 GameState.diplomacy[faction_id]）
const K_ALLIANCE := "alliance"
const K_TRADE := "trade"
const K_WAR := "war"
const K_MARRIAGE := "marriage"

## 参与外交的主要势力（factions6 id）：孙策/刘备/曹操/袁绍/袁术/董卓
const MAJOR_FACTIONS: Array[int] = [3, 5, 15, 16, 17, 18]


## ---------- 关系值状态机 ----------

## 关系值 → 状态名（同盟/友好/中立/敌对/死敌）
static func relation_status(value: int) -> String:
	if value >= 80:
		return "同盟"
	if value >= 30:
		return "友好"
	if value >= -29:
		return "中立"
	if value >= -80:
		return "敌对"
	return "死敌"


## 状态中文名（relation_status 别名，供不同消费方命名）
static func relational_status_name(value: int) -> String:
	return relation_status(value)


## 关系值 → { name, value }
static func relation_status_info(value: int) -> Dictionary:
	return { "name": relation_status(value), "value": value }


## 读取与某势力关系值（默认 0）
static func get_relation(faction_id: int) -> int:
	return int(GameState.faction_relations.get(faction_id, 0))


## 修改关系值并 clamp[-100,100]，广播信号。返回新值
static func modify(faction_id: int, delta: int) -> int:
	var v := clampi(get_relation(faction_id) + delta, -100, 100)
	GameState.faction_relations[faction_id] = v
	EventBus.faction_relation_changed.emit(str(faction_id), v)
	return v


## 列出全部主要势力关系概况：[{faction_id, name, value, status}]
static func list_all() -> Array:
	var out: Array = []
	for fid in MAJOR_FACTIONS:
		var f := DataManager.get_faction6(int(fid))
		var v := get_relation(int(fid))
		out.append({
			"faction_id": int(fid),
			"name": str(f.get("name", "无名")),
			"value": v,
			"status": relation_status(v),
		})
	out.sort_custom(func(a, b): return int(a["faction_id"]) < int(b["faction_id"]))
	return out


## 与某势力的外交活跃标记
static func get_state(faction_id: int) -> Dictionary:
	var s: Dictionary = GameState.diplomacy.get(faction_id, {})
	return s


static func _set_state(faction_id: int, key: String, val: bool) -> void:
	var s: Dictionary = GameState.diplomacy.get(faction_id, {})
	s[key] = val
	GameState.diplomacy[faction_id] = s


## 玩家属性取值（外交使者以主角自身属性计，D-08 使者属性）
static func _charm() -> int:
	return int(GameState.player_stats.get("charisma", 0))


static func _intel() -> int:
	return int(GameState.player_stats.get("intelligence", 0))


static func _force() -> int:
	return int(GameState.player_stats.get("strength", 0))


## 目标势力君主智力（D-08 §3.2 被发现概率项：faction6.lord_role_id → heroes6.intel）
static func _lord_intel(faction_id: int) -> int:
	var f := DataManager.get_faction6(faction_id)
	var lord_id := int(f.get("lord_role_id", 0))
	if lord_id <= 0:
		return 0
	var h := DataManager.get_hero6(lord_id)
	return int(h.get("intel", 0))


# ================= 七手段 =================

## D-08 §3.2.1 结盟：前置 关系≥60 + 使者魅力≥50 + 金≥1000；成功关系+20 进入同盟。
static func alliance(faction_id: int) -> Dictionary:
	if faction_id <= 0:
		return { "ok": false, "msg": "无效的势力。" }
	if get_relation(faction_id) < 60:
		return { "ok": false, "msg": "关系不足（需求≥60），尚难结盟。" }
	if _charm() < 50:
		return { "ok": false, "msg": "使者魅力不足（需求≥50），难以出使。" }
	if GameState.gold < 1000:
		return { "ok": false, "msg": "结盟需备礼金 1000 金。" }
	if bool(get_state(faction_id).get(K_ALLIANCE, false)):
		return { "ok": false, "msg": "已与该势力结盟。" }
	GameState.add_gold(-1000)
	var fail_prob: float = clampf(0.5 - _charm() / 200.0 - 1000.0 / 5000.0, 0.05, 0.7)
	# 【修复】fail_prob 语义是「失败率」，判定必须落在失败侧。旧代码写成
	# randf() > fail_prob，属性越高失败率被压到下限（0.05）反而 95% 失败，
	# 六个外交手段集体反向，且礼金已在判定前扣除、失败不退还。
	if randf() < fail_prob:
		return { "ok": false, "msg": "使者遭拒，结盟失败（失败率 %.0f%%）。" % (fail_prob * 100.0) }
	modify(faction_id, 20)
	_set_state(faction_id, K_ALLIANCE, true)
	return { "ok": true, "msg": "结盟成功！与该势力结为同盟，关系 +20。" }


## D-08 §3.2.2 通商：前置 关系≥0 + 使者智力≥40；成功关系+2 进入通商。
static func trade(faction_id: int) -> Dictionary:
	if faction_id <= 0:
		return { "ok": false, "msg": "无效的势力。" }
	if get_relation(faction_id) < 0:
		return { "ok": false, "msg": "关系不足（需求≥0），暂不可通商。" }
	if _intel() < 40:
		return { "ok": false, "msg": "使者智力不足（需求≥40），难理商路。" }
	if bool(get_state(faction_id).get(K_TRADE, false)):
		return { "ok": false, "msg": "已与该势力通商。" }
	var fail_prob: float = clampf(0.3 - _intel() / 300.0, 0.0, 0.3)
	# 【修复】fail_prob 语义是「失败率」，判定必须落在失败侧。旧代码写成
	# randf() > fail_prob，属性越高失败率被压到下限（0.05）反而 95% 失败，
	# 六个外交手段集体反向，且礼金已在判定前扣除、失败不退还。
	if randf() < fail_prob:
		return { "ok": false, "msg": "商路未开，通商失败（失败率 %.0f%%）。" % (fail_prob * 100.0) }
	modify(faction_id, 2)
	_set_state(faction_id, K_TRADE, true)
	return { "ok": true, "msg": "通商成功！货物互通，关系 +2。" }


## D-08 §3.2.3 宣战：前置 关系≤-30；必成，关系-50 进入战争。
static func war(faction_id: int) -> Dictionary:
	if faction_id <= 0:
		return { "ok": false, "msg": "无效的势力。" }
	if get_relation(faction_id) > -30:
		return { "ok": false, "msg": "关系不足（需求≤-30），尚不可宣战。" }
	if bool(get_state(faction_id).get(K_WAR, false)):
		return { "ok": false, "msg": "已与该势力处于战争状态。" }
	modify(faction_id, -50)
	_set_state(faction_id, K_WAR, true)
	return { "ok": true, "msg": "正式宣战！双方关系 -50。" }


## D-08 §3.2.4 联姻：前置 关系≥70 + 使者魅力≥60 + 金≥2000；成功关系+30 缔结婚亲。
## （适婚女将校验依赖 M11 字段，Demo 未实装，暂缺）
static func marriage(faction_id: int) -> Dictionary:
	if faction_id <= 0:
		return { "ok": false, "msg": "无效的势力。" }
	if get_relation(faction_id) < 70:
		return { "ok": false, "msg": "关系不足（需求≥70），难结姻亲。" }
	if _charm() < 60:
		return { "ok": false, "msg": "使者魅力不足（需求≥60），难登门提亲。" }
	if GameState.gold < 2000:
		return { "ok": false, "msg": "聘礼需 2000 金。" }
	if bool(get_state(faction_id).get(K_MARRIAGE, false)):
		return { "ok": false, "msg": "已与对方联姻。" }
	GameState.add_gold(-2000)
	var fail_prob: float = clampf(0.4 - _charm() / 200.0 - 2000.0 / 10000.0, 0.1, 0.6)
	# 【修复】fail_prob 语义是「失败率」，判定必须落在失败侧。旧代码写成
	# randf() > fail_prob，属性越高失败率被压到下限（0.05）反而 95% 失败，
	# 六个外交手段集体反向，且礼金已在判定前扣除、失败不退还。
	if randf() < fail_prob:
		return { "ok": false, "msg": "联姻未成（失败率 %.0f%%）。" % (fail_prob * 100.0) }
	modify(faction_id, 30)
	_set_state(faction_id, K_MARRIAGE, true)
	return { "ok": true, "msg": "联姻成功！缔结姻亲，关系 +30。" }


## D-08 §3.2.5 离间：前置 密探智力≥70 + 金≥500；成功关系-5，暴露则关系-30。
## 被发现概率 = clamp(0.3 + 目标君主智力/300, 0.1, 0.5)
static func alienate(faction_id: int) -> Dictionary:
	if faction_id <= 0:
		return { "ok": false, "msg": "无效的势力。" }
	if _intel() < 70:
		return { "ok": false, "msg": "智力不足（需求≥70），难以离间。" }
	if GameState.gold < 500:
		return { "ok": false, "msg": "需 500 金安插密探。" }
	GameState.add_gold(-500)
	var fail_prob: float = clampf(0.6 - _intel() / 200.0 - 500.0 / 3000.0, 0.15, 0.85)
	var found_prob: float = clampf(0.3 + _lord_intel(faction_id) / 300.0, 0.1, 0.5)
	# 【修复】fail_prob 语义是「失败率」，判定必须落在失败侧。旧代码写成
	# randf() > fail_prob，属性越高失败率被压到下限（0.05）反而 95% 失败，
	# 六个外交手段集体反向，且礼金已在判定前扣除、失败不退还。
	if randf() < fail_prob:
		if randf() < found_prob:
			modify(faction_id, -30)
			return { "ok": false, "msg": "密探暴露，关系 -30。", "found": true }
		return { "ok": false, "msg": "离间未成。" }
	if randf() < found_prob:
		modify(faction_id, -30)
		return { "ok": true, "msg": "离间被识破，反遭记恨，关系 -30。", "found": true }
	modify(faction_id, -5)
	return { "ok": true, "msg": "离间成功，敌方人心浮动，关系 -5。" }


## D-08 §3.2.6 造谣：前置 密探智力≥60 + 金≥300；成功关系-5，暴露则关系-20 + 名声-5。
## 被发现概率 = clamp(0.4 + 目标君主智力/300, 0.15, 0.6)
static func rumor(faction_id: int) -> Dictionary:
	if faction_id <= 0:
		return { "ok": false, "msg": "无效的势力。" }
	if _intel() < 60:
		return { "ok": false, "msg": "智力不足（需求≥60）。" }
	if GameState.gold < 300:
		return { "ok": false, "msg": "需 300 金。" }
	GameState.add_gold(-300)
	var fail_prob: float = clampf(0.5 - _intel() / 200.0, 0.1, 0.7)
	var found_prob: float = clampf(0.4 + _lord_intel(faction_id) / 300.0, 0.15, 0.6)
	# 【修复】fail_prob 语义是「失败率」，判定必须落在失败侧。旧代码写成
	# randf() > fail_prob，属性越高失败率被压到下限（0.05）反而 95% 失败，
	# 六个外交手段集体反向，且礼金已在判定前扣除、失败不退还。
	if randf() < fail_prob:
		if randf() < found_prob:
			modify(faction_id, -20)
			GameState.add_fame(-5)
			return { "ok": false, "msg": "谣言遭识破，声名受损（名声 -5），关系 -20。", "found": true }
		return { "ok": false, "msg": "造谣未成。" }
	modify(faction_id, -5)
	return { "ok": true, "msg": "谣言四起，敌方声望受损，关系 -5。" }


## D-08 §3.2.7 破坏：前置 关系≤-30 + 密探武力≥70 + 智力≥50 + 金≥800；成功敌城受损。
## 被发现概率 = clamp(0.5 + 目标君主智力/300, 0.2, 0.7)；暴露 → 关系-40（跌入敌对区间）。
static func sabotage(faction_id: int) -> Dictionary:
	if faction_id <= 0:
		return { "ok": false, "msg": "无效的势力。" }
	if get_relation(faction_id) > -30:
		return { "ok": false, "msg": "关系不足（需求≤-30）。" }
	if _force() < 70:
		return { "ok": false, "msg": "武力不足（需求≥70）。" }
	if _intel() < 50:
		return { "ok": false, "msg": "智力不足（需求≥50），难潜敌城。" }
	if GameState.gold < 800:
		return { "ok": false, "msg": "需 800 金。" }
	GameState.add_gold(-800)
	var fail_prob: float = clampf(0.55 - _force() / 200.0 - _intel() / 400.0, 0.2, 0.8)
	var found_prob: float = clampf(0.5 + _lord_intel(faction_id) / 300.0, 0.2, 0.7)
	# 【修复】fail_prob 语义是「失败率」，判定必须落在失败侧。旧代码写成
	# randf() > fail_prob，属性越高失败率被压到下限（0.05）反而 95% 失败，
	# 六个外交手段集体反向，且礼金已在判定前扣除、失败不退还。
	if randf() < fail_prob:
		if randf() < found_prob:
			modify(faction_id, -40)
			return { "ok": false, "msg": "破坏暴露，进入敌对，关系 -40。", "found": true }
		return { "ok": false, "msg": "破坏未成。" }
	return { "ok": true, "msg": "破坏成功，敌城受损。" }


## 月度外交维持结算（AIService / 月推进调用）：结盟 -2/月、通商 +2/月、联姻 -1/月。
static func monthly_relations() -> void:
	for fid in GameState.diplomacy.keys():
		var fid_int := int(fid)
		var s: Dictionary = GameState.diplomacy[fid]
		if bool(s.get(K_ALLIANCE, false)):
			modify(fid_int, -2)
		if bool(s.get(K_TRADE, false)):
			modify(fid_int, 2)
		if bool(s.get(K_MARRIAGE, false)):
			modify(fid_int, -1)
