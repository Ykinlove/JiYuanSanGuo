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

## 武将军团技调度：skill_id(SkillService) -> 持有者 BattleUnit 列表
var _skill_holders: Dictionary = {}
## skill_id -> { next_at: float, uses: int, engage_ok: bool }
var _skill_sched: Dictionary = {}
## 出战时我方总兵力快照（折损结算的分母，避免留守部队被误扣）
var _initial_ally_troops := 0
## 已计入 routs 的敌军实例 id（防止溃散途中被击杀时 kills/routs 双算）
var _routed_ids: Dictionary = {}


func setup(cfg: Dictionary, ally_layer: Node2D, enemy_layer: Node2D) -> void:
	_cfg = cfg
	_ally_layer = ally_layer
	_enemy_layer = enemy_layer
	# 固定种子（20260923）会让同配置战斗的随机序列逐次一致，伤害浮动名存实亡、
	# 可被读档复现；改为每场随机
	_rng.randomize()


## ---------- 布置 ----------

## 按布阵结果生成我方部队
## deployed: FormationCalculator.calculate() 的 detail 数组
## troops:   GameState.troops
func deploy_allies(deployed: Array, troops: Array) -> void:
	_allies.clear()
	_skill_holders.clear()
	_initial_ally_troops = 0
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
			"attack_add": int(d.get("attack_add", 0)),
			"defense_add": int(d.get("defense_add", 0)),
			"hp_add": int(d.get("hp_add", 0)),
			"speed_add": int(d.get("speed_add", 0)),
			"speed_mult": float(d.get("speed_mult", 1.0)),
			"morale_cost": float(d.get("morale_cost", 1.0)),
		}, _cfg, true)
		u.formation_slot = slot
		u.set_counter_table(counter_table_for(str(d["unit_id"])))
		_attach_hero_skill(u, troop)
		_hook_unit(u)
		_allies.append(u)
		_initial_ally_troops += int(u.count)

	_initial_ally_count = _allies.size()


## 按遭遇配置生成敌方部队
func deploy_enemies(encounter: Dictionary) -> void:
	_enemies.clear()
	_routed_ids.clear()
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


## 解析统兵武将的军团技并登记为持有者（无武将/无军团技则跳过）
func _attach_hero_skill(u: BattleUnit, troop: Dictionary) -> void:
	var hero_id := str(troop.get("hero_id", ""))
	if hero_id.is_empty():
		return
	var hero := DataManager.get_hero_resolved(hero_id)
	if hero.is_empty():
		return
	var sid := SkillService.hero_troop_skill(hero)
	if sid == 0:
		return
	u.troop_skill = sid
	u.hero_name = str(hero.get("name", ""))
	if not _skill_holders.has(sid):
		_skill_holders[sid] = []
	(_skill_holders[sid] as Array).append(u)


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
	_init_skill_sched()


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
	_process_skills()


## ---------- 武将军团技调度 ----------

## 为战场上出现的每种军团技初始化节奏状态
func _init_skill_sched() -> void:
	_skill_sched.clear()
	for sid in _skill_holders.keys():
		var k := int(sid)
		var first := float(SkillService.FIRST_DELAY.get(k, SkillService.IRON_WALL_FIRST_DELAY))
		_skill_sched[k] = {
			"next_at": first,
			"uses": 0,
			"engage_ok": false,
		}


func _process_skills() -> void:
	for sid in _skill_holders.keys():
		var k := int(sid)
		var st: Dictionary = _skill_sched.get(k, {})
		if st.is_empty() or int(st["uses"]) >= SkillService.MAX_USES:
			continue
		var holders: Array = _skill_holders[k]
		if not _any_holder_alive(holders):
			continue
		# 铁壁首次与每次 CD 后都需步兵正在交战（交火后略作延迟，避免接敌瞬间全亮）
		if k == SkillService.SKILL_IRON_WALL:
			if not bool(st["engage_ok"]):
				if _any_ally_engaging(SkillService.skill_affects_category(k)):
					st["engage_ok"] = true
					st["next_at"] = maxf(float(st["next_at"]), _elapsed + SkillService.IRON_WALL_ARM_DELAY)
				else:
					continue
		if _elapsed < float(st["next_at"]):
			continue
		_cast_skill(k, holders, st)


## 释放一次军团技。无匹配存活兵种时跳过不耗次数（下 tick 重试）
func _cast_skill(sid: int, holders: Array, st: Dictionary) -> void:
	var cat := SkillService.skill_affects_category(sid)
	var targets: Array[BattleUnit] = []
	for u in _allies:
		if not u.is_gone() and not u.is_routed() and u.category == cat:
			targets.append(u)
	if targets.is_empty():
		return

	match sid:
		SkillService.SKILL_CHARGE:
			for u in targets:
				u.begin_charge()
		SkillService.SKILL_IRON_WALL:
			for u in targets:
				u.apply_defense_buff(float(SkillService.IRON_WALL_DEFENSE), SkillService.BUFF_DURATION)
		SkillService.SKILL_RAPID_FIRE:
			for u in targets:
				u.apply_rapid_fire(SkillService.BUFF_DURATION)

	st["uses"] = int(st["uses"]) + 1
	st["next_at"] = _elapsed + float(SkillService.COOLDOWN[sid])
	st["engage_ok"] = false

	var caster := _first_live_holder(holders)
	var caster_name := caster.hero_name if caster != null and not caster.hero_name.is_empty() else "我军武将"
	log_event.emit("%s发动【%s】，%s" % [
		caster_name, SkillService.skill_name(sid), SkillService.cast_text(sid)
	])


