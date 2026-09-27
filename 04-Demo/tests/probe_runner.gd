extends Node
## 运行时探针（场景式 harness）
## 运行：godot --headless --path <工程> res://tests/probe_runner.tscn
##
## 【为什么要场景式】旧探针一律走 `--script`，而该模式下引擎**不注册 autoload**，
## 主脚本在注册之前就先被编译 → 凡是引用了 DataManager / GameState 的服务层脚本
## （achievement_service.gd 等）编译失败，退化成裸 GDScript，
## 于是 check_all() 静默什么都不做 —— 表现就是「7 项应解锁全 FAIL」。
## 那不是游戏 bug，是 harness 假阴性。改成挂在一个真实场景上跑，
## autoload 由引擎按 project.godot 正常注册，断言才有意义。
##
## 覆盖：① 成就解锁接线（#29 复核）② 治下城池治理指令（#66）
##       ③ 攻城失败守军反扑（#65）④ 原属势力收复与失地（#67）

var _fails := 0
## Windows 控制台版 Godot 的 stdout 编码在管道里常被搅乱（UTF-16 / 代码页混杂），
## 直接读终端会看到乱码。故所有断言除 print 外同步落到 res://probe_result.txt（UTF-8），
## 结果一律以该文件为准。
var _lines: Array[String] = []


func _say(text: String) -> void:
	print(text)
	_lines.append(text)


func _check(tag: String, cond: bool) -> void:
	_say("  [%s] %s" % ["OK" if cond else "FAIL", tag])
	if not cond:
		_fails += 1


