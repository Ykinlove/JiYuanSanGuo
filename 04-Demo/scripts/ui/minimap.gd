extends Control
class_name MiniMap
## 小地图（MiniMap）
## 职责：在屏幕左上角实时呈现「天下格局」——城池点位（按阵营着色 + 名称 + 等级）、
##      道路连线、玩家位置与朝向、当前镜头视野框。
##
## 数据来源（只读，不产生任何数值规则）：
##   DataManager.get_table("cities")   —— 城池/村庄/关隘/遗迹 坐标
##   DataManager.get_table("terrain")  —— 区域矩形与道路折线
##   DataManager.get_table("factions6") —— 阵营主题色（按城池 faction 字段 "fNN" 取色）
##
## 缩放策略：地图远大于控件，按 min(w/map_w, h/map_h) 等比缩放，
##          地图在大地图坐标系里的 (0,0) 对应控件内的居中留白（letterbox）。

const FACTION_FALLBACK := {
	"nanman": Color(0.78, 0.42, 0.62),
	"player": Color(0.36, 0.78, 0.88),
	"own": Color(0.36, 0.78, 0.88),
	"neutral": Color(0.72, 0.72, 0.72),
}
## 小地图属于 HUD：只把「界面外壳色」（底、边框、玩家点、城名）归一到 UITheme。
## 地形色（山/林/泽/漠/雪/水）与势力色是**地图数据可视化**，不是界面配色，
## 硬塞进调色板反而丢语义 —— 保留在各自的绘制函数 / FACTION_COLORS 里。
const C_BG := UITheme.INK
const C_BORDER := UITheme.GOLD_LINE
const C_ROAD := Color(0.62, 0.54, 0.36, 0.42)   ## 道路：地图要素色
const C_PLAYER := UITheme.POINT
const C_VIEW := Color(1, 1, 1, 0.40)            ## 视野框：白色高亮叠层
const C_NAME := UITheme.TEXT
const C_NAME_BRIGHT := UITheme.GOLD

## 名称折叠阈值：按「每世界像素占几个控件像素」判断，越大说明放得越大
const NAME_ZOOM_FULL := 0.30     ## 大于此值显示所有地点名
const NAME_ZOOM_MAJOR := 0.16    ## 大于此值只显示大城（州治/县城以上）
## 显示模式
const MODE_LOCAL := 0            ## 局部跟随（默认，看清周边）
const MODE_WORLD := 1            ## 全局天下（一键切换）
## 局部模式覆盖的世界宽度占地图宽的比例（随地图大小自适应，
## 13000 宽地图 ≈ 2900 世界像素 ≈ 周边 2~3 座城）
const LOCAL_VIEW_RATIO := 0.22
const LOCAL_VIEW_SPAN_MIN := 1100.0

## 点击小地图时发出：请求弹出「放大版地图」覆盖层
signal expand_requested

var view_mode := MODE_LOCAL
## 放大版地图（全屏覆盖层）标记：true 时用羊皮纸亮色高对比渲染，
## false（左上角小缩略图）保持深色风格。
var expanded := false

var _map_size := Vector2(13000, 8000)
var _cities: Array = []
var _roads: Array = []
var _regions: Array = []
var _rivers: Array = []
## 阵营 ID -> 主题色。必须是「有值类型」的字典，否则取值是 Variant，
## 用 := 接收会报「Cannot infer the type of ... variable」。
var _faction_colors: Dictionary = {}

var _scale := 1.0
var _origin := Vector2.ZERO
## 世界坐标可视窗口：局部模式跟随玩家，全局模式即整张地图
var _world_window := Rect2()

var _player_pos := Vector2.ZERO
var _player_facing := Vector2.DOWN
var _view_rect := Rect2()

var _font: Font
var _font_size_name := 11
var _font_size_title := 13
var _title := "天下"


func _ready() -> void:
	# 可点击：点一下小地图即可在「近畿 / 天下」之间切换
	mouse_filter = Control.MOUSE_FILTER_STOP
	_font = ThemeDB.fallback_font
	_load_data()


func _gui_input(event: InputEvent) -> void:
	var hit := false
	if event is InputEventMouseButton:
		hit = (event as InputEventMouseButton).pressed
	elif event is InputEventScreenTouch:
		hit = (event as InputEventScreenTouch).pressed
	if hit:
		accept_event()
		# 点击小地图 = 弹出放大版地图（看清全国地名与路线）
		expand_requested.emit()


