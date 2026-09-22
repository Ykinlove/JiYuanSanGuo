extends Node
class_name BattleDirector
## 战场总指挥（BattleDirector）
## 职责：把「布阵结果 + 敌方配置」变成战场上的 BattleUnit，
##       驱动固定步长战斗 tick、处理索敌/攻击/溃散/阵亡、汇总战况、判定胜负。
##
## 设计：与渲染解耦——只操作 Node2D 坐标与数值，不关心怎么画。

signal battle_finished(win: bool, summary: Dictionary)
signal unit_removed(unit: BattleUnit)
signal log_event(text: String)

## 坐标参数（与 battle_scene 保持一致）
const FIELD_Y_CENTER := 540.0
const COL_SPACING := 128.0
const ROW_SPACING := 192.0
const ALLY_ROW_X := [1080.0, 780.0, 480.0]     ## row 0 前军最靠敌
const ENEMY_ROW_X := [840.0, 1140.0, 1440.0]   ## 敌军前军最靠我

var _cfg: Dictionary = {}
var _allies: Array = []
var _enemies: Array = []
var _ally_layer: Node2D
var _enemy_layer: Node2D
var _rng := RandomNumberGenerator.new()

var _running := false
var _tick_accum := 0.0
var _elapsed := 0.0
var _finished := false

## 统计
var _stat_kills := 0
var _stat_routs := 0
var _stat_losses := 0
var _stat_damage_dealt := 0.0
var _stat_damage_taken := 0.0
var _initial_ally_count := 0
var _initial_enemy_count := 0


func setup(cfg: Dictionary, ally_layer: Node2D, enemy_layer: Node2D) -> void:
	_cfg = cfg
	_ally_layer = ally_layer
	_enemy_layer = enemy_layer
	_rng.seed = 20260923


## ---------- 布置 ----------

## 按布阵结果生成我方部队
## deployed: FormationCalculator.calculate() 的 detail 数组
## troops:   GameState.troops
func deploy_allies(deployed: Array, troops: Array) -> void:
	_allies.clear()
	for d in deployed:
		var troop_index := int(d["troop_index"])
		var troop: Dictionary = troops[troop_index] if troop_index < troops.size() else {}
		var unit := DataManager.get_unit(str(d["unit_id"]))
		if unit.is_empty():
			continue

		var slot := int(d["slot"])
		var row := FormationCalculator.row_of(slot)
		var col := FormationCalculator.col_of(slot)

		var u := BattleUnit.new()
		u.position = Vector2(
			ALLY_ROW_X[clampi(row, 0, 2)],
			FIELD_Y_CENTER + (col - 2) * COL_SPACING
		)
		_ally_layer.add_child(u)
		u.setup(unit, {
			"count": int(d["count"]),
			"troop_index": troop_index,
			"attack_mult": float(d["attack_bonus"]),
			"defense_mult": float(d["defense_bonus"]),
		}, _cfg, true)
		u.formation_slot = slot
		u.set_counter_table(counter_table_for(str(d["unit_id"])))
		_hook_unit(u)
		_allies.append(u)

	_initial_ally_count = _allies.size()


## 按遭遇配置生成敌方部队
func deploy_enemies(encounter: Dictionary) -> void:
	_enemies.clear()
	var units: Array = encounter.get("enemy_units", [])
	if units.is_empty():
		# 保底：无配置时给两支部队
		units = [
			{ "unit_id": "infantry", "count": 80 },
			{ "unit_id": "archer", "count": 50 },
		]

	# 敌方阵列：前排最多 3 支居中，其余排后
	var placed := 0
	for e in units:
		var unit := DataManager.get_unit(str(e.get("unit_id", "")))
		if unit.is_empty():
			continue
		var enemy_count := int(e.get("count", 60))
		# 敌方一支持兵上限压一压，避免单队过强
		enemy_count = maxi(20, int(enemy_count * 0.8))

		# 前排 3 支 + 后排补位
		var row := 0 if placed < 3 else 1
		var col := placed if placed < 3 else placed - 3

		var u := BattleUnit.new()
		u.position = Vector2(
			ENEMY_ROW_X[clampi(row, 0, 2)],
			FIELD_Y_CENTER + (col - 1) * COL_SPACING
		)
		_enemy_layer.add_child(u)
		u.setup(unit, {
			"count": enemy_count,
			"troop_index": -1,
			"attack_mult": 0.0,
			"defense_mult": 0.0,
		}, _cfg, false)
		u.set_counter_table(counter_table_for(str(e.get("unit_id", ""))))
		_hook_unit(u)
		_enemies.append(u)
		placed += 1

	_initial_enemy_count = _enemies.size()


