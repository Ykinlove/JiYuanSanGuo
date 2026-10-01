extends Node2D
class_name NPCManager
## NPC 管理器（NPCManager）
## 职责：按数据表在世界地图生成 NPC，处理靠近提示与交互触发。

signal npc_interacted(npc: Dictionary)

const INTERACT_RADIUS := 425.0   ## 旧 130 仍偏紧（用户反馈：不到一定距离点击无反应），再扩 40
const NPC_TEX_DIR := "res://assets/sprites/npcs/"
## 有类型的扩展名候选表：避免 for 循环变量退化为 Variant（会导致 := 无法推断类型）
const TEX_EXT_CANDIDATES: Array[String] = [".png", ".webp", ".jpg"]
## 立绘在世界中的目标高度（与几何小人同尺度）：素材约 768px，需等比缩小
## 【三十五轮微调】定档 ×2.5：84→210，几何兜底/影子/振幅同比例
const NPC_WORLD_HEIGHT := 210.0

var _player: Node2D
var _nearby_npc: Dictionary = {}
var _nearby_pos: Vector2 = Vector2.ZERO
var _bubble: Label
## 由 world_map 每帧同步：贴脸交互菜单是否已经弹出。
## 菜单弹出后必须收起「▲ 对话」与头顶气泡，否则两套提示叠在一起 = 元素重复显示。
var menu_open := false


func _ready() -> void:
	_player = get_parent().get_node_or_null("Player")
	_spawn_npcs()
	_create_bubble()


func _create_bubble() -> void:
	_bubble = Label.new()
	_bubble.add_theme_font_size_override("font_size", 22)
	_bubble.modulate = Color(1, 0.95, 0.7, 1)
	_bubble.z_index = 200
	_bubble.visible = false
	add_child(_bubble)


func _spawn_npcs() -> void:
	for npc in DataManager.get_table("npcs"):
		# 归属城池的 NPC 在城市场景内活动（city_scene 生成），
		# 大地图城外只应出现山贼、流寇等遭遇物（EncounterManager 负责）
		if not str(npc.get("city_id", "")).is_empty():
			continue
		var pos_arr: Array = npc.get("position", [0, 0])
		var pos := Vector2(float(pos_arr[0]), float(pos_arr[1]))

		var node := Node2D.new()
		node.name = "NPC_" + str(npc.get("id", ""))
		node.position = pos
		node.set_meta("npc", npc)
		add_child(node)

		# 立绘：优先用美术贴图，缺失时回退几何小人
		var tex := _get_npc_tex(str(npc.get("id", "")))
		var c := Color(str(npc.get("color", "#B8A88A")))

		# 【行走动画容器】人物本体统一装进 Art：WalkAnim 只动 Art，
		# 投影 / 名牌 / 交互提示留在外面，不会跟着一起晃。
		var art := Node2D.new()
		art.name = "Art"
		node.add_child(art)

		if tex:
			var sp := Sprite2D.new()
			sp.texture = tex
			# 立绘素材为高分辨率（约 768px 高），必须等比缩到世界尺度，
			# 否则会渲染成巨型贴图覆盖整屏。
			var sc := NPC_WORLD_HEIGHT / maxf(1.0, float(tex.get_height()))
			sp.scale = Vector2(sc, sc)
			sp.position = Vector2(0, 20.0 - NPC_WORLD_HEIGHT * 0.5)
			# 【R3-05】描金外发光：同纹理 ×1.08 垫在立绘下层，暗地形上轮廓立现
			var rim := Sprite2D.new()
			rim.texture = tex
			rim.scale = sp.scale * 1.08
			rim.position = sp.position
			rim.modulate = UITheme.GOLD_DIM
			art.add_child(rim)
			art.add_child(sp)
			# 脚下投影，让贴图"落地"（半径随 84px 身高联动）
			var shadow := Polygon2D.new()
			shadow.polygon = _circle_points(Vector2(0, 20), 55, 16)
			shadow.scale = Vector2(1.0, 0.45)
			shadow.color = Color(0, 0, 0, 0.22)
			node.add_child(shadow)
			node.move_child(shadow, 0)
			# 【行走动画】立绘是单图（腿画在图里动不了），靠踏步起伏+摇摆
			# +影子呼吸演出"落地感"——此前大地图 NPC 完全没挂，纯滑动。
			var wa := WalkAnim.attach(node, art)
			if wa != null:
				wa.bob_amp = 9.8
				wa.lean_deg = 4.0
				wa.dir_lean_deg = 2.5
				wa.squash = 0.035
				wa.shadow_node = shadow
		else:
			# 【三十三轮】几何兜底整体 ×1.5（与 NPC_WORLD_HEIGHT 84 同比例）
			# 身体
			var body := Polygon2D.new()
			body.polygon = PackedVector2Array([
				Vector2(0, -82), Vector2(52, -22), Vector2(52, 60),
				Vector2(-52, 60), Vector2(-52, -22)
			])
			body.color = c
			art.add_child(body)

			# 头
			var head := Polygon2D.new()
			head.polygon = _circle_points(Vector2(0, -120), 40, 12)
			head.color = c.lightened(0.22)
			art.add_child(head)

			# 描边
			var outline := Line2D.new()
			outline.points = PackedVector2Array([
				Vector2(0, -82), Vector2(52, -22), Vector2(52, 60),
				Vector2(-52, 60), Vector2(-52, -22), Vector2(0, -165)
			])
			outline.width = 15.0
			outline.default_color = c.darkened(0.45)
			art.add_child(outline)

			# 【双腿】几何小人装两条会摆动的腿：前摆抬脚、后蹬伸直、
			# 与踏步 bob 同相位（躯干底 y=24，地面 y≈30）
			var wa := WalkAnim.attach(node, art)
			if wa != null:
				wa.leg_len = 37.0
				wa.leg_swing_deg = 26.0
				wa.leg_color = c.darkened(0.55)
				wa.add_legs(art, 45.0, 25.0)
				wa.bob_amp = 8.2
				wa.lean_deg = 4.0
				wa.dir_lean_deg = 2.5
				wa.squash = 0.03

		# 名字
		var label := Label.new()
		label.text = str(npc.get("name", ""))
		label.add_theme_font_size_override("font_size", UITheme.FS_MARKER_NAME)
		label.position = Vector2(-30, 26 if tex else 20)
		label.modulate = Color(1, 1, 1, 0.9) if tex else Color(1, 1, 1, 1)
		node.add_child(label)

		# 交互提示标记（靠近才显示）
		var hint := Label.new()
		hint.name = "Hint"
		hint.text = "▲ 对话"
		hint.add_theme_font_size_override("font_size", UITheme.FS_MARKER_NOTE)
		hint.modulate = Color(1, 0.9, 0.5)
		hint.position = Vector2(-32, -66)
		hint.visible = false
		node.add_child(hint)


