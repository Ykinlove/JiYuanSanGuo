extends RefCounted
class_name CityInteriorArt
## 城内建筑美术（程序化绘制版）
## 与 CityMarkerArt 同思路：优先尝试贴图 res://assets/sprites/city/<key>.png，
## 没有贴图则按建筑类型绘制有辨识度的国风造型。

const C_WALL := Color(0.72, 0.62, 0.48)
const C_WALL_DARK := Color(0.52, 0.44, 0.33)
const C_ROOF := Color(0.42, 0.20, 0.16)
const C_ROOF_DARK := Color(0.30, 0.14, 0.11)
const C_WOOD := Color(0.45, 0.30, 0.18)
const C_WOOD_DARK := Color(0.32, 0.21, 0.12)
const C_GOLD := Color(0.92, 0.78, 0.38)
const C_CLOTH_RED := Color(0.72, 0.22, 0.18)
const C_CLOTH_BLUE := Color(0.24, 0.40, 0.62)
const C_TENT := Color(0.58, 0.50, 0.38)
const C_AWNING := Color(0.78, 0.72, 0.58)
const C_STONE := Color(0.55, 0.53, 0.50)
const C_GLOW := Color(0.95, 0.55, 0.22)
const C_NPC := Color(0.30, 0.26, 0.22)
const C_SKIN := Color(0.85, 0.72, 0.58)

const TEX_DIR := "res://assets/sprites/city/"
const TEX_EXTS: Array[String] = [".png", ".webp", ".jpg"]
## 贴图建筑的目标世界宽度（与程序化建筑的 300~420 尺度对齐）
const BUILDING_WORLD_WIDTH := 400.0

## NPC 立绘目录（AI 美术批次：assets/sprites/npcs/<npc_id>.png）
const NPC_TEX_DIR := "res://assets/sprites/npcs/"
const NPC_TEX_EXTS: Array[String] = [".png", ".webp", ".jpg"]
## 立绘世界目标高度（世界像素）。立绘素材约 768px 高，需等比缩到与几何小人同尺度。
const NPC_WORLD_HEIGHT := 56.0


## 构建一座建筑节点（含阴影、造型、牌匾、门口 NPC）
static func build(key: String, cname: String, open: bool) -> Node2D:
	var root := Node2D.new()
	root.name = "B_" + key
	root.set_meta("key", key)

	var base := Node2D.new()
	root.add_child(base)

	if open:
		# 优先用 AI 贴图；缺图时回退程序化造型
		if not _use_building_texture(base, key):
			_match_building(base, key)
	else:
		_draw_closed(base)
		var lock := Label.new()
		lock.text = "未开放"
		lock.position = Vector2(-40, 30)
		lock.add_theme_font_size_override("font_size", 26)
		lock.add_theme_color_override("font_color", Color(0.8, 0.75, 0.7, 0.9))
		root.add_child(lock)

	# 名字牌匾：贴图建筑挂在建筑顶端之外，程序化建筑沿用檐下位置
	var plaque := Label.new()
	plaque.text = cname
	plaque.add_theme_font_size_override("font_size", 40)
	plaque.add_theme_color_override("font_color", C_GOLD)
	plaque.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	plaque.add_theme_constant_override("shadow_offset_x", 2)
	plaque.add_theme_constant_override("shadow_offset_y", 2)
	var top_y := -170.0
	if base.has_meta("art_height"):
		top_y = -float(base.get_meta("art_height")) - 34.0
	plaque.position = Vector2(-cname.length() * 20.0 - 2, top_y)
	root.add_child(plaque)

	return root


## 尝试用贴图渲染建筑。贴图底边对齐门口地面 (0,0)、水平居中。命中返回 true。
static func _use_building_texture(base: Node2D, key: String) -> bool:
	var tex := _building_texture(key)
	if tex == null:
		return false
	var tw := maxf(1.0, float(tex.get_width()))
	var sc := BUILDING_WORLD_WIDTH / tw
	var h := float(tex.get_height()) * sc
	var sp := Sprite2D.new()
	sp.texture = tex
	sp.scale = Vector2(sc, sc)
	sp.centered = false            # 用左上角定位，便于精确贴地
	sp.position = Vector2(-BUILDING_WORLD_WIDTH * 0.5, -h)
	base.add_child(sp)
	base.set_meta("art_height", h)
	return true


