extends Node
## 环境音层探针：实例化 WorldAmbientAudio 验证合成流与播放状态（取证用，非校验项）
## 用法（headless 即可，AudioServer dummy 下 playing 状态照常工作）：
##   godot --headless --path . res://tests/ambient_audio_probe.tscn

var _node: Node = null


func _ready() -> void:
	var packed: PackedScene = load("res://tests/ambient_audio_probe.tscn")
	if packed == null:
		push_error("[amb_audio] 自身场景加载失败")
		get_tree().quit(1)
		return
	var script: GDScript = load("res://scripts/world/world_ambient_audio.gd")
	if script == null:
		push_error("[amb_audio] 脚本加载失败")
		get_tree().quit(1)
		return
	_node = script.new()
	add_child(_node)
	print("AMB name=", _node.name, " class_ok=", _node is WorldAmbientAudio)

	# 合成流在位与循环设置
	var wind: AudioStreamPlayer = _node.get_node_or_null("WindLoop")
	if wind == null:
		print("AMB FAIL WindLoop 节点不存在")
		get_tree().quit(1)
		return
	var st: AudioStreamWAV = wind.stream
	print("AMB wind_stream=", st != null,
		" mix_rate=", (st.mix_rate if st != null else 0),
		" loop_mode=", (st.loop_mode if st != null else -1),
		" bytes=", (st.data.size() if st != null else 0))

	# 等几帧确认风声循环在播
	for _i in range(5):
		await get_tree().process_frame
	print("AMB wind_playing=", wind.playing, " bus=", wind.bus, " volume_db=", wind.volume_db)

	# 白天/夜间触发各一次（直接调用，不靠随机定时器）
	_node._play_bird()
	await get_tree().process_frame
	var c0: AudioStreamPlayer = _node._callers[0]
	print("AMB bird_playing=", c0.playing, " pitch=", c0.pitch_scale)
	_node._play_cricket()
	await get_tree().process_frame
	print("AMB cricket_playing=", _node._callers[1].playing)

	# 昼夜判断（clock 缺省 → 白天）
	print("AMB is_day_no_clock=", _node._is_day())
	print("AMB bird_interval=", _node.BIRD_INTERVAL, " cricket_interval=", _node.CRICKET_INTERVAL)
	print("AMB_AUDO_DONE")
	get_tree().quit()
