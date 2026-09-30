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
	_run_quests()
	_run_stat_cap()
	_run_dialogue_tokens()
	_run_npc_memory()
	_run_walk_anim()
	_run_battle_feel()
	_run_battle_hud()
	# 【必须 await】本组内部要等场景进树后取节点，不 await 的话 _ready 会继续往下走、
	# 直接写结果并 quit()，本组断言一条都不会执行（表现为"只打印标题没有断言"）。
	await _run_battle_scene_hud()
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

# ------------------------------------------------------------------
# ③ 任务并行（新任务不得覆盖旧任务）
# ------------------------------------------------------------------
func _run_quests() -> void:
	_say("")
	_say("== 任务并行（接新任务不清掉旧任务） ==")
	GameState.active_quests.clear()
	GameState.quest_progress.clear()
	GameState.completed_quests.clear()

	var r1 := QuestService.accept("mj_hj_01")    # battle 清剿黄巾 ×3
	_check("接取任务一（mj_hj_01）", bool(r1.get("ok", false)))
	var r2 := QuestService.accept("side_zhaobing")   # recruit_troop ×5
	_check("接取任务二（side_zhaobing）", bool(r2.get("ok", false)))
	_check("两个任务同时在进行中（%d 个）" % GameState.active_quests.size(),
		GameState.active_quests.size() == 2)

	# 只给任务一记战斗事件：任务二进度必须纹丝不动（这是「覆盖」bug 的直接判定）
	QuestService.record_event("battle", "enc_yellow_turban", 1)
	QuestService.record_event("battle", "enc_yellow_turban", 1)
	var p1 := QuestService.progress(QuestService.get_quest("mj_hj_01"))
	var p2 := QuestService.progress(QuestService.get_quest("side_zhaobing"))
	_check("任务一战斗进度记账（2/3）", p1.size() > 0 and int(p1[0]["cur"]) == 2)
	_check("任务二进度不被串写（0/5）", p2.size() > 0 and int(p2[0]["cur"]) == 0)

	# 再接第三个：前两个仍在
	var r3 := QuestService.accept("life_fishing")
	_check("接取任务三（life_fishing）", bool(r3.get("ok", false)))
	_check("三个任务共存（%d 个）" % GameState.active_quests.size(),
		GameState.active_quests.size() == 3)
	_check("重复接取被拦截", not bool(QuestService.accept("mj_hj_01").get("ok", false)))
	_check("任务一进度仍为 2/3",
		int(QuestService.progress(QuestService.get_quest("mj_hj_01"))[0]["cur"]) == 2)

