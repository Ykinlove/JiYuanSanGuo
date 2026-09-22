# -*- coding: utf-8 -*-
"""_verify_m8.py — M8 安卓导出 / 横屏触屏适配静态校验

覆盖：
  project.godot：横屏、触摸模拟、Compatibility 渲染、ETC2/ASTC、1920x1080 + canvas_items 拉伸
  export_presets.cfg：Android 预设、包名/版本/架构（仅 arm64-v8a）、预制模板、签名、图标、排除设计稿
  触屏：虚拟摇杆在三大循环场景接线，主要交互脚本处理 InputEventScreenTouch
  布局：所有固定面板尺寸在 1920x1080 设计画布内（小屏整体缩放不裁切）
  卫生：无临时探针；预设里不写死本机 keystore 绝对路径
  产物：dist 下存在 debug APK 时做体积校验（缺失只告警不判失败）
"""
import glob
import io
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))


def read(p):
    return io.open(os.path.join(HERE, p), encoding="utf-8").read()


errors = []
warns = []


def check(cond, msg):
    if cond:
        print("  [PASS] " + msg)
    else:
        errors.append(msg)
        print("  [FAIL] " + msg)


def warn(msg):
    warns.append(msg)
    print("  [WARN] " + msg)


print("== A. project.godot 移动端基础设置 ==")
pg = read("project.godot")
# 4.7 实测导出映射（AndroidManifest 值）：4=userLandscape(11 横屏+重力双向)、
# 7=landscape(0 固定横屏)；而 1=portrait(1 竖屏!)、2=reverseLandscape(8)，均不可用
mo = re.search(r"window/handheld/orientation\s*=\s*(\d+)", pg)
ori = int(mo.group(1)) if mo else -1
check(ori in (4, 7),
      "横屏 handheld/orientation=%d（4=userLandscape 重力横屏 / 7=固定 landscape；禁用 1/2 竖屏误值）" % ori)
check('pointing/emulate_touch_from_mouse=true' in pg.replace(" ", ""),
      "开启 emulate_touch_from_mouse（编辑器内可用鼠标调试触屏）")
check('renderer/rendering_method="gl_compatibility"' in pg,
      "桌面渲染器 gl_compatibility（兼容低端安卓 GLES3）")
check('renderer/rendering_method.mobile="gl_compatibility"' in pg,
      "移动渲染器 gl_compatibility")
check("import_etc2_astc=true" in pg, "开启 ETC2/ASTC 纹理压缩（安卓必需）")
check("window/size/viewport_width=1920" in pg and "window/size/viewport_height=1080" in pg,
      "设计分辨率 1920x1080 横屏")
check('window/stretch/mode="canvas_items"' in pg and 'window/stretch/aspect="expand"' in pg,
      "拉伸模式 canvas_items + expand（不同宽高比自适应）")
check(os.path.exists(os.path.join(HERE, "scenes/main/boot.tscn")),
      "主场景 scenes/main/boot.tscn 存在")

print("")
print("== B. export_presets.cfg 安卓预设 ==")
ep = read("export_presets.cfg")
check('platform="Android"' in ep, "存在 Android 导出预设")
m = re.search(r'package/unique_name="([^"]+)"', ep)
check(bool(m) and re.fullmatch(r"[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+", m.group(1) or ""),
      "包名合法（小写反域名）: %s" % (m.group(1) if m else "<缺失>"))
check(re.search(r"version/code=\d+", ep) is not None, "version/code 已设置")
vn = re.search(r'version/name="([^"]+)"', ep)
check(bool(vn and vn.group(1)), "version/name 非空: %s" % (vn.group(1) if vn else "<缺失>"))
check("architectures/arm64-v8a=true" in ep, "导出 arm64-v8a（现代真机主力 ABI）")
for abi in ("armeabi-v7a", "x86", "x86_64"):
    check(("architectures/%s=false" % abi) in ep, "不打 %s（减小 APK 体积）" % abi)
check("gradle_build/use_gradle_build=false" in ep, "使用预制 APK 模板（无需 NDK/Gradle 构建）")
check("package/signed=true" in ep, "启用签名")
check(re.search(r'export_path="[^"]+\.apk"', ep) is not None, "导出路径为 .apk")
check("_preview/*" in ep, "排除 _preview 设计稿目录（不进包）")
for key, path in [
    ("launcher_icons/main_192x192", "assets/icons/launcher_192.png"),
    ("launcher_icons/adaptive_foreground_432x432", "assets/icons/launcher_fg_432.png"),
    ("launcher_icons/adaptive_background_432x432", "assets/icons/launcher_bg_432.png"),
]:
    referenced = ('%s="res://%s"' % (key, path)) in ep
    exists = os.path.exists(os.path.join(HERE, path))
    check(referenced and exists, "图标 %s 已引用且文件存在（%s）" % (key, path))
