class_name FactionService
extends RefCounted
## 势力规则层（FactionService）
## 职责：M12「路径A · 投靠」核心闭环 —— 投靠势力、官阶成长、升官结算、封地、专属兵种。
## 全部 static 纯函数（服务层范式，参考 MainlineService / RegionService）。
## 数值/门槛集中在此层，UI 禁止内联公式；数据来自 factions6 / cities.json。

## 可投靠的三大势力（factions6.faction_line）：蜀线=刘备、魏线=曹操、吴线=孙策。
const AFFILIATION_LINES: Array[String] = ["蜀线", "魏线", "吴线"]
const AFFILIATION_ALL_LINES: Array[String] = ["蜀线", "魏线", "吴线"]

## 官阶中文名：0平民 / 1兵长 / 2校尉 / 3将军 / 4太守
const RANK_NAMES: Array[String] = ["平民", "兵长", "校尉", "将军", "太守"]
const RANK_GENERAL := 3
const RANK_GOVERNOR := 4

## 升官门槛（D-08 1.2.1）：键为「升到该官阶」，值为 {merit, intimacy, cities}。
##   校尉=功勋≥100；将军=功勋≥300+亲密度≥50；太守=功勋≥600+亲密度≥80+势力城数≥3。
const RANK_REQUIREMENTS := {
	2: { "merit": 100, "intimacy": 0,  "cities": 0 },
	3: { "merit": 300, "intimacy": 50, "cities": 0 },
	4: { "merit": 600, "intimacy": 80, "cities": 3 },
}

## 专属兵种（D-08 §4.3）：affiliation_id -> 按官阶 1~4 逐阶解锁的兵种名清单（升到更高官阶解锁更多）。
const SPECIAL_TROOPS := {
	15: [ "长枪兵", "连弩兵", "龙枪兵", "龙骑兵" ],   # 刘备
	16: [ "刀盾兵", "青州兵", "虎豹骑", "重甲骑" ],   # 曹操
	5:  [ "轻步兵", "江东水军", "解烦兵", "横江射士" ], # 孙策
}

## 投靠时初始化与君主的关系值（D-08 投靠关系，中立偏友善）
const JOIN_RELATION := 50
## 封地标识字段（权限字段：产出比例，M12 将军/太守封地数据与权限）
const FEUD_PRODUCTION_RATE := 0.5   ## 封地产出 50% 归玩家
const FEUD_BUCKET_MAX := 5          ## 太守封一「郡」最多 3-5 城


## ---------- 查询 ----------

## 是否已加入某势力
static func is_joined(faction_id: int = -1) -> bool:
	if GameState.affiliation == 0:
		return false
	if faction_id > 0:
		return GameState.affiliation == faction_id
	return true


## 官阶中文名
static func official_rank_name(rank: int) -> String:
	return RANK_NAMES[clampi(rank, 0, RANK_NAMES.size() - 1)]


## 当前官阶中文名
static func current_rank_name() -> String:
	return official_rank_name(GameState.official_rank)


## 可投靠势力列表（从 factions6 读）。
## 返回 [{ id, name, capital, initial_relation, faction_line }]
static func available_affiliations() -> Array:
	var out: Array = []
	for f in DataManager.get_table("factions6"):
		if f is not Dictionary:
			continue
		var line := str(f.get("faction_line", ""))
		if line not in AFFILIATION_LINES:
			continue
		var fid := int(f.get("id", 0))
		out.append({
			"id": fid,
			"name": str(f.get("name", "")),
			"capital": _faction_capital_name(fid),
			"capital_id": _faction_capital_id(fid),
			"initial_relation": JOIN_RELATION,
			"faction_line": line,
		})
	out.sort_custom(func(a, b): return int(a["id"]) < int(b["id"]))
	return out


## 当前君主英雄 id（factions6.lord_role_id）
static func faction_lord_id(faction_id: int = -1) -> int:
	var fid := faction_id if faction_id > 0 else GameState.affiliation
	if fid <= 0:
		return 0
	var f := DataManager.get_faction6(fid)
	if f.is_empty():
		return 0
	return int(f.get("lord_role_id", 0))


## 与当前势力君主的亲密度（从 GameState.party 中该君主好感取，未在队则为 0）
static func faction_lord_intimacy(faction_id: int = -1) -> int:
	var lord := faction_lord_id(faction_id)
	if lord <= 0:
		return 0
	for h in GameState.party:
		if int(h.get("hero_id", 0)) == lord or str(h.get("hero_id", "")) == str(lord):
			return int(h.get("intimacy", 0))
	return 0


