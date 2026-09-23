extends RefCounted
class_name AchievementService
## 成就规则层：读取 achievements.json，对照 GameState 判定是否达成，达成则发奖。
## UI 只调用 check_all() / definitions() / unlocked_state()，不在此放任何公式。

## 全部成就定义（含解锁状态合并，供面板展示）
static func definitions() -> Array:
	var root := DataManager.get_record("achievements", "root")
	var arr: Array = root.get("achievements", [])
	var out: Array = []
	for a in arr:
		out.append({
			"id": str(a.get("id", "")),
			"name": str(a.get("name", "")),
			"desc": str(a.get("desc", "")),
			"icon": str(a.get("icon", "star")),
			"target": int(a.get("target", 1)),
			"reward_gold": int(a.get("reward_gold", 0)),
			"attr_points": int(a.get("attr_points", 0)),
			"unlocked": GameState.is_achievement_unlocked(str(a.get("id", ""))),
			"progress": _progress(a),
		})
	return out


## 单条当前进度（0~1），供面板画进度条
static func _progress(a: Dictionary) -> float:
	var target := float(a.get("target", 1))
	if target <= 0:
		target = 1.0
	var val := _current_value(str(a.get("condition", "")))
	return clampf(val / target, 0.0, 1.0)


## 各类条件当前数值（key 为 achievements.json 的 condition 字段值）
static func _current_value(cond: String) -> float:
	match cond:
		"gold": return float(GameState.gold)
		"troops": return float(GameState.get_total_troops())
		"wins": return float(GameState.battle_win_count)
		"party": return float(GameState.party.size())
		"fame": return float(GameState.fame)
		"level": return float(GameState.player_level)
		"visited_cities": return float(GameState.visited_cities.size())
		"traded": return float(GameState.trades_done)
		"always": return 1.0
	return 0.0


## 判定某条是否满足数值门槛（不含解锁状态）
static func _met(a: Dictionary) -> bool:
	var cond := str(a.get("condition", ""))
	if cond == "always":
		return true
	var target := float(a.get("target", 1))
	return _current_value(cond) >= target


## 扫描全部成就，解锁达标且未解锁者，发放奖励，返回新解锁列表
## 解锁时会通过 EventBus.toast 广播提示，故各调用点直接调用即可，无需处理返回值。
static func check_all() -> Array:
	var newly: Array = []
	for a in definitions():
		var id := str(a.get("id", ""))
		if GameState.is_achievement_unlocked(id):
			continue
		if not _met(a):
			continue
		GameState.unlock_achievement(id)
		var gold := int(a.get("reward_gold", 0))
		var pts := int(a.get("attr_points", 0))
		if gold > 0:
			GameState.add_gold(gold)
		if pts > 0:
			GameState.player_attr_points += pts
		EventBus.player_stats_changed.emit()
		newly.append(a)
	if not newly.is_empty():
		var names: Array[String] = []
		for a in newly:
			names.append(str(a.get("name", "")))
		EventBus.show_toast("成就达成：%s" % "、".join(names))
	return newly


## 解锁数 / 总数
static func unlocked_count() -> int:
	var n := 0
	for a in definitions():
		if bool(a.get("unlocked", false)):
			n += 1
	return n
