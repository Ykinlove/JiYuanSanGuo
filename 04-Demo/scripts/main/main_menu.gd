extends Control
## 主菜单（MainMenu）

@onready var _btn_new: Button = %BtnNewGame
@onready var _btn_continue: Button = %BtnContinue
@onready var _btn_load: Button = %BtnLoad
@onready var _btn_settings: Button = %BtnSettings
@onready var _btn_quit: Button = %BtnQuit
@onready var _version_label: Label = %VersionLabel

var _settings: SettingsPanel
var _new_game_confirm: Control = null   ## 「新的征程」覆盖确认弹窗（P0-5）


func _ready() -> void:
	_version_label.text = "v" + str(ProjectSettings.get_setting("application/config/version", "0.0.0")) + " 内测版"
	_btn_continue.disabled = not SaveManager.has_any_save()
	# 【P4】主菜单显式挂 BGM：从大地图/城内退回时旧曲被切走，不再无人叫停地循环
	AudioManager.play_bgm("res://assets/audio/bgm/main_menu.ogg")

	# 系统设置面板（代码创建，与大地图/城池共用同一脚本）
	_settings = SettingsPanel.new()
	_settings.name = "SettingsPanel"
	add_child(_settings)

	_btn_new.pressed.connect(_on_new_game)
	_btn_continue.pressed.connect(_on_continue)
	_btn_load.pressed.connect(_on_load)
	_btn_settings.pressed.connect(_on_settings)
	_btn_quit.pressed.connect(_on_quit)


## 新开一局：先走「新建角色」三步流程（姓名/性别 → 四维 → 天赋），
## 由 create_hero 落 GameState 并存档后再进大地图。
## 这里不 push 历史（用 goto），避免从大地图 back() 时退回创建界面。
func _on_new_game() -> void:
	AudioManager.sfx_confirm()
	# 【P0-5】已有存档时先确认：新对局会覆盖自动存档，旧进度无法找回
	if SaveManager.has_any_save():
		_show_new_game_confirm()
		return
	SceneRouter.goto("create_hero")


## 覆盖确认弹窗（与大地图/城内同一套 sub-modal 视觉）
func _show_new_game_confirm() -> void:
	if _new_game_confirm != null:
		return
	var m := UITheme.make_sub_modal(self, "开创新的征程？",
		_close_new_game_confirm, Vector2(760, 440))
	_new_game_confirm = m["dim"]
	var body: VBoxContainer = m["body"]
	var tip := UITheme.label(
		"检测到已有存档（含自动存档）。开启新的征程后，自动存档将被新对局覆盖，旧进度无法找回。",
		UITheme.FS_BODY, UITheme.TEXT)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(tip)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 28)
	var cancel := UITheme.button("再想想", UITheme.FS_BODY, Vector2(240, 84))
	cancel.pressed.connect(func():
		AudioManager.sfx_click()
		_close_new_game_confirm())
	var ok := UITheme.button("仍要开创", UITheme.FS_BODY, Vector2(240, 84))
	ok.pressed.connect(func():
		AudioManager.sfx_confirm()
		_close_new_game_confirm()
		SceneRouter.goto("create_hero"))
	row.add_child(cancel)
	row.add_child(ok)
	body.add_child(row)


func _close_new_game_confirm() -> void:
	if _new_game_confirm != null and is_instance_valid(_new_game_confirm):
		_new_game_confirm.queue_free()
	_new_game_confirm = null


func _on_continue() -> void:
	AudioManager.sfx_confirm()
	if SaveManager.load_game(SaveManager.AUTO_SLOT):
		SceneRouter.goto_fresh("world")   # 入世入口：清空菜单残留历史（R1-02）


func _on_load() -> void:
	AudioManager.sfx_click()
	SaveMenu.open_as("load", "main_menu")


func _on_settings() -> void:
	AudioManager.sfx_click()
	_settings.open(false)   # 主菜单入口：无进行中的对局，隐藏存档区


func _on_quit() -> void:
	AudioManager.sfx_click()
	get_tree().quit()
