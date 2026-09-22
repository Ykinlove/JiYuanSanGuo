extends Control
## 存档菜单（SaveMenu）
## 职责：展示存档槽列表，支持存/读/删。

@onready var _slot_list: VBoxContainer = %SlotList
@onready var _btn_back: Button = %BtnBack
@onready var _title: Label = %TitleLabel

var _mode: String = "load"   ## load / save


func _ready() -> void:
	_btn_back.pressed.connect(func():
		AudioManager.sfx_click()
		SceneRouter.goto("main_menu")
	)
	_title.text = "读取存档"
	_refresh()


func _refresh() -> void:
	for child in _slot_list.get_children():
		child.queue_free()

	var slots := SaveManager.get_save_slots()
	for info in slots:
		_slot_list.add_child(_make_slot_row(info))


func _make_slot_row(info: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 96)
	row.add_theme_constant_override("separation", 20)

	var slot_no: int = info["slot"]
	var label_text := "自动存档" if info["is_auto"] else "存档 %d" % slot_no

	var name_btn := Button.new()
	name_btn.custom_minimum_size = Vector2(760, 96)
	name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_btn.add_theme_font_size_override("font_size", 26)
	if info["exists"]:
		name_btn.text = "%s　·　%s　Lv.%d　·　%s" % [
			label_text, info["player_name"], info["level"], info["date_text"]
		]
	else:
		name_btn.text = "%s　·　空" % label_text
		name_btn.disabled = _mode == "load"
	name_btn.pressed.connect(func(): _on_slot_pressed(slot_no, info["exists"]))
	row.add_child(name_btn)

	if info["exists"] and not info["is_auto"]:
		var del_btn := Button.new()
		del_btn.custom_minimum_size = Vector2(140, 96)
		del_btn.add_theme_font_size_override("font_size", 24)
		del_btn.text = "删除"
		del_btn.pressed.connect(func():
			SaveManager.delete_save(slot_no)
			_refresh()
		)
		row.add_child(del_btn)

	return row


func _on_slot_pressed(slot: int, exists: bool) -> void:
	AudioManager.sfx_confirm()
	if _mode == "load":
		if SaveManager.load_game(slot):
			SceneRouter.push_scene("world")
	else:
		if SaveManager.save_game(slot):
			_refresh()
