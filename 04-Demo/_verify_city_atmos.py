# -*- coding: utf-8 -*-
"""城内场景氛围（方向①）· 接线静态复核（2026-09-30 第七轮）

防止后人改回「城内无粒子 / 相机死板」：

  A1 _build_city_atmos 已实现，且用 CPUParticles2D（非 GPU，Compatibility 下 GPU 静默失效）
  A2 氛围层挂到 _interior（与玩家同父），并插在 _player 之前（背景之上、单位之下）
  A3 _build_city_atmos 在 _build_interior 中调用（进了城内就会构建）
  A4 相机待机微动：叠加在 cam.offset，不破坏硬跟随（不写 cam.position）
  A5 硬跟随未被动：cam.position_smoothing_enabled = false 仍在
  A6 氛围常量齐全（4 个粒子 + 4 个微动），且微动用正弦函数而非随机抖
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = HERE
SRC = os.path.join(ROOT, "scripts", "city", "city_scene.gd")

results = []


def check(name, ok, detail):
    results.append((name, ok, detail))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def func_body(src, sig):
    i = src.find(sig)
    if i < 0:
        return ""
    j = src.find("\nfunc ", i + 1)
    if j < 0:
        j = len(src)
    return src[i:j]


print("=" * 68)
print("城内氛围 · 接线静态复核")
print("=" * 68)

src = read(SRC)

# ---------- A1 氛围构建 + 纯 CPU 粒子 ----------
print("\n[A1] _build_city_atmos 实现")
ba = func_body(src, "func _build_city_atmos() -> void:")
check("_build_city_atmos 已实现", bool(ba), "已定义")
check("用 CPUParticles2D（非 GPU）",
      "CPUParticles2D.new()" in ba and "GPUParticles2D" not in ba, "纯 CPU 粒子")
check("扬尘 + 灯火两类粒子均存在",
      "GroundDust" in ba and "Lamp_" in ba, "地面扬尘 / 建筑灯火")

# ---------- A2 层级正确 ----------
print("\n[A2] 氛围层层级")
check("氛围层挂到 _interior（与玩家同父）",
      "_interior.add_child(_atmos)" in ba, "不挂到根 Control")
check("插在 _player 之前（背景之上、单位之下）",
      "move_child(_atmos, _player.get_index())" in ba, "树序保证层级")

# ---------- A3 接线 ----------
print("\n[A3] _build_interior 调用")
bi = func_body(src, "func _build_interior() -> void:")
check("_build_city_atmos 在 _build_interior 中调用",
      "_build_city_atmos()" in bi, "进城即构建")
check("相机引用已保存（_city_cam = cam）",
      "_city_cam = cam" in bi, "供微动使用")

# ---------- A4 相机微动不破坏硬跟随 ----------
print("\n[A4] 相机待机微动")
pr = func_body(src, "func _process(_delta: float) -> void:")
check("微动叠加在 cam.offset（而非 position）",
      "_city_cam.offset =" in pr, "不影响锁定主角的跟随")
check("相位累加用 delta（帧率无关）",
      "_city_cam_t += _delta" in pr, "不依赖被 time_scale 缩放的 delta")
check("微动用正弦/余弦平滑曲线（非随机抖）",
      "sin(_city_cam_t" in pr and "cos(_city_cam_t" in pr, "缓动而非抽搐")

# ---------- A5 硬跟随未被动 ----------
print("\n[A5] 硬跟随保全")
check("cam.position_smoothing_enabled = false 仍在",
      "cam.position_smoothing_enabled = false" in bi, "硬跟随不被微动覆盖")

# ---------- A6 常量齐全 ----------
print("\n[A6] 氛围常量")
need = ["CITY_ATMOS_DUST_AMOUNT", "CITY_ATMOS_DUST_ALPHA",
        "CITY_ATMOS_LAMP_AMOUNT", "CITY_ATMOS_LAMP_ALPHA",
        "CITY_CAM_SWAY_AMP_X", "CITY_CAM_SWAY_AMP_Y",
        "CITY_CAM_SWAY_FREQ_X", "CITY_CAM_SWAY_FREQ_Y"]
missing = [k for k in need if k not in src]
check("8 个氛围常量齐全", not missing, "缺失：%s" % (missing or "无"))

# ---------- 汇总 ----------
print("\n" + "=" * 68)
passed = sum(1 for _, ok, _ in results if ok)
print("复核结果：%d / %d 通过" % (passed, len(results)))
if passed < len(results):
    print("失败项：")
    for n, ok, d in results:
        if not ok:
            print("  - " + n + " :: " + d)
    sys.exit(1)
print("全部通过 ✅")
print("=" * 68)
