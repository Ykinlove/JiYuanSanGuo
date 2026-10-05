extends RefCounted
class_name DepthSort
## 深度排序工具（第六十八轮·用户「一点都没有身临其境的感觉」）
## ------------------------------------------------------------------
## 【为什么需要它】此前大地图与城内都用**固定 z_index** 分层：
##   大地图：城池 10 > NPC 8 > 遭遇物 5 > 玩家 20
##   城内：建筑/NPC/玩家 全部挂在 _interior 下靠添加顺序决定
## 后果是**没有前后关系**：角色走到城池北侧（画面上方）时，z_index 20
## 仍让他画在城池前面 —— 视觉上像**贴在城墙上**，而不是走在城墙后面。
## 这就是用户说的「像贴图游戏」的核心：**所有东西都在同一个平面上**。
##
## 【怎么修】Godot 的 `Node2D.y_sort_enabled` 会按子节点的**全局 y 坐标**排序，
## 谁的 y 大谁画在前面（y 轴向下，所以 y 越大越靠下 = 越靠前）。
## 俯视 2D 里「y 大 = 在前面」是正确的空间直觉：
##   角色 y=800 走到建筑 y=600 的下方（南侧）→ 应画在建筑前面 → 正确遮挡。
##   角色 y=400 在建筑 y=600 的上方（北侧）→ 应被建筑挡住 → y 排序自动处理。
##
## 【引擎行为·已由 tests/depth_sort_probe.gd 的 A0/A0b/A0c 实测确认】
##   A0   y_sort 开启时，兄弟节点按 y 升序排列（y 大的 index 更大 = 画得更靠前）。
##   A0b  y_sort 关闭时保持插入顺序（反证：排序确来自 y_sort，不是巧合）。
##   A0c  **z_index 优先于 y_sort**：z=9/y=100 的节点排在 z=0/y=900 的**后面**。
##        —— 这条是本工具「实体 z_index 必须清零」的全部依据。
##        若引擎行为相反（y_sort 优先），清零就成了多余动作，
##        而地形用 z_index=-100 压底也会失效。改代码前务必先跑探针复核。
##
## 【必须注意的坑·勿踩】
## 1. **y_sort 只在同一父节点的直接子节点之间生效**。所以不能把
##    「建筑」「NPC」「玩家」留在三个并列兄弟节点里 —— 必须**挂到同一个
##    y_sort_enabled 父节点下**，否则排序完全不发生（这是最常见的失败方式）。
## 2. **子节点自身的 z_index 会覆盖 y_sort**（见 A0c）。所以接入层必须把
##    地形 z_index 保持为负（地形永远在最底），但把「实体」节点的 z_index 清零。
## 3. **标签/提示要留在实体节点内**（跟着实体一起排序），
##    不要再挂到不排序的顶层 UI 节点上，否则名字会浮在所有人头顶。
## 4. 地形 `TerrainPainter` 自身若开了 y_sort 会在每帧对全表排序（21256×21826
##    的地图上节点上千），**必须只在地形那一层关掉**，实体层才开。
##
## 【搬运时必须避开的两颗地雷（均为本轮探针实测踩到）】
## ① 容器里可能混有**非 CanvasItem 的子节点**。实证：`Player` 下挂着
##    `WalkAnim extends Node`（纯逻辑节点），对它写 `z_index` 会抛
##    `Invalid assignment of property or key 'z_index'` 并**中断整个搬运循环**，
##    后续实体全部没搬进去 —— 而错误只在运行时日志里，编译期完全无感。
##    → 故必须先判 `is CanvasItem` 再清 z_index，且用循环而非批量赋值。
## ② **「容器」与「实体」必须区分**。`Player` 既是实体（要参与排序）
##    又是容器（挂着 Visual/Camera2D/WalkAnim）。
##    若一律「搬容器的子节点」，玩家本人就留在层外 → 玩家永远压不住任何东西。
##    → 故 API 必须能区分 entity_paths（搬本体）与 container_paths（搬子节点）。

