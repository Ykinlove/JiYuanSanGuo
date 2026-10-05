# -*- coding: utf-8 -*-
"""TerrainMesh（第 5 项第六层）反向验证：10 个真缺陷注入必须报红。

【为什么必须】绿灯必须证明过自己有效。否则「把整个网格删掉」也可能全绿。

【纪律】
  · 还原一律 shutil.copy2（shutil.move 在 Windows 上＝删除源，撞批量删除钩子）
  · 备份必须在注入之前取
  · 锚点命中数必须==1，否则用例自身失效
"""
import hashlib
import io
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
MESH = os.path.join(ROOT, "scripts", "world", "terrain_mesh.gd")
TH = os.path.join(ROOT, "scripts", "world", "terrain_height.gd")
WMAP = os.path.join(ROOT, "scripts", "world", "world_map.gd")
SAVES = os.path.join(os.environ.get("APPDATA", ""), "Godot", "app_userdata",
                     "纪元三国", "saves")

summary = []


def ck(cond, msg):
    summary.append((bool(cond), msg))
    print(("  [OK] " if cond else "  [FAIL] ") + msg)


def read(p):
    return io.open(p, encoding="utf-8").read()


def write(p, s):
    d = open(p, "rb").read()
    crlf = b"\r\n" in d
    open(p, "wb").write((s.replace("\n", "\r\n") if crlf else s).encode("utf-8"))


def run(script):
    p = subprocess.run([sys.executable, script], cwd=ROOT, capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    return p.returncode


def save_fp():
    if not os.path.isdir(SAVES):
        return "no-saves"
    h = hashlib.sha256()
    for f in sorted(os.listdir(SAVES)):
        fp = os.path.join(SAVES, f)
        if os.path.isfile(fp):
            h.update(f.encode("utf-8"))
            h.update(open(fp, "rb").read())
    return h.hexdigest()[:16]


CASES = [
    ("R1", MESH, "const CELL := 170.0", "const CELL := 340.0",
     "网格过粗 → 单格高差仅 1px，等于白做"),
    ("R2", TH, "const VERT_EXAGGERATE := 7.0", "const VERT_EXAGGERATE := 1.0",
     "取消垂直夸张 → 坡度不可见，仍是平板"),
    ("R3", TH, "city_mask) * HEIGHT_SCALE * VERT_EXAGGERATE",
     "city_mask) * HEIGHT_SCALE",
     "lift_at 不再夸张 → 角色与网格脱节"),
    ("R4", MESH, "const LIGHT_MIN := 0.62", "const LIGHT_MIN := 1.0",
     "明暗区间塌缩 → 面无受光差异"),
    ("R5", MESH, "\t\t\t_draw_face(PackedVector2Array([\n\t\t\t\tVector2(x0, y0 - h00), Vector2(x1, y0 - h10), Vector2(x1, y1 - h11)]),\n\t\t\t\tVector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), band)",
     "\t\t\t# 拆三角被摘掉：整格只画一个四边形 → 共面 → 法线单一 → 看起来是平的\n\t\t\t_draw_face(PackedVector2Array([\n\t\t\t\tVector2(x0, y0 - h00), Vector2(x1, y0 - h10), Vector2(x1, y1 - h11), Vector2(x0, y1 - h01)]),\n\t\t\t\tVector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), band)",
     "只画一个四边形 → 折面消失"),
    ("R6", MESH, "var h: Dictionary = _terrain.sample_height(wx, wy)",
     "var h: Dictionary = {\"lift\": 0.0, \"band\": \"plain\"}",
     "顶点高度写死 → 地面变平板（且与角色高度场割裂）"),
    ("R7", WMAP, "\tmesh.z_index = -110", "\tmesh.z_index = 5",
     "网格压在实体之上 → 挡住角色"),
    ("R8", WMAP, "\t_apply_slope_tilt(pv, pp)", "\tpass",
     "玩家不贴坡倾斜 → 站在斜坡上仍笔直"),
    # 【第七十六轮·锚点同步】夹紧行已改为按角色分流（`deg_to_rad(-lim)`），
    # 原锚写死 `deg_to_rad(-MAX_TILT_DEG)` ⇒ 命中 0 次、用例"失效"。
    # 症状是「用例本身失效」而不是 FAIL —— 极易被误读成「判据没功效」。
    # 正解：锚实际存在的夹紧表达式，注入后仍是要去掉夹紧，判据意图不变。
    ("R9", WMAP, "\tvis.rotation = clampf(ang, deg_to_rad(-lim), deg_to_rad(lim))",
     "\tvis.rotation = ang",
     "去掉倾斜夹紧 → 与折面穿模"),
    ("R10", WMAP, "if _terrain_mesh == null or vis == null:",
     "if false:",
     "去掉网格缺失守卫 → 缺网格时崩"),
]

FALSE_POS = [
    ("F1", MESH, "const SLOPE_SHADE := 0.34", "const SLOPE_SHADE := 0.34   # 陡坡压暗",
     "加行尾注释"),
    ("F2", TH, "const HEIGHT_SCALE := 102.0", "const HEIGHT_SCALE := 102.0  # 世界像素",
     "加行尾注释"),
]

fp0 = save_fp()
print("=" * 70)
print("真地形网格 反向验证")
print("=" * 70)

for tag, path, old, new, note in CASES:
    src = read(path)
    cnt = src.count(old)
    if cnt != 1:
        ck(False, "%s 锚点命中数=%d（应为1），用例失效：%r" % (tag, cnt, old[:60]))
        continue
    bak = path + ".rvbak"
    shutil.copy2(path, bak)
    try:
        write(path, src.replace(old, new))
        rc = run("_verify_terrain_mesh.py")
        ck(rc != 0, "%s 注入后校验报红（exit=%s）%s" % (tag, rc, note))
    finally:
        shutil.copy2(bak, path)
        if os.path.exists(bak):
            try:
                os.replace(bak, bak + ".stale")
            except BaseException:
                pass

for tag, path, old, new, note in FALSE_POS:
    src = read(path)
    cnt = src.count(old)
    if cnt != 1:
        ck(False, "%s 锚点命中数=%d（应为1）" % (tag, cnt))
        continue
    bak = path + ".rvbak"
    shutil.copy2(path, bak)
    try:
        write(path, src.replace(old, new))
        rc = run("_verify_terrain_mesh.py")
        ck(rc == 0, "%s 假阳性对照：%s 后仍绿（exit=%s）" % (tag, note, rc))
    finally:
        shutil.copy2(bak, path)
        if os.path.exists(bak):
            try:
                os.replace(bak, bak + ".stale")
            except BaseException:
                pass

ck(save_fp() == fp0, "X1 存档未被污染（指纹一致 %s）" % fp0)

print("\n" + "=" * 70)
total = len(summary)
bad = [m for ok, m in summary if not ok]
print("用例 %d 项 / 失败 %d 项" % (total, len(bad)))
if bad:
    for m in bad:
        print("  FAIL " + m)
    print("TERRAIN_MESH_REVERSE=FAIL")
    sys.exit(1)
print("TERRAIN_MESH_REVERSE=PASS（%d 项全绿）" % total)
sys.exit(0)
