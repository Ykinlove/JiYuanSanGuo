extends Node
## 第六十六轮·问题4 回归锁：大地图轮盘点开子项后，不得把轮盘再弹一遍。
##
## 复现的是 world_map 里真实的那段轮询守卫（第六十六轮加了「信任期」）：
##   if _wheel_return_panel != null:
##       if _wheel_guard_frames > 0:
##           _wheel_guard_frames -= 1
##       var guarded := _wheel_guard_frames > 0
##       if not is_instance_valid(_wheel_return_panel) or not _wheel_return_panel.visible:
##           if not guarded and not _busy and not _any_ui_open():
##               _wheel_return_panel = null
##               _menu_wheel.open()
##
## 【为什么信任期用帧数而不是毫秒】首版用的是毫秒时间窗，实测失效：
## 人物志 open() 要构建最多 300 行按钮，构建本身就可能耗时数百毫秒，
## 时间窗会在面板真正可见之前就耗尽，守卫形同虚设。
## 而穿透事件发生在开门的同帧或下一帧，与构建耗时无关 —— 用帧计数才能稳定覆盖。
##
## 用例：
##   A 点开「系统」后立刻被穿透事件关掉 → 信任期内不得重开轮盘（防误弹）
##   B 点开「人物志」同上
##   C 信任期过后面板真关闭 → 轮盘应当重开（设计行为，不得被误伤）
##   D 面板一直开着 → 任何时刻都不得重开轮盘
##
## 结果写 res://menu_reopen_result.txt

var _fails := 0
var _lines: Array[String] = []


func _say(t: String) -> void:
	print(t)
	_lines.append(t)


func _check(tag: String, cond: bool, detail: String = "") -> void:
	_say("  [%s] %s%s" % ["OK" if cond else "FAIL", tag,
		("  " + detail) if detail != "" else ""])
	if not cond:
		_fails += 1


const GUARD_FRAMES := 8

var _wheel_return_panel: Control = null
var _wheel_guard_frames := 0
var _busy := false
var _ui_panels: Array = []
var _menu_wheel: MainMenuWheel
var _settings: SettingsPanel
var _hero_dex: HeroDex


func _ready() -> void:
	_say("============ 大地图轮盘重复弹出 回归锁 ============")
	await _run()
	_say("")
	_say("MENU_REOPEN_RESULT=%s" % ["PASS" if _fails == 0 else "FAIL (fails=%d)" % _fails])
	var f := FileAccess.open("res://menu_reopen_result.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()
	get_tree().quit()


func _run() -> void:
	var ui := CanvasLayer.new()
	add_child(ui)
	_menu_wheel = MainMenuWheel.new()
	ui.add_child(_menu_wheel)
	_settings = SettingsPanel.new()
	ui.add_child(_settings)
	_hero_dex = HeroDex.new()
	ui.add_child(_hero_dex)
	_ui_panels = [_menu_wheel, _settings, _hero_dex]
	await get_tree().process_frame

	# ---- A 点开「系统」，下一帧面板被穿透关掉 → 信任期内不得重开 ----
	_reset()
	_select("system")
	_settings.visible = false          # 模拟穿透事件把刚开的面板关掉
	await get_tree().process_frame
	_sim_poll()
	_check("A 点开「系统」被穿透关掉后，信任期内不得重开轮盘", not _menu_wheel.visible,
		"wheel.visible=%s" % _menu_wheel.visible)

	# ---- B 点开「人物志」同样处理 ----
	_reset()
	_select("heroes")
	_hero_dex.visible = false
	await get_tree().process_frame
	_sim_poll()
	_check("B 点开「人物志」被穿透关掉后，信任期内不得重开轮盘", not _menu_wheel.visible,
		"wheel.visible=%s" % _menu_wheel.visible)

	# ---- C 信任期过后，面板真关闭 → 轮盘应当重开（设计行为不得误伤）----
	_reset()
	_select("heroes")
	_hero_dex.visible = false
	for i in range(GUARD_FRAMES + 2):
		await get_tree().process_frame
		_sim_poll()
	_check("C 信任期过后面板真关闭，轮盘应重开（设计行为未被误伤）", _menu_wheel.visible,
		"wheel.visible=%s" % _menu_wheel.visible)

	# ---- D 面板一直开着 → 任何时刻都不得重开 ----
	_reset()
	_select("system")
	for i in range(4):
		await get_tree().process_frame
		_sim_poll()
	_check("D 面板持续可见时，轮盘不得重开", not _menu_wheel.visible,
		"wheel.visible=%s settings.visible=%s" % [_menu_wheel.visible, _settings.visible])


func _reset() -> void:
	_wheel_return_panel = null
	_menu_wheel.visible = false
	_settings.visible = false
	_hero_dex.visible = false


func _select(action: String) -> void:
	# 与 world_map._on_wheel_selected 一致：开门即置信任帧数
	_wheel_guard_frames = GUARD_FRAMES
	match action:
		"system":
			_wheel_return_panel = _settings
			_settings.open(true)
		"heroes":
			_wheel_return_panel = _hero_dex
			_hero_dex.open()
		_:
			pass


## world_map._process 里的轮询守卫（含第六十六轮的信任期）
func _sim_poll() -> void:
	if _wheel_return_panel != null:
		if _wheel_guard_frames > 0:
			_wheel_guard_frames -= 1
		var guarded := _wheel_guard_frames > 0
		if not is_instance_valid(_wheel_return_panel) or not _wheel_return_panel.visible:
			if not guarded and not _busy and not _any_ui_open():
				_wheel_return_panel = null
				_menu_wheel.open()


func _any_ui_open() -> bool:
	for p in _ui_panels:
		if p != null and p.is_open():
			return true
	return false