func _any_holder_alive(holders: Array) -> bool:
	for u in holders:
		if u is BattleUnit and not u.is_gone() and not u.is_routed():
			return true
	return false


func _first_live_holder(holders: Array) -> BattleUnit:
	for u in holders:
		if u is BattleUnit and not u.is_gone() and not u.is_routed():
			return u
	return null


## 是否有某兵种我方部队正在交战
func _any_ally_engaging(cat: String) -> bool:
	for u in _allies:
		if not u.is_gone() and not u.is_routed() \
				and u.category == cat and u.state == BattleUnit.State.ENGAGE:
			return true
	return false


func _live(arr: Array) -> Array[BattleUnit]:
	var out: Array[BattleUnit] = []
	for u in arr:
		# 【修复】溃散单位已脱离战斗（正撤向场边），不能再作为攻击目标。
		# 旧代码只排除阵亡，导致友军放着活敌不打、一路追杀逃兵到地图边缘。
		if u is BattleUnit and not u.is_gone() and not u.is_routed():
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
## 【缺陷·已修】原式「x 最小者 = 最近」是错的近似：
##   战场里 y 是**排**（FIELD_Y_CENTER ± COL_SPACING×2 = ±256px），
##   同排敌人的 x 几乎相同而 y 相差最多 256px —— 用 x 选会选中
##   「隔了两排、最远的那支」。于是月牙斩（VFX 落在 battle_scene
##   算出的真正最近者身上）与实际掉血的那支**不是同一支**，
##   玩家看到的是「我砍了 A，A 满血 B 掉了」。
## 改为与 battle_scene._nearest_enemy_pos() 完全同口径的欧氏距离。
func player_strike(damage: float, from: Vector2 = Vector2.INF) -> float:
	var targets := _live(_enemies)
	if targets.is_empty():
		return 0.0
	# 主角位置未知（默认调用）时退化为「最靠左」—— 战场里敌军自右向左
	# 推进，最靠左者即最可能接近主角，仍比原来的近似多一层含义。
	var anchor := from
	var victim: BattleUnit = null
	if anchor.x >= INF:
		victim = targets[0]
		for e in targets:
			if e.position.x < victim.position.x:
				victim = e
	else:
		var best := INF
		for e in targets:
			var d := anchor.distance_to(e.position)
			if d < best:
				best = d
				victim = e
	if victim == null:
		return 0.0
	var before := victim.hp
	victim.take_damage(damage, null)
	_stat_damage_dealt += before - victim.hp
	return before - victim.hp


## 主角大招：范围打击 + 全军士气
## 与 player_strike 同理：目标挑选从「x 最小」改为「距主角最近」，
## 主角位置由调用方传入（battle_scene 手上就有 _player.position）。
func player_ultimate(damage: float, from: Vector2 = Vector2.INF) -> float:
	var targets := _live(_enemies)
	if targets.is_empty():
		return 0.0
	var total := 0.0
	# 打离主角最近的两支部队（全场均匀铺开），次目标吃 60% 衰减
	if from.x < INF:
		targets.sort_custom(func(a, b):
			return from.distance_to(a.position) < from.distance_to(b.position))
	else:
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
		return
	# 溃散的敌军已在 _on_unit_routed 计入 _stat_routs，不能再计入 kills：
	# 否则同一支部队同时进 kills（全额缴获）与 routs（半额缴获），奖励被双算。
	# 【修复】单位死亡时 state 已是 DEAD，is_routed() 取不到 ROUTED，
	# 光靠 is_fled()（只标记"已逃出场边"）拦不住"溃散途中被打死"这一种，
	# 故改用溃散记账集合判定。
	if unit.is_fled() or _routed_ids.has(unit.get_instance_id()):
		return
	_stat_kills += 1
	# 击杀提升我方士气（略）
	if _stat_kills % 2 == 0:
		for u in _allies:
			if not u.is_gone():
				u.boost_morale(6.0)


func _on_unit_routed(unit: BattleUnit) -> void:
	if not unit.is_ally:
		_routed_ids[unit.get_instance_id()] = true
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


## 我方总兵力（未阵亡的部队，含已溃散但仍在撤回的）
## 【修复】旧代码连溃散单位一起排除：部队刚被打崩 HUD 兵力就跳 0，而这些兵
## 其实撤回阵营（GameState.troops 里完好），折损结算也把他们当成全歼。
func ally_troops() -> int:
	var n := 0
	for u in _allies:
		if not u.is_gone():
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


## 出战部队在 GameState.troops 里的下标集合（折损只结转到真正出战的部队，
## 留守部队不跟着缩水）
func deployed_troop_indexes() -> Array:
	var seen: Dictionary = {}
	for u in _allies:
		if u.troop_index >= 0:
			seen[int(u.troop_index)] = true
	return seen.keys()


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
		# 出战兵力快照：折损结算的分子分母必须同口径（都只算上了场的部队）
		"ally_troops_initial": _initial_ally_troops,
		"deployed_indexes": deployed_troop_indexes(),
	}


## ---------- 胜负判定 ----------

func _check_end() -> void:
	if _finished:
		return
	# 胜负判定：主角本人是可操作战力，挂彩后撤而非阵亡。
	# 部曲全灭但主角犹在，主角继续孤身作战，不算失败；
	# 唯有「主角被击倒且部曲已尽」才判负（见 battle_scene._apply_contact_damage）。
	if enemy_alive() == 0:
		_finish(true)


## 本场主角是否曾带部曲出战（孤身作战 = false）。
## 用于区分「部曲尽墨→主角孤身被击倒=真正战败」与「本就孤身=不可被逼败（只能胜/退）」。
func had_allies() -> bool:
	return _initial_ally_count > 0


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
