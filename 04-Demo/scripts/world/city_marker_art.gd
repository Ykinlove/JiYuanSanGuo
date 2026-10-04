extends RefCounted
class_name CityMarkerArt
## 地图地点标记美术模块（CityMarkerArt）
## ------------------------------------------------------------------
## 职责：为一类地点生成有辨识度的程序化图形，替代原先「统一方框」的做法。
## 全部用 Polygon2D / Line2D 绘制，不依赖外部贴图；若日后放了贴图，
## 由 `_try_texture()` 自动改用贴图（约定路径 assets/sprites/map/<id>.png）。
##
## 造型约定（一眼可辨）：
##   city    —— 城墙 + 垛口 + 城楼 + 旗（大）
##   village —— 茅屋群 + 篱笆（小）
##   pass    —— 两侧山崖 + 中间隘口
##   ruin    —— 断柱 + 残垣
##   capital —— 更高城楼 + 双旗 + 金色描边
## ------------------------------------------------------------------

## 调色板（二次元国风：偏暖的土黄/青灰 + 金色描边）
const C_WALL := Color(0.76, 0.66, 0.47)
const C_WALL_DARK := Color(0.52, 0.43, 0.29)
const C_ROOF := Color(0.62, 0.28, 0.24)
const C_ROOF_DARK := Color(0.42, 0.18, 0.16)
const C_WOOD := Color(0.58, 0.44, 0.29)
const C_STONE := Color(0.60, 0.60, 0.63)
const C_STONE_DARK := Color(0.40, 0.40, 0.44)
const C_GOLD := Color(0.88, 0.74, 0.40)
const C_FLAG := Color(0.82, 0.30, 0.26)


## 类型图标目录与各类型缩放（新美术批次：AI 手绘城池图标 128×128）
## 【三十五轮微调】×3 仍偏大，定档 ×2.5：city 3.0 档（384 世界px）。
const TYPE_ICON_DIR := "res://assets/sprites/city_icons/"
const TYPE_ICON_SCALE := {
	"city": 3.00,
	"village": 2.48,
	"pass": 2.55,
	"ruin": 2.25,
	"landmark": 2.63,
}

## 势力配色：读 factions6.color（数据驱动）；缺色按 id 哈希稳定取色；
## 中立(faction_id==0) 灰；玩家已占（captured_cities）金。让归属一眼可辨。
const C_NEUTRAL := Color(0.62, 0.64, 0.68)
const C_PLAYER := Color(0.95, 0.78, 0.30)

static func faction_color(city: Dictionary) -> Color:
	var cid := str(city.get("id", ""))
	# 【本轮加固】GameState / DataManager 都是 autoload，而
	# `--headless --script` **不加载 autoload** → 直接在标识符处编译失败，
	# 连带 TerrainPainter / 整个城池接地链路一起编不过，
	# 于是「城池有没有站在地形上」这件事**根本无法被无头测量**。
	# 表现层对数据层零容错本身也是缺陷：正常运行期若数据缺失会直接崩，
	# 而这只该让城池退回中性配色，不该让整个模块不可用。
	var gs := _autoload("GameState")
	if gs != null:
		var cap: Variant = gs.get("captured_cities")
		if cap is Array and (cap as Array).has(cid):
			return C_PLAYER
	var fid := int(city.get("faction_id", 0))
	if fid <= 0:
		return C_NEUTRAL
	var dm := _autoload("DataManager")
	if dm != null and dm.has_method("get_faction6"):
		var f: Variant = dm.call("get_faction6", fid)
		if f is Dictionary:
			var hex := str((f as Dictionary).get("color", ""))
			var parsed := _parse_hex(hex)
			if parsed.a > 0.0:
				return parsed
	return _hash_color(fid)


