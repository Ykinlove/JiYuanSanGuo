class_name SelfRuleService
extends RefCounted
## 自立为王规则层（SelfRuleService）
## 职责：自立判定（声望公式）、建国信物获取、立业流程（定国号/选旗帜/都城升格）、
##       自立后博弈、失败结局判定。全部 static 纯函数（服务层范式）。
##
## 设计（对应 02-策划文档/D-09 §1 声望系统 / §2 信物 / §3 立业 / §5 结局）：
##   自立判定值 = 村庄声望 + 自身名声 - 自身恶名；自立阈值 = 160；村声望 ≥80 才可自立。
##   信物：玉玺(has_jade_seal) + 虎符(has_tiger_tally)。
##   立业：祠堂自立 -> 定国号 -> 选旗帜 -> 都城升格 -> 自立成功。
##   失败结局：恶名过高触发天下共击；主城被攻破；被俘处决。

## 自立判定阈值（D-09 §5.2）
const SELF_RULE_THRESHOLD := 160
## 村庄声望门槛（需 ≥80 才具备自立资格，D-09 §1.2.1）
const VILLAGE_FAME_NEED := 80
## 自立后对其他势力关系的变化（视为新竞争对手，D-09 §3.2）
const RIVAL_RELATION_DELTA := -10
## 自立成功后追加的名声
const SELF_RULE_FAME_GAIN := 50

## 自立前置任务链：游历天下寻得三位名士，完成其托付后方可自立
##（替代原主菜单「自立」直入入口，需求 4）。
## 三位名士分别在三个不同地区游荡，靠近交互即触发托付任务。
const MENTOR_FLAGS: Array[String] = ["sr_yangleipeng", "sr_yangzixuan", "sr_liming"]

## 某位名士的托付是否已完成
static func mentor_done(flag: String) -> bool:
	return GameState.story_flags.has(flag)

## 完成某位名士的托付；三位皆完成则解锁自立（self_rule_unlocked）。
static func complete_mentor(flag: String) -> void:
	if not GameState.story_flags.has(flag):
		GameState.story_flags.append(flag)
	var all := true
	for f in MENTOR_FLAGS:
		if not GameState.story_flags.has(f):
			all = false
			break
	if all and not GameState.story_flags.has("self_rule_unlocked"):
		GameState.story_flags.append("self_rule_unlocked")

## 任务链是否已解锁自立（SelfRulePanel 打开闸门）
static func chain_unlocked() -> bool:
	return GameState.story_flags.has("self_rule_unlocked")

## 任务链进度（用于提示文案）
static func mentor_progress() -> Dictionary:
	var done := 0
	for f in MENTOR_FLAGS:
		if GameState.story_flags.has(f):
			done += 1
	return { "done": done, "total": MENTOR_FLAGS.size() }

## 某城村庄声望（GameState.village_reputation: city_id -> 声望）
static func village_fame(city_id: String) -> int:
	return int(GameState.village_reputation.get(str(city_id), 0))


## 自立判定值：村庄声望 + 名声 - 恶名（D-09 §5.2 公式）
static func judgment(city_id: String) -> int:
	return village_fame(city_id) + GameState.fame - GameState.infamy


## 建国信物是否齐备（玉玺 + 虎符）
static func has_seals_complete() -> bool:
	return GameState.has_jade_seal and GameState.has_tiger_tally


## 信物收集链完成回调：取得玉玺
static func grant_jade_seal() -> void:
	GameState.has_jade_seal = true
	if not GameState.story_flags.has("seal_jade"):
		GameState.story_flags.append("seal_jade")


## 信物收集链完成回调：取得虎符
static func grant_tiger_tally() -> void:
	GameState.has_tiger_tally = true
	if not GameState.story_flags.has("seal_tiger_tally"):
		GameState.story_flags.append("seal_tiger_tally")


## 按剧情标记名授予对应建国信物（供 quests/encounters 的 unlock 字段统一消费）。
## 返回 true 表示该标记是建国信物，已由本服务处理（调用方无需再写入 story_flags）。
## 【霸王立志篇】sr_ 前缀 = 三名士托付标记：由任务完成（rewards.unlock）驱动
## complete_mentor（幂等），取代旧「听讲即完成」路径。
static func grant_by_flag(flag: String) -> bool:
	if flag.begins_with("sr_"):
		complete_mentor(flag)
		return true
	match flag:
		"seal_jade":
			grant_jade_seal()
			return true
		"seal_tiger_tally":
			grant_tiger_tally()
			return true
	return false


## 若指定村庄声望不足，则取当前声望最高的已解锁村庄声望（容错处理）
static func best_village_fame() -> int:
	var best := 0
	for k in GameState.village_reputation:
		best = maxi(best, int(GameState.village_reputation[k]))
	return best


## 能否在某城发起自立：返回 {ok, reason}
## 前置：未加入任何势力、未自立、村声望达标、判定值达标、信物齐。
static func can_attempt(city_id: String) -> Dictionary:
	if GameState.is_self_rule:
		return { "ok": false, "reason": "已是自立政权，无需再立。" }
	if GameState.affiliation != 0:
		return { "ok": false, "reason": "已投靠势力，自立当先请辞（需退出势力）。" }
	if village_fame(city_id) < VILLAGE_FAME_NEED:
		return { "ok": false,
			"reason": "该地声望不足（%d/%d），尚难自立" % [village_fame(city_id), VILLAGE_FAME_NEED] }
	# 【修复】判定值正好等于阈值时被拒，但提示写的是「判定值 160，需 160」，
	# 数字完全达标却过不去。改成"达到阈值即可自立"，与文案和 status() 的 threshold 一致。
	if judgment(city_id) < SELF_RULE_THRESHOLD:
		return { "ok": false,
			"reason": "声望不足（判定值 %d，需 %d）" % [judgment(city_id), SELF_RULE_THRESHOLD] }
	if not has_seals_complete():
		return { "ok": false, "reason": "建国信物未齐，须集玉玺与虎符。" }
	return { "ok": true, "reason": "" }


