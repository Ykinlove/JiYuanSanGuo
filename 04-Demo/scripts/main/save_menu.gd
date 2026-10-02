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

## 删除确认弹窗（B10，与大地图/城内同一套 sub-modal 视觉）
var _del_confirm: Control = null
var _pending_del_slot: int = -1
## 【第六十一轮·防误触】覆盖确认弹窗。
## 原缺口：删除有二次确认，但**覆盖已存在的存档一点即过**——
## 而覆盖的代价（丢掉一整局进度）与删档等价，同屏两个按钮却一个拦一个放行。
var _ovr_confirm: Control = null
var _pending_ovr_slot: int = -1
## 覆盖确认时展示的旧档摘要（存疑信息快照，避免确认态与列表行出现两个版本）
var _ovr_old_name := ""
var _ovr_old_level := 0
var _ovr_old_date := ""


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
	# 存已有档 → 走覆盖二次确认（不可逆），故把info 快照传下去供弹窗展示
	name_btn.pressed.connect(func(): _on_slot_pressed(slot_no, info["exists"], info))
	row.add_child(name_btn)

	if info["exists"] and not info["is_auto"]:
		var del_btn := Button.new()
		del_btn.custom_minimum_size = Vector2(140, 96)
		del_btn.add_theme_font_size_override("font_size", 24)
		del_btn.text = "删除"
		del_btn.pressed.connect(func(): _show_del_confirm(slot_no))
		row.add_child(del_btn)

	return row


## 删除确认弹窗（B10：误触即永久丢档，二次确认拦截）
func _show_del_confirm(slot_no: int) -> void:
	if _del_confirm != null:
		return
	_pending_del_slot = slot_no
	var m := UITheme.make_sub_modal(self, "删除存档？",
		_close_del_confirm, Vector2(760, 440))
	_del_confirm = m["dim"]
	var body: VBoxContainer = m["body"]
	var tip := UITheme.label(
		"该存档将被永久删除，删除后无法找回。确定删除吗？",
		UITheme.FS_BODY, UITheme.TEXT)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(tip)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 28)
	var cancel := UITheme.button("再想想", UITheme.FS_BODY, Vector2(240, 84))
	cancel.pressed.connect(func():
		AudioManager.sfx_click()
		_close_del_confirm())
	var ok := UITheme.button("确认删除", UITheme.FS_BODY, Vector2(240, 84))
	ok.pressed.connect(func():
		AudioManager.sfx_confirm()
		var slot := _pending_del_slot
		_close_del_confirm()
		if slot >= 0:
			SaveManager.delete_save(slot)
			_refresh())
	row.add_child(cancel)
	row.add_child(ok)
	body.add_child(row)


func _close_del_confirm() -> void:
	if _del_confirm != null and is_instance_valid(_del_confirm):
		_del_confirm.queue_free()
	_del_confirm = null
	_pending_del_slot = -1


func _on_slot_pressed(slot: int, exists: bool, info: Dictionary = {}) -> void:
	AudioManager.sfx_confirm()
	if _mode == "load":
		if SaveManager.load_game(slot):
			SceneRouter.goto_fresh("world")   # 入世入口：清空菜单残留历史（R1-02）
		return
	# 【第六十一轮·防误触】保存模式：覆盖已存在的档必须二次确认。
	# 覆盖不可逆（旧进度永久丢失），代价与删档等价 —— 删除有拦截而覆盖没有，
	# 是同屏两个按钮行为不一致的真实缺口。空槽直达，不平白加步骤。
	if exists:
		_show_overwrite_confirm(slot, info)
		return
	if SaveManager.save_game(slot):
		_refresh()


## 【第六十一轮】覆盖已存在存档的二次确认。
## 与 _show_del_confirm 同一套sub-modal 视觉；文案里的旧档信息取**入参快照**，
## 不在确认态重查 SaveManager —— 否则列表刷新后同一弹窗会显示两个版本的旧档信息。
func _show_overwrite_confirm(slot_no: int, info: Dictionary = {}) -> void:
	if _ovr_confirm != null:
		return
	_pending_ovr_slot = slot_no
	_ovr_old_name = str(info.get("player_name", "未知角色"))
	_ovr_old_level = int(info.get("level", 1))
	_ovr_old_date = str(info.get("date_text", ""))

	var m := UITheme.make_sub_modal(self, "覆盖存档？",
		_close_overwrite_confirm, Vector2(760, 520))
	_ovr_confirm = m["dim"]
	var body: VBoxContainer = m["body"]

	var tip := UITheme.label(
		"存档 %d 已有进度：%s　Lv.%d　%s。\n覆盖后旧进度永久丢失，无法找回。"
		% [slot_no, _ovr_old_name, _ovr_old_level, _ovr_old_date],
		UITheme.FS_BODY, UITheme.TEXT)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(tip)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 28)
	# 撤销放左（拇指高频区留给撤销），与删档确认一致
	var cancel := UITheme.button("再想想", UITheme.FS_BODY, Vector2(240, 84))
	cancel.pressed.connect(func():
		AudioManager.sfx_click()
		_close_overwrite_confirm())
	var ok := UITheme.button("确认覆盖", UITheme.FS_BODY, Vector2(240, 84))
	ok.pressed.connect(func():
		AudioManager.sfx_confirm()
		var slot := _pending_ovr_slot
		_close_overwrite_confirm()
		if slot >= 0 and SaveManager.save_game(slot):
			_refresh())
	row.add_child(cancel)
	row.add_child(ok)
	body.add_child(row)


func _close_overwrite_confirm() -> void:
	if _ovr_confirm != null and is_instance_valid(_ovr_confirm):
		_ovr_confirm.queue_free()
	_ovr_confirm = null
	_pending_ovr_slot = -1
