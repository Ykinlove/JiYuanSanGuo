# -*- coding: utf-8 -*-
"""战斗场景起伏地面（BattleGround）校验器。

  L1 headless 探针 11 项（地面线必须随 x 真实起伏 / 高低差 ≥18px /
     边缘压平 / 倾角限幅 / 竖直范围 / 极小视口）
  L3 独立源码锚定（防探针与产品同改互相放过）
  X  组战斗场景接线（GroundLine 压淡 / 两侧单位根都贴地 / 走 meta 基准防逐帧下坠）
"""
import io
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
GODOT = "D:/Godot/Godot_v4.7.2-stable_win64_console.exe"

BG = os.path.join(ROOT, "scripts", "battle", "battle_ground.gd")
BS = os.path.join(ROOT, "scripts", "battle", "battle_scene.gd")
PROBE = os.path.join(ROOT, "tests", "battle_ground_probe.gd")

summary = []


def ck(cond, msg):
    summary.append((bool(cond), msg))
    print(("  [OK] " if cond else "  [FAIL] ") + msg)


def read(p):
    return io.open(p, encoding="utf-8").read()


def func_body(src, name):
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
print("战斗起伏地面（BattleGround）校验")
print("=" * 70)

# ============================ L1 ============================
print("\n[L1] headless 行为探针")
p = subprocess.run(
    [GODOT, "--headless", "--path", ROOT, "--script", "res://tests/battle_ground_probe.gd"],
    cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace")
out = (p.stdout or "") + (p.stderr or "")
m = re.search(r"BATTLE_GROUND_CHECKS=(\d+)", out)
f = re.search(r"BATTLE_GROUND_FAILS=(\d+)", out)
v = re.search(r"BATTLE_GROUND=(PASS|FAIL)", out)
ck(m is not None and int(m.group(1)) >= 11,
   "L1-a 产出量闸门 checks=%s（须>=11）" % (m.group(1) if m else "?"))
ck(f is not None and int(f.group(1)) == 0,
   "L1-b 行为判定零失败 fails=%s" % (f.group(1) if f else "?"))
ck(v is not None and v.group(1) == "PASS",
   "L1-c 探针自 verdict=%s" % (v.group(1) if v else "?"))
for core in ("G2", "G3", "G6"):
    ck(core in out, "L1-d 核心判定 %s 已执行" % core)

# ============================ L3 ============================
print("\n[L3] 独立源码锚定")
for p_ in (BG, BS):
    if not os.path.exists(p_):
        ck(False, "源文件缺失 " + p_)
ck(all(os.path.exists(p_) for p_ in (BG, BS)), "L3-0 源文件齐备")

bg = read(BG)
bs = read(BS)

ck(re.search(r"^class_name\s+BattleGround\s*$", bg, re.M) is not None,
   "P1 声明 class_name BattleGround")
ck(re.search(r"^extends\s+Node2D\s*$", bg, re.M) is not None,
   "P2 BattleGround 基于 Node2D")

for fn in ("build", "relief_at", "ground_y_at", "tilt_at"):
    ck(re.search(r"^func\s+%s\s*\(" % re.escape(fn), bg, re.M) is not None,
       "P3 API 存在：%s" % fn)

# 起伏幅度：须在「看得见」与「不出戏」之间
m_rel = re.search(r"^const\s+RELIEF\s*:=\s*([\d.]+)", bg, re.M)
rel = float(m_rel.group(1)) if m_rel else 0.0
ck(40.0 <= rel <= 90.0,
   "P4 起伏幅度 RELIEF=%.0f 在合理区间 40~90（太小看不出坡，太大会破坏判定）" % rel)

# 边缘压平必须真归零：clampf(edge, 0.15, 1.0) 是**钳位**不是归零（探针抓到的真实缺陷）
build_body = func_body(bg, "build") or ""
ck(re.search(r"edge\s*=\s*edge\s*\*\s*edge", build_body) is not None,
   "P5 边缘压平用 sin² 真正归零（不是 clampf 钳位）")
# 【本轮判据假红·已修】原先用 `clampf(edge, 0.15` 搜全文件，
# 但那段文字只存在于**注释**里（记录原缺陷）→ 判据恒真失败。
# 正解：只看 build 的**函数体**、且排除注释行。
code_lines = [ln for ln in build_body.split("\n") if not ln.strip().startswith("#")]
code_only = "\n".join(code_lines)
ck(re.search(r"clampf\(edge", code_only) is None,
   "P6 代码中未用 clampf 钳位残留起伏（探针 G6 抓到的原缺陷；注释不算）")

# 生成 / 查询 / 绘制三处必须同口径（否则画的面与查询高度错位）
ck(re.search(r"float\(i\)\s*/\s*float\(maxi\(1,\s*_cols\s*-\s*1\)\)", build_body) is not None,
   "P7 build 用归一化 t 生成（末格精确落在边缘）")
relief_body = func_body(bg, "relief_at") or ""
ck("t * float(_cols - 1)" in relief_body or "t * float(maxi(1, _cols - 1))" in relief_body,
   "P8 relief_at 与 build 同口径（归一化插值）")
draw_body = func_body(bg, "_draw") or ""
draw_code = "\n".join(ln for ln in draw_body.split("\n")
                      if not ln.strip().startswith("#"))
# 【本轮判据假红·已修】原先搜 `_cols - 1) * span_x`，但实际代码是
# `float(i + 1) / float(maxi(1, _cols - 1)) * span_x`（分母带 maxi 包裹），
# 形态对不上导致恒假红。正解：分别断言首末两格的换算，且都按 _cols-1 归一。
ck(re.search(r"float\(i\)\s*/\s*float\(maxi\(1,\s*_cols\s*-\s*1\)\)\s*\*\s*span_x", draw_code) is not None,
   "P9 _draw 首格横坐标按 _cols-1 归一（与 build 同口径）")
ck(re.search(r"float\(i\s*\+\s*1\)\s*/\s*float\(maxi\(1,\s*_cols\s*-\s*1\)\)\s*\*\s*span_x", draw_code) is not None,
   "P9b _draw 末格横坐标同样归一（画的面不会比查询高度窄一格）")

# 受光明暗：没有明暗就不是立体面
ck(re.search(r"^const\s+LIGHT_DIR\s*:=", bg, re.M) is not None,
   "P10 定义受光方向")
# 【反向验证 R5 抓出的漏洞】原先只判「LIGHT_MIN 常量存在」，
# 改成 1.0 全绿 → 所有面同亮 = 没有明暗。正解：判区间必须真的张开。
m_bmin = re.search(r"^const\s+LIGHT_MIN\s*:=\s*([\d.]+)", bg, re.M)
m_bmax = re.search(r"^const\s+LIGHT_MAX\s*:=\s*([\d.]+)", bg, re.M)
bmin = float(m_bmin.group(1)) if m_bmin else -1.0
bmax = float(m_bmax.group(1)) if m_bmax else -1.0
ck(0.0 <= bmin < bmax and (bmax - bmin) >= 0.2,
   "P10b 明暗区间真的张开 min=%.2f max=%.2f span=%.2f（span<0.2 等于没有明暗）"
   % (bmin, bmax, bmax - bmin))
face_body = func_body(bg, "_draw_face") or {}
ck("shade" in face_body and "draw_colored_polygon" in face_body,
   "P11 _draw_face 按受光画面")

# 确定性：种子固定
ck(re.search(r"^var\s+seed_value\s*:=\s*\d+", bg, re.M) is not None,
   "P12 噪声种子固定（可复现，便于截图取证）")
ck("GameState" not in bg and "DataManager" not in bg,
   "P13 不依赖 autoload（无头探针可独立实例化）")

# ============================ X 组接线 ============================
print("\n[X] 战斗场景接线")
ck(re.search(r"var\s+_battle_ground\s*:\s*BattleGround\s*=\s*null", bs) is not None,
   "X1 声明 _battle_ground 且缺省 null（缺依赖自动退化）")
ck(re.search(r"func\s+_setup_battle_ground\s*\(", bs) is not None,
   "X2 存在地面构建函数")
ck(re.search(r"BattleGround\.new\(\)", bs) is not None,
   "X3 战斗场景创建 BattleGround")
ck(re.search(r"bg\.build\(get_viewport_rect\(\)\.size\)", bs) is not None,
   "X4 按当前视口尺寸构建")
ck(re.search(r"bg\.z_index\s*=\s*-20", bs) is not None,
   "X5 地面压在单位之下（z=-20）")
# 旧 GroundLine 必须压淡（否则纯色块盖住起伏地面）
ck(re.search(r"\(gl as ColorRect\)\.modulate\.a\s*=\s*0\.12", bs) is not None,
   "X6 旧 GroundLine 被压淡（否则纯色块压住起伏地面）")
# 每帧贴地
ck(re.search(r"func\s+_apply_ground_alignment\s*\(", bs) is not None,
   "X7 存在贴地对齐函数")
align_body = func_body(bs, "_apply_ground_alignment") or {}
ck("_battle_ground == null" in align_body,
   "X8 地面缺失时安全早退（不崩）")
ck("_ally_units" in align_body and "_enemy_units" in align_body,
   "X9 两侧单位根都处理（写错成员名会静默跳过）")
# meta 基准：防逐帧累加下坠
one_body = func_body(bs, "_align_one") or {}
ck("has_meta" in one_body and "set_meta" in one_body,
   "X10 用 meta 记录基准 y（防每帧叠加导致逐帧下坠）")
ck("ground_y_at" in one_body, "X11 贴地取自 ground_y_at")
ck("tilt_at" in one_body, "X12 随坡倾斜取自 tilt_at")
# 关键：不能改实体 position（战斗判定依赖它）
ck("unit.position.y =" not in one_body and "unit.position.y +=" not in one_body,
   "X13 不改实体 position（战斗判定依赖它）")
ck("vis.position.y =" in one_body,
   "X14 只写视觉子节点的 position")
# 【反向验证 R9 抓出的漏洞】原先只判「写了 vis.position.y」，
# 改成 `vis.position.y = gy`（直接用地平线绝对值、丢掉基准换算）也全绿。
# 正解：必须同时用到「基准 meta」与「实体 y」做差 —— 缺一项单位就会脱位。
one_code = "\n".join(ln for ln in one_body.split("\n")
                     if not ln.strip().startswith("#"))
ck("get_meta(key)" in one_code and "unit.position.y" in one_code,
   "X14b 贴地换算同时用到基准 meta 与实体 y（缺一单位即脱位）")
ck(re.search(r"vis\.position\.y\s*=\s*float\(vis\.get_meta\(key\)\)\s*\+", one_code) is not None,
   "X14c 贴地写成「基准 + (地平线 - 实体y)」而非直接赋值")
# 必须接进每帧
proc_body = func_body(bs, "_process") or {}
ck("_apply_ground_alignment()" in proc_body,
   "X15 已接入 _process")

print("\n" + "=" * 70)
total = len(summary)
bad = [mm for ok, mm in summary if not ok]
print("共 %d 项判定，失败 %d 项" % (total, len(bad)))
if bad:
    for mm in bad:
        print("  FAIL " + mm)
    print("BATTLE_GROUND_VERIFY=FAIL")
    sys.exit(1)
print("BATTLE_GROUND_VERIFY=PASS（%d 项全绿）" % total)
sys.exit(0)
