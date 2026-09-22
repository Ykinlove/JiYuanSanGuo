# -*- coding: utf-8 -*-
"""生成全国大地图数据（cities.json / terrain.json）。

按《三国大时代》系列全国地图的地理格局划分 12 州域，城池依史实分布。
地图尺寸 3600 x 2200（约南中地图的 2.4 倍面积）。
运行一次即可，之后手工微调 JSON 更方便。
"""
import json
import math
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(ROOT, "assets", "data")

W, H = 19440, 11880
SCALE = 4.6          ## 全局坐标放大系数：城池间距从 ~350px → ~1260px
MIN_DIST = 1350.0    ## 任意两地点的最小间距（步行 5 秒以上 @250px/s）
_ROAD_SNAP = {}      ## 缩放后原始坐标 → 松弛后新坐标（官道端点吸附用）

# ------------------------------------------------------------------
# 州域划分（矩形区域 + 地形类型）
# 顺序：先大后小，绘制时后画的覆盖先画的
# ------------------------------------------------------------------
REGIONS = [
    # 北方（幽并冀）
    ("reg_youzhou",    "幽州",      [1900, 60, 900, 260],  "plain"),
    ("reg_bingzhou",   "并州",      [1350, 120, 600, 420], "mountain"),
    ("reg_jizhou",     "冀州",      [1750, 320, 800, 380], "plain"),
    # 中原
    ("reg_sili",       "司隶",      [1450, 520, 620, 380], "plain"),
    ("reg_yuzhou",     "豫州",      [1550, 880, 700, 360], "plain"),
    ("reg_yanzhou",    "兖州",      [2050, 640, 620, 320], "plain"),
    ("reg_xuzhou",     "徐州",      [2500, 700, 620, 380], "plain"),
    ("reg_qingzhou",   "青州",      [2900, 560, 560, 320], "plain"),
    # 西陲
    ("reg_yongzhou",   "雍州",      [900, 480, 600, 400],  "plain"),
    ("reg_liangzhou",  "凉州",      [400, 300, 640, 480],  "desert"),
    ("reg_hanzhong",   "汉中",      [1180, 820, 480, 300], "mountain"),
    ("reg_yizhou",     "益州",      [900, 1050, 780, 460], "plain"),
    # 南中（已有区域，保留并放大）
    ("reg_jianning",   "建宁平原",  [760, 1560, 700, 400], "plain"),
    ("reg_dianchi",    "滇池水域",  [900, 1780, 480, 300], "swamp"),
    ("reg_yongchang",  "永昌盆地",  [440, 1700, 460, 320], "plain"),
    ("reg_wuxi",       "五溪山谷",  [1420, 1480, 480, 300], "mountain"),
    ("reg_gaoligong",  "高黎贡山",  [120, 1400, 420, 380], "mountain"),
    ("reg_manhuang",   "蛮荒密林",  [180, 1880, 700, 280], "forest"),
    # 荆州
    ("reg_jingzhou",   "荆州",      [1500, 1120, 700, 400], "plain"),
    ("reg_nanyang",    "南阳",      [1420, 960, 460, 260], "plain"),
    # 江东
    ("reg_yangzhou",   "扬州",      [2300, 1150, 800, 460], "plain"),
    ("reg_jiaozhou",   "交州",      [1900, 1700, 700, 420], "forest"),
    # 特殊地形
    ("reg_hexi",       "河西走廊",  [260, 560, 400, 300],  "desert"),
    ("reg_bashu",      "巴蜀山道",  [1120, 1380, 360, 240], "mountain"),
]

