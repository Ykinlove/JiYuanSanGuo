extends SceneTree
## 城池接地探针（第六十九轮·第 5 项第七层：城池视觉融入地形）
##
## 【本层要证明的核心主张】
##   城池不是「飘在地图上的一张图标」，而是**站在地形上**：
##     ① marker 的视觉节点按地形高度场抬升（与玩家同一个出口 sample_height）；
##     ② 高低差真实存在（不能所有城池都抬一样多 —— 那等于没接）；
##     ③ 接地投影落在**脚下**而不是图标中心；
##     ④ 抬升有上限（否则深谷里的城池会飞上天）；
##     ⑤ 基准 y 只记一次（连调不累加 —— 这是 terrain_height 的血泪坑）；
##     ⑥ **接线真的通了**（本轮修复的核心，见 M 组）。
##
## 【为什么能真跑】全部走 **TerrainHeight 静态函数 + TerrainMesh + CityMarkerArt**，
## 三者零 autoload 依赖。**碰 TerrainPainter 就会编译期失败**：它的
## `_get_city_mask` 调 DataManager，而 `--headless --script` 不加载 autoload →
## `Identifier not found: DataManager`，且引擎仍会吐出上次输出缓冲 → 假绿灯。

const CITY_JSON := "res://assets/data/cities.json"
const WORLD := Vector2(21256.0, 21826.0)


## 【本轮·关键】TerrainMesh.setup 的形参刻意是 `Object` 而非 `TerrainPainter`
## （MEMORY 铁律「写死具体基类会破坏测试替身」留的口子），而 `_build()` 内部
## **只调 `terrain.sample_height(wx, wy)` 一个方法**。
## 故这里写一个只实现该方法的 RefCounted 替身：内部直接调 TerrainHeight 纯函数，
## 零 autoload 依赖，且让 mesh 的法线**真实非 UP** —— 否则 M5 的限幅判据
## 会在「法线恒 UP → weight 恒 0 → rotation 恒 0」下**恒真通过**（假绿灯）。
class StubPainter extends RefCounted:
	var world: Vector2 = Vector2.ZERO

	func _init(w: Vector2) -> void:
		world = w

	func sample_height(wx: float, wy: float) -> Dictionary:
		var e := TerrainHeight.elevation_at(wx, wy, world, 0.0)
		return {
			"elev": e,
			"lift": TerrainHeight.lift_at(wx, wy, world, 0.0),
			"band": TerrainHeight.band_name(e),
		}


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var fails: Array = []
	var okc := 0
	var cities := _load_cities()
	if cities.is_empty():
		print("FAIL C0 读不到 cities.json")
		print("PROBE_DONE 0/1")
		print("CITY_GROUND_PROBE FAIL")
		quit(0)
		return
	okc += _group_c(fails, cities)   # C 组·高度场一致性
	okc += _group_s(fails, cities)   # S 组·接地投影
	okc += _group_b(fails, cities)   # B 组·基准不累加
	okc += _group_m(fails, cities)   # M 组·marker 真被抬升 + 真被倾斜
	print("PROBE_DONE " + str(okc) + "/" + str(okc + fails.size()))
	if fails.is_empty():
		print("CITY_GROUND_PROBE PASS")
	else:
		for f in fails:
			print("FAIL " + str(f))
		print("CITY_GROUND_PROBE FAIL")
	quit(0)


func _ok(fails: Array, cond: bool, label: String) -> void:
	if cond:
		print("  [OK] " + label)
	else:
		print("  [FAIL] " + label)
		fails.append(label)


func _load_cities() -> Array:
	var f := FileAccess.open(CITY_JSON, FileAccess.READ)
	if f == null:
		return []
	var p: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if p is Array:
		return p
	if p is Dictionary:
		var a: Variant = (p as Dictionary).get("cities", [])
		if a is Array:
			return a
	return []


