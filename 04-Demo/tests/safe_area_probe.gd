extends Node
## 【第五十四轮】移动端安全区探针（headless 真跑）
##
## headless 下 DisplayServer.get_display_safe_area 恒等于整屏，因此 safe_insets()
## 必然返回全 0 —— 这本身就是一条关键不变量：
##   ① 无刘海环境下必须返回 Vector4.ZERO（保证桌面/平板/无头下布局逐像素不变，
##      安全区改造对绝大多数机型零副作用）；
##   ② 数值必须全部非负、有限（负边距会把 UI 推出屏幕，NaN 会让布局整体崩掉）；
##   ③ 不得抛异常（DisplayServer.window_get_size 在无头下可能返回 0）。
##
## 同时真调 apply_safe_top_left / apply_safe_bottom_right，断言零内缩时
## 控件 offset 逐字段不变 —— 这是「无刘海机零副作用」的可执行证据。

const REPORT := "res://encounter_safe_area_result.txt"

var _lines: Array[String] = []
var _fails := 0


func _ready() -> void:
	# ---- I1: safe_insets 在无刘海环境下必须全 0 ----
	var ins := UITheme.safe_insets(self)
	if ins != Vector4.ZERO:
		_fail("无刘海环境 safe_insets 应为全 0，实测 " + str(ins))
	_line("SAFE_INSETS=" + str(ins))

	# ---- I2: 四边必须非负且有限 ----
	var vals := [ins.x, ins.y, ins.z, ins.w]
	for v in vals:
		if v < 0.0:
			_fail("安全区内缩出现负值 " + str(v) + "（负边距会把 UI 推出屏幕）")
		if not is_finite(v):
			_fail("安全区内缩出现非有限值（NaN/Inf 会让布局整体崩掉）")

	# ---- I3: 贴左上控件在零内缩时 offset 逐字段不变 ----
	var top := Control.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 0.0
	top.offset_top = 0.0
	top.offset_right = -24.0
	top.offset_bottom = 92.0
	var before_top := [top.offset_left, top.offset_top, top.offset_right, top.offset_bottom]
	UITheme.apply_safe_top_left(top, self)
	var after_top := [top.offset_left, top.offset_top, top.offset_right, top.offset_bottom]
	for i in before_top.size():
		if not is_equal_approx(float(before_top[i]), float(after_top[i])):
			_fail("零内缩时贴顶控件 offset[" + str(i) + "] 被改动：" + str(before_top[i]) + " → " + str(after_top[i]))
	top.queue_free()

	# ---- I4: 贴右下控件在零内缩时 offset 逐字段不变 ----
	var br := Control.new()
	br.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	br.offset_left = -250.0
	br.offset_right = -110.0
	br.offset_top = -236.0
	br.offset_bottom = -96.0
	var before_br := [br.offset_left, br.offset_right, br.offset_top, br.offset_bottom]
	UITheme.apply_safe_bottom_right(br, self)
	var after_br := [br.offset_left, br.offset_right, br.offset_top, br.offset_bottom]
	for i in before_br.size():
		if not is_equal_approx(float(before_br[i]), float(after_br[i])):
			_fail("零内缩时贴右下控件 offset[" + str(i) + "] 被改动：" + str(before_br[i]) + " → " + str(after_br[i]))
	br.queue_free()

	# ---- I5: 传入 null viewport 不得崩（兜底返回全 0）----
	var nil_ins := UITheme.safe_insets(null)
	if nil_ins != Vector4.ZERO:
		_fail("null viewport 应兜底返回全 0，实测 " + str(nil_ins))

	# ---- I6: 传入 null 控件不得崩 ----
	UITheme.apply_safe_top_left(null, self)
	UITheme.apply_safe_bottom_right(null, self)

	# ---- I7: HUD 的 safe 成员必须已声明（接线存在性）----
	var hud_script: GDScript = load("res://scripts/ui/hud.gd")
	if hud_script == null:
		_fail("hud.gd 加载失败")
	else:
		var src := FileAccess.get_file_as_string("res://scripts/ui/hud.gd")
		if not src.contains("var safe := Vector4.ZERO"):
			_fail("hud.gd 缺少 safe 成员声明，_apply_responsive 的右缘基准会取不到值")
		if not src.contains("UITheme.safe_insets(self)"):
			_fail("hud.gd 未读取安全区内缩量")
		if src.contains("bar.offset_right = -24.0\n"):
			_fail("hud.gd 的资源条右缘仍是写死 -24.0，会顶掉 _ready 里加的安全区左移量")

	# ---- I8: 零内缩必须**早退**（契约层，不依赖 offset 实测）----
	# 只断言「offset 没变」是不够的：一旦有人把早退守卫删掉、直接写
	# `offset += s.x + 7.0` 这类常量补偿，offset 依然不变（因为 s.x 仍是 0），
	# 上一版断言会漏判。这里直接验证早退守卫本身在源码中存在，
	# 保证「无刘海环境一个像素都不动」是结构保证而非巧合。
	var theme_src := FileAccess.get_file_as_string("res://scripts/ui/ui_theme.gd")
	for fn in ["apply_safe_top_left", "apply_safe_bottom_right"]:
		var i := theme_src.find("static func %s(" % fn)
		if i < 0:
			_fail("ui_theme.gd 缺少 static func " + fn)
			continue
		# 截取该函数体（到下一个顶格 static func 或文件尾）
		var j := theme_src.find("\nstatic func ", i + 1)
		var body := theme_src.substr(i, (j if j > 0 else theme_src.length()) - i)
		var g1 := body.find("if s.x <= 0.0 and s.y <= 0.0:")
		var g2 := body.find("if s.z <= 0.0 and s.w <= 0.0:")
		var gi := g1
		if gi < 0:
			gi = g2
		elif g2 >= 0 and g2 < gi:
			gi = g2
		var has_guard := false
		if gi >= 0:
			# 守卫之后 120 字符内必须紧跟 return（否则不算有效早退）
			var tail := body.substr(gi, mini(120, body.length() - gi))
			has_guard = tail.find("return") >= 0
		if not has_guard:
			_fail(fn + " 缺少「零内缩即早退」守卫：无刘海机上仍会执行 offset 写入，"
				+ "一旦写入里混入常量补偿，布局会静默错位且断言测不出来")
		else:
			_lines.append("GUARD_OK " + fn)

	_write()


func _line(s: String) -> void:
	_lines.append(s)


func _fail(s: String) -> void:
	_fails += 1
	_lines.append("FAIL " + s)


func _write() -> void:
	var head := "SAFE_AREA_" + ("PASS" if _fails == 0 else "FAIL")
	var body := "\n".join(_lines)
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string(head + "\n" + body + "\nFAILS=" + str(_fails) + "\n")
		f.close()
	get_tree().quit(0 if _fails == 0 else 1)