func _ready() -> void:
	_say("================ 运行时探针（场景式） ================")
	_run_achievement()
	_run_ownership()
	_say("")
	_say("PROBE_RESULT=%s" % ["PASS" if _fails == 0 else "FAIL (fails=%d)" % _fails])
	var f := FileAccess.open("res://probe_result.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()
	get_tree().quit()


# ------------------------------------------------------------------
# ① 成就解锁接线
# ------------------------------------------------------------------
func _run_achievement() -> void:
	_say("")
	_say("== 成就解锁接线（#29 复核） ==")
	var defs := AchievementService.definitions()
	_check("成就表可读取（definitions > 0）", defs.size() > 0)

	GameState.gold = 2000
	GameState.battle_win_count = 1
	GameState.trades_done = 1
	GameState.player_level = 5
	GameState.fame = 60
	GameState.party = ["h1"]
	GameState.visited_cities = { "scene_2": true }

	var newly := AchievementService.check_all()
	_say("    新解锁 %d 项" % newly.size())
	for id in ["first_step", "rich_1000", "win_1", "trader", "level_5", "fame_50", "party_1"]:
		_check("解锁 " + id, GameState.is_achievement_unlocked(id))
	for id in ["rich_5000", "army_100", "win_10", "party_5", "fame_100", "travel_10"]:
		_check("未解锁 " + id + "（阈值未到）", not GameState.is_achievement_unlocked(id))
	# 幂等：已解锁项再扫一次不应重复发奖
	var again := AchievementService.check_all()
	_check("重复扫描不重复解锁（幂等）", again.is_empty())


# ------------------------------------------------------------------
# ② 治下城池：治理 / 反扑 / 收复
# ------------------------------------------------------------------
func _run_ownership() -> void:
	_say("")
	_say("== 治下城池（#65 反扑 / #66 治理 / #67 收复） ==")
	var svc := CityService.new()
	_check("治理指令表可读（3 条）", CityService.governance_orders().size() == 3)

	# 挑一座有归属的城（原属势力 > 0 才会有收复军）
	var city: Dictionary = {}
	for c in DataManager.get_table("cities"):
		if c is Dictionary and int(c.get("faction_id", 0)) > 0:
			city = c
			break
	if city.is_empty():
		_check("找到带归属的城池", false)
		return
	var cid := str(city.get("id", ""))
	var owner := int(city.get("faction_id", 0))
	_say("    测试城池：%s（%s）原属势力 %d，城防 %d" % [
		str(city.get("name", cid)), cid, owner, int(city.get("defense", 0))])

	# --- 未占有时不能治理 ---
	_check("非治下城不可治理", not bool(svc.can_govern(cid, "repair").get("ok", false)))

	# --- 攻占 → 应排期收复军 ---
	GameState.year = 190
	GameState.month = 1
	GameState.capture_city(cid, 1)
	_check("攻占后进入治下", GameState.captured_cities.has(cid))
	_check("记下原属势力", int(GameState.city_original_owner.get(cid, 0)) == owner)
	var claim: Dictionary = GameState.city_claims.get(cid, {})
	_check("原属势力已排期收复军", not claim.is_empty())
	var due := int(claim.get("due", 0))
	var now0 := GameState.month_index()
	_check("收复军到期在 2~5 个月后（实际 %d）" % (due - now0), due - now0 >= 2 and due - now0 <= 5)

	# --- 治理：修缮城防 ---
	GameState.gold = 100000
	GameState.wood = 100000
	var d0 := GameState.get_city_defense(cid)
	var r1 := svc.govern_city(cid, "repair")
	_check("修缮城防施行成功", bool(r1.get("ok", false)))
	_check("城防上升（%d → %d）" % [d0, GameState.get_city_defense(cid)],
		GameState.get_city_defense(cid) > d0)
	var r1b := svc.govern_city(cid, "repair")
	_check("同月重复施行被冷却拦截", not bool(r1b.get("ok", false)))

	# --- 治理：整饬军备（征兵额度加成） ---
	var q0 := svc.remaining_quota(cid)
	var r2 := svc.govern_city(cid, "conscription")
	_check("整饬军备施行成功", bool(r2.get("ok", false)))
	var q1 := svc.remaining_quota(cid)
	_check("征兵额度提升（%d → %d）" % [q0, q1], q1 > q0)

	# --- 治理：安抚民心 ---
	var m0 := GameState.get_city_morale(cid)
	GameState.set_city_morale(cid, 40)
	var r3 := svc.govern_city(cid, "relieve")
	_check("安抚民心施行成功", bool(r3.get("ok", false)))
	_check("民心上升（40 → %d）" % GameState.get_city_morale(cid),
		GameState.get_city_morale(cid) > 40)
	GameState.set_city_morale(cid, m0)

	# --- 攻城失败：守军反扑 ---
	GameState.troops = []
	GameState.add_troop("infantry", 100)
	GameState.gold = 1000
	var msg := CityService.apply_siege_defeat(city)
	_check("反扑造成额外减员（剩 %d/100）" % GameState.get_total_troops(),
		GameState.get_total_troops() < 100)
	_check("反扑造成辎重损失（剩 %d/1000 金）" % GameState.gold, GameState.gold < 1000)
	_check("该城进入戒备（alert=%d）" % int(GameState.city_alert.get(cid, 0)),
		int(GameState.city_alert.get(cid, 0)) > 0)
	_say("    反扑文案：%s" % msg)

	# --- 戒备抬高守军规模 ---
	var base_city := { "id": cid, "defense": int(city.get("defense", 10)) }
	var g_alert := 0
	for u in CityService.garrison_units_of(base_city):
		g_alert += int(u.get("count", 0))
	GameState.city_alert.erase(cid)
	var g_base := 0
	for u in CityService.garrison_units_of(base_city):
		g_base += int(u.get("count", 0))
	_check("戒备使守军膨胀（%d → %d）" % [g_base, g_alert], g_alert >= g_base)
	GameState.city_alert[cid] = 4

	# --- 收复军逾期 → 失地 ---
	GameState.set_city_morale(cid, 100)     # 排除叛乱干扰，单独验证收复这条失地途径
	GameState.year = 191                    # 快进一年，远超 due + 宽限
	GameState._tick_city_ownership()
	_check("逾期未救 → 城池失守", not GameState.captured_cities.has(cid))
	var restored := 0
	for c in DataManager.get_table("cities"):
		if c is Dictionary and str(c.get("id", "")) == cid:
			restored = int(c.get("faction_id", 0))
			break
	_check("失地后归属还原给原属势力（%d）" % restored, restored == owner)
	_check("失地后清空排期", not GameState.city_claims.has(cid))

	_say("")
	_say("    注：攻城/守城战的 UI 链路（world_map._do_attack / _do_defend）需真机点按验证，")
	_say("        此处只验规则层与状态层的判定。")
