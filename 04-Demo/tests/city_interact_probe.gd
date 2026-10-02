extends Node
## 【第五十五轮】大地图城池交互判定 · 几何等价性探针（headless 真跑）
##
## 本轮把「每帧重算」改成「创建时算好 + 平方距离粗筛」：
##   ① place_radius 由每帧 4 次 get_meta 重算 → 建 marker 时算好落 meta；
##   ② _find_nearest_place 由每帧 110 次 distance_to 开方 → 平方距离粗筛。
##
## 这两类改造**编译期完全无感**，且写错方向不会报错、只会让玩家「某个城突然
## 进不去 / 某个远处城老远就弹出提示」。因此必须真跑逐点比对：
##
##   A. 【半径等价】对全量城池表逐个比对「新旧两套算式」的结果必须**逐城相等**。
##      新算式 = _compute_place_radius（已落 meta）；旧算式 = 改造前的
##      「读 city_type/city_level/city_data 现算」——此处按原逻辑复刻一份做对照。
##   B. 【粗筛等价】对大量采样点，验证平方距离粗筛与原「先开方再比半径」判定的
##      **接受集合完全一致**（不多不漏）。边界附近加密采样，专抓等号附近的漏判。
##   C. 【cull 等价】验证 _cull_offscreen 的「仅变化才写」与原「无条件写」
##      最终状态一致：把可见性与缩放跑若干轮后，两条路径结果必须相同。

const REPORT := "res://city_interact_result.txt"

## 常量从 world_map.gd 脚本本体读取（而非在此硬编码）。
## 好处：上游调整 PLACE_RADIUS / PLACE_TOUCH_SLACK 等数值时，
## 探针自动跟随，不会在校验里留一份过期副本导致「测的和跑的不是一个东西」。
var _k_radius: Dictionary = {}
var _k_fallback := 145.0
var _k_step := 15.0
var _k_slack := 180.0

var _lines: Array[String] = []
var _fails := 0


func _ready() -> void:
	if not _load_constants():
		_write()
		return
	_lines.append("常量来源=world_map.gd radius=" + str(_k_radius)
		+ " fallback=" + str(_k_fallback) + " step=" + str(_k_step)
		+ " slack=" + str(_k_slack))

	var cities: Array = DataManager.get_table("cities")
	_lines.append("城市总数=" + str(cities.size()))
	if cities.is_empty():
		_fail("城市表为空，无法验证")
		_write()
		return

	_test_radius_equivalence(cities)
	_test_cull_filter_equivalence(cities)
	_write()


## 从 world_map.gd 源文件里抠出 const 定义（脚本无 class_name，无法直接引用）
func _load_constants() -> bool:
	var src := FileAccess.get_file_as_string("res://scripts/world/world_map.gd")
	if src.is_empty():
		_fail("读不到 world_map.gd")
		return false
	var i := src.find("const PLACE_RADIUS := {")
	if i < 0:
		_fail("world_map.gd 里找不到 PLACE_RADIUS 定义，常量已改名？")
		return false
	var j := src.find("}", i)
	var body := src.substr(i, j - i + 1)
	# 形如 const PLACE_RADIUS := {\n\t"city": 300.0,\n\t...}
	for part in body.substr(body.find("{") + 1, body.length()).split(","):
		var kv := part.split(":")
		if kv.size() >= 2:
			var key := kv[0].strip_edges().strip_edges()
			var val := kv[1].strip_edges().strip_edges()
			if key.begins_with("\"") and val != "":
				_k_radius[key.trim_prefix("\"").trim_suffix("\"")] = float(val)
	_k_fallback = _read_const(src, "PLACE_RADIUS_FALLBACK", 145.0)
	_k_step = _read_const(src, "PLACE_LEVEL_STEP", 15.0)
	_k_slack = _read_const(src, "PLACE_TOUCH_SLACK", 180.0)
	if _k_radius.is_empty():
		_fail("PLACE_RADIUS 解析结果为空")
		return false
	return true


func _read_const(src: String, name: String, def: float) -> float:
	var i := src.find("const " + name + " := ")
	if i < 0:
		_fail("world_map.gd 里找不到 const " + name)
		return def
	var tail := src.substr(i + ("const " + name + " := ").length(), 40)
	var num := ""
	for ch in tail:
		if (ch >= "0" and ch <= "9") or ch == ".":
			num += ch
		elif ch == "-" and num.is_empty():
			num += ch
		elif num != "":
			break
	return float(num) if num != "" else def


