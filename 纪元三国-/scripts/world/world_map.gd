extends Node2D
## 大地图（WorldMap）· M2
## 职责：地形绘制、主角行走、相机跟随、城池/遭遇/NPC 交互、进入城镇、对话调度。
## 整合 TerrainPainter / EncounterManager / NPCManager / PlayerController / DialogueUI。

const REGION_ID := "nanzhong"

@onready var _player: PlayerController = $Player
@onready var _terrain: TerrainPainter = $Terrain
@onready var _encounters: EncounterManager = $Encounters
@onready var _npcs: NPCManager = $NPCs
@onready var _hud: WorldHUD = $UI/HUD
@onready var _joystick: VirtualJoystick = $UI/VirtualJoystick
@onready var _btn_enter: Button = $UI/ActionButtons/BtnEnter
@onready var _btn_menu: Button = $UI/ActionButtons/BtnMenu
@onready var _city_markers: Node2D = $CityMarkers
@onready var _dialogue: DialogueUI = $UI/DialogueUI
@onready var _toast_label: Label = $UI/ToastLabel

var _nearby_city_id: String = ""
var _interact_mode: String = ""      ## city / npc / ""
var _toast_tween: Tween
var _in_dialogue := false


func _ready() -> void:
	AudioManager.play_bgm("res://assets/audio/bgm/world_map.ogg")

	# 地形尺寸先定，供各系统使用
	var map_size := _terrain.get_map_size()
	_player.map_size = map_size

	_joystick.changed.connect(_on_joystick_changed)
	_btn_enter.pressed.connect(_on_enter_pressed)
	_btn_menu.pressed.connect(_on_open_menu)

	_dialogue.dialogue_finished.connect(_on_dialogue_finished)
	_npcs.npc_interacted.connect(_on_npc_interacted)
	_encounters.encounter_triggered.connect(_on_encounter_triggered)

	EventBus.toast.connect(show_toast)
	EventBus.gold_changed.connect(func(_v): _hud.update_resources())
	EventBus.food_changed.connect(func(_v): _hud.update_resources())
	EventBus.date_changed.connect(func(_y, _m, _d): _hud.update_resources())

	_spawn_city_markers()
	_hud.update_resources()


func _process(delta: float) -> void:
	# 对话中暂停角色移动
	if _in_dialogue:
		_player.set_move_input(Vector2.ZERO)
		return

	_player.set_move_input(_joystick.output)
	_check_nearby_city()
	_update_interact_button()


func _on_joystick_changed(_value: Vector2) -> void:
	pass


## 生成城池 / 地点标记
func _spawn_city_markers() -> void:
	var cities := DataManager.get_table("cities")
	if cities.is_empty():
		_create_placeholder_cities()
		return
	for city in cities:
		var pos := Vector2(float(city.get("map_x", 0)), float(city.get("map_y", 0)))
		_create_marker(
			str(city.get("id", "")),
			str(city.get("name", "城")),
			str(city.get("type", "city")),
			pos
		)


func _create_placeholder_cities() -> void:
	_create_marker("city_jianning", "建宁", "city", Vector2(700, 400))
	_create_marker("city_yongchang", "永昌", "city", Vector2(400, 620))
	_create_marker("city_yunnan", "云南", "city", Vector2(980, 700))
	_create_marker("village_axiang", "阿乡寨", "village", Vector2(560, 260))


