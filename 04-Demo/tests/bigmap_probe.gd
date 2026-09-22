extends Node
## 运行时探针：复现 world_map._show_big_map 的 MiniMap 创建流程，
## 验证 size / _scale / _map_size 是否正常（headless 下 _draw 逻辑仍会执行）。

func _ready() -> void:
	var ui := CanvasLayer.new()
	add_child(ui)

	# —— 与 _show_big_map 完全相同的创建顺序 ——
	var mm := MiniMap.new()
	mm.size = Vector2(1560, 940)
	mm.position = Vector2(180, 70)
	mm.view_mode = MiniMap.MODE_WORLD
	mm.expanded = true
	ui.add_child(mm)

	await get_tree().process_frame
	await get_tree().process_frame

	print("PROBE-A(先设size后add) size=", mm.size,
		" _scale=", mm._scale,
		" _map_size=", mm._map_size,
		" window=", mm._world_window,
		" visible=", mm.visible)

	# —— 正确顺序对照：先 add 再设 size ——
	var mm2 := MiniMap.new()
	ui.add_child(mm2)
	mm2.size = Vector2(1560, 940)
	mm2.position = Vector2(180, 70)
	mm2.view_mode = MiniMap.MODE_WORLD
	mm2.expanded = true
	await get_tree().process_frame
	await get_tree().process_frame
	print("PROBE-B(先add后设size) size=", mm2.size,
		" _scale=", mm2._scale,
		" _map_size=", mm2._map_size,
		" window=", mm2._world_window)

	get_tree().quit()
