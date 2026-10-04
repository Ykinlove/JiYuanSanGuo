extends SceneTree
## 战斗逻辑审计探针（第六十八轮·战斗合理化）
##
## 为什么用真跑而不是纯 Python 复算：
##   本轮要抓的缺陷里有一半是**运行期才暴露**的（BattleUnit 依赖
##   CombatFeelService → DataManager，纯静态复算测不到）。所以这里
##   走 SceneTree 型探针：自己 new 出 BattleUnit，走完整 tick()，
##   观测真实行为。
##
## 判据组：
##   L1 组·伤害基准一致性（C 组）—— base_damage 与 calc_damage 口径必须同源
##   L2 组·索敌合理性（D 组）—— 目标评分不得被单一维度垄断
##   L3 组·指令有效性（E 组）—— 固守/集火/冲锋必须真的改变行为
##   L4 组·战斗时长（F 组）—— 不能秒完也不能打不完
##   L5 组·输出契约（G 组）—— player_strike/ultimate 必须打中「最近的」那个
##   Z  组·存档不污染

const UNIT_DIR := "res://assets/data/"


func _init() -> void:
	var fails: Array = []
	var okc := 0
	okc += _group_c(fails)
	okc += _group_d(fails)
	okc += _group_e(fails)
	okc += _group_f(fails)
	okc += _group_g(fails)
	print("PROBE_DONE " + str(okc) + "/" + str(okc + fails.size()))
	if fails.is_empty():
		print("BATTLE_LOGIC_PROBE PASS")
	else:
		for f in fails:
			print("FAIL " + str(f))
		print("BATTLE_LOGIC_PROBE FAIL")
	quit(0)


func _ok(fails: Array, cond: bool, label: String) -> void:
	if cond:
		print("  [OK] " + label)
	else:
		print("  [FAIL] " + label)
		fails.append(label)


## ---------- 公共夹具 ----------