## 按建筑 key 加载贴图（缺失返回 null）
static func _building_texture(key: String) -> Texture2D:
	if key.is_empty():
		return null
	for ext in TEX_EXTS:
		var path: String = TEX_DIR + key + ext
		if ResourceLoader.exists(path):
			var res := load(path)
			if res is Texture2D:
				return res
	return null


## 门口 NPC（简单人形 + 名牌）
## 传 npc_id 且存在 res://assets/sprites/npcs/<npc_id>.png 时改用立绘贴图，
## 否则回退到几何小人。两者占据相同的世界高度与落脚点，便于混排。
static func build_npc(npc_name: String, npc_id: String = "") -> Node2D:
	var n := Node2D.new()

	var tex := _npc_texture(npc_id)
	if tex != null:
		# 立绘：等比缩放到世界目标高度，使脚底落在与几何小人一致的 y=26
		var sc := NPC_WORLD_HEIGHT / maxf(1.0, float(tex.get_height()))
		var sp := Sprite2D.new()
		sp.texture = tex
		sp.scale = Vector2(sc, sc)
		sp.position = Vector2(0.0, 26.0 - NPC_WORLD_HEIGHT * 0.5)
		n.add_child(sp)
	else:
		var body := Polygon2D.new()
		body.polygon = PackedVector2Array([
			Vector2(-10, -8), Vector2(10, -8), Vector2(8, 26), Vector2(-8, 26)])
		body.color = C_NPC
		n.add_child(body)
		var head := Polygon2D.new()
		head.polygon = PackedVector2Array([
			Vector2(0, -30), Vector2(8, -22), Vector2(0, -14), Vector2(-8, -22)])
		head.color = C_SKIN
		n.add_child(head)

	# 脚下投影：让贴图与几何小人都有"落地"感
	var shadow := Polygon2D.new()
	shadow.polygon = PackedVector2Array([
		Vector2(-15, 27), Vector2(0, 21), Vector2(15, 27), Vector2(0, 33)])
	shadow.color = Color(0, 0, 0, 0.22)
	n.add_child(shadow)
	n.move_child(shadow, 0)

	var lbl := Label.new()
	lbl.text = npc_name
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", Color(0.95, 0.92, 0.85))
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 1)
	lbl.position = Vector2(-npc_name.length() * 10.0, 30)
	n.add_child(lbl)
	return n


## 按 npc_id 尝试加载立绘贴图（缺失返回 null）
static func _npc_texture(npc_id: String) -> Texture2D:
	if npc_id.is_empty():
		return null
	for ext in NPC_TEX_EXTS:
		var path: String = NPC_TEX_DIR + npc_id + ext
		if ResourceLoader.exists(path):
			var res := load(path)
			if res is Texture2D:
				return res
	return null


static func _match_building(base: Node2D, key: String) -> void:
	match key:
		"tavern": _draw_tavern(base)
		"barracks": _draw_barracks(base)
		"market": _draw_market(base)
		"smith": _draw_smith(base)
		"hall": _draw_hall(base)
		_: _draw_hall(base)


# ------------------------------------------------------------------
# 各建筑造型（以 (0,0) 为门口地面中心，向上为负）
# ------------------------------------------------------------------

static func _draw_hall(base: Node2D) -> void:
	# 官府：宽三间大堂 + 台阶 + 双旗
	_body(base, Vector2(-180, -190), Vector2(360, 130))
	_roof(base, Vector2(-210, -190), Vector2(420, 70))
	_pillars(base, Vector2(-180, -190), Vector2(360, 130), 5)
	_stairs(base, Vector2(-70, -60), Vector2(140, 60))
	_flag(base, Vector2(-215, -190), C_CLOTH_RED)
	_flag(base, Vector2(215, -190), C_CLOTH_RED)


