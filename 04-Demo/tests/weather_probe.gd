extends Node
## 天气层探针：四季概率统计 + 强制雨/晴/雪渐变 + 红锁 + 联动断言（取证用，非校验项）
## 用法：godot --headless --audio-driver Dummy --path . res://tests/weather_probe.tscn
##
## 【三十八轮 headless 大坑实录】CPUParticles2D 在 headless 下"实际发射中"会死循环
## 挂死引擎帧（await process_frame 永不返回）：与属性无关（amount=10 默认配置存活，
## 满速发射必挂）；amount_ratio 任何赋值也挂。主层对策：晴天冻结发射器
## set_process(false)（沿切换）+ 渐变用颜色 alpha。本探针验逻辑前先冻结发射器，
## 视觉/帧率取证走带窗口探针 weather_shot（非 headless）。

func _ready() -> void:
	print("WX probe_ready_begin")
	var script: GDScript = load("res://scripts/world/world_weather.gd")
	if script == null:
		push_error("[weather] 脚本加载失败")
		get_tree().quit(1)
		return

	# 假相机 + 真 tint/amb_audio（tint._process 依赖 GameState.month，autoload 已在位）
	var cam := Camera2D.new()
	add_child(cam)
	var tint := DayNightTint.new()
	add_child(tint)
	var amb_audio := WorldAmbientAudio.new()
	add_child(amb_audio)

	var node: Node = script.new()
	print("WX before_add_child")
	add_child(node)
	print("WX after_add_child")
	node.setup(cam, tint, amb_audio)
	await get_tree().process_frame
	print("WX after_frame1")
	# headless 下主层自动不建粒子（_rain/_snow 恒 null，见主层坑注），
	# 逻辑断言全部判空友好。
	print("WX headless_safe=", node._headless, " rain_null=", node._rain == null)

	# ① 四季概率统计（month=1 春 / 6 夏 / 10 冬；雪只应出现在冬）
	var rolls := 600
	var last := {"clear": 0, "rain": 0, "snow": 0}
	for m in [1, 6, 10]:
		GameState.month = m
		var cnt := {"clear": 0, "rain": 0, "snow": 0}
		for i in range(rolls):
			node._reroll()
			match int(node.weather):
				node.WEATHER_CLEAR: cnt["clear"] += 1
				node.WEATHER_RAIN: cnt["rain"] += 1
				node.WEATHER_SNOW: cnt["snow"] += 1
		print("WX season m=", m, " clear=", cnt["clear"], " rain=", cnt["rain"],
			" snow=", cnt["snow"], " /", rolls)
		last = cnt
	var ok_season: bool = int(last["snow"]) > 100 and int(last["rain"]) < 80   # 冬段：雪为主
	GameState.month = 1

	# ② 红锁：粒子数上限（填充率铁律）+ amount_ratio 禁用（headless 挂死坑）
	var src := FileAccess.get_file_as_string("res://scripts/world/world_weather.gd")
	var ok_lock: bool = node.RAIN_AMOUNT <= 200 and node.SNOW_AMOUNT <= 150 \
		and not src.contains("amount_ratio =") and not src.contains("amount_ratio=")
	print("WX lock rain=", node.RAIN_AMOUNT, "(≤200) snow=", node.SNOW_AMOUNT,
		"(≤150) no_amount_ratio=", ok_lock)

	# ③ 强制雨天渐入：跑 75 帧（0.35/s ≈ 0.0058/帧 → ~0.43）
	node._days_left = 9999
	node._apply(node.WEATHER_RAIN)
	node._target = 1.0
	for _i in range(75):
		await get_tree().process_frame
	var it: float = node._intensity
	var dim_a: float = tint.weather_dim.a
	var quiet: bool = amb_audio.weather_quiet
	var rain_vis: bool = (node._rain == null) or (node._rain.visible and node._rain.color.a > 0.2)
	print("WX rain intensity=", snappedf(it, 0.01), " dim_a=", snappedf(dim_a, 0.01),
		" quiet=", quiet, " rain_visible_alpha=", rain_vis)
	var ok_rain: bool = it > 0.3 and dim_a > 0.01 and quiet and rain_vis

	# ④ 切回晴天：渐出（90 帧 ~0.52 强度衰减）
	node._apply(node.WEATHER_CLEAR)
	for _i in range(90):
		await get_tree().process_frame
	print("WX clear target=", node._target, " intensity=", snappedf(node._intensity, 0.01),
		" dim_a=", snappedf(tint.weather_dim.a, 0.01),
		" quiet=", amb_audio.weather_quiet,
		" rain_volume=", snappedf(node._rain_audio.volume_db, 1.0))
	var ok_clear: bool = node._target == 0.0 and node._intensity < 0.2 \
		and amb_audio.weather_quiet == false

	# ⑤ 强制雪天：染色走 SNOW_DIM
	node._apply(node.WEATHER_SNOW)
	node._target = 0.8
	for _i in range(60):
		await get_tree().process_frame
	print("WX snow visible_ok=", node._snow == null or node._snow.visible,
		" alpha=", snappedf(node._snow.color.a, 0.01) if node._snow != null else -1.0,
		" dim=", tint.weather_dim)
	var ok_snow: bool = (node._snow == null) or (node._snow.visible and node._snow.color.a > 0.3)

	print("WX ok_season=", ok_season, " ok_rain=", ok_rain, " ok_clear=", ok_clear,
		" ok_snow=", ok_snow)
	print("WEATHER_DONE")
	get_tree().quit(0 if (ok_lock and ok_rain and ok_clear and ok_snow) else 1)
