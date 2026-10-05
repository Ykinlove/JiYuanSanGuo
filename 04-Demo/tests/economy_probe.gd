extends Node
## 物品经济探针（由 _verify_item_economy.py 驱动）
## 运行：godot --headless --path<工程> res://tests/economy_probe.tscn
##
## 【为什么必须真跑，不能只静态查表】
## 玩家报告「物品的获取或者任务奖励没有落实」。静态判据只能证明
## 「配置里有这些 id」「代码里有这几行字」，证明不了**钱扣了、料扣了、东西到手了**。
## 本探针把四条途径各跑一遍真实交易，逐项断言背包/金币/日计数的净变化。
##
## 每条用例都做「操作前快照 → 操作 → 操作后断言」，
## 断言的是**差值**而不是绝对值 —— 绝对值会被上一条用例的残留污染。
##
## 输出落 res://economy_probe_result.txt（Windows 控制台编码兜底）。

var _lines: Array[String] = []
var _fails: int = 0


func _say(t: String) -> void:
	print(t)
	_lines.append(t)


func _check(tag: String, ok: bool, detail: String) -> void:
	if ok:
		_say("[PASS] " + tag + "  " + detail)
	else:
		_fails += 1
		_say("[FAIL] " + tag + "  " + detail)


func _ready() -> void:
	# 干净起点：清空背包与日计数，避免继承上一局的存量
	GameState.inventory = {}
	GameState.gold = 100000
	GameState.food = 500
	GameState.iron = 500
	GameState.player_level = 30
	GameState.craft_today = {}
	GameState.exchange_today = {}
	GameState.ad_today = {}
	GameState.ad_claimed = {}

	_probe_data_closure()
	_probe_exchange()
	_probe_mall()
	_probe_craft()
	_probe_ad()
	_probe_quest_items()
	_probe_daily_limit()
	_probe_save_roundtrip()

	_say("FAILS=" + str(_fails))
	var f := FileAccess.open("res://economy_probe_result.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()
	# 不退出会被 timeout 杀，且杀掉后可能残留进程占着 .godot 与存档写锁
	# （MEMORY 铁律：Windows 上 Godot 被 timeout 杀会留僵尸进程）
	get_tree().quit()


## ---------- A. 数据闭合 ----------
func _probe_data_closure() -> void:
	# A1 三张途径表都非空
	var ex: Array = ItemEconomyService.exchange_goods()
	var ma: Array = ItemEconomyService.mall_goods()
	var ad: Array = ItemEconomyService.ad_tiers()
	_check("A1a 集市有货", ex.size() > 0, "goods=" + str(ex.size()))
	_check("A1b 商城有货", ma.size() > 0, "goods=" + str(ma.size()))
	_check("A1c 看广告有档位", ad.size() > 0, "tiers=" + str(ad.size()))

	# A2 每个 id 都能在 items6 查到（配错的 id 在这里暴露）
	var bad_ex := 0
	for g in ex:
		if DataManager.get_item6(int(g["item_id"])).is_empty():
			bad_ex += 1
	_check("A2a 集市全部 id 可解析", bad_ex == 0, "bad=" + str(bad_ex))
	var bad_ma := 0
	for g in ma:
		if DataManager.get_item6(int(g["item_id"])).is_empty():
			bad_ma += 1
	_check("A2b 商城全部 id 可解析", bad_ma == 0, "bad=" + str(bad_ma))
	var bad_ad := 0
	for t in ad:
		for m in t.get("items", []):
			if DataManager.get_item6(int(m["item_id"])).is_empty():
				bad_ad += 1
	_check("A2c 广告全部 id 可解析", bad_ad == 0, "bad=" + str(bad_ad))

	# A3 ★ 商城不得含材料/工具（cat 1/8）—— 定价体系红线
	var wrong_cat := 0
	for g in ma:
		var rec := DataManager.get_item6(int(g["item_id"]))
		var cm := int(rec.get("cat_major", 0))
		if cm == 1 or cm == 8:
			wrong_cat += 1
	_check("A3★ 商城不含材料/工具（否则价格体系崩）", wrong_cat == 0, "violations=" + str(wrong_cat))

	# A4 ★ 广告不得产出装备/宝物（cat 2~7）—— 稀缺性红线
	var ad_equip := 0
	for t in ad:
		for m in t.get("items", []):
			var rec := DataManager.get_item6(int(m["item_id"]))
			var cm := int(rec.get("cat_major", 0))
			if cm >= 2:
				ad_equip += 1
	_check("A4★ 看广告不产装备/宝物（防刷核心）", ad_equip == 0, "violations=" + str(ad_equip))

	# A5 配方清单非空且都真的可锻造
	var cr: Array = CraftService.craftable_list()
	_check("A5a 锻造清单非空", cr.size() > 0, "count=" + str(cr.size()))
	var bad_cr := 0
	for r in cr:
		if not CraftService.is_craftable(DataManager.get_item6(int(r["item_id"]))):
			bad_cr += 1
	_check("A5b 清单内每件都带 craft_flag 与配方", bad_cr == 0, "bad=" + str(bad_cr))


## ---------- B. 集市（金币兑换） ----------
func _probe_exchange() -> void:
	var goods: Array = ItemEconomyService.exchange_goods()
	if goods.is_empty():
		_check("B0 集市有货可测", false, "goods 为空")
		return
	var g0: Dictionary = goods[0]
	var iid := int(g0["item_id"])
	var price := int(g0["price"])

	var gold0 := GameState.gold
	var cnt0 := GameState.get_item_count(str(iid))
	var r := ItemEconomyService.exchange(iid)
	var ok := bool(r.get("ok", false))
	_check("B1 兑换成功", ok, str(r.get("msg", "")))
	_check("B2 金币精确扣减（不多不少）",
		GameState.gold == gold0 - price,
		"期望 " + str(gold0 - price) + " 实得 " + str(GameState.gold))
	_check("B3 物品入背包 +1",
		GameState.get_item_count(str(iid)) == cnt0 + 1,
		"期望 " + str(cnt0 + 1) + " 实得 " + str(GameState.get_item_count(str(iid))))
	_check("B4 今日次数 +1",
		ItemEconomyService.exchange_used_today() == 1,
		"used=" + str(ItemEconomyService.exchange_used_today()))

	# B5 金不足必须拒
	GameState.gold = 0
	var g2 := ItemEconomyService.can_exchange(iid)
	_check("B5 金不足时拒绝兑换", not bool(g2["ok"]), str(g2["reason"]))
	var cnt_before := GameState.get_item_count(str(iid))
	ItemEconomyService.exchange(iid)
	_check("B5b 拒绝时物品未入账（不凭空发货）",
		GameState.get_item_count(str(iid)) == cnt_before,
		"count=" + str(GameState.get_item_count(str(iid))))
	GameState.gold = 100000


## ---------- C. 商城 ----------
func _probe_mall() -> void:
	var goods: Array = ItemEconomyService.mall_goods()
	if goods.is_empty():
		_check("C0 商城有货可测", false, "goods 为空")
		return
	var g0: Dictionary = goods[0]
	var iid := int(g0["item_id"])
	var price := int(g0["price"])
	var gold0 := GameState.gold
	var cnt0 := GameState.get_item_count(str(iid))
	var r := ItemEconomyService.buy_mall(iid)
	_check("C1 购买成功", bool(r.get("ok", false)), str(r.get("msg", "")))
	_check("C2 金币精确扣减",
		GameState.gold == gold0 - price,
		"期望 " + str(gold0 - price) + " 实得 " + str(GameState.gold))
	_check("C3 物品入背包 +1",
		GameState.get_item_count(str(iid)) == cnt0 + 1,
		"count=" + str(GameState.get_item_count(str(iid))))
	# C4 商城不写日计数（不设每日限次）
	_check("C4 商城不占每日额度",
		ItemEconomyService.exchange_used_today() == 1,
		"exchange_used=" + str(ItemEconomyService.exchange_used_today()))


## ---------- D. 锻造 ----------
func _probe_craft() -> void:
	# 找一件配方最短的装备：材料好备
	var best_id := 0
	var best_n := 999
	for r in CraftService.craftable_list():
		var n: int = (r["materials"] as Array).size()
		var cat := int(r.get("cat", 0))
		if cat >= 2 and cat <= 5 and n < best_n:
			best_n = n
			best_id = int(r["item_id"])
	if best_id <= 0:
		_check("D0 存在可锻造装备", false, "没找到 cat2~5 的配方")
		return
	# 按配方实际需求量备料
	var rec := CraftService.recipe_of(best_id)
	var gold_need := int(rec["gold"])
	for m in rec["materials"]:
		GameState.add_item(str(int(m["item_id"])), int(m["count"]))
	# 备料后不该有多余
	var over := 0
	for m in rec["materials"]:
		if GameState.get_item_count(str(int(m["item_id"]))) != int(m["count"]):
			over += 1
	_check("D1 备料到位（持有量==需求量）", over == 0, "mismatch=" + str(over))

	var gold0 := GameState.gold
	var gate := CraftService.can_craft(best_id)
	_check("D2 材料齐+钱够时可锻造", bool(gate["ok"]), str(gate["reason"]))

	var r := CraftService.craft(best_id)
	_check("D3 锻造成功", bool(r.get("ok", false)), str(r.get("msg", "")))
	_check("D4 工费精确扣减", GameState.gold == gold0 - gold_need,
		"期望 " + str(gold0 - gold_need) + " 实得 " + str(GameState.gold))
	var all_zero := true
	for m in rec["materials"]:
		if GameState.get_item_count(str(int(m["item_id"]))) != 0:
			all_zero = false
	_check("D5★ 材料按配方全额扣除（不多扣不少扣）", all_zero, "残留=" + str(rec["materials"]))
	_check("D6 成品入背包", GameState.get_item_count(str(best_id)) == 1,
		"count=" + str(GameState.get_item_count(str(best_id))))
	_check("D7 锻造次数 +1", CraftService.used_today() == 1,
		"used=" + str(CraftService.used_today()))

	# D8 ★ 缺料时必须拒，且**一件材料都不能扣**（最易写错的分支）
	var probe_id := 0
	for r2 in CraftService.craftable_list():
		if int(r2["item_id"]) != best_id and (r2["materials"] as Array).size() > 0:
			probe_id = int(r2["item_id"])
			break
	if probe_id > 0:
		var rec2 := CraftService.recipe_of(probe_id)
		# 只备一半材料
		for m in rec2["materials"]:
			GameState.add_item(str(int(m["item_id"])), int(m["count"]) - 1)
		var gold1 := GameState.gold
		var snap := {}
		for m in rec2["materials"]:
			snap[str(int(m["item_id"]))] = GameState.get_item_count(str(int(m["item_id"])))
		var r3 := CraftService.craft(probe_id)
		_check("D8 缺料时拒绝锻造", not bool(r3.get("ok", false)), str(r3.get("msg", "")))
		_check("D8b★ 拒绝时材料零损耗（不白扣玩家料）",
			GameState.gold == gold1 and _snap_eq(snap),
			"gold " + str(gold1) + "->" + str(GameState.gold))
		# 还原
		for m in rec2["materials"]:
			GameState.add_item(str(int(m["item_id"])), -(int(m["count"]) - 1))


func _snap_eq(s: Dictionary) -> bool:
	for k in s:
		if GameState.get_item_count(str(k)) != int(s[k]):
			return false
	return true


## ---------- E. 看广告（三重防刷） ----------
func _probe_ad() -> void:
	var tiers: Array = ItemEconomyService.ad_tiers()
	if tiers.is_empty():
		_check("E0 广告档位非空", false, "tiers 为空")
		return
	var t0: Dictionary = tiers[0]
	var tid := str(t0["id"])

	var gold0 := GameState.gold
	var food0 := GameState.food
	var r := ItemEconomyService.watch_ad(tid)
	_check("E1 观览领奖成功", bool(r.get("ok", false)), str(r.get("msg", "")))
	_check("E2 金币入账",
		GameState.gold == gold0 + int(t0.get("gold", 0)),
		"期望 " + str(gold0 + int(t0.get("gold", 0))) + " 实得 " + str(GameState.gold))
	_check("E3 粮草入账",
		GameState.food == food0 + int(t0.get("food", 0)),
		"期望 " + str(food0 + int(t0.get("food", 0))) + " 实得 " + str(GameState.food))
	var mat_ok := true
	for m in t0.get("items", []):
		if GameState.get_item_count(str(int(m["item_id"]))) < int(m["count"]):
			mat_ok = false
	_check("E4 档位材料入账", mat_ok, str(t0.get("items", [])))
	_check("E5 今日次数 +1", ItemEconomyService.ad_used_today() == 1,
		"used=" + str(ItemEconomyService.ad_used_today()))

	# E6 ★ 同档冷却期内必须重复领取失败
	var gold1 := GameState.gold
	var r2 := ItemEconomyService.watch_ad(tid)
	_check("E6★ 同档 24 日冷却内不可再领（防刷核心）",
		not bool(r2.get("ok", false)), str(r2.get("msg", "")))
	_check("E6b 冷却期拒绝时金币零增长", GameState.gold == gold1,
		"gold " + str(gold1) + " -> " + str(GameState.gold))

	# E7 冷却剩余 >0
	_check("E7 冷却剩余日数为正",
		ItemEconomyService.ad_cooldown_left(tid) > 0,
		"left=" + str(ItemEconomyService.ad_cooldown_left(tid)))

	# E8 换档可领（每档独立冷却）
	var other := ""
	for t in tiers:
		if str(t["id"]) != tid:
			other = str(t["id"])
			break
	if not other.is_empty():
		var r3 := ItemEconomyService.watch_ad(other)
		_check("E8 换一档仍可领（冷却按档位独立计）", bool(r3.get("ok", false)), str(r3.get("msg", "")))


## ---------- F. 任务物品奖励 ----------
func _probe_quest_items() -> void:
	# F1 找一个配了 items 的任务，接取后直接交还
	var target := ""
	for q in DataManager.get_table("quests"):
		if q is Dictionary and (q["rewards"] as Dictionary).has("items"):
			target = str(q["id"])
			break
	if target.is_empty():
		_check("F1 存在配了 items 的任务", false, "quests.json 里 items 键为 0")
		return
	var qd := DataManager.get_record("quests", target)
	var items: Array = (qd["rewards"] as Dictionary)["items"]
	var iid := int((items[0] as Dictionary)["item_id"])
	var want := int((items[0] as Dictionary).get("count", 1))
	var cnt0 := GameState.get_item_count(str(iid))
	# 绕过目标判定直接调发放逻辑（探针只验发放，不验目标完成流程）
	var parts: Array[String] = []
	QuestService._grant_reward_items(qd["rewards"], parts)
	_check("F1 任务奖励物品入账",
		GameState.get_item_count(str(iid)) == cnt0 + want,
		"期望 " + str(cnt0 + want) + " 实得 " + str(GameState.get_item_count(str(iid))))
	_check("F2 结算提示列出该物品",
		parts.size() > 0 and parts[0].find(str(DataManager.get_item6(iid).get("name", ""))) >= 0,
		str(parts))

	# F3 配了 items 的任务数量
	var n := 0
	for q in DataManager.get_table("quests"):
		if q is Dictionary and (q["rewards"] as Dictionary).has("items"):
			n += 1
	_check("F3 多数任务配发了物品（≥50）", n >= 50, "count=" + str(n))

	# F4 materials 键也走同一条路（上游 battle_rewards 的既有键名）
	var parts2: Array[String] = []
	QuestService._grant_reward_items({"materials": [126]}, parts2)
	_check("F4 materials 键同样能发放（不是死键）",
		GameState.get_item_count("126") >= 1 and parts2.size() > 0, str(parts2))

	# F5 无效 id 必须显式暴露，不得静默吞掉
	var parts3: Array[String] = []
	QuestService._grant_reward_items({"items": [{"item_id": 999999, "count": 1}]}, parts3)
	_check("F5★ 无效 id 在结算提示里暴露（不静默吞）",
		parts3.size() > 0 and parts3[0].find("缺失") >= 0, str(parts3))


## ---------- G. 每日限次 ----------
func _probe_daily_limit() -> void:
	GameState.exchange_today = {}
	GameState.ad_today = {}
	var lim := ItemEconomyService.exchange_daily_limit()
	var goods: Array = ItemEconomyService.exchange_goods()
	var iid := int((goods[0] as Dictionary)["item_id"])
	var granted := 0
	for i in range(lim + 3):
		if bool(ItemEconomyService.exchange(iid).get("ok", false)):
			granted += 1
	_check("G1★ 集市每日限次生效（超出即拒）", granted == lim,
		"limit=" + str(lim) + " 实成功 " + str(granted) + " 次")
	# 换日归零
	GameState.exchange_today = {str(GameState.total_days() + 1): 99}
	_check("G2 换日后次数归零（惰性重置）",
		ItemEconomyService.exchange_used_today() == 0,
		"used=" + str(ItemEconomyService.exchange_used_today()))


## ---------- H. 存档往返 ----------
func _probe_save_roundtrip() -> void:
	GameState.craft_today = {str(GameState.total_days()): 3}
	GameState.ad_today = {str(GameState.total_days()): 2}
	GameState.ad_claimed = {"ad_mid": GameState.total_days()}
	GameState.exchange_today = {str(GameState.total_days()): 1}
	var d := GameState.to_dict()
	# 存档是 JSON —— int 键会变 str 键，这是既有事实，读侧用 str 取
	var keys := ["craft_today", "ad_today", "ad_claimed", "exchange_today"]
	var miss := 0
	for k in keys:
		if not d.has(k):
			miss += 1
	_check("H1 四个经济字段都进存档", miss == 0, "missing=" + str(miss))

	GameState.craft_today = {}
	GameState.ad_today = {}
	GameState.ad_claimed = {}
	GameState.exchange_today = {}
	GameState.from_dict(d)
	_check("H2 读档还原锻造次数", CraftService.used_today() == 3,
		"used=" + str(CraftService.used_today()))
	_check("H3 读档还原广告次数", ItemEconomyService.ad_used_today() == 2,
		"used=" + str(ItemEconomyService.ad_used_today()))
	_check("H4 读档还原广告冷却", ItemEconomyService.ad_cooldown_left("ad_mid") > 0,
		"left=" + str(ItemEconomyService.ad_cooldown_left("ad_mid")))
	_check("H5 读档还原兑换次数", ItemEconomyService.exchange_used_today() == 1,
		"used=" + str(ItemEconomyService.exchange_used_today()))
	# 旧档（缺这四个键）不得崩
	GameState.from_dict({"year": 184, "month": 1, "day": 1})
	_check("H6 旧档缺四字段时安全（不崩、额度全新）",
		CraftService.used_today() == 0 and ItemEconomyService.ad_used_today() == 0,
		"craft=" + str(CraftService.used_today()) + " ad=" + str(ItemEconomyService.ad_used_today()))
