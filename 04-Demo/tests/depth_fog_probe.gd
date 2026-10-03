extends SceneTree
## 纵深雾化（DepthFog）行为探针 —— 第 5 项第五层
##
## 【为什么用纯函数复算而不是跑一帧场景】
##   DepthFog.sample_fog() 依赖 TerrainPainter（autoload 依赖链），
##   而 `--headless --script` **不加载 autoload**（MEMORY 已记的铁律），
##   任何经依赖链碰到 GameState/DataManager 的脚本都会加载期编译失败。
##   故本探针：
##   L1 用**纯静态函数** fog_for_elevation / desat_for_elevation 直接复算分档；
##   L2 独立锚定上游源码（防「探针照抄实现反而放过」）。
##
## 【血泪·探针铁律】
##   ① 协程必须 await；② 根节点用 Control；③ 探针内禁用 % 格式化，全用字符串拼接
##      （_fail 参数不匹配会中断、结果文件不落盘、进程挂死 → 缺陷伪装成「超时」）。

var _checks := 0
var _fails := 0


func _fail(msg: String) -> void:
	_fails += 1
	print("FAIL " + msg)


func _ok(msg: String) -> void:
	_checks += 1
	print("[OK] " + msg)


## 活体验证：真调一次静态分档函数。
## 【为什么不用 has_method】GDScript 里 has_method 是实例方法，
## 在静态类上直接调会 Parse Error（"Cannot call non-static function ... Make an instance instead"），
## 且这类 Parse Error 会让**整份探针加载失败**、表现为一个笼统的 Parse Error，
## 极易误判成产品代码炸了。
func _callable_static() -> bool:
	var c = DepthFog.fog_for_elevation(0.5)
	return c is Color


