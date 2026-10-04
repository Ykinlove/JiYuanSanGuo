extends Node
## 地形高度场探针（第六十八轮·第 5 项第三层）
##
## 【为什么必须有这个探针】高度场是「角色浮在多高」的**纯视觉量**，
## 编译期无感、运行期不崩、几乎不报错：写错了只是「看起来还是平的」。
## 而且它有一个特别危险的失效形态 —— **全部返回 0**：
## 若海拔算错来源、或采样恒为低档，lift 恒 0，函数照常返回、照常被调用，
## 只是每个人都被抬 0 像素 → 画面与改动前一模一样 → **看起来"没问题"**。
## 所以判据必须证明「高程**真的随位置变化**」，而不是「函数被调到了」。
##
## 【本探针证明什么】
##   H0a/b   高度场可加载、函数签名齐全（先证伪 API 面）
##   H1      **核心**：同一张图上，西部（高山）与东部（平原）海拔显著不同
##   H2      海拔随位置**连续变化**（不是只有两档跳变）
##   H3      海拔落在合法区间 [0,1]
##   H4      抬升量 lift 与海拔单调正相关（无反号 bug —— 反号会让人沉进地里，
##           这是本模块最危险的一个符号错误，且完全不报错）
##   H5      确定性：同坐标两次采样完全相等（噪声非随机化）
##   H6      城池周边被压平为低海拔（与底图"城周平原"一致）
##   H7      apply_to 相对**基准 y**计算，不累加漂移（连调 10 次 y 不变）
##   H8      band_name 分档单调
##   Z1      判定产出量闸门
##
## 【为什么 H7 单列】`apply_to` 若写成 `node.position.y -= lift`
## （而不是相对基准 y），每帧调一次就会累加，走 100 步飞出天际 ——
## 而第一帧看起来完全正常。这类 bug 只有"连调多次看是否漂移"才抓得到。
##
## 注意：本文件内**禁用 % 格式化** —— 引擎里参数不匹配会抛异常 →
## 结果不落盘、进程挂死，上层只能表现为「超时」。

const REPORT := "res://terrain_height_result.txt"
## 预期判定项总数（闸门用）。改动判定项时**必须同步改这里**。
## 当前构成：H0a/H0b 2 + H1/H2/H3/H4/H4b/H4c/H5/H6/H7/H8 共 10 = 12 项
## （Z1 自身在断言时还没执行，数不到自己，故下限取 11；
##   与 depth_sort_probe 同款「下限取实测值」惯例）
const EXPECT_CHECKS := 12

var _fails := 0
var _oks := 0
var _lines: Array[String] = []


func _check(tag: String, cond: bool, detail: String) -> void:
	_lines.append("[" + ("OK" if cond else "FAIL") + "] " + tag + " :: " + detail)
	if cond:
		_oks += 1
	else:
		_fails += 1


