class_name MainlineService
extends RefCounted
## 主线剧情规则层（MainlineService）
## 职责：主线章节的标题/解锁判定/推进、第一章黄巾之乱任务链的关卡校验与推进记账。
## 全部 static 纯函数，规则不持有场景节点（服务层范式，参考 RegionService / QuestService）。
##
## 第一章黄巾之乱闭环（M11）：
##   开局184南中 → 剿灭黄巾残党(满足阈值) → 声望达标 → 北上中原(许昌/汝南)
##   → 张角决战(中原黄巾主力 BOSS) → 第一章完成，mainline_chapter 推进到 2。
##
## 数值/阈值集中在此层，UI/场景脚本禁止内联数值公式。

## 章节中文名（1-7 章）。
const CHAPTER_TITLES := {
	1: "黄巾之乱",
	2: "董卓之乱",
	3: "群雄割据",
	4: "官渡之战",
	5: "赤壁之战",
	6: "三国鼎立",
	7: "一统天下",
}
const MAX_CHAPTER := 7

## 第一章黄巾主线（quests.json 任务 id）
const QUEST_CLEAR_SOUTH := "mj_hj_01"    ## 清剿南中黄巾残党
const QUEST_SUPPORT := "mj_hj_02"        ## 支援许昌 / 北上中原
const QUEST_FINAL := "mj_hj_03"          ## 决战张角

## 张角决战（encounters.json 新增遭遇 id + heroes6 boss 张角 id=358）
const ZHANGJUE_BATTLE_ID := "enc_zhangjue_boss"
const ZHANGJUE_HERO_ID := "358"
const ZHANGJUE_FACTION_ID := 8           ## factions6 张角

## 张角决战所需的中原区域（encounters.json regions 字段，配合 game region "zhongyuan"）
const FINAL_BATTLE_REGION := "zhongyuan"

## 黄巾残党清剿阈值（达成后开放北上中原）
const TURBAN_CLEAR_THRESHOLD := 3
## 北上中原所需名声门槛
const CH1_FAME_THRESHOLD := 10
## 第一章完成标记（写入 story_flags）
const FLAG_CH1_DONE := "chapter_1_done"
## 已接取第一章主线标记
const FLAG_CH1_STARTED := "mj_ch1_started"

## 黄巾残党清剿计数键（存于 GameState.mainline_data）
const DATA_TURBAN_CLEARED := "yellow_turban_cleared"


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


## 某章节是否已解锁（章节号 <= 当前章）
static func is_chapter_unlocked(ch: int) -> bool:
	return ch >= 1 and ch <= current_chapter()


## 第一章黄巾之乱是否处于进行中（mainline_chapter == 1）
static func is_ch1_active() -> bool:
	return current_chapter() == 1


## 黄巾残党清剿计数
static func turban_cleared_count() -> int:
	return int(_data().get(DATA_TURBAN_CLEARED, 0))


## 记录一次黄巾残党清剿（胜利结算调用）。返回当前计数。
static func record_turban_clear(amount: int = 1) -> int:
	var n := turban_cleared_count() + amount
	_data()[DATA_TURBAN_CLEARED] = n
	return n


## 黄巾残党是否已清剿达标（开放北上主线）
static func turban_clear_met() -> bool:
	return turban_cleared_count() >= TURBAN_CLEAR_THRESHOLD


## 名声门槛是否达标（可北上中原接主线）
static func fame_gate_passed() -> bool:
	return GameState.fame >= CH1_FAME_THRESHOLD


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


## 第一章黄巾任务链的关卡校验。
## 返回该主线程任务当前的状态，供 NPC 对话/剧情分支判定：
##   { ok, state, reason }
## state: blocked(不可接/未到前置) / available(可接) / active(进行中) / done(已完成)
static func mainline_quest_state(qid: String) -> Dictionary:
	if GameState.completed_quests.has(qid):
		return { "ok": false, "state": "done", "reason": "已在第一章黄巾线中完成。" }
	if GameState.active_quests.has(qid):
		return { "ok": true, "state": "active", "reason": "" }
	if not is_ch1_active():
		return { "ok": false, "state": "blocked",
			"reason": "当前不在第一章黄巾线中。第%d章：%s" % [current_chapter(), chapter_title(current_chapter())] }

	match qid:
		QUEST_CLEAR_SOUTH:
			return { "ok": true, "state": "available", "reason": "" }
		QUEST_SUPPORT:
			if not turban_clear_met():
				return { "ok": false, "state": "blocked",
					"reason": "南中黄巾残党未清剿（%d/%d）" % [turban_cleared_count(), TURBAN_CLEAR_THRESHOLD] }
			if not fame_gate_passed():
				return { "ok": false, "state": "blocked",
					"reason": "声望不足，尚难北上（%d/%d）" % [GameState.fame, CH1_FAME_THRESHOLD] }
			return { "ok": true, "state": "available", "reason": "" }
		QUEST_FINAL:
			if not bool(GameState.completed_quests.has(QUEST_SUPPORT)):
				return { "ok": false, "state": "blocked", "reason": "尚未抵达中原支援。" }
			return { "ok": true, "state": "available", "reason": "" }
	return { "ok": false, "state": "blocked", "reason": "未知主线程任务。" }


## 能否接取某主线程任务（对话 accept_quest 前置判定）
static func can_accept_quest(qid: String) -> bool:
	return bool(mainline_quest_state(qid).get("ok", false))


## 张角决战（第一章终局）是否可触发。
## 需：正在第一章 + 处于中原区域 + 已抵达中原(完成支援任务)。
static func is_final_battle_available() -> bool:
	if not is_ch1_active():
		return false
	if GameState.current_region != FINAL_BATTLE_REGION:
		return false
	return GameState.completed_quests.has(QUEST_SUPPORT)


## 第一章完成的章节旁白触发标记（写入 story_flags，world_map 检测后消费）
const FLAG_CH1_END_PENDING := "mj_ch1_end_pending"

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
## 推进到第 2 章，记录完成标记，并打上章末旁白触发标记。
## 返回 chapter_title 供 UI 展示章节旁白。
static func finalize_ch1_victory() -> Dictionary:
	var adv := advance_chapter()
	if not GameState.story_flags.has(FLAG_CH1_END_PENDING):
		GameState.story_flags.append(FLAG_CH1_END_PENDING)
	return {
		"ok": true,
		"chapter": adv.get("chapter", 2),
		"chapter_name": adv.get("chapter_name", chapter_title(2)),
		"title": "群雄割据",
	}


## 消费「第一章完成章节旁白」标记。返回是否需要播放旁白；播放后清除标记。
static func consume_ch1_end_pending() -> bool:
	if not GameState.story_flags.has(FLAG_CH1_END_PENDING):
		return false
	GameState.story_flags.erase(FLAG_CH1_END_PENDING)
	return true
