extends Node
## 场景路由（SceneRouter）
## 职责：带渐隐过渡的场景切换、返回上一场景、全局加载遮罩。

const SCENES := {
	"boot":       "res://scenes/main/boot.tscn",
	"main_menu":  "res://scenes/main/main_menu.tscn",
	"create_hero": "res://scenes/main/create_hero.tscn",
	"save_menu":  "res://scenes/main/save_menu.tscn",
	"world":      "res://scenes/world/world_map.tscn",
	"city":       "res://scenes/city/city_scene.tscn",
	"formation":  "res://scenes/battle/formation_editor.tscn",
	"battle":     "res://scenes/battle/battle_scene.tscn",
}

var _overlay: ColorRect
var _is_transitioning := false
var _history: Array[String] = []
## 当前场景 key【M4】：不能用 _history[-1] 代替——goto_fresh（读档/新局）
## 会清空历史且不追加记录，此时栈是空的。
var current_key: String = "boot"


func _ready() -> void:
	_build_overlay()


func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 128
	add_child(layer)

	_overlay = ColorRect.new()
	_overlay.color = Color(0, 0, 0, 0)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_overlay)


## 切换场景（带渐隐）
## record=false 供 goto_fresh 使用：先清空历史、本次不再追加，避免把菜单流残留
## 的旧历史又记回来。历史一律在**真正开始切换后**才追加——早期版本是 push_scene
## 先 append 再 goto，goto 因上一场过渡未结束被拒时历史已经污染，玩家会 back 到
## 一个根本没去过的场景。
func goto(scene_key: String, fade_time: float = 0.3, record: bool = true) -> void:
	if _is_transitioning:
		return
	if not SCENES.has(scene_key):
		push_error("[SceneRouter] 未知场景：%s" % scene_key)
		return
	current_key = scene_key
	if record:
		_history.append(scene_key)
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
	goto(scene_key)   # 历史由 goto 在切换真正开始后追加


## 【R1-02】全新进入（开新局/读档/续档后的「入世」入口）：
## 清空历史再切换。菜单流残留的旧历史（上一局的 city/formation 栈、存档界面）
## 不应跟进新对局，否则在 world 里 back() 会被带回已失效的场景。
func goto_fresh(scene_key: String) -> void:
	_history.clear()
	goto(scene_key, 0.3, false)


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
