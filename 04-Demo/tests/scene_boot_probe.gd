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
## 各场景 _ready() 耗时（ms）。【第七十二轮·性能取证】
## 玩家反馈「加载黑屏太久、进出城池/战斗结算回大地图都慢」，
## 但此前只量过 world_map（1356ms）。本表把全链路主场景一次性量出来，
## 避免继续「盯着已知最慢的那个而漏掉更大的」。
var _cost: Dictionary = {}


func _say(text: String) -> void:
	print(text)
	_lines.append(text)


## 启动一个主场景：加载 → 实例化 → 进树 → 跑 3 帧（让 _ready / 延迟调用 flush）
## 返回是否成功加载并实例化（_ready 内部是否真报错由 stderr 兜底，不在本函数判定）。
func _try_boot(key: String, path: String) -> bool:
	_say("  >> 启动 %s (%s)" % [key, path])
	# 【分段计时】load 首载 / instantiate / 进树(_ready) 三段分开量。
	# 只量总和会分不清「纹理首载」与「_ready 构建」——这两者的优化手段完全不同。
	var t0 := Time.get_ticks_usec()
	var scene := load(path) as PackedScene
	var t1 := Time.get_ticks_usec()
	if scene == null:
		_say("     [FAIL] 场景加载失败（load 返回 null）")
		return false
	var inst := scene.instantiate()
	var t2 := Time.get_ticks_usec()
	if inst == null:
		_say("     [FAIL] 实例化返回 null")
		return false
	add_child(inst)
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	var t3 := Time.get_ticks_usec()
	_cost[key] = {
		"load": (t1 - t0) / 1000.0,
		"inst": (t2 - t1) / 1000.0,
		"ready": (t3 - t2) / 1000.0,
	}
	_say("     [OK] 实例化成功，子节点 %d 个" % inst.get_child_count())
	_say("     [耗时] load %.1fms / instantiate %.1fms / _ready+3帧 %.1fms"
		% [_cost[key]["load"], _cost[key]["inst"], _cost[key]["ready"]])
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
	# 【第七十二轮】战斗场景必须进表：玩家反馈「战斗完结算进行大地图」慢，
	# 而这条路径要经过 battle → world_map 两段启动，两段都得量。
	r = await _try_boot("battle_scene", "res://scenes/battle/battle_scene.tscn")
	all_ok = all_ok and r
	r = await _try_boot("world_map", "res://scenes/world/world_map.tscn")
	all_ok = all_ok and r
	r = await _try_boot("city_scene", "res://scenes/city/city_scene.tscn")
	all_ok = all_ok and r

	# ============================================================
	# 耗时汇总：按「玩家一次真实操作」看到的顺序排列（不是按启动顺序），
	# 便于直接看出哪一段最该优化。
	# ============================================================
	_say("")
	_say("================ 场景启动耗时汇总 ================")
	var flow := [
		["主菜单 → 大地图", ["main_menu", "world_map"]],
		["大地图 → 城内", ["world_map", "city_scene"]],
		["城内 → 大地图", ["city_scene", "world_map"]],
		["大地图 → 战斗", ["world_map", "battle_scene"]],
		["战斗结算 → 大地图", ["battle_scene", "world_map"]],
	]
	for row in flow:
		var label: String = row[0]
		var keys: Array = row[1]
		var parts: Array[String] = []
		var sum := 0.0
		for k in keys:
			if not _cost.has(k):
				continue
			var c: Dictionary = _cost[k]
			parts.append("%s %.0fms(load %.0f + ready %.0f)"
				% [k, c["load"] + c["ready"], c["load"], c["ready"]])
			# 【关键口径】ready 里的 load 首载在首次进游戏时才算真实成本，
			# 第二段（已缓存）只算 ready + 少量 load 命中。两者都要看。
			sum += c["load"] + c["ready"]
		_say("  %s" % label)
		for p in parts:
			_say("      %s" % p)
		_say("      合计 %.0fms" % sum)
	_say("")
	_say("  单场景明细（load首载 / instantiate / _ready+3帧，单位 ms）：")
	for k in _cost.keys():
		var c: Dictionary = _cost[k]
		_say("      %-18s load %7.1f  inst %7.1f  ready %7.1f"
			% [k, c["load"], c["inst"], c["ready"]])

	# ============================================================
	# 【第七十二轮·关键口径】上面测的是**冷启动**（每个场景首次 load，
	# 含全部纹理/子资源解码）。但真实玩家路径有 SceneRouter.prewarm：
	# 进入一个场景前已经把目标场景 load 过了 ⇒ 玩家实际等待的是
	#「已缓存 load + _ready」。两者差着数倍，不分开量就会得出
	# 「load 是瓶颈」的错误结论（而load 恰恰是 prewarm 覆盖的那段）。
	# 故这里再跑一轮**二次启动**（同进程内 load 已命中缓存）。
	# ============================================================
	_say("")
	_say("================ 二次启动（模拟 prewarm 已生效） ================")
	var warm: Dictionary = {}
	for row2 in [["main_menu", "res://scenes/main/main_menu.tscn"],
			["battle_scene", "res://scenes/battle/battle_scene.tscn"],
			["world_map", "res://scenes/world/world_map.tscn"],
			["city_scene", "res://scenes/city/city_scene.tscn"]]:
		var k2: String = row2[0]
		var p2: String = row2[1]
		var w0 := Time.get_ticks_usec()
		var sc2 := load(p2) as PackedScene
		var w1 := Time.get_ticks_usec()
		if sc2 == null:
			_say("  %s 二次 load 失败" % k2)
			continue
		var i2 := sc2.instantiate()
		var w2 := Time.get_ticks_usec()
		add_child(i2)
		await get_tree().process_frame
		await get_tree().process_frame
		await get_tree().process_frame
		var w3 := Time.get_ticks_usec()
		warm[k2] = {"load": (w1 - w0) / 1000.0, "ready": (w3 - w2) / 1000.0}
		_say("  %-14s load %7.1fms（缓存命中）  _ready %7.1fms  ⇒玩家等待 %7.1fms"
			% [k2, warm[k2]["load"], warm[k2]["ready"],
			warm[k2]["load"] + warm[k2]["ready"]])
		i2.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame

	_say("")
	_say(" 冷启动 vs 二次启动 对比（玩家真正等的是「二次」那行）：")
	for k3 in _cost.keys():
		if not warm.has(k3):
			continue
		var c3: Dictionary = _cost[k3]
		var w3b: Dictionary = warm[k3]
		_say("      %-14s 冷 %7.1fms  →  热 %7.1fms   （其中 _ready %7.1fms 未被 prewarm 覆盖）"
			% [k3, c3["load"] + c3["ready"], w3b["load"] + w3b["ready"], w3b["ready"]])

	_say("")
	_say("SCENE_BOOT=%s" % ["PASS" if all_ok else "FAIL"])
	var f := FileAccess.open("res://scene_boot_result.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()
	get_tree().quit()
