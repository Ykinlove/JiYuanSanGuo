extends Node
## 四十轮 跨场景天气联动探针（取证用，非校验项）
## 用法：godot --headless --audio-driver Dummy --path . res://tests/weather_linkage_probe.tscn
##
## 验的是「事实层 GameState ↔ 演出层 WeatherFx ↔ 各场景」这条链：
##   ① 大地图掷出的天气会写进 GameState（战斗/城内读得到）
##   ② 回图时未到期的雨会续上（不会突变），到期才重掷
##   ③ 夜色系数连续、区间正确（灯火夜亮用）
##   ④ headless 下粒子层恒 null（CPUParticles2D 挂死坑），但雨声/雪地照常可建
##   ⑤ 雨声：三场景共用同一份流（采样字节数与循环标记一致）

func _ready() -> void:
	print("WXL probe_begin")
	var ok := true

	# ① WorldWeather 掷天气 → 写 GameState
	GameState.weather_id = 0
	GameState.weather_days_left = 0
	GameState.weather_intensity = 0.0
	var tint := DayNightTint.new()
	add_child(tint)
	var amb := WorldAmbientAudio.new()
	add_child(amb)
	var w := WorldWeather.new()
	add_child(w)
	w.setup(null, tint, amb)
	GameState.month = 10            # 冬：雪为主，方便区分雨雪
	w._reroll()
	var wid: int = int(GameState.weather_id)
	var wleft: int = int(GameState.weather_days_left)
	var wint: float = float(GameState.weather_intensity)
	print("WXL after_reroll id=", wid, " days_left=", wleft, " intensity=", snappedf(wint, 0.01),
		" node_weather=", int(w.weather))
	var ok_write: bool = wid == int(w.weather) and wleft >= 1 and wleft <= 3 and wint >= 0.0
	ok = ok and ok_write

	# ② 战斗/城内读的是同一份事实
	var read_id := WeatherFx.current()
	var read_int := WeatherFx.intensity()
	print("WXL crossscene read id=", read_id, " intensity=", snappedf(read_int, 0.01))
	var ok_read: bool = read_id == wid and absf(read_int - wint) < 0.001
	ok = ok and ok_read

	# ③ 回图续场：未到期不重掷（天数和天气都保留）
	GameState.weather_id = WeatherFx.SNOW
	GameState.weather_days_left = 2
	GameState.weather_intensity = 0.7
	var w2 := WorldWeather.new()
	add_child(w2)
	w2.setup(null, tint, amb)
	w2._restore_or_reroll()
	print("WXL restore weather=", int(w2.weather), " days_left=", int(w2._days_left),
		" intensity=", snappedf(float(w2._intensity), 0.01))
	var ok_restore: bool = int(w2.weather) == WeatherFx.SNOW and int(w2._days_left) == 2 \
		and absf(float(w2._intensity) - 0.7) < 0.001
	ok = ok and ok_restore

	# ③b 到期重掷（days_left=0 → 重掷并回写）
	GameState.weather_days_left = 0
	var w3 := WorldWeather.new()
	add_child(w3)
	w3.setup(null, tint, amb)
	w3._restore_or_reroll()
	print("WXL reroll_on_expire days_left=", int(GameState.weather_days_left))
	var ok_expire: bool = int(GameState.weather_days_left) >= 1
	ok = ok and ok_expire

	# ③c 过一天：天数递减并回写（未到期）
	GameState.weather_id = WeatherFx.RAIN
	GameState.weather_days_left = 3
	w2._days_left = 3
	w2._on_day_passed(184, 10, 2)
	print("WXL day_passed left=", int(GameState.weather_days_left))
	var ok_day: bool = int(GameState.weather_days_left) == 2
	ok = ok and ok_day

	# ④ headless 粒子恒 null；雪地泛白层照常可建
	var precip := WeatherFx.build_precip(WeatherFx.RAIN, Vector2(1920.0, 1080.0), 1.0)
	var snow_g := WeatherFx.build_snow_ground(Rect2(0.0, 712.0, 1920.0, 368.0))
	print("WXL headless=", WeatherFx.is_headless(), " precip_null=", precip == null,
		" snow_ground_size=", snow_g.size, " alpha=", snappedf(snow_g.color.a, 0.01))
	var ok_fx: bool = precip == null and snow_g.size.x == 1920.0 and snow_g.color.a > 0.0
	ok = ok and ok_fx

	# ⑤ 夜色系数：区间 + 跨日连续（0.999 → 0.001 不跳变）
	var nf0 := WeatherFx.night_factor(0.0)
	var nf_noon := WeatherFx.night_factor(0.45)
	var nf_night := WeatherFx.night_factor(0.88)
	var nf_end := WeatherFx.night_factor(1.0)
	print("WXL night f(0)=", snappedf(nf0, 0.01), " f(0.45)=", snappedf(nf_noon, 0.01),
		" f(0.88)=", snappedf(nf_night, 0.01), " f(1.0)=", snappedf(nf_end, 0.01))
	var ok_night: bool = nf_noon == 0.0 and nf_night > 0.9 and absf(nf0 - nf_end) < 0.001
	ok = ok and ok_night

	# ⑥ 雨声：三场景同一份流（WorldWeather 包装 = WeatherFx 实现）
	var st := WeatherFx.make_rain_stream()
	var expect_bytes: int = int(WeatherFx.MIX_RATE * WeatherFx.RAIN_DUR) * 2
	print("WXL rain bytes=", st.data.size(), " expect=", expect_bytes,
		" loop=", int(st.loop_mode), " mix=", st.mix_rate)
	var ok_rain: bool = st.data.size() == expect_bytes \
		and int(st.loop_mode) == int(AudioStreamWAV.LOOP_FORWARD) \
		and st.mix_rate == WeatherFx.MIX_RATE
	ok = ok and ok_rain

	print("WXL ok_write=", ok_write, " ok_read=", ok_read, " ok_restore=", ok_restore,
		" ok_expire=", ok_expire, " ok_day=", ok_day, " ok_fx=", ok_fx,
		" ok_night=", ok_night, " ok_rain=", ok_rain)
	print("WEATHER_LINKAGE_DONE ok=", ok)
	get_tree().quit(0 if ok else 1)