## 势力城数（cities.json 归属该势力的城池数量）
static func faction_city_count(faction_id: int = -1) -> int:
	var fid := faction_id if faction_id > 0 else GameState.affiliation
	return _faction_cities(fid).size()


## ---------- 投靠（两段式）----------
## 【流程】① 外交面板「投靠」→ request_join：只表明意向（不加入）；
##         ② 玩家亲自前往该势力都城 → 面见主公献上投名状（金钱 500）→ pledge_at_capital 才正式加入。

## 投名状金额（小任务：面见主公时的入门献金）
const JOIN_PLEDGE_GOLD := 500

## 势力都城信息（供外交面板/任务卡展示「去哪里找主公」）
static func capital_city_id(faction_id: int) -> String:
	return _faction_capital_id(faction_id)


## 表明投靠意向。前置与 join 相同（未投靠/未自立/势力可投），但不改变归属。
static func request_join(faction_id: int) -> Dictionary:
	if faction_id <= 0:
		return { "ok": false, "msg": "无效的势力。" }
	if GameState.affiliation != 0:
		return { "ok": false, "msg": "你已投靠 %s，不可再投靠他人。" % faction_name() }
	if GameState.is_self_rule:
		return { "ok": false, "msg": "你已自立建国，无法再投靠他人。" }
	var f := DataManager.get_faction6(faction_id)
	if f.is_empty() or str(f.get("faction_line", "")) not in AFFILIATION_LINES:
		return { "ok": false, "msg": "该势力当前不可投靠。" }
	GameState.join_intent = faction_id
	return {
		"ok": true,
		"msg": "你向「%s」表明了投靠意向。前往其都城【%s】面见主公，献上投名状（金钱 %d）即可入门。"
			% [_faction_name(faction_id), _faction_capital_name(faction_id), JOIN_PLEDGE_GOLD],
	}


## 在主公面前献投名状（由城池场景在「该势力都城」内调用）。
## 成功 = 正式加入（join）并扣除投名状献金。
static func pledge_at_capital(city: Dictionary) -> Dictionary:
	if GameState.join_intent <= 0:
		return { "ok": false, "msg": "你尚未表明投靠意向。" }
	if GameState.affiliation != 0:
		GameState.join_intent = 0
		return { "ok": false, "msg": "你已有归属，无需再投靠。" }
	var fid := GameState.join_intent
	var cap_id := _faction_capital_id(fid)
	if str(city.get("id", "")) != cap_id:
		return { "ok": false, "msg": "主公并不在此城。请前往其都城【%s】。"
			% _faction_capital_name(fid) }
	if GameState.gold < JOIN_PLEDGE_GOLD:
		return { "ok": false, "msg": "投名状需金钱 %d，你的盘缠不够。" % JOIN_PLEDGE_GOLD }
	var r := join(fid)
	if bool(r.get("ok", false)):
		GameState.add_gold(-JOIN_PLEDGE_GOLD)
		GameState.join_intent = 0
		EventBus.toast.emit("献上投名状（金钱 %d）" % JOIN_PLEDGE_GOLD)
		r["msg"] = str(r.get("msg", "")) + "（献上投名状 金钱 %d）" % JOIN_PLEDGE_GOLD
	return r


## 放弃投靠意向（任务卡/都城弹窗里的反悔出口）
static func cancel_join_intent() -> void:
	GameState.join_intent = 0


## 投靠势力。前置：当前未加入任何势力 + 未自立。
## 成功：设定 affiliation、官阶置兵长(1)、初始化关系、写入剧情 flag。
static func join(faction_id: int) -> Dictionary:
	if faction_id <= 0:
		return { "ok": false, "msg": "无效的势力。" }
	if GameState.affiliation != 0:
		return { "ok": false, "msg": "你已投靠 %s，不可再投靠他人。" % faction_name() }
	if GameState.is_self_rule:
		return { "ok": false, "msg": "你已自立建国，无法再投靠他人。" }
	var f := DataManager.get_faction6(faction_id)
	if f.is_empty() or str(f.get("faction_line", "")) not in AFFILIATION_LINES:
		return { "ok": false, "msg": "该势力当前不可投靠。" }

	GameState.affiliation = faction_id
	GameState.official_rank = 1          # 投靠即授兵长
	GameState.merit = 0
	GameState.faction_relations[faction_id] = JOIN_RELATION
	var flag := "faction_joined_%d" % faction_id
	if not GameState.story_flags.has(flag):
		GameState.story_flags.append(flag)
	EventBus.faction_relation_changed.emit(str(faction_id), JOIN_RELATION)
	return {
		"ok": true,
		"faction_id": faction_id,
		"rank": GameState.official_rank,
		"rank_name": official_rank_name(GameState.official_rank),
		"msg": "你加入「%s」，受封兵长。" % faction_name(),
	}


