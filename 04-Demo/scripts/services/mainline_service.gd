class_name MainlineService
extends RefCounted
## 主线剧情规则层（MainlineService）
## 职责：主线章节的标题/推进、第一章黄巾之乱的战场记账与章末结算。
## 全部 static 纯函数，规则不持有场景节点（服务层范式，参考 RegionService / QuestService）。
##
## 第一章黄巾之乱闭环（M11）：
##   开局184南中 → 剿灭黄巾残党(战斗胜利记账) → 北上中原 → 张角决战(BOSS)
##   → 第一章完成，mainline_chapter 推进到 2。
##
## 数值/阈值集中在此层，UI/场景脚本禁止内联数值公式。

## 章节中文名（1-7 章，与《剧本规划-三国全史篇》对齐）。
const CHAPTER_TITLES := {
	1: "黄巾之乱",
	2: "董卓之乱",
	3: "群雄割据",
	4: "官渡之战",
	5: "赤壁之战",
	6: "三分鼎立",
	7: "星落五丈原",
}
const MAX_CHAPTER := 7

## 黄巾残党清剿计数键（存于 GameState.mainline_data）
const DATA_TURBAN_CLEARED := "yellow_turban_cleared"

## 第一章完成的章节旁白触发标记（写入 story_flags，world_map 检测后消费）
const FLAG_CH1_END_PENDING := "mj_ch1_end_pending"
## 第一章章首旁白触发标记（开场剧情播完后排期，world_map 消费）
const FLAG_CH1_START_PENDING := "mj_ch1_start_pending"


## 主线程记账字典的可变引用（不存在则创建）
static func _data() -> Dictionary:
	if GameState.mainline_data == null:
		GameState.mainline_data = {}
	return GameState.mainline_data


## 章节中文名
static func chapter_title(ch: int) -> String:
	return str(CHAPTER_TITLES.get(ch, "未知名章"))


## 当前章节（1-7）
static func current_chapter() -> int:
	return clampi(GameState.mainline_chapter, 1, MAX_CHAPTER)


## 黄巾残党清剿计数
static func turban_cleared_count() -> int:
	return int(_data().get(DATA_TURBAN_CLEARED, 0))


## 记录一次黄巾残党清剿（胜利结算调用）。返回当前计数。
static func record_turban_clear(amount: int = 1) -> int:
	var n := turban_cleared_count() + amount
	_data()[DATA_TURBAN_CLEARED] = n
	return n


## 推进主线到下一章。mainline_chapter+1，写入 story_flags 章节完成标记，封顶 MAX_CHAPTER。
## 已推进/返回 {changed, chapter, chapter_name, flag}
static func advance_chapter() -> Dictionary:
	var cur := current_chapter()
	if cur >= MAX_CHAPTER:
		return { "changed": false, "chapter": cur,
			"chapter_name": chapter_title(cur), "flag": "" }
	var flag := "chapter_%d_done" % cur
	if not GameState.story_flags.has(flag):
		GameState.story_flags.append(flag)
		GameState.mainline_chapter = cur + 1
	var nxt := current_chapter()
	return { "changed": true, "chapter": nxt,
		"chapter_name": chapter_title(nxt), "flag": flag }


## 战斗胜利后的主线记账（battle_scene 胜利分支调用）。
## 黄巾残党(quest_target=enc_yellow_turban)胜利 → 清剿计数 +1；
## 张角决战(quest_target=zhangjue_boss)胜利 → 第一章完成结算。
static func on_battle_win(qtarget: String) -> void:
	match qtarget:
		"enc_yellow_turban":
			record_turban_clear(1)
		"zhangjue_boss":
			finalize_ch1_victory()


## 第一章完成结算：张角决战获胜后调用。
## 推进到第 2 章，记录完成标记，跳时间到董卓之乱起点，并打上章末旁白触发标记。
## 返回 chapter_title 供 UI 展示章节旁白。
static func finalize_ch1_victory() -> Dictionary:
	var adv := advance_chapter()
	if not GameState.story_flags.has(FLAG_CH1_END_PENDING):
		GameState.story_flags.append(FLAG_CH1_END_PENDING)
	# 【剧本统一】跳时间到第二章（董卓之乱）史实起点，并置第二章章初旁白
	GameState.advance_to_date(189, 4)
	if not GameState.story_flags.has(chapter_intro_flag(2)):
		GameState.story_flags.append(chapter_intro_flag(2))
	return {
		"ok": true,
		"chapter": adv.get("chapter", 2),
		"chapter_name": adv.get("chapter_name", chapter_title(2)),
		"title": chapter_title(2),   ## 章名直接取章节表（旧写死「群雄割据」与第二章不符）
	}


## 消费「第一章完成章节旁白」标记。返回是否需要播放旁白；播放后清除标记。
static func consume_ch1_end_pending() -> bool:
	if not GameState.story_flags.has(FLAG_CH1_END_PENDING):
		return false
	GameState.story_flags.erase(FLAG_CH1_END_PENDING)
	return true


