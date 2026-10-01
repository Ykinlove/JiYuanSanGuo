extends Node
## 地形诊断探针：真渲染 world_map 后打印 TerrainPainter 内部状态（取证用，非校验项）
## 用法（非 headless）：
##   SHOT_FRAMES=60 godot --path . res://tests/terrain_diag_probe.tscn

var _scene: Node = null


func _ready() -> void:
	var frames := int(OS.get_environment("SHOT_FRAMES")) if OS.get_environment("SHOT_FRAMES") != "" else 60
	var packed: PackedScene = load("res://scenes/world/world_map.tscn")
	if packed == null:
		push_error("[diag] world_map 场景加载失败")
		get_tree().quit(1)
		return
	_scene = packed.instantiate()
	add_child(_scene)

	for _i in range(frames):
		await get_tree().process_frame

	# 可选：SHOT_POS="x,y" 把玩家搬到指定世界坐标（对照取证用）
	var pos_env := OS.get_environment("SHOT_POS")
	if not pos_env.is_empty():
		var parts := pos_env.split(",")
		if parts.size() == 2:
			var p := Vector2(float(parts[0]), float(parts[1]))
			var player: Node2D = _scene.get_node_or_null("Player")
			var cam: Camera2D = _scene.get_node_or_null("Player/Camera2D")
			if player != null and cam != null:
				player.position = p
				cam.reset_smoothing()
				await get_tree().process_frame
				await get_tree().process_frame

	var terrain: TerrainPainter = _scene.get_node_or_null("Terrain")
	if terrain == null:
		print("DIAG terrain 节点不存在")
		get_tree().quit(1)
		return

	print("DIAG region_data_empty=", terrain._region_data.is_empty(),
		" map_size=", terrain.get_map_size(),
		" world_size=", terrain._world_size())
	print("DIAG art_checked=", terrain._art_geo_checked,
		" art_tex=", terrain._art_geo_tex != null)
	print("DIAG cam_zoom=", terrain._cam_zoom,
		" near_factor=", terrain._near_detail_factor())
	print("DIAG static_checked=", terrain._static_checked,
		" static_tex=", terrain._static_tex != null)
	var art: Texture2D = terrain._get_art_geo_tex()
	print("DIAG art_after_get=", art != null,
		" size=", (Vector2i(art.get_width(), art.get_height()) if art != null else Vector2i.ZERO))
	var st: Texture2D = terrain._get_static_tex_lazy()
	print("DIAG static_after_get=", st != null,
		" size=", (Vector2i(st.get_width(), st.get_height()) if st != null else Vector2i.ZERO))

	# 相机实际位置与可视矩形
	var cam: Camera2D = _scene.get_node_or_null("Player/Camera2D")
	if cam != null:
		print("DIAG cam_pos=", cam.global_position, " cam_zoom=", cam.zoom)

	# 截图留证
	var img := get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("res://_preview/_diag_world_terrain.png"))
	print("DIAG 截图已存 _preview/_diag_world_terrain.png")
	print("DIAG_DONE")
	get_tree().quit()
