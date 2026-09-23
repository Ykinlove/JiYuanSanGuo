# -*- coding: utf-8 -*-
"""_m13_add_branch.py — 一次性追加「主线穿插支线 + 武将专属剧情」数据

只改两表，向后兼容，不删不改既有条目：
  - quests.json   追加 支线(br_*)/势力(fa_*)/隐藏(hi_*) 与 整数 id 的武将专属任务(2001+)
  - heroes6.json  给若干历史武将设 exclusive_quest_id（整数，避免破坏 _verify_m9 的 int 校验）
"""
import io
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "assets", "data")

def load(name):
    p = os.path.join(DATA, name)
    with io.open(p, encoding="utf-8") as f:
        return json.load(f), p

def save(p, obj):
    with io.open(p, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    with io.open(p, "a", encoding="utf-8") as f:
        f.write("\n")

# ---- 新增任务（quests.json 追加）----
def obj(t, target, count, desc):
    return {"type": t, "target": target, "count": count, "desc": desc}

NEW_QUESTS = [
    # 支线 branch（穿插主线各章，chapter 标注可在主线第几章期间接取）
    {"id": "br_fenglong", "type": "branch", "quest_type": "branch", "chapter": 5,
     "title": "寻访伏龙", "region": "中原",
     "rewards": {"gold": 800, "exp": 500, "fame": 8},
     "objectives": [obj("talk", "scout_zhuge", 1, "在中原打探\"伏龙\"诸葛亮的下落"),
                    obj("collect", "treasure_longtou", 1, "找到卧龙岗信物")],
     "desc": "水镜先生曾言\"卧龙凤雏得一人可安天下\"。主线进入赤壁前夕，中原传颂伏龙之名。"},
    {"id": "br_guandu", "type": "branch", "quest_type": "branch", "chapter": 4,
     "title": "官渡间客", "region": "中原",
     "rewards": {"gold": 1000, "exp": 400, "fame": 12, "unlock": "mj_guandu_intel"},
     "objectives": [obj("battle", "bandit", 2, "沿途击退山贼掩护行踪"),
                    obj("collect", "intel_map", 1, "取得袁军布防图")],
     "desc": "官渡前夕，曹操与袁绍隔河对峙。许昌有人托你刺探袁军虚实，成功将影响战局。"},
    {"id": "br_chibi", "type": "branch", "quest_type": "branch", "chapter": 5,
     "title": "赤壁舟书", "region": "荆州",
     "rewards": {"gold": 1200, "exp": 600, "fame": 15, "unlock": "mj_chibi_ally"},
     "objectives": [obj("reach", "city_jiangxia", 1, "抵达江夏，为孙刘联盟穿针引线"),
                    obj("talk", "zhou_yu", 1, "与周瑜洽谈联盟")],
     "desc": "赤壁将起。孙刘若不联盟，长江天险亦难守。你被托以传递盟书的重任。"},
    {"id": "br_huizhou", "type": "branch", "quest_type": "branch", "chapter": 3,
     "title": "会稽海商", "region": "江东",
     "rewards": {"gold": 900, "exp": 450, "fame": 10, "materials": ["treasure_pearl"]},
     "objectives": [obj("reach", "city_huiji", 1, "前往会稽"),
                    obj("give_gold", "sea_merchant", 300, "资助海商300金钱进货")],
     "desc": "孙策平江东之时，会稽海商求庇护。解其危难，可得东海明珠与南来奇珍。"},
    {"id": "br_hanzhong", "type": "branch", "quest_type": "branch", "chapter": 6,
     "title": "汉中五斗米", "region": "关中",
     "rewards": {"gold": 700, "exp": 350, "fame": 6},
     "objectives": [obj("reach", "city_hanzhong", 1, "抵达汉中"),
                    obj("collect", "rice_five_dou", 5, "收集五斗米供张鲁义仓")],
     "desc": "张鲁在汉中施行五斗米道，入教者纳五斗米得保境安民。助其义仓可得教众相助。"},
    {"id": "br_shudao", "type": "branch", "quest_type": "branch", "chapter": 6,
     "title": "蜀道险峰", "region": "西蜀",
     "rewards": {"gold": 600, "exp": 600, "fame": 10, "unlock": "mj_shudao_pass"},
     "objectives": [obj("battle", "bandit", 3, "肃清金牛道山贼"),
                    obj("reach", "city_zitong", 1, "探明梓潼关隘")],
     "desc": "刘备入蜀，蜀道天险。探明剑阁梓潼一线，为大军入蜀指明通路。"},
    # 势力 faction（加入对应势力后可接）
    {"id": "fa_caoxu", "type": "faction", "quest_type": "faction", "faction_id": 16,
     "title": "为曹取徐州", "region": "中原",
     "rewards": {"gold": 1500, "exp": 700, "fame": 12, "merit": 20},
     "objectives": [obj("battle", "enc_zhangjue_boss", 0, ""),
                    obj("reach", "city_xuzhou", 1, "陈兵徐州外围")],
     "desc": "投身曹操麾下，徐州吕布反复，需你领军平徐，以立下头功。"},
    {"id": "fa_lujiang", "type": "faction", "quest_type": "faction", "faction_id": 15,
     "title": "庐江访贤", "region": "江东",
     "rewards": {"gold": 800, "exp": 500, "fame": 10, "merit": 15},
     "objectives": [obj("reach", "city_lujiang", 1, "前往庐江"),
                    obj("talk", "zhou_yu", 1, "为你主访贤周瑜")],
     "desc": "投身刘备，江东多贤。庐江周瑜名动江左，其助你主则霸业可期。"},
    # 隐藏 hidden（secret，触发式）
    {"id": "hi_huful", "type": "hidden", "quest_type": "hidden", "secret": True, "chapter": 2,
     "title": "三香得虎符", "region": "南中",
     "rewards": {"gold": 0, "exp": 300, "fame": 5, "unlock": "seal_tiger_tally"},
     "objectives": [obj("collect", "incense", 3, "连上三香（取得三束香）"),
                    obj("talk", "temple_elder", 1, "祠堂老者赐虎符")],
     "desc": "南中祠堂连上三香，可触发隐藏事件，得建国信物虎符之线索（自立线关键）。"},
    {"id": "hi_huatuo", "type": "hidden", "quest_type": "hidden", "secret": True, "chapter": 4,
     "title": "华佗密道", "region": "荆州",
     "rewards": {"gold": 500, "exp": 800, "fame": 8, "unlock": "mj_huatuo_pass"},
     "objectives": [obj("collect", "herb_rare", 5, "收集稀有药草"),
                    obj("reach", "city_jiangling", 1, "经密道抵达江陵医庐")],
     "desc": "神医华佗身后有密道可避敌绕道。寻得名贵药草，可求得医庐相助。"},
    # 武将专属任务（整数 id，供 heroes6.exclusive_quest_id 关联）
    {"id": 2001, "type": "exclusive", "quest_type": "hidden", "hero_id": 167,
     "title": "云长义释", "region": "荆州",
     "rewards": {"gold": 600, "exp": 700, "fame": 12},
     "objectives": [obj("battle", "enc_zhangjue_boss", 0, ""),
                    obj("talk", "guan_yu", 1, "与关羽赴义释之约")],
     "desc": "关羽义薄云天。沿华容之约感其忠义，可得青龙偃月刀之赏识。"},
    {"id": 2002, "type": "exclusive", "quest_type": "hidden", "hero_id": 373,
     "title": "翼德横矛", "region": "荆州",
     "rewards": {"gold": 500, "exp": 650, "fame": 10},
     "objectives": [obj("battle", "bandit", 3, "与张飞并肩肃敌"),
                    obj("reach", "city_changban", 1, "抵长坂坡")],
     "desc": "张飞长坂桥一声断喝吓退曹军。得其认同，能得万军之中取上将之勇。"},
    {"id": 2003, "type": "exclusive", "quest_type": "hidden", "hero_id": 351,
     "title": "子龙护主", "region": "荆州",
     "rewards": {"gold": 600, "exp": 750, "fame": 12, "unlock": "mj_zilong_sworn"},
     "objectives": [obj("battle", "enc_yellow_turban", 3, "与赵云同战"),
                    obj("talk", "zhao_yun", 1, "与赵云论护主之义")],
     "desc": "赵云七进七出救阿斗。与他共历危局，可结八拜之交。"},
    {"id": 2004, "type": "exclusive", "quest_type": "hidden", "hero_id": 294,
     "title": "孔明出山", "region": "中原",
     "rewards": {"gold": 800, "exp": 1000, "fame": 20, "unlock": "mj_zhuge_join"},
     "objectives": [obj("talk", "scout_zhuge", 1, "三访卧龙岗"),
                    obj("reach", "city_wolong", 1, "茅庐求见")],
     "desc": "三顾茅庐，天下三分之策便在其卧龙之中。得孔明出山，天下可图。"},
    {"id": 2005, "type": "exclusive", "quest_type": "hidden", "hero_id": 537,
     "title": "奉先无双", "region": "中原",
     "rewards": {"gold": 700, "exp": 900, "fame": 15, "unlock": "mj_lvbu_sworn"},
     "objectives": [obj("battle", "enc_zhangjue_boss", 0, ""),
                    obj("talk", "lu_bu", 1, "与吕布论武")],
     "desc": "人中吕布马中赤兔。与其较量武艺，方知天下武勇之巅。"},
    {"id": 2006, "type": "exclusive", "quest_type": "hidden", "hero_id": 469,
     "title": "南蛮归心", "region": "南中",
     "rewards": {"gold": 500, "exp": 600, "fame": 10, "unlock": "mj_meng_wo_join"},
     "objectives": [obj("battle", "enc_tribal_warrior", 3, "与孟获一较高下"),
                    obj("talk", "meng_huo", 1, "七擒七纵之后招抚孟获")],
     "desc": "七擒七纵，南蛮心服。收服孟获则南中永固，象兵入麾。"},
    {"id": 2007, "type": "exclusive", "quest_type": "hidden", "hero_id": 268,
     "title": "祝融烈火", "region": "南中",
     "rewards": {"gold": 500, "exp": 550, "fame": 8, "unlock": "mj_zhurong_join"},
     "objectives": [obj("battle", "zhu_rong", 1, "击退祝融夫人"),
                    obj("talk", "zhu_rong", 1, "折服祝融归附")],
     "desc": "祝融夫人善使飞刀，南蛮女将之魁。以武力礼待，可收其部曲为用。"},
]

# 武将 -> 专属任务 id（heroes6.exclusive_quest_id，整数）
HERO_EXCLUSIVE = {
    167: 2001,  # 关羽
    373: 2002,  # 张飞
    351: 2003,  # 赵云
    294: 2004,  # 诸葛亮
    537: 2005,  # 吕布
    469: 2006,  # 孟获
    268: 2007,  # 祝融
}


def fill_battle_skip(q):
    """把 count=0 的 battle 目标改为有效（打任意战斗）。"""
    for o in q.get("objectives", []):
        if o.get("type") == "battle" and int(o.get("count", 0)) <= 0:
            o["target"] = "any"
            o["count"] = 1
            o["desc"] = o.get("desc") or "赢得一场战斗"


def add_quests():
    arr, p = load("quests.json")
    existing = {q.get("id") for q in arr}
    added = 0
    for q in NEW_QUESTS:
        if q["id"] in existing:
            continue
        fill_battle_skip(q)
        arr.append(q)
        added += 1
    save(p, arr)
    print("quests.json: +%d 新任务 (现共 %d)" % (added, len(arr)))


def add_heroes():
    arr, p = load("heroes6.json")
    by_id = {h.get("id"): h for h in arr}
    hit = 0
    missing = []
    for hid, qid in HERO_EXCLUSIVE.items():
        h = by_id.get(hid)
        if h is None:
            missing.append(hid)
            continue
        h["exclusive_quest_id"] = qid
        hit += 1
    save(p, arr)
    print("heroes6.json: %d 位武将设 exclusive_quest_id (现共 %d 武将)" % (hit, len(arr)))
    if missing:
        print("  WARN 未找到武将 id: %s" % missing)


if __name__ == "__main__":
    print("== M13 支线+武将专属数据追加 ==")
    add_quests()
    add_heroes()
    print("== 完成 ==")
