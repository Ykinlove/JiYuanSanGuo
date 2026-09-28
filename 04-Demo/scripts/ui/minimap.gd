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

## 显示模式
const MODE_LOCAL := 0            ## 局部跟随（默认，看清周边）
const MODE_WORLD := 1            ## 全局天下（一键切换）
## 局部模式覆盖的世界宽度占地图宽的比例（随地图大小自适应，
## 13000 宽地图 ≈ 2900 世界像素 ≈ 周边 2~3 座城）
const LOCAL_VIEW_RATIO := 0.22
const LOCAL_VIEW_SPAN_MIN := 1100.0

## —— 放大版（天下地图）自由拖动 / 缩放 ——
const ZOOM_MIN := 1.0            ## 1 = 整图适配控件
const ZOOM_MAX := 5.0            ## 最大放大到 1/5 幅宽（看清城池群细节）
const ZOOM_STEP := 1.35          ## 每按一次 ＋/－ 的缩放倍率

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
## 【地貌同步】大地图 terrain_painter 的远景全图纹理（512→1024 噪声地貌）。
## 由 world_map 注入；存在时小地图直接采样对应世界窗口，
## 与大地图地貌完全一致（用户要求：小地图同步大地图地貌）。
var _terrain_tex: Texture2D = null
## 【R3-15】放大地图羊皮纸底图（原孤立资产启用）
var _paper_tex: Texture2D = preload("res://assets/sprites/ui/panel_paper.png")
## 阵营 ID -> 主题色。必须是「有值类型」的字典，否则取值是 Variant，
## 用 := 接收会报「Cannot infer the type of ... variable」。
var _faction_colors: Dictionary = {}

var _scale := 1.0
var _origin := Vector2.ZERO
## 世界坐标可视窗口：局部模式跟随玩家，全局模式即整张地图
var _world_window := Rect2()

## —— 放大版视野状态 ——
## 缩放倍率（1 = 整图适配）；视野中心（世界坐标），负值 = 未初始化（落到全图中心）。
## 拖动改中心、缩放改倍率，_recalc_geometry 每帧由二者推导可视窗口。
var _zoom := 1.0
var _pan_center := Vector2(-1.0, -1.0)
var _dragging := false          ## 放大版左键拖动进行中
var _drag_moved := 0.0          ## 本次按下以来累计位移（判定「轻点关闭」）
var _press_ms := 0              ## 按下时刻（判定「轻点关闭」）

var _player_pos := Vector2.ZERO
var _player_facing := Vector2.DOWN
var _view_rect := Rect2()

var _font: Font
## 【2026-09-28 用户反馈】城名 11px 太小看不清 → 18（放大版再 +7 = 25）。
## 近畿局部城间距 56px，2 字城名 36px + 偏移 10 仍放得下。
var _font_size_name := 18
var _font_size_title := 15
var _title := "天下"


func _ready() -> void:
	# 可点击：点一下小地图即可在「近畿 / 天下」之间切换
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 【溢出裁剪】河流/道路折线超出窗口时会画到小地图框外的屏幕上
	# （表现为「蓝线飘到小地图外面」），裁到控件矩形内。
	clip_contents = true
	_font = ThemeDB.fallback_font
	_load_data()


func _gui_input(event: InputEvent) -> void:
	# 放大版：拖动平移 / 滚轮缩放 / 轻点关闭
	if expanded:
		_expanded_input(event)
		return
	var hit := false
	if event is InputEventMouseButton:
		hit = (event as InputEventMouseButton).pressed
	elif event is InputEventScreenTouch:
		hit = (event as InputEventScreenTouch).pressed
	if hit:
		accept_event()
		# 点击小地图 = 弹出放大版地图（看清全国地名与路线）
		expand_requested.emit()


