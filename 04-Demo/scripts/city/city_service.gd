extends Node
class_name CityService
## 城池服务层（CityService）
## 职责：把城池经营的**规则计算**从 UI 中剥离出来，作为纯逻辑层。
##       —— UI 只负责显示与点击，所有"能不能做、要花多少钱、做了有什么后果"都在这里判定。
##
## 设计原则：
##   1. 不持有任何场景节点引用（可被独立测试）
##   2. 所有数值来自 JSON 配置表，不在代码里硬编码
##   3. 每个操作返回 {ok: bool, msg: String, ...} 结构，UI 直接显示 msg
##
## 覆盖：征兵 / 练兵 / 武将招募 / 买物 / 卖物 / 内政（民心、城防）

## 城池等级对物价的影响：等级越高，物资越贵（偏远城镇物价高）
const PRICE_LEVEL_FACTOR := 0.08


## ---------- 通用工具 ----------

## 商品买入价 = 基础价 × 城池系数
func buy_price(base_price: int, city_level: int) -> int:
	var f := 1.0 + float(city_level - 2) * PRICE_LEVEL_FACTOR
	return maxi(1, int(round(float(base_price) * maxf(0.6, f))))


## 商品卖出价 = 基础价 × 回收比例
func sell_price(base_price: int, city_level: int) -> int:
	var ratio := float(DataManager.get_shop_settings().get("sell_ratio", 0.55))
	return maxi(1, int(round(float(buy_price(base_price, city_level)) * ratio)))


func _fail(msg: String) -> Dictionary:
	return { "ok": false, "msg": msg }


## ---------- 征兵 ----------

## 兵种是否可在该城征募
## 返回 { ok: bool, reason: String }
func can_recruit_unit(city_id: String, unit_id: String) -> Dictionary:
	var city := DataManager.get_city(city_id)
	if city.is_empty():
		return { "ok": false, "reason": "城池数据缺失" }

	var cfg := DataManager.get_barracks_unit(unit_id)
	if cfg.is_empty():
		return { "ok": false, "reason": "该兵种不可征募" }

	var level := int(city.get("level", 1))
	if level < int(cfg.get("unlock_city_level", 1)):
		return { "ok": false, "reason": "需城池等级 %d" % int(cfg.get("unlock_city_level", 1)) }

	# 城池建筑要求：必须有兵营
	var buildings: Array = city.get("buildings", [])
	if not ("barracks" in buildings):
		return { "ok": false, "reason": "此城无兵营" }

	# 区域限定
	var req_region := str(cfg.get("require_region", ""))
	if not req_region.is_empty() and str(city.get("region", "")) != req_region:
		return { "ok": false, "reason": "仅 %s 地区可征" % req_region }

	# 势力限定
	var req_faction := str(cfg.get("require_faction", ""))
	if not req_faction.is_empty() and str(city.get("faction", "")) != req_faction:
		return { "ok": false, "reason": "需 %s 势力城池" % req_faction }

	# 特产限定
	var req_spec: Array = cfg.get("require_specialty", [])
	if not req_spec.is_empty() and not (str(city.get("specialty", "")) in req_spec):
		return { "ok": false, "reason": "此城无对应条件（需 %s）" % "、".join(PackedStringArray(req_spec)) }

	# 民心限定
	var req_morale := int(cfg.get("require_morale", 0))
	if req_morale > 0 and GameState.get_city_morale(city_id) < req_morale:
		return { "ok": false, "reason": "民心不足（需 %d）" % req_morale }

	return { "ok": true, "reason": "" }


## 计算某兵种征 n 兵的成本
func recruit_cost(unit_id: String, count: int) -> Dictionary:
	var cfg := DataManager.get_barracks_unit(unit_id)
	var batches := float(count) / 10.0
	return {
		"gold": int(round(float(cfg.get("gold_per_10", 40)) * batches)),
		"food": int(round(float(cfg.get("food_per_10", 20)) * batches)),
	}


## 该城今日还可征多少兵
func remaining_quota(city_id: String) -> int:
	var s := DataManager.get_barracks_settings()
	var cap := int(s.get("max_recruit_per_day", 300))
	# 人口越少，可征上限越低
	var city := DataManager.get_city(city_id)
	var pop := int(city.get("population", 0))
	if pop > 0:
		cap = mini(cap, maxi(20, int(pop / 100.0)))
	return maxi(0, cap - GameState.get_recruited_today(city_id))