## 取 autoload 单例；无头环境（不加载 autoload）返回 null。
## 本类 extends RefCounted，**没有 is_inside_tree()**（那是 Node 的方法），
## 想拿 SceneTree 只能问 Engine。
static func _autoload(name: String) -> Object:
	if Engine.has_singleton(name):
		return Engine.get_singleton(name)
	if Engine.get_main_loop() is SceneTree:
		return (Engine.get_main_loop() as SceneTree).root.get_node_or_null(
			"/root/" + name)
	return null

## 解析 #RRGGBB；非法返回透明（alpha=0 表示缺色）
static func _parse_hex(hex: String) -> Color:
	var h := hex.strip_edges()
	if h.begins_with("#"):
		h = h.substr(1)
	if h.length() != 6:
		return Color(0, 0, 0, 0)
	var r := h.substr(0, 2).hex_to_int()
	var g := h.substr(2, 2).hex_to_int()
	var b := h.substr(4, 2).hex_to_int()
	if r < 0 or g < 0 or b < 0:
		return Color(0, 0, 0, 0)
	return Color(float(r) / 255.0, float(g) / 255.0, float(b) / 255.0, 1.0)

## 按势力 id 哈希出稳定色相（缺色兜底，避免撞色太丑）
static func _hash_color(fid: int) -> Color:
	var hue := int(fid * 2654435761) % 360
	return Color.from_hsv(float(hue) / 360.0, 0.55, 0.82)
## 图标素材的基准边长（AI 批次类型图标为 128×128）。
## 有了它就能按「目标世界宽度」反算缩放，素材换成 256/512 都不会走样。
const ICON_BASE_PX := 128.0

## 【本轮·第 5 项第七层】城池贴地倾斜参数。
## 与玩家侧 world_map 的 MAX_TILT_DEG=14 保持一致 —— 城与角色在同一张地面上，
## 两者的倾斜上限必须相同，否则会出现「城歪 20°、旁边的角色只歪 14°」的割裂感。
const CITY_MAX_TILT_DEG := 14.0
## 坡度 → 倾斜的增益。与玩家侧同值（法线 z 越接近 1 越平，weight 越接近 0）。
const CITY_TILT_GAIN := 6.0
## 专属贴图（map/<id>.png）相对类型贴图的放大倍数，让名城更醒目
const UNIQUE_BOOST := 1.14


## 构建一个地点的全部图形，挂到 marker 下
## 优先级：专属贴图（map/<id>.png）→ 类型贴图（city_icons/<type>.png）→ 程序化绘制
static func build(marker: Node2D, city: Dictionary, world: Vector2 = Vector2.ZERO,
		mesh: TerrainMesh = null) -> void:
	# 【本轮·第 5 项第七层】城池视觉融入地形。
	# 【根因·取证结论】world_map._apply_height 会给固定实体抬升，但它找的是
	# `Art` / `Visual` 子节点 —— 而本模块原先**把 Sprite2D/Polygon2D 直接挂在
	# marker 上**，两者都没有 → `_apply_height` **静默 return**，
	# 于是 110 个城池**从未被抬升过**，全贴在原始平面上（贴图感的直接来源）。
	# 现补上 Art 容器，_apply_height 的既有逻辑即可接管，本模块不重复实现。
	# 【为什么要单独一层】marker.position 是**原始地图坐标**，
	# 被交互判定（_find_nearest_place 的距离、_place_radius 半径）直接读，
	# 改它会让「走到城下」的距离判定与存档坐标全错
	# （与 MEMORY「高度场只抬可视子节点、绝不改实体 position」同源铁律）。
	var art: Node2D = null
	if world != Vector2.ZERO:
		art = Node2D.new()
		art.name = "Art"
		marker.add_child(art)
		# 按脚下坡度倾斜：竖直戳在斜面上的城读起来仍是「贴图浮空」。
		# 【法线必须取自 mesh】玩家侧用的是 _terrain_mesh.normal_at（TerrainMesh
		# 的实例方法），而 TerrainHeight 只有 elevation/lift、没有法线 ——
		# 两边各算一份必然对不上，故 mesh 由调用方传入。
		if mesh != null:
			apply_tilt(art, float(city.get("map_x", 0)),
				float(city.get("map_y", 0)), mesh)
	# 无 world（无头测试 / 旧调用方）时退回直接画在 marker 上，行为不变
	var host: Node2D = art if art != null else marker
	_build_onto(host, city, art != null)