## 放大版输入处理：左键拖动=平移，滚轮=以指针为中心缩放，轻点（位移小且时间短）=关闭。
## 只处理鼠标事件即可覆盖鼠标与触摸：项目开启了 emulate_touch_from_mouse /
## emulate_mouse_from_touch，物理触摸也会投递鼠标事件；双路都接会把同一手势算两次。
func _expanded_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_drag_moved = 0.0
				_press_ms = Time.get_ticks_msec()
			elif _dragging:
				_dragging = false
				# 轻点 → 关闭放大地图（拖动看图不被误判为关闭）
				if _drag_moved < 12.0 and Time.get_ticks_msec() - _press_ms < 400:
					expand_requested.emit()
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(mb.position, ZOOM_STEP)
			accept_event()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(mb.position, 1.0 / ZOOM_STEP)
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			# 控件像素位移 → 世界位移：除以当前缩放
			_pan_center -= mm.relative / maxf(_scale, 0.0001)
			_drag_moved += mm.relative.length()
			_recalc_geometry()
			queue_redraw()
			accept_event()


## 缩放并保持 screen_pos 指向的世界点不动（滚轮以指针为中心缩放）
func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var before := _local_to_world(screen_pos)
	_zoom = clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	_recalc_geometry()
	_pan_center += before - _local_to_world(screen_pos)
	_recalc_geometry()
	queue_redraw()


## 控件坐标 → 世界坐标（_map_to_local 的逆变换）
func _local_to_world(p: Vector2) -> Vector2:
	return _world_window.position + (p - _origin) / maxf(_scale, 0.0001)


## 供放大地图的 ＋/－/复位 按钮调用：以视图中心缩放
func zoom_in() -> void:
	_zoom_at(size * 0.5, ZOOM_STEP)


func zoom_out() -> void:
	_zoom_at(size * 0.5, 1.0 / ZOOM_STEP)


## 复位到整图视野（打开放大地图时也调用，保证每次打开都是确定的初始状态）
func reset_view() -> void:
	_zoom = 1.0
	_pan_center = _map_size * 0.5
	_dragging = false
	_recalc_geometry()
	queue_redraw()


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

	if expanded:
		# 放大版：窗口 = 全图 / 缩放倍率，中心 = 拖动位置（夹在地图边界内）。
		# 这样 +/− 按钮与拖动手势都只改 _zoom / _pan_center 两个标量，
		# 几何推导统一走这里，不会出现「拖完一帧又被覆盖回原位」。
		var esz := _map_size / _zoom
		esz.x = minf(esz.x, _map_size.x)
		esz.y = minf(esz.y, _map_size.y)
		if _pan_center.x < 0.0 or _pan_center.y < 0.0:
			_pan_center = _map_size * 0.5
		var ehalf := esz * 0.5
		_pan_center = Vector2(
			clampf(_pan_center.x, ehalf.x, maxf(ehalf.x, _map_size.x - ehalf.x)),
			clampf(_pan_center.y, ehalf.y, maxf(ehalf.y, _map_size.y - ehalf.y)))
		_world_window = Rect2(_pan_center - ehalf, esz)
	elif view_mode == MODE_WORLD:
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
	# 【R3-14】不可见时直接返回：放大地图打开期间缩略图不参与绘制，
	# 省掉每帧几何重算与 queue_redraw；重新可见的下一帧自动恢复
	if not is_visible_in_tree():
		return
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


## 注入大地图地貌纹理（远景全图）。world_map 在地形纹理预热完成后调用。
func set_terrain_tex(tex: Texture2D) -> void:
	_terrain_tex = tex
	queue_redraw()


func _draw() -> void:
	if _scale <= 0.0:
		return
	_draw_panel_bg()
	_draw_terrain_tex()
	# 已有真实地貌纹理时不再叠程序化区域色块与虚构坐标的河流/道路折线 ——
	# 矩形色块盖在真实地貌上就是用户反馈的「放大地图里有很多方块」BUG；
	# 蓝色折线河流与 china_geo 图内真实水系互相错位打架（「蓝色多余线条」）。
	# 仅在无纹理回退（纯程序化底图）时保留折线作水系/道路信息。
	if _terrain_tex == null:
		_draw_regions()
		_draw_rivers()   # 河流仅视觉，无阻挡
		_draw_roads()
	_draw_cities()
	_draw_view_frame()
	_draw_player()
	_draw_title()
	# 【边框必须最后画】旧版画在 _draw_panel_bg 里，随后 _draw_terrain_tex 把整幅
	# 地貌纹理盖上去（窗口铺满控件时边框被完全遮住）——表现为「怎么改宽度都没边框」。
	_draw_border()


