# -*- coding: utf-8 -*-
"""序章重构（去孟获）+ 遗留章节补完（2026-09-24）。
1) main_002「南中之乱」→「北望中原」：长者如半师，去孟获绑定；
2) menghuo 链改 lore-only（孟获留建宁，服务终章 ch7_05 七擒收束）；
3) 补 6 个 NPC 使旧支线/羁绊任务的 talk 目标全部可达；
4) 2001/2003/2005 名将羁绊任务目标修正 + 接取入口（此前完全无入口）。
幂等。
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

# ============================================================
# 1) quests.json：main_002 重构 + 2001/2003/2005 修补
# ============================================================
quests = load("quests.json")
ql = quests["quests"] if isinstance(quests, dict) else quests
n_q = 0
for q in ql:
    qid = str(q.get("id", ""))
    if qid == "main_002":
        q["title"] = "北望中原"
        q["giver_npc"] = ""
        q["description"] = (
            "寨中长者教你武艺、为你讲天下大势，待你如半师。黄巾乱起，他劝你北上投义军"
            "博个出身——临行之前，先替寨子清掉劫道的流寇，再回寨向长者辞行。")
        q["objectives"] = [
            {"type": "battle", "target": "bandit", "count": 2, "desc": "肃清寨外流寇"},
            {"type": "talk", "target": "npc_elder", "count": 1, "desc": "回寨向长者辞行"},
        ]
        q["rewards"] = {"gold": 500, "exp": 200, "fame": 5}
        n_q += 1
    elif qid == "2001":
        # 云长义释：华容之义由曹操感念（吕布式城镇 NPC 不合理；曹操视角最贴华容道）
        for o in q["objectives"]:
            if o.get("type") == "talk" and o.get("target") == "guan_yu":
                o["target"] = "npc_caocao"
                o["desc"] = "向曹操道华容之义"
        q["desc"] = "关羽义薄云天。华容之义，连曹操也感念至今——向曹公道及此事，可得青龙偃月刀之赏识。"
        n_q += 1
    elif qid == "2003":
        # 子龙护主：赵云 NPC 挂襄阳（长坂后随军驻此）；战斗目标改 any 通用「同战」
        for o in q["objectives"]:
            if o.get("type") == "battle" and o.get("target") == "enc_yellow_turban":
                o["target"] = "any"
                o["desc"] = "与子龙同历战阵 ×3"
            if o.get("type") == "talk" and o.get("target") == "zhao_yun":
                o["target"] = "npc_zhao_yu"
                o["desc"] = "与赵云论护主之义"
        n_q += 1
    elif qid == "2005":
        # 奉先无双：吕布 198 年已殁——由白门楼守将（亲见温侯之勇者）转述最合理
        for o in q["objectives"]:
            if o.get("type") == "talk" and o.get("target") == "lu_bu":
                o["target"] = "npc_baimen_warden"
                o["desc"] = "与白门楼守将论吕布之勇"
        q["desc"] = "人中吕布马中赤兔。听白门楼守将述温侯之勇，方知天下武勇之巅。"
        n_q += 1
save("quests.json", quests)
print("quests: %d changed" % n_q)

# ============================================================
# 2) npcs.json：+6 NPC（id 对齐既有 quest talk 目标的 canon 形）
# ============================================================
npcs = load("npcs.json")
nl = npcs["npcs"] if isinstance(npcs, dict) else npcs
have = {n.get("id") for n in nl}

def npc(nid, name, title, city, root, color, desc, lore):
    return {"id": nid, "name": name, "title": title,
            "npc_type": "resident", "tags": ["story", "quest_giver"],
            "position": [0, 0], "region": "", "color": color,
            "dialogue_root": root, "description": desc, "lore": lore,
            "city_id": city}

NEW_NPC = [
    npc("npc_wu_tu_gu", "兀突骨", "建宁 · 乌戈国主", "scene_40", "wutugu_intro", "#5A6A3A",
        "身长丈二、目有光芒的乌戈国主，领藤甲军雄踞南中深处，不与汉官往来。",
        "藤甲浸油七七四十九日，刀箭不入。但老夫知道——这世道，再硬的甲也怕火。"),
    npc("npc_zhu_lao_dawang", "祝老大王", "建宁 · 老族长", "scene_40", "zhu_dawang_intro", "#9A8A6A",
        "祝家寨的白发老族长，年轻时随商队走过益州大道，是南中少有的「见过世面」的人。",
        "老朽这辈子最大的心愿，是摸一摸汉人的书。人死了，书不死。"),
    npc("npc_jin_huan_san_jie", "金环三结", "建宁 · 蛮将", "scene_40", "jinhuan_intro", "#8A5A2A",
        "三洞元帅之一，按刀而立、目光如炬的蛮将，只服拳头与道理。",
        "南中人不只姓孟。谁对我们好，我们记着；谁欺我们，我们也记着。"),
    npc("npc_scout_zhuge", "卧龙书僮", "襄阳 · 卧龙岗书僮", "scene_32", "scout_intro", "#6A8A7A",
        "卧龙岗上守门扫地的少年书僮，替先生挡了不知多少「慕名来访」的名利之徒。",
        "水镜先生言：卧龙凤雏，得一可安天下。先生常自比管仲乐毅，时人多笑之。"),
    npc("npc_zhou_yu", "周瑜", "吴 · 大都督", "scene_39", "zhouyu_intro", "#4A6A9A",
        "年少成名的江东大都督，精音律、雅量高致——曲有误，周郎顾。",
        "北军舍鞍马而操舟楫，与我争长江之险，是弃长就短。瑜只忧一件事：联盟之心，齐不齐。"),
    npc("npc_zhao_yu", "赵云", "襄阳 · 白袍将军", "scene_32", "zhaoyu_intro", "#7A8A9A",
        "白袍银甲、眉目沉静的将军，长坂坡七进七出的传奇正主，却总是先提「不弃」二字。",
        "护主之义不在万人敌，而在「不弃」二字。能守住身后之人的，才配称将军。"),
]
n_npc = 0
for n in NEW_NPC:
    if n["id"] not in have:
        nl.append(n)
        n_npc += 1
save("npcs.json", npcs)
print("npcs: +%d" % n_npc)

# ============================================================
# 3) dialogues.json：menghuo 链去任务化 + 新 NPC 对话 + 2001/2005 接取入口
# ============================================================
dialogues = load("dialogues.json")
dl = dialogues["dialogues"] if isinstance(dialogues, dict) else dialogues
have_d = {d.get("id") for d in dl}

def dia(did, speaker, lines, options):
    return {"id": did, "speaker": speaker, "lines": lines, "options": options}

def opt(text, nxt, action="", require=None):
    o = {"text": text, "next": nxt}
    if action:
        o["action"] = action
    if require:
        o["require"] = require
    return o

n_d = 0
# --- menghuo_intro：去掉 accept_quest:main_002，改为纯 lore ---
for d in dl:
    if d.get("id") != "menghuo_intro":
        continue
    d["lines"] = [
        "你就是那个外乡人？听说你在寨子里跟着老族长学了些本事。",
        "南中这地方，山高皇帝远。汉人来了又走，走了又来。我只认一件事——谁对我族人好，我就认谁。",
    ]
    d["options"] = [
        opt("我愿为南中效力", "menghuo_trust"),
        opt("南中局势如何？", "menghuo_lore"),
        opt("大王威名，早有耳闻", "menghuo_praise"),
        opt("我只是路过", ""),
    ]
    n_d += 1

NEW_DIA = [
    # menghuo_lore：融原 menghuo_quest 的祝融线索（无任务绑定）
    dia("menghuo_lore", "孟获", [
        "南中各部近来不太平，汉家朝廷又逢黄巾大乱，官府顾不上这边。",
        "云南的祝融性烈如火，一身武艺不输男儿——你若途经云南，替我问候一声。"],
        [opt("记下了", "menghuo_intro")]),
    # 兀突骨（side_wutugu：reach 建宁 + talk）
    dia("wutugu_intro", "兀突骨", [
        "（乌戈国主环眼打量来客）汉人？你身上有股不怕死的味道。",
        "南中深山，可不是谁都敢走进来的。说吧，来做什么。"],
        [opt("愿闻藤甲之事", "", "accept_quest:side_wutugu"),
         opt("乌戈国在哪？", "wutugu_lore"),
         opt("告辞", "")]),
    dia("wutugu_lore", "兀突骨", [
        "乌戈国在盘蛇谷外，国中藤甲，浸油七七四十九日，刀箭不入。",
        "但老夫告诉你——藤甲怕火。这世道，再硬的甲，也怕火。"],
        [opt("受教", "wutugu_intro")]),
    # 祝老大王（side_lunyu：collect 论语 + talk）
    dia("zhu_dawang_intro", "祝老大王", [
        "（白发老者捧着半卷残书，指腹摩挲着缺角）汉家的书……",
        "老朽年轻时随商队去过益州，见过汉人读书——那是顶体面的事。"],
        [opt("老大王想要什么书？", "", "accept_quest:side_lunyu"),
         opt("您想找的是什么书？", "zhudawang_lore"),
         opt("告辞", "")]),
    dia("zhudawang_lore", "祝老大王", [
        "听说有一部《论语》，讲的是做人。汉人尊它千年。",
        "老朽想在这把骨头埋进土里之前，摸一摸它。据说大地图某处的宝箱里藏着一册。"],
        [opt("老大王的心愿，我记下了", "zhu_dawang_intro")]),
    # 金环三结（side_golden_ring：talk 即交）
    dia("jinhuan_intro", "金环三结", [
        "（蛮将按刀，目光如炬）你是汉人？哼。",
        "金环三结只服两件事：拳头，和道理。你说得出道理，我就服你。"],
        [opt("愿闻其教", "", "accept_quest:side_golden_ring"),
         opt("三洞元帅是什么？", "jinhuan_lore"),
         opt("告辞", "")]),
    dia("jinhuan_lore", "金环三结", [
        "我与董荼那、阿会喃，各领一部，是为三洞元帅。",
        "孟获大王是南中之主——但南中人不只姓孟。谁对我们好，我们记着；谁欺我们，我们也记着。"],
        [opt("好一个南中汉子", "jinhuan_intro")]),
    # 卧龙书僮（br_fenglong + 2004 孔明出山）
    dia("scout_intro", "卧龙书僮", [
        "（少年书僮作揖）先生云游去了。客官若为「伏龙」之名而来——",
        "先生说过，名利之徒，不见也罢。不知客官是哪一种？"],
        [opt("三顾之诚，天地可鉴", "", "accept_quest:2004", {"min_chapter": 4}),
         opt("愿为盟约访贤", "", "accept_quest:br_fenglong", {"min_chapter": 5}),
         opt("水镜先生是谁？", "scout_lore"),
         opt("告辞", "")]),
    dia("scout_lore", "卧龙书僮", [
        "水镜司马先生言：「卧龙凤雏，得一可安天下。」",
        "先生常自比管仲、乐毅，时人多笑之——唯博陵崔州平、颍川徐元直，谓为信然。"],
        [opt("领教", "scout_intro")]),
    # 周瑜（br_chibi 赤壁舟书 + fa_lujiang 庐江访贤）
    dia("zhouyu_intro", "周瑜", [
        "（年少将军抚琴，闻声而止，抬眼一笑）客官来了许久？",
        "曲有误，周郎顾——方才那一误，是留给知音的。"],
        [opt("奉盟书求见", "", "accept_quest:br_chibi", {"min_chapter": 5}),
         opt("为家主访贤", "", "accept_quest:fa_lujiang", {"min_chapter": 4}),
         opt("都督如何看曹操？", "zhouyu_lore"),
         opt("告辞", "")]),
    dia("zhouyu_lore", "周瑜", [
        "曹氏挟天子以令诸侯，势大——然北军不习水战，舍鞍马而操舟楫，与我争长江之险，弃长就短也。",
        "瑜只忧一件事：联盟之心，齐不齐。"],
        [opt("都督深谋", "zhouyu_intro")]),
    # 赵云（2003 子龙护主）
    dia("zhaoyu_intro", "赵云", [
        "（白袍将军按剑而立，眉目沉静）当阳一役，云怀抱阿斗，七进七出。",
        "不是勇，是不能回头——主母托付在肩，退一步就是失职。"],
        [opt("愿随将军历练", "", "accept_quest:2003", {"min_chapter": 5}),
         opt("将军如何看待护主之义？", "zhaoyu_lore"),
         opt("告辞", "")]),
    dia("zhaoyu_lore", "赵云", [
        "云以为，护主之义不在万人敌，而在「不弃」二字。",
        "乱世人命如草。能守住身后之人的，才配称将军。"],
        [opt("受教", "zhaoyu_intro")]),
    # 白门楼守将：吕布论武分支（2005 接取）
    dia("bamen_lvbu", "白门楼守将", [
        "（军候兴起）温侯之勇，我亲眼见过——辕门射戟，一百五十步外一箭正中小枝，满座皆惊。",
        "只可惜，勇是天给的，性子是自己选的。他选错了。"],
        [opt("叹服", "bamen_intro")]),
    # 曹操：华容之义分支（2001 接取）
    dia("caocao_huarong", "曹操", [
        "（曹操沉默片刻）建安十三年冬，华容道泥泞没膝。孤笑周瑜无谋、诸葛亮少智——",
        "笑到一半，云长提刀立于路前。……他放走了孤。义之一字，云长当得起天下无双。此事，孤记了一辈子。"],
        [opt("（感慨）", "caocao_intro")]),
]
for d in NEW_DIA:
    if d["id"] not in have_d:
        dl.append(d)
        n_d += 1
# bamen_intro / caocao_intro 追加接取选项
for d in dl:
    if d.get("id") == "bamen_intro":
        has = any("2005" in str(o.get("action", "")) for o in d.get("options", []))
        if not has:
            d["options"].insert(2, opt("听守将说说吕布之勇", "bamen_lvbu",
                "accept_quest:2005", {"min_chapter": 3}))
            n_d += 1
    elif d.get("id") == "caocao_intro":
        has = any("2001" in str(o.get("action", "")) for o in d.get("options", []))
        if not has:
            d["options"].insert(3, opt("华容道上，可还记云长？", "caocao_huarong",
                "accept_quest:2001", {"min_chapter": 5}))
            n_d += 1
save("dialogues.json", dialogues)
print("dialogues: %d changed/added" % n_d)
print("PROLOGUE+LEGACY DONE")