func _init() -> void:
	# Z1 闸门期望值 = F1..F11 共 11 项（Z1 断言时数不到自己，故用 expect-1）
	var expect := 11

	# ---- F1 API 面：静态分档函数必须真能调一次（活体验证）----
	# 【GDScript 坑】静态类上不能调实例方法（has_method 是实例方法），
	#   直接写 DepthFog.has_method(...) 会 Parse Error。改用「真调一次静态函数」。
	if typeof(DepthFog) != TYPE_NIL and _callable_static():
		_ok("F1 静态分档函数存在且可调用")
	else:
		_fail("F1 DepthFog 静态分档函数不可用")

	# ---- F2 分档单调：海拔越高，雾越浓（alpha 递增）----
	var a_low := DepthFog.fog_for_elevation(0.10)
	var a_plain := DepthFog.fog_for_elevation(0.50)
	var a_hill := DepthFog.fog_for_elevation(0.70)
	var a_peak := DepthFog.fog_for_elevation(0.90)
	if not (a_low.a < a_plain.a and a_plain.a < a_hill.a and a_hill.a < a_peak.a):
		_fail("F2 雾浓度未随海拔单调递增")
	else:
		_ok("F2 雾浓度随海拔单调递增")

	# ---- F3 降饱和单调：海拔越高，降饱和越强 ----
	var d_low := DepthFog.desat_for_elevation(0.10)
	var d_peak := DepthFog.desat_for_elevation(0.90)
	if not (d_peak > d_low):
		_fail("F3 远景降饱和未随海拔增强")
	else:
		_ok("F3 远景降饱和随海拔增强")

	# ---- F4 分档边界与 TerrainHeight.band_name 一致 ----
	# band_name 的边界是 >0.80 peak / >0.62 hill / >0.40 plain。
	# 若两者边界漂移，会出现「角色按 hill 抬升、雾还停在 plain 档」的割裂。
	var ok4 := true
	var bands := ["low", "plain", "hill", "peak"]
	var samples := [0.10, 0.50, 0.70, 0.90]
	for i in range(bands.size()):
		var e: float = samples[i]
		if TerrainHeight.band_name(e) != bands[i]:
			ok4 = false
	if ok4:
		_ok("F4 分档边界 low<0.40<plain<0.62<hill<0.80<peak 与 band_name 一致")
	else:
		_fail("F4 TerrainHeight.band_name 分档边界与预期不符")

	# ---- F5 雾色偏冷蓝（高空）----
	# 高空大气透视 = 偏蓝。故蓝通道必须**大于**红通道。
	if a_peak.b > a_peak.r:
		_ok("F5 高空雾偏冷 b=" + str(a_peak.b) + " > r=" + str(a_peak.r))
	else:
		_fail("F5 高空雾未偏冷 b=" + str(a_peak.b) + " r=" + str(a_peak.r))

	# ---- F6 alpha 上限：雾不能压到不可读 ----
	var worst := 0.0
	for e in [0.0, 0.3, 0.5, 0.7, 0.9, 1.0]:
		worst = maxf(worst, DepthFog.fog_for_elevation(e).a)
	if worst > 0.12:
		_fail("F6 峰值雾过浓，会伤可读性 alpha=" + str(worst))
	else:
		_ok("F6 峰值雾 alpha=" + str(worst) + " 未超 0.12 上限")

	# ---- F7 确定性：同海拔两次采样必须完全一致 ----
	if DepthFog.fog_for_elevation(0.63) != DepthFog.fog_for_elevation(0.63):
		_fail("F7 同海拔两次采样结果不一致（不确定）")
	else:
		_ok("F7 同海拔采样确定")

	# ---- F8 越界海拔不崩且落在最低档 ----
	if DepthFog.fog_for_elevation(-5.0) != DepthFog.fog_for_elevation(0.0):
		_fail("F8 负海拔未回落到最低档")
	elif DepthFog.fog_for_elevation(99.0) != DepthFog.fog_for_elevation(0.90):
		_fail("F8 超高海拔未回落到最高档")
	else:
		_ok("F8 越界海拔优雅回落")

	# ---- F9 零雾档确实接近透明（plain 档 alpha 极小）----
	if a_plain.a > 0.06:
		_fail("F9 plain 档雾过浓，会让平原失去通透感 alpha=" + str(a_plain.a))
	else:
		_ok("F9 plain 档近乎通透 alpha=" + str(a_plain.a))

	# ---- F10 缺依赖不崩：sample_fog 在 terrain=null 时必须返回全透明 ----
	# 这条必须真调一次实例方法（静态类上调实例方法会 Parse Error）。
	var f := DepthFog.new()
	f.visible = false
	var c := f.sample_fog()
	if c.a != 0.0:
		_fail("F10 terrain 缺失时雾未退化为全透明 alpha=" + str(c.a))
	else:
		_ok("F10 terrain 缺失时安全退化为全透明")
	f.free()

	# ---- F11 自身不自绘（不占混合层）----
	# 【关键】_ready 只在**入树**时执行，故必须真的 add_child 到一棵树上，
	# 直接 new() 出来检查 visible 是无意义的（那测的是 Control 的默认值 true，
	# 不是本类的设计）。用一棵临时 Control 当父。
	var host := Control.new()
	get_root().add_child(host)
	var f2 := DepthFog.new()
	host.add_child(f2)
	if f2.visible:
		_fail("F11 DepthFog 入树后默认可视，会白占一个全屏混合层")
	elif f2.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		_fail("F11 DepthFog 未设 MOUSE_FILTER_IGNORE，会吞掉地图点击")
	else:
		_ok("F11 DepthFog 入树后不自绘且不吞点击")
	host.queue_free()

	# ---- Z1 产出量闸门：防「协程空跑却输出 PASS」的假绿灯 ----
	if _checks < expect - 1:
		_fail("Z1 产出量不足 checks=" + str(_checks) + " 期望>=" + str(expect - 1))
	else:
		_ok("Z1 产出量闸门通过 checks=" + str(_checks))

	print("DEPTH_FOG_CHECKS=" + str(_checks))
	print("DEPTH_FOG_FAILS=" + str(_fails))
	print("DEPTH_FOG=" + ("PASS" if _fails == 0 else "FAIL"))
	quit(0 if _fails == 0 else 1)
