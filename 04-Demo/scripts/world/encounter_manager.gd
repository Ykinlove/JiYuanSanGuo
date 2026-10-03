extends Node2D
class_name EncounterManager
## 遭遇管理器（EncounterManager）
## 职责：在大地图上生成遭遇物（战斗/商队/宝箱/采集），处理踩踏触发与结算。
## 遭遇物挂在世界坐标上，随相机滚动。已触发的非采集类遭遇会消失。

signal encounter_triggered(encounter: Dictionary)
## 【第六十八轮·深度排序】重建后发射，通知大地图把新建的遭遇节点搬进
## y_sort 层。**必须发信号而不是让大地图轮询** —— 轮询要每帧遍历节点树，
## 会破坏第五十七轮建立的「生成期登记、每帧只读数组」性能优化。
signal actors_reparented

const INTERACT_RADIUS := 350.0   ## 旧 100 仍偏紧（用户反馈：不到一定距离点击无反应），再扩 40
## 【2026-09-24 用户拍板】非战斗遭遇改为**手动触发**：垂钓/挖矿药草/宝箱/商队/奇遇
## 走近不再自动结算 —— 范围内亮「▲ 可交互」提示，点右下交互按钮才触发。
## 可战斗的 NPC（野兽/山贼等）保持走近自动开战。
const MANUAL_TYPES: Array[String] = ["gather", "treasure", "merchant", "event"]
## 【R2-12】同一遭遇定义的「每日可结算次数」上限。
## 跨区重撒会换随机种子，enc_id（def_id+坐标）随之改变，旧的已解决记录失效 ——
## 玩家在两州交界来回走几趟就能无限刷同一批同级怪/同一个 BOSS。
## 按 def 维度另记一笔当日计数，超限后不再播撒该定义；次日随采集点一并清零。
const RESOLVE_CAP_PER_DEF := 3
const ENC_TEX_DIR := "res://assets/sprites/encounters/"
## 【第六十八轮·尺度再统一】本常量经历过两轮：
##   第六十六轮 54 -> 125：当时基准身高是主角 425，54:425 = 1:7.9 像小石子。
##   第六十八轮 125 -> 62：基准身高已归一到 120（全工程统一取 UITheme.WORLD_UNIT_HEIGHT），
##   125 反而比人还高（物件 > 人，比例又崩）。62 约为人的一半，符合「地面物件」观感。
## 现比例：主角 120 : 遭遇物 62 : 城池 380 ≈ 1 : 0.52 : 3.2
const ENC_WORLD_HEIGHT := 62.0    ## 对应 UITheme.WORLD_ENC_HEIGHT
## 各类型相对基准高度的倍率（数值 × 62 得到实际世界像素）：
##   battle   1.40 →  87px（黄巾军/山贼：成队人马，比单人略高）
##   event    1.10 →  68px（隐士/伤兵/流民，场景里有人）
##   merchant 1.05 →  65px（商队）
##   treasure 0.85 →  53px（宝箱是物件，约为人高 0.44）
##   gather   0.85 →  53px（矿脉/药草/渔点，同为物件）
const ENC_TYPE_SCALE := {
	"battle": 1.40,
	"event": 1.10,
	"merchant": 1.05,
	"treasure": 0.85,
	"gather": 0.85,
}
## BOSS 级强敌（张角等）再放大一档，"大敌当前"要一眼可辨
const ENC_BOSS_SCALE := 1.25

## 【第六十六轮·密度放宽】旧间距 220px 是配 54px 小图标定的：图标放大到
## 放大后两点边缘只剩几十像素，画面上挤成一堆；玩家 250px/s 走直线
## 不到一秒撞一个 —— 用户反馈「走不了几步就有宝箱」的直接来源。
## 现放宽到 620px（≥10 个图标身位），并把数量改由面积反推。
const ENC_MIN_GAP := 620.0
## 城池图标宽 384px（半宽 192），旧值 180 会让遭遇物压在城墙上
const ENC_CITY_GAP := 300.0
## 每个遭遇物平均分摊的地图面积（px²）。数量由它反推，
## 地图再大也只是"摊得开"，不会像旧式（面积/90 万）那样越铺越密。
const ENC_AREA_PER_ONE := 2.6e6
const ENC_MAX_COUNT := 70
## 名称 /「▲ 可交互」提示的标签宽度（居中对齐用，避免长短名字左右乱跑）
const ENC_LABEL_W := 260.0
## 有类型的扩展名候选表：避免 for 循环变量退化为 Variant（会导致 := 无法推断类型）
const TEX_EXT_CANDIDATES: Array[String] = [".png", ".webp", ".jpg"]

