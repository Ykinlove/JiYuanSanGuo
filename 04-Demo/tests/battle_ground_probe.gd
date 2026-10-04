extends SceneTree
## BattleGround（战斗场景起伏地面）行为探针
##
## 【本层要证明的核心主张】
##   战场地面不再是「一条 ColorRect」——地面线必须随 x 真实起伏，
##   且两军站在坡上时脚下高度**不同**（交战时产生高低差）。
##
## 【为什么可以独立实例化】BattleGround 只用 FastNoiseLite，不碰任何
## autoload（GameState/DataManager）→ 无头探针可直接 new 出来测。

var _checks := 0
var _fails := 0


func _fail(msg: String) -> void:
	_fails += 1
	print("FAIL " + msg)


func _ok(msg: String) -> void:
	_checks += 1
	print("[OK] " + msg)


func _init() -> void:
	var expect := 10
	var g := BattleGround.new()
	g.build(Vector2(1920.0, 1080.0))

	# ---- G1 构建后必须有数据 ----
	if g.relief_at(0.0) == 0.0 and g.relief_at(1920.0) == 0.0:
		_fail("G1 构建后全为零 → 地面仍是平板")
	else:
		_ok("G1 起伏数据已生成")

	# ---- G2【核心】地面线随 x 真实起伏（这才是「不是桌布」的证明）----
	var samples := []
	for i in range(17):
		samples.append(g.ground_y_at(120.0 + float(i) * 100.0))
	var uniq := {}
	for s in samples:
		uniq[str(s)] = true
	if uniq.size() < 8:
		_fail("G2【核心】地面线起伏太平，仅 " + str(uniq.size()) + " 种高度 → 仍是桌布")
	else:
		_ok("G2【核心】地面线随位置真实起伏 distinct=" + str(uniq.size()))

	# ---- G3【核心】起伏幅度够形成高低差（否则看不出两军站位差异）----
	var lo := 9999.0
	var hi := -9999.0
	for s in samples:
		lo = minf(lo, float(s))
		hi = maxf(hi, float(s))
	var span := hi - lo
	if span < 18.0:
		_fail("G3【核心】高低差过小 span=" + str(span) + "px（须>=18）")
	else:
		_ok("G3【核心】地面高低差 span=" + str(span) + "px")

	# ---- G4 幅度受控：不能大到把单位甩出画面 ----
	if span > BattleGround.RELIEF * 2.2:
		_fail("G4 起伏过大 span=" + str(span) + " 会让后排单位悬空")
	else:
		_ok("G4 起伏幅度受控 span=" + str(span) + " / RELIEF=" + str(BattleGround.RELIEF))

	# ---- G5 确定性：同 x 两次查询一致（可复现，便于截图取证）----
	if g.ground_y_at(777.0) != g.ground_y_at(777.0):
		_fail("G5 地面查询不确定")
	else:
		_ok("G5 地面查询确定")

	# ---- G6 边缘压平：两端不能是一堵墙（否则单位无立足处）----
	if absf(g.relief_at(0.0)) > 1.0 or absf(g.relief_at(1920.0)) > 1.0:
		_fail("G6 战场两端未压平，角色可能站到墙上")
	else:
		_ok("G6 战场两端已压平")

	# ---- G7 倾角有限幅：折面地形倾斜过大会穿模 ----
	var max_tilt := 0.0
	for i in range(33):
		var t := absf(g.tilt_at(float(i) * 60.0))
		max_tilt = maxf(max_tilt, t)
	if max_tilt > deg_to_rad(13.0):
		_fail("G7 倾角超限 max=" + str(rad_to_deg(max_tilt)) + "°")
	else:
		_ok("G7 倾角限幅有效 max=" + str(rad_to_deg(max_tilt)) + "°")

	# ---- G8 地面高度必须落在屏幕内（不能画到画面外或盖住 HUD）----
	var ok8 := true
	for s in samples:
		if float(s) < 100.0 or float(s) > 1080.0:
			ok8 = false
	if not ok8:
		_fail("G8 地面高度越出竖直范围")
	else:
		_ok("G8 地面高度在竖直范围内")

	# ---- G9 越界查询安全（相机边缘/极小视口）----
	var ok9 := true
	for x in [-500.0, 0.0, 99999.0]:
		if not is_finite(g.ground_y_at(x)) or not is_finite(g.tilt_at(x)):
			ok9 = false
	if not ok9:
		_fail("G9 越界查询产生非有限值")
	else:
		_ok("G9 越界查询安全")

	# ---- G10 极小视口不崩（headless 视口可能退化）----
	var g2 := BattleGround.new()
	g2.build(Vector2(64.0, 64.0))
	if not is_finite(g2.ground_y_at(32.0)):
		_fail("G10 极小视口下地面查询异常")
	else:
		_ok("G10 极小视口安全")

	# ---- Z1 产出量闸门 ----
	if _checks < expect - 1:
		_fail("Z1 产出量不足 checks=" + str(_checks) + " 期望>=" + str(expect - 1))
	else:
		_ok("Z1 产出量闸门通过 checks=" + str(_checks))

	print("BATTLE_GROUND_CHECKS=" + str(_checks))
	print("BATTLE_GROUND_FAILS=" + str(_fails))
	print("BATTLE_GROUND=" + ("PASS" if _fails == 0 else "FAIL"))
	quit(0 if _fails == 0 else 1)