# ------------------------------------------------------------------
# ④ 四维属性上限（掷点上限 ≠ 加点上限）
# ------------------------------------------------------------------
## 回归锁定：创角曾把「加点上限」别名成「随机掷点上限」80，而四维掷 60~80、
## 另有 10 点自由分配 —— 掷高的项一点就报「超出上限」，套预设必现。
## 两条铁律：① 掷点上限 + 可分配点数 ≤ 单项上限（否则加点必然被拦）
##          ② 单项上限 = 100，且游戏内加点必须真的拦在 100
func _run_stat_cap() -> void:
	_say("")
	_say("== 四维属性上限 ==")
	var ch := load("res://scripts/main/create_hero.gd")
	# 【GDScript 坑】脚本方法返回的 Variant 不能用 := 推断类型（会报 Cannot infer the type）
	var c: Dictionary = ch.get_script_constant_map()
	var stat_min := int(c.get("STAT_MIN", 0))
	var stat_max := int(c.get("STAT_MAX", 0))
	var pool := int(c.get("POOL", 0))
	var cap := int(c.get("STAT_CAP", 0))
	_say("    掷点 %d~%d / 可分配 %d / 单项上限 %d" % [stat_min, stat_max, pool, cap])
	_check("单项上限为 100", cap == 100)
	_check("上限取全局真源 GameState.STAT_CAP", cap == GameState.STAT_CAP)
	_check("掷点上限 + 可分配点数 ≤ 单项上限（加点不会被误拦）", stat_max + pool <= cap)
	_check("掷点上限不等于单项上限（两个数不能互相别名）", stat_max != cap)
	# 【2026-09-27 用户改需求】掷点下限 20、可分配 5 点
	_check("掷点下限为 20", stat_min == 20)
	_check("可分配点数为 5", pool == 5)

	# 派生联动：四维每一项改变，生命/精力/攻击/防御都跟着变
	var d0 := CharacterService.player_derived({"constitution": 20, "strength": 20, "intelligence": 20, "charisma": 20})
	var d1 := CharacterService.player_derived({"constitution": 80, "strength": 80, "intelligence": 80, "charisma": 80})
	_say("    派生（20 四维）→ 生命%d 精力%d 攻击%d 防御%d" % [d0["hp"], d0["mp"], d0["attack"], d0["defense"]])
	_say("    派生（80 四维）→ 生命%d 精力%d 攻击%d 防御%d" % [d1["hp"], d1["mp"], d1["attack"], d1["defense"]])
	_check("体质↑ → 生命上限↑", int(d1["hp"]) > int(d0["hp"]))
	_check("智力↑ → 精力↑", int(d1["mp"]) > int(d0["mp"]))
	_check("力量↑ → 攻击↑", int(d1["attack"]) > int(d0["attack"]))
	_check("体质/魅力↑ → 防御↑", int(d1["defense"]) > int(d0["defense"]))
	# 单维独立联动：只加体质，攻击不应变化（验证各维互不串扰）
	var only_con := CharacterService.player_derived({"constitution": 80, "strength": 20, "intelligence": 20, "charisma": 20})
	_check("单加体质不串扰攻击", int(only_con["attack"]) == int(d0["attack"]))

	# ------------------------------------------------------------------
	# 【2026-09-27 新增】天赋随掷点随机 + 资质加成随机生成：
	# 掷四维时随机抽一个个人技（不再单独选天赋），并随机掷出
	# 生命/精力/攻击/防御的先天加成（可负），随档保存、与四维联动叠加。
	# ------------------------------------------------------------------
	# _roll_stats() 只动成员变量不依赖场景树，可直接 new 出来调用
	var inst: Control = ch.new()
	inst._roll_stats()
	var skills: Array = SkillService.PERSONAL_SKILLS
	_check("掷点随机出的天赋在合法个人技集合内（id=%d）" % int(inst._talent_id),
		skills.has(int(inst._talent_id)))
	var bonus: Dictionary = inst._derived_bonus
	var brange: Dictionary = CharacterService.DERIVED_BONUS_RANGE
	var in_range := bonus.size() == 4
	for k in brange.keys():
		var r: Array = brange[k]
		var v := int(bonus.get(k, -99999))
		if v < int(r[0]) or v > int(r[1]):
			in_range = false
	_say("    资质加成 → 生命%+d 精力%+d 攻击%+d 防御%+d" % [
		int(bonus.get("hp", 0)), int(bonus.get("mp", 0)),
		int(bonus.get("attack", 0)), int(bonus.get("defense", 0))])
	_check("资质加成四键齐全且都在随机范围内", in_range)
	inst.free()

	# 加成叠加语义：基础公式吃四维实时变化，加成是先天定值
	var stats60 := {"constitution": 60, "strength": 60, "intelligence": 60, "charisma": 60}
	var no_bonus := CharacterService.player_derived(stats60, {})
	var with_bonus := CharacterService.player_derived(stats60, {"hp": 20, "mp": 10, "attack": 5, "defense": 8})
	_check("加成叠加在公式之上（生命+20 精力+10 攻击+5 防御+8）",
		int(with_bonus["hp"]) == int(no_bonus["hp"]) + 20
		and int(with_bonus["mp"]) == int(no_bonus["mp"]) + 10
		and int(with_bonus["attack"]) == int(no_bonus["attack"]) + 5
		and int(with_bonus["defense"]) == int(no_bonus["defense"]) + 8)
	var con_up := CharacterService.player_derived(
		{"constitution": 80, "strength": 60, "intelligence": 60, "charisma": 60},
		{"hp": 20, "mp": 10, "attack": 5, "defense": 8})
	_check("有加成时四维仍联动（体质 60→80 生命再 +80）", int(con_up["hp"]) == int(with_bonus["hp"]) + 80)

	# GameState 落档：加成入存档、player_derived_now 吃实时加成
	GameState.player_derived_bonus = {"hp": 12, "mp": -3, "attack": 7, "defense": -2}
	GameState.player_stats = {
		"constitution": 60, "strength": 60, "intelligence": 60, "charisma": 60,
	}
	var now := CharacterService.player_derived_now()
	_check("player_derived_now 吃 GameState 资质加成",
		int(now["hp"]) == int(no_bonus["hp"]) + 12 and int(now["mp"]) == int(no_bonus["mp"]) - 3)
	var dumped: Dictionary = GameState.to_dict()
	_check("存档带出资质加成", int(dumped.get("player_derived_bonus", {}).get("hp", 0)) == 12)
	GameState.player_derived_bonus = {"hp": 0, "mp": 0, "attack": 0, "defense": 0}

	# 游戏内加点：一路加到 100，触顶后必须拒绝
	GameState.player_stats = {
		"constitution": 60, "strength": 60, "intelligence": 60, "charisma": 60,
	}
	GameState.player_attr_points = 99
	var ok := true
	for _i in range(40):
		if not GameState.spend_attr_point("strength"):
			ok = false
			break
	_check("力量可一路加到 100（当前 %d）" % int(GameState.player_stats["strength"]),
		ok and int(GameState.player_stats["strength"]) == 100)
	_check("触顶 100 后拒绝继续加点", not GameState.spend_attr_point("strength"))
	_check("触顶后属性点未被扣掉（剩 %d）" % GameState.player_attr_points,
		GameState.player_attr_points == 99 - 40)


