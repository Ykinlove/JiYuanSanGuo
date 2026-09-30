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

## 城池等级系数：等级越高物价越贵（偏远城镇更是如此）
func level_factor(city_level: int) -> float:
	return maxf(0.6, 1.0 + float(city_level - 2) * PRICE_LEVEL_FACTOR)


## 商品买入价 = 基础价 × 城池系数
func buy_price(base_price: int, city_level: int) -> int:
	return maxi(1, int(round(float(base_price) * level_factor(city_level))))


## 商品卖出价 = 基础价 × 回收比例
func sell_price(base_price: int, city_level: int) -> int:
	var ratio := float(DataManager.get_shop_settings().get("sell_ratio", 0.55))
	return maxi(1, int(round(float(buy_price(base_price, city_level)) * ratio)))


## ---------- 跑商（城际价差） ----------
## 旧模型里 buy/sell 只按城池等级缩放，且 sell = buy × 0.55 —— 在任何城买入再卖出都亏，
## 跑商在数学上根本不成立；cities.json 里的 commerce（商业）与 specialty（特产）
## 两个字段也就一直零消费，白躺在数据表里。
## 新模型把这两个字段接进来：商业越繁荣货源越足、物价越低；特产决定这座城什么便宜什么贵。
## 城与城之间由此出现真实价差，低买高卖才成立。
## 参数经 110 城 × 3 物资全配对仿真标定（详见 shop_goods.json 的 settings.trade 注释）：
##   约 20~24% 的城对存在盈利路线，同城买卖回收率恒为 0.74~0.82（原地倒卖必亏，杜绝无限刷）。

func _trade_cfg() -> Dictionary:
	return DataManager.get_shop_settings().get("trade", {})


## 商业系数：商业值越高，货源越充足，物价越低
func commerce_factor(city_id: String) -> float:
	var cfg := _trade_cfg()
	var base_c := float(cfg.get("base_commerce", 40))
	var w := float(cfg.get("commerce_weight", 0.004))
	var city := DataManager.get_city(city_id)
	return clampf(1.0 + (base_c - float(city.get("commerce", base_c))) * w, 0.5, 1.6)


## 特产系数：粮仓粮贱矿贵，军屯产矿缺粮，商埠百物平价
func specialty_factor(city_id: String, res: String) -> float:
	var cfg := _trade_cfg()
	var city := DataManager.get_city(city_id)
	var tbl: Dictionary = cfg.get("specialty_factor", {})
	var row: Dictionary = tbl.get(str(city.get("specialty", "")), {})
	return float(row.get(res, 1.0))


## 物资买入价（跑商价，随城而异）
func resource_buy_price(city_id: String, res: String, base_price: int) -> int:
	var city := DataManager.get_city(city_id)
	var p := float(base_price) * level_factor(int(city.get("level", 2)))
	p *= commerce_factor(city_id) * specialty_factor(city_id, res)
	# 世界动态事件价改：丰年粮贱、灾年粮贵、矿脉铁贱、木料紧缺价高（直接拉动跑商经济）
	p *= WorldEventService.region_price_mult(city_id, res)
	return maxi(1, int(round(p)))


## 物资卖出价（跑商价）= 该城买入价 × 回收比例（商埠另加收货加成）
func resource_sell_price(city_id: String, res: String, base_price: int) -> int:
	var cfg := _trade_cfg()
	var ratio := float(cfg.get("commodity_sell_ratio", 0.74))
	var city := DataManager.get_city(city_id)
	var bonus: Dictionary = cfg.get("sell_bonus", {})
	ratio += float(bonus.get(str(city.get("specialty", "")), 0.0))
	return maxi(1, int(round(float(resource_buy_price(city_id, res, base_price)) * ratio)))


## 该城今日还可购入几批物资（跑商限流：否则一趟就能把价差吃干榨净）
func remaining_trade_quota(city_id: String) -> int:
	var cap := int(_trade_cfg().get("daily_buy_pack_limit", 8))
	return maxi(0, cap - GameState.get_trade_today(city_id))


## 天下均价缓存：key = "资源:基础价"（数据表是静态的，算一次即可）
static var _avg_price_cache: Dictionary = {}

