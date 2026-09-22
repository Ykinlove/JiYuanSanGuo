extends RefCounted
class_name MonthlyService
## 月度结算规则层。
## 目前负责「月度义兵」：每月初按当前所在城池民心免费征召一批基础兵。
## UI/时间驱动只允许调用本层取数量，不允许在外部写公式。

const DEFAULT_MILITIA_UNIT := "infantry"
const DEFAULT_MORALE_FACTOR := 3.0
const DEFAULT_MIN_MORALE := 40


## 本月义兵配置。返回 { "unit_id": String, "count": int }
## 民心低于门槛则 count=0。
static func militia(settings: Dictionary, morale: int) -> Dictionary:
	var unit_id := String(settings.get("monthly_militia_unit", DEFAULT_MILITIA_UNIT))
	var factor := float(settings.get("monthly_militia_morale_factor", DEFAULT_MORALE_FACTOR))
	var min_morale := int(settings.get("monthly_militia_min_morale", DEFAULT_MIN_MORALE))
	var count := 0
	if morale >= min_morale:
		count = int(round(float(morale) * factor))
	return { "unit_id": unit_id, "count": count }


## 本月是否有义兵来投（供 UI/逻辑预判）
static func has_militia(settings: Dictionary, morale: int) -> bool:
	return int(militia(settings, morale)["count"]) > 0
