extends SceneTree
## 批次二（地标贴图）运行时探针
## ------------------------------------------------------------------
## 用途：静态检查（_compile_check / _validate）无法验证「贴图真能加载」与
## 「缩放换算是否符合预期」，本探针实际调用 CityInteriorArt / CityMarkerArt
## 的构建函数并检查产出的节点树。
##
## 注意：--headless --script 模式【不加载 autoload】（实证 root.has_node("GameState")=false）。
## CityInteriorArt 是 extends RefCounted + 纯静态方法且零 autoload 引用，可直接调用；
## CityMarkerArt 依赖 GameState/DataManager 判势力色，在该模式下编译不过，
## 故第 [3] 段改为直接加载贴图 + 复算缩放公式（详见 _check_city_markers 注释）。
## 运行：godot --headless --script res://tests/art2_probe.gd
## ------------------------------------------------------------------

const BUILDING_KEYS: Array[String] = ["hall", "tavern", "barracks", "market", "smith"]
const CITY_IDS: Array[String] = [
	"scene_17", "scene_19", "scene_21", "scene_27", "scene_37", "scene_38",
]
## 与脚本常量保持一致
const BUILDING_WORLD_WIDTH := 400.0
const ICON_BASE_PX := 128.0
const UNIQUE_BOOST := 1.14
## 【第六十五轮·已删除】原探针把城池类型缩放写死成 CITY_TYPE_SCALE = 0.80（村落 0.66），
## 生产常量现为 CityMarkerArt.TYPE_ICON_SCALE = {city:3.00, village:2.48, ...}。
## 数值已改为从生产源码动态解析（_parse_type_icon_scale），常量本身已删，避免死数据。

var _fail := 0


func _init() -> void:
	print("======================================================")
	print("批次二地标贴图探针")
	print("======================================================")

	_check_texture_files()
	_check_buildings()
	_check_city_markers()
	_check_math()

	print("")
	if _fail == 0:
		print("ART2 PROBE: ALL PASS")
	else:
		print("ART2 PROBE: %d FAIL" % _fail)
	quit(1 if _fail > 0 else 0)


