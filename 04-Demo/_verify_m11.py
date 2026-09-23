# -*- coding: utf-8 -*-
"""_verify_m11.py — M11 主线第一章「黄巾之乱184」实装静态校验

覆盖：
  A. MainlineService 服务存在 + 章节标题常量 + 战场记账/章节推进接口
  B. GameState 主线字段（mainline_chapter / mainline_data）+ 存档同步
  C. quests.json 含黄巾主线任务链（mj_hj_01/02/03 + 顺序 next）
  D. encounters.json 含张角决战遭遇（enc_zhangjue_boss）+ 归属中原 + BOSS 张角
  E. dialogues.json 含第一章引导 / 章末旁白（mj_ch1_guide / mj_ch1_end）
  F. 接线：battle_scene 记主线 + world_map 播章末旁白
  G. 引用闭合：张角(id358)在 heroes6、许昌(scene_21)/汝南(scene_33)在 cities
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


def load_json(name):
    with io.open(os.path.join(DATA, name), encoding="utf-8") as f:
        return json.load(f)


print("== A. MainlineService 主线规则层 ==")
ms = read_text(os.path.join(HERE, "scripts", "services", "mainline_service.gd"))
check(os.path.exists(os.path.join(HERE, "scripts", "services", "mainline_service.gd")),
      "mainline_service.gd 存在")
check("class_name MainlineService" in ms and "extends RefCounted" in ms,
      "class_name MainlineService + extends RefCounted")
for tit in ("黄巾之乱", "董卓之乱", "群雄割据", "官渡之战", "赤壁之战", "三国鼎立", "一统天下"):
    check(tit in ms, "章节标题常量含「%s」" % tit)
check("on_battle_win" in ms and "finalize_ch1_victory" in ms and "advance_chapter" in ms,
      "含 on_battle_win / finalize_ch1_victory / advance_chapter")
check("consume_ch1_end_pending" in ms, "含 consume_ch1_end_pending（章末旁白消耗）")

print("")
print("== B. GameState 主线字段 ==")
gs = read_text(os.path.join(HERE, "scripts", "autoload", "game_state.gd"))
check("var mainline_chapter: int = 1" in gs, "GameState.mainline_chapter 字段（默认1）")
check("var mainline_data: Dictionary = {}" in gs, "GameState.mainline_data 字段")
check('"mainline_chapter": mainline_chapter' in gs and '"mainline_data": mainline_data' in gs,
      "to_dict 序列化两字段")
check('mainline_chapter = int(data.get("mainline_chapter", 1))' in gs and \
      'mainline_data = data.get("mainline_data", {})' in gs, "from_dict 反序列化两字段")
check('mainline_chapter = 1' in gs and 'mainline_data = {}' in gs, "reset 重置两字段")

print("")
print("== C. quests.json 黄巾主线任务链 ==")
quests = load_json("quests.json")
qn = {str(q.get("id", "")): q for q in quests}
check("mj_hj_01" in qn and "mj_hj_02" in qn and "mj_hj_03" in qn,
      "存在 mj_hj_01/02/03 三个主线任务")
if "mj_hj_01" in qn and "mj_hj_02" in qn:
    check(str(qn["mj_hj_01"].get("next", "")) == "mj_hj_02", "mj_hj_01 → mj_hj_02 顺序衔接")
if "mj_hj_02" in qn and "mj_hj_03" in qn:
    check(str(qn["mj_hj_02"].get("next", "")) == "mj_hj_03", "mj_hj_02 → mj_hj_03 顺序衔接")
# 每个主线任务应有 objectives
for qid in ("mj_hj_01", "mj_hj_02", "mj_hj_03"):
    if qid in qn:
        check(bool(qn[qid].get("objectives")) or bool(qn[qid].get("battle_objective")),
              "%s 含 objectives/目标" % qid)

print("")
print("== D. encounters.json 张角决战遭遇 ==")
encs = load_json("encounters.json")
zj = next((e for e in encs if e.get("id") == "enc_zhangjue_boss"), None)
check(zj is not None, "存在 enc_zhangjue_boss 遭遇")
if zj:
    regs = zj.get("regions", [])
    check(regs and ("zhongyuan" in regs or any(r in ("reg_yu", "reg_yan", "china") for r in regs)),
          "张角遭遇归属中原区域 regions=%s" % regs)
    check(zj.get("type") == "battle", "张角遭遇为 battle 类型")
    check(str(zj.get("boss_hero_id", "")) == "358", "张角 BOSS 武将 id=358")
    check(zj.get("quest_target") == "zhangjue_boss", "张角遭遇 quest_target=zhangjue_boss")

print("")
print("== E. dialogues.json 第一章引导/章末旁白 ==")
dlog = read_text(os.path.join(DATA, "dialogues.json"))
check("mj_ch1_guide" in dlog, "对话含 mj_ch1_guide（第一章引导）")
check("mj_ch1_end" in dlog, "对话含 mj_ch1_end（章末旁白）")

print("")
print("== F. 接线：battle 记主线 + world_map 播章末旁白 ==")
bs = read_text(os.path.join(HERE, "scripts", "battle", "battle_scene.gd"))
check("MainlineService.on_battle_win(qtarget)" in bs, "battle_scene 胜利后调用 MainlineService.on_battle_win")
wm = read_text(os.path.join(HERE, "scripts", "world", "world_map.gd"))
check("MainlineService.consume_ch1_end_pending()" in wm, "world_map 检测章末旁白标记")
check('_start_dialogue_by_id("mj_ch1_end")' in wm, "world_map 播放 mj_ch1_end 旁白")
check('_start_dialogue_by_id("intro")' in wm, "world_map 保留开场 intro 播放")

print("")
print("== G. 引用闭合 ==")
heroes = load_json("heroes6.json")
hid = {h.get("id") for h in heroes}
check(358 in hid, "heroes6 含张角 id=358")
cities = load_json("cities.json")
cid = {c.get("id") for c in cities}
check("scene_21" in cid, "cities 含 许昌 scene_21（中原主城）")
check("scene_33" in cid, "cities 含 汝南 scene_33（黄巾波及地）")

print("")
print("=" * 66)
if errors:
    print("[FAIL] M11 校验失败 %d 项" % len(errors))
    for e in errors:
        print("  - " + e)
    raise SystemExit(1)
print("M11 主线第一章黄巾之乱实装校验通过 ✅ (warns=%d)" % len(warns))
for w in warns:
    print("  - " + w)