func _hook_unit(u: BattleUnit) -> void:
	u.unit_died.connect(_on_unit_died)
	u.unit_routed.connect(_on_unit_routed)
	u.damage_dealt.connect(_on_damage_dealt)


## ---------- 克制表 ----------

## 从 combat.json 的 counter_matrix 取某兵种"打谁加倍"的表
func counter_table_for(unit_id: String) -> Dictionary:
	var matrix: Dictionary = _cfg.get("counter_matrix", {})
	var table := {}
	for entry in matrix.get(unit_id, []):
		if str(entry.get("unit_id", "")).begins_with("_"):
			continue
		table[str(entry["unit_id"])] = float(entry.get("mult", 1.0))
	return table


## ---------- 主循环 ----------

func start() -> void:
	_running = true
	_tick_accum = 0.0
	_elapsed = 0.0
	_finished = false


func stop() -> void:
	_running = false


func process_delta(delta: float) -> void:
	if not _running or _finished:
		return
	_elapsed += delta

	var tick := float(_cfg.get("combat", {}).get("tick_rate", 0.25))
	_tick_accum += delta
	# 固定步长：避免高帧率下伤害计算漂移
	while _tick_accum >= tick:
		_tick_accum -= tick
		_simulate(tick)

	_check_end()


func _simulate(step: float) -> void:
	for u in _allies:
		if not u.is_gone():
			u.tick(step, _live(_enemies))
	for u in _enemies:
		if not u.is_gone():
			u.tick(step, _live(_allies))


func _live(arr: Array) -> Array:
	var out: Array = []
	for u in arr:
		if not u.is_gone():
			out.append(u)
	return out


## ---------- 指令 ----------

## 全军突击：所有存活我方部队发起冲锋
func command_charge() -> void:
	var n := 0
	for u in _allies:
		if not u.is_gone() and not u.is_routed():
			u.set_hold(false)
			u.begin_charge()
			n += 1
	if n > 0:
		log_event.emit("全军突击！%d 支部队发起冲锋" % n)


## 固守：停止推进，防御提升
func command_hold() -> void:
	var n := 0
	for u in _allies:
		if not u.is_gone() and not u.is_routed():
			u.set_hold(true)
			u.boost_morale(12.0)
			n += 1
	if n > 0:
		log_event.emit("全军固守，士气 +12")


## 分队进攻：让某支部队集中攻击指定目标
func command_focus(troop_index: int) -> bool:
	var found: BattleUnit = null
	for u in _allies:
		if u.troop_index == troop_index and not u.is_gone():
			found = u
			break
	if found == null:
		return false
	if _enemies.is_empty():
		return false
	# 选一个敌方最弱的集中攻击
	var weakest: BattleUnit = null
	var low := INF
	for e in _enemies:
		if e.is_gone():
			continue
		if e.hp < low:
			low = e.hp
			weakest = e
	if weakest == null:
		return false
	found.target = weakest
	found.state = BattleUnit.State.ENGAGE if found._in_range(weakest) else BattleUnit.State.ADVANCE
	log_event.emit("%s 集中攻击 %s" % [found.unit_name, weakest.unit_name])
	return true


## 主角攻击造成额外伤害 → 转成对最近敌军的打击 + 友军士气鼓舞
func player_strike(damage: float) -> float:
	var targets := _live(_enemies)
	if targets.is_empty():
		return 0.0
	# 找离主角最近的（用最靠左的敌军近似）
	var nearest: BattleUnit = targets[0]
	for e in targets:
		if e.position.x < nearest.position.x:
			nearest = e
	var before := nearest.hp
	nearest.take_damage(damage, null)
	_stat_damage_dealt += before - nearest.hp
	return before - nearest.hp