static func _draw_tavern(base: Node2D) -> void:
	# 酒馆：两层小楼 + 酒旗
	_body(base, Vector2(-150, -230), Vector2(300, 90))
	_body(base, Vector2(-170, -140), Vector2(340, 90))
	_roof(base, Vector2(-190, -230), Vector2(380, 62))
	_roof(base, Vector2(-185, -140), Vector2(370, 52))
	_windows(base, Vector2(-150, -230), Vector2(300, 90), 3)
	_door(base, Vector2(-36, -50), Vector2(72, 50))
	# 酒旗
	var pole := Polygon2D.new()
	pole.polygon = PackedVector2Array([
		Vector2(150, -250), Vector2(156, -250), Vector2(156, -60), Vector2(150, -60)])
	pole.color = C_WOOD_DARK
	base.add_child(pole)
	var flag := Polygon2D.new()
	flag.polygon = PackedVector2Array([
		Vector2(156, -250), Vector2(230, -236), Vector2(156, -206)])
	flag.color = C_CLOTH_BLUE
	base.add_child(flag)
	var ji := Label.new()
	ji.text = "酒"
	ji.add_theme_font_size_override("font_size", 26)
	ji.add_theme_color_override("font_color", Color(0.95, 0.92, 0.85))
	ji.position = Vector2(168, -244)
	base.add_child(ji)


static func _draw_barracks(base: Node2D) -> void:
	# 兵营：两座营帐 + 兵器架 + 战旗
	_tent(base, Vector2(-130, -60), Vector2(200, 150))
	_tent(base, Vector2(60, -40), Vector2(170, 120))
	_rack(base, Vector2(150, -60))
	_flag(base, Vector2(-185, -70), C_CLOTH_BLUE)


static func _draw_market(base: Node2D) -> void:
	# 市场：两排摊位（条纹雨棚）+ 货箱
	_stall(base, Vector2(-160, -90), Vector2(180, 110), C_CLOTH_RED)
	_stall(base, Vector2(30, -90), Vector2(180, 110), C_CLOTH_BLUE)
	_crate(base, Vector2(-60, -30), 34)
	_crate(base, Vector2(10, -34), 28)
	_crate(base, Vector2(120, -28), 30)


static func _draw_smith(base: Node2D) -> void:
	# 铁匠铺：棚子 + 炉子（火光）+ 砧台
	_shed(base, Vector2(-150, -160), Vector2(300, 110))
	_forge(base, Vector2(-90, -50))
	_anvil(base, Vector2(60, -50))
	_barrel(base, Vector2(140, -40))


static func _draw_closed(base: Node2D) -> void:
	var body := Polygon2D.new()
	body.polygon = PackedVector2Array([
		Vector2(-130, -140), Vector2(130, -140), Vector2(130, 0), Vector2(-130, 0)])
	body.color = Color(0.48, 0.44, 0.40)
	base.add_child(body)
	var roof := Polygon2D.new()
	roof.polygon = PackedVector2Array([
		Vector2(-150, -140), Vector2(0, -200), Vector2(150, -140)])
	roof.color = Color(0.36, 0.33, 0.30)
	base.add_child(roof)


# ------------------------------------------------------------------
# 通用部件
# ------------------------------------------------------------------

static func _body(base: Node2D, pos: Vector2, size: Vector2) -> void:
	var body := Polygon2D.new()
	body.polygon = PackedVector2Array([
		pos, pos + Vector2(size.x, 0), pos + size, pos + Vector2(0, size.y)])
	body.color = C_WALL
	base.add_child(body)
	# 底边阴影
	var shade := Polygon2D.new()
	shade.polygon = PackedVector2Array([
		pos + Vector2(0, size.y - 14), pos + size,
		pos + size, pos + Vector2(0, size.y)])
	shade.color = C_WALL_DARK
	base.add_child(shade)


static func _roof(base: Node2D, pos: Vector2, size: Vector2) -> void:
	var roof := Polygon2D.new()
	roof.polygon = PackedVector2Array([
		pos + Vector2(-14, 0), pos + Vector2(size.x * 0.5, -size.y),
		pos + size + Vector2(14, 0), pos + Vector2(size.x, 8),
		pos + Vector2(size.x * 0.5, -size.y + 18), pos + Vector2(0, 8)])
	roof.color = C_ROOF
	base.add_child(roof)
	# 屋脊
	var ridge := Line2D.new()
	ridge.points = PackedVector2Array([
		pos + Vector2(-6, -2), pos + Vector2(size.x * 0.5, -size.y - 2),
		pos + size + Vector2(6, -2)])
	ridge.width = 6.0
	ridge.default_color = C_ROOF_DARK
	base.add_child(ridge)