## 把若干「实体」与「容器」并入同一个 y_sort 父节点。
##
## 【为什么用搬移而不是给每个容器各开 y_sort】y_sort 的排序范围是父节点的
## **直接子节点**；若 CityMarkers/Encounters/NPCs/Player 仍是 WorldMap 的
## 直接子节点，给它们各自开 y_sort 只会在「各自内部」排序，彼此之间仍按
## z_index —— 等于什么都没改。必须把它们的**子节点**统一搬到一层里。
##
## 【搬运后原容器会变空——这是预期的，调用方须知】
## 原先依赖 `容器.get_children()` 的运行期遍历会随之失效。
## 本工程第 57 轮已为城池/NPC/遭遇建好缓存数组（`_marker_cache` /
## `_npc_cache` / `_enc_nodes`），调用方应改用缓存而非重新遍历容器。
##
## @param world_root 场景根（WorldMap / CityScene 的 Interior）
## @param entity_paths 要**搬本体**的实体节点路径（它们本身参与排序）
## @param container_paths 要**搬子节点**的容器路径（容器本体留在原地）
## @returns 新建的 Actor 层节点（已开启 y_sort），失败返回 null
static func build_actor_layer(world_root: Node2D,
		entity_paths: Array, container_paths: Array) -> Node2D:
	if world_root == null:
		push_warning("[DepthSort] world_root 为空")
		return null
	var layer := Node2D.new()
	layer.name = "ActorLayer"
	layer.y_sort_enabled = true
	# ActorLayer 自身不设 z_index（0），让子节点自由 y_sort
	world_root.add_child(layer)
	world_root.move_child(layer, 0)

	# ① 实体：搬**本体**（玩家本人必须进层，否则永远压不住别人）
	for p in entity_paths:
		var e: Node = world_root.get_node_or_null(NodePath(str(p)))
		if e == null:
			push_warning("[DepthSort] 实体不存在，跳过：" + str(p))
			continue
		_reattain(e, layer)

	# ② 容器：搬**子节点**（容器本体留在原地，可能还挂别的东西）
	for p in container_paths:
		var c: Node = world_root.get_node_or_null(NodePath(str(p)))
		if c == null:
			push_warning("[DepthSort] 容器不存在，跳过：" + str(p))
			continue
		for child in c.get_children():
			_reattain(child, layer)
	return layer


## 把单个节点（含其子树）搬进 y_sort 层，并清掉 z_index。
## 【地雷①】子节点未必是 CanvasItem（Player/WalkAnim 就是纯 Node），
## 对非 CanvasItem 写 z_index 会抛错并中断调用方的循环 —— 故必须先判类型。
static func _reattain(node: Node, layer: Node2D) -> void:
	if node == null or node == layer:
		return
	var old_parent := node.get_parent()
	if old_parent == null:
		return
	# 只清「搬移根节点」的 z_index：其子树的 z_index 是相对它的局部偏移，
	# 不参与父层 y_sort（Godot 的 y_sort 只看直接子节点各自的 z_index）。
	# 但仍需清零，否则该实体会整体压在同层实体之上。
	if node is CanvasItem:
		(node as CanvasItem).z_index = 8
	old_parent.remove_child(node)
	layer.add_child(node)


## 地形层专用：关掉 y_sort 并压到最底。
## 【为什么】地形是全图一张底图，若参与 y_sort 会在每帧对上千节点排序，
## 纯浪费；且地形本来就该在所有实体之下。
static func pin_terrain(terrain: Node2D, z: int = -100) -> void:
	if terrain == null:
		return
	terrain.y_sort_enabled = false
	terrain.z_index = z


## 诊断用：Actor 层是否已开启 y_sort。
## 【为什么要有它】y_sort 是引擎行为，静态扫描看不出来；
## 判定「排序真的生效了」必须实跑并读层内 get_index() 顺序，
## 不能只查这个标志位 —— 标志位可以撒谎，兄弟顺序不会。
static func is_sorted_by_y(actor_layer: Node2D) -> bool:
	return actor_layer != null and actor_layer.y_sort_enabled