## 某物资的天下均价（全城买入价平均），供 UI 判断此地是贵是贱
func realm_avg_price(res: String, base_price: int) -> float:
	var key := "%s:%d" % [res, base_price]
	if _avg_price_cache.has(key):
		return float(_avg_price_cache[key])
	var total := 0.0
	var n := 0
	for c in DataManager.get_table("cities"):
		var rec: Dictionary = c
		total += float(resource_buy_price(str(rec.get("id", "")), res, base_price))
		n += 1
	var avg := total / float(maxi(1, n))
	_avg_price_cache[key] = avg
	return avg


## 物价标签：此地价相对天下均价是低是平是高，让玩家不必背价格表也能决策
## 返回 { "text": String, "level": int }，level: -1 价低 / 0 价平 / 1 价高
func price_tag(city_id: String, res: String, base_price: int) -> Dictionary:
	var avg := realm_avg_price(res, base_price)
	if avg <= 0.0:
		return { "text": "价平", "level": 0 }
	var d := (float(resource_buy_price(city_id, res, base_price)) - avg) / avg
	if d <= -0.08:
		return { "text": "价低 %d%%" % int(round(d * 100.0)), "level": -1 }
	if d >= 0.08:
		return { "text": "价高 +%d%%" % int(round(d * 100.0)), "level": 1 }
	return { "text": "价平", "level": 0 }


func _fail(msg: String) -> Dictionary:
	return { "ok": false, "msg": msg }


## ---------- 征兵 ----------

## 兵种是否可在该城征募
## 返回 { ok: bool, reason: String }
func can_recruit_unit(city_id: String, unit_id: String) -> Dictionary:
	var city := DataManager.get_city(city_id)
	if city.is_empty():
		return { "ok": false, "reason": "城池数据缺失" }

	# 粮草软锁：断粮无以为战，禁止征兵
	if GameState.food <= 0:
		return { "ok": false, "reason": "粮草枯竭，无以为战（先筹集粮草）" }

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

	# 区域限定：require_region 用「游戏区域」名（nanzhong / jing / zhongyuan / jiangdong），
	# 经 RegionService 的古州映射判定，勿与 cities.json 的 region（reg_xxx 古州 id）直接比较。
	var req_region := str(cfg.get("require_region", ""))
	if not req_region.is_empty() and not RegionService.city_in_area(req_region, city):
		return { "ok": false, "reason": "仅 %s 地区可征" % RegionService.region_name(req_region) }

	# 势力限定：require_faction_id 用 factions6 的整数 id（与 cities.json 的 faction_id 同源）
	var req_faction := int(cfg.get("require_faction_id", 0))
	if req_faction > 0 and int(city.get("faction_id", 0)) != req_faction:
		return { "ok": false, "reason": "需 %s 势力城池" % FactionService.faction_name(req_faction) }

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
	# 【#66】整饬军备的政令加成：额度直接抬高，与当日已征数无关（过期由 GameState 自行清理）
	cap += GameState.get_recruit_quota_bonus(city_id)
	return maxi(0, cap - GameState.get_recruited_today(city_id))


# ================= 攻城（#64 玩家攻城占地 / #65 守军反扑） =================
## 全部数值取自 combat.json 的 siege 段，本层只做判定与换算，UI 不含公式。
## 【静态化】GameState 的月度结算也要读这些配置（GameState 不持有 CityService 实例），
## 故取配置的入口一律 static；需要实例状态的操作（扣钱/改民心）仍是实例方法。

static func siege_settings() -> Dictionary:
	return DataManager.get_record("combat", "root").get("siege", {})


## 守军反扑配置（#65）
static func counterattack_settings() -> Dictionary:
	return siege_settings().get("counterattack", {})


## 【#67】治下城池总配置（治理指令 / 叛乱 / 收复）
static func ownership_settings() -> Dictionary:
	return DataManager.get_record("city_ownership", "root")


## 【#67】收复军配置
static func retake_settings() -> Dictionary:
	return ownership_settings().get("retake", {})


## 【#67】收复军兵力：由城池 defense 推导，与攻城守军同口径（上限略低，
## 因为远道而来的收复军不可能倾巢而出），但会被该城当前城防抵扣一部分
## —— 玩家治理过的坚城更容易守住，这是治理指令的实战回报。
static func retake_army_size(city: Dictionary) -> int:
	var s := retake_settings()
	var d := int(city.get("defense", 10))
	var raw := clampi(d * int(s.get("army_per_defense", 5)),
		int(s.get("min_army", 40)), int(s.get("max_army", 320)))
	return maxi(1, raw)