## 描金外框（最后绘制，保证不被任何地图内容覆盖）。
## 【美化】圆角双线框（外描金 + 内衬墨线）替代生硬的直角粗线。
func _draw_border() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = C_BORDER
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(14)
	draw_style_box(sb, Rect2(Vector2.ZERO, size))
	var sb2 := StyleBoxFlat.new()
	sb2.bg_color = Color(0, 0, 0, 0)
	sb2.border_color = Color(0.05, 0.06, 0.08, 0.55)
	sb2.set_border_width_all(2)
	sb2.set_corner_radius_all(11)
	draw_style_box(sb2, Rect2(Vector2(3, 3), size - Vector2(6, 6)))


## 把大地图地貌纹理按当前世界窗口采样绘制（区域色块之前，作真实地貌底图）。
## 纹理覆盖世界 (0,0)~map_size；源矩形按窗口归一化采样，letterbox 不受影响。
func _draw_terrain_tex() -> void:
	if _terrain_tex == null:
		return
	var drawn := _world_window.size * _scale
	if drawn.x <= 1.0 or drawn.y <= 1.0:
		return
	var tex_size := Vector2(_terrain_tex.get_width(), _terrain_tex.get_height())
	var norm_tl := _world_window.position / _map_size
	var norm_sz := _world_window.size / _map_size
	var src := Rect2(norm_tl * tex_size, norm_sz * tex_size)
	draw_texture_rect_region(_terrain_tex, Rect2(_origin, drawn), src)


func _draw_panel_bg() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), C_BG, true)
	var drawn := _world_window.size * _scale
	# 放大版：羊皮纸纹理底（【R3-15】panel_paper 启用，替代代码纯色，质感立升），
	# 等比 cover 裁剪防拉伸变形；小缩略图保持深色但**实体不透明**，
	# 避免透明边框与其下方的全国大地图相互透叠、影响观感
	if expanded:
		_draw_paper_bg(Rect2(_origin, drawn))
	else:
		draw_rect(Rect2(_origin, drawn), Color(0.10, 0.13, 0.14, 1.0), true)
	var edge_col := Color(0.34, 0.27, 0.15, 0.95) if expanded else Color(0.44, 0.40, 0.26, 0.95)
	draw_rect(Rect2(_origin, drawn), edge_col, false, 1.0)


## 【R3-15】放大版羊皮纸底：panel_paper 按目标宽高比中心裁剪（cover），铺满世界窗口区域。
## 有地貌纹理时该底被 _draw_terrain_tex 覆盖，仅在程序化回退（无纹理）时可见。
func _draw_paper_bg(rect: Rect2) -> void:
	var tw := _paper_tex.get_width()
	var th := _paper_tex.get_height()
	if tw <= 0 or th <= 0 or rect.size.x <= 1.0 or rect.size.y <= 1.0:
		draw_rect(rect, Color(0.84, 0.78, 0.63, 1.0), true)   # 纹理缺失回退原纯色
		return
	var target_ar := rect.size.x / rect.size.y
	var tex_ar := tw / float(th)
	var src: Rect2
	if tex_ar > target_ar:
		var sw := th * target_ar
		src = Rect2((tw - sw) * 0.5, 0.0, sw, float(th))
	else:
		var sh := tw / target_ar
		src = Rect2(0.0, (th - sh) * 0.5, float(tw), sh)
	draw_texture_rect_region(_paper_tex, rect, src)


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


## 河流（蓝线 + 渡口亮点）。折线先裁剪到地图绘制区再画，
## 缩放/拖动后窗口外的河段不再画出图外（用户反馈 BUG）。
func _draw_rivers() -> void:
	var clip := Rect2(_origin, _world_window.size * _scale).grow(4.0)
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
		for seg in _clip_polyline(line, clip):
			draw_polyline(seg, river_col, river_w, false)
		for f in river.get("fords", []):
			if f is Array and (f as Array).size() >= 2:
				var fp := _map_to_local(Vector2(float(f[0]), float(f[1])))
				if clip.has_point(fp):
					draw_circle(fp, 3.4 if expanded else 2.6, Color(0.86, 0.80, 0.58, 0.95))


func _draw_roads() -> void:
	var clip := Rect2(_origin, _world_window.size * _scale).grow(4.0)
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
			for seg in _clip_polyline(line, clip):
				draw_polyline(seg, road_col, 2.2 if expanded else 1.6, false)


