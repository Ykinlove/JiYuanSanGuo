# -*- coding: utf-8 -*-
"""BattleGround 反向验证：9 个真缺陷注入必须报红。"""
import hashlib
import io
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
BG = os.path.join(ROOT, "scripts", "battle", "battle_ground.gd")
BS = os.path.join(ROOT, "scripts", "battle", "battle_scene.gd")
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
    ("R1", BG, "const RELIEF := 56.0", "const RELIEF := 2.0",
     "起伏幅度归零 → 战场退回成桌布"),
    ("R2", BG, "\t\t\tedge = edge * edge", "\t\t\tpass",
     "边缘不再压平 → 两端是墙，单位悬空"),
    ("R3", BG, "\t\t\tvar t := float(i) / float(maxi(1, _cols - 1))",
     "\t\t\tvar t := 0.5",
     "生成不按归一化 → 末格不在边缘、画的面与查询脱节"),
    ("R4", BG, "\tif _heights.is_empty() or _cols <= 0:\n\t\treturn 0.0\n\t# 【必须与 build 同口径】",
     "\tif _heights.is_empty() or _cols <= 0:\n\t\treturn 0.0\n\tif true:\n\t\treturn 0.0\n\t# 锚点",
     "relief_at 恒返回 0 → 地面恒平"),
    ("R5", BG, "const LIGHT_MIN := 0.70", "const LIGHT_MIN := 1.0",
     "明暗区间塌缩 → 地面无立体感"),
    ("R6", BS, "\tbg.z_index = -20", "\tbg.z_index = 5",
     "地面压在单位之上 → 挡住角色"),
    ("R7", BS, "\t\t(gl as ColorRect).modulate.a = 0.12",
     "\t\t(gl as ColorRect).modulate.a = 1.0",
     "旧 GroundLine 不压淡 → 纯色块盖住起伏地面"),
    ("R8", BS, "\tif not vis.has_meta(key):\n\t\tvis.set_meta(key, vis.position.y)",
     "\tvis.set_meta(key, vis.position.y)",
     "去掉 meta 首帧守卫 → 首帧把已贴地的 y 当基准，之后逐帧下坠"),
    ("R9", BS, "\tvis.position.y = float(vis.get_meta(key)) + (gy - unit.position.y)",
     "\tvis.position.y = gy",
     "丢掉基准换算 → 跳到地平线绝对值，单位脱位"),
]

FALSE_POS = [
    ("F1", BG, "const CELL := 96.0", "const CELL := 96.0  # 屏幕像素",
     "加行尾注释"),
    ("F2", BS, "\tbg.name = \"BattleGround\"", "\tbg.name = \"BattleGround\"  # 命名",
     "加尾注释"),
]

fp0 = save_fp()
print("=" * 70)
print("战斗起伏地面 反向验证")
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
        rc = run("_verify_battle_ground.py")
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
        rc = run("_verify_battle_ground.py")
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
    print("BATTLE_GROUND_REVERSE=FAIL")
    sys.exit(1)
print("BATTLE_GROUND_REVERSE=PASS（%d 项全绿）" % total)
sys.exit(0)