## 排期第一章章首旁白（mj_ch1_start）。由开场剧情结束时调用。
##
## 【为什么要这个（实测取证）】二~七章每一章都有 _start 旁白并由
## on_quest_completed → chapter_intro_flag 排期，唯独**第一章的
## mj_ch1_start 从来没有被任何代码排期过** —— 数据侧就算补了节点也不会播：
## 玩家从 intro（落脚南中）直接进第一章（打黄巾），中间缺
## 「中平元年末·广宗战前」这一拍铺垫，intro 与 ch2 之间是硬跳。
## 在开场结束时排期最自然：玩家刚听完「南中便从这里起」，紧接着
## 就该听见自己决定下山。
static func schedule_ch1_start() -> void:
	if not GameState.story_flags.has(FLAG_CH1_START_PENDING):
		GameState.story_flags.append(FLAG_CH1_START_PENDING)


## 消费「第一章章首旁白」标记。返回是否需要播放；播放后清除标记。
static func consume_ch1_start_pending() -> bool:
	if not GameState.story_flags.has(FLAG_CH1_START_PENDING):
		return false
	GameState.story_flags.erase(FLAG_CH1_START_PENDING)
	return true


# ==================================================================
# 二~七章通用推进（剧本规划《三国全史篇》2026-09-24）
# 机制：每章主线链的「章末任务」turn_in 后（EventBus.quest_completed），
#   ① advance_chapter 推进章节；② advance_to_date 跳到下一章史实起点；
#   ③ 置章末/章初旁白 pending（world_map 检测后播放 mj_ch{N}_end/_start）；
#   ④ 第七章完成 → 置结局 pending（全剧本收束于史实 234 五丈原）。
# 章节奖励不在此发 —— 直接写进各章末任务的 rewards 字段，走 QuestService 统一发放。
# ==================================================================

## 各章「章末任务」id（turn_in 即本章完成）
const CHAPTER_COMPLETE_QUEST := {
	2: "ch2_05", 3: "ch3_05", 4: "ch4_05", 5: "ch5_05", 6: "ch6_05", 7: "ch7_08",
}
## 各章完成后跳到的下一章史实起点（年, 月）
const CHAPTER_NEXT_START := {
	2: Vector2i(192, 4),   # 第二章完成 → 第三章 群雄割据（192.4 王允吕布诛董卓）
	3: Vector2i(200, 2),   # 第三章完成 → 第四章 官渡
	4: Vector2i(208, 7),   # 第四章完成 → 第五章 赤壁
	5: Vector2i(211, 1),   # 第五章完成 → 第六章 三分鼎立
	6: Vector2i(220, 1),   # 第六章完成 → 终章 星落五丈原
}
## 章末/章初旁白 pending 标记（world_map 检测后播放 mj_ch{N}_end / mj_ch{N}_start）
const FLAG_ENDING_PENDING := "story_ending_pending"


static func chapter_end_flag(ch: int) -> String:
	return "chapter_%d_end_pending" % ch


static func chapter_intro_flag(ch: int) -> String:
	return "chapter_%d_intro_pending" % ch


## 任务 id 属于哪一章的章末任务；不属于返回 0
static func chapter_of_complete_quest(qid: String) -> int:
	for ch in CHAPTER_COMPLETE_QUEST:
		if str(CHAPTER_COMPLETE_QUEST[ch]) == qid:
			return int(ch)
	return 0


## 主线任务完成入口（StoryDirector 监听 quest_completed 后调用）。
## 返回 {settled, chapter, jumped, ending} —— settled=true 表示发生了章节推进。
static func on_quest_completed(qid: String) -> Dictionary:
	var ch := chapter_of_complete_quest(qid)
	if ch <= 0:
		return { "settled": false }
	var cur := current_chapter()
	# 两种到达方式都收束：
	#   a) 任务链正常收尾（章末任务 turn_in 时章节尚未推进）；
	#   b) 章节已被战斗结算提前推进（如第一章 on_battle_win 先于 turn_in）。
	if ch != cur and ch != cur - 1:
		return { "settled": false }
	var advanced := false
	if ch == cur:
		advanced = bool(advance_chapter().get("changed", false))
	_settle_chapter(ch)
	return {
		"settled": true, "chapter": ch, "advanced": advanced,
		"jumped": CHAPTER_NEXT_START.has(ch),
		"ending": ch >= MAX_CHAPTER,
	}


## 章节结算内部：置旁白标记 + 跳时间 + 终章结局标记
static func _settle_chapter(ch: int) -> void:
	# 章末旁白（对本章）
	if not GameState.story_flags.has(chapter_end_flag(ch)):
		GameState.story_flags.append(chapter_end_flag(ch))
	# 跳时间到下一章史实起点
	if CHAPTER_NEXT_START.has(ch):
		var tgt: Vector2i = CHAPTER_NEXT_START[ch]
		GameState.advance_to_date(tgt.x, tgt.y)
		# 章初旁白（对下一章）
		var nxt: int = mini(ch + 1, MAX_CHAPTER)
		if not GameState.story_flags.has(chapter_intro_flag(nxt)):
			GameState.story_flags.append(chapter_intro_flag(nxt))
	# 终章完成 → 结局结算旁白
	if ch >= MAX_CHAPTER:
		if not GameState.story_flags.has(FLAG_ENDING_PENDING):
			GameState.story_flags.append(FLAG_ENDING_PENDING)


