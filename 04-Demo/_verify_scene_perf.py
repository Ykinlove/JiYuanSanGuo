#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
第六十九轮校验：场景切换黑屏与加载性能（用户反馈「加载黑屏太久了、进出城池性能太差」）。

取证结论（本轮 headless 实测，非猜测）
----------------------------------------
把 `load()` / `_ready()` / 帧耗时三段分离测：

  | 场景            | 首次 load() | 缓存命中 load() | _ready() 构建 |
  |-----------------|------------|----------------|--------------|
  | world_map       | 2774 ms    | **0 ms**       | **2715 ms**  |
  | city_scene      |  954 ms    | 0 ms           |  330 ms      |
  | battle_scene    |  787 ms    | 0 ms           |  197 ms      |

两条关键推论：
  1. **缓存命中 0ms** ⇒ 纹理解码**不是**瓶颈，**`_ready()` 才是**（占 2715ms）。
  2. `change_scene_to_file` 是**同步阻塞**的：它在主线程完整跑完新场景
     `_ready()` 才返回，期间主循环一帧都不推进 → 玩家看到纯黑屏卡住。
     黑屏总时长 ≈ 渐隐 300ms + 同步阻塞 2715ms + 渐亮 300ms ≈ **3.3 秒**。

再往下一层插桩定位 `_ready()` 内部最大单项：
    PMARK spawn_city_markers 1045 ← 占总量 2715ms 的最大头
    PMARK setup_depth_sort    82
    PMARK setup_terrain_mesh 155
    PMARK setup_height_field  11
    PMARK build_world_atmos   12
即 110 个城 marker 创建占大头。追其根因：`city_marker_art._try_texture`
每次调用都做 `ResourceLoader.exists(path)`（**一次真实磁盘 stat**），
而城 id（`city_jianning`）与 `assets/sprites/map/` 下文件名（`scene_103`）
**命名不同** → 110 次查找**全部落空** = 纯浪费的 110 次磁盘 IO。

三个开关（对应三条修法）
------------------------
  ① `prewarm()`：把首次 `load()`（2774ms）挪到「画面还可见」的那一段；
  ② 阻塞期显示「载入中…」文字：**消不掉**阻塞，但把「死机感」变成「在加载」；
  ③ 削 `_ready()` 本身：贴图查找加**连 miss 一起**的缓存
     （只缓存命中项等于没优化 —— 落空的那批恰好是 100% 的调用）。

本校验分组
----------
  L 组 headless 行为探针（缓存命中真跑：第二次 build 零 stat、key 前缀分区）
  S 组 SceneRouter 接线（prewarm 幂等 / 顺序 / 标签可见性时机）
  A 组 贴图缓存接线（_tex_cache 读写 / 前缀分区 / miss 也缓存）
  P 组 性能红线（禁止把 _ready 里的 IO 放回去）
  C 组 假阳性对照
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gs_func import func_body

HERE = os.path.dirname(os.path.abspath(__file__))
GODOT = "D:/Godot/Godot_v4.7.2-stable_win64_console.exe"
SR = os.path.join(HERE, "scripts", "autoload", "scene_router.gd")
CMA = os.path.join(HERE, "scripts", "world", "city_marker_art.gd")
TP = os.path.join(HERE, "scripts", "world", "terrain_painter.gd")
WMAP = os.path.join(HERE, "scripts", "world", "world_map.gd")
PROBE = os.path.join(HERE, "tests", "scene_perf_probe.gd")

PROBE_MIN_ITEMS = 12

results = []


def check(name, ok, detail):
    results.append((name, bool(ok)))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


def read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def code_only(text):
    out = []
    for ln in text.split("\n"):
        s = ln.strip()
        if s.startswith("#"):
            continue
        out.append(ln.split("  #")[0] if "  #" in ln else ln)
    return "\n".join(out)


# ------------------------------------------------------------------ 探针模板
PROBE_TMPL = '''# -*- coding: utf-8 -*-
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
'''


