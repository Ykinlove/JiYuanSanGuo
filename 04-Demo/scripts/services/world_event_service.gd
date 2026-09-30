extends RefCounted
class_name WorldEventService
## 大地图随机事件规则层（遭遇表 type="event"）。
## 事件定义见 encounters.json：
##   options[] = { id, text, cost:{gold,food,wood,iron}, effects:{...}, result }
## effects 支持：gold/food/wood/iron/fame/infamy/exp（带符号整数）、
##   unit_add {unit_id: count}、item_add {item_id: count}
## UI 只调 can_pick()/resolve()，不自行扣资源或拼结算公式。

const RESOURCE_KEYS: Array[String] = ["gold", "food", "wood", "iron"]


## 取某选项（找不到返回空字典）
static func find_option(event_def: Dictionary, option_id: String) -> Dictionary:
	for opt in event_def.get("options", []):
		if str(opt.get("id", "")) == option_id:
			return opt
	return {}


## 是否可选（资源不足时返回原因供按钮置灰）
static func can_pick(opt: Dictionary) -> Dictionary:
	var cost: Dictionary = opt.get("cost", {})
	for k in RESOURCE_KEYS:
		var need := int(cost.get(k, 0))
		if need > 0 and _get_resource(k) < need:
			return { "ok": false, "reason": "%s不足（需 %d）" % [_resource_name(k), need] }
	return { "ok": true, "reason": "" }


## 结算一个选项：校验→扣消耗→应用效果。返回 {ok, msg}
static func resolve(event_def: Dictionary, option_id: String) -> Dictionary:
	var opt := find_option(event_def, option_id)
	if opt.is_empty():
		return { "ok": false, "msg": "事件选项缺失。" }
	var gate := can_pick(opt)
	if not gate["ok"]:
		return { "ok": false, "msg": str(gate["reason"]) }

	# 扣除消耗
	var cost: Dictionary = opt.get("cost", {})
	for k in RESOURCE_KEYS:
		var need := int(cost.get(k, 0))
		if need > 0:
			_add_resource(k, -need)

	# 应用效果
	var parts: Array[String] = []
	var eff: Dictionary = opt.get("effects", {})
	for k in ["gold", "food", "wood", "iron", "fame", "infamy", "exp"]:
		var v := int(eff.get(k, 0))
		if v != 0:
			_apply_simple(k, v)
			parts.append("%s %s%d" % [_effect_name(k), "+" if v > 0 else "", v])

	var unit_add: Dictionary = eff.get("unit_add", {})
	for uid in unit_add:
		var n := int(unit_add[uid])
		if n > 0:
			GameState.add_troop(str(uid), n)
			EventBus.unit_added.emit(str(uid), n)
			var urec := DataManager.get_record("units", str(uid))
			var uname := str(urec.get("name", uid)) if not urec.is_empty() else str(uid)
			parts.append("%s +%d" % [uname, n])

	var item_add: Dictionary = eff.get("item_add", {})
	for iid in item_add:
		var n2 := int(item_add[iid])
		if n2 > 0:
			GameState.add_item(str(iid), n2)
			var irec := DataManager.get_item(str(iid))
			var iname := str(irec.get("name", iid)) if not irec.is_empty() else str(iid)
			parts.append("%s ×%d" % [iname, n2])

	# 文案优先用配置的 result，没有则按效果拼
	var msg := str(opt.get("result", ""))
	if msg.is_empty():
		if parts.is_empty():
			msg = "什么也没有发生。"
		else:
			msg = "、".join(parts)
	return { "ok": true, "msg": msg }


static func _get_resource(key: String) -> int:
	match key:
		"gold": return GameState.gold
		"food": return GameState.food
		"wood": return GameState.wood
		"iron": return GameState.iron
	return 0


static func _add_resource(key: String, delta: int) -> void:
	match key:
		"gold": GameState.add_gold(delta)
		"food": GameState.add_food(delta)
		"wood": GameState.add_wood(delta)
		"iron": GameState.add_iron(delta)