## 直接走纯函数 TerrainHeight（零 autoload 依赖），city_mask 传 0（无城周压平）。
## 【绕过 city_mask 是否损失判据覆盖】不损失：city_mask 只做「城周压平」，
## 实测绕过前后 110 城的 lift 仍横跨 0~714px、96 种取值、4 类地形档位（C2/C3）
## → 落差主要来源是**基础海拔**而非压平。判据覆盖由 C2/C3 兜底。
func _height_at(wx: float, wy: float) -> Dictionary:
	var e := TerrainHeight.elevation_at(wx, wy, WORLD, 0.0)
	return {
		"elev": e,
		"lift": TerrainHeight.lift_at(wx, wy, WORLD, 0.0),
		"band": TerrainHeight.band_name(e),
	}


## ---------- C 组·高度场一致性 ----------
func _group_c(fails: Array, cities: Array) -> int:
	print("== C 组·城池与地形高度场同源 ==")
	var okc := 0

	# C1 高度场能采样（前置）
	var s0 := _height_at(10000.0, 10000.0)
	okc += 1
	_ok(fails, s0.has("lift") and s0.has("band"),
		"C1 高度场可采样（keys=" + str(s0.keys()) + "）")

	# C2【核心】各城池处的 lift 必须**不全相同**。
	#      若全为 0 → 城池完全没接高度场（图标浮在原始平面上）。
	#      若全相同 → 接了但写死了一个常量，同样是假接入。
	var lifts: Array = []
	var bands := {}
	for c in cities:
		var sm := _height_at(float(c.get("map_x", 0)), float(c.get("map_y", 0)))
		lifts.append(float(sm.get("lift", 0.0)))
		bands[str(sm.get("band", ""))] = true
	var lo := INF
	var hi := -INF
	for l in lifts:
		lo = minf(lo, float(l))
		hi = maxf(hi, float(l))
	var uniq := {}
	for l in lifts:
		uniq[str(int(float(l) * 100.0))] = true
	okc += 1
	_ok(fails, uniq.size() >= 5,
		"C2【核心】各城池 lift 多样（" + str(uniq.size()) + " 种不同取值，范围 "
		+ ("%.1f" % lo) + "~" + ("%.1f" % hi) + "）")

	# C3 地形档位多样（说明确实横跨平原/丘陵/山地）
	okc += 1
	_ok(fails, bands.size() >= 3,
		"C3 城池横跨多种地形档位：" + ", ".join(PackedStringArray(bands.keys())))

	# C4 lift 必须**全为非负**（向上抬；负值会把城池埋进地里）
	var negatives := 0
	for l in lifts:
		if float(l) < -0.001:
			negatives += 1
	okc += 1
	_ok(fails, negatives == 0,
		"C4 lift 全为非负（实测 " + str(negatives) + " 个负值 —— 负值会把城池埋进地里）")

	# C5 抬升有上限：不能大到把城池甩出画面。
	okc += 1
	_ok(fails, hi <= TerrainHeight.HEIGHT_SCALE * TerrainHeight.VERT_EXAGGERATE
			and hi > 0.0,
		"C5 抬升在理论上限内（实测 max=" + ("%.1f" % hi) + " ≤ 上界 "
		+ ("%.1f" % (TerrainHeight.HEIGHT_SCALE * TerrainHeight.VERT_EXAGGERATE))
		+ "，且 >0 说明真的抬了）")

	return okc