# keystore 不写死在工程文件里（走编辑器设置/本机 debug.keystore）
check(re.search(r'keystore/(debug|release)="[A-Za-z]:', ep) is None,
      "预设未写死本机 keystore 绝对路径（凭据与工程解耦）")

print("")
print("== C. 触屏交互接线 ==")
joy_tscn = read("scenes/ui/virtual_joystick.tscn")
check("InputEventScreenTouch" in read("scripts/ui/virtual_joystick.gd")
      and "InputEventScreenDrag" in read("scripts/ui/virtual_joystick.gd"),
      "虚拟摇杆处理 ScreenTouch/ScreenDrag")
for scene, label in [("scenes/world/world_map.tscn", "大地图"),
                     ("scenes/battle/battle_scene.tscn", "战场"),
                     ("scenes/city/city_scene.tscn", "城池")]:
    txt = read(scene)
    check("virtual_joystick.tscn" in txt or ("Joy" in txt and label == "城池"),
          "%s 场景放置了虚拟摇杆节点" % label)
for script, label in [("scripts/world/world_map.gd", "大地图"),
                      ("scripts/battle/battle_scene.gd", "战场"),
                      ("scripts/city/city_scene.gd", "城池")]:
    txt = read(script)
    check("GameJoystick" in txt and (".output" in txt or "changed" in txt),
          "%s 脚本读取摇杆输出" % label)
# 主要自定义点击控件同时认触摸（不强制每个都有，只抽关键的）
for script, label in [("scripts/world/world_map.gd", "大地图"),
                      ("scripts/ui/hero_dex.gd", "武将图鉴"),
                      ("scripts/ui/main_menu_wheel.gd", "主菜单轮盘")]:
    check("InputEventScreenTouch" in read(script), "%s 点击处理含 InputEventScreenTouch" % label)

print("")
print("== D. 弹层/面板尺寸在设计画布内（1920x1080，整体缩放） ==")
bad = []
for p in glob.glob(os.path.join(HERE, "scripts", "**", "*.gd"), recursive=True):
    rel = os.path.relpath(p, HERE)
    for i, line in enumerate(read(rel).splitlines(), 1):
        m2 = re.search(r"custom_minimum_size\s*=\s*Vector2\(\s*(\d+)\s*,\s*(\d+)\s*\)", line)
        if m2:
            w, h = int(m2.group(1)), int(m2.group(2))
            if w > 1840 or h > 980:
                bad.append("%s:%d %dx%d" % (rel, i, w, h))
check(not bad, "所有控件最小尺寸 <= 1840x980（留边距，缩放后不裁切）" +
      ("；异常: %s" % bad if bad else ""))
dp = read("scripts/ui/duel_popup.gd")
mw = re.search(r"const PANEL_W\s*:=\s*(\d+(?:\.\d+)?)", dp)
mh = re.search(r"const PANEL_H\s*:=\s*(\d+(?:\.\d+)?)", dp)
pw = float(mw.group(1)) if mw else -1
ph = float(mh.group(1)) if mh else -1
check(0 < pw <= 1840 and 0 < ph <= 980,
      "单挑弹层 %.0fx%.0f，宽高均在 1920x1080 画布内" % (pw, ph))

print("")
print("== E. 卫生 ==")
leftovers = glob.glob(os.path.join(HERE, "_probe_*")) + \
    glob.glob(os.path.join(HERE, "_icon_gen*"))
check(not leftovers, "无临时探针/图标生成脚本残留: %s" % (leftovers or "无"))
check(os.path.exists(os.path.join(HERE, "assets", "icons")), "assets/icons 目录已纳入工程")

print("")
print("== F. 构建产物与环境（信息项，缺失只告警） ==")
apks = glob.glob(os.path.join(HERE, "dist", "*.apk"))
if apks:
    sz = os.path.getsize(apks[0]) / 1024 / 1024
    check(sz > 80.0, "APK 已导出且体积合理（%.1f MB，含 76MB libgodot 调试库）" % sz)
else:
    warn("未发现 dist/*.apk（执行 headless 导出后才有）")
tpl = os.path.join(os.environ.get("APPDATA", ""), "Godot", "export_templates",
                   "4.7.2.stable", "android_debug.apk")
if os.path.exists(tpl):
    print("  [PASS] 本机已装 4.7.2.stable 安卓导出模板")
else:
    warn("本机缺少 4.7.2.stable 导出模板: %s" % tpl)

print("")
if errors:
    print("[FAIL] M8 校验 %d 项未通过：" % len(errors))
    for e in errors:
        print("  - " + e)
    raise SystemExit(1)
print("[OK] M8 安卓导出/触屏适配校验全部通过%s" %
      ("（%d 条告警）" % len(warns) if warns else " ✅"))
