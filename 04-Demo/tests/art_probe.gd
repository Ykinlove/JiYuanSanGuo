extends SceneTree
## 美术资源运行时探针：验证新批次贴图真的能被引擎加载并挂到节点上。
## 运行：godot --headless --script res://tests/art_probe.gd --path <project>
## 说明：--script 模式不加载 autoload，故只检查「贴图资源 + class_name 模块」，
##       凡是需要 DataManager/GameState 的路径不放这里（那些由 _run_all_checks 覆盖）。

func _initialize() -> void:
	var fails := 0

	# 1) 城池类型图标（地图贴图）
	for t in ["city", "village", "pass", "ruin", "landmark"]:
		var p := "res://assets/sprites/city_icons/%s.png" % t
		if not ResourceLoader.exists(p):
			print("FAIL 缺城池图标: ", p)
			fails += 1

	# 2) 兵种图标（14）
	var units: Array[String] = [
		"infantry", "spearman", "cavalry", "heavy_cavalry", "archer", "crossbow",
		"elephant", "rattan", "navy", "tiger_cavalry", "white_horse",
		"qiang_archer", "great_halberd", "dragon_spear",
	]
	for u in units:
		var p := "res://assets/sprites/units/%s.png" % u
		if not ResourceLoader.exists(p):
			print("FAIL 缺兵种图标: ", p)
			fails += 1

	# 3) 角色立绘（7 NPC + 8 武将数字 id）
	var ports: Array[String] = [
		"npc_elder", "npc_meng_qian", "npc_a_hei", "npc_blacksmith", "npc_traveler",
		"npc_zhurong", "npc_meng_huo",
		"100", "205", "243", "268", "346", "419", "469", "471",
	]
	for n in ports:
		var p := "res://assets/sprites/npcs/%s.png" % n
		if not ResourceLoader.exists(p):
			print("FAIL 缺立绘: ", p)
			fails += 1

	# 4) 城池标记：走贴图分支后应出现 Sprite2D
	var marker := Node2D.new()
	CityMarkerArt.build(marker, {"id": "test_city", "type": "city", "is_capital": false})
	var city_sprite := false
	for c in marker.get_children():
		if c is Sprite2D and c.texture != null:
			city_sprite = true
	print("城池标记走贴图分支: ", city_sprite)
	if not city_sprite:
		fails += 1

	# 5) 战斗单位：应加载到兵种图标 Sprite2D
	var bu := BattleUnit.new()
	bu.setup(
		{"id": "infantry", "name": "刀盾兵", "category": "infantry",
			"hp": 100, "attack": 20, "defense": 15, "speed": 100, "range": 1},
		{"count": 100, "troop_index": 0}, {}, true)
	var unit_icon := false
	for c in bu.get_children():
		if c is Sprite2D and c.texture != null:
			unit_icon = true
	print("战斗单位挂上兵种图标: ", unit_icon)
	if not unit_icon:
		fails += 1

	# 6) 城内 NPC：有立绘时 build_npc 应产出 Sprite2D，且缩放到世界尺度
	var npc_with := CityInteriorArt.build_npc("铁匠老陈", "npc_blacksmith")
	var got_sprite := false
	var got_scale := 1.0
	for c in npc_with.get_children():
		if c is Sprite2D and c.texture != null:
			got_sprite = true
			got_scale = c.scale.x
	print("城内 NPC 走立绘分支: ", got_sprite, " | scale=", got_scale)
	if not got_sprite or got_scale <= 0.0 or got_scale > 0.3:
		fails += 1

	# 7) 无立绘的 NPC（守卒）应回退到几何小人，且仍带名牌
	var npc_plain := CityInteriorArt.build_npc("守卒")
	var has_poly := false
	var has_label := false
	for c in npc_plain.get_children():
		if c is Polygon2D:
			has_poly = true
		if c is Label:
			has_label = true
	print("无立绘 NPC 回退几何小人: ", has_poly, " | 有名牌: ", has_label)
	if not has_poly or not has_label:
		fails += 1

	if fails == 0:
		print("ART PROBE: ALL PASS")
	else:
		print("ART PROBE: FAILS=%d" % fails)
	quit()
