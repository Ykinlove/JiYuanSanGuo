# -*- coding: utf-8 -*-
"""真地形网格（TerrainMesh，第 5 项第六层）校验器。

三层校验：
  L1 headless 探针 14 项（含核心主张：地面几何必须随海拔真实变化、
     且**相邻格之间**也要有可感知高差 —— 只证「东 vs 西不同」不够，
     那可能只是一个巨大斜面，看起来仍是平板）
  L3 独立源码锚定（防「探针与产品代码同改互相放过」）
  X  组跨层一致性（网格高度与角色抬升必须同源 —— 两侧各乘一次会平方放大）
"""
import io
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
GODOT = "D:/Godot/Godot_v4.7.2-stable_win64_console.exe"

MESH = os.path.join(ROOT, "scripts", "world", "terrain_mesh.gd")
TH = os.path.join(ROOT, "scripts", "world", "terrain_height.gd")
WMAP = os.path.join(ROOT, "scripts", "world", "world_map.gd")
PROBE = os.path.join(ROOT, "tests", "terrain_mesh_probe.gd")

summary = []


def ck(cond, msg):
    summary.append((bool(cond), msg))
    print(("  [OK] " if cond else "  [FAIL] ") + msg)


def read(p):
    return io.open(p, encoding="utf-8").read()


def func_body(src, name):
    """提取函数体。参数支持裸名与完整签名片段两种历史调用形态。
    基线 = 函数签名行自身的缩进（顶层恒为 0）。"""
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
    sig_start = src.rfind("\n", 0, m.start()) + 1
    head = src[sig_start:m.start()]
    baseline = len(head) - len(head.lstrip("\t"))
    k = src.find("\n", j)
    out = []
    for ln in src[k + 1:].split("\n"):
        s = ln.strip()
        if s == "":
            out.append(ln)
            continue
        if len(ln) - len(ln.lstrip("\t")) <= baseline:
            break
        out.append(ln)
    return "\n".join(out)


print("=" * 70)
print("真地形网格（TerrainMesh，第 5 项第六层）校验")
print("=" * 70)

# ============================ L1 headless 探针 ============================
print("\n[L1] headless 行为探针")
if not os.path.exists(PROBE):
    ck(False, "探针缺失 tests/terrain_mesh_probe.gd")