func _circle_points(center: Vector2, r: float, seg: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(seg):
		var t := float(i) / float(seg) * TAU
		pts.append(center + Vector2(cos(t), sin(t)) * r)
	return pts


## 尝试加载 NPC 立绘（res://assets/sprites/npcs/<id>.png）
func _get_npc_tex(npc_id: String) -> Texture2D:
	if npc_id.is_empty():
		return null
	for ext in TEX_EXT_CANDIDATES:
		var path: String = NPC_TEX_DIR + npc_id + ext
		if ResourceLoader.exists(path):
			var res := load(path)
			if res is Texture2D:
				return res
	return null


func _process(_delta: float) -> void:
	if _player == null:
		return

	var closest: Dictionary = {}
	var closest_pos := Vector2.ZERO
	var closest_dist := INF
	for node in get_children():
		if not (node is Node2D) or not node.has_meta("npc"):
			continue
		var d := _player.position.distance_to(node.position)
		var hint := node.get_node_or_null("Hint")
		if hint and hint is CanvasItem:
			# 贴脸菜单已经弹出时收起「▲ 对话」，避免和菜单里的按钮重复提示
			hint.visible = d < INTERACT_RADIUS and not menu_open
		if d < INTERACT_RADIUS and d < closest_dist:
			closest_dist = d
			closest_pos = node.position
			closest = node.get_meta("npc")

	if str(closest.get("id", "")) != str(_nearby_npc.get("id", "")):
		_nearby_npc = closest
	_nearby_pos = closest_pos
	_update_bubble()


## 气泡显隐 + 跟随玩家。
## 历史 bug：气泡只在「目标变化的那一帧」设过一次位置并把 alpha 置 1，之后再不管它 ——
## 玩家走开后气泡原地残留、也不跟随移动，与新目标的提示叠在一起，
## 玩家看到的就是「交互提示重复显示 / 位置错乱」。
func _update_bubble() -> void:
	if _bubble == null or _player == null:
		return
	var show := (not menu_open) and (not _nearby_npc.is_empty())
	_bubble.visible = show
	if not show:
		return
	_bubble.text = "可交互：%s" % str(_nearby_npc.get("name", ""))
	_bubble.position = _player.position + Vector2(-90, -70)


## 尝试与最近 NPC 交互
func try_interact() -> bool:
	if _nearby_npc.is_empty():
		return false
	npc_interacted.emit(_nearby_npc)
	return true


func get_nearby_npc() -> Dictionary:
	return _nearby_npc


## 最近 NPC 的世界坐标（供交互菜单贴脸定位）
func get_nearby_npc_pos() -> Vector2:
	return _nearby_pos
