extends Control
## 主菜单（MainMenu）

@onready var _btn_new: Button = %BtnNewGame
@onready var _btn_continue: Button = %BtnContinue
@onready var _btn_load: Button = %BtnLoad
@onready var _btn_settings: Button = %BtnSettings
@onready var _btn_quit: Button = %BtnQuit
@onready var _version_label: Label = %VersionLabel

var _settings: SettingsPanel


func _ready() -> void:
	_version_label.text = "v" + str(ProjectSettings.get_setting("application/config/version", "0.0.0")) + " 内测版"
	_btn_continue.disabled = not SaveManager.has_any_save()

	# 系统设置面板（代码创建，与大地图/城池共用同一脚本）
	_settings = SettingsPanel.new()
	_settings.name = "SettingsPanel"
	add_child(_settings)

	_btn_new.pressed.connect(_on_new_game)
	_btn_continue.pressed.connect(_on_continue)
	_btn_load.pressed.connect(_on_load)
	_btn_settings.pressed.connect(_on_settings)
	_btn_quit.pressed.connect(_on_quit)


func _on_new_game() -> void:
	AudioManager.sfx_confirm()
	GameState.reset()
	SceneRouter.push_scene("world")


func _on_continue() -> void:
	AudioManager.sfx_confirm()
	if SaveManager.load_game(SaveManager.AUTO_SLOT):
		SceneRouter.push_scene("world")


func _on_load() -> void:
	AudioManager.sfx_click()
	SaveMenu.open_as("load", "main_menu")


func _on_settings() -> void:
	AudioManager.sfx_click()
	_settings.open(false)   # 主菜单入口：无进行中的对局，隐藏存档区


func _on_quit() -> void:
	AudioManager.sfx_click()
	get_tree().quit()
