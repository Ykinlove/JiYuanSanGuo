extends Node
## 四十一轮 UI 音效包探针（取证用，非校验项）
## 用法：godot --headless --audio-driver Dummy --path . res://tests/ui_sfx_probe.tscn
##
## 验三件事：
##   ① 三条新音色（按钮 tap / 面板开合 / 铜钱）时域与电平达标
##      —— 短（UI 音不抢戏）、首尾归零（防爆 click）、去直流、峰值按设计留余量
##   ② 编码出来的 WAV 不循环（短音循环=嗡鸣）
##   ③ 路径分派正确：ui_click/ui_panel_open 等封装路径能命中对应音色
##      （旧实现命中不到，全部掉进 "other" 万能音——本探针专门锁这条回归）

func _ready() -> void:
	print("UISFX probe_begin")
	var ok := true

	# ① 三条音色：时长 / 峰值 / 直流 / 首尾
	var cases := [
		["tap", UiSfxSynth.tap(), 0.055, 0.44],
		["panel_open", UiSfxSynth.panel_open(), 0.30, 0.42],
		["panel_close", UiSfxSynth.panel_close(), 0.24, 0.36],
		["coins", UiSfxSynth.coins(), 0.34, 0.50],
	]
	for c in cases:
		var name: String = str(c[0])
		var s: PackedFloat32Array = c[1]
		var dur: float = float(c[2])
		var peak: float = float(c[3])
		var sr := float(UiSfxSynth.SR)
		var n_exp: int = int(sr * dur)
		var n: int = s.size()
		if n == 0:
			print("UISFX ", name, " EMPTY")
			ok = false
			continue
		var mx := 0.0
		var sum := 0.0
		for v in s:
			mx = maxf(mx, absf(v))
			sum += float(v)
		var mean := sum / float(n)
		var head: float = absf(float(s[0]))
		var tail: float = absf(float(s[n - 1]))
		var ok_n: bool = absi(n - n_exp) <= 1
		var ok_peak: bool = absf(mx - peak) < 0.01
		var ok_dc: bool = absf(mean) < 1e-4
		var ok_edge: bool = head < 0.002 and tail < 0.002   ## 归一化后 −54dB 以下，听不见 click
		var ok_dur: bool = dur <= 0.4          ## UI 音铁律：≤400ms
		print("UISFX ", name, " n=", n, "(exp ", n_exp, ") peak=", snappedf(mx, 0.001),
			"(exp ", peak, ") dc=", absf(mean), " head=", head, " tail=", tail)
		ok = ok and ok_n and ok_peak and ok_dc and ok_edge and ok_dur

	# ② 编码：非循环 + 采样率 + 字节数
	var st := UiSfxSynth.encode(UiSfxSynth.tap())
	var expect_bytes: int = UiSfxSynth.tap().size() * 2
	print("UISFX encode loop=", int(st.loop_mode), "(LOOP_DISABLED=",
		int(AudioStreamWAV.LOOP_DISABLED), ") mix=", st.mix_rate,
		" bytes=", st.data.size(), "(exp ", expect_bytes, ")")
	var ok_enc: bool = int(st.loop_mode) == int(AudioStreamWAV.LOOP_DISABLED) \
		and st.mix_rate == UiSfxSynth.SR and st.data.size() == expect_bytes
	ok = ok and ok_enc

	# ③ 路径分派（旧实现的回归锁）
	var paths := {
		"res://assets/audio/sfx/ui_click.ogg": "click",
		"res://assets/audio/sfx/ui_confirm.ogg": "confirm",
		"res://assets/audio/sfx/ui_cancel.ogg": "cancel",
		"res://assets/audio/sfx/ui_panel_open.ogg": "panel_open",
		"res://assets/audio/sfx/ui_panel_close.ogg": "panel_close",
		"res://assets/audio/sfx/ui_coin.ogg": "coin_trade",
		"res://assets/audio/sfx/coin_trade.ogg": "coin_trade",
	}
	var ok_kind := true
	for p in paths:
		var got := AudioManager._sfx_kind(str(p))
		var want: String = str(paths[p])
		if got != want:
			print("UISFX kind MISMATCH ", p, " got=", got, " want=", want)
			ok_kind = false
	print("UISFX ok_kind=", ok_kind)
	ok = ok and ok_kind

	# ③b 实际取流（四十一轮实况修正）：
	#   ui_click / ui_confirm / ui_cancel / coin_trade 都是真实导入的 ogg（7~26KB）
	#   → 必须走真音；ui_panel_open / ui_panel_close 无资产 → 必须走合成 WAV。
	#   旧认知「全部是 1 字节空桩」已被证伪（早期状态，后被导入脚本覆盖），
	#   故本项断言「两条通道各归其位」，而非「一律走合成」。
	var s_click: AudioStream = AudioManager._resolve_stream(
		"res://assets/audio/sfx/ui_click.ogg", false)
	var s_confirm: AudioStream = AudioManager._resolve_stream(
		"res://assets/audio/sfx/ui_confirm.ogg", false)
	var s_cancel: AudioStream = AudioManager._resolve_stream(
		"res://assets/audio/sfx/ui_cancel.ogg", false)
	var s_coin_real: AudioStream = AudioManager._resolve_stream(
		"res://assets/audio/sfx/coin_trade.ogg", false)
	var s_open: AudioStream = AudioManager._resolve_stream(
		"res://assets/audio/sfx/ui_panel_open.ogg", false)
	var s_close: AudioStream = AudioManager._resolve_stream(
		"res://assets/audio/sfx/ui_panel_close.ogg", false)
	# 【GDScript 坑】三元里含 Variant 不能 `:=`（无法推断类型），必须显式声明
	var n_open: int = s_open.data.size() if (s_open is AudioStreamWAV) else 0
	var n_close: int = s_close.data.size() if (s_close is AudioStreamWAV) else 0
	var real_ok: bool = AudioManager._stream_usable(s_click) \
		and AudioManager._stream_usable(s_confirm) \
		and AudioManager._stream_usable(s_cancel) \
		and AudioManager._stream_usable(s_coin_real)
	print("UISFX real_assets_usable=", real_ok,
		" click_len=", snappedf(float(s_click.get_length()), 0.001),
		" confirm_len=", snappedf(float(s_confirm.get_length()), 0.001),
		" cancel_len=", snappedf(float(s_cancel.get_length()), 0.001),
		" coin_len=", snappedf(float(s_coin_real.get_length()), 0.001))
	print("UISFX synth bytes panel_open=", n_open, " panel_close=", n_close,
		" open_is_wav=", s_open is AudioStreamWAV, " close_is_wav=", s_close is AudioStreamWAV)
	var ok_stream: bool = real_ok and n_open == 6615 * 2 and n_close == 5292 * 2 \
		and n_open != n_close
	ok = ok and ok_stream

	# ③c 空桩探测不能误杀真音（guard 的作用是不让损坏/零时长文件静默顶替占位音）
	var usable_bgm: bool = AudioManager._stream_usable(
		load("res://assets/audio/bgm/world_map.res") as AudioStream)
	var usable_ogg: bool = AudioManager._stream_usable(
		load("res://assets/audio/bgm/world_map.ogg") as AudioStream)
	print("UISFX usable baked_bgm=", usable_bgm, " raw_bgm_ogg=", usable_ogg)
	var ok_usable: bool = usable_bgm and usable_ogg
	ok = ok and ok_usable

	# ④ 按钮工厂自带按键音（全工程覆盖的前提）
	var btn := UITheme.button("探针")
	var conns := btn.pressed.get_connections()
	print("UISFX button pressed connections=", conns.size())
	var ok_btn: bool = conns.size() == 1
	btn.free()
	ok = ok and ok_btn

	print("UISFX DONE ok=", ok)
	get_tree().quit(0 if ok else 1)
