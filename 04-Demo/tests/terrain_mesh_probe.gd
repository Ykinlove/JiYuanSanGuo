extends SceneTree
## TerrainMesh（第 5 项第六层·真地形建模）行为探针
##
## 【本层要证明的核心主张】
##   「地面几何真的随海拔变化」—— 这是与前五层的分界：
##   前五层都是平面贴图上的修饰，站立处地面永远一样；
##   本层必须做到：站高山与站平原，脚下的面**不同**。
##
## 【血泪·探针铁律】
##   ① 静态类上不能调实例方法（has_method 等）→ Parse Error
##   ② 探针内禁用 % 格式化，全用字符串拼接（参数不匹配会中断→伪装成超时）
##   ③ 必须加产出量闸门，防协程空跑却输出 PASS

var _checks := 0
var _fails := 0

## 假 terrain：只要能吐 sample_height 即可，用于验证网格算法本身。
## 【为什么可以假】TerrainMesh 只依赖 sample_height 的 {lift, band} 两个键，
## 而这两个键的真源 TerrainHeight 是静态类（无 autoload 依赖）→ 可直接调。
class FakeTerrain extends RefCounted:
	var world := Vector2(21256.0, 21826.0)
	func sample_height(wx: float, wy: float) -> Dictionary:
		var e := TerrainHeight.elevation_at(wx, wy, world, 0.0)
		return {"elev": e, "lift": TerrainHeight.lift_at(wx, wy, world, 0.0),
				"band": TerrainHeight.band_name(e)}


func _fail(msg: String) -> void:
	_fails += 1
	print("FAIL " + msg)


func _ok(msg: String) -> void:
	_checks += 1
	print("[OK] " + msg)


