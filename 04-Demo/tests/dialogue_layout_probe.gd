extends Control
## 对话选项布局探针（场景式 harness）
## 运行：godot --headless --path <工程> res://tests/dialogue_layout_probe.tscn
##
## 【根节点必须是 Control】DialogueUI 靠 PRESET_FULL_RECT / BOTTOM_WIDE 锚点
## 定位，锚点只在父级是 Control 时才有参照。首版探针根节点是 Node，
## 坐标直接失真（按钮 y 落到 1440），370 条溢出全是假警报。
## 换成 Control（tscn 里铺满 1920×1080）后才是真实布局。
##
## 目的：无头验证 DialogueUI 的选项排布在**真实 192 个对话节点**下都不出屏。
## 背景（第五十一轮实测）：选项按钮从 62px 抬到 84px 触控铁律后，
## 单列排布下 8/9/10 项的对话（liubei_intro 10 / caocao_intro 9 /
## strategist_intro 8）总高 756~948px，尾部按钮溢出屏幕下边界 236~428px，
## 玩家「点后面几个选项没反应」。本探针锁死「两列排布」这条修复不回归。
##
## 断言（逐节点）：
##   1. 每个选项按钮都在 1080p 屏幕矩形内（不被下边界/左右切掉）
##   2. 每个按钮高度 >= UITheme.TOUCH_H（触控铁律）
##   3. 按钮之间不重叠（两列错位会导致手势命中歧义）
##   4. 超 4 项确实走了两列
##
## 结果落 res://dialogue_layout_result.txt；真实 WARNING/ERROR 由
## _verify_dialogue_layout.py 从引擎 stderr 抓取。

const EPS := 0.5   ## 浮点比较容差

## 【坐标系坑·必须相对判断，不能硬编码 1080】
## headless 无窗口时 Godot 把视口退化成 1920×**1920**（高度=宽度），
## 而真实运行时是 1920×1080。OptionsBox 用 offset_bottom=-160 锚底，
## 于是 headless 下 box 顶边落到 y=1440，若拿 1080 去卡就会报出
## 370 条「溢出屏幕」的假警报（首版探针就栽在这）。
## 正解：所有出屏判断都相对 **本次实际视口高度**，
## 这样同一套断言在 headless 与真机都成立。
var _vp := Vector2(1920, 1080)

var _lines: Array[String] = []
var _fail := 0
var _checked_nodes := 0
var _checked_buttons := 0
var _two_col_nodes := 0


func _say(text: String) -> void:
	print(text)
	_lines.append(text)


func _write_and_quit(ok: bool) -> void:
	_say("")
	_say("节点数=%d 按钮数=%d 两列节点数=%d" % [
		_checked_nodes, _checked_buttons, _two_col_nodes])
	_say("DIALOGUE_LAYOUT=%s" % ["PASS" if ok else "FAIL"])
	var f := FileAccess.open("res://dialogue_layout_result.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()
	get_tree().quit()


func _rect_in_screen(r: Rect2, screen: Vector2) -> bool:
	return r.position.x >= -EPS \
		and r.position.y >= -EPS \
		and r.end.x <= screen.x + EPS \
		and r.end.y <= screen.y + EPS


func _ready() -> void:
	# 自身也铺满，保证子 DialogueUI 的锚点参照就是 1920×1080
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_say("================ 对话选项布局探针 ================")
	# 以实际视口为准（headless 会退化成 1920×1920，真机是 1920×1080）
	_vp = get_viewport_rect().size
	_say("探针根节点尺寸：%s / 实际视口：%s" % [str(size), str(_vp)])

	var raw := DataManager.get_table("dialogues")
	if raw == null or (raw is Array) == false:
		_say("[FAIL] 读不到 dialogues 表")
		_write_and_quit(false)
		return

	var rows: Array = raw
	_say("dialogues.json 节点数：%d" % rows.size())

	for row in rows:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		# 必须 await：_check_node 内含 await（等布局帧），漏掉会让每次调用
		# 在第一个 await 处挂起直接返回，180 个节点全部空跑、
		# 按钮数为 0 却报 PASS —— 探针反而成了假绿灯。
		await _check_node(row)

	_say("")
	_say("失败项：%d" % _fail)
	_write_and_quit(_fail == 0)


## 逐节点校验：真跑一遍 _show_options() 的排布结果
func _check_node(node: Dictionary) -> void:
	var node_id := str(node.get("id", "?"))
	var opts: Array = node.get("options", [])
	if opts.is_empty():
		return
	_checked_nodes += 1

	var ui := DialogueUI.create()
	add_child(ui)
	# start() 内部会 _show_options()；这里只需要布局，故直接注入选项再触发
	ui._options = opts
	ui._opt_grid.columns = 1
	ui.visible = true
	# 等一帧让容器完成一次布局计算，再读实际矩形
	await get_tree().process_frame
	ui._show_options()
	await get_tree().process_frame
	await get_tree().process_frame

	var btns: Array[Button] = ui._opt_buttons
	if btns.is_empty():
		# 全部选项被过滤（如已完成任务）属正常，交给其它节点覆盖
		ui.queue_free()
		return

	var cols: int = maxi(1, ui._opt_grid.columns)
	if cols > 1:
		_two_col_nodes += 1
	_checked_buttons += btns.size()

	var rects: Array[Rect2] = []
	for b in btns:
		rects.append(b.get_global_rect())

	# 断言 2：触控高度
	for i in btns.size():
		var h := btns[i].size.y
		if h < UITheme.TOUCH_H - EPS:
			_fail += 1
			_say("[FAIL] %s 选项#%d 高度 %.1f < TOUCH_H %.1f"
				% [node_id, i, h, UITheme.TOUCH_H])

	# 断言 1：不出屏（用按钮实际矩形，而非容器高度）
	for i in rects.size():
		if not _rect_in_screen(rects[i], _vp):
			_fail += 1
			_say("[FAIL] %s 选项#%d 溢出视口%s rect=%s"
				% [node_id, i, str(_vp), str(rects[i])])

	# 断言 3：两两不重叠
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			if rects[i].intersects(rects[j]):
				_fail += 1
				_say("[FAIL] %s 选项#%d 与 #%d 重叠 %s / %s"
					% [node_id, i, j, str(rects[i]), str(rects[j])])

	# 断言 4：超 4 项必须两列（单列会溢出，这是本次修复的核心不变量）
	if btns.size() > DialogueUI.MAX_OPT_VISIBLE and cols < 2:
		_fail += 1
		_say("[FAIL] %s 有 %d 项却仍是单列（会溢出屏幕）"
			% [node_id, btns.size()])

	ui.queue_free()
	await get_tree().process_frame
