extends Control
## 主菜单（MainMenu）

@onready var _btn_new: Button = %BtnNewGame
@onready var _btn_continue: Button = %BtnContinue
@onready var _btn_load: Button = %BtnLoad
@onready var _btn_settings: Button = %BtnSettings
@onready var _btn_quit: Button = %BtnQuit
@onready var _version_label: Label = %VersionLabel


func _ready() -> void:
	_version_label.text = "v0.1.0 M1骨架"
	_btn_continue.disabled = not SaveManager.has_any_save()

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
	SceneRouter.goto("save_menu")


func _on_settings() -> void:
	AudioManager.sfx_click()
	EventBus.show_toast("设置界面待实现")


func _on_quit() -> void:
	AudioManager.sfx_click()
	get_tree().quit()
