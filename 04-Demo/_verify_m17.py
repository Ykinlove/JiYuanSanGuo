# -*- coding: utf-8 -*-
"""_verify_m17.py — M16 系统优化衔接 + M17 性能基线 静态校验

覆盖：
  M16 系统优化：
   A. 规则层服务齐全（Mainline/Faction/SelfRule/Diplomacy/AI/Region/Quest/CombatFeel）
   B. 主线闭环衔接接线（intro 开场 / 章末旁白 mj_ch1_end / 主菜单自立入口）
   C. 数值与手感边界封装在 service 层（UI/场景不内联）：
      · 自立阈值 SelfRuleService.SELF_RULE_THRESHOLD
      · 打击感参数 CombatFeelService（combat.json.feel）→ battle_scene 只取参不写值
  M17 性能基线：
   D. 低端机渲染/纹理/帧率：gl_compatibility 双渲染器 + ETC2/ASTC + max_fps 上限 + 1920x1080
   E. 特效预算：Compatibility 下不得使用 GPU 粒子（仅 CPU/几何特效）
   F. 分区加载：区域窗口控制单区域同屏规模
"""
import io
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "assets", "data")
errors = []
warns = []


def check(cond, msg):
    if cond:
        print("  [PASS] " + msg)
    else:
        errors.append(msg)
        print("  [FAIL] " + msg)


def read_text(p):
    with io.open(p, encoding="utf-8") as f:
        return f.read()


def read_json(name):
    with io.open(os.path.join(DATA, name), encoding="utf-8") as f:
        return json.load(f)


svc = os.path.join(HERE, "scripts", "services")
print("== M16-A. 规则层服务齐全 ==")
for s in ("mainline_service.gd", "faction_service.gd", "self_rule_service.gd",
          "diplomacy_service.gd", "ai_service.gd", "region_service.gd",
          "quest_service.gd", "combat_feel_service.gd"):
    check(os.path.exists(os.path.join(svc, s)), "服务存在 %s" % s)

print("")
print("== M16-B. 主线闭环衔接接线 ==")
wm = read_text(os.path.join(HERE, "scripts", "world", "world_map.gd"))
check('_start_dialogue_by_id("intro")' in wm, "world_map 有 intro 开场剧本")
check('_start_dialogue_by_id("mj_ch1_end")' in wm, "world_map 有黄巾章末旁白")
check('"self_rule"' in wm and "_self_rule.open" in wm, "world_map 有自立入口接线")
mw = read_text(os.path.join(HERE, "scripts", "ui", "main_menu_wheel.gd"))
check('"self_rule"' in mw, "主菜单含自立项（完整主线可推进）")

print("")
print("== M16-C. 数值/手感边界封装（service 层） ==")
sr = read_text(os.path.join(svc, "self_rule_service.gd"))
check("SELF_RULE_THRESHOLD := 160" in sr, "自立阈值走 SelfRuleService（未内联 UI）")

feelsvc = read_text(os.path.join(svc, "combat_feel_service.gd"))
check("class_name CombatFeelService" in feelsvc, "打击感服务已声明 class_name")
check("static func hitstop(" in feelsvc and "static func shake(" in feelsvc,
      "打击感提供 hitstop/shake 纯函数")

combat = read_json("combat.json")
feel = combat.get("feel", {})
ck = json.dumps(combat, ensure_ascii=False)
check(bool(feel), "combat.json 含 feel 段（打击感参数外置）")
for k in ("hitstop_light", "hitstop_heavy", "hitstop_ultimate",
          "shake_light", "shake_heavy", "shake_ultimate", "time_scale_on_hit"):
    check(k in feel, "combat.json.feel.%s 已定义" % k)
check("counter" in ck or "克制" in ck, "combat.json 含兵种克制数值骨架")

bs = read_text(os.path.join(HERE, "scripts", "battle", "battle_scene.gd"))
check("CombatFeelService.feedback" in bs, "battle_scene 经服务取手感参数（不内联）")
check("Engine.time_scale" in bs, "顿帧走 Engine.time_scale")
check("func _exit_tree()" in bs and "Engine.time_scale = 1.0" in bs,
      "离开战斗复位 time_scale（防全局卡慢）")
for kind in ("KIND_LIGHT", "KIND_HEAVY", "KIND_ULTIMATE"):
    check("CombatFeelService." + kind in bs, "battle_scene 接线档位 %s" % kind)

print("")
print("== M17-D. 低端机渲染/纹理/帧率基线（对照 M8） ==")
pg = read_text(os.path.join(HERE, "project.godot"))
check('renderer/rendering_method="gl_compatibility"' in pg
      and 'renderer/rendering_method.mobile="gl_compatibility"' in pg,
      "桌面+移动均为 gl_compatibility（低端安卓 GLES3 基线）")
check("import_etc2_astc=true" in pg, "ETC2/ASTC 纹理压缩已开启")
check("run/max_fps=60" in pg, "帧率上限 60（低端机控温/省电）")
check("window/size/viewport_width=1920" in pg and "window/size/viewport_height=1080" in pg,
      "设计分辨率 1920x1080 横屏")

print("")
print("== M17-E. 特效预算：Compatibility 用 CPU 粒子 ==")
gpu_used = []
for dp, _d, fs in os.walk(os.path.join(HERE, "scripts")):
    for f in fs:
        if f.endswith(".gd"):
            txt = read_text(os.path.join(dp, f))
            if "GPUParticles2D" in txt or "GPUParticles3D" in txt:
                gpu_used.append(f)
check(not gpu_used, "未使用 GPU 粒子（Compatibility 兼容；违规：%s）" % (gpu_used or "无"))

print("")
print("== M17-F. 分区加载：区域窗口控制单区域规模 ==")
check("RegionService.region_rect" in wm, "world_map 用区域窗口（RegionService）锁定单区域")
enc = read_text(os.path.join(HERE, "scripts", "world", "encounter_manager.gd"))
check("GameState.current_region" in enc, "遭遇按当前区域生成（单区域敌人规模受控）")

print("")
print("=" * 66)
if errors:
    print("[FAIL] M16/M17 校验失败 %d 项" % len(errors))
    for e in errors:
        print("  - " + e)
    raise SystemExit(1)
print("M16 系统优化 + M17 性能基线 校验通过 ✅ (warns=%d)" % len(warns))
for w in warns:
    print("  - " + w)
