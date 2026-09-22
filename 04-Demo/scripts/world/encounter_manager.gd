extends Node2D
class_name EncounterManager
## 遭遇管理器（EncounterManager）
## 职责：在大地图上生成遭遇物（战斗/商队/宝箱/采集），处理踩踏触发与结算。
## 遭遇物挂在世界坐标上，随相机滚动。已触发的非采集类遭遇会消失。

signal encounter_triggered(encounter: Dictionary)

const INTERACT_RADIUS := 60.0
const ENC_TEX_DIR := "res://assets/sprites/encounters/"
## 有类型的扩展名候选表：避免 for 循环变量退化为 Variant（会导致 := 无法推断类型）
const TEX_EXT_CANDIDATES: Array[String] = [".png", ".webp", ".jpg"]

@export var region_id: String = "nanzhong"
@export var map_size: Vector2 = Vector2(2400, 1400)
@export var spawn_count: int = 26
@export var rng_seed: int = 20260922

var _encounters_table: Array = []
var _rng := RandomNumberGenerator.new()
var _player: Node2D
var _triggered_ids := {}
var _gather_counts := {}     ## 每日采集计数：enc_id -> count
var _current_day := 0


func _ready() -> void:
	_rng.seed = rng_seed
	_encounters_table = DataManager.get_table("encounters")
	_player = get_parent().get_node_or_null("Player")
	EventBus.day_passed.connect(_on_day_passed)
	_spawn_all()


## 当前区域可用的遭遇定义
func _available_defs() -> Array:
	var result: Array = []
	for e in _encounters_table:
		var regions: Array = e.get("regions", [])
		if regions.is_empty() or region_id in regions:
			result.append(e)
	return result


## 生成全部遭遇物
func _spawn_all() -> void:
	var defs := _available_defs()
	if defs.is_empty():
		return
	# 按权重构建取样池
	var pool: Array = []
	for d in defs:
		for i in range(int(d.get("weight", 10))):
			pool.append(d)

	# 生成数量按地图面积自适应（大地图要铺得开，但不能密到走两步一次）
	# 13000×8000 → 约 115 个；小图仍按 spawn_count 保底
	var count := clampi(int(map_size.x * map_size.y / 900000.0), spawn_count, 140)
	var tries := 0
	var placed := 0
	while placed < count and tries < count * 12:
		tries += 1
		var def: Dictionary = pool[_rng.randi_range(0, pool.size() - 1)]
		var pos := Vector2(
			_rng.randf_range(120, map_size.x - 120),
			_rng.randf_range(120, map_size.y - 120)
		)
		# 避开城池标记附近
		if _too_close_to_city(pos):
			continue
		# 避开已有遭遇，避免挤成一堆
		if _too_close_to_encounter(pos):
			continue
		# 跳过本局已解决的遭遇（战斗/宝箱/商队）。EncounterManager 随 world_map 重载时
		# _triggered_ids 会清空，但若不跳过，遭遇物会用固定种子在原位重生，而玩家撤离后
		# 仍在原地，下一帧立刻再次触发，形成「撤退/打完又进战斗」的死循环。
		var enc_id := "%s_%d_%d" % [str(def.get("id", "e")), int(pos.x), int(pos.y)]
		if GameState.encounter_resolved.has(enc_id):
			continue
		_spawn_one(def, pos, enc_id)
		placed += 1


func _too_close_to_encounter(pos: Vector2) -> bool:
	for node in get_children():
		if node is Node2D:
			if pos.distance_to(node.position) < 220.0:
				return true
	return false


func _too_close_to_city(pos: Vector2) -> bool:
	var cities := DataManager.get_table("cities")
	for c in cities:
		var cp := Vector2(float(c.get("map_x", 0)), float(c.get("map_y", 0)))
		if pos.distance_to(cp) < 180.0:
			return true
	return false


func _spawn_one(def: Dictionary, pos: Vector2, id: String) -> void:
	var node := Node2D.new()
	node.name = "Enc_" + id
	node.position = pos
	node.set_meta("enc_def", def)
	node.set_meta("enc_id", id)
	add_child(node)

	# 图标：优先用美术贴图，缺失时回退几何菱形
	var tex := _get_enc_icon(str(def.get("id", "")))
	if tex:
		var sp := Sprite2D.new()
		sp.texture = tex
		sp.position = Vector2(0, -22)
		node.add_child(sp)
		# 贴图下方淡色底衬，保证复杂地形上可辨识
		var halo := _make_diamond(Color(0, 0, 0, 0.18))
		halo.scale = Vector2(1.15, 1.15)
		node.add_child(halo)
		node.move_child(halo, node.get_child_count() - 2)
	else:
		var color := Color(def.get("icon_color", "#FFFFFF"))
		var icon := _make_diamond(color)
		node.add_child(icon)

	# 名称
	var label := Label.new()
	label.text = str(def.get("name", ""))
	label.add_theme_font_size_override("font_size", 18)
	label.position = Vector2(-36, 26)
	label.modulate = Color(1, 1, 1, 0.85)
	node.add_child(label)


## 尝试加载遭遇图标贴图（res://assets/sprites/encounters/<id>.png）
func _get_enc_icon(enc_id: String) -> Texture2D:
	if enc_id.is_empty():
		return null
	for ext in TEX_EXT_CANDIDATES:
		var path: String = ENC_TEX_DIR + enc_id + ext
		if ResourceLoader.exists(path):
			var res := load(path)
			if res is Texture2D:
				return res
	return null