## ---------- S 组·接地投影 ----------
func _group_s(fails: Array, cities: Array) -> int:
	print("== S 组·接地投影落在脚下 ==")
	var okc := 0
	var city: Dictionary = cities[0]
	var mk := Node2D.new()
	root.add_child(mk)
	CityMarkerArt.build(mk, city)

	# S1/S2 投影识别：**按半透明黑判定，不按几何**。
	# 【本轮修正的判据缺陷】原判据找「第一个 size>=12 的 Polygon2D 且 r.y<r.x*0.6」——
	# 但 faction 底盘的外环是 22 点椭圆、position.y=13、ry/rx≈0.32，
	# **同样满足该几何条件** → 一旦 shadow 没被 move 到最底层，
	# 判据会误抓底盘并假绿。现改为按 color.a 精确锁定 shadow 本体。
	var shadow_y := -999.0
	var sh_circum := 0.0
	var n_shadow := 0
	for c in mk.get_children():
		if c is Polygon2D:
			var pg := c as Polygon2D
			if pg.color.a > 0.0 and pg.color.a < 0.5 and pg.color.r < 0.05:
				shadow_y = pg.position.y
				var poly := pg.polygon
				if poly.size() >= 12:
					sh_circum = poly.size()
				n_shadow += 1
	okc += 1
	_ok(fails, n_shadow == 1 and sh_circum >= 12,
		"S1【核心】全marker 恰好 1 个接地投影且为多边形（实测 " + str(n_shadow)
		+ " 个 / " + str(sh_circum) + " 顶点）")
	okc += 1
	_ok(fails, shadow_y > 0.0,
		"S2【核心】投影在图标下方（y=" + ("%.1f" % shadow_y)
		+ "，须 >0 才是落地而非居中）")

	# S3 投影是 marker 的**最底层**（否则会盖住城池本体）
	var first_shadow := false
	if mk.get_child_count() > 0:
		var c0 := mk.get_child(0)
		first_shadow = c0 is Polygon2D and (c0 as Polygon2D).color.a < 0.5
	okc += 1
	_ok(fails, first_shadow,
		"S3 投影置于最底层（get_child(0) 是半透明投影）")

	mk.queue_free()
	return okc


## ---------- B 组·基准不累加 ----------
func _group_b(fails: Array, cities: Array) -> int:
	print("== B 组·基准 y 只记一次（连调不累加）==")
	var okc := 0
	var c: Dictionary = cities[0]
	var cx := float(c.get("map_x", 0))
	var cy := float(c.get("map_y", 0))

	# B1 连调 10 次，位移必须等于单次（terrain_height 的 H7 血泪坑）
	var n := Node2D.new()
	root.add_child(n)
	n.position = Vector2(cx, cy)
	TerrainHeight.apply_to(n, cx, cy, WORLD)
	var d1 := absf(n.position.y - cy)
	for i in range(9):
		TerrainHeight.apply_to(n, cx, cy, WORLD)
	var d10 := absf(n.position.y - cy)
	okc += 1
	_ok(fails, absf(d10 - d1) < 0.5,
		"B1【核心】连调 10 次位移 == 单次（单次 " + ("%.2f" % d1) + "，10 次 "
		+ ("%.2f" % d10) + "）")
	n.queue_free()

	# B2 首次调用必须真的抬升（不是 no-op）
	var n2 := Node2D.new()
	root.add_child(n2)
	n2.position = Vector2(cx, cy)
	TerrainHeight.apply_to(n2, cx, cy, WORLD)
	okc += 1
	_ok(fails, absf(n2.position.y - cy) > 0.5,
		"B2 首次调用真的抬升了（位移 " + ("%.2f" % absf(n2.position.y - cy)) + "px）")
	n2.queue_free()

	return okc