@export var region_id: String = "nanzhong"
@export var map_size: Vector2 = Vector2(2400, 1400)
@export var spawn_count: int = 10
@export var rng_seed: int = 20260922

var _encounters_table: Array = []
var _rng := RandomNumberGenerator.new()
var _player: Node2D
var _triggered_ids := {}
var _gather_counts := {}     ## 每日采集计数：enc_id -> count
var _def_resolved := {}      ## 每日按遭遇定义的结算次数：def_id -> count（R2-12 反无限刷）
var _current_day := 0
var _region_origin := Vector2.ZERO   ## 当前区域矩形左上角（把世界坐标本地化生成）
## 【第五十四轮】已生成的遭遇节点缓存（生成时登记，区域重载时清空）。
## 供 _process / nearest_interactable 遍历，替代每帧 get_children()。
var _enc_nodes: Array[Node2D] = []
## 【第五十四轮】其中的「手动交互类」子集（_is_manual 为真）。
## 提示显隐只作用在这批节点上，把第二遍遍历从 140 缩到实际的手动点数量，
## 不必每帧对每个战斗点重判一次类型。
var _manual_nodes: Array[Node2D] = []


func _ready() -> void:
	_rng.seed = rng_seed
	_encounters_table = DataManager.get_table("encounters")
	_player = get_parent().get_node_or_null("Player")
	EventBus.day_passed.connect(_on_day_passed)
	# 分区加载：跟随当前游戏区域，把生成窗口锁定到该区域矩形（RegionService/D-04）
	region_id = GameState.current_region
	var rect := RegionService.region_rect(region_id)
	if rect.size.x > 0.0 and rect.size.y > 0.0:
		_region_origin = rect.position
		map_size = rect.size
	_spawn_all()


## 原地切换区域后重建遭遇物（全国连续行走后，区域只决定遭遇的分布窗口，
## 不再整场景重载 —— 清空旧标记按新区域矩形重新播撒）。
##
## 【第六十八轮·深度排序】旧写法 `for c in get_children()` 在本轮**已经失效**：
## 遭遇节点已被搬进大地图的 ActorLayer（y_sort 层），本容器已空，
## 遍历零次迭代且**不报任何错** → 切区时旧遭遇点永远不释放、新点叠上去。
## 改用 _enc_nodes 缓存（第 54 轮建的），它与节点集合严格等价。
func reload_region() -> void:
	for c in _enc_nodes:
		if is_instance_valid(c):
			c.queue_free()
	_triggered_ids.clear()
	# 【第五十四轮】缓存必须与子节点同步清空，否则 _process 会遍历到已释放的节点
	_enc_nodes.clear()
	_manual_nodes.clear()
	region_id = GameState.current_region
	var rect := RegionService.region_rect(region_id)
	if rect.size.x > 0.0 and rect.size.y > 0.0:
		_region_origin = rect.position
		map_size = rect.size
	_rng.seed = rng_seed + int(Time.get_ticks_msec() / 1000)   # 换个分布，避免与旧区域完全一致
	_spawn_all()
	# 【第六十八轮】重建完成后通知外部：新节点在旧的 Encounters 容器里，
	# 需要搬进 y_sort 层才能参与前后遮挡。
	actors_reparented.emit()


## 当前区域可用的遭遇定义（regions 为空或含本区域，或含 "china" 通配=全区域）
func _available_defs() -> Array:
	var result: Array = []
	var lv := GameState.player_level
	for e in _encounters_table:
		# 【Post-game 数值铺量】可选 min_player_level 门控：低于该等级的玩家不会撞上
		# 高等级遭遇。没有这道闸，「百战之师」（lv70+）会在开局就撒进南中。
		if int(e.get("min_player_level", 0)) > lv:
			continue
		var regions: Array = e.get("regions", [])
		if regions.is_empty() or region_id in regions or "china" in regions:
			result.append(e)
	return result


