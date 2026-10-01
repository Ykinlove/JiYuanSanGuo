extends Node
## 云影渲染微基准：二分「region/repeat/尺寸」谁在杀 FPS（取证用，非校验项）
## 用法：godot --path . res://tests/cloud_bench_probe.tscn

func _bench(tag: String, setup: Callable) -> void:
	var node: Node2D = setup.call()
	add_child(node)
	# 预热 + 采样
	for _i in range(20):
		await get_tree().process_frame
	var sum := 0.0
	var n := 0
	for _i in range(150):
		await get_tree().process_frame
		sum += Engine.get_frames_per_second()
		n += 1
	print("BENCH ", tag, " = %.1f" % (sum / maxf(n, 1)))
	node.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _make_cloud(with_region: bool, with_repeat: bool, tex_size: int, tile: float) -> Node2D:
	var root := Node2D.new()
	var n := FastNoiseLite.new()
	n.seed = 20261001
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 1.0
	n.fractal_octaves = 3
	var img := Image.create(tex_size, tex_size, false, Image.FORMAT_RGBA8)
	for y in range(tex_size):
		var v := TAU * float(y) / float(tex_size)
		for x in range(tex_size):
			var u := TAU * float(x) / float(tex_size)
			var px := (1.6 + 0.55 * cos(v)) * cos(u) * 200.0
			var py := (1.6 + 0.55 * cos(v)) * sin(u) * 200.0
			var pz := 0.55 * sin(v) * 200.0
			var val := n.get_noise_3d(px, py, pz)
			img.set_pixel(x, y, Color(1, 1, 1, clampf((val - 0.08) / 0.55, 0.0, 1.0)))
	var sp := Sprite2D.new()
	sp.texture = ImageTexture.create_from_image(img)
	sp.modulate = Color(0.05, 0.08, 0.10, 0.13)
	sp.scale = Vector2.ONE * tile
	sp.position = Vector2(10628, 10913)
	if with_repeat:
		sp.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	if with_region:
		sp.region_enabled = true
		var view := Vector2(1920, 1080) / 0.78
		var region := view / tile + Vector2.ONE * 128.0
		sp.region_rect = Rect2(Vector2.ZERO, region)
	root.add_child(sp)
	return root


func _ready() -> void:
	# 相机模拟：zoom 0.78 近景
	var cam := Camera2D.new()
	cam.zoom = Vector2.ONE * 0.78
	cam.position = Vector2(10628, 10913)
	add_child(cam)
	cam.make_current()

	await _bench("A_基线空场景", func() -> Node2D: return Node2D.new())
	await _bench("B_region+repeat(线上配置)",
		func() -> Node2D: return _make_cloud(true, true, 1024, 4.0))
	await _bench("C_无region整tile",
		func() -> Node2D: return _make_cloud(false, true, 1024, 4.0))
	await _bench("D_无repeat无region",
		func() -> Node2D: return _make_cloud(false, false, 1024, 4.0))
	await _bench("E_region+repeat_256纹理",
		func() -> Node2D: return _make_cloud(true, true, 256, 4.0))
	print("BENCH_DONE")
	get_tree().quit()
