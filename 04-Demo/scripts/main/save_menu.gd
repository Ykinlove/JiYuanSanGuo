extends Control
class_name SaveMenu
## 存档菜单（SaveMenu）
## 职责：展示存档槽列表，支持存/读/删。
## 入口：主菜单「读取存档」、游戏内系统面板「保存/读取存档」。
## SceneRouter.goto 不传参，故用静态字段传递「模式 + 返回场景」，由 open_as 统一设置。

## load / save（进入场景时读取，随后复位）
static var pending_mode: String = "load"
## 返回目标场景 key
static var pending_return: String = "main_menu"

@onready var _slot_list: VBoxContainer = %SlotList
@onready var _btn_back: Button = %BtnBack
@onready var _title: Label = %TitleLabel

var _mode: String = "load"   ## load / save


## 以指定模式打开存档菜单（供主菜单 / 游戏内系统面板调用）
static func open_as(mode: String, return_scene: String = "main_menu") -> void:
	pending_mode = mode
	pending_return = return_scene
	SceneRouter.goto("save_menu")


func _ready() -> void:
	var back_target := pending_return
	_mode = pending_mode
	pending_mode = "load"
	pending_return = "main_menu"

	_btn_back.pressed.connect(func():
		AudioManager.sfx_click()
		SceneRouter.goto(back_target)
	)
	_title.text = "读取存档" if _mode == "load" else "保存存档"
	_refresh()


func _refresh() -> void:
	for child in _slot_list.get_children():
		child.queue_free()

	var slots := SaveManager.get_save_slots()
	for info in slots:
		# 保存模式下不展示自动存档槽（自动存档由系统写入）
		if _mode == "save" and info["is_auto"]:
			continue
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
			SceneRouter.goto_fresh("world")   # 入世入口：清空菜单残留历史（R1-02）
	else:
		if SaveManager.save_game(slot):
			_refresh()