## 载入一次静态数据（城池 / 道路 / 阵营配色），之后每帧只更新动态部分
func _load_data() -> void:
	var terrain_table := DataManager.get_table("terrain")
	for row in terrain_table:
		if str(row.get("id", "")) != "china":
			continue
		_map_size = Vector2(float(row.get("width", 3600)), float(row.get("height", 2200)))
		_roads = row.get("roads", [])
		_regions = row.get("regions", [])
		_rivers = row.get("rivers", [])
		_title = str(row.get("name", "天下"))
		break

	_cities = DataManager.get_table("cities")

	# 势力主题色：cities.json 的 faction 字段写作 "f<factions6 整数 id>"，故键须同构
	for fac in DataManager.get_table("factions6"):
		var fid := int(fac.get("id", 0))
		var col: Variant = fac.get("color")
		if fid <= 0 or col == null:
			continue
		_faction_colors["f%d" % fid] = _to_color(col)

	_recalc_geometry()


func _to_color(raw: Variant) -> Color:
	if raw is Color:
		return raw
	if raw is String:
		return Color.from_string(str(raw), Color.WHITE)
	if raw is Array and (raw as Array).size() >= 3:
		var a: Array = raw
		var alpha := 1.0 if a.size() < 4 else float(a[3])
		return Color(float(a[0]), float(a[1]), float(a[2]), alpha)
	return Color.WHITE


## 依据当前模式计算「世界窗口 → 控件」的等比映射
func _recalc_geometry() -> void:
	var ctrl := size
	if ctrl.x <= 1.0 or ctrl.y <= 1.0 or _map_size.x <= 0.0:
		return

	if view_mode == MODE_WORLD:
		_world_window = Rect2(Vector2.ZERO, _map_size)
	else:
		# 局部：以玩家为中心取一个世界宽度的窗口，并夹在地图边界内
		var aspect := ctrl.y / ctrl.x
		var span_x := maxf(_map_size.x * LOCAL_VIEW_RATIO, LOCAL_VIEW_SPAN_MIN)
		var span := Vector2(span_x, span_x * aspect)
		span.x = minf(span.x, _map_size.x)
		span.y = minf(span.y, _map_size.y)
		var tl := _player_pos - span * 0.5
		tl.x = clampf(tl.x, 0.0, maxf(0.0, _map_size.x - span.x))
		tl.y = clampf(tl.y, 0.0, maxf(0.0, _map_size.y - span.y))
		_world_window = Rect2(tl, span)

	var win := _world_window.size
	if win.x <= 0.0 or win.y <= 0.0:
		return
	_scale = minf(ctrl.x / win.x, ctrl.y / win.y)
	var drawn := win * _scale
	_origin = (ctrl - drawn) * 0.5


func _map_to_local(p: Vector2) -> Vector2:
	return _origin + (p - _world_window.position) * _scale


## 世界点是否落在当前可视窗口内（含少量外扩，避免边缘物件突兀消失）
func _in_window(p: Vector2, pad := 0.0) -> bool:
	return _world_window.grow(pad).has_point(p)


## 切换「局部跟随 / 全局天下」
func toggle_mode() -> void:
	set_mode(MODE_WORLD if view_mode == MODE_LOCAL else MODE_LOCAL)


## 指定模式（重复设置同一模式不会重复重算）
func set_mode(m: int) -> void:
	if view_mode == m:
		return
	view_mode = m
	_recalc_geometry()
	queue_redraw()


func mode_label() -> String:
	return "天下" if view_mode == MODE_WORLD else "近畿"


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_recalc_geometry()


## 每帧由 world_map 调用：喂入玩家与镜头状态
func update_view(ppos: Vector2, facing: Vector2, camera: Camera2D) -> void:
	_player_pos = ppos
	if facing.length_squared() > 0.0001:
		_player_facing = facing.normalized()
	if camera != null:
		var vp := get_viewport_rect().size
		var half := vp * 0.5 / camera.zoom
		_view_rect = Rect2(camera.get_screen_center_position() - half, half * 2.0)
	# 【渲染视口修复】两种模式都应每帧重算几何。
	# 历史 bug：只有局部模式重算。放大大地图首次创建时 set_mode(WORLD) 触发的
	# _recalc_geometry 用的是「尚未完成布局、size 仍为 0/过小」的控件尺寸，
	# 随后 WORLD 模式又从不重算 → 整张天下地图只画到左上角一小块（看似只显示
	# 右上角）。放到这里每次可见时都重算，拿到正确控件尺寸后即可整图正常渲染。
	_recalc_geometry()
	queue_redraw()


