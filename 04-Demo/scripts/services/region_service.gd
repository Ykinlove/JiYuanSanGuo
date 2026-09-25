class_name RegionService
extends RefCounted
## 区域服务（RegionService）
## 职责：全国大地图「分区加载」框架的规则层 —— 游戏区域 → 古州映射、
##       区域矩形（世界坐标窗口）、邻接关系、越界判定、区域主城。
## 全部 static 纯函数，规则不持有场景节点（服务层范式）。

## 游戏区域 -> 所属古州列表。M10 首批 4 区；
## 【三国全史篇】扩至 8 区，补齐司隶/徐州/冀州/益州，覆盖剧本全部舞台
## （洛阳·长安·汉中/下邳·寿春/邺·官渡/成都）。
## 【BUG 修复】再补幽/凉/并/交四州：terrain.json 共有 13 个古州，原表只映射 9 个，
## 幽州 11 城 + 凉州 7 + 并州 7 + 交州 7 = 32/110 城不属于任何游戏区域 ——
## city_in_area 恒 false 使这 32 城的大地图标记永不生成，且玩家走进四州时
## 区域归属不切换（HUD 区域名与遭遇分布窗口都停在旧区域）。
const GAME_REGIONS := {
	"nanzhong":  ["reg_nanzhong"],
	"jing":      ["reg_jing"],
	"zhongyuan": ["reg_yu", "reg_yan"],
	"jiangdong": ["reg_yang"],
	"sili":      ["reg_sili"],
	"xuzhou":    ["reg_xu"],
	"jizhou":    ["reg_ji"],
	"yizhou":    ["reg_yi"],
	"youzhou":   ["reg_you"],
	"liangzhou": ["reg_liang"],
	"bingzhou":  ["reg_bing"],
	"jiaozhou":  ["reg_jiao"],
}

const REGION_NAMES := {
	"nanzhong":  "南中",
	"jing":      "荆州",
	"zhongyuan": "中原",
	"jiangdong": "江东",
	"sili":      "司隶",
	"xuzhou":    "徐州",
	"jizhou":    "冀州",
	"yizhou":    "益州",
	"youzhou":   "幽州",
	"liangzhou": "凉州",
	"bingzhou":  "并州",
	"jiaozhou":  "交州",
}

## 邻接关系按 terrain.json 的 13 个古州矩形实测接壤（含 ≤400px 间隙）推导，双向对称。
## walkable_rects 会把邻接区域矩形并进来，缺边 = 交界处空气墙。
const NEIGHBORS := {
	"nanzhong":  ["jing", "yizhou", "jiaozhou"],
	"jing":      ["nanzhong", "zhongyuan", "jiangdong", "sili", "yizhou", "jiaozhou"],
	"zhongyuan": ["jing", "jiangdong", "sili", "jizhou", "xuzhou", "youzhou", "bingzhou"],
	"jiangdong": ["jing", "zhongyuan", "xuzhou"],
	"sili":      ["zhongyuan", "jing", "jizhou", "xuzhou", "yizhou", "liangzhou"],
	"xuzhou":    ["zhongyuan", "jiangdong", "jizhou", "sili", "youzhou"],
	"jizhou":    ["zhongyuan", "sili", "xuzhou", "bingzhou"],
	"yizhou":    ["nanzhong", "jing", "sili", "liangzhou"],
	"youzhou":   ["zhongyuan", "xuzhou"],
	"liangzhou": ["sili", "yizhou"],
	"bingzhou":  ["jizhou", "zhongyuan"],
	"jiaozhou":  ["jing", "nanzhong"],
}


## 古州矩形静态缓存（【R1-20】_check_region_bounds 每帧多次取矩形，
## terrain 表静态不变，缓存后每帧只查内存字典，消除持续 JSON 表遍历）
static var _gz_rect_cache: Dictionary = {}
## 【性能】游戏区域矩形（多古州并集）与可行走矩形集合的缓存。
## 二者都只由静态的 GAME_REGIONS + terrain.json 矩形决定，运行期不变；
## 但 player_controller 每帧 clamp 与 world_map 每帧 _check_region_bounds 都会取，
## 不缓存就是每帧重算 12 个区域的并集 + 邻接判定。
static var _region_rect_cache: Dictionary = {}
static var _walkable_cache: Dictionary = {}


## 取某个古州（reg_xxx）的世界坐标矩形；找不到返回空 Rect2。
static func guizhou_rect(region_code: String) -> Rect2:
	if _gz_rect_cache.has(region_code):
		return _gz_rect_cache[region_code]
	var result := Rect2()
	var terrains: Array = DataManager.get_table("terrain")
	for t in terrains:
		if str(t.get("id", "")) != "china":
			continue
		var regions: Array = t.get("regions", [])
		for rr: Dictionary in regions:
			if str(rr.get("id", "")) != region_code:
				continue
			var raw: Array = rr.get("rect", [])
			if raw.size() >= 4:
				result = Rect2(raw[0], raw[1], raw[2], raw[3])
			break
		break
	_gz_rect_cache[region_code] = result
	return result