## 主动请辞（请辞降平民，保留封地记录）。返回 {ok,msg}
static func resign() -> Dictionary:
	if GameState.affiliation == 0:
		return { "ok": false, "msg": "你并未投靠任何势力。" }
	GameState.affiliation = 0
	GameState.official_rank = 0
	return { "ok": true, "rank_name": "平民", "msg": "你已辞去官职，归为平民。" }


## ---------- 升官 ----------

## 升到 rank_to 所需门槛：{ merit, intimacy, cities }
static func rank_requirements(rank_to: int) -> Dictionary:
	var req: Dictionary = RANK_REQUIREMENTS.get(rank_to, {})
	if req.is_empty():
		return { "merit": 0, "intimacy": 0, "cities": 0 }
	return {
		"merit": int(req.get("merit", 0)),
		"intimacy": int(req.get("intimacy", 0)),
		"cities": int(req.get("cities", 0)),
	}


## 校验是否可升官到下一阶。返回 { ok, rank_to, merit_gap, intimacy_gap, cities_gap, msg }
static func can_promote() -> Dictionary:
	if GameState.is_self_rule:
		return { "ok": false, "rank_to": GameState.official_rank, "msg": "已自立，不再受制于人。" }
	if GameState.affiliation == 0:
		return { "ok": false, "rank_to": 0, "msg": "尚未投靠任何势力。" }
	var cur := GameState.official_rank
	if cur < 1 or cur >= RANK_GOVERNOR:
		return { "ok": false, "rank_to": cur, "msg": "已达最高官阶（太守）。" }
	var nxt := cur + 1
	var req := rank_requirements(nxt)
	var now_merit := GameState.merit
	var now_int := faction_lord_intimacy()
	var now_city := faction_city_count()
	var m_gap := maxi(0, int(req["merit"]) - now_merit)
	var i_gap := maxi(0, int(req["intimacy"]) - now_int)
	var c_gap := maxi(0, int(req["cities"]) - now_city)
	if m_gap == 0 and i_gap == 0 and c_gap == 0:
		return {
			"ok": true, "rank_to": nxt,
			"merit_gap": 0, "intimacy_gap": 0, "cities_gap": 0,
			"msg": "满足升官条件，可晋升为%s。" % official_rank_name(nxt),
		}
	return {
		"ok": false, "rank_to": nxt,
		"merit_gap": m_gap, "intimacy_gap": i_gap, "cities_gap": c_gap,
		"msg": "功勋差%d、亲密度差%d、势力城数差%d" % [m_gap, i_gap, c_gap],
	}


## 升官一级：校验通过则晋升 + 授封地。返回 { ok, rank, rank_name, feud, msg }
static func promote() -> Dictionary:
	var c := can_promote()
	if not bool(c.get("ok", false)):
		return { "ok": false, "rank": GameState.official_rank, "msg": str(c.get("msg", "未满足升官条件。")) }
	var nxt := int(c["rank_to"])
	GameState.official_rank = nxt
	var feud: Dictionary = grant_feud(nxt)
	return {
		"ok": true,
		"rank": nxt,
		"rank_name": official_rank_name(nxt),
		"feud": feud,
		"msg": "你晋升为「%s」！%s" % [official_rank_name(nxt), str(feud.get("grant_msg", ""))],
	}


## ---------- 功勋 ----------

## 加功勋。返回累计功勋
static func add_merit(amount: int) -> int:
	GameState.merit = maxi(0, GameState.merit + amount)
	return GameState.merit


## 按金额捐金换功勋（金100→1功勋）。
## 【P1-5 审计修复】每日功勋上限 DAILY_MERIT_CAP：防「刷钱→捐金」直通官阶，
## 捐金路线升到太守（600 功勋）需约 60 个游戏日，慢于战役路线但始终可行。
## 超出上限部分不收金（按实际计入功勋的金额扣款）。返回 { ok, added, msg }
const DAILY_MERIT_CAP := 10

static func donate_gold(amount: int) -> Dictionary:
	if amount < 100:
		return { "ok": false, "added": 0, "msg": "捐款至少需要 100 金。" }
	if GameState.gold < amount:
		return { "ok": false, "added": 0, "msg": "金钱不足。" }
	# 惰性跨日重置（不接信号，读档/跳日自动生效）
	if GameState.merit_today_day != GameState.day:
		GameState.merit_today_day = GameState.day
		GameState.merit_today = 0
	var room := DAILY_MERIT_CAP - GameState.merit_today
	if room <= 0:
		return { "ok": false, "added": 0, "msg": "今日功勋已满（每日上限 %d），明日再来。" % DAILY_MERIT_CAP }
	var full := int(amount / 100)
	var gained := mini(full, room)
	GameState.add_gold(-gained * 100)
	GameState.merit_today += gained
	add_merit(gained)
	var tail := "" if gained >= full else "（今日功勋额度仅余 %d，超出部分未收取）" % gained
	return { "ok": true, "added": gained, "msg": "捐金 %d，获得功勋 +%d%s。" % [gained * 100, gained, tail] }