static func _apply_simple(key: String, v: int) -> void:
	match key:
		"gold": GameState.add_gold(v)
		"food": GameState.add_food(v)
		"wood": GameState.add_wood(v)
		"iron": GameState.add_iron(v)
		"fame": GameState.add_fame(v)
		"infamy": GameState.add_infamy(v)
		"exp": GameState.add_player_exp(v)


static func _resource_name(key: String) -> String:
	return String({
		"gold": "金钱", "food": "粮草", "wood": "木材", "iron": "铁矿",
	}.get(key, key))


static func _effect_name(key: String) -> String:
	return String({
		"gold": "金钱", "food": "粮草", "wood": "木材", "iron": "铁矿",
		"fame": "名声", "infamy": "恶名", "exp": "经验",
	}.get(key, key))


## ============================================================
## 世界动态事件（时间驱动，让开放沙盘"活起来"）
## 与遭遇事件共用 EventPopup + 选项结算 schema；本段负责：
##   - 每日按权重生成 0~2 起区域事件（丰凶/流民/寇掠/名将寻访/矿脉/疫/民变/异象/商埠）
##   - 维护进行中事件表 + 待播队列（全部存 GameState 以便存档）
##   - region_price_mult() 让事件直接拉动已健康的跑商经济
##     （丰年粮贱→可低买、灾年粮贵→跑商风险、矿脉铁贱、木料紧缺价高）
## ============================================================

const WE_JSON_PATH := "res://assets/data/world_events.json"
static var _we_cache: Array = []


static func _we_table() -> Array:
	if not _we_cache.is_empty():
		return _we_cache
	var p := WE_JSON_PATH
	if not FileAccess.file_exists(p):
		return []
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return []
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if parsed is Array:
		_we_cache = parsed
	return _we_cache


## 进行中事件（仅未过期的）
static func active_world_events() -> Array:
	var out: Array = []
	var today := GameState.abs_day()
	for ev in GameState.world_events_active:
		if int(ev.get("expiry", -1)) >= today:
			out.append(ev)
	return out


## 区域资源价格倍率（多事件可叠加）：丰年粮贱、灾年粮贵
static func region_price_mult(city_id: String, res: String) -> float:
	var city: Dictionary = DataManager.get_city(city_id)
	if city.is_empty():
		return 1.0
	var region := str(city.get("region", ""))
	var m := 1.0
	for ev in active_world_events():
		if str(ev.get("region", "")) == region:
			var pm: Dictionary = ev.get("price_mod", {})
			if pm.has(res):
				m *= float(pm[res])
	return m


## 每日生成（由 GameState.advance_day 在 day_passed 之前调用）
static func roll_world_events() -> void:
	var table := _we_table()
	if table.is_empty():
		return
	var n := 0
	if randf() < 0.6:
		n += 1
	if randf() < 0.30:
		n += 1
	for i in range(n):
		if GameState.world_events_active.size() >= 4:
			break
		_spawn_one(table)


static func _spawn_one(table: Array) -> void:
	var tpl: Dictionary = _weighted_pick(table)
	if tpl.is_empty():
		return
	var region := _random_region()
	if region.is_empty():
		return
	var city: Dictionary = _random_city_in_region(region)
	if city.is_empty():
		return
	var uid := "we_%d_%d" % [GameState.abs_day(), int(randi() % 100000)]
	var rec: Dictionary = {
		"uid": uid,
		"world_event": true,
		"def_id": str(tpl.get("id", "")),
		"type": str(tpl.get("type", "")),
		"title": str(tpl.get("title", "事件")),
		"glyph": str(tpl.get("glyph", "！")),
		"region": region,
		"region_name": str(city.get("region_name", region)),
		"city_id": str(city.get("id", "")),
		"map_x": float(city.get("map_x", 0)),
		"map_y": float(city.get("map_y", 0)),
		"expiry": GameState.abs_day() + int(tpl.get("duration_days", 30)),
		"price_mod": tpl.get("price_mod", {}),
		"desc": str(tpl.get("desc", "")),
		"options": tpl.get("options", []),
	}
	GameState.world_events_active.append(rec)
	GameState.world_event_pending.append(rec)