func _draw() -> void:
	if _scale <= 0.0:
		return
	_draw_panel_bg()
	_draw_regions()
	_draw_rivers()   # 河流仅视觉，无阻挡
	_draw_roads()
	_draw_cities()
	_draw_view_frame()
	_draw_player()
	_draw_title()


func _draw_panel_bg() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), C_BG, true)
	var drawn := _world_window.size * _scale
	# 放大版：羊皮纸亮色底，地图内容一眼可辨；小缩略图保持深色但**实体不透明**，
	# 避免透明边框与其下方的全国大地图相互透叠、影响观感
	var area_col := Color(0.84, 0.78, 0.63, 1.0) if expanded else Color(0.10, 0.13, 0.14, 1.0)
	draw_rect(Rect2(_origin, drawn), area_col, true)
	draw_rect(Rect2(Vector2.ZERO, size), C_BORDER, false, 2.0)
	var edge_col := Color(0.34, 0.27, 0.15, 0.95) if expanded else Color(0.44, 0.40, 0.26, 0.95)
	draw_rect(Rect2(_origin, drawn), edge_col, false, 1.0)


## 区域色块（山地/水泽等，让格局一眼可辨）
func _draw_regions() -> void:
	for reg in _regions:
		if not (reg is Dictionary):
			continue
		var rect: Array = reg.get("rect", [])
		if rect.size() < 4:
			continue
		var world := Rect2(
			Vector2(float(rect[0]), float(rect[1])),
			Vector2(float(rect[2]), float(rect[3])))
		if not _world_window.intersects(world):
			continue
		var r := Rect2(_map_to_local(world.position), world.size * _scale)
		draw_rect(r, _terrain_tint(str(reg.get("terrain", "plain"))), true)


func _terrain_tint(t: String) -> Color:
	# 放大版：亮底上用高不透明度色块，地形格局清晰可辨
	if expanded:
		match t:
			"mountain": return Color(0.50, 0.44, 0.36, 0.85)
			"forest": return Color(0.42, 0.60, 0.36, 0.80)
			"swamp": return Color(0.44, 0.60, 0.56, 0.80)
			"desert": return Color(0.82, 0.71, 0.44, 0.85)
			"snow": return Color(0.91, 0.93, 0.96, 0.90)
			"water": return Color(0.48, 0.64, 0.76, 0.85)
			_: return Color(0.68, 0.72, 0.46, 0.75)
	match t:
		"mountain": return Color(0.42, 0.38, 0.34, 0.30)
		"forest": return Color(0.22, 0.40, 0.24, 0.30)
		"swamp": return Color(0.24, 0.40, 0.42, 0.30)
		"desert": return Color(0.62, 0.55, 0.34, 0.28)
		"snow": return Color(0.72, 0.76, 0.80, 0.26)
		_: return Color(0.48, 0.52, 0.32, 0.18)


## 河流（蓝线 + 渡口亮点）
func _draw_rivers() -> void:
	for river in _rivers:
		if not (river is Dictionary):
			continue
		var pts: Array = river.get("points", [])
		if pts.size() < 2:
			continue
		var line := PackedVector2Array()
		for pt in pts:
			if pt is Array and (pt as Array).size() >= 2:
				line.append(_map_to_local(Vector2(float(pt[0]), float(pt[1]))))
		if line.size() < 2:
			continue
		var bbox := _bounds_of(line)
		if not _world_window.grow(120.0).intersects(bbox):
			continue
		var river_col := Color(0.22, 0.42, 0.64, 0.90) if expanded else Color(0.30, 0.50, 0.60, 0.75)
		var river_w := 4.0 if expanded else 3.0
		draw_polyline(line, river_col, river_w, false)
		for f in river.get("fords", []):
			if f is Array and (f as Array).size() >= 2:
				draw_circle(_map_to_local(Vector2(float(f[0]), float(f[1]))),
					3.4 if expanded else 2.6, Color(0.86, 0.80, 0.58, 0.95))