else:
    p = subprocess.run(
        [GODOT, "--headless", "--path", ROOT, "--script", "res://tests/terrain_mesh_probe.gd"],
        cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = (p.stdout or "") + (p.stderr or "")
    m = re.search(r"TERRAIN_MESH_CHECKS=(\d+)", out)
    f = re.search(r"TERRAIN_MESH_FAILS=(\d+)", out)
    v = re.search(r"TERRAIN_MESH=(PASS|FAIL)", out)
    ck(m is not None and int(m.group(1)) >= 14,
       "L1-a 产出量闸门 checks=%s（须>=14）" % (m.group(1) if m else "?"))
    ck(f is not None and int(f.group(1)) == 0,
       "L1-b 行为判定零失败 fails=%s" % (f.group(1) if f else "?"))
    ck(v is not None and v.group(1) == "PASS",
       "L1-c 探针自 verdict=%s" % (v.group(1) if v else "?"))
    # M2b 是本层的核心主张，必须显式出现在输出里（防被悄悄删掉）
    ck("M2b" in out, "L1-d 核心主张 M2b（相邻格高差）已执行")

# ============================ L3 独立源码锚定 ============================
print("\n[L3] 独立源码锚定")
for p_ in (MESH, TH, WMAP):
    if not os.path.exists(p_):
        ck(False, "源文件缺失 " + p_)
ck(all(os.path.exists(p_) for p_ in (MESH, TH, WMAP)), "L3-0 源文件齐备")

mesh_src = read(MESH)
th_src = read(TH)
wmap_src = read(WMAP)

# N1 类名（正则锁行尾，防 TerrainMeshXXX 子串骗过）
ck(re.search(r"^class_name\s+TerrainMesh\s*$", mesh_src, re.M) is not None,
   "N1 声明 class_name TerrainMesh")
ck(re.search(r"^extends\s+Node2D\s*$", mesh_src, re.M) is not None,
   "N2 TerrainMesh 基于 Node2D")

# N3 关键 API 面
for fn in ("setup", "height_at", "normal_at", "slope_at", "grid_size"):
    ck(re.search(r"^func\s+%s\s*\(" % re.escape(fn), mesh_src, re.M) is not None,
       "N3 API 存在：%s" % fn)

# N4 网格密度：必须比 340 细（340 会导致单格高差仅 1px = 白做）
m_cell = re.search(r"^const\s+CELL\s*:=\s*([\d.]+)", mesh_src, re.M)
cell = float(m_cell.group(1)) if m_cell else 0.0
ck(0 < cell <= 200.0,
   "N4 网格边长 CELL=%.0f 已加密（须<=200；340 时单格高差仅 1px，等于白做）" % cell)

# N5 垂直夸张必须存在且 >= 4（否则坡度不可见）
m_ex = re.search(r"^const\s+VERT_EXAGGERATE\s*:=\s*([\d.]+)", th_src, re.M)
ex = float(m_ex.group(1)) if m_ex else 0.0
ck(ex >= 4.0,
   "N5 垂直夸张 VERT_EXAGGERATE=%.1f 足够（须>=4）" % ex)

# N6 夸张只许出现一次（在 lift_at 里）—— 两侧各乘一次会平方放大
lift_body = func_body(th_src, "lift_at") or ""
ck(lift_body.count("VERT_EXAGGERATE") == 1,
   "N6 lift_at 中 VERT_EXAGGERATE 恰好出现一次（防平方放大）")
ck("VERT_EXAGGERATE" not in mesh_src.replace(
    "TerrainHeight.VERT_EXAGGERATE", "").replace(
    "VERT_EXAGGERATE 只在", ""),
   "N7 网格层未再乘一次夸张（与角色高度场共用唯一真源）")

# N8 受光模型：必须有光向与明暗区间，否则面无明暗 = 白做
ck(re.search(r"^const\s+LIGHT_DIR\s*:=", mesh_src, re.M) is not None,
   "N8 定义受光方向 LIGHT_DIR")
# 【反向验证 R4 抓出的漏洞】原先只判「常量存在」，把 LIGHT_MIN 改成 1.0 全绿。
# 正解：判**区间必须真的张开**（MIN<MAX 且差值足够大，否则所有面同亮=没有明暗）。
m_lmin = re.search(r"^const\s+LIGHT_MIN\s*:=\s*([\d.]+)", mesh_src, re.M)
m_lmax = re.search(r"^const\s+LIGHT_MAX\s*:=\s*([\d.]+)", mesh_src, re.M)
lmin = float(m_lmin.group(1)) if m_lmin else -1.0
lmax = float(m_lmax.group(1)) if m_lmax else -1.0
ck(0.0 <= lmin < lmax and (lmax - lmin) >= 0.25,
   "N9 明暗区间真的张开 min=%.2f max=%.2f span=%.2f（span<0.25 等于没有明暗）"
   % (lmin, lmax, lmax - lmin))

# N10 _draw 必须拆三角（不拆则四边形共面 → 法线单一 → 面看起来是平的）
draw_body = func_body(mesh_src, "_draw") or ""
# 【反向验证 R5 抓出的漏洞】原先只数 `_draw_face(...)` 调用次数=2，
# 但把第二个三角改成「补上第四点凑成四边形」调用次数不变 → 判据假绿。
# 正解：断言**每组三角恰好 3 个顶点**，且两组顶点集合不同。
# 四边形 = 4 个顶点 → 一旦出现 4 个即说明折面被抹平。
# 注意：findall 是**按顶点**逐个返回的，故必须每 3 个切一组（不是每个都算一组）。
verts = re.findall(r"Vector2\(x[01],\s*y[01]\s*-\s*h\d\d\)", draw_body)
tri_groups = [verts[i:i + 3] for i in range(0, len(verts) - 2, 3)]
all_tri3 = len(tri_groups) >= 2 and all(len(g) == 3 for g in tri_groups)
ck(all_tri3 and len(verts) % 3 == 0,
   "N10 每格拆成两个三角（顶点组=%d，每组 3 个顶点；出现 4 顶点即折面被抹平）"
   % len(tri_groups))
first_tri = set(tri_groups[0]) if tri_groups else set()
second_tri = set(tri_groups[1]) if len(tri_groups) > 1 else set()
ck("h01" in "".join(second_tri) and "h01" not in "".join(first_tri),
   "N10b 第二个三角必须覆盖另半格（用到 h01 顶点）")
ck(draw_body.count("_draw_face") >= 2,
   "N10c _draw 每格两次 _draw_face（共 %d 次）" % draw_body.count("_draw_face"))
face_body = func_body(mesh_src, "_draw_face") or ""
ck("normal" in face_body or "nrm" in face_body,
   "N11 _draw_face 按法线算亮度（受光面明暗）")
ck("draw_colored_polygon" in face_body,
   "N12 _draw_face 真正画出多边形")

# N13 顶点高度必须取自 sample_height（与角色高度场同源，不能自造噪声）
build_body = func_body(mesh_src, "_build") or ""
ck("sample_height" in build_body,
   "N13 顶点海拔取自 sample_height（与角色高度场同源）")
ck("FastNoiseLite" not in mesh_src,
   "N14 网格未自造噪声（否则与角色高度场割裂）")

# N15 网格层不得单独放大（与 N6 呼应）
ck("HEIGHT_SCALE" not in mesh_src or "HEIGHT_SCALE_BASE" in mesh_src,
   "N15 网格层不独立使用 HEIGHT_SCALE（避免与真源脱钩）")

# ============================ X 组：跨层一致性 ============================
print("\n[X] 跨层接线（world_map 侧）")
ck(re.search(r"TerrainMesh\.new\(\)", wmap_src) is not None,
   "X1 world_map 创建 TerrainMesh")
ck(re.search(r"mesh\.setup\(_terrain", wmap_src) is not None,
   "X2 注入 terrain（海拔数据源）")
ck(re.search(r"mesh\.z_index\s*=\s*-110", wmap_src) is not None,
   "X3 网格垫在底图之下（z=-110 < Terrain 的 -100）")
ck(re.search(r"_setup_terrain_mesh\(\)", wmap_src) is not None,
   "X4 _ready 调用了建网格")

# 顺序：必须在地形可用之后、高度场之前
i_mesh = wmap_src.find("_setup_terrain_mesh()")
i_h = wmap_src.find("_setup_height_field()")
ck(0 < i_mesh < i_h,
   "X5 建网格早于高度场（角色贴地要查它）")

# 坡度倾斜接线
ck(re.search(r"func\s+_apply_slope_tilt\s*\(", wmap_src) is not None,
   "X6 存在坡度倾斜函数")
ck(re.search(r"^const\s+MAX_TILT_DEG\s*:=", wmap_src, re.M) is not None,
   "X7 倾斜幅度有上限（防与折面穿模）")
tilt_body = func_body(wmap_src, "_apply_slope_tilt") or ""
ck("normal_at" in tilt_body, "X8 倾斜按地面法线计算")
ck("deg_to_rad(-MAX_TILT_DEG)" in tilt_body and
   "deg_to_rad(MAX_TILT_DEG)" in tilt_body,
   "X9 倾斜双向夹紧在 ±MAX_TILT_DEG 内")
ck(tilt_body.count("_terrain_mesh == null") == 1,
   "X10 网格缺失时安全退化（不崩、不阻断）")
# 玩家与 NPC 都要倾斜
# 【反向验证 R8 抓出的漏洞】原先只判「调用处数 >= 3」，而实际有 4 处
# （函数定义 + 玩家 + NPC + _apply_height）—— 把**玩家那行**改成 pass 仍 ≥3 → 假绿。
# 正解：逐目标精确断言——玩家可视节点那一行、实体抬升那一行、NPC 那一行，
# 三处必须各自真的调用到，不能靠别处凑数。
ck(re.search(r"_apply_slope_tilt\(pv,\s*pp\)", wmap_src) is not None,
   "X11a 玩家可视节点每帧跟随坡度")
ck(re.search(r"_apply_slope_tilt\(v,\s*p\)", wmap_src) is not None,
   "X11b 城池/遭遇点等固定实体接入倾斜")
ck(re.search(r"_apply_slope_tilt\(av,\s*ap\)", wmap_src) is not None,
   "X11c 世界 NPC 接入倾斜")
n_tilt = len(re.findall(r"_apply_slope_tilt\(", wmap_src))
ck(n_tilt >= 4,
   "X11d 倾斜调用点齐全（%d 处：定义 + 玩家 + 城池 + NPC）" % n_tilt)

# ============================ 汇总 ============================
print("\n" + "=" * 70)
total = len(summary)
bad = [m for ok, m in summary if not ok]
print("共 %d 项判定，失败 %d 项" % (total, len(bad)))
if bad:
    for m in bad:
        print("  FAIL " + m)
    print("TERRAIN_MESH_VERIFY=FAIL")
    sys.exit(1)
print("TERRAIN_MESH_VERIFY=PASS（%d 项全绿）" % total)
sys.exit(0)