## 生成全部遭遇物
func _spawn_all() -> void:
	var defs := _available_defs()
	if defs.is_empty():
		return
	# 按权重构建取样池（当日已结算到上限的定义不再播撒，R2-12）
	var pool: Array = []
	for d in defs:
		if int(_def_resolved.get(str(d.get("id", "")), 0)) >= RESOLVE_CAP_PER_DEF:
			continue
		for i in range(int(d.get("weight", 10))):
			pool.append(d)
	if pool.is_empty():
		return

	# 生成数量按「每个遭遇物分摊多少面积」反推（大图铺得开，但不会越铺越密）。
	# 旧式是 面积/90 万 + 上限 140 —— 全国图上会撒到 115 个，配上 220px 间距
	# 就是「三步一宝箱」。改为 面积/260 万 + 上限 70。
	var count := clampi(int(map_size.x * map_size.y / ENC_AREA_PER_ONE),
		spawn_count, ENC_MAX_COUNT)
	var tries := 0
	var placed := 0
	while placed < count and tries < count * 12:
		tries += 1
		var def: Dictionary = pool[_rng.randi_range(0, pool.size() - 1)]
		# 区域窗口：位置在本区域矩形内（本地坐标 + 区域左上角偏移回世界坐标）
		var local := Vector2(
			_rng.randf_range(120, map_size.x - 120),
			_rng.randf_range(120, map_size.y - 120)
		)
		var pos := _region_origin + local
		# 避开城池标记附近
		if _too_close_to_city(pos):
			continue
		# 避开已有遭遇，避免挤成一堆
		if _too_close_to_encounter(pos):
			continue
		# 跳过本局已解决的遭遇（战斗/宝箱/商队）。EncounterManager 随 world_map 重载时
		# _triggered_ids 会清空，但若不跳过，遭遇物会用固定种子在原位重生，而玩家撤离后
		# 仍在原地，下一帧立刻再次触发，形成「撤退/打完又进战斗」的死循环。
		var enc_id := "%s_%d_%d" % [str(def.get("id", "e")), int(pos.x), int(pos.y)]
		if _is_resolved(enc_id):
			continue
		_spawn_one(def, pos, enc_id)
		placed += 1


## 该点是否离已有遭遇点太近（撒点时避免重叠）。
## 【第六十八轮】改用 _enc_nodes 缓存：节点已搬进 y_sort 层，本容器已空。
func _too_close_to_encounter(pos: Vector2) -> bool:
	for node in _enc_nodes:
		if node is Node2D:
			if pos.distance_to(node.position) < ENC_MIN_GAP:
				return true
	return false


func _too_close_to_city(pos: Vector2) -> bool:
	var cities := DataManager.get_table("cities")
	for c in cities:
		var cp := Vector2(float(c.get("map_x", 0)), float(c.get("map_y", 0)))
		if pos.distance_to(cp) < ENC_CITY_GAP:
			return true
	return false


## 某个遭遇定义在世界中的目标高度（类型倍率 × BOSS 加成）
func _enc_height(def: Dictionary) -> float:
	var h := ENC_WORLD_HEIGHT * float(ENC_TYPE_SCALE.get(
		str(def.get("type", "battle")), 1.0))
	if bool(def.get("boss", false)) or str(def.get("id", "")).ends_with("_boss"):
		h *= ENC_BOSS_SCALE
	return h