func _draw_roads() -> void:
	for road in _roads:
		if not (road is Dictionary):
			continue
		var pts: Array = road.get("points", [])
		if pts.size() < 2:
			continue
		var line := PackedVector2Array()
		for pt in pts:
			if pt is Array and (pt as Array).size() >= 2:
				var world := Vector2(float(pt[0]), float(pt[1]))
				# 两端都在窗口外就整段跳过（道路最多几十个点，无需精细裁剪）
				line.append(_map_to_local(world))
		if line.size() >= 2:
			var bbox := _bounds_of(line)
			if not _world_window.grow(120.0).intersects(bbox):
				continue
			var road_col := Color(0.40, 0.30, 0.16, 0.85) if expanded else C_ROAD
			draw_polyline(line, road_col, 2.2 if expanded else 1.6, false)


func _bounds_of(pts: PackedVector2Array) -> Rect2:
	if pts.is_empty():
		return Rect2()
	var mn := pts[0]
	var mx := pts[0]
	for p in pts:
		mn.x = minf(mn.x, p.x)
		mn.y = minf(mn.y, p.y)
		mx.x = maxf(mx.x, p.x)
		mx.y = maxf(mx.y, p.y)
	# 注意：这里是控件坐标，转回世界坐标近似值只用于相交测试
	var inv := 1.0 / maxf(_scale, 0.0001)
	return Rect2((mn - _origin) * inv + _world_window.position,
		(mx - mn) * inv)


func _draw_cities() -> void:
	var show_names := _scale >= NAME_ZOOM_MAJOR
	var show_all := _scale >= NAME_ZOOM_FULL
	# 超大地图的「天下」模式：缩放恒小于阈值，改为按行政级别显示
	# 都城全显 / 州治(level>=4)在天下模式显示 / 普通点不显示
	var big_map_mode := _map_size.x >= 15000.0
	for city in _cities:
		if not (city is Dictionary):
			continue
		var world := Vector2(
			float(city.get("map_x", 0)), float(city.get("map_y", 0)))
		if not _in_window(world, 60.0):
			continue
		var pos := _map_to_local(world)
		var ctype := str(city.get("type", "city"))
		var is_capital := bool(city.get("is_capital", false))
		var col := _city_color(city)

		# 放大版：城池标记整体放大 1.5 倍，保证全国视野下清楚可点
		var rm := 1.5 if expanded else 1.0
		match ctype:
			"village":
				_draw_diamond(pos, 3.2 * rm, col, false)
			"pass":
				_draw_square(pos, 3.6 * rm, col, false)
			"ruin":
				_draw_diamond(pos, 3.2 * rm, Color(col.r, col.g, col.b, 0.55), false)
			_:
				var r := (5.0 if is_capital else 3.8) * rm
				if is_capital:
					draw_circle(pos, r + 2.6 * rm, Color(0.95, 0.80, 0.38, 0.30))
				draw_circle(pos, r, col, true)
				draw_circle(pos, r, Color(0.06, 0.06, 0.08, 0.95), false, 1.0)

		if _font == null:
			continue
		var show_name := show_all
		if not show_name and show_names:
			show_name = is_capital or int(city.get("level", 1)) >= 4
		elif not show_name and big_map_mode:
			# 天下模式：都城全显，其余城池仅在局部模式时看周边
			show_name = is_capital
		if expanded:
			# 放大版地图：都城 + 3 级以上城池都显示名字
			show_name = is_capital or int(city.get("level", 1)) >= 3
		if show_name:
			var name_fs := _font_size_name + (3 if expanded else 0)
			var bright := is_capital or ctype != "city"
			var col_txt := Color(0.25, 0.18, 0.06) if expanded else (C_NAME_BRIGHT if bright else C_NAME)
			var shadow_col := Color(1, 1, 1, 0.7) if expanded else Color(0, 0, 0, 0.75)
			var txt := str(city.get("name", ""))
			draw_string(_font, pos + Vector2(6, 4), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, name_fs, shadow_col)
			draw_string(_font, pos + Vector2(5, 3), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, name_fs, col_txt)


func _city_color(city: Dictionary) -> Color:
	var tags: Array = city.get("tags", [])
	# 玩家自己的地盘优先高亮
	if tags.has("own") or tags.has("player"):
		return FACTION_FALLBACK["player"]
	var fac := str(city.get("faction", ""))
	if _faction_colors.has(fac):
		return _to_color(_faction_colors[fac])
	if FACTION_FALLBACK.has(fac):
		return _to_color(FACTION_FALLBACK[fac])
	return _to_color(FACTION_FALLBACK["neutral"])