# ------------------------------------------------------------------
# ⑤ 台词令牌替换（2026-09-29 P2）
#    剧本此前没有任何变量插值，旁白无法打印国号/姓名/年份。
#    本组断言：白名单令牌确实在显示层被替换，且有回退值、不误伤未知令牌。
# ------------------------------------------------------------------
func _run_dialogue_tokens() -> void:
	_say("")
	_say("== 台词令牌替换（dialogue_ui._resolve_tokens） ==")
	# 注意：不能用 `var ui := load(...).new()` —— load() 返回 Variant，`:=` 推断失败
	# （「Cannot infer the type」会让整个探针脚本解析失败、场景空跑不退出）。
	# DialogueUI 有 class_name，直接按类型 new，编译期也能查到 _resolve_tokens。
	var ui: DialogueUI = DialogueUI.new()

	# 造一份「已自立」的存档状态
	var city0: Dictionary = {}
	for c in DataManager.get_table("cities"):
		if c is Dictionary:
			city0 = c
			break
	var cap_name := str(city0.get("name", ""))
	GameState.player_name = "赵云"
	GameState.self_rule_name = "唐"
	GameState.self_rule_city = str(city0.get("id", ""))
	GameState.year = 210

	_check("{guohao} → 国号（%s）" % ui._resolve_tokens("{guohao} 元年"),
		ui._resolve_tokens("{guohao} 元年") == "唐 元年")
	_check("{name} → 主角名", ui._resolve_tokens("壮士 {name} 到此一游") == "壮士 赵云 到此一游")
	# 玩家尚未取名（GameState 初始占位「无名」）时不能直接念出来
	GameState.player_name = "无名"
	_check("默认占位名「无名」时 {name} 回退「壮士」", ui._resolve_tokens("{name}，走好") == "壮士，走好")
	GameState.player_name = "赵云"
	_check("{year} → 当前年份", ui._resolve_tokens("公元 {year} 年") == "公元 210 年")
	_check("{capital} → 都城名（%s）" % cap_name,
		ui._resolve_tokens("定都 {capital}") == "定都 " + cap_name)
	_check("无令牌文本原样返回", ui._resolve_tokens("新朝的钟声响了九下。") == "新朝的钟声响了九下。")
	_check("未知令牌原样保留（不吞字、不报错）",
		ui._resolve_tokens("{unknown} 元年") == "{unknown} 元年")

	# 回退值：未自立 / 未定都时不能显示空白
	GameState.self_rule_name = ""
	GameState.self_rule_city = ""
	_check("未自立时 {guohao} 回退「新朝」", ui._resolve_tokens("{guohao} 元年") == "新朝 元年")
	_check("未定都时 {capital} 回退「都城」", ui._resolve_tokens("定都 {capital}") == "定都 都城")

	# 剧本实测：称帝线确实埋了国号令牌
	var emp := {}
	for d in DataManager.get_table("dialogues"):
		if d is Dictionary and str(d.get("id", "")) == "mj_finale_emperor":
			emp = d
			break
	var has_guohao := false
	for l in emp.get("lines", []):
		if "{guohao}" in str(l):
			has_guohao = true
	_check("称帝线首拍埋了 {guohao} 令牌", has_guohao)
	ui.free()


