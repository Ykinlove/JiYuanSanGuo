extends RefCounted
class_name PrisonerService
## 俘虏招降/处死规则层。
## 数据源：GameState.prisoners（运行时） + heroes6（武将四维）。
## UI 只允许调用本层取门槛与执行操作，不允许在显示层写公式。

const RECRUIT_INTIMACY_THRESHOLD := 50       ## 招降所需好感
const RECRUIT_BASE_GOLD := 500              ## 招降基础金
const RECRUIT_GOLD_PER_STAT := 8            ## 每点四维均值加价
const EXECUTE_INFAMY_GAIN := 5              ## 处死获得恶名
const GIFT_INTIMACY_GAIN := 30              ## 赠美酒好感增量
const CAPTURE_BASE_RATE := 0.45             ## 俘虏基础概率
const CAPTURE_CHARM_FACTOR := 400.0         ## 魅力加成系数
const CAPTURE_RATE_MIN := 0.25
const CAPTURE_RATE_MAX := 0.80


## 俘虏概率 = clamp(基础 + 魅力/系数, 下限, 上限)
static func capture_rate(charm: int) -> float:
	return clampf(CAPTURE_BASE_RATE + float(charm) / CAPTURE_CHARM_FACTOR,
		CAPTURE_RATE_MIN, CAPTURE_RATE_MAX)


## 武将四维均值（用于招降定价）
static func hero_stat_avg(hero6: Dictionary) -> float:
	if hero6.is_empty():
		return 0.0
	var s := float(hero6.get("strong", 0))
	var f := float(hero6.get("force", 0))
	var i := float(hero6.get("intel", 0))
	var c := float(hero6.get("charm", 0))
	return (s + f + i + c) / 4.0


## 招降所需金钱
static func recruit_cost(hero6: Dictionary) -> int:
	return RECRUIT_BASE_GOLD + int(hero_stat_avg(hero6) * float(RECRUIT_GOLD_PER_STAT))


## 招降所需好感
static func recruit_intimacy_required() -> int:
	return RECRUIT_INTIMACY_THRESHOLD


## 招降门槛检查
static func can_recruit(hero6: Dictionary, intimacy: int, gold: int, party_size: int, max_party: int) -> Dictionary:
	if hero6.is_empty():
		return { "ok": false, "reason": "武将数据缺失" }
	if party_size >= max_party:
		return { "ok": false, "reason": "队伍已满（%d 人）" % max_party }
	if intimacy < RECRUIT_INTIMACY_THRESHOLD:
		return { "ok": false, "reason": "好感不足（需 %d，当前 %d）" % [RECRUIT_INTIMACY_THRESHOLD, intimacy] }
	var cost := recruit_cost(hero6)
	if gold < cost:
		return { "ok": false, "reason": "金钱不足（需 %d）" % cost }
	return { "ok": true, "reason": "", "cost": cost }


## 赠礼后好感（clamp 0~100）
static func intimacy_after_gift(current: int) -> int:
	return clampi(current + GIFT_INTIMACY_GAIN, 0, 100)


## 处死获得恶名
static func execute_infamy_gain() -> int:
	return EXECUTE_INFAMY_GAIN