# ------------------------------------------------------------------
# 城池：(id, 名字, 类型, 州域, 势力, x, y, 等级, 人口, 特殊产出, 描述)
# ------------------------------------------------------------------
CITIES = [
    # ============ 南中（首个 Demo 区，保留 11 个地点）============
    ("city_jianning",  "建宁",   "city",    "reg_jianning",  "nanman",   1100, 1680, 5, 30000, "铜矿",
     "南中首府，铜矿丰饶，乃南蛮政令所出之地。"),
    ("city_yunnan",    "云南",   "city",    "reg_dianchi",   "nanman",   1360, 1760, 4, 18000, "药材",
     "滇池之畔的坚城，盛产南中药材。"),
    ("city_dianchi",   "滇池城", "city",    "reg_dianchi",   "nanman",   1080, 1900, 4, 16000, "渔获",
     "依滇池而建，水产丰美。"),
    ("city_yongchang", "永昌",   "city",    "reg_yongchang", "nanman",    640, 1820, 4, 20000, "玉石",
     "西南边陲重镇，玉石与象马由此而出。"),
    ("city_zangke",    "牂牁",   "city",    "reg_wuxi",      "nanman",   1620, 1560, 3, 17000, "木材",
     "南中东北门户，扼守五溪山道。"),
    ("village_axiang", "阿乡寨", "village", "reg_jianning",  "player",    940, 1600, 1,  3000, "山货",
     "山中的小寨，民风淳朴。"),
    ("village_zhujia", "祝家寨", "village", "reg_dianchi",   "nanman",   1480, 1860, 2,  4000, "硫磺",
     "祝融氏世居之寨，寨中女子亦能战。"),
    ("pass_lushui",    "泸水渡口", "pass",  "reg_jianning",  "nanman",   1300, 1620, 0,  0,    "",
     "金沙江上的要害渡口，过河需水军相助。"),
    ("pass_wuxi",      "五溪山谷", "pass",  "reg_wuxi",      "neutral",  1500, 1480, 0,  0,    "",
     "五溪蛮所居的险要山谷。"),
    ("ruin_tonglong",  "毒龙潭", "ruin",    "reg_manhuang",  "neutral",   520, 1960, 0,  0,    "草药",
     "瘴气弥漫的深潭，传闻潭中有异兽。"),
    ("ruin_feicui",    "翡翠矿洞", "ruin",  "reg_jianning",  "neutral",   820, 1500, 0,  0,    "玉石",
     "废弃的翡翠矿洞，仍有零星矿脉。"),

    # ============ 益州 / 汉中 ============
    ("city_chengdu",   "成都",   "city",    "reg_yizhou",    "liu_zhang", 1150, 1150, 5, 45000, "蜀锦",
     "天府之国，沃野千里，蜀锦行销天下。"),
    ("city_jiangzhou", "江州",   "city",    "reg_yizhou",    "liu_zhang", 1420, 1250, 4, 22000, "盐铁",
     "巴郡重镇，扼守长江上游。"),
    ("city_zitong",    "梓潼",   "city",    "reg_bashu",     "liu_zhang", 1300, 1080, 3, 15000, "木材",
     "剑阁以北的门户，山道险峻。"),
    ("pass_jianmen",   "剑门关", "pass",    "reg_bashu",     "liu_zhang", 1320, 1000, 0, 0,     "",
     "天下第一险关，一夫当关万夫莫开。"),
    ("city_hanzhong",  "汉中",   "city",    "reg_hanzhong",  "han",       1440, 900,  4, 26000, "粮草",
     "沃野千里的盆地，高祖由此定天下。"),
    ("city_shangyong", "上庸",   "city",    "reg_hanzhong",  "han",       1620, 940,  3, 12000, "木材",
     "汉水上游的小城，山高林密。"),
    ("city_jiangzhou2","江阳",   "city",    "reg_yizhou",    "liu_zhang", 1400, 1400, 3, 13000, "盐",
     "沱江入江之口，盐井密布。"),
    ("city_jiading",   "犍为",   "city",    "reg_yizhou",    "liu_zhang", 1120, 1300, 3, 14000, "铁矿",
     "铁山所在，蜀中兵器多出于此。"),

    # ============ 雍州 / 凉州（董卓起家）============
    ("city_changan",   "长安",   "city",    "reg_sili",      "dong_zhuo", 1500, 660,  5, 50000, "铜矿",
     "西汉旧都，城阙巍峨，然战火之后已见凋敝。"),
    ("city_luoyang",   "洛阳",   "city",    "reg_sili",      "dong_zhuo", 1680, 680,  5, 55000, "典籍",
     "东都洛阳，天下之中。董卓焚城迁都后，只剩焦土。"),
    ("city_tianshui",  "天水",   "city",    "reg_yongzhou",  "dong_zhuo", 1080, 620,  3, 18000, "马匹",
     "陇右要地，羌汉杂处，出良马。"),
    ("city_wudu",      "武都",   "city",    "reg_yongzhou",  "dong_zhuo", 1040, 760,  2, 9000,  "药材",
     "氐人所居的山城。"),
    ("city_xiliang",   "西凉",   "city",    "reg_liangzhou", "dong_zhuo",  620, 400,  4, 16000, "战马",
     "西凉铁骑的故乡，风沙漫天。"),
    ("city_jincheng",  "金城",   "city",    "reg_hexi",      "dong_zhuo",  560, 620,  3, 11000, "马匹",
     "黄河穿城而过，扼守河西咽喉。"),
    ("city_zhangye",   "张掖",   "city",    "reg_hexi",      "dong_zhuo",  420, 700,  2, 8000,  "玉石",
     "河西四郡之一，商道重镇。"),

    # ============ 并州 / 幽州 ============
    ("city_jinyang",   "晋阳",   "city",    "reg_bingzhou",  "wei_shao",  1580, 300,  4, 24000, "铁矿",
     "并州治所，城坚池深。"),
    ("city_shangdang", "上党",   "city",    "reg_bingzhou",  "wei_shao",  1520, 440,  3, 15000, "铁",
     "太行山中的高城，易守难攻。"),
    ("city_jicheng",   "蓟城",   "city",    "reg_youzhou",   "gongsun_zan", 2180, 220, 4, 20000, "马匹",
     "幽州治所，北接乌桓，多良马。"),
    ("city_beiping",   "北平",   "city",    "reg_youzhou",   "gongsun_zan", 2380, 260, 3, 14000, "皮革",
     "辽东以西，白马将军的驻地。"),
    ("city_xiangping", "襄平",   "city",    "reg_youzhou",   "gongsun_zan", 2520, 160, 2, 10000, "人参",
     "辽东郡治，与高句丽相邻。"),
    ("city_dai_county", "代县",  "city",    "reg_bingzhou",  "wei_shao",  1900, 200,  2, 9000,  "马匹",
     "雁门关外的小县，常有胡骑出没。"),

    # ============ 冀州 / 兖州（袁绍）============
    ("city_ye",        "邺城",   "city",    "reg_jizhou",    "wei_shao",  2080, 440,  5, 40000, "粮草",
     "冀州首府，袁本初据此雄视天下。"),
    ("city_xindu",     "信都",   "city",    "reg_jizhou",    "wei_shao",  2140, 520,  3, 16000, "丝绸",
     "冀州南部富庶之地。"),
    ("city_puyang",    "濮阳",   "city",    "reg_yanzhou",   "wei_shao",  2120, 660,  3, 17000, "粮草",
     "黄河岸边的要冲，曹操曾以此为基。"),
    ("city_chenliu",   "陈留",   "city",    "reg_yanzhou",   "wei_shao",  1980, 740,  3, 18000, "粮草",
     "中原腹地，屯粮之所。"),
    ("city_juancheng", "鄄城",   "city",    "reg_yanzhou",   "wei_shao",  2160, 760, 2, 12000, "木材",
     "兖州南部小城。"),

    # ============ 豫州 ============
    ("city_xuchang",   "许昌",   "city",    "reg_yuzhou",    "wei_shao",  1800, 880,  4, 28000, "粮草",
     "颍川之地，人才辈出。曹操挟天子后以此为都。"),
    ("city_runan",     "汝南",   "city",    "reg_yuzhou",    "yuan_shu",  1900, 960,  3, 22000, "粮草",
     "人口繁盛的大郡，袁术在此称帝。"),
    ("city_nanyang2",  "宛城",   "city",    "reg_nanyang",   "yuan_shu",  1560, 940,  4, 26000, "铁矿",
     "南阳郡治，光武帝的故乡。"),
    ("city_chen_county","陈县",  "city",    "reg_yuzhou",    "yuan_shu",  1960, 900,  2, 13000, "粮草",
     "陈国故地，地势平坦。"),
    ("city_wancheng",  "谯县",   "city",    "reg_yuzhou",    "wei_shao",  2020, 820, 3, 15000, "药材",
     "曹操的故里，华佗亦生于此。"),

    # ============ 徐州 / 青州 ============
    ("city_xiapi",     "下邳",   "city",    "reg_xuzhou",    "gongsun_zan", 2680, 800, 4, 24000, "丝绸",
     "徐州重镇，泗水与沂水交汇。"),
    ("city_pengcheng", "彭城",   "city",    "reg_xuzhou",    "yuan_shu",  2600, 760,  3, 20000, "铁矿",
     "西楚故都，兵家必争。"),
    ("city_guangling", "广陵",   "city",    "reg_xuzhou",    "yuan_shu",  2760, 900,  3, 19000, "海盐",
     "临江近海，盐利丰厚。"),
    ("city_beihai",    "北海",   "city",    "reg_qingzhou",  "wei_shao",  3020, 600,  3, 18000, "海盐",
     "孔融曾治此地，文风颇盛。"),
    ("city_linzi",     "临淄",   "city",    "reg_qingzhou",  "wei_shao",  2960, 500,  3, 17000, "丝绸",
     "齐国故都，工技精巧。"),

    # ============ 荆州 ============
    ("city_xiangyang", "襄阳",   "city",    "reg_jingzhou",  "liu_zhang", 1660, 1180, 5, 32000, "粮草",
     "荆州治所，控扼汉水，兵家必争之地。"),
    ("city_jiangling", "江陵",   "city",    "reg_jingzhou",  "liu_zhang", 1700, 1300, 4, 25000, "木材",
     "长江中游重镇，粮仓所在。"),
    ("city_jiangxia",  "江夏",   "city",    "reg_jingzhou",  "han",       1900, 1260, 3, 21000, "鱼获",
     "长江与汉水交汇处，扼守要津。"),
    ("city_changsha",  "长沙",   "city",    "reg_jingzhou",  "han",       1640, 1420, 4, 24000, "稻米",
     "荆南四郡之首，物产丰饶。"),
    ("city_wuling",    "武陵",   "city",    "reg_jingzhou",  "han",       1480, 1400, 3, 16000, "药材",
     "五溪蛮所居之地，山深林密。"),
    ("city_guiyang",   "桂阳",   "city",    "reg_jingzhou",  "han",       1700, 1560, 3, 14000, "铜矿",
     "荆南南端，近南中之地。"),
    ("city_lingling",  "零陵",   "city",    "reg_jingzhou",  "han",       1520, 1580, 2, 12000, "木材",
     "湘水上游的山城。"),
    ("city_xinye",     "新野",   "city",    "reg_nanyang",   "liu_zhang", 1620, 1020, 2, 10000, "粮草",
     "南阳南部小县，刘备曾屯于此。"),

    # ============ 扬州（江东）============
    ("city_jianye",    "建业",   "city",    "reg_yangzhou",  "wu",        2480, 1300, 4, 30000, "丝绸",
     "长江下游形胜之地，孙权据此建都。"),
    ("city_wu",        "吴郡",   "city",    "reg_yangzhou",  "wu",        2660, 1360, 4, 28000, "海盐",
     "江东首富之郡，孙氏三世经营。"),
    ("city_kuaiji",    "会稽",   "city",    "reg_yangzhou",  "wu",        2820, 1440, 4, 26000, "海盐",
     "东南大郡，山海之利尽在其中。"),
    ("city_jianan",    "建安",   "city",    "reg_yangzhou",  "wu",        2800, 1600, 3, 15000, "木材",
     "闽越故地，山高林密。"),
    ("city_lujiang",   "庐江",   "city",    "reg_yangzhou",  "wu",        2280, 1160, 3, 20000, "稻米",
     "江淮之间的要冲。"),
    ("city_shouchun",  "寿春",   "city",    "reg_yangzhou",  "yuan_shu",  2200, 1040, 4, 26000, "稻米",
     "淮南重镇，袁术据此称帝。"),
    ("city_yuzhang",   "豫章",   "city",    "reg_yangzhou",  "wu",        2280, 1400, 3, 19000, "木材",
     "江西大郡，赣水贯穿全境。"),

    # ============ 交州 ============
    ("city_panyu",     "番禺",   "city",    "reg_jiaozhou",  "wu",        2320, 1760, 3, 16000, "香料",
     "南海之滨的港口，海外商船云集。"),
    ("city_cangwu",    "苍梧",   "city",    "reg_jiaozhou",  "wu",        2080, 1780, 2, 12000, "木材",
     "交州北部，与荆南相接。"),
    ("city_hepu",      "合浦",   "city",    "reg_jiaozhou",  "wu",        2100, 1900, 2, 9000,  "珍珠",
     "以珍珠闻名，采珠之民众多。"),
]

