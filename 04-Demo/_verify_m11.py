# -*- coding: utf-8 -*-
"""_verify_m11.py — M11 主线第一章「黄巾之乱184」实装静态校验

覆盖：
  A. MainlineService 服务存在 + 章节标题常量 + 战场记账/章节推进接口
  B. GameState 主线字段（mainline_chapter / mainline_data）+ 存档同步
  C. quests.json 含黄巾主线任务链（mj_hj_01/02/03 + 顺序 next）
  D. encounters.json 含张角决战遭遇（enc_zhangjue_boss）+ 归属中原 + BOSS 张角
  E. dialogues.json 含第一章引导链 / 章末旁白（intro→intro_guide→intro_goals 发 mj_hj_01 / mj_ch1_end）
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
for tit in ("黄巾之乱", "董卓之乱", "群雄割据", "官渡之战", "赤壁之战", "三分鼎立", "星落五丈原"):
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
print("== E. dialogues.json 第一章引导链 / 章末旁白 ==")
dlog = read_text(os.path.join(DATA, "dialogues.json"))
# 原 mj_ch1_guide 为 orphan 死节点（无 next/action 触发），已在批次 G 清理；
# 其功能由开场链 intro→intro_guide→intro_goals 接管，intro_goals 末端发放第一章主任务 mj_hj_01。
check('"intro_goals"' in dlog, "对话含 intro_goals（第一章引导收尾节点）")
check("accept_quest:mj_hj_01" in dlog, "开场链 intro_goals 发放第一章主任务 mj_hj_01")
check("mj_ch1_end" in dlog, "对话含 mj_ch1_end（章末旁白）")

print("")
print("== F. 接线：battle 记主线 + world_map 播章末旁白 ==")
bs = read_text(os.path.join(HERE, "scripts", "battle", "battle_scene.gd"))
check("MainlineService.on_battle_win(qtarget)" in bs, "battle_scene 胜利后调用 MainlineService.on_battle_win")
wm = read_text(os.path.join(HERE, "scripts", "world", "world_map.gd"))
check("MainlineService.consume_ch1_end_pending()" in wm, "world_map 检测章末旁白标记")
check('_queue_narration("mj_ch1_end"' in wm, "world_map 排队播放 mj_ch1_end 章末旁白")
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
print("")
print("== H. 多结局分支分流（2026-09-28 收尾） ==")
# H1. 四条新结局节点存在（dialogues.json）
djson = load_json("dialogues.json")
dids = {str(n.get("id", "")) for n in djson}
for nid in ("mj_finale_emperor", "mj_finale_han", "mj_finale_hegemon", "mj_finale_hermit"):
    check(nid in dids, "dialogues.json 含结局节点 %s" % nid)

# H2. mainline_service 解析函数 + 常量定义
check("static func ending_node_id() -> String" in ms, "MainlineService 含 ending_node_id()")
check("static func ending_summary() -> String" in ms, "MainlineService 含 ending_summary()")
check("static func player_city_ratio() -> float" in ms, "MainlineService 含 player_city_ratio()")
check("static func player_owned_city_count() -> int" in ms, "MainlineService 含 player_owned_city_count()")
for c in ("HAN_FACTION_ID := 2", "HEGEMON_RATIO := 0.8", "HERMIT_FAME := 80", "TOTAL_CITIES := 110"):
    check(c in ms, "MainlineService 含常量 %s" % c)

# H3. 接线：world_map 播 ending_node_id；story_director 吐 ending_summary
check("MainlineService.ending_node_id()" in wm, "world_map 结局播片改用 ending_node_id()")
sd = read_text(os.path.join(HERE, "scripts", "autoload", "story_director.gd"))
check("MainlineService.ending_summary()" in sd, "story_director 结局吐司改用 ending_summary()")

# H4. Python 独立复算优先级（与 GDScript 同构，抓设计/优先级缺陷）
TOTAL = len(cities)  # 110，与 mainline_service.TOTAL_CITIES 一致


def py_ending(is_self_rule, affiliation, fame, owned_count):
    if is_self_rule:
        return "mj_finale_emperor"
    if affiliation == 2:
        return "mj_finale_han"
    if owned_count / float(TOTAL) >= 0.8:
        return "mj_finale_hegemon"
    if affiliation == 0 and fame >= 80:
        return "mj_finale_hermit"
    return "mj_finale"


check(TOTAL == 110, "全国总城数复算=110（与 TOTAL_CITIES 一致）")
cases = [
    # (is_self_rule, affiliation, fame, owned_count) -> 期望节点
    (True, 0, 0, 110, "mj_finale_emperor"),     # 自立称帝优先于一切
    (False, 2, 0, 0, "mj_finale_han"),          # 效忠汉室
    (False, 2, 90, 110, "mj_finale_han"),       # 汉室忠臣占全图→仍走汉室（优先于霸业）
    (False, 16, 0, 99, "mj_finale_hegemon"),    # 占城 99/110=0.9→霸业
    (False, 0, 90, 0, "mj_finale_hermit"),      # 自由人高名声→归隐
    (False, 0, 10, 0, "mj_finale"),             # 普通自由人→三分归晋默认
    (False, 16, 90, 0, "mj_finale"),            # 非汉投靠+高名声但未占图→默认（归隐需 affiliation==0）
]
for (sr, aff, fame, owned, exp) in cases:
    got = py_ending(sr, aff, fame, owned)
    check(got == exp,
          "优先级复算 (sr=%s,aff=%d,fame=%d,owned=%d)→%s" % (sr, aff, fame, owned, got))

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
