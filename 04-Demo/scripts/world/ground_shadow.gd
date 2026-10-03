extends RefCounted
class_name GroundShadow
## 接地投影工厂（第六十八轮·第 5 项第四层）
## ------------------------------------------------------------------
## 【为什么需要】高度场把角色按脚下海拔**浮起来**之后，画面里立刻出现一个新问题：
## 角色脚下**没有影子** → 观感是「角色浮在地表上方」，比不浮更假。
## 影子是「贴在地面上」这件事的**唯一视觉证据**：它给出接触点，
## 观众的眼睛据此判断「这个人站在山坡上」而不是「贴图漂在地表上」。
##
## 【为什么不能挂在角色节点下跟着浮】投影必须**留在地面**：
## 若投影跟着角色的高度一起上浮，影子会飘到半空 → 反而暴露了浮空。
## 故投影必须是**独立节点**，不进ActorLayer 的 y_sort 参与排序，
## 而是按 x/y 直接画在地形层之上、实体层之下（由调用方设置 z）。
##
## 【尺寸依据】世界角色身高 UITheme.WORLD_UNIT_HEIGHT = 120。
## 椭圆半径按角色身高的 0.26~0.30 取 —— 再大像站在一堆黑墨里，
## 再小则在大地图 0.5 倍缩放下几乎看不见。

const ELLIPSE_SEGMENTS := 16
const DEFAULT_ALPHA := 0.34
## 影子 y 向压扁比（俯视 2D 里影子是椭圆而非正圆）
const SQUASH := 0.34


## 造一个接地投影（椭圆软阴影垫）。
## @param radius 椭圆半宽（世界像素），一般取角色世界身高的 0.26~0.30
## @param alpha  基础不透明度
## @return Polygon2D 节点（**尚未挂树**，由调用方决定父节点与 z_index）
static func make(radius: float = 34.0, alpha: float = DEFAULT_ALPHA) -> Polygon2D:
	var p := Polygon2D.new()
	p.name = "Shadow"
	var pts := PackedVector2Array()
	for i in range(ELLIPSE_SEGMENTS):
		var t := TAU * float(i) / float(ELLIPSE_SEGMENTS)
		pts.append(Vector2(cos(t) * radius, sin(t) * radius * SQUASH))
	p.polygon = pts
	# 【为什么不用纯黑】纯黑影子在深色地形上会显成「一块墨迹」。
	# 略偏冷灰更接近真实环境遮蔽（ambient occlusion）观感。
	p.color = Color(0.05, 0.05, 0.08, alpha)
	return p


## 按角色世界身高换算推荐半径（单一事实源，避免各处各写一个魔法数）。
static func radius_for_height(world_height: float) -> float:
	return world_height * 0.28


## 为某个实体挂上接地投影。
##
## 【关键·父节点由调用方显式指定】影子必须挂在**地面容器**上
##（城内/大地图的 world root），**绝不能**挂在实体的父节点上 ——
## 因为接入 y_sort 后实体的父节点是 ActorLayer，影子会被卷进去参与排序，
## 走远后跑到别的实体后面去（探针实测抓到：Shadow 被当作层内实体，
## z_index=-50 触犯「层内 z 必须为 0」，且 y_sort 让它随 y 漂到他人身后）。
##
## @param actor       实体本体（它的 position 是地面坐标，未被高度场污染）
## @param world_height 该角色的世界身高（世界像素）
## @param ground      影子要挂到的**地面容器**（通常传 world root）
## @param z_index     影子层级（应低于实体层、贴着地形）
## @return 影子节点（已挂到 ground 下）
static func attach(actor: Node2D, world_height: float, ground: Node2D,
		z_index: int = -50) -> Polygon2D:
	if actor == null or not is_instance_valid(actor):
		return null
	if ground == null or not is_instance_valid(ground):
		return null
	# 已有投影就不重复挂（重建容器时会重复调用，重复影子会叠成一片黑）
	# has_meta 守卫：get_meta 对不存在的键会向引擎日志打 ERROR（见 follow 注释）
	if actor.has_meta("shadow"):
		var exist := actor.get_meta("shadow") as Node2D
		if exist != null and is_instance_valid(exist):
			if exist.get_parent() != ground:
				exist.get_parent().remove_child(exist)
				ground.add_child(exist)
			exist.z_index = z_index
			exist.position = actor.position
			return exist
	var sh := make(radius_for_height(world_height))
	ground.add_child(sh)
	sh.position = actor.position
	sh.z_index = z_index
	actor.set_meta("shadow", sh)
	return sh


## 让投影跟随实体移动（实体移动时影子必须跟上，否则会留在原地）。
## 【为什么不用_process】调用方通常已在每帧更新实体位置，
## 在同处调一次即可，避免多一个每帧回调（每帧回调在 110 城 + 数十 NPC
## 的规模下是纯粹的浪费）。
static func follow(actor: Node2D) -> void:
	if actor == null or not is_instance_valid(actor):
		return
	# 【必读】必须先 has_meta 再 get_meta。Godot 的 get_meta 对**不存在的键**
	# 不会返回 null，而是向引擎日志输出一条 ERROR
	#（"The object does not have any 'meta' values with the key 'shadow'"），
	# 这条 ERROR 会被场景启动冒烟判为「真实 WARNING/ERROR」而让校验报红。
	# 实测：并非所有实体都挂了影子（attach 对 ground/actor 校验失败会返回 null），
	# 直接 get_meta 就会刷出 19 条 ERROR。attach() 内部同样已用 get_meta，
	# 但那里调用前一定已 set_meta 或由 attach 自己写入，故安全。
	if not actor.has_meta("shadow"):
		return
	var sh := actor.get_meta("shadow") as Node2D
	if sh == null or not is_instance_valid(sh):
		return
	# 影子**只跟 x/y 的水平位置**，不跟高度场的视觉抬升（那是另一个节点的位移）。
	sh.position = actor.position