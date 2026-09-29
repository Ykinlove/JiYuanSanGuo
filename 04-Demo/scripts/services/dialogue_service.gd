extends RefCounted
class_name DialogueService
## 对话服务（DialogueService）
## 职责：解析「跟这个 NPC 现在该说哪一段话」——NPC 记忆性。
##
## 【为什么需要它】（2026-09-29 用户反馈修复）
## 旧逻辑一律播 npcs.json 里写死的 dialogue_root（初见节点），于是：
##   接了任务 → 再找他 → 又把整段初见台词从头放一遍、再让玩家重新选一遍选项。
## 正确行为是 NPC 有记忆：任务在身就直接问进度，做完了就催你交，
## 交完这一轮，才重新进入下一轮任务的对话。
##
## 约定（数据侧）：为某个 NPC 补两个可选节点即可生效——
##   <root>_pending  任务进行中：「那件事办得怎么样了？」
##   <root>_turnin   任务已达成：「办成了？拿来我看。」
## 两个节点都不存在时自动退回 root，因此**没有数据的 NPC 行为与旧版完全一致**。

const SUF_PENDING := "_pending"
const SUF_TURNIN := "_turnin"

## 任务集合：只认「该 NPC 自己的初见节点（root 与 root_*）」里 accept_quest 发出的任务。
## 用 root 前缀而不是更宽泛的首段前缀，是为了避免 mentor_liming / mentor_yangleipeng
## 这类同前缀不同人互相串台（李明不该过问杨雷鹏的差事）。
static func quests_of_root(root: String) -> Array:
	var out: Array = []
	if root.is_empty():
		return out
	for d in DataManager.get_table("dialogues"):
		var nid := str(d.get("id", ""))
		if nid != root and not nid.begins_with(root + "_"):
			continue
		for o in d.get("options", []):
			for sub in str(o.get("action", "")).split(","):
				sub = sub.strip_edges()
				if not sub.begins_with("accept_quest:"):
					continue
				var qid := sub.substr("accept_quest:".length())
				if not qid.is_empty() and not out.has(qid):
					out.append(qid)
	return out


static func node_exists(node_id: String) -> bool:
	if node_id.is_empty():
		return false
	for d in DataManager.get_table("dialogues"):
		if str(d.get("id", "")) == node_id:
			return true
	return false


## 该 NPC 当前处于「进行中」的任务（不含已达成可交的）
static func _pending_quest(root: String) -> String:
	for qid in quests_of_root(root):
		if not GameState.active_quests.has(qid):
			continue
		if QuestService.can_turn_in(QuestService.get_quest(qid)):
			continue   ## 已达成 → 走 turnin 分支
		return qid
	return ""


## 该 NPC 当前可提交的任务
static func _ready_quest(root: String) -> String:
	for qid in quests_of_root(root):
		if not GameState.active_quests.has(qid):
			continue
		if QuestService.can_turn_in(QuestService.get_quest(qid)):
			return qid
	return ""


## 【对外主入口】与 NPC 交谈时该播哪个对话节点。
## 优先级：可提交 > 进行中 > 初见。目标节点不存在则逐级回退，永不返回空节点 id（root 为空除外）。
static func entry_node(npc: Dictionary) -> String:
	var root := str(npc.get("dialogue_root", ""))
	if root.is_empty():
		return ""
	if not _ready_quest(root).is_empty() and node_exists(root + SUF_TURNIN):
		return root + SUF_TURNIN
	if not _pending_quest(root).is_empty() and node_exists(root + SUF_PENDING):
		return root + SUF_PENDING
	if not _ready_quest(root).is_empty() and node_exists(root + SUF_PENDING):
		return root + SUF_PENDING   ## 只写了 pending 没写 turnin：达成后也先走 pending
	return root


## 去掉 _pending / _turnin 后缀，还原成初见节点 id（root）。
static func strip_suffix(node_id: String) -> String:
	var root := node_id
	if root.ends_with(SUF_TURNIN):
		root = root.substr(0, root.length() - SUF_TURNIN.length())
	elif root.ends_with(SUF_PENDING):
		root = root.substr(0, root.length() - SUF_PENDING.length())
	return root


## 【台词令牌用】当前这段对话「该念叨的那一项差事」：优先可交，其次进行中。
## 返回空字典表示该 NPC 名下没有活跃任务（此时台词里的 {quest} 走回退文案）。
static func focus_quest(node_id: String) -> Dictionary:
	var root := strip_suffix(node_id)
	var qid := _ready_quest(root)
	if qid.is_empty():
		qid = _pending_quest(root)
	if qid.is_empty():
		return {}
	return QuestService.get_quest(qid)


## 【台词令牌用】把任务目标压成一句人话，例：「清剿南中的黄巾残党（3）」。
## 目标描述为空时退回任务简介，保证 NPC 嘴里不会念出空白。
static func quest_goal_text(q: Dictionary) -> String:
	if q.is_empty():
		return ""
	var parts := PackedStringArray()
	for o in q.get("objectives", []):
		var d := str(o.get("desc", "")).strip_edges()
		if d.is_empty():
			d = str(o.get("type", "")).strip_edges()
		var c := int(o.get("count", 1))
		if c > 1 and not d.is_empty():
			d += "（%d）" % c
		if not d.is_empty():
			parts.append(d)
	if parts.is_empty():
		return str(q.get("description", "")).strip_edges()
	return "、".join(parts)


## 【turn_in:* 用】把当前对话节点所属 NPC 名下所有「已达成」的任务一并交付。
## 数据节点不必写死任务 id —— 一个 NPC 同时挂多个任务时也不会交错。
static func turn_in_all(node_id: String) -> String:
	var root := strip_suffix(node_id)
	var done := 0
	var last_msg := ""
	for qid in quests_of_root(root):
		if not GameState.active_quests.has(qid):
			continue
		if not QuestService.can_turn_in(QuestService.get_quest(qid)):
			continue
		var r := QuestService.turn_in(qid)
		if bool(r.get("ok", false)):
			done += 1
			last_msg = str(r.get("msg", ""))
	if done <= 0:
		return ""
	if done == 1:
		return last_msg
	return "%s（共交付 %d 项差事）" % [last_msg, done]