## 主角大招：范围打击 + 全军士气
func player_ultimate(damage: float) -> float:
	var targets := _live(_enemies)
	if targets.is_empty():
		return 0.0
	var total := 0.0
	# 打最靠前的两支部队
	targets.sort_custom(func(a, b): return a.position.x < b.position.x)
	for i in range(mini(2, targets.size())):
		var before := targets[i].hp
		targets[i].take_damage(damage * (1.0 if i == 0 else 0.6), null)
		total += before - targets[i].hp
	_stat_damage_dealt += total
	for u in _allies:
		if not u.is_gone():
			u.boost_morale(15.0)
	log_event.emit("大招命中 %d 支部队，全军士气 +15" % mini(2, targets.size()))
	return total


## ---------- 事件回调 ----------

func _on_unit_died(unit: BattleUnit) -> void:
	unit_removed.emit(unit)
	if unit.is_ally:
		_stat_losses += 1
	else:
		_stat_kills += 1
	# 击杀提升我方士气（略）
		if _stat_kills % 2 == 0:
			for u in _allies:
				if not u.is_gone():
					u.boost_morale(6.0)


func _on_unit_routed(unit: BattleUnit) -> void:
	if not unit.is_ally:
		_stat_routs += 1
		log_event.emit("%s 溃散！" % unit.unit_name)


func _on_damage_dealt(_unit: BattleUnit, amount: float, _is_counter: bool) -> void:
	if _unit.is_ally:
		_stat_damage_dealt += amount
	else:
		_stat_damage_taken += amount


## ---------- 战况 ----------

func ally_alive() -> int:
	var n := 0
	for u in _allies:
		if not u.is_gone() and not u.is_routed():
			n += 1
	return n


func enemy_alive() -> int:
	var n := 0
	for u in _enemies:
		if not u.is_gone() and not u.is_routed():
			n += 1
	return n


## 我方总兵力（存活部队）
func ally_troops() -> int:
	var n := 0
	for u in _allies:
		if not u.is_gone() and not u.is_routed():
			n += u.count
	return n


func enemy_troops() -> int:
	var n := 0
	for u in _enemies:
		if not u.is_gone() and not u.is_routed():
			n += u.count
	return n


## 我方平均士气
func ally_morale() -> float:
	var total := 0.0
	var n := 0
	for u in _allies:
		if not u.is_gone() and not u.is_routed():
			total += u.morale
			n += 1
	return total / maxf(1.0, float(n))


func enemy_morale() -> float:
	var total := 0.0
	var n := 0
	for u in _enemies:
		if not u.is_gone() and not u.is_routed():
			total += u.morale
			n += 1
	return total / maxf(1.0, float(n))


## 战况摘要
func summary() -> Dictionary:
	return {
		"elapsed": _elapsed,
		"kills": _stat_kills,
		"routs": _stat_routs,
		"losses": _stat_losses,
		"damage_dealt": int(_stat_damage_dealt),
		"damage_taken": int(_stat_damage_taken),
		"ally_initial": _initial_ally_count,
		"enemy_initial": _initial_enemy_count,
		"ally_alive": ally_alive(),
		"enemy_alive": enemy_alive(),
		"ally_troops": ally_troops(),
		"enemy_troops": enemy_troops(),
	}


## ---------- 胜负判定 ----------

func _check_end() -> void:
	if _finished:
		return
	# 我方全灭 / 全溃
	var my_alive := ally_alive()
	var foe_alive := enemy_alive()

	if foe_alive == 0:
		_finish(true)
	elif my_alive == 0:
		_finish(false)


func _finish(win: bool) -> void:
	_finished = true
	_running = false
	battle_finished.emit(win, summary())


## 我方崩溃（主角逃跑等）外部强制结束
func force_end(win: bool) -> void:
	if _finished:
		return
	_finish(win)


func is_finished() -> bool:
	return _finished


## 获取战场态势（供 HUD 显示）
func situation() -> Dictionary:
	return {
		"ally_alive": ally_alive(),
		"enemy_alive": enemy_alive(),
		"ally_troops": ally_troops(),
		"enemy_troops": enemy_troops(),
		"ally_morale": ally_morale(),
		"enemy_morale": enemy_morale(),
	}


## 找屏幕上最靠前的我方部队（供主角显示"最近战友"）
func front_ally() -> BattleUnit:
	var best: BattleUnit = null
	for u in _allies:
		if u.is_gone() or u.is_routed():
			continue
		if best == null or u.position.x > best.position.x:
			best = u
	return best