FACTIONS_CN = {
    "wei": "曹魏", "shu": "蜀汉", "wu": "东吴", "wei_shao": "袁绍",
    "dong_zhuo": "董卓", "nanman": "南蛮", "liu_zhang": "刘璋",
    "yuan_shu": "袁术", "gongsun_zan": "公孙瓒", "han": "汉室",
    "player": "自立",
}


def build_cities():
    out = []
    pts = []       # 缩放后的坐标，供最小间距松弛用
    orig = []      # 缩放后的原始坐标（供官道端点吸附）
    for cid, name, ctype, region, faction, x, y, level, pop, spec, desc in CITIES:
        p = [x * SCALE, y * SCALE]
        orig.append(list(p))
        pts.append(p)

    # 按州域预扩张：城池太密的州域从质心向外撑开，
    # 保证域内跨度 >= ceil(sqrt(n)) * MIN_DIST * 0.9
    by_region = {}
    for idx, entry in enumerate(CITIES):
        by_region.setdefault(entry[3], []).append(idx)
    for rid, idxs in by_region.items():
        if len(idxs) < 2:
            continue
        cx = sum(pts[i][0] for i in idxs) / len(idxs)
        cy = sum(pts[i][1] for i in idxs) / len(idxs)
        actual = max(
            math.hypot(pts[a][0] - pts[b][0], pts[a][1] - pts[b][1])
            for ai, a in enumerate(idxs) for b in idxs[ai + 1:])
        needed = math.ceil(len(idxs) ** 0.5) * MIN_DIST * 0.9
        if actual < 1.0 or actual >= needed:
            continue
        factor = min(needed / actual, 5.0)
        for i in idxs:
            pts[i][0] = cx + (pts[i][0] - cx) * factor
            pts[i][1] = cy + (pts[i][1] - cy) * factor

    # 锚定基准 = 预扩张后的位置（松弛只做局部微调，不回缩）
    orig = [list(p) for p in pts]

    MARGIN = 160.0
    # 锚定松弛：城池互相排斥到最小间距，但被弹簧拉回缩放后的原位，
    # 只允许「局部扩散」——密集城市群摊开，而整体地理方位不变。
    for _ in range(2500):
        moved = False
        for i in range(len(pts)):
            for j in range(i + 1, len(pts)):
                dx = pts[j][0] - pts[i][0]
                dy = pts[j][1] - pts[i][1]
                d2 = dx * dx + dy * dy
                if d2 >= MIN_DIST * MIN_DIST or d2 < 1e-6:
                    continue
                d = d2 ** 0.5
                push = (MIN_DIST - d) * 0.25
                ux, uy = dx / d, dy / d
                pts[i][0] -= ux * push
                pts[i][1] -= uy * push
                pts[j][0] += ux * push
                pts[j][1] += uy * push
                moved = True
        # 锚定弱弹簧：保持大方位，允许局部摊开 + 边界约束
        for k, p in enumerate(pts):
            o = orig[k]
            p[0] += (o[0] - p[0]) * 0.015
            p[1] += (o[1] - p[1]) * 0.015
            if p[0] < MARGIN:
                p[0] += (MARGIN - p[0]) * 0.5; moved = True
            if p[0] > W - MARGIN:
                p[0] -= (p[0] - (W - MARGIN)) * 0.5; moved = True
            if p[1] < MARGIN:
                p[1] += (MARGIN - p[1]) * 0.5; moved = True
            if p[1] > H - MARGIN:
                p[1] -= (p[1] - (H - MARGIN)) * 0.5; moved = True
            if abs(p[0] - o[0]) > 1.0 or abs(p[1] - o[1]) > 1.0:
                moved = True
        if not moved:
            break

    # 整体居中：让内容落在地图中央（保留 160 边距）
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    off_x = (W - (max(xs) - min(xs))) * 0.5 - min(xs)
    off_y = (H - (max(ys) - min(ys))) * 0.5 - min(ys)
    for p in pts:
        p[0] = max(MARGIN, min(W - MARGIN, p[0] + off_x))
        p[1] = max(MARGIN, min(H - MARGIN, p[1] + off_y))

    # 布局元数据：NPC / 玩家出生点同步用（锚点 = 阿乡寨）
    anchor_idx = next(i for i, c in enumerate(CITIES) if c[0] == "village_axiang")
    with open(os.path.join(DATA, "_layout_meta.json"), "w", encoding="utf-8") as f:
        json.dump({
            "offset": [round(off_x, 1), round(off_y, 1)],
            "anchor_final": [round(v, 1) for v in pts[anchor_idx]],
            "anchor_orig_scaled": [round(v, 1) for v in orig[anchor_idx]],
        }, f, ensure_ascii=False, indent=2)

    # 官道端点吸附表：缩放后原始坐标 → 松弛后新坐标
    snap = {}
    for k, o in enumerate(orig):
        snap[(round(o[0]), round(o[1]))] = pts[k]
    _ROAD_SNAP.clear()
    _ROAD_SNAP.update(snap)

    for idx, (cid, name, ctype, region, faction, x, y, level, pop, spec, desc) in enumerate(CITIES):
        buildings = ["farm", "market", "barracks", "smith"] if ctype == "city" else []
        tags = [faction]
        if faction == "player":
            tags.append("own")
        elif faction == "neutral":
            tags.append("neutral")
        else:
            tags.append("foreign")

        out.append({
            "id": cid,
            "name": name,
            "title": _title(ctype, faction, level),
            "type": ctype,
            "level": level,
            "region": region,
            "faction": faction,
            "faction_name": FACTIONS_CN.get(faction, faction),
            "map_x": round(pts[idx][0]),
            "map_y": round(pts[idx][1]),
            "defense": 40 + level * 14 if ctype == "city" else 20,
            "population": pop,
            "morale": 70,
            "garrison": pop // 40,
            "specialty": spec,
            "buildings": buildings,
            "tags": tags,
            "is_capital": cid in ("city_jianning", "city_ye", "city_xuchang",
                                  "city_jianye", "city_chengdu", "city_luoyang",
                                  "city_xiangyang", "city_changan"),
            "description": desc,
        })
    return out


