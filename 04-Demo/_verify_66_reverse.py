# -*- coding: utf-8 -*-
"""
_verify_66_reverse.py — 第六十六轮三把新锁的**反向验证**

【为什么要这个脚本】一把「恰好通过」的锁没有价值：如果把它盯着的缺陷改回去，
它却仍然报绿，那它就是一把不会响的锁（假绿灯）。本脚本把每一处修复
**逐个改回旧写法**，断言对应判据必须变红；再把改动还原，断言恢复全绿。
每个注入用例还配一个**假阳性对照**：改一处与判据无关的内容，锁必须**仍然绿**，
否则说明判据过于宽泛（靠"文件里有这个字"蒙对）。

【安全约束】
  · 注入期间只跑**静态**校验器（纯 Python 读源码），不跑 Godot 编译，
    因此即便注入后 GDScript 不合语法也不会污染判定；
  · 唯一需要真跑引擎的用例（R7）注入的是探针自身常量，语法仍合法；
  · 备份与还原走 os.replace（改名），不使用 os.remove —— 避免触发批量删除防护钩子；
  · 每个用例都用 try/finally 保证还原，脚本中途异常也不会把源码留在注入态。
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable

SCALE = os.path.join(HERE, "_verify_world_scale.py")
INTER = os.path.join(HERE, "_verify_interaction_ui.py")
MENU = os.path.join(HERE, "_verify_menu_reopen.py")

ENC = os.path.join(HERE, "scripts", "world", "encounter_manager.gd")
WALK = os.path.join(HERE, "scripts", "world", "walk_anim.gd")
CITY = os.path.join(HERE, "scripts", "city", "city_scene.gd")
DLG = os.path.join(HERE, "scripts", "ui", "dialogue_ui.gd")
IMENU = os.path.join(HERE, "scripts", "ui", "interaction_menu.gd")
WMAP = os.path.join(HERE, "scripts", "world", "world_map.gd")
PROBE = os.path.join(HERE, "tests", "menu_reopen_probe.gd")

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print("  [%s] %s%s" % ("OK" if ok else "FAIL", name, ("  " + detail) if detail else ""))
    return bool(ok)


def run(script):
    p = subprocess.run([PY, script], cwd=HERE, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return p.returncode


def swap(path, old, new):
    """把 path 里首次出现的 old 换成 new，返回还原函数。"""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        src = f.read()
    if old not in src:
        raise AssertionError("锚点未命中：%s 中找不到 %r" % (os.path.basename(path), old[:60]))
    bak = path + ".rvbak"
    os.replace(path, bak)
    with open(path, "w", encoding="utf-8") as f:
        f.write(src.replace(old, new, 1))

    def restore():
        if os.path.exists(bak):
            os.replace(bak, path)
    return restore


def case(tag, path, old, new, script, expect_red):
    """注入 → 跑锁 → 还原 并判定。expect_red=True 表示注入后锁必须变红。"""
    try:
        restore = swap(path, old, new)
    except AssertionError as e:
        check(tag, False, str(e))
        return
    try:
        rc = run(script)
        tail = ""
        if expect_red:
            ok = rc != 0
            tail = "退出码 %d（应为非 0 → 锁变红）" % rc
        else:
            ok = rc == 0
            tail = "退出码 %d（应为 0 → 锁仍绿，判据不误伤）" % rc
        check(tag, ok, tail)
    finally:
        restore()
    # 还原后必须恢复原状
    rc2 = run(script)
    check(tag + " · 还原后恢复", rc2 == (0 if not expect_red or True else 0) and rc2 == 0,
          "退出码 %d" % rc2)


print("=" * 68)
print("第六十六轮 反向验证：三把新锁是否真的会响")
print("=" * 68)

# 基线：三把锁在**未注入**时必须全绿
print("\n[0] 基线（未注入）")
check("世界尺度锁 基线绿", run(SCALE) == 0)
check("交互框锁 基线绿", run(INTER) == 0)
check("菜单重开锁 基线绿", run(MENU) == 0)

# ---------- 世界尺度锁 ----------
print("\n[R1] 遭遇物尺寸改回旧值 54 → 尺度判据必须变红")
case("R1 尺度判据捕获旧尺寸", ENC,
     "const ENC_WORLD_HEIGHT := 125.0", "const ENC_WORLD_HEIGHT := 54.0",
     SCALE, True)

print("\n[R1a] 假阳性对照：只改一处无关注释 → 锁必须仍绿")
case("R1a 无关改动不误报", ENC,
     "const ENC_TEX_DIR := ", "const ENC_TEX_DIR :=  ## 无关注释\nconst ENC_X_DIR := ",
     SCALE, False)

print("\n[R2] 遭遇物间距改回旧值 220 → 密度判据必须变红")
case("R2 密度判据捕获旧间距", ENC,
     "const ENC_MIN_GAP := 620.0", "const ENC_MIN_GAP := 220.0",
     SCALE, True)

print("\n[R3] 步幅改回绝对像素 → 行走判据必须变红")
case("R3 行走判据捕获旧步幅", WALK,
     "lerpf(STRIDE_MIN_RATIO, STRIDE_MAX_RATIO, ratio)",
     "lerpf(26.0, 64.0, ratio)",
     SCALE, True)

print("\n[R3a] 假阳性对照：改一处与步幅无关的行走参数 → 锁必须仍绿")
case("R3a 无关改动不误报", WALK,
     "@export var idle_amp := 0.8", "@export var idle_amp := 0.81",
     SCALE, False)

# ---------- 交互框锁 ----------
print("\n[R4] 提示改回「右端对齐按钮右缘」→ 对齐判据必须变红")
case("R4 对齐判据捕获旧写法", CITY,
     "_action_hint.offset_right = btn_cx + hint_w * 0.5",
     "_action_hint.offset_right = x + sz",
     INTER, True)

print("\n[R4a] 假阳性对照：改一处无关城内代码 → 锁必须仍绿")
case("R4a 无关改动不误报", CITY,
     "var margin := 54.0", "var margin := 55.0",
     INTER, False)

print("\n[R5] 选项框改回贴底预设 → 对话卡定位判据必须变红")
case("R5 对话卡判据捕获旧预设", DLG,
     "_options_box.set_anchors_preset(Control.PRESET_CENTER_TOP)",
     "_options_box.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)",
     INTER, True)

print("\n[R6] 交互菜单关掉居中 → 居中判据必须变红")
case("R6 居中判据捕获关闭居中", IMENU,
     "var center_on_screen := true", "var center_on_screen := false",
     INTER, True)

# ---------- 菜单重开锁 ----------
print("\n[R7] 探针信任期帧数归零（等同修复前）→ A/B 用例必须变红")
case("R7 探针捕获信任期失效", PROBE,
     "const GUARD_FRAMES := 8", "const GUARD_FRAMES := 0",
     MENU, True)

print("\n[R8] 产品源码去掉 guarded 拦截（等同修复前）→ 源码锚定必须变红")
case("R8 源码锚定捕获守卫缺失", WMAP,
     "if not guarded and not _busy and not _any_ui_open():",
     "if not _busy and not _any_ui_open():",
     MENU, True)

print("\n[R8a] 假阳性对照：改一处无关 world_map 代码 → 锁必须仍绿")
case("R8a 无关改动不误报", WMAP,
     "const WHEEL_RETURN_GUARD_FRAMES := 8",
     "const WHEEL_RETURN_GUARD_FRAMES := 8   ## 无关注释",
     MENU, False)

# ---------- 汇总 ----------
print("\n" + "=" * 68)
passed = sum(1 for _, ok, _ in results if ok)
print("反向验证结果：%d / %d 通过" % (passed, len(results)))
if passed < len(results):
    print("失败项：")
    for n, ok, d in results:
        if not ok:
            print("  - %s :: %s" % (n, d))
    sys.exit(1)
print("全部通过 ✅（三把锁都会响，且不会误伤）")
