extends SceneTree
## 战斗演出探针（第六十九轮·战斗演出强化）
##
## 【本层要证明的核心主张】
##   战场单位不再是「一堆左右对称的图钉站在原地互砍」：
##     ① 朝向真的变 —— _face 不再是两个分支相同的死代码；
##     ② 转身是**过程**且**绝不穿过 scale.x=0**（穿过那帧会压扁成一条线）；
##     ③ 战况标签与地面投影**不被翻转**（翻了就读不清战况 / 影子翻向是错的）；
##     ④ 推进留轨迹 —— 走过路径淡出，不是滑步；
##     ⑤ 阵亡是「倒下」而不是「消失」。
##
## 【测法要点】全部走**公开入口 tick()**，不 new 测试钩子、不暴露私有方法 ——
## 走真实路径才测得到真实行为（_face / _apply_impulse 都在 tick 的调用链里）。
## 敌人放在够得着的距离，tick 一次就够 _do_engage → _face。

const UNIT_DIR := "res://assets/data/"


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var fails: Array = []
	var okc := 0
	okc += _group_v(fails)   # V 组·朝向
	okc += _group_t(fails)   # T 组·轨迹
	# 【血泪】_group_d 内含 await（tween 需帧推进）→ 必须 await 调用。
	# 漏写 await 会让整条链挂在第一个 await 空跑，却照样输出 PASS = 假绿灯。
	okc += await _group_d(fails)
	print("PROBE_DONE " + str(okc) + "/" + str(okc + fails.size()))
	if fails.is_empty():
		print("BATTLE_VISUAL_PROBE PASS")
	else:
		for f in fails:
			print("FAIL " + str(f))
		print("BATTLE_VISUAL_PROBE FAIL")
	quit(0)


func _ok(fails: Array, cond: bool, label: String) -> void:
	if cond:
		print("  [OK] " + label)
	else:
		print("  [FAIL] " + label)
		fails.append(label)


func _cfg() -> Dictionary:
	var f := FileAccess.open(UNIT_DIR + "combat.json", FileAccess.READ)
	if f == null:
		return {}
	var p: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return (p as Dictionary) if p is Dictionary else {}


func _mk(cfg: Dictionary, unit_id: String, count: int, x: float, ally: bool) -> BattleUnit:
	var uf := FileAccess.open(UNIT_DIR + "units.json", FileAccess.READ)
	var units: Dictionary = {}
	if uf != null:
		var up: Variant = JSON.parse_string(uf.get_as_text())
		uf.close()
		if up is Dictionary:
			units = up
	var src: Dictionary = {}
	for raw in (units.get("units", []) as Array):
		if raw is Dictionary and str(raw.get("id", "")) == unit_id:
			src = raw
			break
	if src.is_empty():
		src = {"id": unit_id, "name": unit_id, "category": "infantry",
			"hp": 100, "attack": 20.0, "defense": 15.0, "speed": 100.0, "range": 1}
	var u := BattleUnit.new()
	root.add_child(u)
	u.position = Vector2(x, 540.0)
	u.setup(src, {"count": count, "troop_index": 0}, cfg, ally)
	return u


func _facing_of(u: BattleUnit) -> Node2D:
	return u.get_node_or_null("Art/Facing") as Node2D


func _settle(u: BattleUnit, foe: BattleUnit, n: int) -> void:
	## 推 n 帧，让转身插值/轨迹淡出走完
	for i in range(n):
		u.tick(1.0 / 60.0, [foe])