def _title(ctype, faction, level):
    fname = FACTIONS_CN.get(faction, "")
    if ctype == "village":
        return "%s · 寨落" % fname if fname else "寨落"
    if ctype == "pass":
        return "关隘"
    if ctype == "ruin":
        return "遗迹"
    if level >= 5:
        return "%s · 大城" % fname
    if level >= 4:
        return "%s · 重镇" % fname
    return "%s · 城" % fname


def build_terrain(city_pos):
    regions = []
    for rid, rname, rect, terr in REGIONS:
        regions.append({
            "id": rid, "name": rname,
            "rect": [round(rect[0] * SCALE), round(rect[1] * SCALE),
                     round(rect[2] * SCALE), round(rect[3] * SCALE)],
            "terrain": terr,
        })

    # 官道：按「城池 ID 走史实走廊」连线。坐标取松弛后的城池最终位置，
    # 端点精确落在城上，不再出现悬空乱线。
    road_routes = [
        ("幽辽道",   ["city_jicheng", "city_beiping", "city_xiangping"]),
        ("河北驿道", ["city_jicheng", "city_xindu", "city_ye"]),
        ("并州道",   ["city_jicheng", "city_dai_county", "city_jinyang",
                      "city_shangdang", "city_luoyang"]),
        ("函谷道",   ["city_luoyang", "city_changan"]),
        ("洛官道",   ["city_luoyang", "city_chenliu"]),
        ("许洛道",   ["city_luoyang", "city_xuchang", "city_runan"]),
        ("中原东道", ["city_chenliu", "city_juancheng", "city_pengcheng",
                      "city_xiapi", "city_guangling"]),
        ("青徐道",   ["city_juancheng", "city_beihai", "city_linzi"]),
        ("宛襄道",   ["city_xuchang", "city_nanyang2", "city_xinye", "city_xiangyang"]),
        ("荆襄道",   ["city_xiangyang", "city_jiangling", "city_jiangxia"]),
        ("淮南道",   ["city_jiangxia", "city_lujiang", "city_shouchun"]),
        ("江东道",   ["city_lujiang", "city_jianye", "city_wu", "city_kuaiji"]),
        ("豫章道",   ["city_jiangxia", "city_yuzhang"]),
        ("长沙道",   ["city_jiangling", "city_changsha", "city_guiyang", "city_panyu"]),
        ("零桂道",   ["city_changsha", "city_lingling", "city_cangwu", "city_panyu"]),
        ("交州道",   ["city_panyu", "city_cangwu", "city_hepu"]),
        ("陇右道",   ["city_changan", "city_tianshui", "city_jincheng", "city_zhangye"]),
        ("街亭道",   ["city_xiliang", "city_jincheng"]),
        ("阴平道",   ["city_tianshui", "city_wudu", "pass_jianmen"]),
        ("金牛道",   ["city_changan", "city_hanzhong", "pass_jianmen",
                      "city_zitong", "city_chengdu"]),
        ("米仓道",   ["city_hanzhong", "city_jiangzhou"]),
        ("汉沔道",   ["city_hanzhong", "city_shangyong", "city_xiangyang"]),
        ("巴江道",   ["city_chengdu", "city_jiangzhou", "city_jiangzhou2"]),
        ("南中道",   ["city_chengdu", "city_jiading", "city_jiangzhou2",
                      "city_zangke", "city_jianning"]),
        ("滇池道",   ["city_jianning", "city_dianchi", "village_axiang"]),
        ("泸水道",   ["city_yunnan", "pass_lushui", "city_yongchang"]),
        ("五溪道",   ["city_wuling", "pass_wuxi", "city_zangke"]),
        ("寨落小道", ["city_jianning", "village_zhujia"]),
    ]

    def _lerp_pts(a, b):
        """两城之间插 1 个中间点，让道路有一点自然的弯曲。"""
        mx = (a[0] + b[0]) * 0.5 + (b[1] - a[1]) * 0.06
        my = (a[1] + b[1]) * 0.5 - (b[0] - a[0]) * 0.06
        return [[round(mx), round(my)]]

    roads_scaled = []
    for n, route in road_routes:
        pts = []
        for cid in route:
            c = city_pos[cid]
            pts.append([int(c[0]), int(c[1])])
        # 每段之间插一个中间点
        dense = [pts[0]]
        for k in range(1, len(pts)):
            dense.extend(_lerp_pts(pts[k - 1], pts[k]))
            dense.append(pts[k])
        roads_scaled.append({"name": n, "points": dense})

    # 河流：史实走向（黄河河套 / 长江 / 汉水 / 淮河 / 泸水）。
    # 河流不可通行，只能从 fords 渡口渡过（数据供渲染与移动阻挡共用）。
    def _anchor(cid, dx=0.0, dy=0.0):
        c = city_pos[cid]
        return [int(c[0] + dx * SCALE), int(c[1] + dy * SCALE)]

    rivers = [
        {"id": "river_yellow", "name": "黄河",
         "points": [_anchor("city_jincheng", -0.6, 0.2),
                    _anchor("city_jincheng", -0.2, -0.5),
                    _anchor("city_dai_county", -0.9, -0.4),
                    _anchor("city_dai_county", -0.5, -0.1),
                    _anchor("city_jinyang", -0.35, -0.15),
                    _anchor("city_luoyang", -0.25, -0.3),
                    _anchor("city_luoyang", 0.1, -0.18),
                    _anchor("city_puyang", -0.1, -0.12),
                    _anchor("city_beihai", -0.15, -0.35)],
         "fords": [_anchor("city_luoyang", 0.1, -0.18),
                   _anchor("city_puyang", -0.1, -0.12),
                   _anchor("city_jicheng", 0.3, 0.25)]},
        {"id": "river_yangzi", "name": "长江",
         "points": [_anchor("city_jiading", -0.3, 0.35),
                    _anchor("city_jiading", 0.1, 0.15),
                    _anchor("city_jiangzhou", 0.0, 0.18),
                    _anchor("city_jiangzhou2", 0.05, 0.12),
                    _anchor("city_jiangling", 0.0, 0.22),
                    _anchor("city_jiangxia", 0.0, 0.16),
                    _anchor("city_lujiang", -0.05, 0.25),
                    _anchor("city_jianye", 0.0, 0.12),
                    _anchor("city_wu", 0.15, 0.1)],
         "fords": [_anchor("city_jiangling", 0.0, 0.22),
                   _anchor("city_jiangxia", 0.0, 0.16),
                   _anchor("city_jianye", 0.0, 0.12)]},
        {"id": "river_han", "name": "汉水",
         "points": [_anchor("city_hanzhong", 0.1, 0.2),
                    _anchor("city_shangyong", 0.0, 0.15),
                    _anchor("city_xiangyang", 0.0, 0.05),
                    _anchor("city_jiangxia", -0.05, 0.12)],
         "fords": [_anchor("city_xiangyang", 0.0, 0.05)]},
        {"id": "river_huai", "name": "淮河",
         "points": [_anchor("city_runan", 0.25, 0.2),
                    _anchor("city_shouchun", 0.0, 0.15),
                    _anchor("city_guangling", -0.15, 0.05)],
         "fords": [_anchor("city_shouchun", 0.0, 0.15)]},
        {"id": "river_lu", "name": "泸水",
         "points": [_anchor("pass_lushui", -0.25, -0.8),
                    _anchor("pass_lushui", 0.0, 0.0),
                    _anchor("pass_lushui", -0.1, 0.8),
                    _anchor("pass_lushui", -0.3, 1.6)],
         "fords": [_anchor("pass_lushui", 0.0, 0.0)]},
    ]

    return [{
        "id": "china",
        "name": "天下",
        "width": W,
        "height": H,
        "base_terrain": "grass",
        "default_bgm": "res://assets/audio/bgm/world_map.ogg",
        "description": "汉室倾颓，群雄并起。自幽燕至交趾，自西凉至东海，"
                       "九州之地皆入乱世。",
        "regions": regions,
        "roads": roads_scaled,
        "rivers": rivers,
    }]


