extends RefCounted
class_name ItemEconomyService
## 集市（金币兑换）/ 商城（珍玩阁）/ 看广告（激励视频）三条获取途径的规则层。
##
## 【第七十五轮·用户拍板的分层投放】
## 「除了任务奖励以外，将一些很强的物品或者设置很难获取的一些物品改为游戏商城获取，
##   首先一些简单的，可以通过任务奖励的资金进行兑换，构建一些需要在游戏内反复看广告获取的资金或者物品。」
## 三条途径的职责边界（本类强制，_verify_item_economy.py 锁死）：
##   集市 exchange —— 基础材料与消耗品。玩家做任务攒金来买，是**大量低价值消耗**的主出口。
##   商城 mall     —— 史诗/传说装备与宝物。价格数倍于 items6.price，靠长线攒金。
##   看广告 ad     —— 每日限次、24h 冷却的**补给**（材料/金/粮/铁）。绝不产出装备。
##
## 分层理由（不是拍脑袋，是数据实测）：items6 的 113 件配方引用了 54 种基础材料，
## 其中 33 种改动前完全不可获取 ⇒ 整条锻造链是死的。集市补的就是这 33 种；
## 而装备类（头盔/护甲/武器/宝物/坐骑）走商城与锻造两条路，不进集市（否则价格体系全崩）。
##
## 商城与集市共用一套扣金流程（_spend），都写今日限次到 GameState 的日号字典。


static func _cfg() -> Dictionary:
	return DataManager.get_record("item_economy", "root")


static func _exchange_cfg() -> Dictionary:
	return _cfg().get("exchange", {})


static func _mall_cfg() -> Dictionary:
	return _cfg().get("mall", {})


static func _ad_cfg() -> Dictionary:
	return _cfg().get("reward_ad", {})


## ---------- 集市（金币兑换基础材料） ----------

static func exchange_daily_limit() -> int:
	return maxi(0, int(_exchange_cfg().get("daily_limit", 0)))


static func exchange_used_today() -> int:
	return int(GameState.exchange_today.get(GameState.total_days(), 0))


static func exchange_left_today() -> int:
	var lim := exchange_daily_limit()
	if lim <= 0:
		return -1
	return maxi(0, lim - exchange_used_today())


## 集市货单（附今日可兑标记）
static func exchange_goods() -> Array:
	var rows: Array = []
	for raw in _exchange_cfg().get("goods", []):
		if not (raw is Dictionary):
			continue
		var iid := int(raw.get("item_id", 0))
		if iid <= 0:
			continue
		var r: Dictionary = raw.duplicate()
		r["affordable"] = GameState.gold >= int(raw.get("price", 0))
		rows.append(r)
	return rows


static func can_exchange(item6_id: int) -> Dictionary:
	var g := _find_exchange(item6_id)
	if g.is_empty():
		return {"ok": false, "reason": "集市无此货"}
	if exchange_left_today() == 0:
		return {"ok": false, "reason": "今日兑换次数已尽"}
	var price := int(g.get("price", 0))
	if GameState.gold < price:
		return {"ok": false, "reason": "金不足（需 %d）" % price}
	return {"ok": true, "reason": "", "price": price}


static func exchange(item6_id: int) -> Dictionary:
	var gate := can_exchange(item6_id)
	if not bool(gate.get("ok", false)):
		return {"ok": false, "msg": str(gate.get("reason", "不可兑换"))}
	var g := _find_exchange(item6_id)
	var price := int(g.get("price", 0))
	GameState.add_gold(-price)
	GameState.add_item(str(item6_id), 1)
	GameState.exchange_today[GameState.total_days()] = exchange_used_today() + 1
	var name := str(g.get("name", str(item6_id)))
	return {"ok": true, "msg": "购得 %s（%d 金）" % [name, price], "item_id": item6_id}


static func _find_exchange(item6_id: int) -> Dictionary:
	for raw in _exchange_cfg().get("goods", []):
		if raw is Dictionary and int(raw.get("item_id", 0)) == item6_id:
			return raw
	return {}


## ---------- 商城（珍玩阁：强力装备/宝物） ----------

static func mall_goods() -> Array:
	var rows: Array = []
	for raw in _mall_cfg().get("goods", []):
		if not (raw is Dictionary):
			continue
		var iid := int(raw.get("item_id", 0))
		if iid <= 0:
			continue
		var r: Dictionary = raw.duplicate()
		# 商城不加每日限次：它已经是"贵"这一侧的约束，再叠日限会变成双重门槛。
		r["affordable"] = GameState.gold >= int(raw.get("price", 0))
		rows.append(r)
	return rows


static func can_buy_mall(item6_id: int) -> Dictionary:
	var g := _find_mall(item6_id)
	if g.is_empty():
		return {"ok": false, "reason": "商城无此物"}
	var price := int(g.get("price", 0))
	if GameState.gold < price:
		return {"ok": false, "reason": "金不足（需 %d）" % price}
	return {"ok": true, "reason": "", "price": price}


