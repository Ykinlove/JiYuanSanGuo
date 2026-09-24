# -*- coding: utf-8 -*-
"""《三国全史篇》剧本数据批量落表脚本（2026-09-24）。
落表：cities.json(visit_target+州属修正) / npcs.json(13 剧情NPC) /
     quests.json(ch1_05 + ch2~ch7 共 34 环) / encounters.json(11 剧情遭遇) /
     dialogues.json(章末章初旁白 + 剧情NPC对话)。
只增改，不删既有数据；幂等（重复执行不产生重复条目）。
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

def lst(data, key):
    return data[key] if isinstance(data, dict) else data

# ============================================================
# 1. cities.json —— 剧情城 visit_target + 陈留/官渡 州属修正
# ============================================================
cities = load("cities.json")
cl = lst(cities, "cities")
by_scene = {c.get("id"): c for c in cl}

VISIT = {
    "scene_19": "city_luoyang", "scene_22": "city_chenliu",
    "scene_27": "city_chengdu", "scene_32": "city_xiangyang",
    "scene_33": "city_runan",   "scene_38": "city_xapi",
    "scene_39": "city_wu",      "scene_42": "city_jiangling",
    "scene_89": "city_guandu",  "scene_97": "city_chibi",
    "scene_16": "city_hanzhong", "scene_35": "city_shouchun",
}
n_visit = 0
for sid, vt in VISIT.items():
    c = by_scene.get(sid)
    if c and not c.get("visit_target"):
        c["visit_target"] = vt
        n_visit += 1

# 州属史实修正：陈留属兖州（reg_yan）、官渡（中牟）属豫州（reg_yu）
n_reg = 0
FIX_REGION = {
    "scene_22": ("reg_yan", "兖州", "兖州 · 城池"),
    "scene_89": ("reg_yu",  "豫州", "豫州 · 要地"),
}
for sid, (reg, rname, title) in FIX_REGION.items():
    c = by_scene.get(sid)
    if c and c.get("region") != reg:
        c["region"], c["region_name"], c["title"] = reg, rname, title
        n_reg += 1
save("cities.json", cities)
print("cities: visit_target +%d, region fix %d" % (n_visit, n_reg))

# ============================================================
# 2. encounters.json —— 11 个剧情遭遇（quest_target=自身 id）
# ============================================================
encounters = load("encounters.json")
el = lst(encounters, "encounters")
have = {e.get("id") for e in el}

def enc(eid, name, color, weight, regions, lv, units, boss, desc):
    return {
        "id": eid, "name": name, "type": "battle",
        "icon_color": color, "quest_target": eid,
        "weight": weight, "regions": regions,
        "terrain_prefer": ["plain"],
        "level_range": lv, "enemy_units": units,
        "boss_hero_id": boss,
        "rewards": {"exp": [lv[0]*35, lv[1]*45], "gold": [lv[0]*18, lv[1]*26], "fame": 3},
        "description": desc,
    }

NEW_ENC = [
    enc("enc_huaxiong", "董卓军·华雄", "#A03028", 8, ["zhongyuan", "sili"], [6, 9],
        [{"unit_id": "infantry", "count": 90}, {"unit_id": "cavalry", "count": 30}],
        "165", "汜水关前连斩联军数将的董卓骁将华雄。其马快刀沉，寻常义军难撄其锋。"),
    enc("enc_lvbu_guard", "并州狼骑·吕布部曲", "#7A4FB0", 6, ["zhongyuan", "sili"], [8, 11],
        [{"unit_id": "cavalry", "count": 70}, {"unit_id": "infantry", "count": 80}],
        "537", "飞将吕布亲率并州狼骑，人马俱甲，来去如风。虎牢关下，三英犹战之不倒。"),
    enc("enc_caobao", "陶谦部·曹豹军", "#5E7A4F", 8, ["xuzhou", "zhongyuan"], [9, 13],
        [{"unit_id": "infantry", "count": 110}],
        "328", "徐州牧陶谦帐下曹豹所部，军纪涣散，劫掠道旁流民。"),
    enc("enc_jiling", "袁术军·纪灵部", "#B0763A", 8, ["zhongyuan", "xuzhou"], [11, 15],
        [{"unit_id": "infantry", "count": 130}, {"unit_id": "archer", "count": 60}],
        "203", "僭号天子袁术麾下大将纪灵，使三尖两刃刀，率军三万屯于淮上。"),
    enc("enc_yanliang", "河北军·颜良部", "#8A2F4F", 8, ["zhongyuan", "jizhou"], [14, 18],
        [{"unit_id": "cavalry", "count": 90}, {"unit_id": "infantry", "count": 120}],
        "187", "河北名将颜良，袁绍麾下第一锋。白马之围，十万河北军旌旗蔽野。"),
    enc("enc_wuchao", "河北军·乌巢守军", "#6A3A6A", 6, ["zhongyuan"], [15, 19],
        [{"unit_id": "infantry", "count": 150}, {"unit_id": "archer", "count": 80}],
        "275", "淳于琼率万人在乌巢守护袁军屯粮。酒气冲天——此乃官渡胜负之枢。"),
    enc("enc_tiger_cavalry", "曹军·虎豹骑分队", "#3A4A6A", 7, ["jing"], [19, 24],
        [{"unit_id": "cavalry", "count": 100}, {"unit_id": "cavalry", "count": 60}],
        "318", "曹纯统领的百战精骑，长坂坡追杀刘备一日一夜三百里的正是此军。"),
    enc("enc_cao_navy", "曹军·水寨水军", "#2F5A6A", 7, ["jing"], [21, 26],
        [{"unit_id": "infantry", "count": 160}, {"unit_id": "archer", "count": 100}],
        "250", "荆州降卒编成的曹军水师，战船连缀，铁索横江——只待一把大火。"),
    enc("enc_zhangren", "刘璋军·张任伏兵", "#7A6A2F", 8, ["yizhou", "jing"], [23, 28],
        [{"unit_id": "archer", "count": 90}, {"unit_id": "infantry", "count": 140}],
        "369", "蜀中名将张任，于雒城道中设伏。忠臣不事二主，其志可敬，其锋难当。"),
    enc("enc_xiahouyuan", "曹军·夏侯渊部", "#4F5A2F", 7, ["sili", "yizhou"], [26, 31],
        [{"unit_id": "cavalry", "count": 110}, {"unit_id": "infantry", "count": 150}],
        "153", "虎步关右的征西将军夏侯渊，用兵神速，一日可行三百里——然定军山，是其终点。"),
    enc("enc_wu_vanguard", "吴军·夷陵前锋", "#2F6A5A", 7, ["jing"], [33, 38],
        [{"unit_id": "infantry", "count": 170}, {"unit_id": "archer", "count": 110}],
        "270", "陆逊麾下朱然所部前锋，沿江而下连营设防，火烧连营七百里的火种由此点燃。"),
]
n_enc = 0
for e in NEW_ENC:
    if e["id"] not in have:
        el.append(e)
        n_enc += 1
save("encounters.json", encounters)
print("encounters: +%d" % n_enc)

# ============================================================
# 3. npcs.json —— 13 个剧情 NPC（city_id 挂城，城内可交谈）
# ============================================================
npcs = load("npcs.json")
nl = lst(npcs, "npcs")
have_npc = {n.get("id") for n in nl}

def npc(nid, name, title, city, root, ntype, color, desc, lore, tags=None):
    return {
        "id": nid, "name": name, "title": title,
        "npc_type": ntype, "tags": tags or ["story", "quest_giver"],
        "position": [0, 0], "region": "", "color": color,
        "dialogue_root": root, "description": desc, "lore": lore,
        "city_id": city,
    }

NEW_NPC = [
    npc("npc_han_envoy", "朝廷使者", "许都 · 朝使", "scene_19", "han_envoy_intro", "resident", "#C7A45C",
        "奉朝廷之命犒劳义军的使者，风尘仆仆，官袍上还沾着北上的泥。",
        "自黄巾起，朝廷的告身就越发不值钱了。但礼数未废——有功之人，朝廷还是要赏的。"),
    npc("npc_caocao", "曹操", "陈留 · 讨董义军", "scene_22", "caocao_intro", "resident", "#5A7A9A",
        "身量不高，双目却锐利如鹰。陈留散家财、合义兵的发起人。",
        "治世之能臣，乱世之奸雄——他自己从不辩解。他只说：宁教我负天下人，休教天下人负我。"),
    npc("npc_strategist", "军中谋士", "洛阳 · 观局者", "scene_19", "strategist_intro", "resident", "#8A7A5A",
        "布衣葛巾，摇一把旧羽扇，在洛阳城中观天下大势的谋士。",
        "他自称山野闲人，却对天下局势了如指掌。有人说他游学于颍川门下，也有人说他根本无名无姓。"),
    npc("npc_historian", "史官", "洛阳 · 著史者", "scene_19", "historian_intro", "resident", "#9A9A7A",
        "白发苍苍的老史官，怀中抱着一摞竹简，一生只做一件事：记史。",
        "「史笔如铁。王侯将相，成王败寇，到了我这竹简上，都只剩一行行字。」"),
    npc("npc_baimen_warden", "白门楼守将", "下邳 · 城楼军校", "scene_38", "bamen_intro", "resident", "#7A6A4A",
        "白门楼上的军候，亲眼看下了那场震动天下的审判。",
        "「楼上缚着的那位，曾是人中吕布。如今……唉，城楼的风，比往常冷得多。」"),
    npc("npc_yushi", "朝廷御史", "寿春 · 巡按御史", "scene_35", "yushi_intro", "resident", "#8A5A4A",
        "奉命巡视淮南的御史，对寿春城里的僭号闹剧嗤之以鼻。",
        "「袁术僭号称帝，粮尽而食桑椹，兵散而掠百姓——我笔下记他一笔：跳梁小丑，僭伪无成。」"),
    npc("npc_liubei", "刘备", "汝南 · 落魄枭雄", "scene_33", "liubei_intro", "resident", "#5A8A5A",
        "织席贩履出身，双耳垂肩。虽屡战屡败，身边人却始终不离不弃。",
        "「今天下英雄，唯使君与操耳。」——他听了这话摔了筷子，却依然是那个百折不挠的刘玄德。"),
    npc("npc_jing_shizhong", "荆州从事", "襄阳 · 州府属吏", "scene_32", "jing_intro", "resident", "#6A7A8A",
        "荆州牧刘表帐下从事，替病重的州牧打理着这座天下最富庶的州。",
        "「使君卧病，少主年幼，北有曹军百万……荆州这艘大船，正在往风浪里开。」"),
    npc("npc_lusu", "鲁肃", "吴 · 江东赞军校尉", "scene_39", "lusu_intro", "resident", "#4A6A7A",
        "体貌魁梧、慷慨好施的鲁子敬，指囷相赠的豪士，榻上策的献策人。",
        "「汉室不可复兴，曹操不可卒除。为将军计，唯有鼎足江东，以观天下。」"),
    npc("npc_sunquan", "孙权", "吴 · 江东之主", "scene_39", "sunquan_intro", "resident", "#3A5A7A",
        "碧眼紫髯的年轻之主，十九岁继兄业坐断东南，举贤任能，隐忍果决。",
        "「曹操拥百万之众，诸议皆言迎之。」他把剑砍下案角：再有言迎操者，如同此案！"),
    npc("npc_jianggan", "蒋干", "赤壁 · 曹营说客", "scene_97", "jianggan_intro", "resident", "#7A8A6A",
        "九江名士，曹营帐下幕宾。自诩辩才无双，却是连环计里最好用的那颗棋子。",
        "「干到江东，必要说周瑜来降！」——他确实见着周瑜了，还『顺』回一封『书信』。"),
    npc("npc_fazheng", "法正", "成都 · 蜀郡太守", "scene_27", "fazheng_intro", "resident", "#8A6A3A",
        "扶风法孝直，奇画策算、睚眦必报的蜀郡太守，先主最信重的谋主。",
        "「天下大乱，非明主莫能定。刘季玉暗弱，益州士民思得明主久矣。」"),
    npc("npc_zhugeliang", "诸葛亮", "成都 · 军师将军", "scene_27", "zhuge_intro", "resident", "#4A7A6A",
        "羽扇纶巾的卧龙先生，隆中一对定三分，如今总揽后方、运筹帷幄。",
        "「臣本布衣，躬耕于南阳……先帝不以臣卑鄙，猥自枉屈，三顾臣于草庐之中。」"),
]
n_npc = 0
for n in NEW_NPC:
    if n["id"] not in have_npc:
        nl.append(n)
        n_npc += 1
save("npcs.json", npcs)
print("npcs: +%d" % n_npc)

# ============================================================
# 4. quests.json —— mj_hj_03 衔接 + ch1_05 + ch2~ch7 共 34 环
# ============================================================
quests = load("quests.json")
ql = lst(quests, "quests")
have_q = {q.get("id") for q in ql}
# 读取既有蛮族遭遇的 quest_target 作为 ch7_05 战斗目标
TRIBAL_QT = "tribal_warrior"
for e in el:
    if e.get("id") == "enc_tribal_warrior":
        TRIBAL_QT = str(e.get("quest_target", TRIBAL_QT))

for q in ql:
    if q.get("id") == "mj_hj_03" and q.get("next", "") == "":
        q["next"] = "ch1_05"   # 第一章收束：张角决战 → 犒军论功 → 交接第二章

def quest(qid, title, region, desc, objectives, rewards, nxt):
    return {"id": qid, "type": "mainline", "title": title, "region": region,
            "giver_npc": "", "description": desc,
            "objectives": objectives, "rewards": rewards, "next": nxt}

def obj(t, target, count, desc):
    return {"type": t, "target": target, "count": count, "desc": desc}

NEW_QUESTS = [
    # ---------- 第一章收束（184） ----------
    quest("ch1_05", "黄巾之乱·犒军论功", "zhongyuan",
        "张角授首，黄巾既平。朝廷论功行赏的使者已在洛阳设下案几，北上洛阳，领受你的第一份朝廷告身——乱世的门，从此为你打开。",
        [obj("reach", "city_luoyang", 1, "北上抵达洛阳"),
         obj("talk", "npc_han_envoy", 1, "面见朝廷使者，领受犒赏")],
        {"gold": 800, "exp": 400, "fame": 20}, "ch2_01"),
    # ---------- 第二章 董卓之乱（189.4–191.12） ----------
    quest("ch2_01", "董卓之乱·入京观变", "sili",
        "灵帝驾崩，董卓入京，废立天子，火烧洛阳。中原驿道上传来的都是坏消息。北上洛阳，亲眼看看这座帝都如今的模样。",
        [obj("reach", "city_luoyang", 1, "北上洛阳观变")],
        {"gold": 200, "exp": 120, "fame": 5}, "ch2_02"),
    quest("ch2_02", "董卓之乱·陈留投义军", "zhongyuan",
        "曹操发矫诏召天下诸侯讨董，陈留正是义军起兵之地。前往陈留面见曹操，乱天下者，必董卓也。",
        [obj("talk", "npc_caocao", 1, "赴陈留面见曹操")],
        {"gold": 300, "exp": 200, "fame": 8}, "ch2_03"),
    quest("ch2_03", "董卓之乱·筹粮募兵", "zhongyuan",
        "义军虽起，粮械两缺。曹操拜你为义军校尉，命你筹措军资：捐输军费五百金，再收集精铁十份交铁匠打造军械。",
        [obj("give_gold", "npc_caocao", 500, "向曹操捐输军资 500 金"),
         obj("collect", "material_fine_iron", 10, "收集精铁 10 份（矿点采集/铁匠购得）")],
        {"gold": 400, "exp": 260, "fame": 8, "merit": 5}, "ch2_04"),
    quest("ch2_04", "董卓之乱·虎牢之战", "sili",
        "联军兵锋直抵汜水、虎牢。华雄连斩联军数将，吕布更率并州狼骑虎视关前。此战若胜，天下皆知你名。",
        [obj("battle", "enc_huaxiong", 1, "阵前斩将：击败华雄部曲"),
         obj("battle", "enc_lvbu_guard", 1, "关前鏖战：击退吕布部曲")],
        {"gold": 900, "exp": 700, "fame": 18, "merit": 10}, "ch2_05"),
    quest("ch2_05", "董卓之乱·玉玺传闻", "sili",
        "董卓西遁，焚洛阳宫室。传国玉玺下落成谜，军中谋士似乎知道些什么。回洛阳找军中谋士问问——这一页史书，该翻过去了。",
        [obj("talk", "npc_strategist", 1, "回洛阳与军中谋士论天下")],
        {"gold": 1200, "exp": 800, "fame": 30, "merit": 10}, "ch3_01"),
    # ---------- 第三章 群雄割据（192.4–199.12） ----------
    quest("ch3_01", "群雄割据·长安惊变", "sili",
        "王允定连环计，吕布诛董卓；然李傕郭汜反攻长安，天子蒙尘。天下自此再无一霸，群雄并起。找军中谋士听听长安之变的前后。",
        [obj("talk", "npc_strategist", 1, "听谋士讲述长安惊变")],
        {"gold": 250, "exp": 150, "fame": 5}, "ch3_02"),
    quest("ch3_02", "群雄割据·徐州救急", "xuzhou",
        "曹操以报父仇为名兵发徐州，所过之处鸡犬不留。陶谦遣使四方求救，曹豹所部却趁机劫掠道旁流民。东进下邳，先平乱军，再解州难。",
        [obj("reach", "city_xapi", 1, "东进抵达下邳"),
         obj("battle", "enc_caobao", 1, "剿灭劫道的曹豹军")],
        {"gold": 500, "exp": 400, "fame": 10}, "ch3_03"),
    quest("ch3_03", "群雄割据·迎驾许都", "zhongyuan",
        "天子东归，道路险恶，杨奉韩暹乱兵一路劫驾。曹操决意迎天子都许。回师许昌，护驾清道——这一步棋，将定此后数十年天下大势。",
        [obj("reach", "city_xuchang", 1, "抵达许昌护驾"),
         obj("battle", "enc_bandit", 2, "肃清劫驾乱兵 ×2")],
        {"gold": 600, "exp": 450, "fame": 12, "merit": 8}, "ch3_04"),
    quest("ch3_04", "群雄割据·讨逆袁术", "xuzhou",
        "袁术寿春僭号称帝，天下哗然。奉诏讨逆——寿春城下，纪灵率军三万屯于淮上。去寿春寻朝廷御史问明军情，再两破纪灵部。",
        [obj("battle", "enc_jiling", 2, "讨伐纪灵部 ×2")],
        {"gold": 800, "exp": 600, "fame": 15, "merit": 10}, "ch3_05"),
    quest("ch3_05", "群雄割据·白门楼观刑", "xuzhou",
        "曹操决水灌下邳，白门楼上缚着人中吕布。「缚太急，乞缓之」——去白门楼下看看这场审判。你是看客，也是史书的一笔。",
        [obj("talk", "npc_baimen_warden", 1, "登白门楼观刑")],
        {"gold": 1500, "exp": 900, "fame": 35, "merit": 10}, "ch4_01"),
    # ---------- 第四章 官渡之战（200.2–207.12） ----------
    quest("ch4_01", "官渡之战·衣带诏风声", "sili",
        "衣带诏事发，董承族诛，许都血流成河。北方袁绍拥兵七十万南下来攻——袁曹决战，一触即发。洛阳城里听听谋士如何论这两位霸主。",
        [obj("talk", "npc_strategist", 1, "听谋士论官渡形势")],
        {"gold": 300, "exp": 200, "fame": 6}, "ch4_02"),
    quest("ch4_02", "官渡之战·白马之围", "zhongyuan",
        "颜良围白马，锋不可当。万军之中，一位赤面长髯的大将单骑冲阵——你在阵中助战，先破颜良部再说。",
        [obj("battle", "enc_yanliang", 1, "解白马之围：击败颜良部")],
        {"gold": 700, "exp": 550, "fame": 12}, "ch4_03"),
    quest("ch4_03", "官渡之战·官渡相持", "zhongyuan",
        "两军相持于官渡，粮道就是命脉。大军征你为军中渔粮官——去河湖渔猎筹粮十五份，守营粮道便有你的功劳。",
        [obj("collect", "material_fish", 15, "筹措军粮（渔猎鲜鱼 ×15）")],
        {"gold": 500, "exp": 400, "fame": 8, "merit": 6}, "ch4_04"),
    quest("ch4_04", "官渡之战·夜袭乌巢", "zhongyuan",
        "许攸夜投曹营：「袁绍不用吾谋，乌巢一夜可破！」曹操亲率轻骑五千，打袁军旗号，人衔枚马缚口——火烧乌巢，就在今夜。",
        [obj("battle", "enc_wuchao", 1, "夜袭乌巢：击破淳于琼守军")],
        {"gold": 1000, "exp": 800, "fame": 18, "merit": 12}, "ch4_05"),
    quest("ch4_05", "官渡之战·汝南寻刘备", "zhongyuan",
        "官渡大胜，北方将定。传闻刘备兵败后遁走汝南。南下汝南寻访这位屡败屡起的枭雄——乱世的下一幕，正在南方酝酿。",
        [obj("talk", "npc_liubei", 1, "赴汝南面见刘备")],
        {"gold": 2000, "exp": 1200, "fame": 40, "merit": 10}, "ch5_01"),
    # ---------- 第五章 赤壁之战（208.7–209.12） ----------
    quest("ch5_01", "赤壁之战·荆州剧变", "jing",
        "曹操南征，大军压境；刘表病笃，襄阳人心惶惶。南下襄阳看一眼这座风雨飘摇的荆州重镇——历史在这里转弯。",
        [obj("reach", "city_xiangyang", 1, "南下抵达襄阳")],
        {"gold": 350, "exp": 250, "fame": 8}, "ch5_02"),
    quest("ch5_02", "赤壁之战·长坂护民", "jing",
        "刘琮举州而降，刘备携十余万百姓南逃，曹操以虎豹骑一日一夜追三百里。当阳道上有虎豹骑分队追杀百姓——护民，还是保身？",
        [obj("battle", "enc_tiger_cavalry", 2, "阻击虎豹骑分队 ×2")],
        {"gold": 800, "exp": 700, "fame": 15, "merit": 8}, "ch5_03"),
    quest("ch5_03", "赤壁之战·舌战结盟", "jiangdong",
        "诸葛亮过江柴桑，鲁肃往来奔走。曹操檄文已至江东，「与将军会猎于吴」。赴吴地先后面见鲁肃与孙权——这一盟，定天下三分。",
        [obj("talk", "npc_lusu", 1, "面见鲁肃陈说利害"),
         obj("talk", "npc_sunquan", 1, "面见孙权共决大计")],
        {"gold": 700, "exp": 550, "fame": 15}, "ch5_04"),
    quest("ch5_04", "赤壁之战·连环计中计", "jing",
        "周瑜会蒋干于帐中，庞统献连环之计，黄盖愿行苦肉。赤壁江畔有曹营说客蒋干出入——去会会他，识不识破这一局，在你一念之间。",
        [obj("talk", "npc_jianggan", 1, "与蒋干论江东战局")],
        {"gold": 600, "exp": 450, "fame": 10}, "ch5_05"),
    quest("ch5_05", "赤壁之战·赤壁火攻", "jing",
        "东风起。黄盖的火船直插曹军水寨，铁索连舟、烟炎张天——去赤壁江面参战，两破曹军水师，亲眼看这场烧出三分天下的冲天大火。",
        [obj("battle", "enc_cao_navy", 2, "火烧曹军水寨 ×2")],
        {"gold": 2500, "exp": 1500, "fame": 50, "merit": 15}, "ch6_01"),
    # ---------- 第六章 三分鼎立（211.1–219.12） ----------
    quest("ch6_01", "三分鼎立·西川之邀", "yizhou",
        "刘璋遣法正迎刘备入蜀，共讨张鲁——醉翁之意，路人皆知。西行成都，面见法正，听他亲口道破益州的天机。",
        [obj("reach", "city_chengdu", 1, "西行抵达成都")],
        {"gold": 400, "exp": 300, "fame": 10}, "ch6_02"),
    quest("ch6_02", "三分鼎立·雒城之难", "yizhou",
        "庞统陨于落凤坡，刘备进退维谷。入蜀道中，张任设伏屡挫义军——两破张任伏兵，为西川之门扫清道路。",
        [obj("battle", "enc_zhangren", 2, "击破张任伏兵 ×2")],
        {"gold": 1000, "exp": 800, "fame": 15, "merit": 10}, "ch6_03"),
    quest("ch6_03", "三分鼎立·成都易主", "yizhou",
        "雒城破，马超归，刘璋开城出降，刘备入主益州。去军师将军府见诸葛亮——这盘三分棋，又落下关键一子。",
        [obj("talk", "npc_zhugeliang", 1, "面见诸葛亮论益州新政")],
        {"gold": 600, "exp": 450, "fame": 10}, "ch6_04"),
    quest("ch6_04", "三分鼎立·定军山", "sili",
        "汉中之战爆发。法正定计，黄忠斩将——但夏侯渊部主力仍在。北上定军山参战，击破这位虎步关右的征西将军。",
        [obj("battle", "enc_xiahouyuan", 1, "定军山破夏侯渊部")],
        {"gold": 1200, "exp": 900, "fame": 20, "merit": 12}, "ch6_05"),
    quest("ch6_05", "三分鼎立·汉中称王", "yizhou",
        "汉中已定，群臣劝进，刘备进位汉中王。回到成都向法正道贺——而荆州方向，隐隐传来吕蒙整军的消息，襄樊上空阴云密布。",
        [obj("talk", "npc_fazheng", 1, "向法正道贺汉中捷音")],
        {"gold": 3000, "exp": 1800, "fame": 60, "merit": 15}, "ch7_01"),
    # ---------- 终章 星落五丈原（220.1–234.8） ----------
    quest("ch7_01", "星落五丈原·汉室终焉", "sili",
        "曹操薨于洛阳，曹丕受禅代汉——四百年大汉，至此而终。回到洛阳，听谋士讲述这场「禅让」大戏的台前幕后。",
        [obj("talk", "npc_strategist", 1, "洛阳听谋士论汉魏之变")],
        {"gold": 500, "exp": 400, "fame": 10}, "ch7_02"),
    quest("ch7_02", "星落五丈原·章武称帝", "yizhou",
        "献帝遇害的传闻传到成都，群臣拥立先主即皇帝位。向法正致贺——年号章武，汉祚在西南延续，也把复仇的火种埋进了夷陵。",
        [obj("talk", "npc_fazheng", 1, "成都向法正贺章武建元")],
        {"gold": 600, "exp": 450, "fame": 12}, "ch7_03"),
    quest("ch7_03", "星落五丈原·夷陵之痛", "jing",
        "先主伐吴，猇亭连营七百里。陆逊按兵不动，只等一把火。你在前线亲历吴军前锋的反扑——这一战，史学家的笔写着「先主大败」。",
        [obj("battle", "enc_wu_vanguard", 1, "夷陵前线击退吴军前锋")],
        {"gold": 800, "exp": 650, "fame": 12}, "ch7_04"),
    quest("ch7_04", "星落五丈原·白帝托孤", "yizhou",
        "先主殂于永安宫，托孤于丞相：「君才十倍曹丕，必能安国，终定大事。」成都的诸葛亮开始总揽军政——去见他，见证这副担子如何接过。",
        [obj("talk", "npc_zhugeliang", 1, "成都面见托孤后的丞相")],
        {"gold": 700, "exp": 550, "fame": 15}, "ch7_05"),
    quest("ch7_05", "星落五丈原·南中平定", "nanzhong",
        "丞相南征，「攻心为上，攻城为下」。回到你出发的地方——建宁。两破蛮部，再与孟获当面一叙：当年的七擒七纵，就从这一战开始。",
        [obj("reach", "city_jianning", 1, "重返建宁"),
         obj("battle", TRIBAL_QT, 2, "平定蛮部叛军 ×2"),
         obj("talk", "npc_meng_huo", 1, "与孟获一叙攻心之道")],
        {"gold": 1000, "exp": 800, "fame": 20, "merit": 10}, "ch7_06"),
    quest("ch7_06", "星落五丈原·北伐出师表", "sili",
        "「先帝创业未半而中道崩殂……」《出师表》上，大军进驻汉中。北上抵达汉中，看一眼北伐的出发点——那面「克复中原」的大旗。",
        [obj("reach", "city_hanzhong", 1, "抵达北伐大本营汉中")],
        {"gold": 800, "exp": 650, "fame": 15}, "ch7_07"),
    quest("ch7_07", "星落五丈原·秋风渭水", "yizhou",
        "五丈原上，丞相与司马懿对峙百日，油尽灯枯。回成都再见诸葛亮最后一面——他将要北上前托付给你的话，或许就是他留给这个时代的遗言。",
        [obj("talk", "npc_zhugeliang", 1, "听丞相最后一席话")],
        {"gold": 1200, "exp": 900, "fame": 25, "merit": 10}, "ch7_08"),
    quest("ch7_08", "星落五丈原·青史留名", "sili",
        "将星陨落五丈原，三国步入残章。天下大势已定，而你的故事需要一位执笔者。回洛阳寻白发史官，让他在竹简上为你的乱世一生落笔。",
        [obj("talk", "npc_historian", 1, "洛阳请史官为你落笔")],
        {"gold": 5000, "exp": 3000, "fame": 100, "merit": 50}, ""),
]
n_q = 0
for q in NEW_QUESTS:
    if q["id"] not in have_q:
        ql.append(q)
        n_q += 1
save("quests.json", quests)
print("quests: +%d (ch7_05 battle target=%s)" % (n_q, TRIBAL_QT))

# ============================================================
# 5. dialogues.json —— 章末/章初旁白 + 结局 + 剧情NPC对话
# ============================================================
dialogues = load("dialogues.json")
dl = lst(dialogues, "dialogues")
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

NARR = "旁白"
NEW_DIA = []

# ---- 章初/章末旁白（world_map 消费 pending 标记后播放）----
NEW_DIA += [
    dia("mj_ch2_start", NARR, [
        "公元 189 年，汉灵帝驾崩。西凉军阀董卓率铁骑入京，废少帝，立献帝，夜宿龙床——洛阳城的宫阙，第一次在铁蹄下发抖。",
        "你随流民北望中原。乱世真正的帷幕，才刚刚拉开。"], []),
    dia("mj_ch2_end", NARR, [
        "虎牢关前的烽烟散去，董卓焚洛阳、挟天子西遁长安。讨董的诸侯们各怀鬼胎，盟约名存实亡。",
        "帝都的火光映红了半边天——大一统的秩序死了，群雄割据的时代来了。"], []),
    dia("mj_ch3_start", NARR, [
        "公元 192 年，吕布一戟刺穿董卓，百姓歌舞于道。然而王允不赦凉州兵，李傕郭汜反攻长安，天子再度蒙尘。",
        "旧的霸主死了，没有新的共主。曹操、吕布、袁绍、袁术、刘表、孙策——乱世群雄，就此登场。"], []),
    dia("mj_ch3_end", NARR, [
        "白门楼的绳索套上了吕布的脖颈，僭号的袁术众叛亲离、呕血而亡。曹操迎天子都许，挟天子以令诸侯。",
        "北方最耀眼的两颗星，只剩两颗：袁绍，与曹操。"], []),
    dia("mj_ch4_start", NARR, [
        "公元 200 年，衣带诏事发，许都血流成河。袁绍率七十万大军南下，檄文骂遍曹操三代——官渡，两强之间必有一战。",
        "北方的天空压着大战前的阴云。这也是你距中原霸业最近的一次。"], []),
    dia("mj_ch4_end", NARR, [
        "乌巢的火烧了一夜，七十万河北军土崩瓦解。两年后袁绍呕血而亡，北方终归一统。",
        "曹操把目光投向南方——那里有荆州、有江东，还有两个不肯低头的人。"], []),
    dia("mj_ch5_start", NARR, [
        "公元 208 年秋，曹操八十三万大军南征，饮马长江。刘表病死，刘琮束手，刘备携民渡江，长坂坡一战几乎全军覆没。",
        "危亡之际，一人过江东，舌战群儒——天下三分的走向，将在这一盟之间见分晓。"], []),
    dia("mj_ch5_end", NARR, [
        "赤壁的火烧了三天三夜，八十三万大军灰飞烟灭。曹操败走华容道，留下一句「若奉孝在，不使孤至此」。",
        "天下三分的格局，就此铸成。南方的双雄，将各自去啃属于自己的那块天下。"], []),
    dia("mj_ch6_start", NARR, [
        "公元 211 年，刘备应刘璋之邀入蜀——假道伐虢，醉翁之意不在张鲁。荆州与益州的棋局同时落子。",
        "这是英雄们最后的扩张时代：得陇望蜀，天下将定于谁手，就看这十年。"], []),
    dia("mj_ch6_end", NARR, [
        "汉中称王，巅峰之上，噩耗接踵而来——吕蒙白衣渡江，关羽败走麦城，殒命临沮。",
        "荆州尽失，联盟破裂。白发苍苍的先主擦拭泪痕，把目光投向了东方。"], []),
    dia("mj_ch7_start", NARR, [
        "公元 220 年，曹操薨，曹丕受禅代汉。四百年大汉，在一场「禅让」大戏中落幕。",
        "成都的群臣为汉室续上了香火——刘备即皇帝位，年号章武。但复仇的火焰，将烧尽蜀汉最后的元气。"], []),
    dia("mj_ch7_end", NARR, [
        "秋风五丈原，将星陨落。诸葛亮殁于军中，年五十四。諸葛一生唯谨慎，终究没能走出这最后一步。",
        "克复中原的旗帜缓缓降下。三国的英雄们正在谢幕——而青史的长卷上，也该为你落笔了。"], []),
    dia("mj_finale", NARR, [
        "你从南中的边陲小寨走出，亲历了黄巾、董卓、官渡、赤壁、三分与五丈原——整整五十年乱世，你都走在了其中。",
        "史官在竹简上为你落笔。乱世虽未终结，属于英雄们的时代，已经落幕。",
        "——你的名字，留在了青史之间。"], []),
]

# ---- 剧情 NPC 对话 ----
NEW_DIA += [
    # 朝廷使者 @ 洛阳（ch1_05 犒军论功 / ch3_03 迎驾许都）
    dia("han_envoy_intro", "朝廷使者", [
        "你便是那位义军中的壮士？黄巾既平，朝野震动——天子有旨，义军犒赏，人人有份。",
        "北地风霜苦，壮士这一路，辛苦了。"],
        [opt("叩谢天恩，领受犒赏", "", "accept_quest:ch1_05", {"min_chapter": 1}),
         opt("如今京中局势如何？", "han_envoy_lore"),
         opt("改日再来", "")]),
    dia("han_envoy_lore", "朝廷使者", [
        "唉，实不相瞒——宫中十常侍弄权，大将军与凉州军阀虎视眈眈，天子形同傀儡。",
        "朝廷的告身越发不值钱了，可礼数不能废。乱世里，能把礼数守住的，就只剩下我们这些老骨头了。"],
        [opt("受教了", "han_envoy_intro")]),
    # 曹操 @ 陈留（ch2_02 投义军 / ch2_03 捐军资）
    dia("caocao_intro", "曹操", [
        "（帐中一人按剑而立，目光如鹰）足下便是南中来的义士？孟德失礼了。",
        "乱天下者，必董卓也。吾今散家财、合义兵，发矫诏召天下共讨国贼——足下若不弃，同往讨贼如何？"],
        [opt("愿从将军讨贼！", "", "accept_quest:ch2_02", {"min_chapter": 2}),
         opt("愿捐输军资，助将军成事", "caocao_fund", "give_gold:500",
             {"min_chapter": 2, "quest_active": "ch2_03", "gold": 500}),
         opt("自成一军，各讨各贼", "caocao_solo"),
         opt("改日再来", "")]),
    dia("caocao_solo", "曹操", [
        "（曹操大笑）好！有志气！乱世人各有志，孟德不强求。",
        "今日你我虽不同路，讨贼之心是一致的。他日战场相逢，望足下莫要手软——孟德亦然。"],
        [opt("后会有期", "caocao_intro")]),
    dia("caocao_fund", "曹操", [
        "（曹操接过金帛，郑重一揖）足下之义，孟德记下了。",
        "军中正缺铁器——若能再筹些精铁来，工匠便能为义军打造军械。此恩必报。"],
        [opt("还帐", "caocao_intro")]),
    # 军中谋士 @ 洛阳（ch2_05/ch3_01/ch4_01/ch7_01）
    dia("strategist_intro", "军中谋士", [
        "（布衣葛巾的谋士摇着旧羽扇）足下终于来了。我在这洛阳城头看了半辈子，就等着有人来问——这天下，会往哪里去？"],
        [opt("玉玺下落，究竟如何？（董卓之乱）", "", "accept_quest:ch2_05", {"min_chapter": 2}),
         opt("长安变后，天下如何？（群雄割据）", "", "accept_quest:ch3_01", {"min_chapter": 3}),
         opt("衣带诏是什么？（官渡前夜）", "", "accept_quest:ch4_01", {"min_chapter": 4}),
         opt("汉魏之变，究竟如何？（曹丕代汉）", "", "accept_quest:ch7_01", {"min_chapter": 7}),
         opt("先论论天下大势", "strategist_lore"),
         opt("改日再来", "")]),
    dia("strategist_lore", "军中谋士", [
        "天下大势，分久必合，合久必分。桓灵以降，宦竖弄权，黄巾揭竿——大汉这艘船，底早就朽了。",
        "如今群雄并起，会猎中原。乱世出英雄，英雄亦造乱世。足下这样的豪杰，何不趁势而为一番？"],
        [opt("受教", "strategist_intro")]),
    # 白门楼守将 @ 下邳（ch3_02/ch3_05 + 白门楼大戏）
    dia("bamen_intro", "白门楼守将", [
        "（军候面色复杂地望向城楼）壮士来得不巧，也不巧得刚刚好——楼上正审着那位温侯。",
        "曹公在楼上坐定，被缚的那位却还嚷着「缚太急，乞缓之」。唉……"],
        [opt("徐州道上有曹豹军劫掠流民？", "", "accept_quest:ch3_02", {"min_chapter": 3}),
         opt("登白门楼，看这场审判", "", "accept_quest:ch3_05", {"min_chapter": 3}),
         opt("楼上情形究竟如何？", "bamen_lore"),
         opt("改日再来", "")]),
    dia("bamen_lore", "白门楼守将", [
        "楼上，吕布问刘备：「玄德公，卿为坐上客，何不发一言而相宽乎？」",
        "曹公问刘备：「何如？」刘备只答了一句：「公不见丁建阳、董卓之事乎？」——这话一出，温侯的命就定了。"],
        [opt("丁建阳、董卓……都是吕布的义父，也都死在吕布手上。", "bamen_verdict"),
         opt("只作壁上观，不置一词", "bamen_intro")]),
    dia("bamen_verdict", "白门楼守将", [
        "壮士也这么看？——「是儿最无信者！」曹公于是缢杀吕布。人中吕布，就此落幕。",
        "（军候长叹）他站在天下最高的地方，却谁也不肯忠于谁。这一败，怪不得旁人。"],
        [opt("……回见", "bamen_intro")]),
    # 朝廷御史 @ 寿春（ch3_04）
    dia("yushi_intro", "朝廷御史", [
        "（御史合上卷宗）壮士来得正好。袁术僭号称帝，自封「仲家」——荒唐！",
        "他寿春城里粮尽，军民相食，还敢在郊外建宗庙、设天坛。奉诏讨逆的檄文已发，义师正需人手。"],
        [opt("愿为讨逆先锋！", "", "accept_quest:ch3_04", {"min_chapter": 3}),
         opt("袁术何以至此？", "yushi_lore"),
         opt("改日再来", "")]),
    dia("yushi_lore", "朝廷御史", [
        "袁公路，四世三公之后，坐拥淮南——本有王佐之资，却自己把自己作死了。",
        "我记史一笔：跳梁小丑，僭伪无成。后人说起来，怕是要笑上几百年。"],
        [opt("领教", "yushi_intro")]),
    # 刘备 @ 汝南（ch4_05）
    dia("liubei_intro", "刘备", [
        "（一袭旧袍的将军起身相迎，身后站着一位赤面长髯的大将与一位豹头环眼的莽汉）",
        "足下远来辛苦。备织席贩履之徒，屡战屡败，寄寓汝南——让足下见笑了。"],
        [opt("玄德公大志未灭，何言见笑？", "", "accept_quest:ch4_05", {"min_chapter": 4}),
         opt("公打算往何处去？", "liubei_lore"),
         opt("改日再来", "")]),
    dia("liubei_lore", "刘备", [
        "（刘备望向南方）北方已无容身之处。荆州刘景升与备同宗，或可暂依。",
        "云长、翼德与备，自桃园结义以来，败了多少阵，散了多少次，可人心没散。备相信——人心在，天下就在。"],
        [opt("公之志，令人敬佩", "liubei_intro")]),
    # 荆州从事 @ 襄阳（ch5_01/ch5_02）
    dia("jing_intro", "荆州从事", [
        "（属吏满面愁容）壮士是从北边来的？曹公大军已到宛城——荆州，怕是守不住了。",
        "使君卧病在床，少主年幼怯懦，城中主降的议论一天比一天响。"],
        [opt("襄阳如今情势如何？", "", "accept_quest:ch5_01", {"min_chapter": 5}),
         opt("当阳道上可有战事？", "", "accept_quest:ch5_02", {"min_chapter": 5}),
         opt("改日再来", "")]),
    # 鲁肃 @ 吴（ch5_03）
    dia("lusu_intro", "鲁肃", [
        "（魁梧的将军爽朗一笑）子敬等候足下多时了。刘豫州兵败当阳，曹操檄文已至江东——江东上下，主降之声不绝。",
        "肃曾向将军进言：汉室不可复兴，曹操不可卒除。鼎足江东，以观天下——如今，就看这一盟成与不成。"],
        [opt("长坂追兵犹急，江东如何接应？", "", "accept_quest:ch5_03", {"min_chapter": 5}),
         opt("江东主战主降，孰是孰非？", "lusu_lore"),
         opt("改日再来", "")]),
    dia("lusu_lore", "鲁肃", [
        "（鲁肃摇头）张子布等辈，皆言「迎之」。可迎曹之后，江东诸公还能封侯拜将，将军又能往哪里去？",
        "肃可以降曹换富贵，唯有将军不可降。这话说与孙将军——他懂了。"],
        [opt("子敬高见", "lusu_intro")]),
    # 孙权 @ 吴（ch5_05 + 联盟交互）
    dia("sunquan_intro", "孙权", [
        "（年轻的江东之主按剑而坐，目光灼灼）足下自荆州来？曹操拥百万之众，檄文要孤「会猎于吴」。",
        "诸议皆言迎之。足下以为如何？"],
        [opt("迎之，则江南终非公有时", "sunquan_war", "", {"min_chapter": 5}),
         opt("暂避锋芒，徐图后计", "sunquan_yield"),
         opt("赤壁战况如何？", "", "accept_quest:ch5_05", {"min_chapter": 5}),
         opt("改日再来", "")]),
    dia("sunquan_war", "孙权", [
        "（孙权猛然起身，拔剑砍下案角）孤与老贼，势不两立！再有言迎操者，如同此案！",
        "（他收剑入鞘，转向足下）回去告知刘豫州——孙刘联盟，就此缔结。同舟共济，共破曹贼！",
        "（名声大增）"],
        [opt("愿为盟约奔走", "sunquan_intro")]),
    dia("sunquan_yield", "孙权", [
        "（孙权沉默良久，鲁肃在旁急道）将军！众人之议，专误将军——肃可以降，将军不可！",
        "（孙权长叹）子敬说的是。孤岂能坐拥江东而束手降曹？——备兵，联刘，战！"],
        [opt("将军明断", "sunquan_intro")]),
    # 蒋干 @ 赤壁（ch5_04）
    dia("jianggan_intro", "蒋干", [
        "（说客捋须自得）足下有所不知，某昨夜自周瑜营中『做客』归来——得了一封要紧的书信，公瑾亲笔！",
        "曹丞相览信必喜。看来这赤壁之战，不日便可收场喽。"],
        [opt("那封书信，只怕有诈", "", "accept_quest:ch5_04", {"min_chapter": 5}),
         opt("周郎待先生如何？", "jianggan_lore"),
         opt("改日再来", "")]),
    dia("jianggan_lore", "蒋干", [
        "（他犹豫了一下，压低声音）实不相瞒……公瑾设宴，只叙旧情，绝口不提军务。",
        "夜里某「无意」翻到他案头书信——蔡瑁张允『通吴』的字据！某连夜带了回来。只是……为何总觉得哪里不对？"],
        [opt("曹丞相连环锁船，此信一至，两员水军都督人头落地——中计的是丞相啊！", "jianggan_awake"),
         opt("且看局势再定", "jianggan_intro")]),
    dia("jianggan_awake", "蒋干", [
        "（蒋干面如土色，喃喃道）连环计……某竟成了递刀之人？！",
        "（他一把抓住足下手腕）壮士千万莫要声张！罢了罢了——江东战局，全凭壮士一言了。"],
        [opt("告辞", "jianggan_intro")]),
    # 法正 @ 成都（ch6_01/ch6_02/ch6_04/ch7_02）
    dia("fazheng_intro", "法正", [
        "（太守抬眼打量来客）足下便是随军南来的义士？正候你多时了。",
        "刘季玉暗弱，坐拥天府之国而不能自保。明主入川，是天时——也是益州士民之望。"],
        [opt("入川军情如何？", "", "accept_quest:ch6_01", {"min_chapter": 6}),
         opt("雒城道中伏兵凶险", "", "accept_quest:ch6_02", {"min_chapter": 6}),
         opt("汉中战事如何？", "", "accept_quest:ch6_04", {"min_chapter": 6}),
         opt("（章武建元之贺）", "", "accept_quest:ch7_02", {"min_chapter": 7}),
         opt("改日再来", "")]),
    # 诸葛亮 @ 成都（ch6_03/ch7_04/ch7_07 + 五丈原遗言）
    dia("zhuge_intro", "诸葛亮", [
        "（羽扇纶巾的丞相搁下手中军报）先生请坐。亮常闻南中义士之名——今日得见，幸甚。",
        "军务繁忙，先生若有问，亮知无不言。"],
        [opt("益州新政如何？（成都易主）", "", "accept_quest:ch6_03", {"min_chapter": 6}),
         opt("白帝托孤之后……（建兴之初）", "", "accept_quest:ch7_04", {"min_chapter": 7}),
         opt("丞相北伐在即，可有嘱托？（五丈原前夜）", "", "accept_quest:ch7_07", {"min_chapter": 7}),
         opt("愿闻天下三分之势", "zhuge_lore"),
         opt("改日再来", "")]),
    dia("zhuge_lore", "诸葛亮", [
        "（羽扇轻摇）自董卓已来，豪杰并起。曹操比于袁绍，则名微而众寡，然操遂能克绍，以弱为强者，非惟天时，抑亦人谋也。",
        "今操拥百万之众，挟天子而令诸侯，此诚不可与争锋。孙权据有江东，已历三世，可以为援而不可图也。",
        "天下有变，则霸业可成，汉室可兴——此亮为将军谋之三足鼎立也。"],
        [opt("先生高瞻远瞩，佩服", "zhuge_intro")]),
    # 史官 @ 洛阳（ch7_08 结局）
    dia("historian_intro", "史官", [
        "（白发老者抱着一摞竹简，浑浊的双眼在足下身上停留片刻）",
        "老朽著史五十年，见过多少王侯将相在我笔下化为几行字。足下这五十年乱世行走的经历——说来听听？"],
        [opt("请史官为我的乱世一生落笔", "", "accept_quest:ch7_08", {"min_chapter": 7}),
         opt("史笔如铁，如何落笔？", "historian_lore"),
         opt("改日再来", "")]),
    dia("historian_lore", "史官", [
        "「史笔如铁」四字，说来容易。写董卓，要写他的暴，也要写他的枭；写吕布，要写他的勇，也要写他的反复。",
        "人不是一行字。可史书留给每个人的，偏偏就只有一行字——足下想让后人读到哪一行呢？"],
        [opt("……请老先生落笔", "historian_intro")]),
]
n_d = 0
for d in NEW_DIA:
    if d["id"] not in have_d:
        dl.append(d)
        n_d += 1
save("dialogues.json", dialogues)
print("dialogues: +%d" % n_d)
print("ALL DONE")