# ------------------------------------------------------------------
# ⑥ NPC 对话记忆性（2026-09-29 用户反馈）
#    旧行为：接了任务再找他，仍从头播一遍初见台词、再让玩家重选一遍选项。
#    正确分流：可交付 → <root>_turnin；进行中 → <root>_pending；都没写 → 退回 root。
# ------------------------------------------------------------------
func _run_npc_memory() -> void:
	_say("")
	_say("== NPC 对话记忆性（DialogueService 分流） ==")
	var root := "zhurong_intro"
	var npc := { "dialogue_root": root }
	var qid := "side_zhurong"

	# 清场，保证本组断言可重复执行
	GameState.active_quests.erase(qid)
	GameState.completed_quests.erase(qid)

	_check("未接任务时走初见节点（%s）" % DialogueService.entry_node(npc),
		DialogueService.entry_node(npc) == root)

	var ar := QuestService.accept(qid)
	_check("接取「祝融之请」成功", bool(ar.get("ok", false)))
	_check("进行中 → _pending 节点（%s）" % DialogueService.entry_node(npc),
		DialogueService.entry_node(npc) == root + "_pending")

	# NPC 嘴里必须念出「具体目标」，而不是「你的任务怎么样了」
	var goal := DialogueService.quest_goal_text(DialogueService.focus_quest(root + "_pending"))
	_check("能念出具体目标（%s）" % goal, goal.find("蛮族战士") >= 0)

	# 打一场蛮族战士 → 目标达成
	QuestService.record_event("battle", "enc_tribal_warrior", 1)
	_check("达成后 → _turnin 节点（%s）" % DialogueService.entry_node(npc),
		DialogueService.entry_node(npc) == root + "_turnin")

	# 显示层替换：{quest_goal} 必须真的变成目标描述
	var ui: DialogueUI = DialogueUI.new()
	ui._current_id = root + "_turnin"
	var line := ui._resolve_tokens("{quest_goal}——办成了？")
	_check("台词里的 {quest_goal} 已替换（%s）" % line, line.find("蛮族战士") >= 0)
	ui.free()

	var msg := DialogueService.turn_in_all(root + "_turnin")
	_check("turn_in_all 交付成功（%s）" % msg, not msg.is_empty())
	_check("交付后回到初见节点，才能开下一轮", DialogueService.entry_node(npc) == root)
	_check("任务已进完成表", GameState.completed_quests.has(qid))

	# 覆盖度：凡是 npcs.json 里挂了 dialogue_root、且会发任务的 NPC 都得有记忆节点，
	# 少一个就会退化回「每次从头播」的旧行为。
	var missing := PackedStringArray()
	var checked := 0
	for n in DataManager.get_table("npcs"):
		if not (n is Dictionary):
			continue
		var rid := str(n.get("dialogue_root", ""))
		if rid.is_empty():
			continue
		if DialogueService.quests_of_root(rid).is_empty():
			continue
		checked += 1
		for suf in [DialogueService.SUF_PENDING, DialogueService.SUF_TURNIN]:
			if not DialogueService.node_exists(rid + suf):
				missing.append(rid + suf)
	_check("发任务 NPC 全覆盖记忆节点（%d 人，缺 %d）" % [checked, missing.size()],
		checked > 0 and missing.is_empty())
	if not missing.is_empty():
		_say("     缺：%s" % ", ".join(missing))