## ---------- V 组·朝向 ----------
func _group_v(fails: Array) -> int:
	print("== V 组·朝向（_face 不再是死代码）==")
	var cfg := _cfg()
	var okc := 0

	# V1【前置】朝向容器存在，且翻转它就能整支转身
	var me := _mk(cfg, "infantry", 100, 400.0, true)
	var foe_r := _mk(cfg, "infantry", 100, 700.0, false)
	var fa := _facing_of(me)
	okc += 1
	_ok(fails, fa != null, "V1 朝向容器 Art/Facing 已建立（翻转它即可整支转身）")

	# V2【核心·原缺陷】敌人往右 → 朝右；敌人往左 → 朝左。
	#      原式 `1.0 if dir.x >= 0.0 else 1.0` 两分支相同 → 什么都不做。
	# 【测法要点·判据自纠】首跑写了「先打右边的，再把敌人搬到左边继续打」，
	# 结果右=1.00 左=1.00 → 看着像实现没生效。取证发现是**测法错**：
	# tick 的 IDLE 分支每次都 _acquire_target() 重新索敌，场上同时有
	# 两个敌人时它会重选 —— 传「一个敌人」才是干净的单变量对照。
	var me_r := _mk(cfg, "infantry", 100, 400.0, true)
	var only_r := _mk(cfg, "infantry", 100, 800.0, false)
	_settle(me_r, only_r, 60)
	var fa_r := _facing_of(me_r)
	var s_right := fa_r.scale.x if fa_r != null else 0.0
	var me_l := _mk(cfg, "infantry", 100, 400.0, true)
	var only_l := _mk(cfg, "infantry", 100, 40.0, false)
	_settle(me_l, only_l, 60)
	var fa_l := _facing_of(me_l)
	var s_left := fa_l.scale.x if fa_l != null else 0.0
	okc += 1
	_ok(fails, s_right > 0.9 and s_left < -0.9,
		"V2【核心】朝向随目标左右翻转（右=%.2f 左=%.2f）" % [s_right, s_left])

	# V3【回归·最易写错处】转身**绝不能穿过 scale.x=0**：
	#      穿过的那一帧整层压扁成一条线，视觉上是一下「闪」。
	#      同样只能用单敌人：先朝右打稳，再让**同一个敌人**翻到左边，
	#      目标不变但方向变了 —— 这才是纯粹的「转身」对照。
	var u3 := _mk(cfg, "infantry", 100, 400.0, true)
	var fa3 := _facing_of(u3)
	var f3 := _mk(cfg, "infantry", 100, 800.0, false)
	_settle(u3, f3, 20)
	f3.position.x = 40.0
	var min_abs := INF
	for i in range(150):
		u3.tick(1.0 / 60.0, [f3])
		min_abs = minf(min_abs, absf(fa3.scale.x))
	okc += 1
	_ok(fails, min_abs > 0.02,
		"V3【核心】转身过程不穿过 scale.x=0（最小绝对值 %.3f > 0.02，不闪扁）" % min_abs)

	# V4 转身不是硬切：中途必须出现**中间态**（证明是插值过程）
	var u4 := _mk(cfg, "infantry", 100, 400.0, true)
	var fa4 := _facing_of(u4)
	var r4 := _mk(cfg, "infantry", 100, 800.0, false)
	_settle(u4, r4, 40)
	var before := fa4.scale.x
	r4.position.x = 40.0
	var mid := INF
	for i in range(150):
		u4.tick(1.0 / 60.0, [r4])
		var s := fa4.scale.x
		if s < -0.9:
			break
		mid = minf(mid, absf(s))
	okc += 1
	_ok(fails, before > 0.9 and mid < 0.9,
		"V4 转身是插值过程而非硬切（起点 %.2f，中途经过 %.3f）" % [before, mid])

	# V5 战况标签（血条/名牌/兵力/士气/状态）**不在**朝向容器内
	#      —— 翻了就读不清战况，这是原设计刻意的分层
	var strays: Array = []
	if fa != null:
		for c in fa.get_children():
			if c is Label or c is ColorRect:
				strays.append(str(c.name))
	okc += 1
	_ok(fails, strays.is_empty(),
		"V5 战况标签不参与翻转（应全在 Facing 外，实测混入：%s）" % str(strays))

	# V6 地面投影**不**在朝向容器内（影子翻向是错的）
	var shadow_in := fa != null and (fa.get_node_or_null("Shadow") != null
		or fa.get_child_count() == 0 and false)
	var found_shadow := false
	if fa != null:
		for c in fa.get_children():
			if c is Polygon2D and c.get_index() == 0 and str(c.name) == "Shadow":
				found_shadow = true
	okc += 1
	_ok(fails, not shadow_in and not found_shadow,
		"V6 地面投影留在 _art 下不翻转（影子永远摊在脚下）")

	# V7 军旗在朝向容器内（旗面必须朝敌方向）
	var has_pole := false
	if fa != null:
		for c in fa.get_children():
			if c is Line2D:
				has_pole = true
				break
	okc += 1
	_ok(fails, has_pole, "V7 军旗随朝向一起翻转（旗面朝敌）")

	return okc


