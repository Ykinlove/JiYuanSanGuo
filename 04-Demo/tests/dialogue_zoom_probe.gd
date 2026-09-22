extends SceneTree
## 对话界面 + 自由缩放 运行时探针。
## 运行：godot --headless --script res://tests/dialogue_zoom_probe.gd --path <project>
##
## 说明：--script 模式不加载 autoload（EventBus/DataManager 会报 Identifier not found），
## 因此这里**不能用 DialogueUI / PlayerController 的 class_name 直接构造**——
## 一旦 new() 就会连带编译依赖 autoload 的脚本而失败。
## 替代做法：把「不依赖 autoload 的那部分逻辑」用独立的小场景/资源在运行时验证：
##   1) 立绘贴图真的能被引擎加载（ResourceLoader.exists + load 出 Texture2D）
##   2) 对话 tscn 里的节点树结构完整（用 load 场景 + 实例化，不触发脚本依赖）
##   3) 缩放范围的数学正确（内联复算，与 player_controller 的公式保持一致）

## 与 player_controller.gd 保持一致的常量（仅用于复算校验）
const ZOOM_ABS_MAX := 2.4
const ZOOM_ABS_MIN := 0.05

func _calc_zoom_min(map_size: Vector2, vp: Vector2) -> float:
	var fit: float = minf(vp.x / maxf(map_size.x, 1.0), vp.y / maxf(map_size.y, 1.0))
	return clampf(fit, ZOOM_ABS_MIN, ZOOM_ABS_MAX)

func _calc_zoom_max(map_size: Vector2, vp: Vector2) -> float:
	var lo := _calc_zoom_min(map_size, vp)
	return clampf(ZOOM_ABS_MAX, lo, ZOOM_ABS_MAX)

func _initialize() -> void:
	var fails := 0

	# 1) 立绘贴图真实可加载（南中 8 将数字 id + 7 个 NPC 字符串 id）
	var keys: Array[String] = [
		"100", "205", "243", "268", "346", "419", "469", "471",
		"npc_elder", "npc_meng_qian", "npc_a_hei", "npc_blacksmith",
		"npc_traveler", "npc_zhurong", "npc_meng_huo",
	]
	var miss := 0
	for k in keys:
		var p := "res://assets/sprites/npcs/%s.png" % k
		if not ResourceLoader.exists(p):
			print("FAIL 立绘不存在: ", p)
			miss += 1
			continue
		var res := load(p)
		if not (res is Texture2D):
			print("FAIL 立绘加载后不是 Texture2D: ", p)
			miss += 1
	print("立绘可加载 %d/%d" % [keys.size() - miss, keys.size()])
	fails += miss

	# 2) 对话场景节点树（world_map.tscn 里的 DialogueUI 子树）
	#    注意：只读 tscn 结构，不实例化到树上，避免触发脚本 _ready。
	var tscn := "res://scenes/world/world_map.tscn"
	var packed := load(tscn)
	if packed == null:
		print("FAIL 无法加载 ", tscn)
		fails += 1
	else:
		var state := (packed as PackedScene).get_state()
		# 收集所有节点路径
		var paths := {}
		var cnt := state.get_node_count()
		for i in range(cnt):
			# SceneState 的路径带 "./" 前缀，统一去掉便于比对
			var p := String(state.get_node_path(i))
			if p.begins_with("./"):
				p = p.substr(2)
			elif p == ".":
				p = ""
			paths[p] = true
		# 关键节点：立绘栏必须存在，且位于 TextBox 之下
		var need: Array[String] = [
			"UI/DialogueUI/RootPanel/TextBox",
			"UI/DialogueUI/RootPanel/TextBox/PortraitBox",
			"UI/DialogueUI/RootPanel/TextBox/PortraitBox/PortraitTex",
			"UI/DialogueUI/RootPanel/TextBox/PortraitBox/PortraitChar",
			"UI/DialogueUI/RootPanel/TextBox/SpeakerLabel",
			"UI/DialogueUI/RootPanel/TextBox/TextLabel",
			"UI/DialogueUI/RootPanel/TextBox/ContinueHint",
			"UI/DialogueUI/RootPanel/OptionsBox",
		]
		var hit := 0
		for n in need:
			if paths.has(n):
				hit += 1
			else:
				print("FAIL tscn 缺节点: ", n)
				fails += 1
		print("tscn 对话节点树: %d/%d 项就位（全场景 %d 个节点）" % [hit, need.size(), cnt])

	# 3) 缩放范围数学（复算，脚本内联公式与 player_controller 一致）
	var viewport := Vector2(1920, 1080)
	var cases := {
		"全国大地图 19440x11880": Vector2(19440, 11880),
		"城内小图 2400x1800": Vector2(2400, 1800),
	}
	for label in cases.keys():
		var ms: Vector2 = cases[label]
		var lo := _calc_zoom_min(ms, viewport)
		var hi := _calc_zoom_max(ms, viewport)
		print("%s → 下限 %.4f / 上限 %.4f" % [label, lo, hi])
		if not (lo > 0.0 and hi > lo):
			print("FAIL 缩放范围非法: ", label)
			fails += 1
	# 大地图下限应正好是「整图装进屏幕」
	var expect := minf(viewport.x / 19440.0, viewport.y / 11880.0)
	var got := _calc_zoom_min(Vector2(19440, 11880), viewport)
	if absf(got - expect) > 0.001:
		print("FAIL 下限 != 整图适配值（期望 %.5f 实得 %.5f）" % [expect, got])
		fails += 1
	else:
		print("缩放下限 = 整图适配值 ✓（%.5f）" % got)
	# 上限恒为 2.4（除非地图小于下限，此时下限即上限）
	var got_hi := _calc_zoom_max(Vector2(19440, 11880), viewport)
	if absf(got_hi - ZOOM_ABS_MAX) > 0.001:
		print("FAIL 上限 != 2.4（实得 %.4f）" % got_hi)
		fails += 1
	else:
		print("缩放上限 = %.1f ✓" % got_hi)

	if fails == 0:
		print("DIALOGUE+ZOOM PROBE: ALL PASS")
	else:
		print("DIALOGUE+ZOOM PROBE: FAILS=%d" % fails)
	quit()
