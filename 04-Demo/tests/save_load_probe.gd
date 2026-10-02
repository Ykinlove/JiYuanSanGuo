extends Node
## 存档读档往返探针（场景式 harness）
## 运行：godot --headless --path <工程> res://tests/save_load_probe.tscn
##
## 目的：补齐测试套件盲区——存档/读档（SaveManager.save_game / load_game +
## GameState.to_dict / from_dict）这条「整局游戏生死线」此前从未被无头验证过。
## 编译期（_compile_check）与规则层探针都抓不到：
##   - to_dict 序列化了不可 JSON 化的字段导致存档内容残缺
##   - from_dict 读档后丢失/错位关键状态（尤其 JSON 把 int 键变 str 键的经典坑）
##   - 读不存在的槽位未优雅返回 false 而崩溃
##
## 结果落 res://save_load_result.txt；底层真实 WARNING/ERROR 由 _verify_save_load.py
## 从引擎 stderr 抓取。
##
## 【第六十一轮·副作用修复】本探针原先直接 `SaveManager.save_game(1)` /
## `load_game(1)`，**即每跑一次聚合就无声覆盖玩家 1 号槽的真实存档**，且不做
## 任何还原（实测：slot_1 已被写成 name="存档往返测试"/gold=8888 的测试垃圾）。
## 改为：
##   - 只用3 号专用槽（0 号是自动档，玩家真档实际落在 1 号）；
##   - 跑前快照 slot_3.json / slot_3.json.bak / _meta.json / _meta.json.bak，
##     跑完逐一还原（含 SaveManager 原子写的 .bak 副产品）。
## 取证/还原清单必须枚举原子写的**全部**产物，只还原主文件 = 污染残留。

const PROBE_SLOT := 3

var _lines: Array[String] = []
## slot_3 / _meta 的原文本快照（空串 = 原本不存在）
var _bak: Dictionary = {}


func _say(text: String) -> void:
	print(text)
	_lines.append(text)


func _slot_path() -> String:
	return "user://saves/slot_%d.json" % PROBE_SLOT


func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


func _backup_state() -> void:
	for p in [
		_slot_path(),
		_slot_path() + ".bak",
		"user://saves/_meta.json",
		"user://saves/_meta.json.bak",
	]:
		_bak[p] = _read_text(p)


func _restore_state() -> void:
	for p in _bak.keys():
		var text: String = _bak[p]
		if text == "":
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(p)
			continue
		var f := FileAccess.open(p, FileAccess.WRITE)
		if f != null:
			f.store_string(text)
			f.close()
	_say("  存档副作用还原：%d 个文件（slot_%d / _meta）"
		% [_bak.size(), PROBE_SLOT])


func _write_and_quit(ok: bool) -> void:
	_restore_state()
	_say("")
	_say("SAVE_LOAD=%s" % ["PASS" if ok else "FAIL"])
	var f := FileAccess.open("res://save_load_result.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()
	get_tree().quit()


func _ready() -> void:
	_say("================ 存档读档往返探针 ================")
	_backup_state()

	# 预置一份明确的游戏状态（覆盖默认空值，贴近真实游玩中途存档）
	GameState.player_name = "存档往返测试"
	GameState.gold = 8888
	GameState.year = 210
	GameState.month = 7
	GameState.current_city_id = "10"
	# int 键字典——直击 JSON 存档「int 键变 str 键」经典坑（faction_relations/diplomacy/ai_state）
	GameState.faction_relations = {1: 7, 2: -2, 5: 0}

	_say("  预置：player_name=%s gold=%d year=%d month=%d city=%s" % [
		GameState.player_name, GameState.gold, GameState.year, GameState.month, GameState.current_city_id])
	_say("  预置：faction_relations(int 键)=%s" % str(GameState.faction_relations))

	# 1) 存档到专用槽 3（不碰玩家的 1 号槽）
	var s1 := SaveManager.save_game(PROBE_SLOT)
	_say("  save_game(%d) -> %s" % [PROBE_SLOT, s1])
	if not s1:
		_say("  [FAIL] 存档失败")
		_write_and_quit(false)
		return

	# 2) 篡改内存状态
	GameState.player_name = "已被篡改"
	GameState.gold = 0
	GameState.year = 1
	GameState.current_city_id = ""
	GameState.faction_relations = {}

	# 3) 读档还原
	var l1 := SaveManager.load_game(PROBE_SLOT)
	_say("  load_game(%d) -> %s" % [PROBE_SLOT, l1])
	if not l1:
		_say("  [FAIL] 读档失败")
		_write_and_quit(false)
		return

	# 4) 断言往返正确性
	var ok := true
	if GameState.player_name != "存档往返测试":
		_say("  [FAIL] player_name 未还原：%s" % GameState.player_name); ok = false
	if GameState.gold != 8888:
		_say("  [FAIL] gold 未还原：%d" % GameState.gold); ok = false
	if GameState.year != 210:
		_say("  [FAIL] year 未还原：%d" % GameState.year); ok = false
	if GameState.current_city_id != "10":
		_say("  [FAIL] current_city_id 未还原：%s" % GameState.current_city_id); ok = false
	# int 键恢复：读档后 faction_relations 必须仍以 int 为键、值正确
	var fr = GameState.faction_relations
	if not (fr is Dictionary) or fr.get(1, null) != 7 or fr.get(2, null) != -2:
		_say("  [FAIL] faction_relations int 键未还原：%s" % str(fr)); ok = false
	else:
		_say("  faction_relations int 键还原正确：%s" % str(fr))

	# 5) 读不存在的槽位必须优雅返回 false（不崩溃）
	var l99 := SaveManager.load_game(99)
	_say("  load_game(99)(不存在) -> %s" % l99)
	if l99 != false:
		_say("  [FAIL] 读不存在槽位未返回 false"); ok = false

	_write_and_quit(ok)