## 征 count 兵所消耗的民心
## 公式：ceil(count / 每批人数) × 每批民心消耗
func _morale_cost_of(count: int) -> int:
	var s := DataManager.get_barracks_settings()
	var batch := maxi(1, int(s.get("recruit_per_batch", 10)))
	var per_batch := int(s.get("morale_cost_per_batch", 3))
	return int(ceil(float(count) / float(batch))) * per_batch


## 单批（10 兵）的民心消耗，供 UI 显示
func morale_cost_for_batch() -> int:
	return int(DataManager.get_barracks_settings().get("morale_cost_per_batch", 3))


## 民心可支撑的征兵人数上限（受 min_city_morale 约束）
func morale_recruit_capacity(city_id: String) -> int:
	var s := DataManager.get_barracks_settings()
	var batch := maxi(1, int(s.get("recruit_per_batch", 10)))
	var per_batch := maxi(1, int(s.get("morale_cost_per_batch", 3)))
	var budget := GameState.get_city_morale(city_id) - int(s.get("min_city_morale", 30))
	if budget <= 0:
		return 0
	return int(budget / per_batch) * batch


## 该城今日实际可征人数 = min(每日名额，民心容量)
func effective_recruit_limit(city_id: String) -> int:
	return mini(remaining_quota(city_id), morale_recruit_capacity(city_id))


## 征兵（核心操作）
## 返回 { ok, msg, unit_id, count, gold, food }
func recruit(city_id: String, unit_id: String, count: int) -> Dictionary:
	if count <= 0:
		return _fail("征兵数量无效")

	var gate := can_recruit_unit(city_id, unit_id)
	if not gate["ok"]:
		return _fail(str(gate["reason"]))

	# 民心门槛
	var s := DataManager.get_barracks_settings()
	var morale := GameState.get_city_morale(city_id)
	var min_morale := int(s.get("min_city_morale", 30))
	if morale < min_morale:
		return _fail("民心过低（%d），百姓不愿从军" % morale)

	# 每日上限
	var quota := remaining_quota(city_id)
	if quota <= 0:
		return _fail("此城今日征兵名额已满")
	if count > quota:
		count = quota

	# 资源检查
	var cost := recruit_cost(unit_id, count)
	if GameState.gold < int(cost["gold"]):
		return _fail("金钱不足（需 %d）" % int(cost["gold"]))
	if GameState.food < int(cost["food"]):
		return _fail("粮草不足（需 %d）" % int(cost["food"]))

	# 扣资源 + 加兵
	GameState.add_gold(-int(cost["gold"]))
	GameState.add_food(-int(cost["food"]))
	GameState.add_troop(unit_id, count)
	GameState.add_recruited_today(city_id, count)

	# 征兵消耗民心（兵源来自百姓，这是 Demo 阶段最紧的约束）
	var morale_cost := _morale_cost_of(count)
	GameState.set_city_morale(city_id, morale - morale_cost)
	EventBus.city_morale_changed.emit(city_id, GameState.get_city_morale(city_id))
	EventBus.troop_recruited.emit(unit_id, count, int(cost["gold"]))

	var unit := DataManager.get_unit(unit_id)
	var uname := str(unit.get("name", unit_id))
	return {
		"ok": true,
		"msg": "征募 %s ×%d（-金 %d / -粮 %d / 民心 -%d）" % [uname, count, int(cost["gold"]), int(cost["food"]), morale_cost],
		"unit_id": unit_id,
		"count": count,
		"gold": int(cost["gold"]),
		"food": int(cost["food"]),
	}