## ---------- T 组·冲锋轨迹 ----------
func _group_t(fails: Array) -> int:
	print("== T 组·冲锋轨迹（推进不留残影就是滑步）==")
	var cfg := _cfg()
	var okc := 0
	var me := _mk(cfg, "infantry", 100, 200.0, true)
	var far := _mk(cfg, "infantry", 100, 1400.0, false)
	var tr := me.get_node_or_null("Art/ChargeTrail") as Line2D
	okc += 1
	_ok(fails, tr != null, "T1 冲锋轨迹节点已建")

	# T2 推进时轨迹点数增长
	var n0 := tr.points.size() if tr != null else -1
	var x0 := me.position.x
	_settle(me, far, 30)
	var n1 := tr.points.size() if tr != null else -1
	okc += 1
	_ok(fails, n1 > n0 and me.position.x > x0,
		"T2 推进时轨迹记录点数增长（%d → %d，位移 %.0fpx）" % [n0, n1, me.position.x - x0])

	# T3 轨迹点数封顶（否则一条无限长的线扫过整个战场）
	# 【判据加固】只判「一次 ≤ 7」是**假绿**：封顶后第二次也必然 ≤7，
	# 单位动没动都一样。必须让单位**持续推进足够多帧**后再判，
	# 才能真正验证 remove_at(0) 的截断在工作。
	var cap := 7
	_settle(me, far, 60)                      # 再推 60 帧（约 96px）
	okc += 1
	_ok(fails, n1 <= cap and (tr.points.size() if tr != null else -1) <= cap
		and me.position.x - x0 > 90.0,
		"T3 持续推进 %.0fpx 后点数仍封顶 ≤ %d（实测 %d）"
		% [me.position.x - x0, cap, tr.points.size() if tr != null else -1])

	# T4 站定不动时不记新点（否则原地抖动也画线）
	# 【判据自纠·T4 首跑是假绿】原写法只判「点数没超过 n2+1」，
	# 而点数早已封顶在 CHARGE_TRAIL_MAX=7 —— 无论单位动不动都是 7，
	# 判据恒绿，测了个寂寞。**封顶判据必须另配一条**：
	# 先让单位真正站定（ADVANCE→ENGAGE），再判点数**一点不涨**。
	# 而「站定」不能靠「在射程内」—— 首跑 me=..., near=+40px 仍报 state=ADVANCE，
	# 因为场上的旧敌人 far 还在，_acquire_target 又把它选回去了（与 V2 同一个坑）。
	# 正解：每段用**全新的 me + 唯一的敌人**，不给场子留第二个选项。
	var me2 := _mk(cfg, "infantry", 100, 400.0, true)
	var foe2 := _mk(cfg, "infantry", 100, 1400.0, false)
	_settle(me2, foe2, 30)                      # 先推进，攒一条轨迹
	var tr2 := me2.get_node_or_null("Art/ChargeTrail") as Line2D
	okc += 1
	_ok(fails, me2.state == 1 and (tr2.points.size() if tr2 != null else 0) > 0,
		"T4a 推进态确实在记轨迹（state=%d，点数=%d）"
		% [me2.state, tr2.points.size() if tr2 != null else 0])
	foe2.position.x = me2.position.x + 40.0      # 拉进射程内 → 转入 ENGAGE
	_settle(me2, foe2, 10)
	var n2 := tr2.points.size() if tr2 != null else -1
	_settle(me2, foe2, 20)
	okc += 1
	_ok(fails, me2.state == 2 and (tr2.points.size() if tr2 != null else -1) == n2,
		"T4【核心】站定（ENGAGE）后一点不记（%d → %d）"
		% [n2, tr2.points.size() if tr2 != null else -1])

	# T5 轨迹会淡出（推进停了就该消失，不能永久拖一条线）
	# 【测法要点】必须确认单位**不在推进**：_track_advance 在 ADVANCE
	# 态每帧把 alpha 重新拉回 0.55，与淡出互相抵消 → 若还在推进，
	# alpha 恒定不降，那是设计如此，不是「淡出没生效」。
	# 【判据自纠】首跑 a_before 取在 T4b 之后（20 帧），那时 alpha 已被
	# 淡到 0.00，前后都是 0.00 → 恒假红。必须在**刚转 ENGAGE 的那一帧**取值。
	var me3 := _mk(cfg, "infantry", 100, 400.0, true)
	var foe3 := _mk(cfg, "infantry", 100, 1400.0, false)
	_settle(me3, foe3, 30)
	var tr3 := me3.get_node_or_null("Art/ChargeTrail") as Line2D
	foe3.position.x = me3.position.x + 40.0
	_settle(me3, foe3, 1)                       # 刚转 ENGAGE，此刻 alpha 仍高
	var a_before := tr3.default_color.a if tr3 != null else -1.0
	var st := me3.state
	_settle(me3, foe3, 40)
	var a_after := tr3.default_color.a if tr3 != null else -1.0
	okc += 1
	_ok(fails, st == 2 and a_before > 0.1 and a_after < a_before * 0.5,
		"T5 轨迹 alpha 会淡出（%.2f → %.2f，state=%d，转 ENGAGE 后 40 帧内基本消隐）"
		% [a_before, a_after, st])

	return okc


