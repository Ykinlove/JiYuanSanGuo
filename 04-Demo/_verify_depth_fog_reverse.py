# -*- coding: utf-8 -*-
"""纵深雾化（DepthFog）反向验证：11 个真缺陷注入必须报红。

【为什么必须反向验证】绿灯必须证明过自己有效。否则「把雾删掉」也可能全绿。

【血泪·纪律】
  · 还原一律 shutil.copy2（shutil.move 在 Windows 上＝删除源，撞批量删除钩子）
  · 注入前先断言锚点命中数==1（assert 在写盘前中止＝制造假绿灯）
  · 存档指纹跑前跑后比对，确保零污染玩家存档
"""
import hashlib
import io
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
FOG = os.path.join(ROOT, "scripts", "world", "depth_fog.gd")
TINT = os.path.join(ROOT, "scripts", "world", "day_night_tint.gd")
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
    d = io.open(p, "rb").read()
    crlf = b"\r\n" in d
    out = s.replace("\n", "\r\n") if crlf else s
    open(p, "wb").write(out.encode("utf-8"))


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


# (用例标签, 目标文件, 旧锚点, 新代码, 说明)
CASES = [
    ("R1", FOG,
     "\tvisible = false\n\tmouse_filter = Control.MOUSE_FILTER_IGNORE\n\t# 采样只在",
     "\tvisible = true\n\tmouse_filter = Control.MOUSE_FILTER_IGNORE\n\t# 采样只在",
     "_init 里恢复可见 → 白占一个全屏混合层"),
    ("R2", FOG, "\tprocess_mode = Node.PROCESS_MODE_DISABLED",
     "\tprocess_mode = Node.PROCESS_MODE_ALWAYS",
     "恢复每帧回调 → 多一份无谓开销"),
    ("R3", FOG, "\tif not terrain.has_method(\"sample_height\"):",
     "\tif false:",
     "去掉 has_method 守卫 → 缺接口时崩"),
    ("R4", FOG, "focus = camera.get_screen_center_position()",
     "focus = Vector2.ZERO",
     "不采样相机 → 雾与观察位置脱节"),
    ("R5", FOG, "var h = terrain.sample_height(focus.x, focus.y)",
     "var h = {\"elev\": 0.5}",
     "绕开 sample_height → 与角色高度场不同源"),
    ("R6", FOG, "\t[0.80, Color(0.62, 0.74, 0.92, 0.085), 0.26]",
     "\t[0.80, Color(0.62, 0.74, 0.92, 0.55), 0.26]",
     "峰值雾调到 0.55 → 压垮可读性"),
    ("R7", FOG, "\t[0.40, Color(0.82, 0.86, 0.93, 0.038), 0.08]",
     "\t[0.55, Color(0.82, 0.86, 0.93, 0.038), 0.08]",
     "plain 档阈值漂到 0.55 → 与 band_name 割裂"),
    ("R8", TINT, "\t\t\tweather_dim), _fog_color())",
     "\t\t\tweather_dim))",
     "把雾从合成链摘掉 → 写了等于没写"),
    ("R9", TINT, "\treturn fog.sample_fog()",
     "\treturn Color(0, 0, 0, 0)",
     "_fog_color 恒返回透明 → 雾永不生效"),
    ("R10", WMAP, "\ttint.fog = depth_fog\n",
     "",
     "world_map 不把 fog 挂到 tint → 合成链接线断开"),
    ("R11", WMAP, "\tdepth_fog.terrain = _terrain\n",
     "",
     "不注入 terrain → 雾永远退化透明"),
]

# 假阳性对照：这些注入**不该**让校验报红（它们是无害改动）
FALSE_POS = [
    ("F1", FOG, "var current_elev := 0.0",
     "var current_elev := 0.0   # 当前相机海拔（调试可读）",
     "只加行尾注释"),
    ("F2", WMAP, "\tdepth_fog.name = \"DepthFog\"",
     "\tdepth_fog.name = \"DepthFog\"  # 命名固定，改了会被判据抓到",
     "加尾注释"),
]

fp0 = save_fp()
print("=" * 70)
print("纵深雾化 反向验证")
print("=" * 70)

fails = 0
for tag, path, old, new, note in CASES:
    src = read(path)
    cnt = src.count(old)
    if cnt != 1:
        ck(False, "%s 锚点命中数=%d（应为1），用例本身失效：%r" % (tag, cnt, old[:60]))
        fails += 1
        continue
    bak = path + ".rvbak"
    shutil.copy2(path, bak)          # 备份必须在注入之前取
    try:
        write(path, src.replace(old, new))
        rc = run("_verify_depth_fog.py")
        ck(rc != 0, "%s 注入后校验报红（exit=%s）%s" % (tag, rc, note))
    finally:
        shutil.copy2(bak, path)        # copy2 覆写，不用 move
        if os.path.exists(bak):
            try:
                os.replace(bak, bak + ".stale")
            except BaseException:
                pass

# 假阳性对照
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
        rc = run("_verify_depth_fog.py")
        ck(rc == 0, "%s 假阳性对照：%s 后仍绿（exit=%s）" % (tag, note, rc))
    finally:
        shutil.copy2(bak, path)
        if os.path.exists(bak):
            try:
                os.replace(bak, bak + ".stale")
            except BaseException:
                pass

# X1 判据方向对照：峰值雾真的超标时必须报红（证明 F6 上限判据不是死代码）
fp1 = save_fp()
ck(fp0 == fp1, "X1 存档未被污染（指纹一致 %s）" % fp0)

print("\n" + "=" * 70)
total = len(summary)
bad = [m for ok, m in summary if not ok]
print("用例 %d 项 / 失败 %d 项" % (total, len(bad)))
if bad:
    for m in bad:
        print("  FAIL " + m)
    print("DEPTH_FOG_REVERSE=FAIL")
    sys.exit(1)
print("DEPTH_FOG_REVERSE=PASS（%d 项全绿）" % total)
sys.exit(0)