## 消费「章末旁白」标记（world_map 每帧检测）。返回章号；无则 0。
static func consume_chapter_end_pending() -> int:
	for ch in range(1, MAX_CHAPTER + 1):
		var f := chapter_end_flag(ch)
		if GameState.story_flags.has(f):
			GameState.story_flags.erase(f)
			return ch
	return 0


## 消费「章初旁白」标记（world_map 每帧检测）。返回章号；无则 0。
static func consume_chapter_intro_pending() -> int:
	for ch in range(2, MAX_CHAPTER + 1):
		var f := chapter_intro_flag(ch)
		if GameState.story_flags.has(f):
			GameState.story_flags.erase(f)
			return ch
	return 0


## 消费「全剧本结局」标记。返回是否需要播放结局演出。
static func consume_ending_pending() -> bool:
	if not GameState.story_flags.has(FLAG_ENDING_PENDING):
		return false
	GameState.story_flags.erase(FLAG_ENDING_PENDING)
	return true


# ==================================================================
# 多结局分支（2026-09-28 收尾）：第七章完成 → 按玩家终局状态自动分流
# 优先级：开国称帝(自立) > 匡扶汉室(效忠汉) > 枭雄霸业(占城≥阈值)
#        > 归隐山林(高名声自由人) > 三分归晋(默认历史线)
# 接入：world_map 消费 FLAG_ENDING_PENDING 时改播 ending_node_id()；
#       story_director 结局吐司改播 ending_summary()（与节点对应）。
# 失败结局（自立覆灭 self_ending_c）由 SelfRuleService.check_ending 单独处理，不在此。
# ==================================================================

## 汉朝势力 id（factions6.json：id=2「汉朝」）—— 效忠汉室线判定
const HAN_FACTION_ID := 2
## 枭雄霸业占城阈值（玩家实际占领城池 / 全国总城数）
const HEGEMON_RATIO := 0.8
## 归隐山林名声门槛（自由人且名声 ≥ 此值）
const HERMIT_FAME := 80
## 全国总城数（assets/data/cities.json 实际 110 城；占城比分母，若扩城须同步）
const TOTAL_CITIES := 110
## 玩家势力 id（factions6.json 中「玩家」条目）。玩家自由身 / 自立时攻下的城池记此号；
## 已投靠则记所投靠势力 id。（2026-09-29 修正：旧口径用 1，但势力表无 id=1，
## 导致城池归属显示「无名势力」，故统一到势力表里真实存在的条目。）
const PLAYER_FACTION_ID := 888888

## 城池接管方口径（唯一真源）：已投靠则归该势力，否则归玩家势力。
## world_map 攻城接管与此处占城统计必须共用本函数，否则霸业判定与实际归属对不上。
static func player_faction_id() -> int:
	return GameState.affiliation if GameState.affiliation > 0 else PLAYER_FACTION_ID

## 玩家实际占领的城池数。capture_city 写入 captured_cities 的 faction_id：
## 已投靠则归该势力，否则归玩家势力 PLAYER_FACTION_ID（888888）—— 见 world_map.gd
## 接管方判定。（2026-09-29 修正：旧口径用 1，但 factions6.json 无 id=1，
## 导致归属显示「无名势力」；现统一为势力表里真实存在的「玩家」条目。）
static func player_owned_city_count() -> int:
	var owner := player_faction_id()
	var n := 0
	for cid in GameState.captured_cities.keys():
		if int(GameState.captured_cities[cid]) == owner:
			n += 1
	return n

## 玩家占城比（0~1）
static func player_city_ratio() -> float:
	return float(player_owned_city_count()) / float(TOTAL_CITIES)

## 解析终局应播放的结局对话节点 id（供 world_map 分流播片）
static func ending_node_id() -> String:
	if GameState.is_self_rule:
		return "mj_finale_emperor"
	if GameState.affiliation == HAN_FACTION_ID:
		return "mj_finale_han"
	if player_city_ratio() >= HEGEMON_RATIO:
		return "mj_finale_hegemon"
	if GameState.affiliation == 0 and GameState.fame >= HERMIT_FAME:
		return "mj_finale_hermit"
	return "mj_finale"   ## 默认：三分归晋（历史线，保留原节点）

## 结局一句话总结（供 story_director 吐司，与节点对应；建国线带国号）
static func ending_summary() -> String:
	match ending_node_id():
		"mj_finale_emperor":
			return "【史官】天命所归——你以「%s」之名扫平六合，登基称帝，开万世之基业。" % GameState.self_rule_name
		"mj_finale_han":
			return "【史官】汉祚赖你而续——你辅弼幼主、重整朝纲，青史留忠名。"
		"mj_finale_hegemon":
			return "【史官】群雄尽伏——你仗剑横行，终成一统江山之霸主。"
		"mj_finale_hermit":
			return "【史官】功成身退——你挂印归隐、泛舟江湖，笑看风云。"
		_:
			return "【史官】三分归晋之局已定，而你的名字，已留在了青史之间。"
