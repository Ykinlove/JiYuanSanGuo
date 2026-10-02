# -*- coding: utf-8 -*-
"""四十一轮 UI 音效包 静态复核（合成器/路径分派/全局接线/空桩守卫）"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
SYN = os.path.join(ROOT, "scripts", "audio", "ui_sfx_synth.gd")
AM = os.path.join(ROOT, "scripts", "autoload", "audio_manager.gd")
THEME = os.path.join(ROOT, "scripts", "ui", "ui_theme.gd")
CITY = os.path.join(ROOT, "scripts", "city", "city_scene.gd")
PROBE_GD = os.path.join(ROOT, "tests", "ui_sfx_probe.gd")
PROBE_TSCN = os.path.join(ROOT, "tests", "ui_sfx_probe.tscn")

passes, fails = [], []


def check(name, cond):
    if cond:
        passes.append(name)
    else:
        fails.append(name)


def read(p):
    if not os.path.exists(p):
        return ""
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


syn = read(SYN)
am = read(AM)
theme = read(THEME)
city = read(CITY)
probe = read(PROBE_GD)

# ---- A. 合成器 ----
check("A1 UiSfxSynth 在位并注册", os.path.exists(SYN) and "class_name UiSfxSynth" in syn)
check("A2 四条音色（按钮/面板开/面板合/铜钱）",
      all(("static func %s(" % n) in syn for n in ["tap", "panel_open", "panel_close", "coins"]))
check("A3 采样率与占位音一致（22050）",
      "const SR := 22050" in syn and "PLACEHOLDER_MIX_RATE := 22050" in am)
check("A4 UI 音够短（≤0.4s：tap 55ms / 开 300ms / 合 240ms / 钱 340ms）",
      "sr * 0.055" in syn and "sr * 0.30" in syn and "sr * 0.24" in syn and "total := 0.34" in syn)
check("A5 首尾淡入淡出（防爆 click）",
      "0.002)" in syn and "0.008)" in syn and "from_end < fade_out" in syn)
# 【顺序坑】先淡后减均值：先减均值再淡，两端不对称衰减会把直流带回来（实测 tap 1.3e-3）
check("A6 去直流在淡入淡出之后（顺序不能反）",
      syn.index("var mean := sum") > syn.index("from_end < fade_out"))
# 【按源码字面切段的老坑】注释里也写了 loop_mode（说明为何不设），只禁「赋值」
check("A7 编码不循环（短音循环=嗡鸣）",
      "loop_mode =" not in syn and "loop_mode=" not in syn)
check("A8 峰值留叠加余量（≤0.6，UI 音会连点叠加）",
      all(float(v) <= 0.6 for v in re.findall(r"PEAK_\w+ := ([0-9.]+)", syn)))

# ---- B. 路径分派 ----
check("B1 ui_ 前缀归一（旧实现全掉进 other 万能音）",
      '"ui_click": "click"' in am and '"ui_panel_open": "panel_open"' in am
      and '"ui_panel_close": "panel_close"' in am)
check("B2 面板开合分支接进占位合成器",
      '"panel_open":' in am and "UiSfxSynth.panel_open()" in am
      and '"panel_close":' in am and "UiSfxSynth.panel_close()" in am)
check("B3 按钮音/铜钱音走新合成器",
      "UiSfxSynth.tap()" in am and "UiSfxSynth.coins()" in am)
check("B4 AudioManager 对外封装齐（ui_click/ui_panel_open/ui_panel_close）",
      all(("func %s() -> void" % n) in am for n in ["ui_click", "ui_panel_open", "ui_panel_close"]))

# ---- C. 全局接线 ----
check("C1 按钮工厂自带按键音（全工程一处覆盖）",
      'b.pressed.connect(AudioManager.ui_click)' in theme)
# style_button() 是"给已有按钮补套样式"，可被调用多次 → 挂那里会一次点击播 N 声
_sb = theme[theme.index("static func style_button"):theme.index("# ================= 样式盒")]
check("C2 只挂工厂、不挂 style_button（后者可多次调用→叠 N 声）",
      "pressed.connect" not in _sb and "b.pressed.connect" in theme)
check("C3 make_modal / make_sub_modal 绑定面板音",
      theme.count("_bind_panel_sound(owner)") >= 2)
check("C4 绑 owner 的 visible 翻转（子节点 visibility_changed 不触发）",
      "panel.visibility_changed.connect" in theme and "is_visible_in_tree" in theme)
check("C5 meta 去重（防重建时连 N 次）",
      'has_meta("ui_panel_sfx")' in theme and 'set_meta("ui_panel_sfx", true)' in theme)
check("C6 城内面板开合改用开合音（原用点击/取消音，语义不符）",
      "AudioManager.ui_panel_open()" in city and "AudioManager.ui_panel_close()" in city)

# ---- D. 空桩守卫 ----
check("D1 _stream_usable 存在且被 _resolve_stream 调用",
      "static func _stream_usable" in am and "_stream_usable(real as AudioStream)" in am)
check("D2 判据是时长 >0.01s（不误杀真音）", "len_sec > 0.01" in am)

# ---- E. 取证 ----
check("E1 探针在位（含 UISFX DONE 终点）",
      os.path.exists(PROBE_GD) and os.path.exists(PROBE_TSCN) and "UISFX DONE" in probe)
check("E2 探针覆盖七组断言",
      all(k in probe for k in ["ok_peak", "ok_dc", "ok_edge", "ok_enc",
                               "ok_kind", "ok_stream", "ok_usable", "ok_btn"]))

print("PASS %d / FAIL %d" % (len(passes), len(fails)))
for p in passes:
    print("  [PASS]", p)
for f in fails:
    print("  [FAIL]", f)
sys.exit(1 if fails else 0)