## 按脚下坡度把城池**倾斜**，让它站在斜面上而不是竖直浮着。
## 【与玩家侧同源】权重公式、限幅、旋转方向全部照抄 world_map._apply_slope_tilt ——
## 城与角色在同一张地面上，两者对坡度的反应必须一致，否则读起来是「城在斜面上、
## 角色在平地上」这种自相矛盾。
## 【为什么是 public】world_map._setup_terrain_mesh 在 mesh 建成后会回头给
## 全部已生成 marker 补一次倾斜（生成时 mesh 还没建，见该处说明）。
static func apply_tilt(art: Node2D, wx: float, wy: float, mesh: TerrainMesh) -> void:
	if art == null or mesh == null:
		return
	var n := mesh.normal_at(wx, wy)
	var weight := clampf(1.0 - n.z, 0.0, 1.0) * CITY_TILT_GAIN
	weight = clampf(weight, 0.0, 1.0)
	if weight <= 0.01:
		art.rotation = 0.0
		return
	# Godot 2D 正 rotation = 顺时针（y 轴朝下）；法线 xy 投影指向上坡方向，
	# 城池应朝反方向倾（与玩家侧同解）。
	art.rotation = clampf(atan2(-n.x, n.y) * weight,
		-deg_to_rad(CITY_MAX_TILT_DEG), deg_to_rad(CITY_MAX_TILT_DEG))


## 真正的绘制（原先直接画在 marker 上，现在画在 host 上）。
## shadow_anchor 非空时，投影要挂到**它所在的那一层** —— 抬升后投影必须跟着走，
## 否则图标升了、影子留在原地，就成了「悬空」。
static func _build_onto(host: Node2D, city: Dictionary,
		_lifted: bool) -> void:
	var t := str(city.get("type", "city"))
	var is_capital := bool(city.get("is_capital", false))
	var base_scale := float(TYPE_ICON_SCALE.get(t, 2.0))

	# 势力色底盘（归属一眼可辨；中立灰 / 玩家金 / 各势力色），置于最底层
	_add_faction_base(host, city, t, is_capital)

	var tex := _try_texture(str(city.get("id", "")))
	var is_unique := tex != null
	if not is_unique:
		tex = _type_texture(t)
	if tex != null:
		# 目标世界宽度：类型基准 × 128px；专属贴图再放大一档
		var target := base_scale * ICON_BASE_PX
		if is_unique:
			target *= UNIQUE_BOOST
		if is_capital:
			target *= 1.18          # 都城整体放大，更醒目
		var sc := target / maxf(1.0, float(tex.get_width()))
		var sp := Sprite2D.new()
		sp.texture = tex
		sp.scale = Vector2(sc, sc)
		host.add_child(sp)
		_add_shadow(host, target * 0.30, 0.5)
		return

	match t:
		"city":
			_draw_city(host, is_capital)
		"village":
			_draw_village(host)
		"pass":
			_draw_pass(host)
		"ruin":
			_draw_ruin(host)
		_:
			_draw_city(host, false)


