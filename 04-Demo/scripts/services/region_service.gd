class_name RegionService
extends RefCounted
## 区域服务（RegionService）
## 职责：全国大地图「分区加载」框架的规则层 —— 游戏区域 → 古州映射、
##       区域矩形（世界坐标窗口）、邻接关系、越界判定、区域主城。
## 全部 static 纯函数，规则不持有场景节点（服务层范式）。

## 游戏区域 -> 所属古州列表。M10 首批 4 区；
## 【三国全史篇】扩至 8 区，补齐司隶/徐州/冀州/益州，覆盖剧本全部舞台
## （洛阳·长安·汉中/下邳·寿春/邺·官渡/成都）。
const GAME_REGIONS := {
	"nanzhong":  ["reg_nanzhong"],
	"jing":      ["reg_jing"],
	"zhongyuan": ["reg_yu", "reg_yan"],
	"jiangdong": ["reg_yang"],
	"sili":      ["reg_sili"],
	"xuzhou":    ["reg_xu"],
	"jizhou":    ["reg_ji"],
	"yizhou":    ["reg_yi"],
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
}

const NEIGHBORS := {
	"nanzhong":  ["jing", "yizhou"],
	"jing":      ["nanzhong", "zhongyuan", "jiangdong", "sili", "yizhou"],
	"zhongyuan": ["jing", "jiangdong", "sili", "jizhou", "xuzhou"],
	"jiangdong": ["jing", "zhongyuan", "xuzhou"],
	"sili":      ["zhongyuan", "jing", "jizhou", "xuzhou", "yizhou"],
	"xuzhou":    ["zhongyuan", "jiangdong", "jizhou", "sili"],
	"jizhou":    ["zhongyuan", "sili", "xuzhou"],
	"yizhou":    ["nanzhong", "jing", "sili"],
}


## 取某个古州（reg_xxx）的世界坐标矩形；找不到返回空 Rect2。
static func guizhou_rect(region_code: String) -> Rect2:
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
				return Rect2(raw[0], raw[1], raw[2], raw[3])
	return Rect2()


## 取某个游戏区域的世界坐标矩形（该区全部古州 rect 的并集）。
static func region_rect(game_region: String) -> Rect2:
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
	return Rect2(min_x, min_y, max_x - min_x, max_y - min_y)


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
