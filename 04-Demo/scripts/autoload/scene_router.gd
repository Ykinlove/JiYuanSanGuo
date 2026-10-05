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

## 【本轮·性能】渐隐/渐亮时长（单程）。
## 【为什么从 0.3 降到 0.14】这一段是**纯等待**：画面已经全黑（或已经全亮），
## 玩家在这 0.3s 里什么也做不了，什么也看不见。两次各 0.3 = 每次切场景
## 白等 0.6s，占「短距切换」总耗时的大头。
## 0.14 仍足够长到不闪（硬切到全黑反而更刺眼，且会暴露 change_scene 的
## 中间态），但把每次白等砍掉 0.32s。
const FADE_TIME := 0.14

var _overlay: ColorRect
var _label: Label                    ## 阻塞期的进度文字（见 goto 说明）
var _is_transitioning := false
var _history: Array[String] = []
## 当前场景 key【M4】：不能用 _history[-1] 代替——goto_fresh（读档/新局）
## 会清空历史且不追加记录，此时栈是空的。
var current_key: String = "boot"
## 【本轮·性能】已预热（load 过）的场景 key 集合。
## 实测首次 load 大地图 2774ms、二次 0ms —— 纹理解码只付一次，
## 故「切场景前先把目标场景 load 一遍」能把黑屏从 2.7s 压到接近 0。
var _prewarmed: Dictionary = {}


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

	# 【本轮·性能】阻塞期的进度文字。
	# 【为什么要它而不是「黑屏快一点」】Godot 的 change_scene_to_file 是
	# **同步阻塞**的：它在主线程完整跑完新场景的 _ready() 才返回，
	# 期间主循环一帧都不推进 —— 纯黑屏看起来就是「卡死」。
	# 而玩家真正抱怨的往往不是那 2.7 秒本身，是「不知道在干什么」。
	# 文字不能消除阻塞（引擎限制），但能把「死机感」变成「在加载」，
	# 且不依赖异步加载那套线程池配置（线程池本身有踩坑成本，见 pitfalls）。
	_label = Label.new()
	_label.name = "LoadingLabel"
	_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 26)
	_label.add_theme_color_override("font_color", Color(0.78, 0.72, 0.60))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("outline_size", 6)
	_label.text = "载入中…"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.visible = false
	layer.add_child(_label)


## 预热指定场景（只做 load，不实例化）。
## 幂等：已预热过则立即返回。供「玩家点了之后、画面还在旧场景时」提前调用。
func prewarm(scene_key: String) -> void:
	if _prewarmed.has(scene_key) or not SCENES.has(scene_key):
		return
	var ps: PackedScene = load(SCENES[scene_key])
	if ps != null:
		_prewarmed[scene_key] = true


## 预热**整条对战链路**（world → formation → battle → world）。
## 【本轮·性能·取证结论】一次「进城→开战→回城」要连续切 4 次场景，
## 而 prewarm 只在 goto 内部、即渐黑之后才跑 —— 每个新场景都在黑屏里
## 付首次 load 的代价（实测首次 2774ms）。四个场景都是**同一场对局内必然经过**的，
## 属于「可以确定会用」的集合，故允许在玩家还停留于上一场景时一并预热。
## 【为什么不全表预热】`load` 会常驻内存，一次性全 load 会把 boot 的启动时间
## 全部转嫁给玩家；只挑这条必经链是收益/代价比最高的切法。
const BATTLE_CHAIN: Array[String] = ["world", "formation", "battle", "city"]


func prewarm_battle_chain() -> void:
	for k in BATTLE_CHAIN:
		prewarm(k)


## 切换场景（带渐隐）
## record=false 供 goto_fresh 使用：先清空历史、本次不再追加，避免把菜单流残留
## 的旧历史又记回来。历史一律在**真正开始切换后**才追加——早期版本是 push_scene
## 先 append 再 goto，goto 因上一场过渡未结束被拒时历史已经污染，玩家会 back 到
## 一个根本没去过的场景。
func goto(scene_key: String, fade_time: float = FADE_TIME, record: bool = true) -> void:
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

	# 【本轮·性能·顺序是修掉「黑屏太久」的关键】
	# 【取证结论·原式的错在哪】预热原本写在「渐黑 tween 之后」：
	#     渐黑 0.3s（await 完才继续）→ 此刻画面已全黑 → 才 load 目标场景
	#     → 再 change_scene_to_file 同步阻塞 → 渐亮 0.3s
	# 预热的收益本该是「在画面还可见时把 load 成本付掉」，写成渐黑之后
	# 就只剩后半段：玩家看到的是**纯黑屏 + 载入中…** 干等一整轮 load。
	# 现在把 prewarm 提到最前 —— 玩家看到的是旧场景正常可动、只是不能点，
	# 感知上比黑屏等待短得多（黑屏时的等待是无法忍受的，能操作但无反馈是可忍受的）。
	# 实测首次 load 大地图 2774ms、二次 0ms —— 这一行是黑屏时长的主因。
	prewarm(scene_key)

	# 渐黑
	var tween := create_tween()
	tween.tween_property(_overlay, "color:a", 1.0, fade_time)
	await tween.finished

	# 【本轮·性能】全黑之后立刻显示进度文字，再做同步阻塞的场景切换。
	# 顺序很重要：文字必须在黑幕**之后**才可见（黑幕之前显示等于被淡入淡出吃掉）。
	_label.visible = true

	get_tree().change_scene_to_file(SCENES[scene_key])
	await get_tree().process_frame

	# 渐亮（先撤文字：它只是遮挡物，白幕上留字会闪一下）
	_label.visible = false
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
	goto(scene_key, FADE_TIME, false)


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
