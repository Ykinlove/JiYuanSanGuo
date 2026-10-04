# -*- coding: utf-8 -*-
# 【本文件由 _verify_scene_perf.py 自动生成，请勿手改】
#零 autoload 依赖 —— `--headless --script` 不加载 autoload，碰GameState 即编译失败。
extends SceneTree

## ---- 复刻 CityMarkerArt 的静态贴图缓存（判据端另有 A 组源码锚定兜底）----
static var _tex_cache: Dictionary = {}
const _TEX_EXTS: Array[String] = [".png", ".webp", ".jpg"]

## 统计桩：替代真实的 ResourceLoader.exists / load，用来数「磁盘 stat 次数」。
## 【为什么可以替代】我们要验的是**调用次数与缓存语义**，不是真实 IO；
## 用桩才能在headless 里确定性地断言「第二次零 stat」。
static var stat_count: int = 0
static var load_count: int = 0
## 桩的资源表：只有 "hit_city" 有图，其余一律落空（复刻真实项目的100% miss 场景）
static var _FILES: Dictionary = {"hit_city": true}


static func _reset_probe() -> void:
	_tex_cache.clear()
	stat_count = 0
	load_count = 0


static func _stub_exists(path: String) -> bool:
	stat_count += 1
	for k in _FILES.keys():
		if path.ends_with("/" + str(k) + ".png"):
			return true
	return false


## 【修·探针自身缺陷·第一次】初版 return null —— 于是"命中项该返回非 null"
## 与桩自相矛盾，T1c/T2b 必假红（错的不是产品，是桩）。
## 正解：返回一个真的 Texture2D 实例当命中产物。
static func _stub_load(path: String):
	load_count += 1
	return ImageTexture.create_from_image(Image.create(2, 2, false,
			Image.FORMAT_RGBA8))


static func _try_texture(city_id: String):
	if city_id.is_empty():
		return null
	var key := "m:" + city_id
	if _tex_cache.has(key):
		return _tex_cache[key]
	var found = null
	for ext in _TEX_EXTS:
		var path := "res://assets/sprites/map/" + city_id + ext
		if _stub_exists(path):
			found = _stub_load(path)
			break
	_tex_cache[key] = found
	return found


static func _type_texture(city_type: String):
	var t := city_type if not city_type.is_empty() else "city"
	var key := "t:" + t
	if _tex_cache.has(key):
		return _tex_cache[key]
	var path := "res://assets/sprites/city_icons/" + t + ".png"
	var found = null
	if _stub_exists(path):
		found = _stub_load(path)
	_tex_cache[key] = found
	return found


var _fails: Array[String] = []
var _n := 0


func _check(cond: bool, key: String) -> void:
	_n += 1
	if not cond:
		_fails.append(key)
	print("[" + ("PASS" if cond else "FAIL") + "] " + key)


func _init() -> void:
	# ---------- T1 首次调用确实做了磁盘 stat（证明桩在计数，不是空转） ----------
	_reset_probe()
	#【GDScript 坑·本轮又踩】`:=` 不能推断自定义函数的返回值（它返回 Variant）
	var first = _try_texture("hit_city")
	_check(stat_count == 1, "T1a 首次命中恰好 1 次 stat（实测 " + str(stat_count) + "）")
	_check(load_count == 1, "T1b 首次命中恰好 1 次 load（实测 " + str(load_count) + "）")
	_check(first != null, "T1c 命中项返回非 null")

	# ---------- T2 第二次调用零 stat（缓存真的生效） ----------
	var c2 := stat_count
	var l2 := load_count
	var second = _try_texture("hit_city")
	_check(stat_count == c2 and load_count == l2,
			"T2a 同 id 第二次零 IO（stat+load 增量 " + str(stat_count - c2) + "/"
			+ str(load_count - l2) + "）")
	_check(second != null, "T2b 第二次仍返回同一非 null 结果（缓存不吞结果）")

	# ---------- T3 miss 也必须缓存（本项目 100% miss，只缓存命中项等于没优化） ----------
	_reset_probe()
	_try_texture("miss_a")
	var miss_first := stat_count
	_check(miss_first >= 1, "T3a miss 项首次确实 stat 了（实测 " + str(miss_first) + "）")
	var miss2 := stat_count
	_try_texture("miss_a")
	_check(stat_count == miss2,
			"T3b miss 项第二次零 stat —— 负缓存生效（实测 " + str(stat_count - miss2) + "）")

	# ---------- T4 key 前缀分区：city_id 与 city_type 同名不得串味 ----------
	_reset_probe()
	# 「city」既是可能的城 id，也一定是默认 city_type。
	# 【判据方向·血泪】初版写成「id 查询后 stat 增量须 ==0」，把「前缀分区生效」
	# 当成了失败 —— 恰恰相反：分区生效的表现就是**两者的 key 不同、该查还得查**
	# （若增量 0，说明 id 查询复用了type 的缓存项 = 串味了）。
	_type_texture("")
	var type_cached := stat_count
	_try_texture("city")
	var id_delta := stat_count - type_cached
	_check(id_delta > 0,
			"T4a 前缀分区生效：type 查过的 key 不会被 id 查询复用（实测 id 查询增量 "
			+ str(id_delta) + " 次 stat，须 >0；=0 才是串味)")
	_check(_tex_cache.has("t:city"), "T4b 类型 key 落在 t: 分区")
	_check(_tex_cache.has("m:city") and _tex_cache.has("t:city"),
			"T4c id key 与 type key 各自独立落在 m:/t: 分区（实测 m:city=%s, t:city=%s）"
			% [_tex_cache.has("m:city"), _tex_cache.has("t:city")])

	# ---------- T5 110 城规模：缓存后总 stat 数应远小于 110×3 ----------
	_reset_probe()
	for i in range(110):
		_try_texture("city_" + str(i))
	var first_round := stat_count
	for i in range(110):
		_try_texture("city_" + str(i))
	_check(stat_count == first_round,
			"T5a 110 城第二轮零 stat（第一轮 " + str(first_round) + " 次，第二轮增量 "
			+ str(stat_count - first_round) + "）")

	# ---------- T6 空 id 早退，不做无谓 IO ----------
	_reset_probe()
	_try_texture("")
	_check(stat_count == 0, "T6 空 id 直接返回，零 stat（实测 " + str(stat_count) + "）")

	print("PROBE_DONE " + str(_n - _fails.size()) + "/" + str(_n))
	print("SCENE_PERF_PROBE " + ("PASS" if _fails.is_empty() else "FAIL"))
	for f in _fails:
		print("PROBE_FAIL " + str(f))
	quit(0 if _fails.is_empty() else 1)