## 立业：定国号 + 选旗帜 + 都城升格，自立成功。
## city_id：自立所在城池（升格为都城）。name：国号。flag：旗帜纹样 id。
static func found_self_rule(city_id: String, name: String, flag: int) -> Dictionary:
	var pre := can_attempt(city_id)
	if not bool(pre.get("ok", false)):
		return pre
	if name.is_empty():
		return { "ok": false, "reason": "须定国号，方可称国。" }
	GameState.is_self_rule = true
	GameState.self_rule_city = city_id
	GameState.self_rule_name = name
	GameState.self_rule_flag = flag
	# 【修复】直接改字段会绕过 add_fame() 里的 0~100 clamp 与 fame_changed 广播：
	# 名声可能加到 130 溢出，且外交/声望 UI 不刷新。
	GameState.add_fame(SELF_RULE_FAME_GAIN)
	# 自立后：全势力关系下降（新竞争对手）
	var rivals: Array = GameState.faction_relations.keys()
	for fid in rivals:
		GameState.faction_relations[fid] = clampi(
			int(GameState.faction_relations[fid]) + RIVAL_RELATION_DELTA, -100, 100)
	if not GameState.story_flags.has("self_rule_done"):
		GameState.story_flags.append("self_rule_done")
	return { "ok": true, "reason": "自立成功，国号为「%s」！" % name }


## 设定旗帜纹样（自立后可改）
static func set_flag(flag: int) -> Dictionary:
	if not GameState.is_self_rule:
		return { "ok": false, "reason": "尚未自立，无从选旗。" }
	GameState.self_rule_flag = flag
	return { "ok": true, "reason": "已更换旗帜纹样。" }


## 修改国号（自立后可改，参考 D-09 自立后行为）
static func rename(name: String) -> Dictionary:
	if not GameState.is_self_rule:
		return { "ok": false, "reason": "尚未自立。" }
	if name.is_empty():
		return { "ok": false, "reason": "国号不可为空。" }
	GameState.self_rule_name = name
	return { "ok": true, "reason": "已改国号为「%s」。" % name }


## 自立失败结局判定（D-09 §5.5 结局触发时序）：
## 返回当前自立政权的"安危"状态，供剧情/结局判定使用。
## value: state -> safe(稳固) / threat(被讨伐) / collapsed(覆灭/被俘)
static func ending_state() -> String:
	if not GameState.is_self_rule:
		return ""   # 非自立线，无自立结局
	if GameState.infamy >= 80:
		return "collapsed"   # 恶名过高，天下共击，势力瓦解
	# 【修复】_relation_with(0) 恒返回 0 —— 势力 id 从 1 起、relations 里没有键 0，
	# 于是「危在旦夕」预警是永不触发的死分支。改为看与任一势力的最低关系。
	if _worst_relation() <= -90:
		return "threat"
	return "safe"


## 与所有势力中关系最差者的关系值（无任何势力记录时按 0 计）
static func _worst_relation() -> int:
	var worst := 0
	for fid in GameState.faction_relations.keys():
		worst = mini(worst, int(GameState.faction_relations[fid]))
	return worst


## 读取对某势力的关系值（兼容存档 JSON 把整型键转成字符串键的情况）
static func _relation_with(faction_id: int) -> int:
	if GameState.faction_relations.has(faction_id):
		return int(GameState.faction_relations[faction_id])
	return int(GameState.faction_relations.get(str(faction_id), 0))


## 失败结局逐月检查（由 GameState.advance_month 调用）。
## 幂等：已在 GameState.ending_triggered 记录后不再重复触发（D-09 §5.4）。
## 返回本次触发的结局 id；未触发返回空串。
static func check_ending() -> String:
	if not GameState.is_self_rule or GameState.ending_triggered:
		return ""
	var st := ending_state()
	if st == "collapsed":
		GameState.ending_triggered = true
		if not GameState.story_flags.has("self_ending_c"):
			GameState.story_flags.append("self_ending_c")
		EventBus.show_toast("恶名滔天，天下共击——自立政权覆灭（结局·叛贼伏诛）")
		return "self_ending_c"
	# threat：仅提示一次，不作终局，玩家仍有翻盘余地
	if st == "threat" and not GameState.story_flags.has("self_rule_threat"):
		GameState.story_flags.append("self_rule_threat")
		EventBus.show_toast("各势力视你为敌，自立政权危在旦夕。")
	return ""


## 是否符合自立判定的总状态（供 UI/条件展示）：返回各分量
static func status(city_id: String) -> Dictionary:
	return {
		"village_fame": village_fame(city_id),
		"fame": GameState.fame,
		"infamy": GameState.infamy,
		"judgment": judgment(city_id),
		"threshold": SELF_RULE_THRESHOLD,
		"seals_ok": has_seals_complete(),
		"self_rule": GameState.is_self_rule,
	}
