extends RefCounted
class_name CraftService
## 锻造规则层（items6.craft_flag/craft_materials + item_economy.json）。
##
## 【为什么需要这个类·第七十五轮实测取证】
## items6.json 里有 113 件物品带 craft_flag=1 与完整配方（如「佛跳墙」= 66×2 + 67×2 + 214×2 + 213×1），
## 但改动前 `grep -rn "craft" scripts/` **零命中** —— 数据设计完整，代码一行都没读，
## 于是这 113 件物品玩家永远做不出来。同期 33 种基础材料完全不可获取（连材料都拿不到）。
## 本类把这条死链接上：读配方 → 校验材料 → 扣料+扣工费 → 出货 + 每日次数。
##
## 配方材料不写在本类里（**单一真源在 items6.craft_materials**）：
## 照抄一份进代码会造成「上游改数值、这里留过期副本」，测的和跑的不是同一个东西。
## 本类只补 items6 没有的语义：工费、每日限次、等级门槛。
##
## 每日次数存 GameState.craft_today{绝对日号:次数}，换日自动归零、随存档往返。


static func _cfg() -> Dictionary:
	return DataManager.get_record("item_economy", "root")


static func _settings() -> Dictionary:
	return _cfg().get("settings", {})


## 每日锻造上限（0 = 不限）
static func daily_limit() -> int:
	return maxi(0, int(_settings().get("craft_daily_limit", 0)))


## 锻造门槛：主角等级下限
static func level_gate() -> int:
	return maxi(0, int(_settings().get("craft_level_gate", 1)))


## 工费（金）= 基础工费 + 材料件数 × 每件工费。
## 与材料实际价格无关：材料是玩家自备的沉没成本，工费只买「手艺」，
## 若按材料总价抽成，低级配方会变成纯亏本买卖，玩家会直接不做。
static func gold_cost(material_count: int) -> int:
	var s := _settings()
	return maxi(0, int(s.get("craft_gold_base", 20)) \
		+ maxi(0, material_count) * maxi(0, int(s.get("craft_gold_per_material", 8))))


## 今日已锻造次数（换日归零：存的键是「当日绝对日号」，日号一变自然取不到旧值）
static func used_today() -> int:
	return int(GameState.craft_today.get(GameState.total_days(), 0))


static func left_today() -> int:
	var lim := daily_limit()
	if lim <= 0:
		return -1  # -1 = 不限
	return maxi(0, lim - used_today())


## 该物品是否可锻造（craft_flag 为真且配方非空）
static func is_craftable(item6: Dictionary) -> bool:
	if item6.is_empty():
		return false
	var flag: Variant = item6.get("craft_flag", 0)
	var on := false
	if flag is bool:
		on = flag
	else:
		on = int(flag) == 1
	return on and not _materials(item6).is_empty()


## 归一配方：[{item_id:int, count:int}]。**空配方返回 []，绝不返回 null**
## （GDScript 带类型标注的变量不能赋 null，见 MEMORY 铁律）。
static func _materials(item6: Dictionary) -> Array:
	var out: Array = []
	var raw: Variant = item6.get("craft_materials", [])
	if not (raw is Array):
		return out
	for m in raw:
		if m is Dictionary and int(m.get("item_id", 0)) > 0:
			out.append({"item_id": int(m["item_id"]), "count": maxi(1, int(m.get("count", 1)))})
	return out


## 配方明细（含逐项持有量/缺口），供 UI 拼副标题
static func recipe_of(item6_id: int) -> Dictionary:
	var item: Dictionary = DataManager.get_item6(item6_id)
	if not is_craftable(item):
		return {}
	var mats := _materials(item)
	var rows: Array = []
	var missing := 0
	for m in mats:
		var md: Dictionary = m
		var iid := int(md["item_id"])
		var need := int(md["count"])
		var have := GameState.get_item_count(str(iid))
		var rec := CharacterService.resolve_item6(iid)
		var short := maxi(0, need - have)
		if short > 0:
			missing += 1
		rows.append({
			"item_id": iid,
			"count": need,
			"have": have,
			"short": short,
			"name": str(rec.get("name", str(iid))),
		})
	return {
		"item_id": item6_id,
		"name": str(item.get("name", str(item6_id))),
		"materials": rows,
		"gold": gold_cost(mats.size()),
		"missing": missing,
		"ok": missing == 0,
	}


## 可否开炉（材料齐 + 钱够 + 等级够 + 今日未超限）。返回带 reason 的字典。
static func can_craft(item6_id: int) -> Dictionary:
	var item: Dictionary = DataManager.get_item6(item6_id)
	if not is_craftable(item):
		return {"ok": false, "reason": "无配方"}
	if GameState.player_level < level_gate():
		return {"ok": false, "reason": "主角等级需 %d" % level_gate()}
	var lf := left_today()
	if lf == 0:
		return {"ok": false, "reason": "今日锻造次数已尽"}
	var r := recipe_of(item6_id)
	if r.is_empty():
		return {"ok": false, "reason": "配方缺失"}
	if int(r["missing"]) > 0:
		return {"ok": false, "reason": "材料不足（缺 %d 种）" % int(r["missing"])}
	var gold := int(r["gold"])
	if GameState.gold < gold:
		return {"ok": false, "reason": "工费不足（需 %d 金）" % gold}
	return {"ok": true, "reason": "", "gold": gold}


## 开炉。成功返回 { ok, msg, item_id, name }。
##
## 【扣料必须先全量校验、再一次性扣】不能「扣一样发现不够就返回」——
## 那会留下已扣掉的料（玩家白白损失材料，且不报错）。这里先 can_craft 全量过，
## 再逐项 consume_item。consume_item 内部只做 has 检查，不会半途失败。
static func craft(item6_id: int) -> Dictionary:
	var gate := can_craft(item6_id)
	if not bool(gate.get("ok", false)):
		return {"ok": false, "msg": str(gate.get("reason", "不可锻造"))}
	var r := recipe_of(item6_id)
	var gold := int(r["gold"])

	GameState.add_gold(-gold)
	for m in r["materials"]:
		var md: Dictionary = m
		GameState.consume_item(str(int(md["item_id"])), int(md["count"]))
	GameState.add_item(str(item6_id), 1)
	GameState.craft_today[GameState.total_days()] = used_today() + 1

	var name := str(r.get("name", str(item6_id)))
	EventBus.inventory_changed.emit(str(item6_id), GameState.get_item_count(str(item6_id)))
	return {"ok": true, "msg": "锻造成功：%s（工费 %d 金）" % [name, gold],
		"item_id": item6_id, "name": name}


## 列出全部可锻造物品（UI 锻造区用）。按 cat_major 再 id 排序，材料齐的排前面。
static func craftable_list() -> Array:
	var rows: Array = []
	for raw in DataManager.get_table("items6"):
		if not (raw is Dictionary):
			continue
		if not is_craftable(raw):
			continue
		var r := recipe_of(int(raw.get("id", 0)))
		if r.is_empty():
			continue
		r["cat"] = int(raw.get("cat_major", 0))
		r["quality"] = str(raw.get("quality_name", ""))
		rows.append(r)
	rows.sort_custom(func(a, b):
		if bool(a["ok"]) != bool(b["ok"]):
			return bool(a["ok"])   # 材料齐的在前
		if int(a["cat"]) != int(b["cat"]):
			return int(a["cat"]) < int(b["cat"])
		return int(a["item_id"]) < int(b["item_id"]))
	return rows