func _spawn_one(def: Dictionary, pos: Vector2, id: String) -> void:
	var node := Node2D.new()
	node.name = "Enc_" + id
	node.position = pos
	node.set_meta("enc_def", def)
	node.set_meta("enc_id", id)
	add_child(node)
	# 【第五十四轮】登记进缓存数组：_process / nearest_interactable 此前
	# 每次都 get_children() 全量遍历（大地图最多 140 个遭遇点），
	# 且每帧对每个点做 has_meta + get_meta 字典查找。生成期登记一次即可，
	# 避免每帧重复做与「节点集合」无关的工作。
	_enc_nodes.append(node)

	# 图标：优先用美术立绘（AI 批次，18 种遭遇各一张），缺失时回退几何菱形。
	# 支持 def.icon 字段复用既有立绘（剧情遭遇无专属图时可指向同类图）。
	var tex := _get_enc_icon(str(def.get("icon", def.get("id", ""))))
	# 【第六十六轮】所有纵向偏移改由 h 推导，图标放大后脚底仍落在地面 y=20
	var h := _enc_height(def)
	if tex:
		var sp := Sprite2D.new()
		sp.texture = tex
		# 立绘按目标世界高度等比缩放，锚点取"脚底落地"位
		var sc := h / maxf(1.0, float(tex.get_height()))
		sp.scale = Vector2(sc, sc)
		sp.position = Vector2(0, 20.0 - h * 0.5)
		# 【R3-05】描金外发光：同纹理 ×1.08 垫在立绘下层，暗地形上轮廓立现
		var rim := Sprite2D.new()
		rim.texture = tex
		rim.scale = sp.scale * 1.08
		rim.position = sp.position
		rim.modulate = UITheme.GOLD_DIM
		node.add_child(rim)
		node.add_child(sp)
		# 【R3-13】脚下投影统一为椭圆（与城池 marker 同语言，α=0.20 对齐 CityMarkerArt._add_shadow）
		# 旧半轴写死 21×8（对应 54px 图标），放大后必须按高度联动，否则影子比脚还小
		var halo := Polygon2D.new()
		halo.polygon = CityMarkerArt._ellipse(h * 0.39, h * 0.15, 18)
		halo.color = Color(0, 0, 0, 0.20)
		halo.position = Vector2(0, 20)
		node.add_child(halo)
		node.move_child(halo, 0)   ## 投影垫最底（加入 rim 后原 count-2 会插进中层）
	else:
		var color := Color(def.get("icon_color", "#FFFFFF"))
		var icon := _make_diamond(color, h)
		node.add_child(icon)

	# 名称
	# 【第六十六轮】旧写法 position=(-36, 26) 是给 54px 图标配的固定左偏移，
	# 且未设对齐：名字长短不一 → 有的压在图形左肩、有的拖到右边。
	# 改为固定宽度 + 居中对齐，中心恒在 x=0，与图标同轴。
	var label := Label.new()
	label.text = str(def.get("name", ""))
	label.add_theme_font_size_override("font_size", UITheme.FS_MARKER_NAME)
	label.size = Vector2(ENC_LABEL_W, 44.0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector2(-ENC_LABEL_W * 0.5, 26.0)
	label.modulate = Color(1, 1, 1, 0.85)
	node.add_child(label)

	# 手动交互提示（非战斗类型）：玩家进入范围时亮起，点交互按钮触发
	if _is_manual(def):
		var hint := Label.new()
		hint.name = "Hint"
		hint.text = "▲ 可交互"
		hint.add_theme_font_size_override("font_size", UITheme.FS_MARKER_NOTE)
		# 浮在图标顶上：顶边 y = 20-h，再留 46px 呼吸，图标放大也不会压住字
		hint.size = Vector2(ENC_LABEL_W, 40.0)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint.position = Vector2(-ENC_LABEL_W * 0.5, 20.0 - h - 46.0)
		hint.modulate = Color(1.0, 0.92, 0.60, 0.95)
		hint.visible = false
		node.add_child(hint)
		# 【第五十四轮】提示显隐只对手动类有意义，单独登记一份子集，
		# 让每帧「只亮最近一个」那一遍不必扫全部遭遇点。
		_manual_nodes.append(node)


## 开关某个遭遇物头顶的「▲ 可交互」提示
func _set_hint(node: Node2D, on: bool) -> void:
	var h := node.get_node_or_null("Hint")
	if h is CanvasItem:
		var c := h as CanvasItem
		# 【第五十四轮】仅在真的变化时写 visible：写同值也会触发属性通知，
		# 让 CanvasItem 标记重绘失效。每帧无条件写 140 次是白开销。
		if c.visible != on:
			c.visible = on


## 供 world_map 交互按钮查询：范围内最近的可手动触发遭遇（无则返回空字典）
func nearest_interactable(player_pos: Vector2) -> Dictionary:
	# 【第五十四轮】与 _process 一并改走 _enc_nodes 缓存 + 平方距离。
	# 保留 visible 判定：结算后的节点可能仍挂在树上但已不可交互。
	var best: Node2D = null
	var best_d2 := INF
	var r2 := INTERACT_RADIUS * INTERACT_RADIUS
	for node in _enc_nodes:
		if not is_instance_valid(node) or not node.visible:
			continue
		var enc_id: String = node.get_meta("enc_id")
		if _triggered_ids.has(enc_id):
			continue
		var def: Dictionary = node.get_meta("enc_def")
		if not _is_manual(def):
			continue
		var d2 := player_pos.distance_squared_to(node.position)
		if d2 < r2 and d2 < best_d2:
			best_d2 = d2
			best = node
	if best == null:
		return {}
	return {
		"node": best,
		"def": best.get_meta("enc_def"),
		"id": str(best.get_meta("enc_id")),
		# 【第五十四轮·注意】上面比较用的是**平方距离**（省开方），
		# 但对外契约一直是真实距离。必须开方还原，
		# 否则调用方拿到的 dist 会是距离的平方（量级完全不对，且不报错）。
		"dist": sqrt(best_d2),
	}


## 手动触发入口（world_map 交互菜单「交 互」调用）
func trigger_encounter(node: Node2D) -> void:
	if node != null and is_instance_valid(node) and node.has_meta("enc_def"):
		_set_hint(node, false)
		_trigger(node)


## 尝试加载遭遇图标贴图（res://assets/sprites/encounters/<id>.png）
func _get_enc_icon(enc_id: String) -> Texture2D:
	if enc_id.is_empty():
		return null
	for ext in TEX_EXT_CANDIDATES:
		var path: String = ENC_TEX_DIR + enc_id + ext
		if ResourceLoader.exists(path):
			var res := load(path)
			if res is Texture2D:
				return res
	return null


## 无贴图时的几何菱形兜底。旧尺寸写死 ±18（配 54px 图标），
## 放大后必须按目标高度走，否则有图/无图两类遭遇物会差出三倍大。
func _make_diamond(color: Color, h: float = ENC_WORLD_HEIGHT) -> Polygon2D:
	var r := h * 0.33
	var poly := Polygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(0, -r), Vector2(r, 0), Vector2(0, r), Vector2(-r, 0)
	])
	poly.color = color
	# 描边
	var outline := Line2D.new()
	outline.points = PackedVector2Array([
		Vector2(0, -r), Vector2(r, 0), Vector2(0, r), Vector2(-r, 0), Vector2(0, -r)
	])
	outline.width = maxf(2.0, h * 0.03)
	outline.default_color = color.darkened(0.4)
	poly.add_child(outline)
	return poly