static func _pillars(base: Node2D, pos: Vector2, size: Vector2, count: int) -> void:
	for i in range(count):
		var x := pos.x + size.x * float(i) / float(count - 1)
		var col := Polygon2D.new()
		col.polygon = PackedVector2Array([
			Vector2(x - 7, pos.y + 10), Vector2(x + 7, pos.y + 10),
			Vector2(x + 7, pos.y + size.y), Vector2(x - 7, pos.y + size.y)])
		col.color = C_WOOD
		base.add_child(col)


static func _stairs(base: Node2D, pos: Vector2, size: Vector2) -> void:
	for i in range(3):
		var h := size.y * (3.0 - float(i)) / 3.0
		var w := size.x * (1.0 - float(i) * 0.18)
		var x := pos.x + (size.x - w) * 0.5
		var st := Polygon2D.new()
		st.polygon = PackedVector2Array([
			Vector2(x, pos.y + size.y - h), Vector2(x + w, pos.y + size.y - h),
			Vector2(x + w, pos.y + size.y), Vector2(x, pos.y + size.y)])
		st.color = C_STONE
		base.add_child(st)


static func _door(base: Node2D, pos: Vector2, size: Vector2) -> void:
	var d := Polygon2D.new()
	d.polygon = PackedVector2Array([
		pos, pos + Vector2(size.x, 0), pos + size, pos + Vector2(0, size.y)])
	d.color = C_WOOD_DARK
	base.add_child(d)


static func _windows(base: Node2D, pos: Vector2, size: Vector2, count: int) -> void:
	for i in range(count):
		var x := pos.x + size.x * (float(i) + 0.5) / float(count) - 22
		var w := Polygon2D.new()
		w.polygon = PackedVector2Array([
			Vector2(x, pos.y + 24), Vector2(x + 44, pos.y + 24),
			Vector2(x + 44, pos.y + 62), Vector2(x, pos.y + 62)])
		w.color = Color(0.20, 0.16, 0.12)
		base.add_child(w)


static func _flag(base: Node2D, top: Vector2, color: Color) -> void:
	var pole := Polygon2D.new()
	pole.polygon = PackedVector2Array([
		top + Vector2(-3, 0), top + Vector2(3, 0), top + Vector2(3, 120),
		top + Vector2(-3, 120)])
	pole.color = C_WOOD_DARK
	base.add_child(pole)
	var f := Polygon2D.new()
	f.polygon = PackedVector2Array([
		top + Vector2(3, 0), top + Vector2(58, 12), top + Vector2(3, 34)])
	f.color = color
	base.add_child(f)


static func _tent(base: Node2D, pos: Vector2, size: Vector2) -> void:
	var t := Polygon2D.new()
	t.polygon = PackedVector2Array([
		pos + Vector2(-size.x * 0.5, 0), pos + Vector2(0, -size.y),
		pos + Vector2(size.x * 0.5, 0)])
	t.color = C_TENT
	base.add_child(t)
	var door := Polygon2D.new()
	door.polygon = PackedVector2Array([
		pos + Vector2(-26, 0), pos + Vector2(0, -52), pos + Vector2(26, 0)])
	door.color = C_WALL_DARK
	base.add_child(door)


static func _rack(base: Node2D, pos: Vector2) -> void:
	var frame := Polygon2D.new()
	frame.polygon = PackedVector2Array([
		pos + Vector2(-40, -70), pos + Vector2(40, -70),
		pos + Vector2(40, -62), pos + Vector2(-40, -62)])
	frame.color = C_WOOD_DARK
	base.add_child(frame)
	for i in range(3):
		var x := pos.x - 26 + i * 26
		var blade := Polygon2D.new()
		blade.polygon = PackedVector2Array([
			Vector2(x - 3, -66) + pos, Vector2(x + 3, -66) + pos,
			Vector2(x + 3, -20) + pos, Vector2(x - 3, -20) + pos])
		blade.color = C_STONE
		base.add_child(blade)