## 【#67】兵临城下时真正要打的敌军规模：城墙守军先吃掉一部分
## （wall_defense_ratio × 当前城防 × 每点城防的守军数），故治理过的坚城敌军更少。
static func retake_battle_units(city: Dictionary) -> Dictionary:
	var s := retake_settings()
	var siege := siege_settings()
	var garrison_total := _static_garrison_total(city)
	var wall := int(float(garrison_total) * float(s.get("wall_defense_ratio", 0.5)))
	var army := maxi(1, retake_army_size(city) - wall)
	var spear := int(float(army) * float(s.get("spearman_ratio", 0.35)))
	var arch := int(float(army) * float(s.get("archer_ratio", 0.25)))
	var inf := maxi(0, army - spear - arch)
	var units: Array = []
	if inf > 0:
		units.append({ "unit_id": "infantry", "count": inf })
	if spear > 0:
		units.append({ "unit_id": "spearman", "count": spear })
	if arch > 0:
		units.append({ "unit_id": "archer", "count": arch })
	return {
		"units": units,
		"army": army,
		"raw": retake_army_size(city),
		"wall": wall,
	}


## 城池当前守军总数（含玩家修缮 + 攻城失败后的戒备膨胀），供抵扣与 UI 展示
static func _static_garrison_total(city: Dictionary) -> int:
	var n := 0
	for u in garrison_units_of(city):
		if u is Dictionary:
			n += int(u.get("count", 0))
	return n


## 守军编制（静态版）：defense 含「玩家修缮加成 + 守军戒备」
static func garrison_units_of(city: Dictionary) -> Array:
	var cid := str(city.get("id", ""))
	var s := siege_settings()
	var defense := int(city.get("defense", 10))
	defense += int(GameState.city_defense_bonus.get(cid, 0))
	defense += int(GameState.city_alert.get(cid, 0))
	var total := clampi(defense * int(s.get("garrison_per_defense", 6)),
		int(s.get("min_garrison", 24)), int(s.get("max_garrison", 420)))
	var spear := int(float(total) * float(s.get("spearman_ratio", 0.35)))
	var arch := int(float(total) * float(s.get("archer_ratio", 0.25)))
	var inf := maxi(0, total - spear - arch)
	var out: Array = []
	if inf > 0:
		out.append({ "unit_id": "infantry", "count": inf })
	if spear > 0:
		out.append({ "unit_id": "spearman", "count": spear })
	if arch > 0:
		out.append({ "unit_id": "archer", "count": arch })
	return out


## 【#65】攻城失利的后果：守军出城掩杀。返回 { loss, gold, alert, msg }
## loss/gold 已按当前兵力与库存夹取，调用方直接扣即可。
static func counterattack_result(city: Dictionary) -> Dictionary:
	var c := counterattack_settings()
	var troops := GameState.get_total_troops()
	var loss := maxi(int(c.get("min_loss", 10)), int(float(troops) * float(c.get("loss_ratio", 0.18))))
	loss = mini(loss, troops)
	var gold := maxi(int(c.get("min_gold_loss", 30)), int(float(GameState.gold) * float(c.get("gold_loss_ratio", 0.05))))
	gold = mini(gold, GameState.gold)
	return {
		"loss": loss,
		"gold": gold,
		"alert": int(c.get("alert_gain", 4)),
		"msg": "守军出城掩杀：折损 %d 人，辎重散失 %d 金，城中戒备森严。" % [loss, gold],
	}


## 【#65】执行攻城失利的反扑（扣兵、扣钱、加戒备）。纯副作用，返回展示文案。
static func apply_siege_defeat(city: Dictionary) -> String:
	var r := counterattack_result(city)
	var loss := int(r.get("loss", 0))
	if loss > 0:
		GameState.lose_troops(loss)
	var gold := int(r.get("gold", 0))
	if gold > 0:
		GameState.add_gold(-gold)
	var cid := str(city.get("id", ""))
	if not cid.is_empty():
		GameState.city_alert[cid] = int(GameState.city_alert.get(cid, 0)) + int(r.get("alert", 0))
	return str(r.get("msg", "攻城失利。"))


## 城池守军编制：由 defense 推导总兵力，再按比例拆成 刀盾/长枪/弓 三兵种。
## 【#65】defense 取「基础城防 + 玩家修缮 + 守军戒备」：攻城失败后守军有了防备，
## 再攻会更难；而玩家若先治理修城防，轮到别人来夺时守军也更厚。
func garrison_units(city: Dictionary) -> Array:
	return garrison_units_of(city)


