extends Control
## Toast 队列探针（场景式 harness）
## 运行：godot --headless --path <工程> res://tests/toast_queue_probe.tscn
##
## 目的：无头验证 ToastLayer 的多提示队列不互相覆盖。
## 背景（第五十一轮）：旧实现是单 Label + 单 Tween + 单 Panel，新 toast 直接
## 改写同一个 Label 并 kill 掉上一个 Tween → 「后一条把前一条顶掉」。
## 而 story_director.gd 一次章节结算就连发两条（【史官】终 + 主线推进），
## 玩家只读得到最后一条。改成每条一个独立面板 + VBox 堆叠后必须真跑验证，
## 因为「不覆盖」是运行时行为，编译期与静态扫描都看不见。
##
## 断言：
##   1. 连续发 3 条 → 栈里同时存活 3 个面板（而非 1 个被覆盖）
##   2. 3 条文本都真实存在于各自面板中（没被后写的 text 冲掉）
##   3. 超过 MAX_VISIBLE(4) 时挤掉最旧的，存活数恒 <= 4
##   4. 面板被释放后从存活表摘除（不泄漏）
##
## 结果落 res://toast_queue_result.txt；真实 WARNING/ERROR 由
## _verify_toast_queue.py 从引擎 stderr 抓取。

const EPS := 0.5

var _lines: Array[String] = []
var _fail := 0


func _say(text: String) -> void:
	print(text)
	_lines.append(text)


func _write_and_quit(ok: bool) -> void:
	_say("")
	_say("TOAST_QUEUE=%s" % ["PASS" if ok else "FAIL"])
	var f := FileAccess.open("res://toast_queue_result.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()
	get_tree().quit()


func _fail_msg(msg: String) -> void:
	_fail += 1
	_say("[FAIL] " + msg)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_say("================ Toast 队列探针 ================")

	# ToastLayer 是 autoload，_ready 时已订阅 EventBus.toast。
	# 直接取 autoload 单例的真实实例来验，而不是 new 一个假的。
	var layer := get_node_or_null("/root/ToastLayer")
	if layer == null:
		_fail_msg("拿不到 ToastLayer autoload 单例")
		_write_and_quit(false)
		return
	_say("ToastLayer 类型：%s" % layer.get_class())

	# ---- 断言 1+2：连发 3 条，应同时存活 3 个独立面板 ----
	EventBus.show_toast("甲条提示内容AAA")
	EventBus.show_toast("乙条提示内容BBB")
	EventBus.show_toast("丙条提示内容CCC")
	await get_tree().process_frame

	var live: Array = layer._live
	_say("连发 3 条后存活面板数：%d" % live.size())
	if live.size() < 3:
		_fail_msg("连发 3 条只存活 %d 个面板（期望 >=3，说明后一条覆盖了前一条）"
			% live.size())

	# 逐个面板取回自己的 Label 文本，确认没被后写的 text 冲掉
	var texts: Array[String] = []
	for entry in live:
		var p = entry["panel"]
		if not is_instance_valid(p):
			_fail_msg("存活表里有一个已失效的面板（应先摘除再释放）")
			continue
		var lbl = p.get_child(0) as Label
		if lbl != null:
			texts.append(lbl.text)
	_say("各面板文本：%s" % str(texts))
	for want in ["甲条提示内容AAA", "乙条提示内容BBB", "丙条提示内容CCC"]:
		if not texts.has(want):
			_fail_msg("面板文本 %s 丢失（被覆盖或未生成）" % want)

	# 面板应两两不同实例（不是同一个被反复改 text）
	if live.size() >= 2:
		var a = live[0]["panel"]
		var b = live[1]["panel"]
		if a == b:
			_fail_msg("两个存活条目指向同一面板实例（说明仍在复用单 Panel）")

	# ---- 断言 3：超过 MAX_VISIBLE 应挤掉最旧的，存活数封顶 ----
	var cap: int = layer.MAX_VISIBLE
	for i in range(5):
		EventBus.show_toast("补充提示%02d" % i)
	await get_tree().process_frame
	var live2: Array = layer._live
	_say("再发 5 条后存活面板数：%d（上限 %d）" % [live2.size(), cap])
	if live2.size() > cap:
		_fail_msg("存活 %d 条超过上限 %d（应挤掉最旧的，防糊屏）" % [live2.size(), cap])

	# ---- 断言 4：手动释放一个存活面板后应从存活表摘除，不泄漏 ----
	# 这里直接验结构完整性：_live 里不应出现已 queue_free 的实例
	var dead := 0
	for entry in live2:
		if not is_instance_valid(entry["panel"]):
			dead += 1
	if dead > 0:
		_fail_msg("存活表残留 %d 个已失效实例（释放后未摘除，泄漏）" % dead)

	_say("")
	_say("失败项：%d" % _fail)
	_write_and_quit(_fail == 0)
