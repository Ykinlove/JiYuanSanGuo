extends Node
## 商队层探针：假路验证折线采样/推进/折返/歇脚 + 真数据派队（取证用，非校验项）
## 用法：godot --headless --path . res://tests/caravan_probe.tscn

func _ready() -> void:
	var script: GDScript = load("res://scripts/world/world_caravans.gd")
	if script == null:
		push_error("[caravan] 脚本加载失败")
		get_tree().quit(1)
		return
	var node: Node = script.new()
	add_child(node)

	# ① 假路（L 形折线）：0,0 → 3000,0 → 3000,1000，总长 4000
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(3000, 0), Vector2(3000, 1000)])
	node.spawn_manual(pts)
	# 【注意】_ready 已自动派真队，假路队是最后一支
	var cv: Dictionary = node._caravans[node._caravans.size() - 1]
	print("CAR total=", cv["total"], " dir=", cv["dir"], " dist=", cv["dist"])

	# ② 折线采样：弧长 0 / 3000 / 4000 三点
	var s0: Dictionary = node._sample(cv, 0.0)
	var s1: Dictionary = node._sample(cv, 3000.0)
	var s2: Dictionary = node._sample(cv, 4000.0)
	print("CAR sample0=", s0["pos"], " sample3000=", s1["pos"],
		" sample4000=", s2["pos"])
	var ok_sample: bool = (s0["pos"] as Vector2).distance_to(Vector2.ZERO) < 0.01 \
		and (s1["pos"] as Vector2).distance_to(Vector2(3000, 0)) < 0.01 \
		and (s2["pos"] as Vector2).distance_to(Vector2(3000, 1000)) < 0.01
	print("CAR sample_ok=", ok_sample)

	# ③ 推进 + 折返：把 dist 推到末端附近跑帧
	cv["dist"] = 3999.0
	cv["dir"] = 1
	for _i in range(30):
		await get_tree().process_frame
	print("CAR after_end dir=", cv["dir"], " rest=", cv["rest"],
		" dist=", cv["dist"], " (应 dir=-1 且 rest>0)")
	var ok_turn: bool = int(cv["dir"]) == -1 and float(cv["rest"]) > 0.0

	# ④ 真数据派队（DataManager 已作为 autoload 在位）
	node._spawn_from_data()
	print("CAR real_spawned=", node._caravans.size(), " (上限 ", node.CARAVAN_MAX, ")")
	for i in range(node._caravans.size()):
		var c: Dictionary = node._caravans[i]
		print("CAR van", i, " total_len=", int(c["total"]),
			" pts_n=", (c["pts"] as PackedVector2Array).size())

	print("CAR ok_sample=", ok_sample, " ok_turn=", ok_turn)
	print("CARAVAN_DONE")
	get_tree().quit(0 if (ok_sample and ok_turn) else 1)