## 攻城战利（同样由 defense 推导）
func siege_rewards(city: Dictionary) -> Dictionary:
	var s := siege_settings()
	var d := int(city.get("defense", 10))
	var gold := d * int(s.get("reward_gold_per_defense", 4))
	var exp := d * int(s.get("reward_exp_per_defense", 8))
	return {
		"gold": [gold, gold * 2],
		"exp": [exp, exp * 2],
		"fame": int(s.get("reward_fame", 8)),
		"infamy": int(s.get("reward_infamy", 3)),
	}


## 能否攻打此地：己方城 / 无兵 / 本势力城 均不可攻
func can_siege(city: Dictionary) -> Dictionary:
	var cid := str(city.get("id", ""))
	if cid.is_empty():
		return _fail("此地不可攻打。")
	if GameState.captured_cities.has(cid):
		return _fail("此地已在你治下。")
	if GameState.get_total_troops() <= 0:
		return _fail("需先招募部队，方可兴兵。")
	var fid := int(city.get("faction_id", 0))
	if GameState.affiliation > 0 and fid == GameState.affiliation:
		return _fail("不可攻打本势力城池。")
	return { "ok": true, "reason": "" }


# ================= 治下城池治理指令（#66） =================
## 玩家攻下的城池此前只有「月度赋税」一条收益，没有任何经营手段，
## 治理指令让「占地」从收租变成真正的经营：修城防顶住收复军、安民心压住叛乱、
## 整军备抬高征兵额度。数值全部在 city_ownership.json。

static func governance_orders() -> Array:
	return ownership_settings().get("orders", [])


static func governance_order(order_id: String) -> Dictionary:
	for o in governance_orders():
		if str(o.get("id", "")) == order_id:
			return o
	return {}


## 指令成本：按城池等级缩放（大郡治理更贵）
static func governance_cost(city_id: String, order_id: String) -> Dictionary:
	var o := governance_order(order_id)
	if o.is_empty():
		return {}
	var city := DataManager.get_city(city_id)
	var lv := maxi(1, int(city.get("level", 2)))
	return {
		"gold": int(o.get("gold_per_level", 0)) * lv,
		"wood": int(o.get("wood_per_level", 0)) * lv,
	}


## 指令效果摘要（UI 直接显示，不含公式）
static func governance_effect_text(order_id: String) -> String:
	var o := governance_order(order_id)
	if o.is_empty():
		return ""
	var desc := str(o.get("desc", ""))
	if desc.find("%d") < 0:
		return desc
	match order_id:
		"repair":
			return desc % int(o.get("defense_gain", 0))
		"relieve":
			return desc % int(o.get("morale_gain", 0))
		"conscription":
			return desc % [int(o.get("duration_months", 1)), int(o.get("recruit_quota_bonus", 0)), int(o.get("morale_cost", 0))]
		_:
			return desc


## 能否下达该指令：非治下城 / 资源不足 / 冷却未过 / 民心已满 分别给原因
func can_govern(city_id: String, order_id: String) -> Dictionary:
	var o := governance_order(order_id)
	if o.is_empty():
		return _fail("无此政令。")
	if not GameState.captured_cities.has(city_id):
		return _fail("此地不在你治下。")
	var cd: Dictionary = GameState.city_order_cooldown.get(city_id, {})
	if GameState.month_index() < int(cd.get(order_id, 0)):
		return _fail("此政令尚在施行，需待来月。")
	var cost := governance_cost(city_id, order_id)
	if int(cost.get("gold", 0)) > GameState.gold:
		return _fail("金钱不足（需 %d）" % int(cost.get("gold", 0)))
	if int(cost.get("wood", 0)) > GameState.wood:
		return _fail("木材不足（需 %d）" % int(cost.get("wood", 0)))
	if order_id == "relieve" and GameState.get_city_morale(city_id) >= 100:
		return _fail("民心已归附，无需再赈。")
	if order_id == "conscription" and GameState.get_city_morale(city_id) < int(o.get("morale_cost", 0)):
		return _fail("民心过低，乡勇不肯应征。")
	return { "ok": true, "reason": "" }


