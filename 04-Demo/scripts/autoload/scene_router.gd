extends Node
## 场景路由（SceneRouter）
## 职责：带渐隐过渡的场景切换、返回上一场景、全局加载遮罩。

const SCENES := {
	"boot":       "res://scenes/main/boot.tscn",
	"main_menu":  "res://scenes/main/main_menu.tscn",
	"save_menu":  "res://scenes/main/save_menu.tscn",
	"world":      "res://scenes/world/world_map.tscn",
	"city":       "res://scenes/city/city_scene.tscn",
	"formation":  "res://scenes/battle/formation_editor.tscn",
	"battle":     "res://scenes/battle/battle_scene.tscn",
}

var _overlay: ColorRect
var _is_transitioning := false
var _history: Array[String] = []


func _ready() -> void:
	_build_overlay()


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 128
	add_child(layer)

	_overlay = ColorRect.new()
	_overlay.color = Color(0, 0, 0, 0)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_overlay)


## 切换场景（带渐隐）
func goto(scene_key: String, fade_time: float = 0.3) -> void:
	if _is_transitioning:
		return
	if not SCENES.has(scene_key):
		push_error("[SceneRouter] 未知场景：%s" % scene_key)
		return
	_is_transitioning = true
	EventBus.scene_loading_started.emit(scene_key)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	# 渐黑
	var tween := create_tween()
	tween.tween_property(_overlay, "color:a", 1.0, fade_time)
	await tween.finished

	get_tree().change_scene_to_file(SCENES[scene_key])
	await get_tree().process_frame

	# 渐亮
	var tween2 := create_tween()
	tween2.tween_property(_overlay, "color:a", 0.0, fade_time)
	await tween2.finished

	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_is_transitioning = false
	EventBus.scene_loading_finished.emit(scene_key)


## 切换并记录历史（用于返回）
func push_scene(scene_key: String) -> void:
	_history.append(scene_key)
	goto(scene_key)


## 返回上一场景
func back() -> void:
	if _history.size() <= 1:
		goto("world")
		return
	_history.pop_back()
	var target := _history[-1]
	goto(target)


## 是否正在场景过渡中
func is_transitioning() -> bool:
	return _is_transitioning