func _draw_diamond(pos: Vector2, r: float, col: Color, filled: bool) -> void:
	var pts := PackedVector2Array([
		pos + Vector2(0, -r), pos + Vector2(r, 0),
		pos + Vector2(0, r), pos + Vector2(-r, 0)])
	if filled:
		draw_colored_polygon(pts, col)
	else:
		draw_polyline(pts + PackedVector2Array([pts[0]]), col, 1.4, true)


func _draw_square(pos: Vector2, r: float, col: Color, filled: bool) -> void:
	var rc := Rect2(pos - Vector2(r, r), Vector2(r, r) * 2.0)
	if filled:
		draw_rect(rc, col, true)
	else:
		draw_rect(rc, col, false, 1.4)


## 当前镜头视野框（让玩家知道自己正在看哪一块）
func _draw_view_frame() -> void:
	# 放大版天下地图：视野框反而让画面显得歪斜不对称（玩家镜头区域只是图上一小块），
	# 且与「看全图」的意图冲突。放大版隐藏视野框，保持整图干净对称。
	if expanded:
		return
	if _view_rect.size.x <= 1.0 or _view_rect.size.y <= 1.0:
		return
	var tl := _map_to_local(_view_rect.position)
	var br := _map_to_local(_view_rect.position + _view_rect.size)
	var rc := Rect2(tl, br - tl)
	var clip := Rect2(_origin, _world_window.size * _scale)
	# 视野框可能大于小地图窗口（相机看得很远），裁到窗口内再画
	var vis := rc.intersection(clip)
	if vis.size.x <= 1.0 or vis.size.y <= 1.0:
		return
	draw_rect(vis, Color(0.25, 0.18, 0.05, 0.55) if expanded else C_VIEW, false, 1.5)


func _draw_player() -> void:
	if not _in_window(_player_pos, 40.0):
		return
	var p := _map_to_local(_player_pos)
	if not Rect2(_origin, _world_window.size * _scale).grow(24.0).has_point(p):
		return
	# 呼吸光晕
	var t := Time.get_ticks_msec() / 1000.0
	var pulse := 5.5 + sin(t * 3.0) * 1.2
	draw_circle(p, pulse + 3.0, Color(1.0, 0.92, 0.55, 0.18))
	draw_circle(p, 4.2, C_PLAYER, true)
	draw_circle(p, 4.2, Color(0.15, 0.10, 0.02, 0.95), false, 1.2)

	# 朝向箭头
	var f := _player_facing
	var tip := p + f * 11.0
	var side := Vector2(-f.y, f.x) * 4.0
	var tri := PackedVector2Array([tip, p + side, p - side])
	draw_colored_polygon(tri, Color(1.0, 0.95, 0.60, 0.92))


func _draw_title() -> void:
	if _font == null:
		return
	var count := "天下 %d城" % _cities.size()
	draw_string(_font, Vector2(10, 18), count,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size_title,
		Color(0, 0, 0, 0.8))
	draw_string(_font, Vector2(9, 17), count,
		HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size_title,
		Color(0.96, 0.88, 0.60, 0.95))

	# 右上角「[近畿] 点击切换」提示只属于左上角小缩略图（点击=切换模式）。
	# 放大版的点击语义是「关闭地图」，提示由 world_map 底部提示条负责，
	# 这里不再绘制 —— 旧代码照画会造成「提示说切换、实际却关闭」的误导，
	# 也是放大地图内部文字与外部标题条互相打架、观感杂乱的原因之一。
	if expanded:
		# 放大版：显示全图尺寸与当前缩放比例
		var info := "全图 %d × %d　缩放 %d%%" % [int(_map_size.x), int(_map_size.y), roundi(_scale * 100.0)]
		draw_string(_font, Vector2(10, 36), info,
			HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size_name,
			Color(0, 0, 0, 0.8))
		draw_string(_font, Vector2(9, 35), info,
			HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size_name,
			Color(0.92, 0.88, 0.76, 0.95))
		return
	var tag := "近畿" if view_mode == MODE_LOCAL else "天下"
	var hint := "[%s] 点击切换" % tag
	draw_string(_font, Vector2(size.x - 9, 17), hint,
		HORIZONTAL_ALIGNMENT_RIGHT, -1, _font_size_name,
		Color(0.80, 0.84, 0.90, 0.80))
