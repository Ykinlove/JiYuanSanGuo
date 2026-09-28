extends Node
## 遭遇撤退循环回归探针（2026-09-28）
## 验证「战败/撤退后当日不再重生同一遭遇」——这是阻断「撤退→一直重复进入战前布阵」
## 死循环的核心机制（encounter_manager._is_resolved 用 int(记录值) >= 绝对游戏日）。
## 直接驱动 EncounterManager._is_resolved（与 _generate 跳过重生的判定同一函数），
## 覆盖三种记录值：当日战败 / 过去某日战败 / 胜利。
## 结果写 res://encounter_loop_result.txt（终端编码不可靠，以文件为准）。

var _fails := 0
var _lines: Array[String] = []


func _say(t: String) -> void:
	print(t)
	_lines.append(t)


func _check(tag: String, cond: bool) -> void:
	_say("  [%s] %s" % ["OK" if cond else "FAIL", tag])
	if not cond:
		_fails += 1


func _ready() -> void:
	_say("========= 遭遇撤退循环回归探针 =========")
	await _run()
	_say("")
	_say("ENCOUNTER_LOOP_RESULT=%s" % ["PASS" if _fails == 0 else "FAIL (fails=%d)" % _fails])
	var f := FileAccess.open("res://encounter_loop_result.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()
	get_tree().quit()


func _run() -> void:
	var mgr := EncounterManager.new()
	add_child(mgr)
	await get_tree().process_frame

	var today := GameState.total_days()
	_say("当前绝对游戏日 = %d" % today)

	var enc_id := "raider_1024_768"

	# 1) 战败/撤退：记录为「当日」→ 当日应判定为已解决（不重生 → 不循环）
	GameState.encounter_resolved[enc_id] = today
	_check("战败当日：_is_resolved == true（不重生，循环被阻断）", mgr._is_resolved(enc_id))

	# 2) 设计允许「次日复活」：记录为过去某日 → 当日应判定未解决（可再战）
	GameState.encounter_resolved[enc_id] = today - 3
	_check("过去战败：_is_resolved == false（次日可原地复活）", not mgr._is_resolved(enc_id))

	# 3) 胜利：记录为 true（永久解决）
	GameState.encounter_resolved[enc_id] = true
	_check("胜利：_is_resolved == true（永久解决）", mgr._is_resolved(enc_id))

	# 4) 复刻 battle_scene._note_encounter_resolved 的战败写入路径：
	#    current_encounter 带 _enc_id → 写 total_days() → 当日必须挡住重生
	GameState.encounter_resolved.clear()
	GameState.current_encounter = { "_enc_id": enc_id, "id": "raider", "type": "battle" }
	# 复刻：战败 resolved_value = total_days()
	var rid := str(GameState.current_encounter.get("_enc_id", ""))
	if not rid.is_empty():
		GameState.encounter_resolved[rid] = GameState.total_days()
	_check("复刻战败写入后：当日 _is_resolved == true", mgr._is_resolved(enc_id))

	# 5) 防护：_enc_id 缺失时回退到 def id，仍能挡住当日原地重生（battle_scene 修复后分支）。
	#    复刻 battle_scene._note_encounter_resolved 的「_enc_id 缺失 → 回退 id」逻辑：
	GameState.encounter_resolved.clear()
	GameState.current_encounter = { "id": "raider", "type": "battle" }   # 无 _enc_id
	var fb_id := str(GameState.current_encounter.get("_enc_id", ""))
	if fb_id.is_empty():
		fb_id = str(GameState.current_encounter.get("id", ""))          # 回退到 def id
	if not fb_id.is_empty():
		GameState.encounter_resolved[fb_id] = GameState.total_days()    # 战败当日
	_check("缺 _enc_id → 回退 id 后：当日 _is_resolved('raider') == true（重生被挡）",
			not fb_id.is_empty() and mgr._is_resolved(fb_id))

	mgr.queue_free()
	await get_tree().process_frame
