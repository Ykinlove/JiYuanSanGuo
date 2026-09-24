# -*- coding: utf-8 -*-
"""剧本落表后的既有数据欠账修复（2026-09-24）。
修复历史遗留的不可达成目标：无 visit_target 的 reach / 无 NPC 的 give_gold /
quest_target 指向错误的 battle。幂等。
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

# 1) cities.json：补齐旧支线涉及城的 visit_target
cities = load("cities.json")
cl = cities["cities"] if isinstance(cities, dict) else cities
by_scene = {c.get("id"): c for c in cl}
VISIT = {
    "scene_43": "city_jiangxia",  # 江夏
    "scene_47": "city_huiji",     # 会稽
    "scene_26": "city_zitong",    # 梓潼
    "scene_36": "city_lujiang",   # 庐江
    "scene_25": "city_xuzhou",    # 徐州（下邳带）
}
n = 0
for sid, vt in VISIT.items():
    c = by_scene.get(sid)
    if c and not c.get("visit_target"):
        c["visit_target"] = vt
        n += 1
save("cities.json", cities)
print("cities: +%d visit_target" % n)

# 2) quests.json：修不可达目标
quests = load("quests.json")
ql = quests["quests"] if isinstance(quests, dict) else quests
FIX = {
    # 旧支线：高黎贡山为无实体特殊地点 → 改为可达的建宁
    "side_wutugu": [("reach", "ruin_gaoligong", "city_jianning", "抵达建宁，入南中深处寻兀突骨")],
    # 旧分支：海商 NPC 不存在 → 资助对象改为行脚商人（南中大地图真实 NPC）
    "br_huizhou": [("give_gold", "sea_merchant", "npc_traveler", "资助行脚商人 300 金进货")],
    # 旧专属：长坂无城 → 退屯江夏（2002 翼德横矛）
    "2002": [("reach", "city_changban", "city_jiangxia", "长坂退敌，退屯江夏")],
    # 旧专属：卧龙岗无城 → 隆中在襄阳（2004 孔明出山）
    "2004": [("reach", "city_wolong", "city_xiangyang", "隆中茅庐求见")],
    # 旧专属：蛮族遭遇 quest_target 实为 zhu_rong（2006 南蛮归心）
    "2006": [("battle", "enc_tribal_warrior", "zhu_rong", None)],
    # 新主线 ch3_03：山贼遭遇 quest_target 是 bandit
    "ch3_03": [("battle", "enc_bandit", "bandit", None)],
}
nq = 0
for q in ql:
    qid = str(q.get("id", ""))
    if qid not in FIX:
        continue
    for otype, old_t, new_t, new_desc in FIX[qid]:
        for o in q.get("objectives", []):
            if str(o.get("type", "")) == otype and str(o.get("target", "")) == old_t:
                o["target"] = new_t
                if new_desc:
                    o["desc"] = new_desc
                nq += 1
save("quests.json", quests)
print("quests: %d objectives fixed" % nq)

# 3) dialogues.json：行脚商人加资助选项（br_huizhou 联动）
dialogues = load("dialogues.json")
dl = dialogues["dialogues"] if isinstance(dialogues, dict) else dialogues
n_d = 0
for d in dl:
    if d.get("id") != "traveler_intro":
        continue
    has = any("give_gold" in str(o.get("action", "")) for o in d.get("options", []))
    if not has:
        d["options"].insert(1, {
            "text": "资助海商进货（300 金）",
            "next": "traveler_fund",
            "action": "give_gold:300",
            "require": {"quest_active": "br_huizhou", "gold": 300},
        })
        n_d += 1
# traveler_fund 回应节点
have = {x.get("id") for x in dl}
if "traveler_fund" not in have:
    dl.append({
        "id": "traveler_fund",
        "speaker": "行脚商人",
        "lines": [
            "哎哟，客官真是爽快人！这趟去会稽进货，定给客官捎些南来奇珍。",
            "东海明珠、越地丝绸——到时候少不了您的份。"],
        "options": [{"text": "生意兴隆", "next": ""}],
    })
    n_d += 1
save("dialogues.json", dialogues)
print("dialogues: %d changed/added" % n_d)
print("FIX DONE")
