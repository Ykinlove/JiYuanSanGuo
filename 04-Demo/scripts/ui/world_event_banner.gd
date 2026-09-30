extends CanvasLayer
class_name WorldEventBanner
## 世界事件横幅（大地图史诗感，纯演出层，零新资源）
##
## 破城 / 失地 / 名将来投 / 阵擒名将 → 全屏金字横幅，
## 视觉语言与战斗「开战横幅」同源：暗色横幅带 + 金字主标题 + 骨白副标题。
##
## 【队列播放】势力 AI 互伐可能一晚连破数城：事件先进队列逐条轮播，
## 队列上限 QUEUE_MAX，溢出丢弃最新（旧事优先播完，防刷屏）。
## 【铁律】EventBus 信号一律方法绑定连接（勿用捕获 self 的 lambda），
## 本层随场景释放，方法绑定由引擎自动断连。

const QUEUE_MAX := 3
const FADE_IN := 0.25
const HOLD := 1.6
const FADE_OUT := 0.5

var _queue: Array = []
var _playing := false
var _box: Control = null


func _ready() -> void:
	layer = 60   # 世界内容之上、ToastLayer(100) 之下
	EventBus.city_captured.connect(_on_city_captured)
	EventBus.city_lost.connect(_on_city_lost)
	EventBus.hero_recruited.connect(_on_hero_recruited)
	EventBus.prisoner_captured.connect(_on_prisoner_captured)


## ---------- 事件 → 横幅文案 ----------

func _on_city_captured(city_id: String, faction_id: String) -> void:
	var fid := int(faction_id) if faction_id.is_valid_int() else -1
	_push("攻破 「%s」" % _city_name(city_id),
		"「%s」占据此城" % FactionService.faction_name(fid))


func _on_city_lost(city_id: String, faction_id: int) -> void:
	_push("「%s」失守" % _city_name(city_id),
		"「%s」趁虚而入" % FactionService.faction_name(faction_id))


func _on_hero_recruited(hero_id: String) -> void:
	_push("名将来投", "「%s」愿效犬马之劳" % _unit_name(hero_id))


func _on_prisoner_captured(hero_id: String) -> void:
	_push("阵擒敌将", "「%s」已入囚车" % _unit_name(hero_id))


## ---------- 取名（缺数据回退原始 id，不崩不空） ----------

func _city_name(id: String) -> String:
	var c := DataManager.get_city(id)
	if c.is_empty():
		return id
	return str(c.get("name", id))


func _unit_name(id: String) -> String:
	var u := DataManager.get_unit(id)
	if u.is_empty():
		return id
	return str(u.get("name", id))


## ---------- 队列与演出 ----------

func _push(main: String, sub: String) -> void:
	if _queue.size() >= QUEUE_MAX:
		return
	_queue.append({"main": main, "sub": sub})
	if not _playing:
		_play_next()


func _play_next() -> void:
	if _queue.is_empty():
		_playing = false
		return
	_playing = true
	var item: Dictionary = _queue.pop_front()
	_show_banner(str(item["main"]), str(item["sub"]))


func _show_banner(main: String, sub: String) -> void:
	_box = Control.new()
	_box.name = "Banner"
	_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_box)

	# 暗色横幅带：全宽、竖直居中，高度 156——压住背后地图亮度保证金字可读
	var band := ColorRect.new()
	band.color = Color(0.05, 0.04, 0.03, 0.55)
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	band.anchor_left = 0.0
	band.anchor_right = 1.0
	band.anchor_top = 0.5
	band.anchor_bottom = 0.5
	band.offset_left = 0.0
	band.offset_right = 0.0
	band.offset_top = -78.0
	band.offset_bottom = 78.0
	_box.add_child(band)

	# 上下两根细金线，横幅带的「描金」收边
	for top_edge: bool in [true, false]:
		var line := ColorRect.new()
		line.color = Color(0.78, 0.64, 0.36, 0.85)
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.anchor_left = 0.0
		line.anchor_right = 1.0
		line.anchor_top = 0.5
		line.anchor_bottom = 0.5
		line.offset_left = 0.0
		line.offset_right = 0.0
		if top_edge:
			line.offset_top = -78.0
			line.offset_bottom = -76.0
		else:
			line.offset_top = 76.0
			line.offset_bottom = 78.0
		_box.add_child(line)

	# 文字盒：绕屏幕中心点自适应生长（PRESET_CENTER 必配 grow BOTH，铁律）
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.set_anchors_preset(Control.PRESET_CENTER)
	vb.grow_horizontal = Control.GROW_DIRECTION_BOTH
	vb.grow_vertical = Control.GROW_DIRECTION_BOTH
	vb.add_theme_constant_override("separation", 10)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	_box.add_child(vb)

	var main_lb := Label.new()
	main_lb.text = main
	main_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_lb.add_theme_font_size_override("font_size", 72)
	main_lb.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	main_lb.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	main_lb.add_theme_constant_override("shadow_offset_y", 3)
	vb.add_child(main_lb)

	var sub_lb := Label.new()
	sub_lb.text = sub
	sub_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_lb.add_theme_font_size_override("font_size", 28)
	sub_lb.add_theme_color_override("font_color", Color(0.92, 0.90, 0.84))
	sub_lb.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	sub_lb.add_theme_constant_override("shadow_offset_y", 2)
	vb.add_child(sub_lb)

	# 淡入 → 停留 → 淡出 → 回收 → 播下一条
	_box.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_box, "modulate:a", 1.0, FADE_IN)
	tw.tween_interval(HOLD)
	tw.tween_property(_box, "modulate:a", 0.0, FADE_OUT)
	tw.tween_callback(_on_banner_done)


func _on_banner_done() -> void:
	if _box != null and is_instance_valid(_box):
		_box.queue_free()
	_box = null
	_play_next()
