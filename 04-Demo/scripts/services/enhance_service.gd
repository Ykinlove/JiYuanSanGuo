extends RefCounted
class_name EnhanceService
## 铁匠铺装备强化规则层（shop_goods.json -> enhance）。
## 等级 0~max_level；每级战斗属性 ×(1 + lv×stat_per_level)（在 CharacterService 生效）。
## 从 L 升 L+1：耗金 gold_base×gold_growth^L、耗铁 iron_costs[L]，成功率 success_rates[L]。
## 失败：材料照扣，装备不碎；fail_drops_level=true 时掉 1 级（保底 0）。


static func _cfg() -> Dictionary:
	return DataManager.get_record("shop_goods", "root").get("enhance", {})


static func max_level() -> int:
	return int(_cfg().get("max_level", 5))


static func stat_per_level() -> float:
	return float(_cfg().get("stat_per_level", 0.15))


## 装备当前强化等级
static func level_of(item_id6: int) -> int:
	if item_id6 <= 0:
		return 0
	return clampi(int(GameState.equip_levels.get(str(item_id6), 0)), 0, max_level())


## 升到下一级的消耗与成功率（已满级返回 at_max）
static func terms(item_id6: int) -> Dictionary:
	var lv := level_of(item_id6)
	var cfg := _cfg()
	if lv >= max_level():
		return { "at_max": true, "level": lv, "gold": 0, "iron": 0, "rate": 0.0 }
	var gold := int(round(float(cfg.get("gold_base", 80)) \
		* pow(float(cfg.get("gold_growth", 1.6)), float(lv))))
	var costs: Array = cfg.get("iron_costs", [])
	var iron := int(costs[lv]) if lv < costs.size() else 999
	var rates: Array = cfg.get("success_rates", [])
	var rate := float(rates[lv]) if lv < rates.size() else 0.5
	return { "at_max": false, "level": lv, "gold": gold, "iron": iron, "rate": rate }


## 是否可强化：装备存在、有战斗属性、未满级、资源够
static func can_enhance(item: Dictionary, item_id6: int) -> Dictionary:
	if item.is_empty() or item_id6 <= 0:
		return { "ok": false, "reason": "装备数据缺失" }
	var b := CharacterService.item_combat_bonus(item, 0)
	var has_stat := false
	for k in ["attack", "defense", "hp", "speed"]:
		if int(b.get(k, 0)) != 0:
			has_stat = true
			break
	if not has_stat:
		return { "ok": false, "reason": "此装备无战斗属性" }
	var t := terms(item_id6)
	if bool(t.get("at_max", false)):
		return { "ok": false, "reason": "已达最高级" }
	if GameState.gold < int(t["gold"]):
		return { "ok": false, "reason": "金钱不足（需 %d）" % int(t["gold"]) }
	if GameState.iron < int(t["iron"]):
		return { "ok": false, "reason": "铁矿不足（需 %d）" % int(t["iron"]) }
	return { "ok": true, "reason": "" }


## 执行一次强化。返回 {ok, msg, success, level}
static func enhance(item_id6: int) -> Dictionary:
	var item := DataManager.get_item6(item_id6)
	var gate := can_enhance(item, item_id6)
	if not gate["ok"]:
		return { "ok": false, "msg": str(gate["reason"]), "success": false, "level": level_of(item_id6) }

	var t := terms(item_id6)
	var gold := int(t["gold"])
	var iron := int(t["iron"])
	GameState.add_gold(-gold)
	GameState.add_iron(-iron)

	var lv := level_of(item_id6)
	var success := randf() < float(t["rate"])
	var name := str(item.get("name", str(item_id6)))
	if success:
		lv += 1
		GameState.equip_levels[str(item_id6)] = lv
		EventBus.equipment_changed.emit()
		return {
			"ok": true, "success": true, "level": lv,
			"msg": "%s 强化至 +%d！（-金 %d / -铁 %d）" % [name, lv, gold, iron],
		}
	# 失败：不掉耐久，装备不碎；配置允许时掉 1 级
	var drop := bool(_cfg().get("fail_drops_level", true))
	if drop and lv > 0:
		lv -= 1
		GameState.equip_levels[str(item_id6)] = lv
	EventBus.equipment_changed.emit()
	var tail := "强化失败，等级回落至 +%d" % lv if drop else "强化失败，等级不变"
	return {
		"ok": true, "success": false, "level": lv,
		"msg": "%s%s（-金 %d / -铁 %d）" % [name, tail, gold, iron],
	}