## 势力色底盘：外环（实色）+ 内盘（淡色）叠出一圈，置于 marker 最底层。
## 让玩家一眼分清中立/各势力/自己地盘；AI 攻城翻转 faction_id 后随标记重建实时更新。
static func _add_faction_base(p: Node2D, city: Dictionary, t: String, is_capital: bool) -> void:
	var col := faction_color(city)
	var rx := 32.0
	var ry := 11.0
	if t == "city":
		rx = 40.0 if is_capital else 32.0
	elif t == "village":
		rx = 26.0
	elif t == "pass":
		rx = 30.0
	elif t == "ruin":
		rx = 24.0
	# 外环（实色，作描边）
	var ring := Polygon2D.new()
	ring.polygon = _ellipse(rx + 2.5, ry + 1.5, 22)
	ring.color = col
	ring.position = Vector2(0, 13)
	p.add_child(ring)
	# 内盘（淡色），叠在外环上形成圈
	var disc := Polygon2D.new()
	disc.polygon = _ellipse(rx, ry, 20)
	disc.color = Color(col.r, col.g, col.b, 0.30)
	disc.position = Vector2(0, 13)
	p.add_child(disc)
	p.move_child(ring, 0)
	p.move_child(disc, 1)


## 【本轮·性能】贴图查找缓存（静态，全进程共享）。
##
## 【为什么必须缓存·取证结论】`_try_texture` / `_type_texture` 原式每次调用都
## `ResourceLoader.exists(path)` —— 那是**一次真实磁盘 stat**（不是内存查表）。
## headless 插桩实测：`_spawn_city_markers` 单项耗 **1045ms**，是 world_map
## `_ready()` 总耗时 2715ms 里的最大一项，其主体就是 110 个城各做 1~3 次 stat。
## 而城 id 与 `assets/sprites/map/` 下的文件名**部分不匹配**：
## headless 插桩实测（第七十一轮）`_spawn_city_markers` 里贴图查找单项 **438ms**，
## 占该项 460ms 的 95%。逐项取证：110 城触发 110 次 miss（负缓存全生效、
## 二次调用零 stat），其中 **18 城命中真实贴图**（scene_17 / scene_103 等，
## 最慢单次 32ms —— 那是 load() 解码），其余 92 城查空。
## 而每次查空要连试 **3 个扩展名**（.png/.webp/.jpg）= 最多 330 次磁盘 stat。
##
## 【为什么缓存还不够】负缓存只省掉「第二次以后」，而本场景 110 城各查一次
## 恰好全是「第一次」—— 缓存命中率恒为 0，**438ms 一毫秒没省**。
## 根因是**用磁盘 stat 回答「这个 id 有没有图」**这个本该一次问清的问题。
##
## 【正解·一次性目录索引】开头扫一次目录，把「有哪些图」变成内存字典，
## 之后每次查询是纯内存查表。用 DirAccess 枚举而非逐个 exists()：
## 1 次 readdir（1 次系统调用批）替代最多 330 次 stat。
## 索引**惰性构建**（首次真正查图时才扫），保证不碰 units.json / cities.json
## 等玩家数据表，也不在无图场景（无头测试）付出扫描代价。
##
## 【key 前缀的必要性】`_try_texture` 的 key 是 city_id、`_type_texture` 的 key 是
## city_type，两者取值域**可能相同**（都有 "city"）。共用一个无前缀字典会让
## "城名恰好叫 city" 的城错拿到类型图标。故用 "m:" / "t:" 前缀分区。
static var _tex_cache: Dictionary = {}
const _TEX_EXTS: Array[String] = [".png", ".webp", ".jpg"]
## city_id -> res:// 完整路径。惰性构建，见_ensure_map_index。
static var _map_index: Dictionary = {}
static var _map_index_built: bool = false
## city_type -> res:// 完整路径。同一套惰性机制。
static var _type_index: Dictionary = {}
static var _type_index_built: bool = false


## 扫一次目录建索引：把 N 次 stat 压成 1 次 readdir。
## 【为什么用 DirAccess 而不是 exists()】exists() 每次都是一次独立系统调用；
## 而 readdir 是一次批量枚举。330 次 stat ≈ 300+ 次往返，1 次 readdir ≈ 1 次。
static func _ensure_map_index() -> void:
	if _map_index_built:
		return
	_map_index_built = true
	_scan_dir_into("res://assets/sprites/map/", "", _map_index)