## 折线按矩形裁剪（Liang-Barsky 逐段），返回若干段折线数组。
## 【为什么需要】河流/道路是世界折线，缩放拖动后窗口只覆盖折线中段，
## 映射到控件后窗口外的点会画进 letterbox 暗区甚至飘出地图纹理
## （用户截图：河流蓝线延伸进暗区）——画前必须把界外部分裁掉。
func _clip_polyline(line: PackedVector2Array, rect: Rect2) -> Array:
	var out: Array = []
	var cur := PackedVector2Array()
	for i in range(line.size() - 1):
		var seg := _clip_segment(line[i], line[i + 1], rect)
		if seg.size() == 2:
			# 与当前累积段相接则延续，否则另起一条（折线穿出界外再折回）
			if cur.is_empty():
				cur.append(seg[0])
			elif cur[cur.size() - 1].distance_to(seg[0]) > 0.5:
				out.append(cur)
				cur = PackedVector2Array([seg[0]])
			cur.append(seg[1])
		elif not cur.is_empty():
			out.append(cur)
			cur = PackedVector2Array()
	if cur.size() >= 2:
		out.append(cur)
	return out


## 单段 Liang-Barsky 裁剪：与矩形相交则返回裁剪后的两端点，否则空。
func _clip_segment(a: Vector2, b: Vector2, r: Rect2) -> PackedVector2Array:
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	for c in [[-d.x, a.x - r.position.x], [d.x, r.end.x - a.x],
			[-d.y, a.y - r.position.y], [d.y, r.end.y - a.y]]:
		var p := float(c[0])
		var q := float(c[1])
		if p == 0.0:
			if q < 0.0:
				return PackedVector2Array()
		else:
			var t := q / p
			if p < 0.0:
				t0 = maxf(t0, t)
			else:
				t1 = minf(t1, t)
		if t0 > t1:
			return PackedVector2Array()
	if t1 <= t0:
		return PackedVector2Array()
	return PackedVector2Array([a + d * t0, a + d * t1])


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

		# 放大版：城池标记整体放大 2.6 倍 —— 旧值 1.5 在全国视野下只有绿豆大，
		# 用户反馈「点开后城池变为小点、不容易分辨」。
		var rm := 2.6 if expanded else 1.0
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
		# 【2026-09-27 用户反馈：小地图上看不到城名】旧规则 _scale 阈值 0.16/0.30，
		# 但近畿局部模式 _scale≈0.11、天下缩略 ≈0.025、放大版整图 ≈0.08 —— 全被卡死，
		# 名字几乎永远不出现。改为按模式定规则：
		# - 近畿局部：窗口就是玩家周边几座城，全部显示名字（间距 56px+ 不会重叠）
		# - 放大版：缩放 ≥2 档全显；整图视野显都城 + level≥3
		# - 天下缩略：110 城全显必糊，显都城 + level≥4（13 城左右）
		var lv := int(city.get("level", 1))
		var show_name := false
		if expanded:
			show_name = _zoom >= 2.0 or is_capital or lv >= 3
		elif view_mode == MODE_LOCAL:
			show_name = true
		else:
			show_name = is_capital or lv >= 4
		if show_name:
			# 放大版：城名字号 +7（旧 +3 配不上放大的城池标记，小字糊在一起）
			var name_fs := _font_size_name + (7 if expanded else 0)
			var bright := is_capital or ctype != "city"
			var col_txt := Color(0.25, 0.18, 0.06) if expanded else (C_NAME_BRIGHT if bright else C_NAME)
			var shadow_col := Color(1, 1, 1, 0.7) if expanded else Color(0, 0, 0, 0.75)
			var txt := str(city.get("name", ""))
			var off := Vector2(10, 6) if expanded else Vector2(6, 4)
			draw_string(_font, pos + off + Vector2(1, 1), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, name_fs, shadow_col)
			draw_string(_font, pos + off, txt,
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
	# 【方框残留修复】「近畿」局部模式的窗口本来就是玩家周边这一块，
	# 视野框画出来只会悬在小地图正中间（用户反馈的「中间显示方框」）。
	# 视野框只在「天下」缩略模式下画 —— 那里它才有「你在这」的指位意义。
	if view_mode == MODE_LOCAL:
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