# ------------------------------------------------------------------
# ⑦ 角色行走动画（2026-09-29 用户反馈）
#    「立绘图片在屏幕上飘来飘去，不真实」——角色形象是单张 AI 立绘，
#    此前只有 1.8~3.4px 的上下浮动，等于没有步伐。WalkAnim 用
#    踏步起伏 + 左右摇摆 + 落地挤压 + 静止呼吸四个动作演出走路，
#    并按**宿主实际位移**驱动相位（玩家摇杆与 NPC 游荡共用一套）。
# ------------------------------------------------------------------
func _run_walk_anim() -> void:
	_say("")
	_say("== 角色行走动画（WalkAnim） ==")

	var host := Node2D.new()
	host.name = "WAHost"
	add_child(host)
	# 模拟 NPC 立绘：本体自带缩放到 56px 高（sc 远小于 1）
	var body := Sprite2D.new()
	body.name = "WABody"
	body.scale = Vector2(0.073, 0.073)
	host.add_child(body)

	var wa := WalkAnim.attach(host, body)
	_check("WalkAnim 可挂到角色上", wa != null)
	if wa == null:
		return

	# ① 静止：只有极轻微呼吸，不应有明显起伏
	wa._process(0.1)
	_check("静止时仅呼吸起伏（%0.2f）" % wa.bob_offset, absf(wa.bob_offset) <= 1.0)

	# ② 走动：模拟 250px/s，走 3 秒，必须产生可观的踏步起伏
	var max_bob := 0.0
	for _i in range(30):
		host.position.x += 25.0        ## 250px/s × 0.1s
		wa._process(0.1)
		max_bob = maxf(max_bob, absf(wa.bob_offset))
	_check("走动时产生踏步起伏（峰值 %0.2f px）" % max_bob, max_bob > 1.5)
	_check("速度被正确读出（%0.0f px/s）" % wa.move_speed, wa.move_speed > 100.0)

	# ③ 最容易踩的回归点：动画绝不能覆盖立绘本体自带的缩放。
	#    直接写 scale=(1,1) 会把 56px 的立绘放大十几倍，角色瞬间撑爆屏幕。
	_check("立绘缩放未被动画覆盖（%0.4f ≈ 0.073）" % body.scale.x,
		absf(body.scale.x - 0.073) < 0.01)

	# ④ 站定后收步归零（否则角色会停在半空中）
	for _i in range(40):
		wa._process(0.1)
	_check("停步后起伏归零（%0.2f）" % wa.bob_offset, absf(wa.bob_offset) < 1.0)

	# ⑤ 步频封顶：疾跑 400px/s 时步幅自动拉大，不能抖成抽搐
	var prev_a := 0.0
	var rising := false
	var peaks := 0
	for _i in range(100):
		host.position.x += 4.0         ## 400px/s × 0.01s
		wa._process(0.01)
		var a := absf(wa.bob_offset)
		if a > prev_a:
			rising = true
		elif rising and a < prev_a:
			peaks += 1
			rising = false
		prev_a = a
	_check("疾跑步频受上限约束（%d 步/秒，上限 3.2）" % peaks, peaks >= 2 and peaks <= 5)

	# ⑥ NPC 形象：人物本体必须独立成 Body 容器，
	#    否则脚下的投影与名牌会跟着一起晃，看着像整块贴图在抖
	var art := CityInteriorArt.build_npc("测试居民", "")
	var art_body := art.get_node_or_null("Body") as Node2D
	_check("NPC 人物本体独立成 Body 容器", art_body != null)
	if art_body != null:
		var lbl_in_body := false
		for c in art_body.get_children():
			if c is Label:
				lbl_in_body = true
		_check("名牌不在 Body 内（不会跟着晃）", not lbl_in_body)
		_check("Body 内确实有人物形象", art_body.get_child_count() > 0)
	art.free()

	host.free()


# ------------------------------------------------------------------
# ⑧ 战斗演出（2026-09-30 用户反馈「战斗页面太生硬死板」）
#    顿帧/震屏只解决手感，玩家**看不见**发生了什么。本组断言三件事：
#    打多少看得见（飘字）/ 谁在打看得见（前突）/ 部队怎么没的（渐隐）。
# ------------------------------------------------------------------
func _run_battle_feel() -> void:
	_say("")
	_say("== 战斗演出（飘字 / 前突 / 击退 / 阵亡渐隐） ==")

	# ① 演出参数必须真的来自 combat.json（写死在场景里就又变成"四层纪律"破窗）
	var cfg := DataManager.get_record("combat", "root")
	var feel: Dictionary = cfg.get("feel", {})
	_check("combat.json 有 feel 段", not feel.is_empty())
	_check("飘字上浮距离来自配置（%0.0f）" % CombatFeelService.damage_number_rise(),
		CombatFeelService.damage_number_rise() > 0.0)
	_check("前突速度来自配置（%0.0f）" % CombatFeelService.lunge_speed(),
		CombatFeelService.lunge_speed() > 0.0)
	_check("击退速度来自配置（%0.0f）" % CombatFeelService.knock_speed(),
		CombatFeelService.knock_speed() > 0.0)
	_check("阵亡渐隐时长来自配置（%0.2f）" % CombatFeelService.death_fade(),
		CombatFeelService.death_fade() > 0.0)

	# ② 伤害飘字：能生成、压在最上层、且会自行回收
	var holder := Node2D.new()
	add_child(holder)
	DamageNumber.pop_damage(holder, Vector2(100.0, 100.0), 42.0, false, false)
	var dn := holder.get_node_or_null("DamageNumber")
	_check("伤害飘字已生成", dn != null)
	if dn != null:
		_check("飘字压在最上层（z_index=%d）" % (dn as Node2D).z_index,
			(dn as Node2D).z_index >= 100)
	_check("飘字挂在战场层（跟随世界坐标）", holder.get_child_count() > 0)

	# ③ 部队的出手前突 / 受击击退 / 阵亡渐隐
	var u := BattleUnit.new()
	add_child(u)
	u.setup({"id": "u_probe", "name": "探针部队", "category": "infantry",
			"hp": 200.0, "attack": 20.0, "defense": 15.0, "speed": 100.0, "range": 1},
		{"count": 100, "troop_index": 0, "attack_mult": 0.0, "defense_mult": 0.0},
		cfg, true)
	u.position = Vector2(400.0, 400.0)

	var v := BattleUnit.new()
	add_child(v)
	v.setup({"id": "v_probe", "name": "探针敌队", "category": "infantry",
			"hp": 200.0, "attack": 18.0, "defense": 12.0, "speed": 100.0, "range": 1},
		{"count": 100, "troop_index": 0, "attack_mult": 0.0, "defense_mult": 0.0},
		cfg, false)
	v.position = Vector2(520.0, 400.0)

	# 出手前突（视觉偏移，不动战斗坐标）
	var pos_before := v.position
	u._lunge_toward(v)
	for _i in range(6):
		u._apply_impulse(1.0 / 60.0)
	_check("出手产生前突视觉偏移（%0.1f px）" % u._vis_off.length(), u._vis_off.length() > 2.0)

	# 受击击退：应沿「攻击者 → 自己」方向退开（友军在左，故向右退）
	v.take_damage(30.0, u)
	for _i in range(6):
		v._apply_impulse(1.0 / 60.0)
	_check("受击产生击退视觉偏移（%0.1f px）" % v._vis_off.length(), v._vis_off.length() > 2.0)
	_check("击退方向背离攻击者（x=%0.1f）" % v._vis_off.x, v._vis_off.x > 0.0)

	# 【关键回归点】演出绝不能污染战斗坐标：position 是 AI 推进/接战距离的判据，
	# 被演出改动会导致「连打几次方阵就飘离战位」。
	for _i in range(120):
		v._apply_impulse(1.0 / 60.0)
	_check("战斗坐标未被演出改动（Δ=%0.2f）" % v.position.distance_to(pos_before),
		v.position.distance_to(pos_before) < 0.001)
	# 弹簧回中：反复触发不累积漂移
	_check("视觉偏移会回中（%0.2f）" % v._vis_off.length(), v._vis_off.length() < 1.0)

	# 重创之下士气先崩：先进"溃散"而不是直接消失（兵败如山倒，正确的战场逻辑）
	v.take_damage(999.0, u)
	_check("士气崩塌先进溃散而非直接阵亡", v.is_routed())

	# 阵亡：不再是 visible=false 瞬间消失，而是渐隐后再离场。
	# 这里直接触发阵亡——上面的溃散分支会 return，走不到歼灭。
	v._die(false)
	_check("阵亡判定生效", v.is_gone())
	_check("阵亡不再瞬间消失（渐隐中仍可见）", v.visible)

	u.free()
	await get_tree().process_frame
	if is_instance_valid(v):
		v.free()
	holder.free()


