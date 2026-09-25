extends Node2D
## 启动场景（Boot）
## 职责：初始化、进入主菜单。可作为将来资源预加载的入口。
## 【B14】演出总时长压缩至 0.5s，且点击/触屏可立即跳过——固定 1s 不可跳过拖慢每次启动。

@onready var _label: Label = $UI/CenterBox/VBox/StatusLabel

var _leaving := false


func _ready() -> void:
	_label.text = "正在初始化…"
	await get_tree().process_frame
	if _leaving:
		return
	_label.text = "数据表加载完成"
	await get_tree().create_timer(0.3).timeout
	if _leaving:
		return
	_label.text = "进入主菜单"
	await get_tree().create_timer(0.2).timeout
	_goto_menu()


func _goto_menu() -> void:
	if _leaving:
		return
	_leaving = true
	SceneRouter.goto("main_menu")


func _unhandled_input(event: InputEvent) -> void:
	# 注意：event.pressed 为动态属性，中间变量赋值会触发类型推断 Parse Error，
	# 必须直接放 if 条件（Variant 条件转换）
	if (event is InputEventMouseButton and event.pressed) \
			or (event is InputEventScreenTouch and event.pressed):
		_goto_menu()