func _make_diamond(color: Color) -> Polygon2D:
	var poly := Polygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(0, -18), Vector2(18, 0), Vector2(0, 18), Vector2(-18, 0)
	])
	poly.color = color
	# 描边
	var outline := Line2D.new()
	outline.points = PackedVector2Array([
		Vector2(0, -18), Vector2(18, 0), Vector2(0, 18), Vector2(-18, 0), Vector2(0, -18)
	])
	outline.width = 2.0
	outline.default_color = color.darkened(0.4)
	poly.add_child(outline)
	return poly


func _process(_delta: float) -> void:
	if _player == null:
		return
	for node in get_children():
		if not (node is Node2D) or not node.has_meta("enc_def"):
			continue
		var enc_id: String = node.get_meta("enc_id")
		if _triggered_ids.has(enc_id):
			continue
		if _player.position.distance_to(node.position) < INTERACT_RADIUS:
			_trigger(node)


## 触发遭遇
func _trigger(node: Node2D) -> void:
	var def: Dictionary = node.get_meta("enc_def")
	var enc_id: String = node.get_meta("enc_id")
	var type := str(def.get("type", "battle"))

	match type:
		"gather":
			_handle_gather(node, def, enc_id)
		"treasure":
			_handle_treasure(node, def, enc_id)
		"event":
			_handle_event(node, def, enc_id)
		"merchant":
			_handle_merchant(node, def)
			_triggered_ids[enc_id] = true      # 商队触发一次后暂时消失
			GameState.encounter_resolved[enc_id] = true
			_hide(node)
		_:
			# 战斗类
			_triggered_ids[enc_id] = true
			GameState.encounter_resolved[enc_id] = true   # 标记已解决，跨场景重载不再原地重生
			_hide(node)
			encounter_triggered.emit(def)
			EventBus.show_toast("遭遇 %s！" % def.get("name", "敌人"))


func _handle_gather(node: Node2D, def: Dictionary, enc_id: String) -> void:
	var limit := int(def.get("daily_limit", 5))
	var used := int(_gather_counts.get(enc_id, 0))
	# 无论采到还是已采完，都先解除本帧触发（否则站在点上会每帧连采/连弹提示）
	_triggered_ids[enc_id] = true
	if used >= limit:
		EventBus.show_toast("此处今日已采完，明日再来")
		return
	_gather_counts[enc_id] = used + 1

	var item_id := str(def.get("gather_item", ""))
	var count := int(def.get("gather_count", 1))
	GameState.add_item(item_id, count)
	# 任务记账：采集物本身计 collect；采集点可用 quest_event 计特殊事件（如 fish）
	if not item_id.is_empty():
		QuestService.record_event("collect", item_id, count)
	var qev := str(def.get("quest_event", ""))
	if not qev.is_empty():
		QuestService.record_event(qev, str(def.get("quest_target", "any")), count)
	var item := DataManager.get_item(item_id)
	var item_name := str(item.get("name", item_id)) if not item.is_empty() else item_id

	EventBus.show_toast("采集到 %s ×%d（今日 %d/%d）" % [item_name, count, used + 1, limit])
	encounter_triggered.emit(def)


func _handle_treasure(node: Node2D, def: Dictionary, enc_id: String) -> void:
	_triggered_ids[enc_id] = true
	GameState.encounter_resolved[enc_id] = true
	_hide(node)

	var loot: Array = def.get("loot_table", [])
	if loot.is_empty():
		EventBus.show_toast("箱子是空的")
		return
	var pick: String = str(loot[_rng.randi_range(0, loot.size() - 1)])
	GameState.add_item(pick, 1)
	QuestService.record_event("collect", pick, 1)
	var item := DataManager.get_item(pick)
	var item_name := str(item.get("name", pick)) if not item.is_empty() else pick
	EventBus.show_toast("打开宝箱，获得：%s（已入背包）" % item_name)
	encounter_triggered.emit(def)


func _handle_merchant(node: Node2D, def: Dictionary) -> void:
	EventBus.show_toast("遇到行商，打开交易")
	encounter_triggered.emit(def)


## 随机事件：一次性结算（跨场景重载不复活），弹选项由 world_map 承接
func _handle_event(node: Node2D, def: Dictionary, enc_id: String) -> void:
	_triggered_ids[enc_id] = true
	GameState.encounter_resolved[enc_id] = true
	_hide(node)
	encounter_triggered.emit(def)


func _hide(node: Node2D) -> void:
	node.visible = false
	node.set_process(false)


## 每日重置采集计数
func _on_day_passed(_y: int, _m: int, d: int) -> void:
	if d != _current_day:
		_current_day = d
		_gather_counts.clear()
		_respawn_daily()


## 每日重新生成部分遭遇（保持世界活力）
## 采集点次日恢复可交互（战斗/宝箱已解决的不复活）
func _respawn_daily() -> void:
	for node in get_children():
		if not (node is Node2D) or not node.has_meta("enc_def"):
			continue
		var def: Dictionary = node.get_meta("enc_def")
		if str(def.get("type", "")) != "gather":
			continue
		var enc_id: String = node.get_meta("enc_id")
		_triggered_ids.erase(enc_id)


## 获取当前所有未触发遭遇的位置（供小地图使用）
func get_active_markers() -> Array:
	var result: Array = []
	for node in get_children():
		if node is Node2D and node.has_meta("enc_def") and node.visible:
			result.append({"position": node.position, "def": node.get_meta("enc_def")})
	return result
