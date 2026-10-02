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

var _lines: Array[String] = []


func _say(text: String) -> void:
	print(text)
	_lines.append(text)


func _write_and_quit(ok: bool) -> void:
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

	# 1) 存档到槽位 1
	var s1 := SaveManager.save_game(1)
	_say("  save_game(1) -> %s" % s1)
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
	var l1 := SaveManager.load_game(1)
	_say("  load_game(1) -> %s" % l1)
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
