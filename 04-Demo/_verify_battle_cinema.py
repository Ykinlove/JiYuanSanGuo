# -*- coding: utf-8 -*-
"""战斗 镜头语言 + 战场氛围 + BGM 战况三态 · 接线静态复核（2026-09-30 第四轮续）

运行时探针（probe_runner 第 ⑦ 组）验实件存在；本脚本补源码接线复核，
防止后人改回「固定相机 / 硬编码背景 / 单 BGM」：

  C1 镜头推近：_cam_punch 已实现，且开战/大招/击杀三处接线
  C2 击杀特写：_director.unit_removed 已连 _on_unit_removed（含短慢镜）
  C3 结算复位：_play_finish_transition 收回镜头推近
  C4 战场氛围：_build_battle_atmos 用 CPUParticles2D（非 GPU）+ 插在 Player 之前
  C5 BGM 三态：准备/交战/胜利 三处切曲，路径走 CombatFeelService（不硬编码）
  C6 feel 段键齐全 + CombatFeelService 暴露齐全
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = HERE
SRC = os.path.join(ROOT, "scripts", "battle", "battle_scene.gd")
SERVICE = os.path.join(ROOT, "scripts", "services", "combat_feel_service.gd")
CFG_PATH = os.path.join(ROOT, "assets", "data", "combat.json")

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
print("战斗 镜头/氛围/BGM · 接线静态复核")
print("=" * 68)

src = read(SRC)
svc = read(SERVICE)
cfg = json.load(open(CFG_PATH, "r", encoding="utf-8"))
feel = cfg.get("feel", {})

# ---------- C1 镜头推近 ----------
print("\n[C1] 镜头推近 _cam_punch")
check("_cam_punch 函数已实现",
      bool(re.search(r"func _cam_punch\(", src)), "已定义")
check("开战横幅处推近（_begin_battle）",
      "_cam_punch(CombatFeelService.cam_zoom(\"begin\")" in func_body(src, "func _begin_battle()"),
      "开战镜头一紧")
check("大招处推近（_on_skill）",
      "_cam_punch(CombatFeelService.cam_zoom(\"skill\")" in func_body(src, "func _on_skill()"),
      "大招重推近")
check("推近用独立 tween（不碰 _shake 的 offset）",
      "_cam_tween" in src and "create_tween()" in func_body(src, "func _cam_punch("),
      "zoom/position 走 _cam_tween")
check("推近焦点居中且 clamp（不露世界外黑边）",
      "clampf(pan.x" in func_body(src, "func _cam_punch(")
      and "clampf(pan.y" in func_body(src, "func _cam_punch("), "焦点居中")

# ---------- C2 击杀特写 ----------
print("\n[C2] 击杀特写（unit_removed）")
check("_on_unit_removed 已连接",
      "_director.unit_removed.connect(_on_unit_removed)" in src, "击杀/溃散触发")
check("_on_unit_removed 已实现",
      bool(re.search(r"func _on_unit_removed\(unit: BattleUnit\)", src)), "已定义")
cb = func_body(src, "func _on_unit_removed(unit: BattleUnit)")
check("仅交战中触发特写", "_phase != Phase.FIGHTING" in cb, "结算阶段不推近")
check("击杀特写推近到阵亡单位", "_cam_punch(CombatFeelService.cam_zoom(\"kill\")" in cb,
      "焦点 = unit.position")
check("短慢镜复用 _hitstop_end_ms 还原",
      "Engine.time_scale = slow" in cb and "_hitstop_end_ms" in cb,
      "不另起慢镜机制")

# ---------- C3 结算复位 ----------
print("\n[C3] 结算收回镜头推近")
ft = func_body(src, "func _play_finish_transition()")
check("结算前收回推近（zoom/position 归位）",
      "_cam.zoom = Vector2.ONE" in ft and "_cam.position = Vector2.ZERO" in ft,
      "特写不残留到结算画面")

# ---------- C4 战场氛围 ----------
print("\n[C4] 战场氛围（CPUParticles2D）")
ba = func_body(src, "func _build_battle_atmos()")
check("_build_battle_atmos 已实现", bool(ba), "已定义")
check("用 CPUParticles2D（非 GPU，Compatibility 下 GPU 静默失效）",
      "CPUParticles2D.new()" in ba and "GPUParticles2D" not in ba, "纯 CPU 粒子")
check("氛围层插在 Player 之前（背景之上、单位之下）",
      "move_child(_atmos, $Player.get_index())" in ba, "树序保证层级")
check("_build_battle_atmos 在 _setup_background 中调用",
      "_build_battle_atmos()" in func_body(src, "func _setup_background()"), "已接线")
check("扬尘粒子数取自配置", "CombatFeelService.atmos_dust_amount()" in ba, "不内联")
check("扬尘/烟雾透明度取自配置",
      "atmos_dust_alpha()" in ba and "atmos_fog_alpha()" in ba, "不内联")

# ---------- C5 BGM 战况三态 ----------
print("\n[C5] BGM 战况三态")
ready = func_body(src, "func _ready()")
check("准备阶段播铺垫曲（bgm_prepare，非硬编码 battle.ogg）",
      "AudioManager.play_bgm(CombatFeelService.bgm_prepare())" in ready
      and 'play_bgm("res://assets/audio/bgm/battle.ogg")' not in ready, "formation 曲")
check("开战切交战曲（bgm_fight）",
      "AudioManager.play_bgm(CombatFeelService.bgm_fight())" in func_body(src, "func _begin_battle()"),
      "battle 曲")
check("胜利切胜利曲（bgm_win）",
      "AudioManager.play_bgm(CombatFeelService.bgm_win())" in func_body(src, "func _on_battle_finished("),
      "victory 曲")

# ---------- C6 配置键 + 服务暴露 ----------
print("\n[C6] feel 段键 + CombatFeelService 暴露")
need_keys = ["cam_zoom_begin", "cam_zoom_skill", "cam_zoom_kill", "cam_zoom_defeat", "cam_punch_in",
             "cam_punch_out", "cam_kill_slow", "cam_kill_slow_time",
             "atmos_dust_amount", "atmos_dust_alpha", "atmos_fog_alpha",
             "bgm_prepare", "bgm_fight", "bgm_win"]
missing = [k for k in need_keys if k not in feel]
check("feel 段新增键齐全（%d 项）" % len(need_keys), not missing, "缺失：%s" % (missing or "无"))
check("推近倍率均 ≥ 1.0", all(float(feel.get(k, 1.0)) >= 1.0 for k in
      ["cam_zoom_begin", "cam_zoom_skill", "cam_zoom_kill", "cam_zoom_defeat"]), "begin/skill/kill/defeat")
check("慢镜 time_scale 在 (0,1)", all(0.0 < float(feel.get(k, 0)) < 1.0 for k in
      ["cam_kill_slow"]), "%.2f" % float(feel.get("cam_kill_slow", 0)))
check("BGM 三态路径非空", all(str(feel.get(k, "")).strip() != "" for k in
      ["bgm_prepare", "bgm_fight", "bgm_win"]), "prepare/fight/win")

need_fns = ["cam_zoom", "cam_punch_in", "cam_punch_out", "cam_kill_slow",
            "cam_kill_slow_time", "atmos_dust_amount", "atmos_dust_alpha",
            "atmos_fog_alpha", "bgm_prepare", "bgm_fight", "bgm_win"]
for fn in need_fns:
    check("CombatFeelService 暴露 %s()" % fn,
          bool(re.search(r"static func %s\(" % fn, svc)), "已定义")

# ---------- C7 败北演出（2026-09-30 第六轮）----------
print("\n[C7] 败北演出（与胜利侧对称）")
fb = func_body(src, "func _on_battle_finished(")
check("败北横幅（暗红 _banner 调用）",
      '_banner("败' in fb and "Color(0.86" in fb, "败北仪式感")
check("败北推主角镜头（_cam_punch + cam_zoom(\"defeat\")）",
      '_cam_punch(CombatFeelService.cam_zoom("defeat")' in fb, "推近主角")
check("败北战乐淡出收束（stop_bgm）",
      "AudioManager.stop_bgm(true)" in fb, "无 defeat 曲则停战乐")
check("feel 段含 cam_zoom_defeat", "cam_zoom_defeat" in feel, "中近景倍率")
check("CombatFeelService 暴露 cam_zoom(\"defeat\")",
      'return maxf(1.0, _num("cam_zoom_defeat"))' in svc, "读取函数")

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