## 取某个游戏区域的世界坐标矩形（该区全部古州 rect 的并集）。
static func region_rect(game_region: String) -> Rect2:
	if _region_rect_cache.has(game_region):
		return _region_rect_cache[game_region]
	var codes: Array = GAME_REGIONS.get(game_region, [])
	if codes.is_empty():
		return Rect2()
	var min_x := 2.0e9
	var min_y := 2.0e9
	var max_x := -2.0e9
	var max_y := -2.0e9
	var found := false
	for code in codes:
		var r := guizhou_rect(str(code))
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		found = true
		min_x = minf(min_x, r.position.x)
		min_y = minf(min_y, r.position.y)
		max_x = maxf(max_x, r.end.x)
		max_y = maxf(max_y, r.end.y)
	if not found:
		return Rect2()
	var rect := Rect2(min_x, min_y, max_x - min_x, max_y - min_y)
	_region_rect_cache[game_region] = rect
	return rect


## 游戏区域中文名
static func region_name(game_region: String) -> String:
	return str(REGION_NAMES.get(game_region, game_region))


## 邻接游戏区域列表
static func neighbors(game_region: String) -> Array:
	var arr: Array = NEIGHBORS.get(game_region, [])
	return arr.duplicate()


## 某城池是否属于某游戏区域（按城池 region 古州字段判定）
static func city_in_area(game_region: String, city: Dictionary) -> bool:
	var codes: Array = GAME_REGIONS.get(game_region, [])
	if codes.is_empty():
		return false
	var cg := str(city.get("region", ""))
	return cg in codes


## 当前区域的可进入主城（is_capital 优先，否则取等级最高城）
static func main_city(game_region: String) -> Dictionary:
	var result: Dictionary = {}
	var best_level := 0
	for city in DataManager.get_table("cities"):
		if not city_in_area(game_region, city):
			continue
		if bool(city.get("is_capital", false)):
			return city
		var lv := int(city.get("level", 0))
		if lv > best_level:
			best_level = lv
			result = city
	return result


## 越界判定：当前区域 + 玩家世界坐标 → 应切换的邻接区域。
## 依据「位置已落入某个邻接区域矩形」判定（相邻 rect 边界重叠/相接可触发）。
static func resolve_crossing(game_region: String, pos: Vector2) -> String:
	var me := region_rect(game_region)
	if me.size.x <= 0.0 or me.size.y <= 0.0:
		return ""
	for nb_node in neighbors(game_region):
		var nb := str(nb_node)
		var r := region_rect(nb)
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		if r.has_point(pos):
			return nb
	return ""


## 当前区域的「可行走矩形集合」：本辖区各古州 rect + 与本区域有交集的邻接区域 rect。
## 【为什么不能直接用 region_rect 那个并集矩形】
## 并集会圈出「不属于任何古州」的虚空角落（例：兖州+豫州并集的东南角、
## 两州上下错位凸出来的那一块）。玩家能走进去，但地形上那里是空的，
## 观感就是"走出了地图"。必须逐个古州矩形限制。
## 邻接区域 rect 之所以也放进集合：玩家必须能越过多州交界的一小段，
## 走到邻接矩形里才轮到 resolve_crossing() 触发切区；不放进来交界处就成了空气墙。
static func walkable_rects(game_region: String) -> Array:
	if _walkable_cache.has(game_region):
		# 返回副本：调用方（player_controller 的 walk_rects）若就地增删不会污染缓存
		return (_walkable_cache[game_region] as Array).duplicate()
	var me := region_rect(game_region)
	if me.size.x <= 0.0 or me.size.y <= 0.0:
		return []
	var out: Array = []
	for code_node in (GAME_REGIONS.get(game_region, []) as Array):
		var r := guizhou_rect(str(code_node))
		if r.size.x > 0.0 and r.size.y > 0.0:
			out.append(r)
	for nb_node in neighbors(game_region):
		var nb_r := region_rect(str(nb_node))
		if nb_r.size.x > 0.0 and nb_r.size.y > 0.0 and me.intersects(nb_r):
			out.append(nb_r)
	_walkable_cache[game_region] = out.duplicate()
	return out


## 把坐标夹进可行走矩形中最接近的那一个（已在任一矩形内则原样返回）
static func clamp_to_walkable(game_region: String, pos: Vector2) -> Vector2:
	var rects: Array = walkable_rects(game_region)
	return _clamp_into(rects, pos)


## 矩形集合内的最近点钳制（供调用方复用）
static func _clamp_into(rects: Array, pos: Vector2) -> Vector2:
	if rects.is_empty():
		return pos
	for r_node in rects:
		var r := r_node as Rect2
		if r.has_point(pos):
			return pos
	var best := pos
	var best_d := INF
	for r_node in rects:
		var r := r_node as Rect2
		var c := Vector2(
			clampf(pos.x, r.position.x, r.end.x),
			clampf(pos.y, r.position.y, r.end.y))
		var d := c.distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = c
	return best


## 把切换后的位置推入新区域内部（脱离边界重叠带，避免反复触发越界）
static func push_into_region(game_region: String, pos: Vector2) -> Vector2:
	var r := region_rect(game_region)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return pos
	var c := Vector2(
		clampf(pos.x, r.position.x, r.end.x),
		clampf(pos.y, r.position.y, r.end.y))
	var center := (r.position + r.end) * 0.5
	c += (center - c).normalized() * 80.0
	return Vector2(
		clampf(c.x, r.position.x, r.end.x),
		clampf(c.y, r.position.y, r.end.y))