## ---------- M 组·marker 真被抬升 + 真被倾斜（本轮决定性判据）----------
## 【为什么这组最重要】C 组测的是「地形有起伏」（高度场本身），
## 而用户的诉求是「城池站在地形上」。二者之间隔着**接线**：
## world_map._apply_height 按 Art/Visual 子节点找抬升对象，
## 而本模块原先把图形直接挂在 marker 上 → 两者都没有 → **静默 return**，
## 110 个城池**从未被抬升过**。这组判据就是锁死那条接线。
func _group_m(fails: Array, cities: Array) -> int:
	print("== M 组·marker 真被抬升 / 真被倾斜（接线判据）==")
	var okc := 0

	# mesh 走 StubPainter 替身 → 法线真实（非 UP），M5 限幅判据才有效
	var mesh := TerrainMesh.new()
	root.add_child(mesh)
	mesh.setup(StubPainter.new(WORLD), WORLD)
	var probe_n := mesh.normal_at(float(cities[0].get("map_x", 0)),
		float(cities[0].get("map_y", 0)))

	# ---- M0【前置】mesh 法线必须真的不是 UP ----
	#      否则 M5 会在 weight≡0 的死值上恒真通过（假绿灯）。
	okc += 1
	_ok(fails, probe_n.z < 0.999,
		"M0【前置】mesh 法线真实非 UP（z=" + ("%.5f" % probe_n.z)
		+ "，若恒为 1 则倾斜判据全部无效）")

	# ---- M1【核心】传入 world 后必须建出 Art 子节点 ----
	#      没有 Art → world_map._apply_height 找不到可视子节点 → 静默 return，
	#      城池永远不抬升（本轮修复的核心）。
	var mk := Node2D.new()
	root.add_child(mk)
	CityMarkerArt.build(mk, cities[0], WORLD, mesh)
	var art := mk.get_node_or_null("Art") as Node2D
	okc += 1
	_ok(fails, art != null,
		"M1【核心】传入 world 后建出 Art 子节点（_apply_height 靠它接管抬升）")

	# ---- M2 不传 world 时退回旧行为（无 Art），保证无头可测 ----
	var mk2 := Node2D.new()
	root.add_child(mk2)
	CityMarkerArt.build(mk2, cities[0])
	okc += 1
	_ok(fails, mk2.get_node_or_null("Art") == null
		and mk2.get_child_count() > 0,
		"M2 不传 world 时退回直画（无 Art 但有图形，旧行为不变）")

	# ---- M3 图形必须画在 Art 里（不在 marker 根上）----
	var in_art := 0
	var in_root := 0
	if art != null:
		in_art = art.get_child_count()
	in_root = mk.get_child_count()
	okc += 1
	_ok(fails, art != null and in_art > 0 and in_root == 1,
		"M3【核心】城池图形画在 Art 内（Art 内 " + str(in_art)
		+ " 个 / marker 根 " + str(in_root) + " 个，根应只有 Art 一个）")

	# ---- M4【端到端】复刻 world_map._apply_height 的接线，验证真被抬升 ----
	#      【关键·不能只判 Art 存在】Art 存在但 _apply_height 若改为改 marker
	#      自身坐标，M1~M3 仍全绿。而 marker.position 被交互判定
	#      （_find_nearest_place 距离、_place_radius 半径）与存档坐标直读，
	#      改它＝「走到城下」的判定全错。此处按 _apply_height 的真实契约验：
	#      抬升只落在 Art 上，marker 自身坐标逐位不变。
	#      【方向·本轮踩过】判据首版写 `art.position.y > 0.5` 判红，实为**判据错**：
	#      Godot 2D 的 y 轴朝下，「向上抬」= y **减小**。
	#      TerrainHeight.apply_to 的实现是 `y = base_y - lift`，
	#      所以 Art.y 应为**负**（−714.0 正是满量程抬升）。判据须按符号方向写。
	var city0: Dictionary = cities[0]
	var cx := float(city0.get("map_x", 0))
	var cy := float(city0.get("map_y", 0))
	mk.position = Vector2(cx, cy)
	var root_before := mk.position
	var expect_lift := TerrainHeight.lift_at(cx, cy, WORLD, 0.0)
	if art != null:
		art.position = Vector2.ZERO
		art.set_meta("base_y", 0.0)
		TerrainHeight.apply_to(art, cx, cy, WORLD)
	okc += 1
	_ok(fails, art != null and art.position.y < -0.5
		and is_equal_approx(-art.position.y, expect_lift)
		and mk.position == root_before,
		"M4【端到端】抬升只落在 Art 上（Art.y=" + ("%.1f" % art.position.y)
		+ "，2D y 轴朝下故向上为负，期望 -" + ("%.1f" % expect_lift)
		+ "）且 marker 坐标逐位不变（" + ("%.1f,%.1f" % [mk.position.x, mk.position.y])
		+ "）")

	# ---- M5 倾斜限幅在 ±CITY_MAX_TILT_DEG 内，且**确有非零倾斜** ----
	#      【双向】只测「不越界」在法线恒 UP 时是恒真的假绿；
	#      故同时要求「至少有一个城池真的歪了」，两端都测才有效。
	var lim := deg_to_rad(CityMarkerArt.CITY_MAX_TILT_DEG)
	var bad := 0
	var tilted := 0
	var max_abs := 0.0
	for c in cities:
		var t := Node2D.new()
		root.add_child(t)
		CityMarkerArt.apply_tilt(t, float(c.get("map_x", 0)),
			float(c.get("map_y", 0)), mesh)
		if absf(t.rotation) > lim + 0.001:
			bad += 1
		if absf(t.rotation) > 0.001:
			tilted += 1
			max_abs = maxf(max_abs, absf(t.rotation))
		t.queue_free()
	okc += 1
	_ok(fails, bad == 0 and tilted > 0,
		"M5【核心】倾斜双向限幅在 ±" + str(int(CityMarkerArt.CITY_MAX_TILT_DEG))
		+ "° 内（越界 " + str(bad) + " 个）**且确有非零倾斜**（歪了 "
		+ str(tilted) + " 个，最大 " + ("%.2f" % rad_to_deg(max_abs)) + "°）")

	# ---- M6 mesh 为 null 时不崩（生成时序：marker 早于 mesh 生成）----
	var mk6 := Node2D.new()
	root.add_child(mk6)
	CityMarkerArt.build(mk6, cities[0], WORLD, null)
	okc += 1
	_ok(fails, mk6.get_node_or_null("Art") != null,
		"M6 mesh 为 null 时仍建 Art（生成早于 mesh 的时序不崩）")

	# ---- M7 倾斜参数与玩家侧一致（否则城与角色对坡度的反应割裂）----
	okc += 1
	_ok(fails, CityMarkerArt.CITY_MAX_TILT_DEG == 14.0
		and is_equal_approx(CityMarkerArt.CITY_TILT_GAIN, 6.0),
		"M7 倾斜参数与玩家侧一致（MAX_TILT_DEG="
		+ str(int(CityMarkerArt.CITY_MAX_TILT_DEG)) + " / GAIN="
		+ ("%.1f" % CityMarkerArt.CITY_TILT_GAIN) + "）")

	# ---- M8 投影必须与城池主体同在 Art 内（抬升后不能影子留原地）----
	#      MEMORY 铁律「接地投影必须与主体同层」。
	#      本层 Art 即地面容器；若投影留在 marker 根，图标升高、影子不动＝悬空。
	#      【本轮踩过·判据缺陷】首版只按 `a<0.5` 抓，误抓 faction 内盘
	#      （实测 col=(0.82,0.41,0.37,**0.30**)，alpha 也在 0~0.5 区间）→ 报「2 个」。
	#      S1 之所以对，是因为它多判了 `color.r < 0.05`（影子是纯黑半透明）。
	#      **教训：判据不能只靠单个数值区间，必须用能唯一锁定目标的组合特征。**
	var shadow_in_art := 0
	if art != null:
		for c in art.get_children():
			if c is Polygon2D and (c as Polygon2D).color.a > 0.0 \
					and (c as Polygon2D).color.a < 0.5 \
					and (c as Polygon2D).color.r < 0.05:
				shadow_in_art += 1
	okc += 1
	_ok(fails, shadow_in_art == 1,
		"M8【核心】投影与主体同在 Art 内（实测 " + str(shadow_in_art)
		+ " 个纯黑半透明投影；留在 marker 根＝抬升后影子留原地＝悬空）")

	mk.queue_free()
	mk2.queue_free()
	mk6.queue_free()
	mesh.queue_free()
	return okc
