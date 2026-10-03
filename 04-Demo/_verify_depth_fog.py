# -*- coding: utf-8 -*-
"""纵深雾化（DepthFog，第 5 项第五层）校验器。

三层校验：
  L1 headless 探针 12 项（分档单调性 / 边界与 TerrainHeight 一致 / 缺依赖退化 /
     不自绘不吞点击 / 产出量闸门）
  L3 独立源码锚定（防「探针与产品代码同改互相放过」——MEMORY 已记的教训：
     探针照抄改造后版本，则上游改错反而放过）
"""
import io
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
GODOT = "D:/Godot/Godot_v4.7.2-stable_win64_console.exe"

FOG = os.path.join(ROOT, "scripts", "world", "depth_fog.gd")
TINT = os.path.join(ROOT, "scripts", "world", "day_night_tint.gd")
WMAP = os.path.join(ROOT, "scripts", "world", "world_map.gd")
TH = os.path.join(ROOT, "scripts", "world", "terrain_height.gd")
PROBE = os.path.join(ROOT, "tests", "depth_fog_probe.gd")

summary = []


def ck(cond, msg):
    summary.append((bool(cond), msg))
    print(("  [OK] " if cond else "  [FAIL] ") + msg)


def read(p):
    return io.open(p, encoding="utf-8").read()


def func_body(src, name):
    """提取函数体：先按括号配平吃掉完整签名（**可跨行**），再按缩进定界取体。

    【参数两种历史形态都要支持】（本轮统一时踩过：只认裸名会让 9 个
     用「完整签名片段」调用的校验器集体返回 None → 假红）
      · 裸名：      "_process"
      · 带 func 前缀："func add_legs("
      · 带参数字面： "func _process(delta"
    统一规约为：去掉 "func " 前缀 → 取首个 "(" 之前的部分 → 即函数名。

    【血泪·五次踩坑的最终形态，勿再简化】
      1) 只按 {}/} 配对 → 遇 `var x: Dictionary = {}` 立刻 depth 归零 → 体被截成几十字符
      2) 加字符串跳过后被单引号 'Hint' 搞乱状态
      3) 正则只写 ^func → 匹配不到 `static func` → 判据集体假红
      4) 按「第一个换行」当签名结束 → 截到的是签名续行（缩进更深）→ 真体缩进更小 → 立即 break
      5) **基线缩进取错行**：拿「签名后第一行代码」当基线，而该行通常是 `if`（1 tab），
         体里同级的 `if`/`var`（也是 1 tab）会被判成「函数结束」→ 体被截断 → 判据假红。
         正解：基线 = **函数签名行自身的缩进**（顶层函数恒为 0）。
    """
    fname = name.strip()
    if fname.startswith("func "):
        fname = fname[5:]
    fname = fname.split("(")[0].strip()
    if not fname:
        return None
    m = re.search(r"^(?:static\s+)?func\s+%s\s*\(" % re.escape(fname), src, re.M)
    if not m:
        return None
    i = src.find("(", m.start())
    depth = 0
    j = i
    while j < len(src):
        if src[j] == "(":
            depth += 1
        elif src[j] == ")":
            depth -= 1
            if depth == 0:
                break
        j += 1
    sig_line_start = src.rfind("\n", 0, m.start()) + 1
    head = src[sig_line_start:m.start()]
    baseline = len(head) - len(head.lstrip("\t"))
    k = src.find("\n", j)
    lines = src[k + 1:].split("\n")
    out = []
    for ln in lines:
        s = ln.strip()
        if s == "":
            out.append(ln)
            continue
        ind = len(ln) - len(ln.lstrip("\t"))
        if ind <= baseline:
            break
        out.append(ln)
    return "\n".join(out)

print("=" * 70)
print("纵深雾化（第 5 项第五层）校验")
print("=" * 70)

# ============================ L1 headless 探针 ============================
print("\n[L1] headless 行为探针")
if not os.path.exists(PROBE):
    ck(False, "探针缺失 tests/depth_fog_probe.gd")