def main():
    cities = build_cities()
    with open(os.path.join(DATA, "cities.json"), "w", encoding="utf-8") as f:
        json.dump(cities, f, ensure_ascii=False, indent=2)

    city_pos = {c["id"]: (c["map_x"], c["map_y"]) for c in cities}
    terrain = build_terrain(city_pos)
    with open(os.path.join(DATA, "terrain.json"), "w", encoding="utf-8") as f:
        json.dump(terrain, f, ensure_ascii=False, indent=2)

    print("城池 %d 座" % len(cities))
    ty = {}
    for c in cities:
        ty[c["type"]] = ty.get(c["type"], 0) + 1
    print("类型分布:", ty)
    fa = {}
    for c in cities:
        fa[c["faction_name"]] = fa.get(c["faction_name"], 0) + 1
    print("势力分布:", fa)
    print("州域 %d 个 / 官道 %d 条 / 河流 %d 条" % (len(terrain[0]["regions"]), len(terrain[0]["roads"]), len(terrain[0]["rivers"])))
    print("地图尺寸: %d x %d" % (W, H))

    # 最近邻距离报告（验证步行节奏）
    import math
    nn = []
    for i, a in enumerate(cities):
        best = 1e18
        for j, b in enumerate(cities):
            if i == j:
                continue
            d = math.hypot(a["map_x"] - b["map_x"], a["map_y"] - b["map_y"])
            best = min(best, d)
        nn.append(best)
    nn.sort()
    print("最近邻距离: 最小 %d / 中位 %d / 最大 %d px" % (nn[0], nn[len(nn)//2], nn[-1]))
    print("步行换算 @250px/s: 最小 %.1fs / 中位 %.1fs" % (nn[0]/250, nn[len(nn)//2]/250))


if __name__ == "__main__":
    main()
