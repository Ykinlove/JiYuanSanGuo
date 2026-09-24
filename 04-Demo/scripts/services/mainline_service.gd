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