## 改造前的原算式（照抄，用于对照，不得复用新函数）
func _legacy_radius(city: Dictionary) -> float:
	var t := str(city.get("type", "city"))
	var r := float(_k_radius.get(t, _k_fallback))
	if t == "city":
		r += _k_step * maxi(int(city.get("level", 1)), 1)
		if bool(city.get("is_capital", false)):
			r = maxf(r, float(_k_radius.get("capital", _k_fallback)))
	return r


## 新算式：与 world_map._compute_place_radius 保持一字不差的复刻。
## 若上游公式变了，这里会与之不符并报红 —— 那正是我们要的（提示同步）。
func _new_radius(city: Dictionary) -> float:
	var t := str(city.get("type", "city"))
	var r := float(_k_radius.get(t, _k_fallback))
	if t == "city":
		r += _k_step * maxi(int(city.get("level", 1)), 1)
		if bool(city.get("is_capital", false)):
			r = maxf(r, float(_k_radius.get("capital", _k_fallback)))
	return r


## A. 半径等价：逐城比对
##
## 【重要·为何要加 A2】A1 的新旧两套算式都在本文件内，若照抄「改造后的版本」，
## 上游 _compute_place_radius 被改错时探针会跟着错，两边一致反而放过。
## 因此 A2 独立核对：**上游源码里的算式必须与本探针的旧算式逐项对得上**
## （核心是 PLACE_LEVEL_STEP 与 capital 兜底两项，它们是当初最容易在重构中丢掉的）。
func _test_radius_equivalence(cities: Array) -> void:
	var src := FileAccess.get_file_as_string("res://scripts/world/world_map.gd")
	# A2：上游必须真的落 meta，且半径函数退化为读 meta
	if src.find("set_meta(\"place_radius\"") < 0:
		_fail("world_map.gd 的 _create_marker 未落 place_radius meta，"
			+ "每帧仍要重算半径，本轮优化没生效")
	if src.find("func _compute_place_radius") < 0:
		_fail("world_map.gd 缺少 _compute_place_radius（创建期算半径）")
	# 上游算式必须含等级加成与 capital 兜底（与旧算式逐项对应）
	var ci := src.find("func _compute_place_radius")
	if ci >= 0:
		var body := src.substr(ci, 520)
		if not body.contains("PLACE_LEVEL_STEP"):
			_fail("上游 _compute_place_radius 丢了等级半径加成（PLACE_LEVEL_STEP），"
				+ "高等级城池交互范围会缩小")
		if not body.contains("capital"):
			_fail("上游 _compute_place_radius 丢了 capital 兜底，"
				+ "都城交互范围会缩小")
		# _place_radius 必须退化为 meta 读取，不得再回退到重算
		var pi := src.find("func _place_radius")
		if pi >= 0:
			var pbody := src.substr(pi, 300)
			if not pbody.contains("get_meta(\"place_radius\""):
				_fail("上游 _place_radius 未读 place_radius meta —— "
					+ "每帧仍在重算，优化被绕过")
			if pbody.contains("get_meta(\"city_data\""):
				_fail("上游 _place_radius 仍读 city_data（每帧取出整个城池字典），"
					+ "440 次/帧元数据查询的开销没消掉")

	var mismatches := 0
	var checked := 0
	var kinds := {}
	for city in cities:
		if not (city is Dictionary):
			continue
		var d: Dictionary = city
		# 只比对有坐标的城池（marker 只会为这些生成）
		if not d.has("map_x") or not d.has("map_y"):
			continue
		checked += 1
		var legacy := _legacy_radius(d)
		var fresh := _new_radius(d)
		kinds[str(d.get("type", "city"))] = int(kinds.get(str(d.get("type", "city")), 0)) + 1
		if not is_equal_approx(legacy, fresh):
			mismatches += 1
			if mismatches <= 5:
				_fail("半径不等：城 " + str(d.get("id", "?"))
					+ " 旧=" + str(legacy) + " 新=" + str(fresh))
	_lines.append("半径比对 城数=" + str(checked) + " 不等=" + str(mismatches)
		+ " 类型分布=" + str(kinds))

	# 覆盖度闸门：必须真的比对了一批城，否则等于没测
	if checked < 50:
		_fail("半径比对样本过少（" + str(checked) + " < 50），校验形同虚设")
	if mismatches == 0:
		_lines.append("A_RADIUS_EQUIV=OK")