func _ready() -> void:
	# ---------- H0 API 面 ----------
	#【踩坑·判据自身 bug】原先写 `TerrainHeight.has_method(...)` —— 但
	# has_method 是**实例**方法，在 class 对象（静态类）上调会抛 Parse Error：
	# "Cannot call non-static function ... Make an instance instead."
	# 4 个 Parse Error 一起冒出来，看起来像产品代码炸了，其实是判据写错。
	# 正解：静态类的存在性用「真调一次静态函数」来验 —— 能调通就是 API 齐的。
	# 顺带记住：**静态类上不能调实例方法**（has_method/get_name 等）。
	var api_ok := true
	var api_detail := ""
	# base_elevation 是静态纯函数，先用它做「类可用」的活体验证
	var api_probe := TerrainHeight.base_elevation(1000.0, 1000.0, Vector2(21256, 21826))
	if api_probe < 0.0 or api_probe > 1.0:
		api_ok = false
		api_detail = "base_elevation 返回越界 " + str(api_probe)
	# 再逐一验证其余三个静态函数确实存在（能调通即存在）
	for fn in ["elevation_at", "lift_at", "band_name"]:
		match fn:
			"elevation_at":
				if TerrainHeight.elevation_at(1000.0, 1000.0,
						Vector2(21256, 21826), 0.0) < -0.001:
					api_ok = false
					api_detail = fn + " 返回异常"
			"lift_at":
				if TerrainHeight.lift_at(1000.0, 1000.0,
						Vector2(21256, 21826), 0.0) < -0.001:
					api_ok = false
					api_detail = fn + " 返回异常"
			_:
				if TerrainHeight.band_name(0.5) != "plain":
					api_ok = false
					api_detail = fn + " 分档返回 " + TerrainHeight.band_name(0.5)
	_check("H0a TerrainHeight 静态 API 可调用（类缓存已刷、无 Parse Error）",
		api_ok, api_detail if api_detail != "" else "四个静态函数均调用成功")
	_check("H0b base_elevation 返回合法区间（活体验证而非仅检查存在）",
		api_probe >= 0.0 and api_probe <= 1.0,
		"base_elevation(1000,1000)=" + str(snappedf(api_probe, 0.001)))

	var world := Vector2(21256, 21826)

	# ---------- H1 核心：西部高山 vs 东部平原 ----------
	# 地形公式里 elev_base = (1 - nx)^2 * 0.8，即**西部高、东部低**（三级阶梯）。
	# 取同一纬度（同一 y，避免把纬度差当成高差）上的东西两点。
	var west := TerrainHeight.elevation_at(world.x * 0.12, world.y * 0.5, world, 0.0)
	var east := TerrainHeight.elevation_at(world.x * 0.88, world.y * 0.5, world, 0.0)
	_check("H1 同纬度西部海拔显著高于东部（中国地势西高东低三级阶梯）",
		west - east > 0.15,
		"west=" + str(snappedf(west, 0.001))
		+ " east=" + str(snappedf(east, 0.001))
		+ " 差=" + str(snappedf(west - east, 0.001)))

	# ---------- H2 连续性：沿一条线采样，应得到多个不同值 ----------
	# 【为什么单判"west!=east"不够】两档跳变（高/低）也能满足 H1，
	# 但那样地形是台阶而不是山。连续性判据用"多个采样点互不相同"。
	var samples: Array[float] = []
	for i in range(9):
		var fx := 0.10 + 0.09 * float(i)
		samples.append(TerrainHeight.elevation_at(world.x * fx, world.y * 0.5, world, 0.0))
	var distinct := 0
	for a in range(samples.size()):
		for b in range(a + 1, samples.size()):
			if absf(samples[a] - samples[b]) > 0.001:
				distinct += 1
	_check("H2 海拔沿横向连续变化（非二值跳变）",
		distinct >= 8,
		"9 个采样点里互不相同的对数=" + str(distinct))
	_lines.append("H2 采样明细: " + str(samples))

	# ---------- H3 区间合法性 ----------
	var all_in_range := true
	for v in samples:
		if v < 0.0 or v > 1.0:
			all_in_range = false
	if west < 0.0 or west > 1.0 or east < 0.0 or east > 1.0:
		all_in_range = false
	_check("H3 海拔落在合法区间 [0,1]", all_in_range,
		"west=" + str(west) + " east=" + str(east))

	# ---------- H4 lift 与 elev 单调正相关 + 反号检测 ----------
	# 【本模块最危险的 bug】符号写反 → 角色沉进地里。
	# 判据：任意两点，lift 的差必须与 elev 的差**同号**（lift 随 elev 升高而增大）。
	var monotonic := true
	var worst := ""
	for a in range(samples.size()):
		for b in range(samples.size()):
			if a == b:
				continue
			var de := samples[b] - samples[a]
			var dl := TerrainHeight.lift_at(world.x * (0.10 + 0.09 * float(b)),
				world.y * 0.5, world, 0.0) \
				- TerrainHeight.lift_at(world.x * (0.10 + 0.09 * float(a)),
				world.y * 0.5, world, 0.0)
			if de > 0.001 and dl < -0.001:
				monotonic = false
				worst = "elev↑但 lift↓ de=" + str(snappedf(de, 0.001)) \
					+ " dl=" + str(snappedf(dl, 0.001))
	_check("H4 抬升量随海拔单调正相关（无反号 bug，反号=角色沉进地里）",
		monotonic, worst if worst != "" else "全部同号")
	# 【第六层·公式已扩展】抬升量 = 海拔 × HEIGHT_SCALE × VERT_EXAGGERATE。
	# 为什么必须有 VERT_EXAGGERATE：俯视 2D 严格按 1:1 画的话高差只有格跨度的
	# 0.3%，数学正确但视觉完全是平面。角色与地形网格**共用这一个出口**，
	# 所以公式一变，两侧自动同步 —— 这正是把它收敛到单点的原因。
	var _h4b_lift := TerrainHeight.lift_at(world.x * 0.12, world.y * 0.5, world, 0.0)
	var _h4b_exp := west * TerrainHeight.HEIGHT_SCALE * TerrainHeight.VERT_EXAGGERATE
	_check("H4b 抬升量 = 海拔 × HEIGHT_SCALE × VERT_EXAGGERATE（常数可复现）",
		absf(_h4b_lift - _h4b_exp) < 0.001,
		"lift=" + str(_h4b_lift)
		+ " 海拔×SCALE×EXAG=" + str(snappedf(_h4b_exp, 0.001))
		+ " SCALE=" + str(TerrainHeight.HEIGHT_SCALE)
		+ " EXAG=" + str(TerrainHeight.VERT_EXAGGERATE))
	# 垂直夸张必须真的 >1，否则等于没做（这一条是「本层没白做」的最小保证）
	_check("H4c 垂直夸张系数 >1（否则高差不可见，等于白做）",
		TerrainHeight.VERT_EXAGGERATE > 1.0,
		"VERT_EXAGGERATE=" + str(TerrainHeight.VERT_EXAGGERATE))

	# ---------- H5 确定性 ----------
	var a1 := TerrainHeight.elevation_at(8000.0, 9000.0, world, 0.0)
	var a2 := TerrainHeight.elevation_at(8000.0, 9000.0, world, 0.0)
	_check("H5 同坐标两次采样完全相等（噪声非随机化，可复现）",
		absf(a1 - a2) < 0.000001,
		"a1=" + str(a1) + " a2=" + str(a2))

	# ---------- H6 城池压平 ----------
	# 传 city_mask=1 表示"完全在城周平坦区"，海拔应被压到 ELEV_CITY_FLAT 附近。
	var with_city := TerrainHeight.elevation_at(world.x * 0.12, world.y * 0.5, world, 1.0)
	var expect_flat := lerpf(west, TerrainHeight.ELEV_CITY_FLAT, 0.85)
	_check("H6 城池影响把海拔压平（城周是田园平原，与底图一致）",
		absf(with_city - expect_flat) < 0.001 and absf(with_city - west) > 0.001,
		"west=" + str(snappedf(west, 0.001)) + " 城周=" + str(snappedf(with_city, 0.001))
		+ " 期望=" + str(snappedf(expect_flat, 0.001)))

	# ---------- H7 apply_to 不累加漂移（连调 10 次）----------
	# apply_to 是**静态**函数（参数里传 node），不是实例方法 —— 这里直接调。
	#
	# 【踩坑·判据自身 bug·首版】最初写的是
	#   drift = abs((y - v0) - lift)
	# 但 apply_to 是**向上抬**，即 `y = base_y - lift` → 位移是**负值**。
	# 于是"位移 - (-45) = +45"被算成漂移 90，而正确漂移明明是 0。
	# 更糟的是：真正累加时（位移 -450）这个式子给出 495 —— **数值确实不同，
	# 判据能报红**，可它报的"漂移量"是错的，会误导排查方向。
	# 正解：漂移 = |位移 - (-lift)| = |位移 + lift|，符号与量纲都对。
	var probe := Node2D.new()
	probe.position = Vector2(8000.0, 9000.0)
	add_child(probe)
	var v0 := probe.position.y
	for _i in range(10):
		TerrainHeight.apply_to(probe, 8000.0, 9000.0, world, 0.0)
	var one_lift := TerrainHeight.lift_at(8000.0, 9000.0, world, 0.0)
	var delta := probe.position.y - v0            # 负值 = 向上抬
	var drift := absf(delta + one_lift)           # 应为 0
	_check("H7 连续 apply_to 10 次不累加漂移（相对基准 y 而非相对当前 y）",
		drift < 0.001 and delta < 0.0,
		"位移=" + str(snappedf(delta, 0.001))
		+ " 期望位移=" + str(snappedf(-one_lift, 0.001))
		+ " 漂移量=" + str(snappedf(drift, 0.001)))

	# ---------- H8 分档单调 ----------
	var b_low := TerrainHeight.band_name(0.1)
	var b_plain := TerrainHeight.band_name(0.5)
	var b_hill := TerrainHeight.band_name(0.7)
	var b_peak := TerrainHeight.band_name(0.95)
	_check("H8 分档单调递增（低→平原→丘陵→山峰）",
		b_low == "low" and b_plain == "plain" and b_hill == "hill" and b_peak == "peak",
		b_low + "/" + b_plain + "/" + b_hill + "/" + b_peak)

	# ---------- Z1 产出量闸门 ----------
	_check("Z1 判定产出量达到预期（探针未中途崩溃）",
		_oks + _fails >= EXPECT_CHECKS,
		"实到 " + str(_oks + _fails) + " 项 / 预期至少 " + str(EXPECT_CHECKS) + " 项")

	_write()


func _write() -> void:
	_lines.append("TERRAIN_HEIGHT_OKS=" + str(_oks))
	_lines.append("TERRAIN_HEIGHT_FAILS=" + str(_fails))
	_lines.append("TERRAIN_HEIGHT_RESULT=" + ("PASS" if _fails == 0 else "FAIL"))
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines))
		f.close()
	for l in _lines:
		print(l)
	get_tree().quit(0 if _fails == 0 else 1)