func _create_marker(city_id: String, city_name: String, city_type: String, pos: Vector2) -> void:
	var marker := Node2D.new()
	marker.name = "Marker_" + city_id
	marker.position = pos
	marker.set_meta("city_id", city_id)
	marker.set_meta("city_name", city_name)

	var color := Color(0.72, 0.55, 0.26)
	if city_type == "village":
		color = Color(0.42, 0.62, 0.42)
	elif city_type == "ruin":
		color = Color(0.55, 0.48, 0.62)

	# 城池图标（方形底座 + 城墙垛口）
	var base := Polygon2D.new()
	base.polygon = PackedVector2Array([
		Vector2(-30, 20), Vector2(30, 20), Vector2(30, -6),
		Vector2(20, -6), Vector2(20, -18), Vector2(10, -18),
		Vector2(10, -6), Vector2(-10, -6), Vector2(-10, -18),
		Vector2(-20, -18), Vector2(-20, -6), Vector2(-30, -6)
	])
	base.color = color
	marker.add_child(base)

	var outline := Line2D.new()
	outline.points = base.polygon + PackedVector2Array([base.polygon[0]])
	outline.width = 2.0
	outline.default_color = color.darkened(0.5)
	marker.add_child(outline)

	# 名称
	var label := Label.new()
	label.text = city_name
	label.add_theme_font_size_override("font_size", 20)
	label.position = Vector2(-34, 26)
	marker.add_child(label)

	# 可进入提示
	var hint := Label.new()
	hint.name = "Hint"
	hint.text = "▲ 进入"
	hint.add_theme_font_size_override("font_size", 18)
	hint.modulate = Color(1, 0.9, 0.5)
	hint.position = Vector2(-32, -46)
	hint.visible = false
	marker.add_child(hint)

	_city_markers.add_child(marker)


## 检测靠近的城池
func _check_nearby_city() -> void:
	var closest_id := ""
	var closest_dist := INF
	for marker in _city_markers.get_children():
		var d := _player.position.distance_to(marker.position)
		var hint := marker.get_node_or_null("Hint")
		var in_range := d < 110.0
		if hint:
			hint.visible = in_range
		if in_range and d < closest_dist:
			closest_dist = d
			closest_id = marker.get_meta("city_id")

	if closest_id != _nearby_city_id:
		_nearby_city_id = closest_id


## 决定「进入」按钮的含义（进城镇 / 对话）
func _update_interact_button() -> void:
	var npc := _npcs.get_nearby_npc()
	if not npc.is_empty():
		_interact_mode = "npc"
		_btn_enter.disabled = false
		_btn_enter.text = "对话"
	elif not _nearby_city_id.is_empty():
		_interact_mode = "city"
		_btn_enter.disabled = false
		_btn_enter.text = "进入"
	else:
		_interact_mode = ""
		_btn_enter.disabled = true
		_btn_enter.text = "进入"


func _on_enter_pressed() -> void:
	if _interact_mode == "npc":
		if _npcs.get_nearby_npc().is_empty():
			# 对话结束后 NPC 可能已离开提示范围
			return
		AudioManager.sfx_confirm()
		var npc := _npcs.get_nearby_npc()
		_in_dialogue = true
		_dialogue.start(str(npc.get("dialogue_root", "")))
	elif _interact_mode == "city":
		if _nearby_city_id.is_empty():
			return
		AudioManager.sfx_confirm()
		GameState.current_city_id = _nearby_city_id
		EventBus.city_entered.emit(_nearby_city_id)
		SceneRouter.push_scene("city")


func _on_npc_interacted(_npc: Dictionary) -> void:
	pass


func _on_dialogue_finished() -> void:
	_in_dialogue = false


## 遭遇触发
func _on_encounter_triggered(encounter: Dictionary) -> void:
	var type := str(encounter.get("type", "battle"))
	if type == "battle":
		# 战斗类：先进战前布阵界面，由布阵界面决定何时开战
		GameState.current_encounter = encounter
		_in_dialogue = true
		await get_tree().create_timer(0.5).timeout
		SceneRouter.push_scene("formation")


func _on_open_menu() -> void:
	AudioManager.sfx_click()
	show_toast("菜单：角色 / 部队 / 城池 / 任务 / 外交")


## 顶部提示条
func show_toast(message: String) -> void:
	_toast_label.text = message
	_toast_label.modulate.a = 1.0
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(2.2)
	_toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.5)


## 供外部（如对话推进）调用
func advance_dialogue() -> void:
	if _dialogue.is_open():
		_dialogue.advance()