func _is_manual(def: Dictionary) -> bool:
	# 【R2-03】BOSS 级强敌（如张角）带 manual_trigger 标记：不自动开战，
	# 走近亮「▲ 可交互」，玩家点交互钮才交手 —— 打不打、何时打，由玩家决定。
	if bool(def.get("manual_trigger", false)):
		return true
	return str(def.get("type", "battle")) in MANUAL_TYPES


func _process(_delta: float) -> void:
	if _player == null:
		return
	# 【第五十四轮】性能改造，但**判定顺序与语义保持原样**，只砍掉三处浪费：
	#   ① 走 _enc_nodes 缓存数组，不再每帧两次 get_children() 全量遍历
	#      （大地图最多 140 个遭遇点 → 原 280 次遍历）；
	#   ② 用 distance_squared_to 替代 distance_to，省掉每点一次开方；
	#   ③ 提示显隐那一遍只扫 _manual_nodes 子集，且 _set_hint 内部
	#      「仅变化才写 visible」，不再每帧无条件写 140 次属性通知。
	#
	#【顺序铁律·勿调换】_triggered_ids 必须先于 _is_manual 判定：
	#   战斗点被 _trigger 结算后会写 _triggered_ids 并 _hide。若把类型判定提前，
	#   已结算的战斗点会落到「走近自动触发」分支里被**每帧重复触发**，
	#   导致站着不动也反复开战斗场景（encounter_triggered 被连发）。
	var ppos := _player.position
	var r2 := INTERACT_RADIUS * INTERACT_RADIUS
	var near_manual: Node2D = null
	var near_d2 := INF
	for node in _enc_nodes:
		if not is_instance_valid(node):
			continue
		var enc_id: String = node.get_meta("enc_id")
		if _triggered_ids.has(enc_id):
			continue      # 已结算：战斗类不再触发，手动类交给下面统一收提示
		var def: Dictionary = node.get_meta("enc_def")
		if not _is_manual(def):
			# 战斗类：保持走近自动触发
			if ppos.distance_squared_to(node.position) < r2:
				_trigger(node)
			continue
		# 手动类型：只在范围内亮提示，绝不自动触发
		var d2 := ppos.distance_squared_to(node.position)
		if d2 < r2 and d2 < near_d2:
			near_d2 = d2
			near_manual = node
	# 只亮最近一个「▲ 可交互」，其余收起。
	# 恒等式赋值（而不是「谁不是最近就收起谁」）——后者有遍历顺序依赖：
	# 远点若先被访问并临时占位 near_manual，后续近点抢走后它就走不到收起分支，
	# 上一帧亮着的提示会留在屏幕上，同屏出现两串「▲ 可交互」。
	for node in _manual_nodes:
		if is_instance_valid(node):
			_set_hint(node, node == near_manual)