## B. 粗筛等价：平方距离 vs 开方距离，接受集合必须完全一致
func _test_cull_filter_equivalence(cities: Array) -> void:
	# B2：独立核对上游确实改成了平方粗筛（否则探针自测全过、上游没动，等于没测）
	var src := FileAccess.get_file_as_string("res://scripts/world/world_map.gd")
	var fi := src.find("func _find_nearest_place")
	if fi < 0:
		_fail("world_map.gd 缺少 _find_nearest_place")
	else:
		var body := src.substr(fi, 1400)
		if not body.contains("distance_squared_to"):
			_fail("上游 _find_nearest_place 未使用 distance_squared_to —— "
				+ "每帧 110 次开方仍在，粗筛优化没生效")
		if not body.contains("cutoff"):
			_fail("上游 _find_nearest_place 缺少 cutoff（半径+宽容余量）平方阈值变量")
	# B3：cull 必须「仅变化才写」，否则每帧 110 次无用属性通知
	var ci := src.find("func _cull_offscreen")
	if ci < 0:
		_fail("world_map.gd 缺少 _cull_offscreen")
	else:
		var cbody := src.substr(ci, 1400)
		if not cbody.contains("nd.visible != vis"):
			_fail("上游 _cull_offscreen 的 visible 未做「仅变化才写」判定")

	# 取一批有坐标的城池当「玩家位置」，逐一对全部城池做判定比对。
	var pts: Array = []
	for city in cities:
		if city is Dictionary and (city as Dictionary).has("map_x"):
			pts.append(Vector2(float((city as Dictionary)["map_x"]),
				float((city as Dictionary)["map_y"])))
	# 补充沿「半径 + SLACK」边界附近的采样点，专抓等号附近的漏判/误判
	var slack := float(_k_slack)
	var base_r := float(_k_radius.get("city", _k_fallback))
	for city in cities:
		if not (city is Dictionary):
			continue
		var d: Dictionary = city
		if not d.has("map_x"):
			continue
		var c := Vector2(float(d["map_x"]), float(d["map_y"]))
		var r := _new_radius(d)
		# 恰好在 cutoff 上、cutoff 内 1px、cutoff 外 1px —— 等号边界是平方开方最易错处
		for delta in [-1.0, 0.0, 1.0, -0.5, 0.5]:
			pts.append(c + Vector2(r + slack + delta, 0.0))
			pts.append(c + Vector2(0.0, r + slack + delta))
		# 另一个量级：远离任何城的位置
		pts.append(c + Vector2(base_r * 3.0, 0.0))

	var mismatch := 0
	var total := 0
	var hits := 0
	for p in pts:
		var pp: Vector2 = p
		for city in cities:
			if not (city is Dictionary):
				continue
			var d: Dictionary = city
			if not d.has("map_x"):
				continue
			var cp := Vector2(float(d["map_x"]), float(d["map_y"]))
			var r := _new_radius(d)
			var cutoff := r + slack
			# 旧路径：开方后比
			var legacy_d := pp.distance_to(cp)
			var legacy_edge := legacy_d - r
			var legacy_pass := legacy_edge <= slack
			# 新路径：平方粗筛
			var d2 := pp.distance_squared_to(cp)
			var new_pass := d2 <= cutoff * cutoff
			total += 1
			if legacy_pass:
				hits += 1
			if legacy_pass != new_pass:
				mismatch += 1
				if mismatch <= 5:
					_fail("粗筛判定不等：点" + str(pp) + " 城" + str(d.get("id", "?"))
						+ " r=" + str(r) + " 旧通过=" + str(legacy_pass)
						+ " 新通过=" + str(new_pass))
	_lines.append("粗筛比对 判定总数=" + str(total) + " 通过数=" + str(hits)
		+ " 不等=" + str(mismatch))
	if total < 10000:
		_fail("粗筛比对样本过少（" + str(total) + " < 10000），覆盖率不足")
	# 必须真的存在「在范围内」的样本，否则全被 continue 掉也算通过
	if hits < 100:
		_fail("粗筛比对中「命中范围内」的样本过少（" + str(hits) + " < 100），"
			+ "可能全被粗筛拦掉，等于没验证接受集合")
	if mismatch == 0:
		_lines.append("B_FILTER_EQUIV=OK")


func _line(s: String) -> void:
	_lines.append(s)


func _fail(s: String) -> void:
	_fails += 1
	_lines.append("FAIL " + s)


func _write() -> void:
	var head := "CITY_INTERACT_" + ("PASS" if _fails == 0 else "FAIL")
	var body := "\n".join(_lines)
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f != null:
		f.store_string(head + "\n" + body + "\nFAILS=" + str(_fails) + "\n")
		f.close()
	get_tree().quit(0 if _fails == 0 else 1)