static func _ensure_type_index() -> void:
	if _type_index_built:
		return
	_type_index_built = true
	_scan_dir_into(TYPE_ICON_DIR, "", _type_index)


## 把 dir 下所有贴图的「去扩展名文件名 -> res:// 路径」写进 out。
## 【扩展名优先级】同名多扩展名时按 _TEX_EXTS 的顺序取首个，
## 保证结果与原式「按 .png→.webp→.jpg 依次 exists」的优先级一致。
static func _scan_dir_into(dir_path: String, _prefix: String,
		out: Dictionary) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	# 先收集候选，再按扩展名优先级择一 —— 直接边遍历边写会被后到的覆盖。
	var found: Dictionary = {}   # base_name -> {ext_idx: full_path}
	for f in dir.get_files():
		var dot := f.rfind(".")
		if dot <= 0:
			continue
		var base := f.substr(0, dot)
		var ext := f.substr(dot)
		var idx := _TEX_EXTS.find(ext)
		if idx < 0:
			continue
		var slot: Dictionary = found.get(base, {})
		if not slot.has("i") or int(slot["i"]) > idx:
			slot["i"] = idx
			slot["p"] = dir_path + f
			found[base] = slot
	for base in found.keys():
		out[base] = String(found[base]["p"])


## 若放了贴图则优先用贴图（约定：assets/sprites/map/<id>.png|webp|jpg）
static func _try_texture(city_id: String) -> Texture2D:
	if city_id.is_empty():
		return null
	var key := "m:" + city_id
	if _tex_cache.has(key):
		return _tex_cache[key] as Texture2D
	_ensure_map_index()
	# 【纯内存查表】索引里没有 = 该城确定无专属图（负结论同样缓存）
	var found: Texture2D = null
	if _map_index.has(city_id):
		var res := load(String(_map_index[city_id]))
		if res is Texture2D:
			found = res
	_tex_cache[key] = found   # 正负都缓存
	return found


## 类型贴图：assets/sprites/city_icons/<type>.png（AI 美术批次）
static func _type_texture(city_type: String) -> Texture2D:
	var t := city_type if not city_type.is_empty() else "city"
	var key := "t:" + t
	if _tex_cache.has(key):
		return _tex_cache[key] as Texture2D
	_ensure_type_index()
	var found: Texture2D = null
	if _type_index.has(t):
		var res := load(String(_type_index[t]))
		if res is Texture2D:
			found = res
	_tex_cache[key] = found   # 正负都缓存
	return found


static func _add_shadow(p: Node2D, r: float, squash: float) -> void:
	var sh := Polygon2D.new()
	sh.polygon = _ellipse(r, r * squash, 18)
	sh.color = Color(0, 0, 0, 0.20)
	sh.position = Vector2(0, 8)
	p.add_child(sh)
	p.move_child(sh, 0)