## 触发遭遇
func _trigger(node: Node2D) -> void:
	var def: Dictionary = node.get_meta("enc_def")
	var enc_id: String = node.get_meta("enc_id")
	var type := str(def.get("type", "battle"))

	match type:
		"gather":
			_handle_gather(node, def, enc_id)
		"treasure":
			_handle_treasure(node, def, enc_id)
		"event":
			_handle_event(node, def, enc_id)
		"merchant":
			_handle_merchant(node, def)
			_note_resolved(def, enc_id)       # 商队触发一次后暂时消失
			_hide(node)
		_:
			# 战斗类【M-4 修复】：不再「触发即永久解决」——原实现战败/战前
			# 撤退也写 encounter_resolved，这批怪永久消失。改为只做本场景
			# 防重复标记，并把 enc_id 注入 def 副本随身携带；分出胜负后由
			# battle_scene 写 GameState.encounter_resolved（胜利=永久解决，
			# 战败=当日封锁、次日原地复活可再战）。
			_triggered_ids[enc_id] = true
			_hide(node)
			var enc := def.duplicate()
			enc["_enc_id"] = enc_id
			# 遭遇战开打号角（急促战鼓），补齐战斗链路第一声反馈
			AudioManager.play_sfx("res://assets/audio/sfx/encounter_battle.ogg")
			encounter_triggered.emit(enc)
			EventBus.show_toast("遭遇 %s！" % def.get("name", "敌人"))


func _handle_gather(node: Node2D, def: Dictionary, enc_id: String) -> void:
	var limit := int(def.get("daily_limit", 5))
	# 【M-2 修复】计数键从实例 enc_id（含生成坐标）改为 def.id：
	# enc_id = "id_x_y"，跨区重撒换种子后坐标全变、键全换新，同一天
	# 换个区域采集计数就归零，每日上限形同虚设。改按遭遇定义计数。
	var gkey := str(def.get("id", enc_id))
	var used := int(_gather_counts.get(gkey, 0))
	if used >= limit:
		# 【R1-04】采满每日上限才移出可交互列表；采集已改手动交互（不会每帧连采），
		# 未满时保持可点，否则 daily_limit>1 的采集点一次都采不满
		_triggered_ids[enc_id] = true
		EventBus.show_toast("此处今日已采完，明日再来")
		return
	_gather_counts[gkey] = used + 1

	var item_id := str(def.get("gather_item", ""))
	var count := int(def.get("gather_count", 1))
	GameState.add_item(item_id, count)
	# 任务记账：采集物本身计 collect；采集点可用 quest_event 计特殊事件（如 fish）
	if not item_id.is_empty():
		QuestService.record_event("collect", item_id, count)
	var qev := str(def.get("quest_event", ""))
	if not qev.is_empty():
		QuestService.record_event(qev, str(def.get("quest_target", "any")), count)
	var item := DataManager.get_item(item_id)
	var item_name := str(item.get("name", item_id)) if not item.is_empty() else item_id

	AudioManager.play_sfx("res://assets/audio/sfx/gather_ok.ogg")
	EventBus.show_toast("采集到 %s ×%d（今日 %d/%d）" % [item_name, count, used + 1, limit])
	encounter_triggered.emit(def)


