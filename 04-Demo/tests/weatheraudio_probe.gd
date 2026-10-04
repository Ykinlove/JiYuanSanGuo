extends Node
## 【第七十二轮·性能】雨声/风声缓存探针（无头真跑）
##
## 五个问题，各有判据：
## ① 两次调用的 AudioStreamWAV **必须逐位相同**（缓存不能改内容）
## ② 第二次起必须显著更快（缓存真的生效，而不是只加了个没用的分支）
## ③ 三个调用点（战斗/城内/大地图）拿到的**必须是同一个对象**
##    —— 这条最关键：如果各自 new 一份，内存没省，且预热白做
## ④ 清掉缓存后重合成，字节必须仍与第一次**完全相同**
##    —— 这是确定性自证：若原实现混进了非确定性（无 seed 的 randf、
##    全局 randi()），缓存就会悄悄改内容，而① 是发现不了的
## ⑤ 字节数/loop 头仍正确（缓存不能把流写坏）
##
## 输出 res://weatheraudio_probe_result.txt

const REPEAT := 4
const OUT_PATH := "res://weatheraudio_probe_result.txt"


func _ready() -> void:
	var out: Array[String] = []

	# ---------- ① 雨声：冷/热计时 ----------
	var t0 := Time.get_ticks_usec()
	var s1 := WeatherFx.make_rain_stream()
	var t1 := Time.get_ticks_usec()
	var s2 := WeatherFx.make_rain_stream()
	var t2 := Time.get_ticks_usec()
	var rain_cold := t1 - t0
	var rain_warm := t2 - t1
	for i in range(REPEAT):
		var ta := Time.get_ticks_usec()
		WeatherFx.make_rain_stream()
		rain_warm += Time.get_ticks_usec() - ta
	rain_warm /= (REPEAT + 1)

	var rain_expect: int = int(WeatherFx.MIX_RATE * WeatherFx.RAIN_DUR) * 2
	out.append("rain_same_object=%d" % (1 if s1 == s2 else 0))
	out.append("rain_same_bytes=%d" % (1 if s1.data == s2.data else 0))
	out.append("rain_bytes=%d" % s1.data.size())
	out.append("rain_expect_bytes=%d" % rain_expect)
	out.append("rain_bytes_ok=%d" % (1 if s1.data.size() == rain_expect else 0))
	out.append("rain_mix_rate=%d" % s1.mix_rate)
	out.append("rain_mix_rate_ok=%d"
		% (1 if s1.mix_rate == WeatherFx.MIX_RATE else 0))
	out.append("rain_loop_mode=%d" % int(s1.loop_mode))
	out.append("rain_loop_forward=%d" % int(AudioStreamWAV.LOOP_FORWARD))
	out.append("rain_loop_end=%d" % s1.loop_end)
	out.append("rain_loop_end_ok=%d"
		% (1 if s1.loop_end == rain_expect / 2 else 0))
	out.append("rain_cold_us=%d" % rain_cold)
	out.append("rain_warm_us=%d" % rain_warm)
	out.append("rain_speedup_x=%.1f"
		% (float(rain_cold) / maxf(1.0, float(rain_warm))))

	# ---------- ② 风声 ----------
	# 【类型标注坑】返回值来自对象方法调用是 Variant，:= 无法推断
	# ⇒ 显式标注 AudioStreamWAV。
	var amb := WorldAmbientAudio.new()
	var wt0 := Time.get_ticks_usec()
	var w1: AudioStreamWAV = amb._make_wind()
	var wt1 := Time.get_ticks_usec()
	var w2: AudioStreamWAV = amb._make_wind()
	var wt2 := Time.get_ticks_usec()
	var wind_cold := wt1 - wt0
	var wind_warm := wt2 - wt1
	for i in range(REPEAT):
		var tb := Time.get_ticks_usec()
		amb._make_wind()
		wind_warm += Time.get_ticks_usec() - tb
	wind_warm /= (REPEAT + 1)
	amb.free()

	var wind_expect: int = int(WorldAmbientAudio.MIX_RATE
		* WorldAmbientAudio.WIND_DUR) * 2
	out.append("wind_same_object=%d" % (1 if w1 == w2 else 0))
	out.append("wind_same_bytes=%d" % (1 if w1.data == w2.data else 0))
	out.append("wind_bytes=%d" % w1.data.size())
	out.append("wind_expect_bytes=%d" % wind_expect)
	out.append("wind_bytes_ok=%d" % (1 if w1.data.size() == wind_expect else 0))
	out.append("wind_loop_mode=%d" % int(w1.loop_mode))
	out.append("wind_loop_forward=%d" % int(AudioStreamWAV.LOOP_FORWARD))
	out.append("wind_cold_us=%d" % wind_cold)
	out.append("wind_warm_us=%d" % wind_warm)
	out.append("wind_speedup_x=%.1f"
		% (float(wind_cold) / maxf(1.0, float(wind_warm))))

	# ---------- ③ 大地图包装必须同源 ----------
	# WorldWeather._make_rain() 只是 WeatherFx.make_rain_stream() 的包装，
	# 加缓存后它必须返回**同一个对象**，否则包装层自己又合成了一遍。
	var wnode := WorldWeather.new()
	var wmap_stream: AudioStreamWAV = wnode._make_rain()
	out.append("worldmap_is_weatherfx=%d" % (1 if wmap_stream == s1 else 0))
	wnode.free()

	# ---------- ④ 确定性自证：清缓存重合成，字节必须不变 ----------
	# 【为什么必须做这条】① 只能证「两次调用相同」，证不了「两次都等于
	# 原实现的正确结果」。若 make_rain_stream 里混进了非确定性来源，
	# 缓存会把「每次不同」变成「永远同一个错值」—— 而这对循环音频来说
	# 恰好听起来还行，缺陷会被完全掩盖。清掉缓存重合成 = 拿一份新的来对拍。
	WeatherFx._rain_stream_cache = null
	WorldAmbientAudio._wind_cache = null
	var s3 := WeatherFx.make_rain_stream()
	out.append("rain_determinism=%d" % (1 if s3.data == s1.data else 0))
	var amb2 := WorldAmbientAudio.new()
	var w3: AudioStreamWAV = amb2._make_wind()
	out.append("wind_determinism=%d" % (1 if w3.data == w1.data else 0))
	amb2.free()

	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	f.store_string("\n".join(out) + "\n")
	f.close()
	print("WEATHER_AUDIO_PROBE_DONE n=", out.size())
	get_tree().quit(0)