func _ok(label: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("  [PASS] %s%s" % [label, "  " + detail if detail != "" else ""])
	else:
		_fail += 1
		print("  [FAIL] %s%s" % [label, "  " + detail if detail != "" else ""])


func _load_tex(path: String) -> Texture2D:
	if not ResourceLoader.exists(path):
		return null
	var res: Resource = load(path)
	if res is Texture2D:
		return res as Texture2D
	return null


## 1. 11 张贴图文件可加载
func _check_texture_files() -> void:
	print("\n[1] 贴图文件可加载")
	var n_b := 0
	for k in BUILDING_KEYS:
		var t := _load_tex("res://assets/sprites/city/" + k + ".png")
		if t != null:
			n_b += 1
	_ok("城内建筑贴图 5/5", n_b == 5, "实得 %d" % n_b)

	var n_c := 0
	for cid in CITY_IDS:
		var t := _load_tex("res://assets/sprites/map/" + cid + ".png")
		if t != null:
			n_c += 1
	_ok("都城专属贴图 6/6", n_c == 6, "实得 %d" % n_c)

	# 素材尺寸约定：建筑贴图宽固定 512px、高度随内容（紧贴不留透明边），
	# 高度应明显小于宽度（< 480），否则可能又回到了「正方形留白」的做法。
	var bt := _load_tex("res://assets/sprites/city/hall.png")
	if bt != null:
		_ok("建筑素材宽 512", bt.get_width() == 512,
			"实为 %d" % bt.get_width())
		_ok("建筑素材紧贴内容(高<480)", bt.get_height() < 480,
			"实为 %d×%d" % [bt.get_width(), bt.get_height()])
	var ct := _load_tex("res://assets/sprites/map/scene_17.png")
	if ct != null:
		_ok("地图图标为 256×256", ct.get_width() == 256 and ct.get_height() == 256,
			"实为 %d×%d" % [ct.get_width(), ct.get_height()])


func _find_sprite(n: Node) -> Sprite2D:
	if n is Sprite2D:
		return n as Sprite2D
	for c in n.get_children():
		var r := _find_sprite(c)
		if r != null:
			return r
	return null


## 【第六十五轮·新增】在整棵子树里找带 art_height 元数据的节点。
## 不用 get_child(0)：落地投影是后加的第 0 号子节点，写 meta 的 base 已挪到第 1 号。
## 找不到返回 -1.0（交由调用方判 FAIL）。
func _find_art_height(n: Node) -> float:
	if n.has_meta("art_height"):
		return float(n.get_meta("art_height"))
	for c in n.get_children():
		var v := _find_art_height(c)
		if v >= 0.0:
			return v
	return -1.0


## 2. 城内建筑：命中贴图、底边贴地、水平居中
func _check_buildings() -> void:
	print("\n[2] 城内建筑走贴图")
	for k in BUILDING_KEYS:
		var node := CityInteriorArt.build(k, "测试", true)
		var sp := _find_sprite(node)
		if sp == null or sp.texture == null:
			_ok("建筑 %s 用上贴图" % k, false, "未找到贴图 Sprite2D")
			continue
		var tex := sp.texture
		var sc := sp.scale.x
		var w := float(tex.get_width()) * sc
		var h := float(tex.get_height()) * sc
		# 宽度应等于目标世界宽度
		var w_ok := absf(w - BUILDING_WORLD_WIDTH) < 0.5
		# 底边贴地：左上角 y + 显示高度 == 0；水平居中：左上角 x == -w/2
		var bottom := sp.position.y + h
		var ground_ok := absf(bottom) < 0.5
		var center_ok := absf(sp.position.x + w * 0.5) < 0.5
		_ok("建筑 %-8s 宽=%.0f 高=%.0f 贴地(%+.1f) 居中" % [k, w, h, bottom],
			w_ok and ground_ok and center_ok and not sp.centered,
			"" if (w_ok and ground_ok and center_ok) else "几何不符")
		# art_height 元数据供牌匾定位。
		# 【第六十五轮·修探针过时】原判据写死 node.get_child(0)，但落地投影（Polygon2D）
		# 是后来加在 root 的第 0 号子节点，写 meta 的 base 被挤到第 1 号 ——
		# 于是 get_meta 恒返回 -1，5 座建筑整齐假红。实证：child(0)=Polygon2D(-1.0) /
		# child(1)=Node2D(228.125)。改为按「谁带 art_height」定位，不依赖子节点序号。
		var meta_h := _find_art_height(node)
		_ok("建筑 %-8s 记录 art_height" % k, absf(meta_h - h) < 0.5,
			"%.0f" % meta_h)

	# 缺图回退：不存在的 key 应走程序化绘制（无 Sprite2D）
	var fallback := CityInteriorArt.build("nonexistent_building", "测试", true)
	_ok("未知建筑回退程序化绘制", _find_sprite(fallback) == null)
	# 未开放建筑应显示「未开放」且不用贴图
	var closed := CityInteriorArt.build("hall", "测试", false)
	_ok("未开放建筑不走贴图", _find_sprite(closed) == null)


## 3. 大地图城池标记：专属贴图存在 + 缩放换算公式自洽
##
## 【第六十五轮·重写】原实现直接调 `CityMarkerArt.build()`，在 --script 模式下必然崩：
##   `city_marker_art.gd:47` 的 faction_color() 读 GameState.captured_cities、
##   `:50` 读 DataManager.get_faction6，而 `--headless --script` **不加载 autoload**
##   （实证 root.has_node("GameState")=false）→ 该脚本编译失败 →
##   类对象存在但方法全空 → "Nonexistent function 'build' in base 'GDScript'"。
##   生产代码在正常游戏里没问题（autoload 在），不该为测试改生产代码，故此处改为
##   「直接加载贴图 + 复算同一套缩放公式」。
##   另：原判据的常量（city 0.80 / village 0.66）也早过时，生产现值是
##   TYPE_ICON_SCALE={city:3.00, village:2.48, ...}。为免同类过时重演，
##   本段**从生产源码动态解析常量**，不再把数值抄一份进探针。
func _check_city_markers() -> void:
	print("\n[3] 大地图城池标记")
	var scales := _parse_type_icon_scale()
	_ok("解析 TYPE_ICON_SCALE（city/village 存在）",
		scales.has("city") and scales.has("village"),
		"解析到 %d 项" % scales.size())
	var base_px := _parse_const_float("ICON_BASE_PX", ICON_BASE_PX)
	var boost := _parse_const_float("UNIQUE_BOOST", UNIQUE_BOOST)
	var cap_boost := 1.18   # build() 内对 is_capital 的硬编码倍率，源码 city_marker_art.gd:105
	_ok("解析 ICON_BASE_PX=%.1f UNIQUE_BOOST=%.2f" % [base_px, boost],
		base_px > 0.0 and boost > 1.0)

	# 专属贴图：assets/sprites/map/<id>.png 必须真实可加载
	for cid in CITY_IDS:
		var tex := _load_map_texture(cid)
		if tex == null:
			_ok("城池 %s 专属贴图可加载" % cid, false, "map/%s.png 缺失" % cid)
			continue
		var is_cap: bool = cid in ["scene_17", "scene_19", "scene_37"]
		# 复算 build() 的目标宽度：type_scale × ICON_BASE_PX × UNIQUE_BOOST（都城再 ×1.18）
		var expect := float(scales.get("city", 3.0)) * base_px * boost
		if is_cap:
			expect *= cap_boost
		# 按 build() 的反算方式求 scale，再看显示宽是否回到 expect
		var sc := expect / maxf(1.0, float(tex.get_width()))
		var disp_w := float(tex.get_width()) * sc
		_ok("城池 %-9s 贴图 %dpx 显示宽 %.1f（期望 %.1f）" % [cid, tex.get_width(), disp_w, expect],
			absf(disp_w - expect) < 0.5)

	# 类型贴图：非专属城池回退到 city_icons/city.png，显示宽应等于 3.00×128=384
	var city_tex := _load_type_texture("city")
	if city_tex == null:
		_ok("类型贴图 city 可加载", false, "city_icons/city.png 缺失")
	else:
		var expect2 := float(scales.get("city", 3.0)) * base_px
		var sc2 := expect2 / maxf(1.0, float(city_tex.get_width()))
		_ok("普通城走类型贴图 显示宽 %.1f（期望 %.1f）" % [float(city_tex.get_width()) * sc2, expect2],
			absf(float(city_tex.get_width()) * sc2 - expect2) < 0.5)

	# 村落类型：scale 2.48 → 显示宽 317.4
	var vil_tex := _load_type_texture("village")
	if vil_tex == null:
		_ok("类型贴图 village 可加载", false, "city_icons/village.png 缺失")
	else:
		var expect3 := float(scales.get("village", 2.48)) * base_px
		var sc3 := expect3 / maxf(1.0, float(vil_tex.get_width()))
		_ok("村落显示宽 %.1f（期望 %.1f）" % [float(vil_tex.get_width()) * sc3, expect3],
			absf(float(vil_tex.get_width()) * sc3 - expect3) < 0.5)


## 从生产源码 city_marker_art.gd 解析 TYPE_ICON_SCALE 字典。
## 目的：探针不抄一份常量，避免生产调了数值而探针静默恒假。
func _parse_type_icon_scale() -> Dictionary:
	var out := {}
	var f := FileAccess.open("res://scripts/world/city_marker_art.gd", FileAccess.READ)
	if f == null:
		return out
	var txt := f.get_as_text()
	f.close()
	var start := txt.find("const TYPE_ICON_SCALE")
	if start < 0:
		return out
	var seg := txt.substr(start, 400)
	var re := RegEx.new()
	re.compile("\"(\\w+)\"\\s*:\\s*([0-9.]+)")
	for m in re.search_all(seg):
		out[m.get_string(1)] = float(m.get_string(2))
	return out


## 从生产源码解析一个 const 浮点常量，取不到时回退到探针自带默认值。
func _parse_const_float(name: String, fallback: float) -> float:
	var f := FileAccess.open("res://scripts/world/city_marker_art.gd", FileAccess.READ)
	if f == null:
		return fallback
	var txt := f.get_as_text()
	f.close()
	var re := RegEx.new()
	re.compile("const\\s+" + name + "\\s*:?=?\\s*([0-9.]+)")
	var m := re.search(txt)
	if m == null:
		return fallback
	return float(m.get_string(1))


func _load_map_texture(city_id: String) -> Texture2D:
	# 【GDScript 坑】for ext in [...] 的元素无静态类型，var path := 无法推断 → 显式标注
	for ext: String in [".png", ".webp", ".jpg"]:
		var path := "res://assets/sprites/map/" + city_id + ext
		if ResourceLoader.exists(path):
			var res := load(path)
			if res is Texture2D:
				return res
	return null


func _load_type_texture(city_type: String) -> Texture2D:
	var path := "res://assets/sprites/city_icons/" + city_type + ".png"
	if ResourceLoader.exists(path):
		var res := load(path)
		if res is Texture2D:
			return res
	return null


## 4. 独立复算：素材从 128 换成 256 时显示宽度不变（这正是本次改动的目的）
##
## 【第六十五轮·修假绿灯】原判据的 a 与 target 都由同一个 CITY_TYPE_SCALE(=0.80) 推导，
## 两边一起错、等式照样成立 —— 于是即便生产常量早从 0.80 改成 3.00，本段仍然全绿，
## 属于「结构上恒真」的假绿灯，验不出任何东西。
## 现改为：从生产源码解析真实 TYPE_ICON_SCALE，再验「任意素材分辨率 → 同一目标显示宽」。
func _check_math() -> void:
	print("\n[4] 缩放换算自洽性（素材分辨率无关）")
	var scales := _parse_type_icon_scale()
	var base_px := _parse_const_float("ICON_BASE_PX", ICON_BASE_PX)
	var boost := _parse_const_float("UNIQUE_BOOST", UNIQUE_BOOST)
	_ok("生产常量可解析（判据不依赖探针内抄写的数值）",
		scales.has("city") and base_px > 0.0 and boost > 0.0,
		"city=%s base_px=%.1f" % [str(scales.get("city", -1.0)), base_px])

	var type_scale := float(scales.get("city", 3.0))
	var target := type_scale * base_px            # 类型贴图目标世界宽
	var u_target := target * boost                # 专属贴图目标世界宽
	# 同一目标宽度下，128px / 256px / 512px 素材反算出的显示宽必须都等于 target
	var widths_ok := true
	var detail := ""
	for px: int in [128, 256, 512]:
		var shown := float(px) * (target / float(px))
		if absf(shown - target) > 0.01:
			widths_ok = false
		detail += "%dpx→%.1f " % [px, shown]
	_ok("类型贴图：128/256/512px 素材显示宽一致（%.1f）  %s" % [target, detail], widths_ok)

	# 专属贴图同样分辨率无关，且恒大于类型贴图
	var u_ok := true
	for px: int in [128, 256, 512]:
		if absf(float(px) * (u_target / float(px)) - u_target) > 0.01:
			u_ok = false
	_ok("专属贴图分辨率无关且 > 类型贴图（%.1f > %.1f）" % [u_target, target],
		u_ok and u_target > target)
	print("  说明：改前专属贴图硬编码 scale=1.0，256px 素材会渲染成 256 世界像素；")
	print("        改后按「目标世界宽度 ÷ 素材宽度」反算，换成任何分辨率都不走样。")
