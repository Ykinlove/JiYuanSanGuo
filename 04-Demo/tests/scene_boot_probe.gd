extends Node
## 场景启动探针（场景式 harness）
## 运行：godot --headless --path <工程> res://tests/scene_boot_probe.tscn
##
## 目的：补齐 probe_runner 未覆盖的两块演出主场景——world_map / city_scene
## （probe_runner 只实例化 battle_scene 做断言）。本探针专门暴露 _ready 里的
## 空引用 / 节点缺失 / 资源加载失败 / 装饰面板构造异常，这些只在「真实把场景
## 跑起来」时才会出现，编译期（_compile_check）与规则层探针都抓不到。
##
## 结果落 res://scene_boot_result.txt（Windows 控制台编码兜底）；
## 更底层的真实 WARNING/ERROR 由 _run_scene_boot.py 从引擎 stderr 抓取。

var _lines: Array[String] = []


func _say(text: String) -> void:
	print(text)
	_lines.append(text)


## 启动一个主场景：加载 → 实例化 → 进树 → 跑 3 帧（让 _ready / 延迟调用 flush）
## 返回是否成功加载并实例化（_ready 内部是否真报错由 stderr 兜底，不在本函数判定）。
func _try_boot(key: String, path: String) -> bool:
	_say("  >> 启动 %s (%s)" % [key, path])
	var scene := load(path) as PackedScene
	if scene == null:
		_say("     [FAIL] 场景加载失败（load 返回 null）")
		return false
	var inst := scene.instantiate()
	if inst == null:
		_say("     [FAIL] 实例化返回 null")
		return false
	add_child(inst)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	_say("     [OK] 实例化成功，子节点 %d 个" % inst.get_child_count())
	# 干净拆除：模拟真实场景切换（change_scene_to_file 会释放旧场景）的释放路径，
	# 避免「5 个重场景堆叠 + 立即 quit」在退出期产生的伪告警（get_path / 仍在用）。
	inst.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
	return true


func _ready() -> void:
	_say("================ 场景启动探针 ================")
	# city_scene._ready 第 157 行 _city_id = GameState.current_city_id，
	# 默认是空串 → DataManager.get_city("") 下游可能空引用。预置一个合法城池
	# 避免「空存档」伪阳性（真实游戏进城的路径必然先 set 过 current_city_id）。
	var cities := DataManager.get_table("cities")
	var cid := ""
	if cities.size() > 0 and cities[0] is Dictionary:
		cid = str(cities[0].get("id", ""))
	GameState.current_city_id = cid
	GameState.player_name = "测试"
	GameState.self_rule_name = ""
	_say("    city_scene 预置 current_city_id = %s" % cid)

	var all_ok := true
	var r: bool

	r = await _try_boot("main_menu", "res://scenes/main/main_menu.tscn")
	all_ok = all_ok and r
	r = await _try_boot("create_hero", "res://scenes/main/create_hero.tscn")
	all_ok = all_ok and r
	r = await _try_boot("formation_editor", "res://scenes/battle/formation_editor.tscn")
	all_ok = all_ok and r
	r = await _try_boot("world_map", "res://scenes/world/world_map.tscn")
	all_ok = all_ok and r
	r = await _try_boot("city_scene", "res://scenes/city/city_scene.tscn")
	all_ok = all_ok and r

	_say("")
	_say("SCENE_BOOT=%s" % ["PASS" if all_ok else "FAIL"])
	var f := FileAccess.open("res://scene_boot_result.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()
	get_tree().quit()
