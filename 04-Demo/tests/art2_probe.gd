extends SceneTree
## 批次二（地标贴图）运行时探针
## ------------------------------------------------------------------
## 用途：静态检查（_compile_check / _validate）无法验证「贴图真能加载」与
## 「缩放换算是否符合预期」，本探针实际调用 CityInteriorArt / CityMarkerArt
## 的构建函数并检查产出的节点树。
##
## 注意：--headless --script 模式【不加载 autoload】。这两个类是
## `extends RefCounted` + 静态方法，不依赖 EventBus/DataManager，因此可直接调用。
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
const CITY_TYPE_SCALE := 0.80

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
		# art_height 元数据供牌匾定位
		var meta_h := float(node.get_child(0).get_meta("art_height", -1.0))
		_ok("建筑 %-8s 记录 art_height" % k, absf(meta_h - h) < 0.5,
			"%.0f" % meta_h)

	# 缺图回退：不存在的 key 应走程序化绘制（无 Sprite2D）
	var fallback := CityInteriorArt.build("nonexistent_building", "测试", true)
	_ok("未知建筑回退程序化绘制", _find_sprite(fallback) == null)
	# 未开放建筑应显示「未开放」且不用贴图
	var closed := CityInteriorArt.build("hall", "测试", false)
	_ok("未开放建筑不走贴图", _find_sprite(closed) == null)


## 3. 大地图城池标记：专属贴图命中 + 缩放换算
func _check_city_markers() -> void:
	print("\n[3] 大地图城池标记")
	for cid in CITY_IDS:
		var marker := Node2D.new()
		CityMarkerArt.build(marker, {
			"id": cid, "type": "city", "is_capital": cid in ["scene_17", "scene_19", "scene_37"],
		})
		var sp := _find_sprite(marker)
		if sp == null or sp.texture == null:
			_ok("城池 %s 命中专属贴图" % cid, false, "无 Sprite2D")
			marker.free()
			continue
		var disp_w := float(sp.texture.get_width()) * sp.scale.x
		# 期望目标宽度：0.8×128×1.14（都城再 ×1.18）
		var expect := CITY_TYPE_SCALE * ICON_BASE_PX * UNIQUE_BOOST
		var is_cap: bool = cid in ["scene_17", "scene_19", "scene_37"]
		if is_cap:
			expect *= 1.18
		_ok("城池 %-9s 显示宽 %.1f（期望 %.1f）" % [cid, disp_w, expect],
			absf(disp_w - expect) < 0.5)
		marker.free()

	# 非专属城池：走 128px 类型贴图，显示宽应回到 102.4（与改前一致，无回归）
	var plain := Node2D.new()
	CityMarkerArt.build(plain, {"id": "scene_2", "type": "city", "is_capital": false})
	var psp := _find_sprite(plain)
	if psp != null and psp.texture != null:
		var pw := float(psp.texture.get_width()) * psp.scale.x
		_ok("普通城走类型贴图 显示宽 %.1f（期望 102.4）" % pw, absf(pw - 102.4) < 0.5)
	else:
		_ok("普通城走类型贴图", false, "无 Sprite2D")
	plain.free()

	# 村落类型：scale 0.66 → 显示宽 84.5
	var vil := Node2D.new()
	CityMarkerArt.build(vil, {"id": "scene_1000", "type": "village", "is_capital": false})
	var vsp := _find_sprite(vil)
	if vsp != null and vsp.texture != null:
		var vw := float(vsp.texture.get_width()) * vsp.scale.x
		_ok("村落显示宽 %.1f（期望 %.1f）" % [vw, 0.66 * 128.0], absf(vw - 0.66 * 128.0) < 0.5)
	else:
		_ok("村落类型贴图", false, "无 Sprite2D")
	vil.free()


## 4. 独立复算：素材从 128 换成 256 时显示宽度不变（这正是本次改动的目的）
func _check_math() -> void:
	print("\n[4] 缩放换算自洽性（素材分辨率无关）")
	# 类型贴图 128px @ scale 0.8
	var a := 128.0 * (CITY_TYPE_SCALE * ICON_BASE_PX / 128.0)
	# 专属贴图 256px @ 按目标宽度反算
	var target := CITY_TYPE_SCALE * ICON_BASE_PX * UNIQUE_BOOST
	var b := 256.0 * (target / 256.0)
	_ok("128px 与 256px 素材显示宽度按同一目标换算", absf(b - target) < 0.01,
		"%.1f / %.1f" % [a, b])
	_ok("专属贴图略大于类型贴图", target > a, "%.1f > %.1f" % [target, a])
	print("  说明：改前专属贴图硬编码 scale=1.0，256px 素材会渲染成 256 世界像素；")
	print("        改后按「目标世界宽度 ÷ 素材宽度」反算，换成任何分辨率都不走样。")