# ------------------------------------------------------------------
# ⑨ 战斗 HUD（2026-09-30 第二轮优化：血条平滑 / 掉血残影 / 残血警示 / 连斩）
#    血条原来是「value = 当前值」瞬间跳格，扣血涨怒都像啪一下切过去。
#    本组断言三件事：参数真的来自 combat.json、逼近算法本身正确（帧率无关
#    且不过冲）、演出强度区间自洽（警示不能浓到挡住画面）。
# ------------------------------------------------------------------
func _run_battle_hud() -> void:
	_say("")
	_say("== 战斗 HUD（血条平滑 / 残影 / 残血警示 / 连斩） ==")

	# ① 参数来自配置——写死在场景里就又是四层纪律破窗
	_check("血条逼近速率来自配置（hp=%0.1f）" % CombatFeelService.bar_smooth("hp"),
		CombatFeelService.bar_smooth("hp") > 0.0)
	_check("士气条逼近速率来自配置（%0.1f）" % CombatFeelService.bar_smooth("morale"),
		CombatFeelService.bar_smooth("morale") > 0.0)
	_check("怒气条逼近速率来自配置（%0.1f）" % CombatFeelService.bar_smooth("rage"),
		CombatFeelService.bar_smooth("rage") > 0.0)
	_check("残影停留来自配置（%0.2f s）" % CombatFeelService.ghost_hold(),
		CombatFeelService.ghost_hold() > 0.0)
	_check("残血阈值来自配置（%0.2f）" % CombatFeelService.low_hp_ratio(),
		CombatFeelService.low_hp_ratio() > 0.0 and CombatFeelService.low_hp_ratio() < 1.0)
	_check("连斩窗口来自配置（%0.1f s）" % CombatFeelService.combo_window(),
		CombatFeelService.combo_window() > 0.0)
	_check("连斩至少 2 连才显示（%d）" % CombatFeelService.combo_min(),
		CombatFeelService.combo_min() >= 2)

	# ② 逼近算法：单调下行、不过冲、能收敛
	var cur := 100.0
	var bad := false
	for _i in range(300):
		var nxt := CombatFeelService.approach(cur, 0.0, 1.0 / 60.0, 9.0)
		if nxt < 0.0 or nxt > cur:
			bad = true
		cur = nxt
	_check("逼近单调且不过冲（5s 后剩 %0.2f）" % cur, (not bad) and cur < 1.0)

	# ③ 【关键】帧率无关：1 次 dt=0.1 与 10 次 dt=0.01 必须几乎一样。
	#    若写成 lerp(cur,target,0.2)，120Hz 下血条会快一倍、掉帧时又慢得像没动。
	var a := CombatFeelService.approach(100.0, 0.0, 0.1, 9.0)
	var b := 100.0
	for _i in range(10):
		b = CombatFeelService.approach(b, 0.0, 0.01, 9.0)
	_check("帧率无关（0.1s 一次 %0.3f ≈ 0.01s×10 %0.3f）" % [a, b], absf(a - b) < 0.5)

	# ④ 演出强度区间自洽：警示再急也不能糊住画面
	_check("残血脉冲频率区间自洽（%0.1f~%0.1f Hz）" % [
			CombatFeelService.low_hp_hz_min(), CombatFeelService.low_hp_hz_max()],
		CombatFeelService.low_hp_hz_min() <= CombatFeelService.low_hp_hz_max())
	_check("残血透明度区间自洽（%0.2f~%0.2f）" % [
			CombatFeelService.low_hp_alpha_min(), CombatFeelService.low_hp_alpha_max()],
		CombatFeelService.low_hp_alpha_min() <= CombatFeelService.low_hp_alpha_max())
	_check("残血警示足够淡（峰值 %0.2f ≤ 0.35）" % CombatFeelService.low_hp_alpha_max(),
		CombatFeelService.low_hp_alpha_max() <= 0.35)