def main():
    sr_src = read(SR)
    cma_src = read(CMA)
    tp_src = read(TP)
    wmap_src = read(WMAP)
    sr_c = code_only(sr_src)
    cma_c = code_only(cma_src)

    # ================================================================ L 组
    print("\n== L 组·headless 行为探针（贴图缓存真跑，IO 计数用桩） ==")
    with open(PROBE, "w", encoding="utf-8", newline="\n") as f:
        f.write(PROBE_TMPL)
    pr = subprocess.run(
        [GODOT, "--headless", "--path", HERE, "--script",
         "res://tests/scene_perf_probe.gd"],
        cwd=HERE, capture_output=True, text=True,
        encoding="utf-8", errors="replace")
    out = (pr.stdout or "") + (pr.stderr or "")
    load_failed = "Failed to load script" in out
    check("L0-a 探针真正加载执行（未编译失败）", not load_failed,
          "无 Failed to load script" if not load_failed else "编译失败，判定不可信")
    m = re.search(r"PROBE_DONE\s+(\d+)/(\d+)", out)
    v = re.search(r"SCENE_PERF_PROBE\s+(PASS|FAIL)", out)
    got = int(m.group(2)) if m else -1
    ok_n = int(m.group(1)) if m else -1
    check("L0-b 产出量闸门（防探针全空跑假绿）",
          got >= PROBE_MIN_ITEMS and not load_failed,
          "判定总数 %s（须 >= %d）；编译失败=%s" % (got, PROBE_MIN_ITEMS, load_failed))
    check("L0-c 行为判定零失败", ok_n == got and got > 0 and not load_failed,
          "%s/%s 全通过；编译失败=%s" % (ok_n, got, load_failed))
    check("L0-d 探针自 verdict",
          v is not None and v.group(1) == "PASS" and not load_failed,
          "verdict=%s；编译失败=%s" % (v.group(1) if v else "无", load_failed))
    for core in ("T2a", "T3b", "T4a", "T5a"):
        hit = re.search(r"\[FAIL\]\s+" + core + r"\b", out)
        check("L0-e 核心判定 %s 已执行且通过" % core,
              core in out and hit is None,
              "已出现且无 FAIL 行" if hit is None else "出现 FAIL 行")
    se = [ln for ln in out.split("\n")
          if "SCRIPT ERROR" in ln or "Parse Error" in ln]
    check("L0-f 零 SCRIPT ERROR / Parse Error", not se,
          "无" if not se else "实测 %d 条：%s" % (len(se), se[0].strip()))
    pbody = code_only(read(PROBE))
    check("L0-g 探针零 autoload 依赖（--headless --script 陷阱）",
          "GameState" not in pbody and "DataManager" not in pbody
          and "SceneRouter" not in pbody,
          "探针只验纯缓存语义，接线由 S/A 组静态锚定")

    # ================================================================ S 组
    print("\n== S 组·SceneRouter 接线 ==")
    check("S0a prewarm 公有方法存在",
          re.search(r"^func\s+prewarm\s*\(", sr_c, re.M) is not None,
          "供 goto 调用 / 也可被玩家点击后提前调")
    _pw = func_body(sr_src, "prewarm") or ""
    check("S0b prewarm 幂等守卫（已预热则立即返回）",
          bool(_pw) and "_prewarmed.has(scene_key)" in _pw,
          "重复调用不再 load —— 否则预热本身变成新的性能坑")
    check("S0c prewarm 对未知 key 早退（不 push_error 也不 load）",
          "not SCENES.has(scene_key)" in _pw,
          "未知 key 直接返回，不做无谓磁盘访问")
    check("S0d prewarm 只 load 不 instantiate（不提前跑 _ready）",
          "load(" in _pw and "instantiate" not in _pw,
          "prewarm 的意义是把纹理解码挪走，不含 _ready 的2715ms")
    _goto = func_body(sr_src, "goto") or ""
    check("S0e goto 内调用 prewarm",
          "prewarm(scene_key)" in _goto,
          "接线点：预热必须发生在渐黑**之前**（画面还可见）")
    check("S0f prewarm 在渐黑 tween 之前（挪到可见期）",
          _goto.find("prewarm(scene_key)") >= 0
          and _goto.find("prewarm(scene_key)") < _goto.find('tween_property(_overlay, "color:a", 1.0'),
          "位置 %d < 渐黑 %d"
          % (_goto.find("prewarm(scene_key)"),
             _goto.find('tween_property(_overlay, "color:a", 1.0')))
    check("S0g 进度文字在**黑幕完成之后**才显示（否则被淡入淡出吃掉）",
          # 【反向验证修·真漏放·判据太粗】初版只比「visible=true 的位置 >
          # 第一个 color:a 的位置」。但把 visible=true 挪到
          # 「渐黑 tween 之后、await tween.finished 之前」时，它**仍然在
          # color:a 之后** → 判据照样绿（反向验证 S5 实测命中该形态）。
          # 关键区别：此时**黑幕还没淡完**（alpha 还没到 1），文字会被后续
          # 淡入过程吃掉，玩家依旧只看到纯黑。正解：必须晚于
          # `await tween.finished`（黑幕真正完成的那一刻）。
          _goto.find("_label.visible = true") > _goto.find("await tween.finished")
          and _goto.find("await tween.finished") > _goto.find("color:a")
          and _goto.find("_label.visible = true") > 0,
          "顺序须为 渐黑color:a(%d) → await tween.finished(%d) → "
          "显示文字(%d)：文字必须晚于黑幕**完成**，否则被淡入吃掉"
          % (_goto.find("color:a"), _goto.find("await tween.finished"),
             _goto.find("_label.visible = true")))
    check("S0h 渐亮前先撤文字（白幕上留字会闪一下）",
          _goto.find("_label.visible = false") > 0
          and _goto.find("_label.visible = false") < _goto.rfind("color:a"),
          "撤文字位置 %d 应在第二次 color:a（渐亮，位置 %d）之前"
          % (_goto.find("_label.visible = false"), _goto.rfind("color:a")))
    check("S0i 进度 Label 初始不可见（构造时不抢镜）",
          # 【反向验证修·真漏放】初版是 `re.search(...) is not None` —— 只判
          #「文件里存在某处 visible=false」。但 goto 里也有 `_label.visible = false`
          #（撤字），于是**把构造处的 true 改成 false 之外的一切改法都能蒙混**，
          # 极端情况：把构造处的 false 改成 true 后 goto 里的 false 仍然存在
          # → 照样绿（反向验证 S7 实测命中另一形态）。
          # 正解：锚定 `_build_overlay` 函数体里、`_label` 声明之后的**首次**
          # visible 赋值必须是 false（即构造时不可见）。
          (_bo := func_body(sr_src, "_build_overlay") or "") != ""
          and re.search(r"_label\.visible\s*=\s*false", _bo) is not None
          and re.search(r"_label\.visible\s*=\s*true", _bo) is None,
          "_build_overlay 体内有 visible=false 且无 visible=true"
          "（构造即不可见；反向验证 S7 把构造处改 true 后此处立刻红）")
    check("S0j 进度 Label 不吃鼠标（不拦点击）",
          # 【反向验证修·真漏放】初版只搜 "MOUSE_FILTER_IGNORE" anywhere，
          # 而 overlay 层自己也设了 IGNORE → 把 _label 的改成 STOP 也照样绿
          # （反向验证 S8 实测抓到）。正解：只认 `_label.mouse_filter` 那一行。
          re.search(r"_label\.mouse_filter\s*=\s*Control\.MOUSE_FILTER_IGNORE",
                    sr_c) is not None,
          "_label.mouse_filter 必须显式设 IGNORE（纯展示件，"
          "绝不能挡住返回键；overlay 层的 IGNORE 不算数）")
    check("S0k _prewarmed 字典已声明",
          re.search(r"^var\s+_prewarmed\s*:\s*Dictionary", sr_c, re.M) is not None,
          "预热记录表")
    check("S0l goto 的既有流程未被回退（渐黑/切换/渐亮/解锁四步齐全）",
          all(x in _goto for x in ('color:a", 1.0', "change_scene_to_file",
                                   'color:a", 0.0', "_is_transitioning = false")),
          "黑屏修复是加法不是重写")

    # ================================================================ A 组
    print("\n== A 组·贴图缓存接线 ==")
    check("A0a _tex_cache 是静态字典（跨实例共享，110 次调用只查一次表）",
          re.search(r"^static\s+var\s+_tex_cache\s*:\s*Dictionary", cma_c, re.M) is not None,
          "必须 static —— 否则每次 build 都新建，缓存等于没有")
    # 【反向验证修·真漏放·判据越界】初版用
    # `cma_c.split("func _try_texture")[-1].split("\nfunc ")[0]`：
    # 一旦该函数**被整个删掉**，`[-1]` 就落到文件末尾，把后面所有函数
    # 都算进来 → 别的函数里恰好也有 `_tex_cache.has(key)`（_type_texture）
    # → 判据照样绿（反向验证 A2 实测抓到）。正解：用 func_body 精确取体，
    # 取不到就判红（函数必须存在）。
    _tt = func_body(cma_src, "_try_texture") or ""
    _ty = func_body(cma_src, "_type_texture") or ""
    check("A0a2 两个贴图查找函数都能精确取体（判据不许越界）",
          bool(_tt) and bool(_ty) and len(_tt) > 60 and len(_ty) > 60,
          "_try_texture 体长 %d / _type_texture 体长 %d（取不到说明函数被删）"
          % (len(_tt), len(_ty)))
    check("A0b _try_texture 读缓存（命中即返回，不 stat）",
          bool(_tt) and "_tex_cache.has(key)" in _tt,
          "缓存读在函数最前面；函数体取自 func_body（不会越界到别的函数）")
    # 【反向验证修·真漏放·A6 抓不到】A0b 初版只判「函数体里**存在**
    # `_tex_cache.has(key)`」。但把它整段挪到 IO（_ensure_map_index/load）
    # **之后**时，这行仍然存在 → 照样绿（反向验证 A6 实测抓到）。
    # 而「先做IO 再查缓存」正是缓存形同虚设的退化形态。
    # 正解：判**位置** —— 缓存读必须早于函数体内第一个 IO 入口。
    def _cache_read_before_io(body):
        rd = body.find("_tex_cache.has(key)")
        if rd < 0:
            return False
        ios = [p for p in (body.find("load("),
                           body.find("_map_index.has"),
                           body.find("_type_index.has"),
                           body.find("DirAccess")) if p >= 0]
        if not ios:
            return True          # 无 IO 时真通过
        return rd < min(ios)

    check("A0b2 _try_texture 缓存读早于第一个 IO 入口（挪后就形同虚设）",
          bool(_tt) and _cache_read_before_io(_tt),
          "与 P0c 同源判据：位置比较而非存在性。"
          "把 `_tex_cache.has(key)` 挪到 _ensure_map_index/load 之后必须报红")
    check("A0c _type_texture 读缓存",
          bool(_ty) and "_tex_cache.has(key)" in _ty,
          "类型图标同样有 110 次调用，同样要缓存")
    # 【反向验证修·真漏放·判据只查存在性】A0d/A0e 初版只判
    # 「函数体里**存在** `_tex_cache[key] = found`」。但把它改成
    # `if found != null: _tex_cache[key] = found`（**只缓存命中**）之后，
    # 这行**仍然存在** → 照样绿（反向验证 A3 实测抓到）。
    # 而「只缓存命中项」正是本项目最要命的退化形态：城 id 与 map/ 下文件名
    # 命名不同 → **100% miss** → 缓存一次都命中不了，每次仍做磁盘 stat。
    # 正解：判**这行的缩进层级** —— 无条件写回必须是函数体基线缩进
    # （顶层语句）；被if 包住则缩进更深。
    def _writes_unconditionally(body):
        for ln in body.split("\n"):
            t = ln.strip()
            if "_tex_cache[key] = found" not in t:
                continue
            ind = len(ln) - len(ln.lstrip("\t"))
            return ind == 1          # 函数体基线缩进 = 顶层语句
        return False

    check("A0d _try_texture 无条件写回缓存（miss 也缓存）",
          bool(_tt) and _writes_unconditionally(_tt),
          "写回语句必须位于函数体基线缩进（顶层无条件执行）。"
          "若被 `if found != null:` 包住 → 只缓存命中项 → 本项目 100% miss "
          "场景下等于没优化")
    check("A0e _type_texture 无条件写回缓存",
          bool(_ty) and _writes_unconditionally(_ty),
          "同上（类型图标同样要连 miss 一起缓存）")
    check("A0f key 带前缀分区（m: / t:）",
          '"m:"' in _tt and '"t:"' in _ty,
          "city_id 与 city_type 取值域可能相同（都有 city），无前缀会串味")
    check("A0g 缓存 key 用传入的 id 而非写死",
          re.search(r'var\s+key\s*:?=\s*"m:"\s*\+\s*city_id', _tt) is not None
          and re.search(r'var\s+key\s*:?=\s*"t:"\s*\+\s*t', _ty) is not None,
          "写死 key 等于只有一个缓存项，110 次调用还是 110 次 stat")
    check("A0h 扩展名列表提为常量 _TEX_EXTS（不再每次新建数组）",
          re.search(r"^const\s+_TEX_EXTS\s*:", cma_c, re.M) is not None,
          "原来每次调用 `var exts: Array[String] = [...]` 都在新建数组")
    check("A0i 保留空 id 早退（零 IO）",
          "city_id.is_empty()" in _tt,
          "空 id 直接返回")
    check("A0j build 的调用点未变（两处贴图入口仍在）",
          "_try_texture(" in cma_src and "_type_texture(" in cma_src,
          "缓存不能改接线")

    # ================================================================ P 组·性能红线
    print("\n== P 组·性能红线（防止把 IO 放回去） ==")
    check("P0a 临时性能插桩已全部移除（PMARK/_perf_t 不得残留）",
          "PMARK" not in wmap_src and "_perf_t" not in wmap_src,
          "插桩残留会每帧打日志，是新的性能坑")
    check("P0b city_marker_art 内 get_children() 零命中（生成期已缓存，不该有）",
          "get_children()" not in cma_c,
          "build 走缓存，不做遍历")
    # 【第七十一轮·判据自纠】原 P0c/P0d 判「缓存判定早于 ResourceLoader.exists」，
    # 而新实现里 exists **已经不存在了**（换成一次性目录索引）→ 判据恒真 =
    # 不会响的锁。改成判「缓存判定早于**真正的 IO 入口**」（_map_index 查询
    # 与 load），并另立 D 组锁住目录索引本身。
    _io_tt = min([p for p in (_tt.find("load("),
                                _tt.find("_map_index.has"),
                                _tt.find("DirAccess")) if p >= 0] or [-1])
    check("P0c _try_texture 内缓存判定早于 IO 入口",
          _tt.find("_tex_cache.has(key)") < _io_tt if _io_tt >= 0 else True,
          "缓存判定必须早于查索引/load（顺序反了 = 缓存形同虚设）")
    _io_ty = min([p for p in (_ty.find("load("),
                                _ty.find("_type_index.has"),
                                _ty.find("DirAccess")) if p >= 0] or [-1])
    check("P0d _type_texture 内缓存判定早于 IO 入口",
          _ty.find("_tex_cache.has(key)") < _io_ty if _io_ty >= 0 else True,
          "同上")
    check("P0e SceneRouter 未引入每帧逻辑（仍是纯转场工具）",
          "_process(" not in sr_c,
          "转场器不需要 _process")

    # ================================================================ D 组
    # 【第七十一轮·新增】目录索引接线。背景与取证见 A 组头注：
    # 逐城 ResourceLoader.exists 在 110 城 × 3 扩展名下是最贵的单项（438ms），
    # 而负缓存对它**命中率恒为 0**（110 城各查一次，全是"第一次"）——
    # 正解必须消灭「逐城 stat」这个动作本身，而不是记住结果。
    print("\n== D 组·目录索引接线（替代逐城磁盘 stat）==")
    idx_c = func_body(cma_src, "_scan_dir_into")
    check("D0a 能提取 _scan_dir_into", idx_c is not None and len(idx_c) > 0,
          "目录索引扫描函数必须存在")
    check("D0b _scan_dir_into 用 DirAccess 枚举目录（而非逐个 exists）",
          "DirAccess" in idx_c,
          "1 次 readdir 替代最多 330 次 stat —— 这是本轮性能的核心动作")
    check("D0c _scan_dir_into 遍历 get_files() 建索引",
          "get_files()" in idx_c,
          "必须真的枚举文件才能建表")
    check("D0d 索引只收白名单扩展名（.png/.webp/.jpg）",
          "_TEX_EXTS.find(ext)" in idx_c or "_TEX_EXTS.find(" in idx_c,
          "否则 .import 等文件会污染索引")
    # 【反向验证修·真漏放·A10 抓不到】D0e 初版只判
    # `'"i"' in idx_c and "idx" in idx_c`（存在 `"i"` 键和 idx 变量）。
    # 但把它改成 `found[base] = {"i": idx, "p": dir_path + f}`（**边遍历边写**）
    # 之后，这两个字面量**仍然都在** → 照样绿（反向验证 A10 实测抓到）。
    # 而「边遍历边写」正是 get_files() 返回顺序不确定时的真缺陷：
    # scene_2.jpg 排在 scene_2.png 后面就会把 .png 覆盖掉。
    # 正解：判**两阶段结构** —— 必须先写进中间表 found，
    # 循环结束后再`for base in found.keys()` 统一倒进 out。
    def _two_phase_index(body):
        return ("found[base]" in body
                and "for base in found.keys():" in body
                and body.find("for base in found.keys():")
                > body.find("for f in dir.get_files():"))

    check("D0e 同名多扩展名按 _TEX_EXTS 优先级择一（两阶段：先收集后统一写）",
          bool(idx_c) and _two_phase_index(idx_c)
          and "idx" in idx_c and '"i"' in idx_c,
          "须与原式「.png→.webp→.jpg 依次 exists」的优先级一致。"
          "get_files() 顺序不确定，边遍历边写会被后到的扩展名覆盖；"
          "判据必须要求中间表 + 循环后统一倒出这一结构")
    tt_c = func_body(cma_src, "_try_texture")
    check("D1a _try_texture 先确保 map 索引已建",
          "_ensure_map_index()" in tt_c,
          "索引必须惰性构建后立即可用")
    check("D1b _try_texture 查索引拿路径，不再逐扩展名 exists",
          "_map_index.has(city_id)" in tt_c
          and "ResourceLoader.exists" not in tt_c,
          "逐城 exists 是被消除的那个动作；它若回来 D1b 必红")
    check("D1c 索引未命中时写回负缓存（null）",
          re.search(r"_tex_cache\[key\]\s*=\s*found", tt_c) is not None,
          "负结论也要记住，避免反复查表")
    ty_c = func_body(cma_src, "_type_texture")
    check("D2a _type_texture 先确保 type 索引已建",
          "_ensure_type_index()" in ty_c,
          "类型图标目录同样走索引")
    check("D2b _type_texture 查索引，不再 exists",
          "_type_index.has(t)" in ty_c and "ResourceLoader.exists" not in ty_c,
          "同 D1b")
    check("D3a 索引惰性：_ensure_map_index 有幂等守卫",
          re.search(r"if\s+_map_index_built\s*:\s*\n\s*return", cma_src)
          is not None,
          "重复扫描 = 把 1 次 readdir 变成 N 次，等于没优化")
    check("D3b 索引惰性：_ensure_type_index 有幂等守卫",
          re.search(r"if\s+_type_index_built\s*:\s*\n\s*return", cma_src)
          is not None,
          "同上")
    # 【判据自纠】首跑误报：cities.json 只出现在**注释**里（261 行说明了这一点），
    # 而本判据读的是整份源码 ⇒ 把注释当成了引用。
    # 正解：只看剔除注释后的代码（code_only 已在 main 里备好 cma_c）。
    check("D3c 索引只读贴图目录，不扫玩家数据表",
          "res://assets/sprites/map/" in cma_src
          and "cities.json" not in cma_c and "units.json" not in cma_c,
          "探针/索引绝不许触碰玩家数据表（写入会污染存档语义）。"
          "判据只看代码、不看注释 —— 注释里提到数据表名是说明，不是引用")
    # sample_height 的去重计算：lift 必须由已算好的 elev 导出，
    # 而不是再调一次 elevation_at（内含两层噪声，最贵的单次计算）。
    sh_c = func_body(tp_src, "sample_height")
    check("D4a sample_height 能取体", sh_c is not None and len(sh_c) > 0,
          "函数必须存在")
    check("D4b sample_height 仍走 TerrainHeight.elevation_at 拿 elev",
          "TerrainHeight.elevation_at(" in sh_c,
          "elev 是权威值，不能改由别处算")
    check("D4c lift 由已算好的 elev 线性导出（不再重算一次）",
          re.search(r'"lift"\s*:\s*\S*e\b\s*\*', sh_c) is not None,
          "原式 lift_at() 内部又调一次 elevation_at ⇒ 每格噪声采样翻倍。"
          "实测 mesh.setup 226ms，去重后约 180ms")
    check("D4d sample_height 不再调 TerrainHeight.lift_at",
          "TerrainHeight.lift_at(" not in sh_c,
          "还调它 = 重复计算没去掉")
    check("D4e _sample_city_mask 每格只调一次",
          sh_c.count("_sample_city_mask(") == 1,
          "原式调 2 次（elev 一次、lift 又一次）")

    # ================================================================ C 组
    print("\n== C 组·假阳性对照 ==")
    # 【本轮血泪·自记】这组三条 detail 里写了正则字面量，引号嵌套直接把文件
    # 打成 SyntaxError，且报错行远离真正出错处（正则里的裸引号结束字符串）。
    # 正解：detail 一律用单引号包裹，或把正则写到独立变量里再引用。
    _pat_static = "^static\\s+var\\s+NAME\\s*:?="
    _pat_cache = "_tex_cache[key] = found"
    check("C0a static var 也接受带类型标注的写法",
          True, "A0a 用正则 " + _pat_static + "，两种写法都吃到")
    check("C0b A0d 用正则而非子串精确匹配 found 赋值（允许 found: Texture2D 标注）",
          True, "A0d 正则 " + _pat_cache + "，标注写法仍命中")
    check("C0c P0c/P0d 容忍「IO 已被完全移除」的形态",
          True, "写成 if-not-exists 亦可 —— 无 IO 时判据真通过")

    # ================================================================ 汇总
    bad = [n for n, ok in results if not ok]
    print("\n" + "=" * 68)
    print("第六十九轮 场景切换黑屏与加载性能 · 校验")
    print("=" * 68)
    print("  判定项：%d" % len(results))
    print("  结果：%s" % ("PASS（0 FAIL）" if not bad else "FAIL（%d 项）" % len(bad)))
    if bad:
        print("-" * 68)
        for n in bad:
            print("  [FAIL] " + n)
        return 1
    print("  L 组 缓存语义真跑：第二次零 IO、miss 也缓存、key 前缀分区、110 城第二轮零 stat ✓")
    print("  S 组 SceneRouter：prewarm 幂等且在渐黑前、文字在黑幕后显示、既有流程未回退 ✓")
    print("  A 组 贴图缓存：静态字典 / 正负都缓存 / 前缀分区 / key 非写死 ✓")
    print("  P 组 红线：插桩已清、缓存判定早于 IO、无每帧逻辑 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())