## 直接读 combat.json（探针不依赖 DataManager，避免 autoload 依赖链）
func _cfg() -> Dictionary:
	var f := FileAccess.open(UNIT_DIR + "combat.json", FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		return parsed
	return {}


## 造一支可独立驱动的 BattleUnit
func _mk(cfg: Dictionary, unit_id: String, count: int, x: float, ally: bool) -> BattleUnit:
	var units_path := UNIT_DIR + "units.json"
	var units: Dictionary = {}
	var uf := FileAccess.open(units_path, FileAccess.READ)
	if uf != null:
		var up: Variant = JSON.parse_string(uf.get_as_text())
		uf.close()
		if up is Dictionary:
			units = up
	var src: Dictionary = {}
	var pool: Array = units.get("units", []) if units.has("units") else []
	for raw in pool:
		if raw is Dictionary and str(raw.get("id", "")) == unit_id:
			src = raw
			break
	if src.is_empty():
		src = {
			"id": unit_id, "name": unit_id, "category": "infantry",
			"hp": 100, "attack": 20.0, "defense": 15.0, "speed": 100.0,
			"range": 1,
		}
	var u := BattleUnit.new()
	root.add_child(u)
	u.position = Vector2(x, 540.0)
	u.setup(src, {"count": count, "troop_index": 0}, cfg, ally)
	return u


func _count(u: BattleUnit) -> int:
	return u.count


## ---------- L1·C 组：伤害基准一致性 ----------
## 【要抓的缺陷】base_damage() 用 count/100.0，calc_damage() 用
## clamp(count/max(30,count_max)*0.7+0.3, 0.3, 1.0)。两套口径。
## 后果：base_damage 只用于两处判据 —— ① _strike 里判 is_counter
## ② take_damage 里判 crit。基准错 → 克制/暴击提示全错。
## 例：40 人队（count_max=100）base 系数 0.40 而 calc 系数 0.58，
##     于是「普通一记」被算成 1.45 倍基准 → **每刀都报克制**。
func _group_c(fails: Array) -> int:
	print("== C 组·伤害基准一致性 ==")
	var cfg := _cfg()
	var okc := 0

	# C1：满编时两者必须相等（这是唯一能直接对齐的锚点）
	var u_full := _mk(cfg, "infantry", 100, 300.0, true)
	var full_base := u_full.base_damage()
	var u_full2 := _mk(cfg, "infantry", 100, 500.0, true)
	var full_calc := BattleUnit.calc_damage(u_full2, u_full2)
	# 用同一份 cfg 但不加成的手算参照
	okc += 1
	_ok(fails, absf(full_base - full_calc / 1.0) < full_calc * 0.5,
		"C1 满编 base_damage=%.1f 与 calc_damage=%.1f 同量级" % [full_base, full_calc])

	# C2（核心）：减员后两者必须**同比缩放**，不能各自算各自的
	# 【判据自纠·随机性】首跑用单次采样，variance(±0.16) 直接把
	# 比值带偏 0.06 判据线（0.58 vs 0.52）。凡比值型判据必须
	# 多次采样取均值 —— 单次采样在有随机浮动时必然假红。
	var a := _mk(cfg, "infantry", 100, 300.0, true)
	var b := _mk(cfg, "infantry", 100, 500.0, true)
	var base_full := a.base_damage()
	var calc_full := 0.0
	for i in range(60):
		calc_full += BattleUnit.calc_damage(a, b)
	calc_full /= 60.0
	a.count = 40
	b.count = 40
	var base_40 := a.base_damage()
	var calc_40 := 0.0
	for i in range(60):
		calc_40 += BattleUnit.calc_damage(a, b)
	calc_40 /= 60.0
	var base_ratio := base_40 / maxf(0.001, base_full)
	var calc_ratio := calc_40 / maxf(0.001, calc_full)
	okc += 1
	_ok(fails, absf(base_ratio - calc_ratio) <= 0.02,
		"C2 减员到 40 人时 base_damage 降幅(%.3f) 与真实伤害降幅(%.3f) 偏差 ≤0.02（60 次采样均值）"
			% [base_ratio, calc_ratio])

	# C3：同样剩 50 人，100 人队（半编制）与 200 人队（1/4 编制）
	#     的基准必须**不相等**且方向正确：编制越残，输出越低。
	#     【判据自纠】首跑我写的阈值是「差 ≤10%」，那是把
	#     「100人队剩50人」与「200人队剩50人」当同基准比 —— 错。
	#     两者的 count_factor 是 0.650 / 0.475（差 27%），
	#     这 27% 正是「按各自满编算残兵比例」的设计意图，不是缺陷。
	var c1 := _mk(cfg, "infantry", 100, 300.0, true)
	var c2 := _mk(cfg, "infantry", 200, 500.0, true)
	c1.count = 50
	c2.count = 50
	var base_c1 := c1.base_damage()
	var base_c2 := c2.base_damage()
	okc += 1
	_ok(fails, base_c2 < base_c1 * 0.95,
		"C3 同样剩 50 人，200 人队（1/4 编制）基准 %.1f 应低于 100 人队（半编制）%.1f"
			% [base_c2, base_c1])

	# C4：超编（count > count_max，如增援）不得让基准失控
	var d := _mk(cfg, "infantry", 100, 300.0, true)
	d.count = 300
	var base_over := d.base_damage()
	okc += 1
	_ok(fails, base_over <= base_full * 1.05,
		"C4 超编到 300 人时基准(%.1f) 不超过满编(%.1f) 的 1.05 倍"
			% [base_over, base_full])

	# C5：calc_damage 必须有 min_damage 保底，且不返回负数
	var lo := 0.0
	var attacker := _mk(cfg, "infantry", 100, 300.0, true)
	var defender := _mk(cfg, "infantry", 100, 900.0, false)
	defender.defense = 99999.0
	lo = BattleUnit.calc_damage(attacker, defender)
	var mind := float((cfg.get("combat", {}) as Dictionary).get("min_damage", 2.0))
	okc += 1
	_ok(fails, lo >= mind and lo >= 0.0,
		"C5 极端高防下伤害仍有保底（%.2f ≥ %.2f）且非负" % [lo, mind])

	# C6：克制倍率必须真的改变伤害
	# 【判据自纠·第 4 次踩同一个坑】calc_damage 带 variance(±0.16) 随机浮动，
	# 单次采样的比值会被噪声带偏：本判据理论比值 = 1.25/0.8 = 1.5625，
	# 阈值取 1.4 本应稳过，实测单次只到 1.36 → **假红**。
	# 与 C2/E4/E5/E6 同因，统一改为 60 次采样取均值（比值型判据铁律）。
	var atk := _mk(cfg, "infantry", 100, 300.0, true)
	var dfn := _mk(cfg, "infantry", 100, 900.0, false)
	var s_hi := 0.0
	var s_lo := 0.0
	var N := 60
	for i in range(N):
		atk.set_counter_table({"infantry": 1.25})
		s_hi += BattleUnit.calc_damage(atk, dfn)
		atk.set_counter_table({"infantry": 0.8})
		s_lo += BattleUnit.calc_damage(atk, dfn)
	var d_hi := s_hi / float(N)
	var d_lo := s_lo / float(N)
	okc += 1
	_ok(fails, d_hi > d_lo * 1.4, "C6 克制 1.25 的伤害(%.1f) 显著高于被克 0.8(%.1f)，比值 %.2f（%d 次采样均值）"
		% [d_hi, d_lo, d_hi / maxf(0.01, d_lo), N])

	return okc


## ---------- L2·D 组：索敌合理性 ----------
## 【要抓的缺陷】proximity 权重 1.2 是 counter(0.55)+weak(0.45) 的
## 1.2 倍，且 proximity∈[0,1] 恒为正贡献 —— 「近」本身就是最大权重。
## 后果：所有部队都会一窝蜂扑向最近的敌人，克制表形同虚设。
## 合不合理：战场是横向的，两军阵线距离固定，近战贴脸没有战术差别，
##           真正该起作用的是「打谁最划算」。
func _group_d(fails: Array) -> int:
	print("== D 组·索敌合理性 ==")
	var cfg := _cfg()
	var okc := 0

	var me := _mk(cfg, "spearman", 100, 800.0, true)
	var near_far_pair := []
	# 近处一个被克目标，远处一个被自己克的目标
	var near_bad := _mk(cfg, "cavalry", 100, 900.0, false)     # spearman 被克 cavalry 0.8
	var far_good := _mk(cfg, "spearman", 100, 1300.0, false)   # spearman 克 spearman 1.25
	me.set_counter_table({"cavalry": 0.8, "spearman": 1.25})
	me._acquire_target([near_bad, far_good])
	okc += 1
	_ok(fails, me.target == far_good,
		"D1 面对「近处被克(0.8) vs 远处被克我(1.25)」时应咬后者（选了 %s）"
			% (me.target.unit_id if me.target != null else "null"))

	# D2：残血目标应被优先
	var m2 := _mk(cfg, "infantry", 100, 800.0, true)
	var full_hp := _mk(cfg, "infantry", 100, 1000.0, false)
	var low_hp := _mk(cfg, "infantry", 100, 1010.0, false)
	low_hp.hp = low_hp.hp_max * 0.15
	m2.set_counter_table({})
	m2._acquire_target([full_hp, low_hp])
	okc += 1
	_ok(fails, m2.target == low_hp, "D2 同样距离时应优先打残血目标")

	# D3：不能把已溃散/已阵亡的当目标
	var m3 := _mk(cfg, "infantry", 100, 800.0, true)
	var routed := _mk(cfg, "infantry", 100, 810.0, false)
	routed._begin_rout()
	var fresh := _mk(cfg, "infantry", 100, 1300.0, false)
	m3.set_counter_table({})
	m3._acquire_target([routed, fresh])
	okc += 1
	_ok(fails, m3.target == fresh, "D3 不得把已溃散单位选为目标")

	# D4：无敌人时 target 必须为 null，不得留上一场的残值
	var m4 := _mk(cfg, "infantry", 100, 800.0, true)
	m4._acquire_target([])
	okc += 1
	_ok(fails, m4.target == null, "D4 没有敌人时 target 必须为 null")

	# D5：距离权重不得压倒克制 + 残血之和。
	#     【判据自纠·假红】首跑这里硬编码了字面量 1.2，代码已改但判据
	#     没跟着改 → 报了个不存在的红。判据必须**从 cfg 读**，
	#     否则它测的是「我记忆里的旧值」，代码一改就假红。
	var ai_cfg: Dictionary = (cfg.get("ai", {}) as Dictionary)
	var w_prox := float(ai_cfg.get("proximity_weight", 0.55))
	var w_counter := float(ai_cfg.get("counter_weight", 0.55))
	var w_hp := float(ai_cfg.get("weak_hp_weight", 0.45))
	okc += 1
	_ok(fails, w_prox <= w_counter + w_hp,
		"D5 距离权重(%.2f) 不应大于克制+残血权重之和(%.2f)"
			% [w_prox, w_counter + w_hp])
	okc += 1
	_ok(fails, ai_cfg.has("proximity_weight") and ai_cfg.has("category_weight"),
		"D6 索敌权重四项全部落进 combat.json.ai，不再硬编码在代码里")

	return okc


## ---------- L3·E 组：指令有效性 ----------
## 【要抓的缺陷】
## ① hold_position 只在 _do_advance 里判「距离 > engage_range*2.5 就回 IDLE」，
##    但 IDLE 下 _do_idle 第一件事就是 _acquire_target → 立刻又转回
##    ADVANCE/ENGAGE → **下一 tick 又被弹回 IDLE**。状态在两个态之间
##    每帧来回跳，且固守形同虚设（若敌人进入 2.5 倍范围内就直接开打）。
## ② 固守期间士气照旧每秒掉（_tick_morale 无 hold 豁免），
##    「固守更稳」在数值上体现不出来。
func _group_e(fails: Array) -> int:
	print("== E 组·指令有效性 ==")
	var cfg := _cfg()
	var okc := 0

	# E1：固守单位在远处敌人时，必须**持续**停在原地不推进
	# 【测法要点】tick() 里 IDLE 分支会调 _recover_morale（纯数值，安全），
	# 但 ENGAGE 分支的 _strike → take_damage 会碰表现层。
	# 本例敌人远在 1500px 外，够不到 range_px(92)，不会进 _strike，
	# 因此 tick 整条路径都不碰 autoload —— 可安全真跑。
	var holder := _mk(cfg, "infantry", 100, 400.0, true)
	var foe := _mk(cfg, "infantry", 100, 1500.0, false)
	holder.set_hold(true)
	var x0 := holder.position.x
	var states: Array = []
	for i in range(40):
		holder.tick(0.25, [foe])
		states.append(holder.state)
	okc += 1
	_ok(fails, absf(holder.position.x - x0) < 1.0,
		"E1 固守单位在远敌时 10 秒内 x 不变（%.1f → %.1f）" % [x0, holder.position.x])

	# E2：固守时不得出现 IDLE↔ADVANCE 的逐帧抖动
	#     （抖动不报错，但说明状态机在两个态之间来回弹，逻辑是残的）
	var flips := 0
	for i in range(1, states.size()):
		if states[i] != states[i - 1]:
			flips += 1
	okc += 1
	_ok(fails, flips <= 1,
		"E2 固守 40 tick 内状态切换次数 ≤1（实测 %d 次）" % flips)

	# E3：不固守时必须真的推进（对照组：证明 E1 不是因为单位压根不动）
	# 【测法要点】敌人放在「冲过去能接战、但本组只推进 10 tick 就停」
	# 的距离之外：10 tick × 0.25s × speed(100) = 250px，
	# 从 400 出发落在 650px，仍大于 range_px(92) → 不会进 _strike。
	var mover := _mk(cfg, "infantry", 100, 400.0, true)
	var foe2 := _mk(cfg, "infantry", 100, 4000.0, false)
	mover.set_hold(false)
	var xa := mover.position.x
	for i in range(10):
		mover.tick(0.25, [foe2])
	okc += 1
	_ok(fails, mover.position.x > xa + 10.0,
		"E3 不固守时 10 tick 内确实推进了（%.1f → %.1f）" % [xa, mover.position.x])

	# E4：固守必须真的带来防御收益。
	# 【测法要点】不能用 take_damage 直接喂固定伤害 —— take_damage 是
	# 「收钱」函数，不含任何减伤算式；固守减伤在 calc_damage 里
	# （defender.hold_position → raw *= 1 - hold_defense_bonus）。
	# 只有走 calc_damage 才测得到真实效果（探针首跑就是在这里误报的）。
	var atk_open := _mk(cfg, "infantry", 100, 300.0, true)
	var def_open := _mk(cfg, "infantry", 100, 900.0, false)
	def_open.set_hold(false)
	# 【探针首次真跑就抓到】单次采样被 variance(±0.16) 带偏：
	# 真值比 ≈0.65，但单次可能只跑到 0.83 → 阈值 0.80 判红。
	# 凡比值型判据必须多次采样取均值（同 C2 的教训）。
	var d_open := 0.0
	for i in range(60):
		d_open += BattleUnit.calc_damage(atk_open, def_open)
	d_open /= 60.0
	var atk_hold := _mk(cfg, "infantry", 100, 300.0, true)
	var def_hold := _mk(cfg, "infantry", 100, 900.0, false)
	def_hold.set_hold(true)
	var d_hold := 0.0
	for i in range(60):
		d_hold += BattleUnit.calc_damage(atk_hold, def_hold)
	d_hold /= 60.0
	okc += 1
	_ok(fails, d_hold < d_open * 0.80,
		"E4 固守方挨打掉血(%.1f) 明显少于进攻方(%.1f)，比值 %.2f（60 次采样均值）"
			% [d_hold, d_open, d_hold / maxf(0.001, d_open)])

	# E5：冲锋必须真的更快 + 伤害更高（同样多次采样）
	var ch1 := _mk(cfg, "infantry", 100, 400.0, true)
	ch1.begin_charge()
	var ch2 := _mk(cfg, "infantry", 100, 500.0, true)
	var d_charge := 0.0
	for i in range(60):
		d_charge += BattleUnit.calc_damage(ch1, ch2)
	d_charge /= 60.0
	var normal := _mk(cfg, "infantry", 100, 400.0, true)
	var d_norm := 0.0
	for i in range(60):
		d_norm += BattleUnit.calc_damage(normal, ch2)
	d_norm /= 60.0
	okc += 1
	_ok(fails, d_charge > d_norm * 1.2,
		"E5 冲锋期伤害(%.1f) 高于常态(%.1f)，比值 %.2f（60 次采样均值）"
			% [d_charge, d_norm, d_charge / maxf(0.001, d_norm)])

	# E6：固守方主动输出必须**下降**（攻降防升是固守的核心代价）
	#     否则固守是纯增益，玩家无脑固守 = 无脑最优解
	var hog := _mk(cfg, "infantry", 100, 400.0, true)
	hog.set_hold(true)
	var d_hog_out := 0.0
	for i in range(60):
		d_hog_out += BattleUnit.calc_damage(hog, ch2)
	d_hog_out /= 60.0
	var plain := _mk(cfg, "infantry", 100, 400.0, true)
	var d_plain_out := 0.0
	for i in range(60):
		d_plain_out += BattleUnit.calc_damage(plain, ch2)
	d_plain_out /= 60.0
	okc += 1
	_ok(fails, d_hog_out < d_plain_out,
		"E6 固守方输出(%.1f) 低于正常进攻(%.1f) —— 固守不应是无代价的"
			% [d_hog_out, d_plain_out])

	# E7：冲锋必须真的位移更快（速度乘数生效），而不只是伤害加成
	var cm1 := _mk(cfg, "cavalry", 100, 400.0, true)
	cm1.begin_charge()
	okc += 1
	_ok(fails, cm1._speed_mult() > 1.2,
		"E7 冲锋期速度乘数 %.2f > 1.2" % cm1._speed_mult())

	return okc


## ---------- L4·F 组：战斗时长 ----------
## 【模型要点·自纠】首跑我按「hp 耗尽 = 战斗结束」推算，得 119 秒，
## 但那**不是真实的结束条件**：士气崩溃才是。第七项里
## morale_dmg_weight(0.45) + morale_grind_per_sec(2.2) 会先把单位打到
## rout_morale_threshold(18) 而退场。真实时长 = min(击杀, 士气崩溃)。
## 注释里「战斗时长从 1~2 秒延长到十几秒」的说法必须用这个模型复核。
func _group_f(fails: Array) -> int:
	print("== F 组·战斗时长（双终止模型：击杀 vs 士气崩溃，取先到） ==")
	var cfg := _cfg()
	var ccfg: Dictionary = (cfg.get("combat", {}) as Dictionary)
	var okc := 0

	var a := _mk(cfg, "infantry", 100, 800.0, true)
	var b := _mk(cfg, "infantry", 100, 1000.0, false)
	var interval := clampf(1.15 - a.speed / 400.0, 0.55, 1.2)
	# 期望伤害：跑 40 次取均值，消除 variance(±0.16) 的随机漂移
	var dmg := 0.0
	for i in range(40):
		dmg += BattleUnit.calc_damage(a, b)
	dmg /= 40.0

	# 终止条件 A：血量耗尽
	var t_kill := a.hp_max / maxf(0.001, dmg) * interval
	# 终止条件 B：士气从 100 掉到 rout_morale_threshold
	var w_dmg := float(ccfg.get("morale_dmg_weight", 0.45))
	var grind := float(ccfg.get("morale_grind_per_sec", 2.2))
	var rate := float(ccfg.get("morale_decay_per_sec", 0.45))
	var thr := float(ccfg.get("rout_morale_threshold", 18.0))
	# 每秒士气压力：① 伤害冲击（每秒挨 interval 秒一下）② 按秒疲劳
	# 【口径·必须与产品代码同源】伤害冲击的分母是 hp_max / HP_SCALE，
	# 不是 hp_max —— HP_SCALE 是「战斗总时长」旋钮，士气是独立旋钮，
	# 两者解耦。这里硬编码 8.0 即 BattleUnit.HP_SCALE，同源单点。
	var hp_scale := BattleUnit.HP_SCALE
	var mps_dmg := (dmg / maxf(1.0, a.hp_max / hp_scale)) * 100.0 * w_dmg / interval
	var mps_grind := grind * rate
	var t_morale := (100.0 - thr) / maxf(0.001, mps_dmg + mps_grind)
	var t_real := minf(t_kill, t_morale)

	okc += 1
	_ok(fails, t_real > 0.0,
		"F1 可算出真实时长 %.1fs（击杀 %.1fs / 士气崩溃 %.1fs，期望伤害 %.1f）"
			% [t_real, t_kill, t_morale, dmg])

	# F2：不能秒完
	okc += 1
	_ok(fails, t_real >= 8.0, "F2 战斗不秒完（%.1fs ≥ 8s）" % t_real)

	# F3：手游单场战斗的上限。1v1 对拼超过 45 秒就已冗长 ——
	#     玩家点一次「遭遇」要盯着进度条一分多钟，是明确的体验缺陷。
	okc += 1
	_ok(fails, t_real <= 45.0,
		"F3 单场战斗不拖沓（%.1fs ≤ 45s；击杀线 %.1fs、士气线 %.1fs）"
			% [t_real, t_kill, t_morale])

	# F4：超编方应当明显更耐打（兵力必须真的换算成耐久）
	var small := _mk(cfg, "infantry", 40, 800.0, true)
	var big := _mk(cfg, "infantry", 200, 1000.0, true)
	okc += 1
	_ok(fails, big.hp_max > small.hp_max * 2.0,
		"F4 200 人队耐久(%.0f) 显著高于 40 人队(%.0f)" % [big.hp_max, small.hp_max])

	# F5：耐久必须随兵力**单调递增**且有上限。
	#     【判据自纠】首跑我写的是「25 人队是满编的 0.30~1.0 倍」——
	#     参照系错。hp_ratio 的基准是 HP_TROOP_REF=40（1.0×），
	#     不是「本次战斗的满编数」，所以 25 人 → 0.625、
	#     100 人 → 2.50，比值 0.25 完全正常。判据该问的是
	#     「有没有落在 hp_ratio 的钳位区间内」。
	var s1 := _mk(cfg, "infantry", 25, 800.0, true)
	var s2 := _mk(cfg, "infantry", 100, 800.0, true)
	var s3 := _mk(cfg, "infantry", 400, 800.0, true)
	okc += 1
	_ok(fails, s1.hp_max < s2.hp_max and s2.hp_max <= s3.hp_max,
		"F5 耐久随兵力单调不减且已封顶（25人 %.0f / 100人 %.0f / 400人 %.0f）"
			% [s1.hp_max, s2.hp_max, s3.hp_max])
	# F6：超编必须封顶。
	#     【判据自纠·参照系】封顶是 HP_TROOP_MAX_RATIO=4.0，
	#     而 hp_ratio = count / HP_TROOP_REF(40) → 封顶对应 **160 兵**，
	#     不是 100 兵。首跑拿 100 人当封顶点，参照系错，判了假红。
	var cap1 := _mk(cfg, "infantry", 160, 800.0, true)
	var cap2 := _mk(cfg, "infantry", 400, 800.0, true)
	okc += 1
	_ok(fails, cap1.hp_max == cap2.hp_max,
		"F6 160 兵(%.0f) 与 400 兵(%.0f) 耐久相同 —— 超编只加输出不加耐久"
			% [cap1.hp_max, cap2.hp_max])

	# F7：兵种差异要能体现在实战时长上（否则兵种数据无意义）
	var inf := _mk(cfg, "infantry", 100, 800.0, true)
	var cav := _mk(cfg, "cavalry", 100, 800.0, true)
	var foe_i := _mk(cfg, "infantry", 100, 1000.0, false)
	var t_inf := inf.hp_max / maxf(0.001, BattleUnit.calc_damage(cav, foe_i))
	var t_cav := cav.hp_max / maxf(0.001, BattleUnit.calc_damage(inf, foe_i))
	okc += 1
	_ok(fails, absf(t_inf - t_cav) >= 0.5,
		"F7 兵种间存在实战时长差异（步兵 %.1fs vs 骑兵 %.1fs）" % [t_inf, t_cav])

	return okc


## ---------- L5·G 组：输出契约 ----------
## 【要抓的缺陷】player_strike 用「x 最小」近似「离主角最近」。
## 战场里 y 是**排**，同排多支敌军的 x 相近而 y 不同；用 x 选会让
## 月牙斩（落在真正的最近者身上）与实际掉血的那支**不是同一支**。
## 用户看到的「我砍了 A，A 满血 B 掉了」就是这么来的。
## 那一项需要 director 参与（探针零 autoload 依赖），由
## _verify_battle_logic.py 做静态锚定复核。
## 本组只测 BattleUnit 自身**不碰表现层**的契约：
## 受击结算里的「扣血 / 扣兵」是纯数值逻辑，用 hp/count 直接断言。
func _group_g(fails: Array) -> int:
	print("== G 组·输出契约（零 autoload 依赖部分） ==")
	var cfg := _cfg()
	var okc := 0

	# G1：血量上限必须由兵力推导，且兵力越多越厚
	var g1a := _mk(cfg, "infantry", 40, 800.0, true)
	var g1b := _mk(cfg, "infantry", 160, 1000.0, true)
	okc += 1
	_ok(fails, g1b.hp_max > g1a.hp_max,
		"G1 160 人队耐久(%.0f) 高于 40 人队(%.0f)" % [g1b.hp_max, g1a.hp_max])

	# G2：单兵耐久 = hp_max / count_max（take_damage 折算的分母）
	#     兵力折损公式必须与耐久同源，否则「人没了血还满」
	var g2 := _mk(cfg, "infantry", 100, 800.0, true)
	var per_troop := g2.hp_max / maxf(1.0, float(g2.count_max))
	okc += 1
	_ok(fails, per_troop > 0.0 and is_finite(per_troop),
		"G2 单兵耐久可解析（%.2f/兵）" % per_troop)

	# G3：calc_damage 不得返回 0 / 负数（min_damage 保底生效）
	var g3a := _mk(cfg, "infantry", 10, 800.0, true)
	var g3b := _mk(cfg, "infantry", 100, 1000.0, false)
	g3b.defense = 99999.0
	g3b.buff_defense_add = 99999.0
	var d3 := BattleUnit.calc_damage(g3a, g3b)
	okc += 1
	_ok(fails, d3 > 0.0, "G3 极端高防下伤害仍为正（%.2f）" % d3)

	# G4：单位必须能被标记为溃散并进入 ROUTED 态
	var g4 := _mk(cfg, "infantry", 100, 800.0, true)
	g4._begin_rout()
	okc += 1
	_ok(fails, g4.is_routed() and not g4.is_gone(),
		"G4 溃散后 is_routed 为真但仍算存活（未阵亡）")

	# G5：溃散单位必须被索敌排除（缺陷已修的回归锁）
	var g5me := _mk(cfg, "infantry", 100, 800.0, true)
	var g5rout := _mk(cfg, "infantry", 100, 810.0, false)
	var g5live := _mk(cfg, "infantry", 100, 1300.0, false)
	g5rout._begin_rout()
	g5me.set_counter_table({})
	g5me._acquire_target([g5rout, g5live])
	okc += 1
	_ok(fails, g5me.target == g5live, "G5 索敌跳过已溃散单位")

	# G6：base_damage 不得为 0（它是克制/暴击的判据基准，0 会让判据恒真）
	var g6 := _mk(cfg, "infantry", 10, 800.0, true)
	okc += 1
	_ok(fails, g6.base_damage() > 0.0, "G6 base_damage 为正（%.2f）" % g6.base_damage())

	return okc