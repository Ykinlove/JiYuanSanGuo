extends Node
class_name FormationCalculator
## 阵型计算器（FormationCalculator）
## 职责：纯计算模块。输入「哪些部队摆在哪些阵位」，输出各项加成明细与战力预估。
## 设计：不持有任何场景节点引用，可被 UI / 战斗 / 自动化测试独立调用。
##
## 网格约定：
##   index = row * COLS + col
##   row 0=前军(贴近敌)  1=中军  2=后军(我方大营)
##   col 0=左锋          2=中坚        4=右锋

const ROWS := 3
const COLS := 5
const SLOT_COUNT := ROWS * COLS   ## 15

## 数据表缓存
var _grid: Dictionary = {}
var _slot_bonuses: Array = []      ## 按 row*COLS+col 顺序缓存，便于 O(1) 取用
var _row_match: Array = []
var _quality_cfg: Dictionary = {}
var _hero_cfg: Dictionary = {}
var _loaded := false


## 载入配置（幂等）
func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true

	var table := DataManager.get_record("formation_slots", "root")
	if table.is_empty():
		# formation_slots.json 为对象而非数组，DataManager 未索引；直接取原始表
		table = _raw_table()

	_grid = table.get("grid", {"rows": ROWS, "cols": COLS})
	_quality_cfg = table.get("unit_quality_baseline", {})
	_hero_cfg = table.get("hero_multiplier", {})

	# 阵位加成按 index 建表
	_slot_bonuses = []
	for i in range(SLOT_COUNT):
		_slot_bonuses.append({})
	for sb in table.get("slot_bonuses", []):
		var idx := int(sb.get("row", 0)) * COLS + int(sb.get("col", 0))
		if idx >= 0 and idx < SLOT_COUNT:
			_slot_bonuses[idx] = sb

	# 行适配按 row 建表
	_row_match = [{}, {}, {}]
	for rm in table.get("row_match", []):
		var r := int(rm.get("row", 0))
		if r >= 0 and r < ROWS:
			_row_match[r] = rm


## 读取 formation_slots.json 原始对象
func _raw_table() -> Dictionary:
	var path := "res://assets/data/formation_slots.json"
	if not FileAccess.file_exists(path):
		push_warning("[FormationCalculator] 配置缺失：%s" % path)
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK:
		push_error("[FormationCalculator] JSON 解析失败：%s" % path)
		return {}
	if json.data is Dictionary:
		return json.data
	return {}


## ---------- 网格坐标工具 ----------

static func index_of(row: int, col: int) -> int:
	return row * COLS + col


static func row_of(index: int) -> int:
	return int(index / COLS)


static func col_of(index: int) -> int:
	return index % COLS


static func is_valid_index(index: int) -> bool:
	return index >= 0 and index < SLOT_COUNT


## 阵位名称（如"前军·中锋"）
func slot_label(index: int) -> String:
	if not is_valid_index(index):
		return "—"
	var sb: Dictionary = _slot_bonuses[index]
	var row_names: Array = _grid.get("row_names", ["前军", "中军", "后军"])
	var col_names: Array = _grid.get("col_names", ["左锋", "左翼", "中坚", "右翼", "右锋"])
	return "%s·%s" % [row_names[row_of(index)], col_names[col_of(index)]]


## 取阵位加成
func slot_bonus(index: int) -> Dictionary:
	if not is_valid_index(index):
		return {}
	return _slot_bonuses[index]


## ---------- 行适配判定 ----------

## 返回 { bonus: float, desc: String, kind: "good"/"bad"/"none" }
func row_match_bonus(index: int, unit_category: String) -> Dictionary:
	if not is_valid_index(index):
		return {"bonus": 0.0, "desc": "", "kind": "none"}
	var rm: Dictionary = _row_match[row_of(index)]
	if rm.is_empty():
		return {"bonus": 0.0, "desc": "", "kind": "none"}

	var good: Array = rm.get("good_categories", [])
	if unit_category in good:
		return {
			"bonus": float(rm.get("good_bonus", 0.0)),
			"desc": str(rm.get("good_desc", "")),
			"kind": "good",
		}
	var bad: Array = rm.get("bad_categories", [])
	if unit_category in bad:
		return {
			"bonus": float(rm.get("bad_penalty", 0.0)),
			"desc": str(rm.get("bad_desc", "")),
			"kind": "bad",
		}
	return {"bonus": 0.0, "desc": "", "kind": "none"}