## 练兵：消耗粮草提升部队经验（经验满则升级，战力小幅提升）
func train(city_id: String, troop_index: int, count: int = 10) -> Dictionary:
	if troop_index < 0 or troop_index >= GameState.troops.size():
		return _fail("部队不存在")

	var s := DataManager.get_barracks_settings()
	var food_cost := int(round(float(s.get("train_food_per_10", 8)) * float(count) / 10.0))
	if GameState.food < food_cost:
		return _fail("粮草不足（需 %d）" % food_cost)

	var troop: Dictionary = GameState.troops[troop_index]
	GameState.add_food(-food_cost)

	var gain := int(round(float(s.get("train_exp_per_10", 5)) * float(count) / 10.0))
	var exp := int(troop.get("exp", 0)) + gain
	var threshold := int(s.get("veteran_threshold", 100))
	var leveled := false
	if exp >= threshold:
		exp -= threshold
		troop["level"] = int(troop.get("level", 1)) + 1
		leveled = true
	troop["exp"] = exp

	var unit := DataManager.get_unit(str(troop.get("unit_id", "")))
	var uname := str(unit.get("name", "?"))
	var msg := "%s 练兵 +%d 经验（耗粮 %d）" % [uname, gain, food_cost]
	if leveled:
		msg += " ★ 晋升为精锐（等级 %d）" % int(troop.get("level", 1))
	return { "ok": true, "msg": msg, "leveled": leveled }


## ---------- 武将招募 ----------

## 该武将的招募成本与门槛
## 返回 { gold, fame, infamy, difficulty, ok, reason }
func recruit_hero_terms(entry: Dictionary) -> Dictionary:
	var s := DataManager.get_recruit_settings()
	var diff := int(entry.get("difficulty", 1))
	var gold := int(s.get("base_gold", 300)) + diff * int(s.get("gold_per_difficulty", 450))
	gold += int(entry.get("gold_extra", 0))
	var fame := int(entry.get("require_fame", 0))
	var infamy := int(entry.get("require_infamy", 0))
	return {
		"gold": gold,
		"fame": fame,
		"infamy": infamy,
		"difficulty": diff,
	}


## 检查能否招募某武将
func can_recruit_hero(entry: Dictionary) -> Dictionary:
	var hero_id := str(entry.get("hero_id", ""))
	if hero_id.is_empty():
		return { "ok": false, "reason": "武将数据缺失" }
	if GameState.has_hero(hero_id):
		return { "ok": false, "reason": "已在队伍中" }

	var cap := int(DataManager.get_recruit_settings().get("max_party_size", 8))
	if GameState.party.size() >= cap:
		return { "ok": false, "reason": "队伍已满（%d 人）" % cap }

	var t := recruit_hero_terms(entry)
	if GameState.gold < int(t["gold"]):
		return { "ok": false, "reason": "金钱不足（需 %d）" % int(t["gold"]) }
	if int(t["fame"]) > 0 and GameState.fame < int(t["fame"]):
		return { "ok": false, "reason": "名声不足（需 %d，当前 %d）" % [int(t["fame"]), GameState.fame] }
	if int(t["infamy"]) > 0 and GameState.infamy < int(t["infamy"]):
		return { "ok": false, "reason": "恶名不足（需 %d）" % int(t["infamy"]) }

	return { "ok": true, "reason": "" }


## 招募武将
func recruit_hero(entry: Dictionary) -> Dictionary:
	var gate := can_recruit_hero(entry)
	if not gate["ok"]:
		return _fail(str(gate["reason"]))

	var hero_id := str(entry.get("hero_id", ""))
	var t := recruit_hero_terms(entry)
	GameState.add_gold(-int(t["gold"]))
	if not GameState.recruit_hero(hero_id):
		# 回滚（理论上不会发生，防御性处理）
		GameState.add_gold(int(t["gold"]))
		return _fail("入队失败")

	var hero := DataManager.get_character(hero_id)
	var hname := str(hero.get("name", hero_id))
	EventBus.hero_recruited.emit(hero_id)

	# 名声奖励：招募高难度武将会提升名声
	var fame_gain := int(entry.get("difficulty", 1))
	if fame_gain > 0:
		GameState.add_fame(fame_gain)

	return {
		"ok": true,
		"msg": "%s 加入队伍！（-金 %d，名声 +%d）" % [hname, int(t["gold"]), fame_gain],
		"hero_id": hero_id,
	}