## 下达治理指令：扣资源 → 落效果 → 记冷却 → 发信号
func govern_city(city_id: String, order_id: String) -> Dictionary:
	var chk := can_govern(city_id, order_id)
	if not bool(chk.get("ok", false)):
		return { "ok": false, "msg": str(chk.get("reason", "此刻不可施行。")) }
	var o := governance_order(order_id)
	var cost := governance_cost(city_id, order_id)
	GameState.add_gold(-int(cost.get("gold", 0)))
	GameState.add_wood(-int(cost.get("wood", 0)))

	var msg := ""
	match order_id:
		"repair":
			var gain := int(o.get("defense_gain", 0))
			GameState.city_defense_bonus[city_id] = int(GameState.city_defense_bonus.get(city_id, 0)) + gain
			EventBus.city_defense_changed.emit(city_id, GameState.get_city_defense(city_id))
			msg = "修缮城防：城防 +%d（-金 %d / -木 %d）" % [
				gain, int(cost.get("gold", 0)), int(cost.get("wood", 0))]
		"relieve":
			var m := GameState.get_city_morale(city_id)
			var gain := mini(int(o.get("morale_gain", 0)), 100 - m)
			GameState.set_city_morale(city_id, m + gain)
			EventBus.city_morale_changed.emit(city_id, GameState.get_city_morale(city_id))
			msg = "安抚民心：民心 +%d（-金 %d）" % [gain, int(cost.get("gold", 0))]
		"conscription":
			var mc := int(o.get("morale_cost", 0))
			var m2 := GameState.get_city_morale(city_id)
			GameState.set_city_morale(city_id, maxi(0, m2 - mc))
			EventBus.city_morale_changed.emit(city_id, GameState.get_city_morale(city_id))
			GameState.city_recruit_bonus[city_id] = {
				"amount": int(o.get("recruit_quota_bonus", 0)),
				"until": GameState.month_index() + int(o.get("duration_months", 1)),
			}
			msg = "整饬军备：征兵额度 +%d，持续 %d 个月（民心 -%d / -金 %d / -木 %d）" % [
				int(o.get("recruit_quota_bonus", 0)), int(o.get("duration_months", 1)),
				mc, int(cost.get("gold", 0)), int(cost.get("wood", 0))]
		_:
			return { "ok": false, "msg": "无此政令。" }

	var cd: Dictionary = GameState.city_order_cooldown.get(city_id, {})
	cd[order_id] = GameState.month_index() + int(o.get("cooldown_months", 1))
	GameState.city_order_cooldown[city_id] = cd
	EventBus.city_governed.emit(city_id, order_id)
	return { "ok": true, "msg": msg }


## 征 count 兵所消耗的民心## 公式：ceil(count / 每批人数) × 每批民心消耗
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

	AchievementService.check_all()

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
## packs：本次买入的批数（跑商按批计入当日额度）
func buy_resource(city_id: String, resource: String, pack: int, price: int, packs: int = 1) -> Dictionary:
	# 【L-6 修复】未知资源先拦截：原实现先扣金扣当日配额、match 默认分支才退金，
	# 配额却已经白扣一天份——未知资源应在动账本之前挡掉
	if resource != "food" and resource != "wood" and resource != "iron":
		return _fail("未知资源：%s" % resource)
	# 跑商限流：一城一日只能吃下这么多货，否则价差一趟就被榨干
	if remaining_trade_quota(city_id) < packs:
		return _fail("此城今日货源已尽（余 %d 批）" % remaining_trade_quota(city_id))
	if GameState.gold < price:
		return _fail("金钱不足（需 %d）" % price)
	GameState.add_gold(-price)
	GameState.add_trade_today(city_id, packs)
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

	# 特产限定：require_region 用「游戏区域」名，走 RegionService 映射判定
	var req_region := str(entry.get("require_region", ""))
	if not req_region.is_empty() and not RegionService.city_in_area(req_region, city):
		return { "ok": false, "reason": "此城无此特产" }

	return { "ok": true, "reason": "" }


## 购买装备
func buy_equipment(city_id: String, entry: Dictionary) -> Dictionary:
	var gate := can_buy_smith(city_id, entry)
	if not gate["ok"]:
		return _fail(str(gate["reason"]))

	var item_id := str(entry.get("item_id", ""))
	# 纯数字 id → items6 新装备表；否则走旧 items.json（命运装备）
	var is_v6 := item_id.is_valid_int()
	var item: Dictionary = DataManager.get_item6(int(item_id)) if is_v6 else DataManager.get_item(item_id)
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
	EventBus.item_bought.emit(item_id, 1, price)

	# 旧命运装备：首次获得时提示
	var suffix := ""
	if not is_v6 and bool(item.get("is_fate", false)):
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