## ---------- 封地 ----------

## 当前官阶可封的城池：
##   将军(3)：封 1 座一般城（非首都）；太守(4)：封 1 郡（至多 FEUD_BUCKET_MAX 城）。
## 从 cities.json 按当前势力地盘取，剔除已封地。返回 { level, cities:[id], size, grant_msg }
static func get_feudal_city(rank: int) -> Dictionary:
	if GameState.affiliation == 0:
		return { "level": "", "cities": [], "size": 0, "grant_msg": "" }
	var pool := _unfeudal_cities()
	if pool.is_empty():
		return { "level": "", "cities": [], "size": 0, "grant_msg": "" }
	if rank >= RANK_GOVERNOR:
		var ids: Array = []
		for c in pool.slice(0, FEUD_BUCKET_MAX):
			ids.append(str(c.get("id", "")))
		return {
			"level": "郡", "cities": ids, "size": ids.size(),
			"grant_msg": "受封 1 郡（%s），产出部分归你所有。" % "、".join(ids),
		}
	# 将军：1 座一般城（优先非首都）
	var general: Array = []
	for c in pool:
		if not bool(c.get("is_capital", false)):
			general.append(c)
	if general.is_empty():
		general = pool
	if general.is_empty():
		return { "level": "县", "cities": [], "size": 0, "grant_msg": "" }
	var cid := str(general[0].get("id", ""))
	return {
		"level": "县", "cities": [cid], "size": 1,
		"grant_msg": "受封一般城，产出部分归你所有。",
	}


## 授予封地：把 get_feudal_city(rank) 判定结果写入 GameState.feudal_cities。返回同 get_feudal_city
static func grant_feud(rank: int) -> Dictionary:
	var feud := get_feudal_city(rank)
	for cid in feud.get("cities", []):
		var sid := str(cid)
		if not GameState.feudal_cities.has(sid):
			GameState.feudal_cities.append(sid)
	return feud


## ---------- 专属兵种 ----------

## 当前官阶可解锁的专属兵种名清单（读 D-08 §4.3 内置表，按官阶 1~4 逐阶解锁）。
## 未加入势力返回空数组。
static func special_troops(rank: int = -1) -> Array:
	if GameState.affiliation == 0:
		return []
	var r := clampi(rank if rank >= 0 else GameState.official_rank, 0, 4)
	if r <= 0:
		return []
	var list: Array = SPECIAL_TROOPS.get(GameState.affiliation, [])
	return (list.slice(0, r) as Array).duplicate()


## ---------- 辅助 ----------

## 当前势力中文名
static func faction_name(faction_id: int = -1) -> String:
	var fid := faction_id if faction_id > 0 else GameState.affiliation
	return _faction_name(fid)


static func _faction_name(fid: int) -> String:
	if fid <= 0:
		return "无"
	var f := DataManager.get_faction6(fid)
	return str(f.get("name", "无名势力"))


## 势力首都（cities.json 中 is_capital 的第一个该势力城）
static func _faction_capital_name(fid: int) -> String:
	var c := _faction_capital(fid)
	return str(c.get("name", "")) if not c.is_empty() else ""


static func _faction_capital_id(fid: int) -> String:
	var c := _faction_capital(fid)
	return str(c.get("id", "")) if not c.is_empty() else ""


static func _faction_capital(fid: int) -> Dictionary:
	for c in _faction_cities(fid):
		if bool(c.get("is_capital", false)):
			return c
	# 无首都标记则取第一座
	var list := _faction_cities(fid)
	return list[0] if not list.is_empty() else {}


## 该势力地盘的全部城池（cities.json faction_id 匹配）
static func _faction_cities(fid: int) -> Array:
	var out: Array = []
	if fid <= 0:
		return out
	for c in DataManager.get_table("cities"):
		if c is Dictionary and int(c.get("faction_id", 0)) == fid:
			out.append(c)
	return out


## 当前势力地盘下尚未封地的城池
static func _unfeudal_cities() -> Array:
	var out: Array = []
	for c in _faction_cities(GameState.affiliation):
		if not GameState.feudal_cities.has(str(c.get("id", ""))):
			out.append(c)
	return out