## 赠礼提升好感（消耗美酒等道具）
func give_gift(hero_id: String, item_id: String) -> Dictionary:
	if not GameState.has_hero(hero_id):
		return _fail("该武将不在队伍中")
	if not GameState.has_item(item_id, 1):
		return _fail("没有该道具")

	var item := DataManager.get_item(item_id)
	var value := int(item.get("gift_value", 10))
	GameState.consume_item(item_id, 1)

	for h in GameState.party:
		if str(h.get("hero_id", "")) == hero_id:
			var cur := int(h.get("intimacy", 0))
			h["intimacy"] = clampi(cur + value, 0, 100)
			var hero := DataManager.get_character(hero_id)
			return {
				"ok": true,
				"msg": "%s 好感 +%d（当前 %d）" % [str(hero.get("name", hero_id)), value, int(h["intimacy"])],
			}
	return _fail("操作失败")


## 把武将编入某支部队（统兵武将）
func assign_hero(troop_index: int, hero_id: String) -> Dictionary:
	if troop_index < 0 or troop_index >= GameState.troops.size():
		return _fail("部队不存在")
	if not hero_id.is_empty() and not GameState.has_hero(hero_id):
		return _fail("该武将不在队伍中")

	# 同一武将不能带两支部队
	if not hero_id.is_empty():
		for i in range(GameState.troops.size()):
			if i != troop_index and str(GameState.troops[i].get("hero_id", "")) == hero_id:
				GameState.troops[i]["hero_id"] = ""

	GameState.assign_hero_to_troop(troop_index, hero_id)
	var hero := DataManager.get_character(hero_id) if not hero_id.is_empty() else {}
	var hname := str(hero.get("name", "")) if not hero.is_empty() else "（无）"
	return { "ok": true, "msg": "已任命统兵武将：%s" % hname }


## ---------- 市场买卖 ----------

## 买资源（粮/木/铁）
func buy_resource(city_id: String, resource: String, pack: int, price: int) -> Dictionary:
	if GameState.gold < price:
		return _fail("金钱不足（需 %d）" % price)
	GameState.add_gold(-price)
	match resource:
		"food": GameState.add_food(pack)
		"wood": GameState.add_wood(pack)
		"iron": GameState.add_iron(pack)
		_:
			GameState.add_gold(price)
			return _fail("未知资源：%s" % resource)
	var rname: String = str({ "food": "粮草", "wood": "木材", "iron": "铁矿" }.get(resource, resource))
	return { "ok": true, "msg": "购入 %s ×%d（-金 %d）" % [rname, pack, price] }


## 卖资源
func sell_resource(city_id: String, resource: String, pack: int, price: int) -> Dictionary:
	var have := 0
	match resource:
		"food": have = GameState.food
		"wood": have = GameState.wood
		"iron": have = GameState.iron
		_:
			return _fail("未知资源：%s" % resource)
	if have < pack:
		return _fail("存量不足（有 %d）" % have)

	match resource:
		"food": GameState.add_food(-pack)
		"wood": GameState.add_wood(-pack)
		"iron": GameState.add_iron(-pack)
	GameState.add_gold(price)
	var rname: String = str({ "food": "粮草", "wood": "木材", "iron": "铁矿" }.get(resource, resource))
	return { "ok": true, "msg": "售出 %s ×%d（+金 %d）" % [rname, pack, price] }


## 买道具
func buy_item(city_id: String, item_id: String, count: int, unit_price: int) -> Dictionary:
	if count <= 0:
		return _fail("数量无效")
	var total := unit_price * count
	if GameState.gold < total:
		return _fail("金钱不足（需 %d）" % total)

	GameState.add_gold(-total)
	GameState.add_item(item_id, count)
	var item := DataManager.get_item(item_id)
	EventBus.item_bought.emit(item_id, count, total)
	return { "ok": true, "msg": "购入 %s ×%d（-金 %d）" % [str(item.get("name", item_id)), count, total] }


## 卖道具
func sell_item(city_id: String, item_id: String, count: int, unit_price: int) -> Dictionary:
	if count <= 0:
		return _fail("数量无效")
	if not GameState.has_item(item_id, count):
		return _fail("道具不足（有 %d）" % GameState.get_item_count(item_id))

	GameState.consume_item(item_id, count)
	var gain := unit_price * count
	GameState.add_gold(gain)
	var item := DataManager.get_item(item_id)
	EventBus.item_sold.emit(item_id, count, gain)
	return { "ok": true, "msg": "售出 %s ×%d（+金 %d）" % [str(item.get("name", item_id)), count, gain] }


