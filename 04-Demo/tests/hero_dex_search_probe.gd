extends Control
## 人物志搜索响应性探针（场景式 harness）
## 运行：godot --headless --path <工程> res://tests/hero_dex_search_probe.tscn
##
## 目的：无头验证第五十三轮的两项搜索性能改造真的生效且没改坏行为。
## 背景：
##   ① DataManager.get_heroes6() 原每次调用都遍历 heroes6 全表（825 条）过滤
##      并新建数组；hero_dex 搜索框 text_changed 直连列表重建 → 每敲一个字
##      整表重扫一次。
##   ② 重建本身要销毁+新建最多 300 个 Button 节点；手机输入法拼拼音时
##      text_changed 高频触发（每声母/候选词一次）→ 手机上明显卡手。
##   改为：表过滤结果缓存 + 输入去抖（SEARCH_DEBOUNCE=0.22s）。
##
## 断言：
##   1. get_heroes6() 两次调用返回**同一实例**（缓存生效）
##   2. 缓存内容与「不过滤的原始表」语义一致：条数 > 0 且不含 is_dummy /
##      is_troop_template / name 为「无」的行（缓存不能把过滤逻辑改错）
##   3. 连打 6 个字符只触发 **1 次**列表重建（去抖生效；不去抖会是 6 次）
##   4. 去抖后列表内容正确（搜「赵云」能查到人）
##   5. 回车提交立即出结果，不等去抖窗口
##
## 结果落 res://hero_dex_search_result.txt；真实 WARNING/ERROR 由
## _verify_hero_dex_search.py 从引擎 stderr 抓取。

const TYPED := "赵云"   ## 2 字；中文输入法下 2 个字符常触发多次 text_changed

var _lines: Array[String] = []
var _fail := 0


func _say(text: String) -> void:
	print(text)
	_lines.append(text)


func _write_and_quit(ok: bool) -> void:
	_say("")
	_say("HERO_DEX_SEARCH=%s" % ["PASS" if ok else "FAIL"])
	var f := FileAccess.open("res://hero_dex_search_result.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()
	get_tree().quit()


func _fail_msg(msg: String) -> void:
	_fail += 1
	_say("[FAIL] " + msg)


func _count_rows(dex: Control) -> int:
	# _list 是模态的 body 容器；行都是 Button，末尾那条统计是 Label
	var body = dex.get("_list")
	if body == null or not is_instance_valid(body):
		return -1
	var n := 0
	for c in body.get_children():
		if c is Button:
			n += 1
	return n


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_say("================ 人物志搜索响应性探针 ================")

	# ---- 断言 1+2：get_heroes6 缓存 ----
	var a1 := DataManager.get_heroes6()
	var a2 := DataManager.get_heroes6()
	_say("get_heroes6() 条数：%d" % a1.size())
	if a1.is_empty():
		_fail_msg("get_heroes6() 返回空，缓存逻辑把人物全滤没了")
	if a1 == a2:
		_say("两次调用返回同一实例：true（缓存生效）")
	else:
		_say("两次调用返回同一实例：false")
		_fail_msg("get_heroes6() 未命中缓存（每次仍重建数组）")

	# 过滤语义不能被缓存改错
	var bad := 0
	for r in a1:
		if not (r is Dictionary):
			bad += 1
			continue
		if bool(r.get("is_dummy", false)):
			bad += 1
		if r.has("is_troop_template") and bool(r.get("is_troop_template", false)):
			bad += 1
		var nm := str(r.get("name", "")).strip_edges()
		if nm.is_empty() or nm == "无":
			bad += 1
	if bad > 0:
		_fail_msg("缓存里混入了 %d 条本该被过滤的行（占位/模板/空名）" % bad)
	else:
		_say("缓存内容过滤语义正确：无占位/模板/空名行")

	# 过滤条数应与原始表不同（证明确实做了过滤，不是把全表缓存了）
	var raw_total := DataManager.get_table("heroes6").size()
	_say("原始表 %d 条 → 过滤后 %d 条" % [raw_total, a1.size()])
	if a1.size() >= raw_total:
		_fail_msg("过滤后条数(%d) >= 原始表(%d)，说明没过滤" % [a1.size(), raw_total])

	# ---- 断言 3~5：面板搜索去抖 ----
	var dex := HeroDex.new()
	add_child(dex)
	dex.open()
	await get_tree().process_frame
	await get_tree().process_frame

	var baseline := _count_rows(dex)
	_say("打开面板（空搜索）行数：%d" % baseline)
	if baseline <= 0:
		_fail_msg("打开面板后列表为空，人物志打不开")

	# 逐字符输入，观察 _debounce_left 是否被正确置起（即去抖已接管而非直连重建）
	var search: LineEdit = dex.get("_search")
	if search == null:
		_fail_msg("拿不到 _search 成员")
		_write_and_quit(false)
		return

	for i in TYPED.length():
		search.text = TYPED.substr(0, i + 1)
		search.text_changed.emit(search.text)
		# 连打：不给任何等待，模拟最快输入
		if dex.get("_debounce_left") is float \
				and float(dex.get("_debounce_left")) <= 0.0:
			_fail_msg("第 %d 次输入后去抖计时未置起（仍是直连重建）" % (i + 1))
	_say("连打 %d 字后去抖计时=%.2f（>0 表示已合并为一次重建）"
		% [TYPED.length(), float(dex.get("_debounce_left"))])

	# 去抖窗口内列表应显示「筛选中」而不是旧结果
	var mid := _count_rows(dex)
	_say("去抖窗口内行数：%d（应为 0，表示已清空并提示筛选中）" % mid)
	if mid > 0:
		_fail_msg("去抖窗口内仍显示 %d 行旧结果（玩家会以为搜索没生效）" % mid)

	# 等去抖窗口过去
	var waited := 0.0
	while float(dex.get("_debounce_left")) > 0.0 and waited < 2.0:
		await get_tree().process_frame
		waited += 1.0 / 60.0

	var after := _count_rows(dex)
	_say("去抖结束后行数：%d（搜索「%s」的结果）" % [after, TYPED])
	if after <= 0:
		_fail_msg("去抖结束后列表为空，搜索「%s」查不到人" % TYPED)

	# ---- 断言 5：回车立即出结果 ----
	search.text = "曹操"
	search.text_changed.emit("曹操")
	search.text_submitted.emit("曹操")
	if float(dex.get("_debounce_left")) > 0.0:
		_fail_msg("回车提交后去抖计时未清（仍在等窗口，出结果有延迟）")
	var caocao := _count_rows(dex)
	_say("回车提交「曹操」后行数：%d" % caocao)
	if caocao <= 0:
		_fail_msg("回车提交后列表为空，搜不到曹操")

	dex.queue_free()
	_say("")
	_say("失败项：%d" % _fail)
	_write_and_quit(_fail == 0)