static func buy_mall(item6_id: int) -> Dictionary:
	var gate := can_buy_mall(item6_id)
	if not bool(gate.get("ok", false)):
		return {"ok": false, "msg": str(gate.get("reason", "不可购买"))}
	var g := _find_mall(item6_id)
	var price := int(g.get("price", 0))
	GameState.add_gold(-price)
	GameState.add_item(str(item6_id), 1)
	var name := str(g.get("name", str(item6_id)))
	return {"ok": true, "msg": "购得 %s（%d 金）" % [name, price], "item_id": item6_id}


static func _find_mall(item6_id: int) -> Dictionary:
	for raw in _mall_cfg().get("goods", []):
		if raw is Dictionary and int(raw.get("item_id", 0)) == item6_id:
			return raw
	return {}


## ---------- 看广告（激励视频的模拟实现） ----------

static func ad_daily_limit() -> int:
	return maxi(0, int(_ad_cfg().get("ad_daily_limit", 0)))


static func ad_cooldown_hours() -> int:
	return maxi(0, int(_ad_cfg().get("cooldown_hours", 24)))


static func ad_used_today() -> int:
	return int(GameState.ad_today.get(GameState.total_days(), 0))


static func ad_left_today() -> int:
	var lim := ad_daily_limit()
	if lim <= 0:
		return -1
	return maxi(0, lim - ad_used_today())


## 某档位距上次领取过了多少**游戏日**。ad_claimed 存的是绝对日号。
## 用日号而非挂钟小时：游戏内一天 = 15 秒现实时间（MEMORY 玩法铁律），
## 挂钟小时在单机节奏下毫无意义，玩家一天能打 20 场仗。
static func ad_cooldown_left(tier_id: String) -> int:
	var last := int(GameState.ad_claimed.get(tier_id, -1))
	if last < 0:
		return 0
	return maxi(0, ad_cooldown_hours() - (GameState.total_days() - last))


## 广告档位（附可领/冷却标记）
static func ad_tiers() -> Array:
	var rows: Array = []
	for raw in _ad_cfg().get("tiers", []):
		if raw is Dictionary:
			var r: Dictionary = raw.duplicate()
			var cd := ad_cooldown_left(str(raw.get("id", "")))
			r["cooldown"] = cd
			r["ready"] = cd == 0
			rows.append(r)
	return rows


## 能否领取某档（冷却未到 / 今日次数已尽 / 钱无消耗故不校验金）
static func can_watch_ad(tier_id: String) -> Dictionary:
	var t := _find_ad(tier_id)
	if t.is_empty():
		return {"ok": false, "reason": "无此档位"}
	var cd := ad_cooldown_left(tier_id)
	if cd > 0:
		return {"ok": false, "reason": "冷却中（还需 %d 日）" % cd}
	if ad_left_today() == 0:
		return {"ok": false, "reason": "今日次数已尽"}
	return {"ok": true, "reason": ""}


## 看一次广告并领奖。
##
## 【防刷是这里的核心，不是附带】三重闸门：
## ① 今日总次数（日号键，换日归零，重进档不刷新）
## ② 单档位冷却（上次领取日号 + cooldown_hours）
## ③ 奖励内容不含装备（数据侧由 _verify_item_economy.py 断言 cat_major 不为 2~7）
## 只做 ①② 的话，玩家可以每分钟重进档刷爆材料，与商城定价直接冲突。
static func watch_ad(tier_id: String) -> Dictionary:
	var gate := can_watch_ad(tier_id)
	if not bool(gate.get("ok", false)):
		return {"ok": false, "msg": str(gate.get("reason", "不可领取"))}
	var t := _find_ad(tier_id)
	var got: Array[String] = []

	var gold := int(t.get("gold", 0))
	if gold > 0:
		GameState.add_gold(gold)
		got.append("金 %d" % gold)
	var food := int(t.get("food", 0))
	if food > 0:
		GameState.add_food(food)
		got.append("粮 %d" % food)
	var iron := int(t.get("iron", 0))
	if iron > 0:
		GameState.add_iron(iron)
		got.append("铁 %d" % iron)
	for m in t.get("items", []):
		if not (m is Dictionary):
			continue
		var iid := int(m.get("item_id", 0))
		var cnt := maxi(1, int(m.get("count", 1)))
		if iid <= 0:
			continue
		GameState.add_item(str(iid), cnt)
		var rec := CharacterService.resolve_item6(iid)
		got.append("%s ×%d" % [str(rec.get("name", str(iid))), cnt])

	GameState.ad_today[GameState.total_days()] = ad_used_today() + 1
	GameState.ad_claimed[tier_id] = GameState.total_days()

	var msg := "观览之获：%s" % "、".join(got)
	return {"ok": true, "msg": msg, "tier_id": tier_id}


static func _find_ad(tier_id: String) -> Dictionary:
	for raw in _ad_cfg().get("tiers", []):
		if raw is Dictionary and str(raw.get("id", "")) == tier_id:
			return raw
	return {}
