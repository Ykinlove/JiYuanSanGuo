extends Node
## 场景截图探针：带窗口真渲染指定场景并保存 PNG（视觉自审用）
## 用法（必须非 headless）：
##   SHOT_SCENE=res://scenes/main/main_menu.tscn SHOT_FRAMES=30 SHOT_OUT=menu \
##   godot --path . res://tests/shot_probe.tscn
## 数据类场景（battle/city）自行灌好 GameState 再截图，见 SHOT_PRESET。

var _lines: Array[String] = []


func _ready() -> void:
	# 【四十轮】确定性对照取证：同种子 → 同背景/同布景，雨晴两图相减即纯天气层
	var senv := OS.get_environment("SHOT_SEED")
	if senv != "":
		seed(int(senv))
	var scene_path := OS.get_environment("SHOT_SCENE")
	var out_name := OS.get_environment("SHOT_OUT")
	var frames := int(OS.get_environment("SHOT_FRAMES")) if OS.get_environment("SHOT_FRAMES") != "" else 30
	if scene_path.is_empty():
		push_error("[shot_probe] 未设置 SHOT_SCENE")
		get_tree().quit(1)
		return

	# 数据预置：battle/city 需要部队/遭遇/当前城，空跑只会看到空壳
	# 【四十轮】天气 / 时辰预置：跨场景联动取证（雨天战斗、雪地泛白、城内夜灯）。
	# 天气事实本来由 WorldWeather 写在 GameState，这里直接灌值即可让战斗/城内演出层读到。
	var wenv := OS.get_environment("SHOT_WEATHER")
	if wenv != "":
		GameState.weather_id = clampi(int(wenv), 0, 2)
		GameState.weather_intensity = 0.9
		GameState.weather_days_left = 2
	var fenv := OS.get_environment("SHOT_DAYF")
	if fenv != "":
		GameState.day_fraction = clampf(float(fenv), 0.0, 1.0)

	var preset := OS.get_environment("SHOT_PRESET")
	if preset == "battle":
		GameState.troops = [
			{"unit_id": "infantry", "count": 80, "hero_id": "", "exp": 0},
			{"unit_id": "spearman", "count": 60, "hero_id": "", "exp": 0},
			{"unit_id": "archer", "count": 50, "hero_id": "", "exp": 0},
		]
		GameState.party = [{"hero_id": "181", "level": 3, "exp": 0, "intimacy": 20}]
		GameState.current_encounter = {
			"id": "shot_1", "name": "黄巾残党", "type": "battle",
			"enemy_units": [
				{"unit_id": "infantry", "count": 70},
				{"unit_id": "archer", "count": 40},
			],
			"rewards": {"gold": [100, 200], "fame": 10},
		}
	elif preset == "city":
		# 城内需要当前城：取一座有归属的城
		for c in DataManager.get_table("cities"):
			if c is Dictionary and str(c.get("id", "")) != "":
				GameState.current_city_id = str(c.get("id", ""))
				break

	var scene: PackedScene = load(scene_path)
	if scene == null:
		push_error("[shot_probe] 场景加载失败：%s" % scene_path)
		get_tree().quit(1)
		return
	add_child(scene.instantiate())

	for _i in range(frames):
		await get_tree().process_frame

	var img := get_viewport().get_texture().get_image()
	var out := "res://_preview/probe-%s.png" % (out_name if not out_name.is_empty() else "shot")
	img.save_png(ProjectSettings.globalize_path(out))
	_lines.append("SAVED %s (%dx%d)" % [out, img.get_width(), img.get_height()])
	print(_lines[0])
	var f := FileAccess.open("res://shot_probe_result.txt", FileAccess.WRITE)
	if f != null:
		f.store_line(_lines[0])
		f.close()
	get_tree().quit()