else:
    p = subprocess.run(
        [GODOT, "--headless", "--path", ROOT, "--script", "res://tests/depth_fog_probe.gd"],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = (p.stdout or "") + (p.stderr or "")
    m = re.search(r"DEPTH_FOG_CHECKS=(\d+)", out)
    f = re.search(r"DEPTH_FOG_FAILS=(\d+)", out)
    verdict = re.search(r"DEPTH_FOG=(PASS|FAIL)", out)
    ck(m is not None and int(m.group(1)) >= 12,
       "L1-a 产出量闸门 checks=%s（须>=12，防协程空跑假绿灯）" % (m.group(1) if m else "?"))
    ck(f is not None and int(f.group(1)) == 0,
       "L1-b 行为判定零失败 fails=%s" % (f.group(1) if f else "?"))
    ck(verdict is not None and verdict.group(1) == "PASS",
       "L1-c 探针自 verdict=%s" % (verdict.group(1) if verdict else "?"))
    ck("DEPTH_FOG_FAILS=0" in out and "FAIL F" not in out,
       "L1-d 无逐项 FAIL 输出")

# ============================ L3 独立源码锚定 ============================
print("\n[L3] 独立源码锚定（防探针与产品同改互相放过）")
for p_ in (FOG, TINT, WMAP, TH):
    if not os.path.exists(p_):
        ck(False, "源文件缺失 " + p_)
ck(all(os.path.exists(p_) for p_ in (FOG, TINT, WMAP, TH)),
   "L3-0 四个源文件齐备")

fog_src = read(FOG)
tint_src = read(TINT)
wmap_src = read(WMAP)

# F1 类名与基类（正则锁行尾，防 TerrainHeightXXX 之类子串骗过）
ck(re.search(r"^class_name\s+DepthFog\s*$", fog_src, re.M) is not None,
   "F1 声明 class_name DepthFog（正则锁行尾）")
ck(re.search(r"^extends\s+ColorRect\s*$", fog_src, re.M) is not None,
   "F2 DepthFog 基于 ColorRect")

# F3 纯函数签名（正则锁括号，防 sample_height_XXX 子串骗过）
ck(re.search(r"^static\s+func\s+fog_for_elevation\s*\(", fog_src, re.M) is not None,
   "F3 静态纯函数 fog_for_elevation")
ck(re.search(r"^static\s+func\s+desat_for_elevation\s*\(", fog_src, re.M) is not None,
   "F4 静态纯函数 desat_for_elevation")

# F5 分档表存在且档数>=4
ck(re.search(r"^const\s+FOG_BANDS\s*:=", fog_src, re.M) is not None,
   "F5 分档表 FOG_BANDS 存在")
bands = re.findall(r"\[(-?\d+\.?\d*),\s*Color\(([^)]*)\),\s*([\d.]+)\]", fog_src)
ck(len(bands) >= 4, "F6 分档数=%d（须>=4，对齐 low/plain/hill/peak）" % len(bands))

# F7 分档阈值必须与 TerrainHeight.band_name 的边界一致（双向核对）
# 【双向锚定·MEMORY 教训】只查下游侧会假绿：雾表阈值对、但 terrain_height 改了边界，
# 判据全绿而实际已割裂。故两侧都取出来排序比对。
band_body = func_body(read(TH), "band_name") or ""
fog_thr = sorted({float(b[0]) for b in bands if float(b[0]) > 0})
th_vals = sorted({float(x) for x in re.findall(r">\s*(\d+\.\d+)", band_body)})
ck(fog_thr == th_vals and len(th_vals) == 3,
   "F7 雾分档阈值与 band_name 边界双向一致 fog=%s th=%s" % (fog_thr, th_vals))

# F8 雾必须走 sample_height（与角色高度场同源），不得自行拼 elevation_at
body = func_body(fog_src, "sample_fog") or ""
# 【子串匹配漏洞·MEMORY 已记同类坑】用 `"sample_height" in body` 会被
# 守卫行 `has_method("sample_height")` 骗过 —— 把真正的调用点
# `terrain.sample_height(` 换成硬编码字典，照样命中 → 判据假绿。
# 正解：锁**调用形态** `terrain.sample_height(`，守卫里的 has_method("sample_height")
# 匹配不到（它没有 `terrain.` 前缀也没有紧跟左括号）。
ck(re.search(r"terrain\.sample_height\s*\(", body) is not None,
   "F8 sample_fog 真正调用 terrain.sample_height（与角色高度场同源）")
ck(re.search(r"elevation_at", body) is None,
   "F9 sample_fog 未绕过 sample_height 自行调 elevation_at（会丢城池掩码）")

# F10 必须采样相机而非玩家（雾是观察者所处大气）
ck(re.search(r"camera\.get_screen_center_position\s*\(", body) is not None,
   "F10 采样相机中心而非玩家位置")

# F11 缺依赖必须退化为全透明，不得抛异常
ck(body.count("return current_fog") >= 2 and "has_method" in body,
   "F11 terrain 缺失/无 sample_height 时安全退化为全透明")

# F12 必须不自绘且不吞点击（省一个全屏混合层）
ck(re.search(r"visible\s*=\s*false", fog_src) is not None,
   "F12 DepthFog 设 visible=false（不占全屏混合层）")
ck(re.search(r"mouse_filter\s*=\s*Control\.MOUSE_FILTER_IGNORE", fog_src) is not None,
   "F13 DepthFog 不吞点击")

# F14 process_mode 必须禁用（不得多一个每帧回调）
ck("PROCESS_MODE_DISABLED" in fog_src,
   "F14 禁用自身 _process（采样由 DayNightTint 顺带驱动）")

# F15 合成链接线：DayNightTint 必须真的把雾串进合成链
tint_proc = func_body(tint_src, "_process") or ""
ck("_fog_color()" in tint_proc,
   "F15 DayNightTint._process 把雾色串进合成链")
fog_fn = func_body(tint_src, "_fog_color") or ""
ck(re.search(r"fog\.sample_fog\s*\(", fog_fn) is not None,
   "F16 _fog_color 取 DepthFog.sample_fog")
ck(re.search(r"^var\s+fog\s*:\s*Node\s*=\s*null\s*$", tint_src, re.M) is not None,
   "F17 DayNightTint 声明 fog 成员且缺省 null（缺依赖行为同改动前）")
fog_fn2 = func_body(tint_src, "_fog_color") or ""
ck("is_instance_valid" in fog_fn2 or "== null" in fog_fn2,
   "F18 _fog_color 对 fog 缺失做了守卫")

# F19 world_map 必须注入 fog 与 camera/terrain
ck(re.search(r"DepthFog\.new\(\)", wmap_src) is not None,
   "F19 world_map 创建 DepthFog")
ck(re.search(r"depth_fog\.camera\s*=\s*_camera", wmap_src) is not None,
   "F20 DepthFog 注入相机")
ck(re.search(r"depth_fog\.terrain\s*=\s*_terrain", wmap_src) is not None,
   "F21 DepthFog 注入地形（高度场来源）")
ck(re.search(r"tint\.fog\s*=\s*depth_fog", wmap_src) is not None,
   "F22 DepthFog 挂到 DayNightTint（合成链真正生效）")

# F23 不得新开第二个全屏染色层（填充率铁律）
ck(wmap_src.count("DayNightTint.new()") == 1,
   "F23 未新增第二个全屏染色层（雾并入既有 tint）")

# F24 峰值 alpha 上限（源码字面核对，防手滑调浓）
peak_alpha = max(float(b[1].split(",")[3]) for b in bands)
ck(peak_alpha <= 0.12,
   "F24 源码峰值雾 alpha=%.3f 未超 0.12（可读性上限）" % peak_alpha)

# ============================ 汇总 ============================
print("\n" + "=" * 70)
total = len(summary)
bad = [m for ok, m in summary if not ok]
print("共 %d 项判定，失败 %d 项" % (total, len(bad)))
if bad:
    for m in bad:
        print("  FAIL " + m)
    print("DEPTH_FOG_VERIFY=FAIL")
    sys.exit(1)
print("DEPTH_FOG_VERIFY=PASS（%d 项全绿）" % total)
sys.exit(0)