static func _weighted_pick(table: Array) -> Dictionary:
	var total := 0.0
	for t in table:
		total += float(t.get("weight", 1))
	var r := randf() * total
	for t in table:
		r -= float(t.get("weight", 1))
		if r <= 0.0:
			return t
	if not table.is_empty():
		return table[table.size() - 1]
	return {}


static func _regions() -> Array:
	var s := {}
	for c in DataManager.get_table("cities"):
		s[str(c.get("region", ""))] = true
	var out: Array = []
	for k in s:
		out.append(k)
	return out


static func _random_region() -> String:
	var rs := _regions()
	if rs.is_empty():
		return ""
	return rs[randi() % rs.size()]


static func _random_city_in_region(region: String) -> Dictionary:
	var pool: Array = []
	for c in DataManager.get_table("cities"):
		if str(c.get("region", "")) == region:
			pool.append(c)
	if pool.is_empty():
		return {}
	return pool[randi() % pool.size()]


## 到期清理（每天推进时调用）
static func expire_world_events(today: int) -> void:
	var kept: Array = []
	for ev in GameState.world_events_active:
		if int(ev.get("expiry", -1)) >= today:
			kept.append(ev)
	GameState.world_events_active = kept
	var pk: Array = []
	for p in GameState.world_event_pending:
		var uid := ""
		if p is Dictionary:
			uid = str(p.get("uid", ""))
		var still := false
		for ev in GameState.world_events_active:
			if str(ev.get("uid", "")) == uid:
				still = true
		if still:
			pk.append(p)
	GameState.world_event_pending = pk


## 结算世界事件选项（复用玩家资源效果逻辑，并处理 end_event 收尾）
static func resolve_world(event_def: Dictionary, option_id: String) -> Dictionary:
	var opt: Dictionary = find_option(event_def, option_id)
	if opt.is_empty():
		return { "ok": false, "msg": "事件选项缺失。" }
	var gate: Dictionary = can_pick(opt)
	if not gate["ok"]:
		return { "ok": false, "msg": str(gate["reason"]) }

	var cost: Dictionary = opt.get("cost", {})
	for k in RESOURCE_KEYS:
		var need := int(cost.get(k, 0))
		if need > 0:
			_add_resource(k, -need)

	var parts: Array[String] = []
	var eff: Dictionary = opt.get("effects", {})
	for k in ["gold", "food", "wood", "iron", "fame", "infamy", "exp"]:
		var v := int(eff.get(k, 0))
		if v != 0:
			_apply_simple(k, v)
			parts.append("%s %s%d" % [_effect_name(k), "+" if v > 0 else "", v])

	var unit_add: Dictionary = eff.get("unit_add", {})
	for uid in unit_add:
		var n := int(unit_add[uid])
		if n > 0:
			GameState.add_troop(str(uid), n)
			EventBus.unit_added.emit(str(uid), n)
			var urec: Dictionary = DataManager.get_record("units", str(uid))
			var uname := str(urec.get("name", uid)) if not urec.is_empty() else str(uid)
			parts.append("%s +%d" % [uname, n])

	var item_add: Dictionary = eff.get("item_add", {})
	for iid in item_add:
		var n2 := int(item_add[iid])
		if n2 > 0:
			GameState.add_item(str(iid), n2)
			var irec: Dictionary = DataManager.get_item(str(iid))
			var iname := str(irec.get("name", iid)) if not irec.is_empty() else str(iid)
			parts.append("%s ×%d" % [iname, n2])

	if bool(opt.get("end_event", false)):
		_end_event(str(event_def.get("uid", "")))

	var msg := str(opt.get("result", ""))
	if msg.is_empty():
		if parts.is_empty():
			msg = "什么也没有发生。"
		else:
			msg = "、".join(parts)
	return { "ok": true, "msg": msg }


static func _end_event(uid: String) -> void:
	var kept: Array = []
	for ev in GameState.world_events_active:
		if str(ev.get("uid", "")) != uid:
			kept.append(ev)
	GameState.world_events_active = kept
	var pk: Array = []
	for p in GameState.world_event_pending:
		var puid := ""
		if p is Dictionary:
			puid = str(p.get("uid", ""))
		if puid != uid:
			pk.append(p)
	GameState.world_event_pending = pk
