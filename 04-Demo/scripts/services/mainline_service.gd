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