func _init() -> void:
	var expect := 13
	var ft := FakeTerrain.new()

	# ---- M1 构建：网格必须真的建出格数与顶点数据 ----
	var mesh := TerrainMesh.new()
	mesh.setup(ft, ft.world)
	var gs := mesh.grid_size()
	if gs.x < 8 or gs.y < 8:
		_fail("M1 网格格数过少 " + str(gs))
	else:
		_ok("M1 网格已构建 " + str(gs.x) + "×" + str(gs.y) + " 格")

	# ---- M2【核心】高度场：脚下地面必须随世界坐标变化 ----
	# 这条是本层的存在意义：若它失败，说明地面仍是平的 = 白做。
	var h_west := mesh.height_at(1500.0, 10000.0)   # 西部（西高东低 → 应较高）
	var h_east := mesh.height_at(19500.0, 10000.0)  # 东部（应较低）
	if absf(h_west - h_east) < 1.0:
		_fail("M2【核心】地面高度不随位置变化 west=" + str(h_west) + " east=" + str(h_east))
	else:
		_ok("M2【核心】地面几何随海拔真实变化 west=" + str(h_west) + " east=" + str(h_east))

	# ---- M2b【核心·加强】相邻格之间也必须有可感知高差 ----
	# M2 只证明「东 vs 西」不同，那可能只是**一个巨大的斜面**（仍然像平板）。
	# 真正的「面」要求**局部**就有起伏：相邻采样点之间的高差必须够大，
	# 否则受光差≈0，看起来还是平的 —— 这正是本层要治的病。
	var y2 := 10000.0
	var adjacent := []
	for i in range(8):
		adjacent.append(mesh.height_at(4000.0 + float(i) * TerrainMesh.CELL, y2))
	var max_adj := 0.0
	for i in range(adjacent.size() - 1):
		max_adj = maxf(max_adj, absf(float(adjacent[i + 1]) - float(adjacent[i])))
	if max_adj < 3.0:
		_fail("M2b【核心】相邻格高差过小 max=" + str(max_adj) + "px → 受光差≈0，仍是平板")
	else:
		_ok("M2b【核心】相邻格有可感知高差 max=" + str(max_adj) + "px")

	# ---- M3 同一水平线上的起伏（不是单一斜面）----
	var y := 9000.0
	var samples := []
	for i in range(9):
		samples.append(mesh.height_at(1000.0 + float(i) * 2200.0, y))
	var uniq := {}
	for s in samples:
		uniq[str(s)] = true
	if uniq.size() < 5:
		_fail("M3 同一水平线起伏太平，仅 " + str(uniq.size()) + " 种高度")
	else:
		_ok("M3 沿同一水平线有真实起伏 distinct=" + str(uniq.size()))

	# ---- M4 法线有效且非退化 ----
	var n := mesh.normal_at(6000.0, 9000.0)
	if absf(n.length() - 1.0) > 0.01 or n.z <= 0.0:
		_fail("M4 法线异常 len=" + str(n.length()) + " z=" + str(n.z))
	else:
		_ok("M4 法线单位化且朝上 z=" + str(n.z))

	# ---- M5 平地法线应接近竖直，斜坡应明显偏离 ----
	# 用两个相距很远的点各测一次坡度：至少有一个不为 0（真实有坡）
	var s1 := mesh.slope_at(3000.0, 3000.0)
	var s2 := mesh.slope_at(17000.0, 17000.0)
	if s1 <= 0.0 and s2 <= 0.0:
		_fail("M5 全图零坡度 → 地面是平板，立体感无从产生")
	else:
		_ok("M5 坡度非零 s1=" + str(s1) + " s2=" + str(s2))

	# ---- M6 坡度与法线一致性：坡大 ⟺ 法线 z 小 ----
	# 【GDScript 坑】不支持 `for ... else`（那是 Python 语法）→ Parse Error，
	# 而 Parse Error 会让整份探针加载失败、只吐一个笼统错误，极易误判成产品炸了。
	var ok6 := true
	var probe_pts := [Vector2(2000.0, 2000.0), Vector2(18000.0, 6000.0), Vector2(9000.0, 18000.0)]
	for p in probe_pts:
		var nn := mesh.normal_at(p.x, p.y)
		var ss := mesh.slope_at(p.x, p.y)
		var expect_slope := clampf(1.0 - nn.z, 0.0, 1.0)
		if absf(ss - expect_slope) > 0.001:
			ok6 = false
			_fail("M6 坡度与法线不一致 @" + str(p) + " slope=" + str(ss) + " exp=" + str(expect_slope))
			break
	if ok6:
		_ok("M6 坡度与法线互相一致")

	# ---- M7 确定性：同点两次查询必须完全一致 ----
	if mesh.height_at(7777.0, 8888.0) != mesh.height_at(7777.0, 8888.0):
		_fail("M7 高度查询不确定")
	else:
		_ok("M7 高度查询确定")

	# ---- M8 越界查询不得崩（相机边缘/传送落点会越界）----
	var ok8 := true
	for p in [Vector2(-5000.0, -5000.0), Vector2(99999.0, 99999.0), Vector2(0.0, 0.0)]:
		var v := mesh.height_at(p.x, p.y)
		if not is_finite(v):
			ok8 = false
	if not ok8:
		_fail("M8 越界查询产生非有限值")
	else:
		_ok("M8 越界查询安全")

	# ---- M9 缺 terrain 时不得崩，退化为空网格 ----
	var m2 := TerrainMesh.new()
	m2.setup(null, Vector2.ZERO)
	if m2.height_at(100.0, 100.0) != 0.0 or m2.normal_at(100.0, 100.0) != Vector3.UP:
		_fail("M9 terrain 缺失时未安全退化")
	else:
		_ok("M9 terrain 缺失时安全退化为平地")

	# ---- M10 高度方向正确：抬升量越大，y 越小（屏幕上方）----
	# 本层 _draw 里用 y - lift 表达「高」，此处验证 height_at 的符号约定一致：
	# 西高东低 → 西侧 height_at 更大（表示抬升更多）
	if h_west <= h_east:
		_fail("M10 高度符号反了（西应高于东）west=" + str(h_west) + " east=" + str(h_east))
	else:
		_ok("M10 高度符号正确（西高东低）")

	# ---- M11 受光模型常数合法（否则画面会全黑或全白）----
	var lit := TerrainMesh.LIGHT_MAX - TerrainMesh.LIGHT_MIN
	if lit <= 0.0 or TerrainMesh.LIGHT_MIN <= 0.0 or TerrainMesh.LIGHT_MAX > 2.0:
		_fail("M11 受光区间非法 min=" + str(TerrainMesh.LIGHT_MIN) + " max=" + str(TerrainMesh.LIGHT_MAX))
	else:
		_ok("M11 受光区间合法 span=" + str(lit))

	# ---- M12 网格密度合理（顶点数在可接受范围，非爆炸）----
	var cells := gs.x * gs.y
	if cells > 40000:
		_fail("M12 网格过密 cells=" + str(cells))
	else:
		_ok("M12 网格规模可控 cells=" + str(cells))

	# ---- Z1 产出量闸门 ----
	if _checks < expect - 1:
		_fail("Z1 产出量不足 checks=" + str(_checks) + " 期望>=" + str(expect - 1))
	else:
		_ok("Z1 产出量闸门通过 checks=" + str(_checks))

	print("TERRAIN_MESH_CHECKS=" + str(_checks))
	print("TERRAIN_MESH_FAILS=" + str(_fails))
	print("TERRAIN_MESH=" + ("PASS" if _fails == 0 else "FAIL"))
	quit(0 if _fails == 0 else 1)