static func _stall(base: Node2D, pos: Vector2, size: Vector2, cloth: Color) -> void:
	# 台面
	var table := Polygon2D.new()
	table.polygon = PackedVector2Array([
		pos, pos + Vector2(size.x, 0), pos + Vector2(size.x - 12, 52),
		pos + Vector2(12, 52)])
	table.color = C_WOOD
	base.add_child(table)
	# 四根柱
	for px in [pos + Vector2(6, 0), pos + Vector2(size.x - 12, 0)]:
		var leg := Polygon2D.new()
		leg.polygon = PackedVector2Array([
			px + Vector2(0, -70), px + Vector2(7, -70),
			px + Vector2(7, 6), px + Vector2(0, 6)])
		leg.color = C_WOOD_DARK
		base.add_child(leg)
	# 条纹雨棚
	var aw := Polygon2D.new()
	aw.polygon = PackedVector2Array([
		pos + Vector2(-12, -70), pos + Vector2(size.x + 12, -70),
		pos + Vector2(size.x, -44), pos + Vector2(0, -44)])
	aw.color = C_AWNING
	base.add_child(aw)
	var stripes := int(size.x / 24.0)
	for i in range(stripes):
		if i % 2 == 0:
			continue
		var x0 := pos.x - 12 + 24.0 * float(i)
		var s := Polygon2D.new()
		s.polygon = PackedVector2Array([
			Vector2(x0, -70) + pos, Vector2(x0 + 24, -70) + pos,
			Vector2(x0 + 18, -44) + pos, Vector2(x0 - 6, -44) + pos])
		s.color = cloth
		base.add_child(s)


static func _crate(base: Node2D, pos: Vector2, s: float) -> void:
	var c := Polygon2D.new()
	c.polygon = PackedVector2Array([
		Vector2(-s * 0.5, -s) + pos, Vector2(s * 0.5, -s) + pos,
		Vector2(s * 0.5, 0) + pos, Vector2(-s * 0.5, 0) + pos])
	c.color = C_WOOD
	base.add_child(c)


static func _shed(base: Node2D, pos: Vector2, size: Vector2) -> void:
	_roof(base, pos, size)
	for px in [pos.x + 10, pos.x + size.x - 10]:
		var leg := Polygon2D.new()
		leg.polygon = PackedVector2Array([
			Vector2(px - 6, pos.y + 14), Vector2(px + 6, pos.y + 14),
			Vector2(px + 6, 0), Vector2(px - 6, 0)])
		leg.color = C_WOOD_DARK
		base.add_child(leg)


static func _forge(base: Node2D, pos: Vector2) -> void:
	var f := Polygon2D.new()
	f.polygon = PackedVector2Array([
		pos + Vector2(-40, -60), pos + Vector2(40, -60),
		pos + Vector2(48, 0), pos + Vector2(-48, 0)])
	f.color = C_STONE
	base.add_child(f)
	var fire := Polygon2D.new()
	fire.polygon = PackedVector2Array([
		pos + Vector2(-20, -34), pos + Vector2(20, -34),
		pos + Vector2(26, -6), pos + Vector2(-26, -6)])
	fire.color = C_GLOW
	base.add_child(fire)


static func _anvil(base: Node2D, pos: Vector2) -> void:
	var a := Polygon2D.new()
	a.polygon = PackedVector2Array([
		pos + Vector2(-30, -34), pos + Vector2(34, -34), pos + Vector2(26, -22),
		pos + Vector2(10, -16), pos + Vector2(12, 0), pos + Vector2(-12, 0),
		pos + Vector2(-8, -18), pos + Vector2(-26, -24)])
	a.color = Color(0.28, 0.28, 0.30)
	base.add_child(a)


static func _barrel(base: Node2D, pos: Vector2) -> void:
	var b := Polygon2D.new()
	b.polygon = PackedVector2Array([
		pos + Vector2(-22, -50), pos + Vector2(22, -50),
		pos + Vector2(26, 0), pos + Vector2(-26, 0)])
	b.color = C_WOOD
	base.add_child(b)
	var band := Polygon2D.new()
	band.polygon = PackedVector2Array([
		pos + Vector2(-24, -32), pos + Vector2(24, -32),
		pos + Vector2(25, -26), pos + Vector2(-25, -26)])
	band.color = C_WOOD_DARK
	base.add_child(band)
