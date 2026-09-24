# -*- coding: utf-8 -*-
"""遗留章节收尾：为 10 个无接取入口的支线/羁绊任务补入口（2026-09-24）。
分配：行脚商人(垂钓/海商)、朝廷使者(官渡间客)、御史(五斗米)、祠堂老者(华佗)、
刘备(翼德横矛)、祝融夫人(祝融烈火)、孟获(南蛮归心)、曹操(为曹取徐州)、
新 NPC 蜀道驿丞@梓潼(蜀道险峰)。幂等。
"""
import json, io, os

BASE = os.path.join(os.path.dirname(__file__), "assets", "data")

def load(name):
    with io.open(os.path.join(BASE, name), encoding="utf-8") as f:
        return json.load(f)

def save(name, data):
    with io.open(os.path.join(BASE, name), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write("\n")

# 1) 新 NPC：蜀道驿丞 @ 梓潼
npcs = load("npcs.json")
nl = npcs["npcs"] if isinstance(npcs, dict) else npcs
if not any(n.get("id") == "npc_yicheng" for n in nl):
    nl.append({
        "id": "npc_yicheng", "name": "蜀道驿丞", "title": "梓潼 · 驿丞",
        "npc_type": "resident", "tags": ["story", "quest_giver"],
        "position": [0, 0], "region": "", "color": "#7A6A5A",
        "dialogue_root": "yicheng_intro",
        "description": "守了一辈子金牛道驿站的老驿丞，闭着眼都知道哪段路塌过方。",
        "lore": "蜀道之难，难于上青天。剑阁天险，一夫当关——可再险的路，也是人走出来的。",
        "city_id": "scene_26",
    })
save("npcs.json", npcs)
print("npcs: yicheng ok")

# 2) 对话：新驿丞对话 + 既有对话插接取选项
dialogues = load("dialogues.json")
dl = dialogues["dialogues"] if isinstance(dialogues, dict) else dialogues
have_d = {d.get("id") for d in dl}
n_d = 0

if "yicheng_intro" not in have_d:
    dl.append({
        "id": "yicheng_intro", "speaker": "蜀道驿丞",
        "lines": [
            "（老驿丞眯眼打量）军爷要过金牛道？先听老朽一句：剑阁栈道年久失修，山贼据险劫道。",
            "大军若要入蜀，得先有人探明梓潼关隘一线的虚实。"],
        "options": [
            {"text": "愿为大军探路", "next": "", "action": "accept_quest:br_shudao",
             "require": {"min_chapter": 6}},
            {"text": "蜀道究竟多险？", "next": "yicheng_lore"},
            {"text": "告辞", "next": ""},
        ],
    })
    dl.append({
        "id": "yicheng_lore", "speaker": "蜀道驿丞",
        "lines": [
            "「蜀道之难，难于上青天」——剑阁天险，一夫当关，万夫莫开。",
            "可再险的路，也是人走出来的。老朽守了四十年驿，看着它塌了修、修了塌。"],
        "options": [{"text": "（告退）", "next": "yicheng_intro"}],
    })
    n_d += 1

INSERTS = [
    ("traveler_intro", 2, {"text": "滇池边有何营生？", "next": "",
        "action": "accept_quest:life_fishing"}),
    ("traveler_intro", 2, {"text": "会稽海商之事，愿效劳", "next": "",
        "action": "accept_quest:br_huizhou", "require": {"min_chapter": 3}}),
    ("han_envoy_intro", 2, {"text": "官渡军情，愿为朝廷效力", "next": "",
        "action": "accept_quest:br_guandu", "require": {"min_chapter": 4}}),
    ("yushi_intro", 1, {"text": "五斗米义仓之事，愿效劳", "next": "",
        "action": "accept_quest:br_hanzhong", "require": {"min_chapter": 3}}),
    ("temple_elder_intro", 1, {"text": "华佗神医有何托付？", "next": "",
        "action": "accept_quest:hi_huatuo"}),
    ("liubei_intro", 1, {"text": "愿识翼德将军之勇", "next": "",
        "action": "accept_quest:2002", "require": {"min_chapter": 5}}),
    ("zhurong_intro", 3, {"text": "愿领教夫人飞刀之术", "next": "",
        "action": "accept_quest:2007", "require": {"min_chapter": 7}}),
    ("menghuo_intro", 2, {"text": "（七纵之后）大王可有归附之意？", "next": "",
        "action": "accept_quest:2006", "require": {"min_chapter": 7}}),
    ("caocao_intro", 4, {"text": "愿为明公取徐州", "next": "",
        "action": "accept_quest:fa_caoxu", "require": {"min_chapter": 3}}),
]
for did, pos, option in INSERTS:
    for d in dl:
        if d.get("id") != did:
            continue
        dup = any(str(o.get("action", "")) == option["action"] for o in d.get("options", []))
        if dup:
            continue
        pos2 = min(pos, len(d["options"]))
        d["options"].insert(pos2, option)
        n_d += 1
save("dialogues.json", dialogues)
print("dialogues: %d inserts" % n_d)
print("ENTRY DONE")