# ------------------------------------------------------------------
# ⑩ 战斗场景 HUD 实件（真实例化 battle_scene.tscn）
#    ⑨ 只验了参数与算法，"残影条到底有没有建出来、有没有被画在血条下面、
#    连斩到底会不会显示"必须真把场景跑起来才知道。本组直接实例化战斗场景验证。
# ------------------------------------------------------------------
func _run_battle_scene_hud() -> void:
	_say("")
	_say("== 战斗场景 HUD 实件（残影条 / 警示层 / 连斩） ==")

	var scene := load("res://scenes/battle/battle_scene.tscn") as PackedScene
	if scene == null:
		_check("战斗场景可加载", false)
		return
	var bs := scene.instantiate()
	add_child(bs)
	# _ready 里 _build_hud_extras() 排在 await _setup_battle() 之前，两帧足够
	await get_tree().process_frame
	await get_tree().process_frame

	_check("残影条已建", bs._hp_ghost_bar != null)
	_check("残影条画在血条下层（index %d < %d）" % [
			bs._hp_ghost_bar.get_index(), bs._hp_bar.get_index()],
		bs._hp_ghost_bar.get_index() < bs._hp_bar.get_index())
	_check("残影条与血条同量程（%0.0f）" % bs._hp_ghost_bar.max_value,
		absf(bs._hp_ghost_bar.max_value - bs._hp_bar.max_value) < 0.001)
	_check("残血警示层已建且初始隐藏", bs._low_hp_veil != null and not bs._low_hp_veil.visible)
	_check("连斩标签已建且初始隐藏", bs._combo_label != null and not bs._combo_label.visible)
	_check("动作按钮冷却遮罩已建（%d 个）" % bs._cd_veils.size(), bs._cd_veils.size() == 2)
	_check("敌方血条量程已统一到 0~100（%0.0f）" % bs._enemy_hp_bar.max_value,
		absf(bs._enemy_hp_bar.max_value - 100.0) < 0.001)

	# ① 血条平滑：目标值骤降后，控件值应"追在后面"而不是瞬间到位
	bs._player_hp = bs._player_hp_max * 0.5
	bs._update_bars()
	bs._tick_bars(1.0 / 60.0)
	_check("掉血后血条追在后面（控件 %0.1f > 目标 %0.1f）" % [bs._hp_bar.value, bs._target_hp],
		bs._hp_bar.value > bs._target_hp + 1.0)
	_check("残影条此刻仍领先血条（露出掉血量）" ,
		bs._hp_ghost_bar.value > bs._hp_bar.value)
	# 多跑几帧必须收敛到目标
	for _i in range(120):
		bs._tick_bars(1.0 / 60.0)
	_check("2s 后血条收敛到目标（%0.2f ≈ %0.1f）" % [bs._hp_bar.value, bs._target_hp],
		absf(bs._hp_bar.value - bs._target_hp) < 1.0)
	_check("残影条最终追平血条（%0.2f）" % bs._hp_ghost_bar.value,
		absf(bs._hp_ghost_bar.value - bs._hp_bar.value) < 1.0)

	# ② 残血警示：只在「真的残血 + 正在打」时亮
	bs._phase = 1                       ## Phase.FIGHTING
	bs._player_hp = bs._player_hp_max * 0.9
	bs._tick_bars(1.0 / 60.0)
	_check("血量充足时不闪红", not bs._low_hp_veil.visible)
	bs._player_hp = bs._player_hp_max * 0.15
	bs._tick_bars(1.0 / 60.0)
	_check("残血时全屏警示亮起（a=%0.3f）" % bs._low_hp_veil.modulate.a,
		bs._low_hp_veil.visible and bs._low_hp_veil.modulate.a > 0.0)
	bs._phase = 2                       ## Phase.RESULT
	bs._tick_bars(1.0 / 60.0)
	_check("结算阶段不再闪红", not bs._low_hp_veil.visible)

	# ③ 连斩：不足门槛不显示，够门槛才出，且会随时间断掉
	bs._phase = 1
	bs._combo = 0
	bs._bump_combo()
	_check("1 连不显示（门槛 %d）" % CombatFeelService.combo_min(), not bs._combo_label.visible)
	bs._bump_combo()
	_check("2 连起显示（%s）" % bs._combo_label.text, bs._combo_label.visible)
	var w := CombatFeelService.combo_window()
	for _i in range(int(w * 60.0) + 10):
		bs._tick_combo(1.0 / 60.0)
	_check("超过窗口后连斩断掉", not bs._combo_label.visible and bs._combo == 0)

	# ④ 转场件：开场黑幕 / 血条数值文本
	var curtain := bs.get_node_or_null("UI/SceneCurtain")
	_check("开场黑幕已建（正在淡出）", curtain != null)
	if curtain != null:
		_check("黑幕不吞点击", curtain.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	_check("血条数值文本已建", bs._hp_text != null)
	_check("敌血条数值文本已建", bs._enemy_text != null)
	_check("血条改显绝对值（关掉百分比）", not bs._hp_bar.show_percentage)
	bs._player_hp = 55.0
	bs._tick_bars(1.0 / 60.0)
	_check("血条数值跟随真实血量（%s）" % bs._hp_text.text,
		bs._hp_text.text.begins_with("55"))
	bs._enemy_alive_n = 3
	bs._enemy_total_n = 8
	bs._tick_bars(1.0 / 60.0)
	_check("敌军计数可读（%s）" % bs._enemy_text.text, bs._enemy_text.text.contains("3 / 8"))

	# ⑤ 开战横幅
	bs._banner("交　战", "黄巾残党")
	var banner := bs.get_node_or_null("UI/BattleBanner")
	_check("开战横幅已生成", banner != null)
	if banner != null:
		_check("横幅弹出中（scale %0.2f > 1）" % banner.scale.x, banner.scale.x > 1.0)

	# ⑥ 结算转场：慢镜 + 渐暗（渐暗层必须在最底层，否则会盖住结算面板）
	bs._play_finish_transition()
	_check("结算慢镜生效（time_scale %0.2f < 1）" % Engine.time_scale, Engine.time_scale < 1.0)
	var veil := bs.get_node_or_null("UI/FinishVeil")
	_check("结算渐暗层已建且压在最底层", veil != null and veil.get_index() == 0)
	Engine.time_scale = 1.0     ## 手动还原：别把慢镜带出探针污染后续断言

	# ⑦ 镜头语言 / 战场氛围 / BGM 战况三态（结构性，不依赖 tween 时序）
	_check("战斗相机已建（Camera2D）", bs._cam != null and bs._cam is Camera2D)
	_check("镜头推近函数可调用", bs.has_method("_cam_punch"))
	_check("击杀特写回调已挂", bs.has_method("_on_unit_removed"))
	var atmos_node := bs.get_node_or_null("Atmos")
	_check("战场氛围层已建（Atmos）", atmos_node != null)
	var player_node := bs.get_node_or_null("Player")
	if atmos_node != null and player_node != null:
		_check("氛围层位于单位之下（Atmos index %d < Player %d）" % [
				atmos_node.get_index(), player_node.get_index()],
			atmos_node.get_index() < player_node.get_index())
	_check("BGM 三态路径已配置",
		CombatFeelService.bgm_prepare() != "" and CombatFeelService.bgm_fight() != "" and CombatFeelService.bgm_win() != "")

	bs.free()