## ---------- 兵种品质与武将加成 ----------

func unit_quality(unit: Dictionary) -> float:
	var atk := float(unit.get("attack", 20))
	var hp := float(unit.get("hp", 100))
	var div := float(_quality_cfg.get("attack_divisor", 30.0))
	var w := float(_quality_cfg.get("hp_weight", 0.1))
	return maxf(0.2, (atk + hp * w) / div)


func hero_multiplier(hero: Dictionary, is_command_slot: bool) -> float:
	if hero.is_empty():
		return 1.0
	var stats: Dictionary = hero.get("stats", {})
	# 统率近似 = 智力与魅力均值
	var cmd := (float(stats.get("intelligence", 50)) + float(stats.get("charisma", 50))) * 0.5
	var base := float(_hero_cfg.get("base_stat", 50))
	var div := float(_hero_cfg.get("divisor", 200.0))
	var cap := float(_hero_cfg.get("cap", 0.30))
	var mult := 1.0 + clampf((cmd - base) / div, -cap, cap)
	if is_command_slot:
		# 中帐位统帅加成翻倍（取其超出 1.0 的部分翻倍）
		mult = 1.0 + (mult - 1.0) * float(slot_bonus(_command_slot_index()).get("command_bonus", 1.0))
	return mult


func _command_slot_index() -> int:
	return index_of(2, 2)   ## 后军·中帐


## ---------- 核心：计算整场配置 ----------

## 输入：
##   slots        Array[15]，每项为部队索引(int) 或 -1（空）
##   troops       GameState.troops —— [{ unit_id, count, hero_id? }, ...]
##   formation    DataManager.get_formation(formation_id)
## 输出：
##   {
##     total_power: float,
##     detail: [ { slot, troop_index, unit_id, unit_name, count,
##                 slot_label, attack_bonus, defense_bonus,
##                 row_kind, row_desc, power, warnings:[...] }, ... ],
##     warnings: [String],
##     filled: int,
##   }
func calculate(slots: Array, troops: Array, formation: Dictionary) -> Dictionary:
	ensure_loaded()

	var f_atk := float(formation.get("attack_bonus", 0.0))
	var f_def := float(formation.get("defense_bonus", 0.0))

	var detail: Array = []
	var warnings: Array = []
	var total_power := 0.0
	var filled := 0

	for idx in range(SLOT_COUNT):
		var troop_index := int(slots[idx]) if idx < slots.size() else -1
		if troop_index < 0 or troop_index >= troops.size():
			continue
		var troop: Dictionary = troops[troop_index]
		var unit := DataManager.get_unit(str(troop.get("unit_id", "")))
		if unit.is_empty():
			continue
		filled += 1

		var sb: Dictionary = _slot_bonuses[idx]
		var s_atk := float(sb.get("attack_bonus", 0.0))
		var s_def := float(sb.get("defense_bonus", 0.0))

		var category := str(unit.get("category", ""))
		var rm := row_match_bonus(idx, category)

		var is_cmd := idx == _command_slot_index()
		var hero: Dictionary = {}
		var hero_id := str(troop.get("hero_id", ""))
		if not hero_id.is_empty():
			hero = DataManager.get_character(hero_id)
		var h_mult := hero_multiplier(hero, is_cmd)

		var count := int(troop.get("count", 0))
		var q := unit_quality(unit)

		# 战力公式：兵力 × 阵型加成 × 阵位加成 × 行适配 × 兵种品质 × 武将加成
		# 行适配对攻击向加成影响为主；此处简化为乘到总战力上（负值则按 1+负值 缩放）
		var row_factor: float = 1.0 + float(rm["bonus"])
		var power: float = float(count) \
			* (1.0 + f_atk) \
			* (1.0 + s_atk) \
			* row_factor \
			* q \
			* h_mult

		total_power += power

		# 组合警告
		var slot_warnings: Array = []
		if rm["kind"] == "bad":
			slot_warnings.append(rm["desc"])
		if category == "archer" and row_of(idx) == 0:
			slot_warnings.append("弓兵置于前排，极易被冲散")
		if category == "cavalry" and row_of(idx) == 2:
			slot_warnings.append("骑兵置于后排，无法发挥冲击力")

		detail.append({
			"slot": idx,
			"troop_index": troop_index,
			"unit_id": str(troop.get("unit_id", "")),
			"unit_name": str(unit.get("name", troop.get("unit_id", ""))),
			"count": count,
			"slot_label": slot_label(idx),
			"attack_bonus": f_atk + s_atk + rm["bonus"],
			"defense_bonus": f_def + s_def,
			"row_kind": rm["kind"],
			"row_desc": rm["desc"],
			"power": power,
			"warnings": slot_warnings,
		})

	if filled == 0:
		warnings.append("未布置任何部队")

	return {
		"total_power": total_power,
		"detail": detail,
		"warnings": warnings,
		"filled": filled,
	}