func _handle_treasure(node: Node2D, def: Dictionary, enc_id: String) -> void:
	_note_resolved(def, enc_id)
	_hide(node)

	var loot: Array = def.get("loot_table", [])
	if loot.is_empty():
		EventBus.show_toast("箱子是空的")
		return
	var pick: String = str(loot[_rng.randi_range(0, loot.size() - 1)])
	GameState.add_item(pick, 1)
	QuestService.record_event("collect", pick, 1)
	var item := DataManager.get_item(pick)
	var item_name := str(item.get("name", pick)) if not item.is_empty() else pick
	AudioManager.play_sfx("res://assets/audio/sfx/treasure_open.ogg")
	EventBus.show_toast("打开宝箱，获得：%s（已入背包）" % item_name)
	# 剧情/信物解锁：rewards.unlock（如南中隐藏宝箱内的建国信物）
	QuestService.apply_unlock_value(def.get("rewards", {}).get("unlock", ""))
	encounter_triggered.emit(def)


func _handle_merchant(node: Node2D, def: Dictionary) -> void:
	EventBus.show_toast("遇到行商，打开交易")
	encounter_triggered.emit(def)


## 随机事件：一次性结算（跨场景重载不复活），弹选项由 world_map 承接
func _handle_event(node: Node2D, def: Dictionary, enc_id: String) -> void:
	_note_resolved(def, enc_id)
	_hide(node)
	encounter_triggered.emit(def)


## 统一记录一次「已解决」：写全局已解决表（按 enc_id，跨场景不原地重生）
## + 按遭遇定义累一次当日计数（R2-12，跨区重撒不再无限刷同一批怪）。
## 采集类不走这里：它有自己的 daily_limit，且次日需要原地复活。
func _note_resolved(def: Dictionary, enc_id: String) -> void:
	_triggered_ids[enc_id] = true
	GameState.encounter_resolved[enc_id] = true
	var def_id := str(def.get("id", ""))
	_def_resolved[def_id] = int(_def_resolved.get(def_id, 0)) + 1


## 已解决判定【M-4】：值为 true = 胜利永久解决；值为 int（绝对游戏日）
## = 战败当日封锁，次日判定不再命中 → 原地复活可再战。
func _is_resolved(enc_id: String) -> bool:
	var r: Variant = GameState.encounter_resolved.get(enc_id, false)
	if r is bool:
		return bool(r)
	return int(r) >= _absolute_day()


## 绝对游戏日（月固定 30 天，复用 GameState.total_days 的口径）
func _absolute_day() -> int:
	return GameState.total_days()


func _hide(node: Node2D) -> void:
	node.visible = false
	node.set_process(false)


## 每日重置采集计数
func _on_day_passed(_y: int, _m: int, d: int) -> void:
	if d != _current_day:
		_current_day = d
		_gather_counts.clear()
		_def_resolved.clear()   ## R2-12：跨区刷怪配额随日恢复
		_respawn_daily()


## 每日重新生成部分遭遇（保持世界活力）
## 采集点次日恢复可交互（战斗/宝箱已解决的不复活）
## 【第六十八轮】改用 _enc_nodes 缓存：节点已搬进 y_sort 层，本容器已空。
## 若仍遍历 get_children()，采集点会**永远不再恢复**（玩家以为采集点只有一次性）。
func _respawn_daily() -> void:
	for node in _enc_nodes:
		if not (node is Node2D) or not node.has_meta("enc_def"):
			continue
		var def: Dictionary = node.get_meta("enc_def")
		if str(def.get("type", "")) != "gather":
			continue
		var enc_id: String = node.get_meta("enc_id")
		_triggered_ids.erase(enc_id)