## ---------- D 组·阵亡倒地 ----------
func _group_d(fails: Array) -> int:
	print("== D 组·阵亡倒地（是倒下不是消失）==")
	var cfg := _cfg()
	var okc := 0

	# D1 倒地角度常量在合理范围（0.42 弧度 ≈ 24°，太大会像被砍飞）
	var me := _mk(cfg, "infantry", 100, 400.0, true)
	var foe := _mk(cfg, "infantry", 100, 800.0, false)
	_settle(me, foe, 30)
	var fa := _facing_of(me)
	okc += 1
	_ok(fails, BattleUnit.DEATH_FALL_ANGLE > 0.15
		and BattleUnit.DEATH_FALL_ANGLE < 0.9,
		"D1 倒地角度常量合理（%.2f 弧度 = %.0f°）"
		% [BattleUnit.DEATH_FALL_ANGLE,
		   rad_to_deg(BattleUnit.DEATH_FALL_ANGLE)])

	# D2 触发阵亡演出后 _facing 真的歪过去（tween 需要帧推进）
	# 【测法要点】必须先确认 me 此刻还活着（_settle 里 30 帧 tick 走的是真实
	# 战斗，foe 也在打人），否则 take_damage 会被 _dead 护栏直接 return，
	# 倒地演出根本没被触发 —— 那是测法错，不是实现没生效。
	if me.is_gone():
		_ok(fails, false, "D2【前置】_settle 后 me 竟已阵亡，无法测倒地（测法失效）")
		okc += 1
		return okc
	me.take_damage(99999.0, foe)
	for i in range(90):
		await process_frame
	var rot := absf(fa.rotation) if fa != null else 0.0
	okc += 1
	_ok(fails, rot > 0.05, "D2【核心】阵亡时朝向层歪倒（rotation=%.3f 弧度 = %.0f°）"
		% [rot, rad_to_deg(rot)])

	# D3 倒地方向与朝向自洽（朝右时往左倒 = rotation 为正），不许随机挑方向
	var u3 := _mk(cfg, "infantry", 100, 400.0, true)
	var f3 := _mk(cfg, "infantry", 100, 800.0, false)
	_settle(u3, f3, 30)
	var fa3 := _facing_of(u3)
	var pre := fa3.scale.x
	u3.take_damage(99999.0, f3)
	for i in range(90):
		await process_frame
	okc += 1
	_ok(fails, pre > 0.9 and fa3 != null and fa3.rotation > 0.0,
		"D3 倒地方向随朝向自洽（朝右 %.2f 时 rotation=%s）"
		% [pre, ("%.3f" % fa3.rotation if fa3 != null else "n/a")])

	return okc