## ---------- 胜率预估 ----------

## 基于双方战力的 Logistic 估计，输出 0~1
func estimate_win_rate(my_power: float, enemy_power: float) -> float:
	if my_power <= 0.0 and enemy_power <= 0.0:
		return 0.5
	if enemy_power <= 0.0:
		return 1.0
	if my_power <= 0.0:
		return 0.0
	var ratio := my_power / enemy_power
	# 用 log 使得战力比 1.0 → 50%，2.0 → ~76%，0.5 → ~24%
	var x := log(ratio) * 1.1
	return 1.0 / (1.0 + exp(-x))


## 敌方战力粗估（用于战前对比）
func estimate_enemy_power(encounter: Dictionary) -> float:
	ensure_loaded()
	var total := 0.0
	for u in encounter.get("enemy_units", []):
		var unit := DataManager.get_unit(str(u.get("unit_id", "")))
		if unit.is_empty():
			continue
		var count := int(u.get("count", 0))
		# 敌方无阵型加成，仅计兵种品质与兵力
		total += float(count) * unit_quality(unit)
	return total


## ---------- 默认摆位（自动布阵） ----------

## 把 troops 按兵种智能填入 slots，返回新的 slots 数组。
## 规则：骑兵/精英→前军与中军；步兵→前军与中军；弓兵→后军。
## 返回 { slots: Array, formation_id: String }
func auto_arrange(troops: Array) -> Array:
	ensure_loaded()
	var slots: Array = []
	for i in range(SLOT_COUNT):
		slots.append(-1)
	if troops.is_empty():
		return slots

	# 分池
	var front_pool: Array = []   # 步兵 / 骑兵 / 精英 / 象兵 / 特殊
	var rear_pool: Array = []    # 弓兵
	for i in range(troops.size()):
		var unit := DataManager.get_unit(str(troops[i].get("unit_id", "")))
		var cat := str(unit.get("category", ""))
		if cat == "archer":
			rear_pool.append(i)
		else:
			front_pool.append(i)

	# 前军优先放步兵（列阵如墙），其次骑兵
	front_pool.sort_custom(func(a, b):
		return _front_priority(troops[a]) > _front_priority(troops[b])
	)

	# 前军 5 格：中锋优先给最强的
	var front_order := [index_of(0, 2), index_of(0, 1), index_of(0, 3), index_of(0, 0), index_of(0, 4)]
	var mid_order := [index_of(1, 2), index_of(1, 1), index_of(1, 3), index_of(1, 0), index_of(1, 4)]
	var rear_order := [index_of(2, 2), index_of(2, 1), index_of(2, 3), index_of(2, 0), index_of(2, 4)]

	var pi := 0
	for s in front_order:
		if pi < front_pool.size():
			slots[s] = front_pool[pi]
			pi += 1
	for s in mid_order:
		if pi < front_pool.size():
			slots[s] = front_pool[pi]
			pi += 1

	var ri := 0
	for s in rear_order:
		if ri < rear_pool.size():
			slots[s] = rear_pool[ri]
			ri += 1

	return slots


## 前军优先级：步兵最高（抗线），其次精英/骑兵
func _front_priority(troop: Dictionary) -> int:
	var unit := DataManager.get_unit(str(troop.get("unit_id", "")))
	var cat := str(unit.get("category", ""))
	match cat:
		"infantry":
			return 4
		"elite":
			return 3
		"cavalry":
			return 2
		"beast":
			return 1
		_:
			return 0