static func _ellipse(rx: float, ry: float, seg: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(seg):
		var a := float(i) / float(seg) * TAU
		pts.append(Vector2(cos(a) * rx, sin(a) * ry))
	return pts


static func _poly(parent: Node2D, pts: Array, color: Color) -> Polygon2D:
	var p := Polygon2D.new()
	p.polygon = PackedVector2Array(pts)
	p.color = color
	parent.add_child(p)
	return p


static func _line(parent: Node2D, pts: Array, color: Color, w: float) -> Line2D:
	var l := Line2D.new()
	var pv := PackedVector2Array()
	for v in pts:
		pv.append(v)
	l.points = pv
	l.width = w
	l.default_color = color
	l.joint_mode = Line2D.LINE_JOINT_ROUND
	parent.add_child(l)
	return l


# ------------------------------------------------------------------
# 城池：城墙 + 垛口 + 城楼 + 旗
# ------------------------------------------------------------------

static func _draw_city(marker: Node2D, is_capital: bool) -> void:
	var w := 62.0 if is_capital else 50.0
	var h := 30.0 if is_capital else 25.0

	_add_shadow(marker, w * 0.62, 0.38)

	# 城墙主体
	_poly(marker, [
		Vector2(-w, 10), Vector2(w, 10), Vector2(w, 10 - h),
		Vector2(-w, 10 - h)
	], C_WALL)

	# 垛口（城头锯齿）
	var merlon := 4 if is_capital else 3
	var step := (w * 2) / float(merlon * 2 - 1)
	var top := 10 - h
	var pts: Array = []
	for i in range(merlon):
		var x0 := -w + i * step * 2
		pts.append(Vector2(x0, top))
		pts.append(Vector2(x0, top - 8))
		pts.append(Vector2(x0 + step, top - 8))
		pts.append(Vector2(x0 + step, top))
	_poly(marker, pts, C_WALL)

	# 城门
	_poly(marker, [
		Vector2(-9, 10), Vector2(9, 10), Vector2(9, -6), Vector2(-9, -6)
	], C_WALL_DARK)

	# 城楼（中央）
	var tw := 15.0 if is_capital else 12.0
	var th := 16.0 if is_capital else 12.0
	_poly(marker, [
		Vector2(-tw, top - 8), Vector2(tw, top - 8),
		Vector2(tw, top - 8 - th), Vector2(-tw, top - 8 - th)
	], C_WOOD)

	# 屋檐
	_poly(marker, [
		Vector2(-tw - 7, top - 8 - th),
		Vector2(tw + 7, top - 8 - th),
		Vector2(tw + 2, top - 8 - th - 9),
		Vector2(-tw - 2, top - 8 - th - 9)
	], C_ROOF)

	# 旗帜
	var fx := tw + 4
	var fy := top - 8 - th - 16
	_line(marker, [Vector2(fx, fy), Vector2(fx, fy + 20)], C_WOOD, 2.0)
	_poly(marker, [
		Vector2(fx, fy), Vector2(fx + 15, fy + 5), Vector2(fx, fy + 11)
	], C_FLAG)

	# 都城：加一圈金边 + 第二面旗
	if is_capital:
		_line(marker, [
			Vector2(-w, 10), Vector2(w, 10), Vector2(w, top),
			Vector2(-w, top), Vector2(-w, 10)
		], C_GOLD, 2.0)
		var fx2 := -tw - 4
		_line(marker, [Vector2(fx2, fy), Vector2(fx2, fy + 20)], C_WOOD, 2.0)
		_poly(marker, [
			Vector2(fx2, fy), Vector2(fx2 - 15, fy + 5), Vector2(fx2, fy + 11)
		], C_FLAG)
	else:
		_line(marker, [
			Vector2(-w, 10), Vector2(w, 10), Vector2(w, top),
			Vector2(-w, top), Vector2(-w, 10)
		], C_WALL_DARK, 1.6)


# ------------------------------------------------------------------
# 村落：茅屋群 + 篱笆
# ------------------------------------------------------------------

static func _draw_village(marker: Node2D) -> void:
	_add_shadow(marker, 40.0, 0.36)

	# 三间茅屋，中间大两侧小
	_hut(marker, Vector2(0, 6), 20.0, 15.0)
	_hut(marker, Vector2(-24, 12), 13.0, 10.0)
	_hut(marker, Vector2(24, 12), 13.0, 10.0)

	# 篱笆
	_line(marker, [
		Vector2(-42, 18), Vector2(42, 18)
	], C_WOOD.darkened(0.25), 1.6)


static func _hut(parent: Node2D, pos: Vector2, hw: float, hh: float) -> void:
	var n := Node2D.new()
	n.position = pos
	parent.add_child(n)
	# 屋身
	_poly(n, [
		Vector2(-hw, 0), Vector2(hw, 0), Vector2(hw, -hh), Vector2(-hw, -hh)
	], Color(0.72, 0.64, 0.48))
	# 茅顶
	_poly(n, [
		Vector2(-hw - 5, -hh), Vector2(hw + 5, -hh),
		Vector2(hw * 0.35, -hh - 12), Vector2(-hw * 0.35, -hh - 12)
	], Color(0.60, 0.48, 0.28))
	# 门
	_poly(n, [
		Vector2(-3.5, 0), Vector2(3.5, 0), Vector2(3.5, -6), Vector2(-3.5, -6)
	], Color(0.34, 0.26, 0.18))


# ------------------------------------------------------------------
# 关隘：两侧山崖 + 中间隘口
# ------------------------------------------------------------------

static func _draw_pass(marker: Node2D) -> void:
	_add_shadow(marker, 44.0, 0.30)

	# 左崖
	_poly(marker, [
		Vector2(-44, 16), Vector2(-10, 16),
		Vector2(-16, -26), Vector2(-30, -34), Vector2(-44, -20)
	], C_STONE)
	# 右崖
	_poly(marker, [
		Vector2(10, 16), Vector2(44, 16),
		Vector2(44, -20), Vector2(30, -34), Vector2(16, -26)
	], C_STONE)
	# 崖顶积雪/高光
	_poly(marker, [
		Vector2(-30, -34), Vector2(-16, -26), Vector2(-24, -22)
	], Color(0.92, 0.94, 0.97, 0.8))
	_poly(marker, [
		Vector2(30, -34), Vector2(16, -26), Vector2(24, -22)
	], Color(0.92, 0.94, 0.97, 0.8))

	# 隘口门架
	var posts := [Vector2(-10, 16), Vector2(-10, -14)]
	_line(marker, posts, C_WOOD, 4.0)
	_line(marker, [Vector2(10, 16), Vector2(10, -14)], C_WOOD, 4.0)
	_line(marker, [Vector2(-13, -14), Vector2(13, -14)], C_WOOD, 4.0)
	_line(marker, [Vector2(-44, 16), Vector2(44, 16)], C_STONE_DARK, 1.6)

	# 栅栏横木
	_line(marker, [Vector2(-10, -2), Vector2(10, -2)], C_WOOD.darkened(0.2), 2.0)


# ------------------------------------------------------------------
# 遗迹：断柱 + 残垣
# ------------------------------------------------------------------

static func _draw_ruin(marker: Node2D) -> void:
	_add_shadow(marker, 38.0, 0.32)

	# 残破基座
	_poly(marker, [
		Vector2(-36, 14), Vector2(36, 14), Vector2(30, 4), Vector2(-30, 4)
	], Color(0.50, 0.47, 0.45))
	_line(marker, [
		Vector2(-36, 14), Vector2(36, 14), Vector2(30, 4),
		Vector2(-30, 4), Vector2(-36, 14)
	], Color(0.30, 0.28, 0.28), 1.6)

	# 断柱（高低不一，显得残破）
	_pillar(marker, Vector2(-22, 4), 9.0, 34.0)
	_pillar(marker, Vector2(-4, 4), 9.0, 20.0)
	_pillar(marker, Vector2(14, 4), 9.0, 42.0)

	# 坍塌的石块
	_poly(marker, [Vector2(24, 14), Vector2(36, 14), Vector2(32, 8)], Color(0.46, 0.44, 0.42))


static func _pillar(parent: Node2D, base: Vector2, hw: float, h: float) -> void:
	_poly(parent, [
		base + Vector2(-hw, 0), base + Vector2(hw, 0),
		base + Vector2(hw * 0.85, -h), base + Vector2(-hw * 0.85, -h)
	], Color(0.66, 0.63, 0.60))
	# 柱头
	_poly(parent, [
		base + Vector2(-hw - 2, -h), base + Vector2(hw + 2, -h),
		base + Vector2(hw + 2, -h - 4), base + Vector2(-hw - 2, -h - 4)
	], Color(0.58, 0.55, 0.52))