## 铁匠铺商品是否可在该城购买
func can_buy_smith(city_id: String, entry: Dictionary) -> Dictionary:
	var city := DataManager.get_city(city_id)
	var level := int(city.get("level", 1))
	var need := int(entry.get("min_city_level", 1))
	if level < need:
		return { "ok": false, "reason": "需城池等级 %d" % need }

	var buildings: Array = city.get("buildings", [])
	if not ("smith" in buildings):
		return { "ok": false, "reason": "此城无铁匠铺" }

	var req_region := str(entry.get("require_region", ""))
	if not req_region.is_empty() and str(city.get("region", "")) != req_region:
		return { "ok": false, "reason": "此城无此特产" }

	return { "ok": true, "reason": "" }


## 购买装备
func buy_equipment(city_id: String, entry: Dictionary) -> Dictionary:
	var gate := can_buy_smith(city_id, entry)
	if not gate["ok"]:
		return _fail(str(gate["reason"]))

	var item_id := str(entry.get("item_id", ""))
	var item := DataManager.get_item(item_id)
	if item.is_empty():
		return _fail("装备数据缺失")

	var city := DataManager.get_city(city_id)
	var price := buy_price(int(item.get("price", 0)), int(city.get("level", 1)))
	if price <= 0:
		return _fail("此物不出售")
	if GameState.gold < price:
		return _fail("金钱不足（需 %d）" % price)

	GameState.add_gold(-price)
	GameState.add_item(item_id, 1)

	# 命运装备：首次获得时提示（真正效果留给后续装备系统）
	var suffix := ""
	if bool(item.get("is_fate", false)):
		suffix = "（命运装备）"
	return { "ok": true, "msg": "打造 %s%s（-金 %d）" % [str(item.get("name", item_id)), suffix, price] }


## ---------- 内政 ----------

## 施赈（用金钱换民心）
func relieve_city(city_id: String, gold_cost: int = 200) -> Dictionary:
	if GameState.gold < gold_cost:
		return _fail("金钱不足（需 %d）" % gold_cost)
	var cur := GameState.get_city_morale(city_id)
	if cur >= 100:
		return _fail("民心已满")
	GameState.add_gold(-gold_cost)
	var gain := int(round(float(gold_cost) / 40.0))
	GameState.set_city_morale(city_id, cur + gain)
	EventBus.city_morale_changed.emit(city_id, GameState.get_city_morale(city_id))
	return { "ok": true, "msg": "开仓施赈：民心 +%d（-金 %d）" % [gain, gold_cost] }


## 修缮城防（用木材+金钱换城防）
func repair_city(city_id: String, wood_cost: int = 50, gold_cost: int = 150) -> Dictionary:
	if GameState.wood < wood_cost:
		return _fail("木材不足（需 %d）" % wood_cost)
	if GameState.gold < gold_cost:
		return _fail("金钱不足（需 %d）" % gold_cost)

	GameState.add_wood(-wood_cost)
	GameState.add_gold(-gold_cost)
	var gain := int(round(float(wood_cost) / 25.0)) + 2
	GameState.city_defense_bonus[city_id] = int(GameState.city_defense_bonus.get(city_id, 0)) + gain
	EventBus.city_defense_changed.emit(city_id, GameState.get_city_defense(city_id))
	return { "ok": true, "msg": "修缮城防：城防 +%d（-木 %d / -金 %d）" % [gain, wood_cost, gold_cost] }


## ---------- 演练 ----------

## 取演练预设的敌方配置（转成 standard encounter 结构，供布阵界面复用）
func drill_as_encounter(drill_id: String) -> Dictionary:
	var d := DataManager.get_drill(drill_id)
	if d.is_empty():
		return {}
	return {
		"id": str(d.get("id", "")),
		"name": str(d.get("name", "演练")),
		"type": "drill",
		"terrain": str(d.get("terrain", "plain")),
		"enemy_units": d.get("enemy_units", []),
		"rewards": {},
		"description": str(d.get("description", "")),
	}
