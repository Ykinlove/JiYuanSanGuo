extends Node2D
## 启动场景（Boot）
## 职责：初始化、进入主菜单。可作为将来资源预加载的入口。

@onready var _label: Label = $UI/CenterBox/VBox/StatusLabel


func _ready() -> void:
	_label.text = "正在初始化…"
	await get_tree().process_frame
	_label.text = "数据表加载完成"
	await get_tree().create_timer(0.6).timeout
	_label.text = "进入主菜单"
	await get_tree().create_timer(0.4).timeout
	SceneRouter.goto("main_menu")
