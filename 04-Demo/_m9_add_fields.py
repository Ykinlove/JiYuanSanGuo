# -*- coding: utf-8 -*-
"""_m9_add_fields.py — M9 一次性数据表字段添加脚本

给 4 张数据表追加 M9 标记字段（仅追加，不删除/不改既有字段值）：
  - cities.json   : mainline_chapter (1-7)
  - heroes6.json  : story_role + exclusive_quest_id
  - factions6.json: storyline_tag + faction_line
  - quests6.json  : quest_type (mainline/branch/faction/hidden/commission/life)

字段值规则参考 02-策划文档/D-02 / D-04 / D-08 / D-09 设计。
幂等：若字段已存在则按规则重新计算覆盖；不影响其他字段。
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
    # 末尾补一个换行，与原文件保持一致
    with io.open(p, "a", encoding="utf-8") as f:
        f.write("\n")


# ============ 1. cities.json 加 mainline_chapter ============

# 显式 id → chapter 映射（取自 D-02 引用清单"首次出现"原则）
CITY_CHAPTER = {
    # 第1章 黄巾之乱 184
    "scene_19": 1, "scene_21": 1, "scene_33": 1, "scene_23": 1,
    "scene_32": 1, "scene_17": 1, "scene_40": 1, "scene_48": 1,
    # 第2章 董卓之乱 189（洛阳/许昌/襄阳/长安已在 ch1，不重复）
    "scene_5": 2, "scene_22": 2, "scene_35": 2,
    # 第3章 群雄割据 190-199
    "scene_38": 3, "scene_39": 3, "scene_47": 3, "scene_11": 3,
    # 第4章 官渡 200
    "scene_89": 4, "scene_31": 4,
    # 第5章 赤壁 208
    "scene_81": 5, "scene_42": 5, "scene_97": 5, "scene_43": 5,
    "scene_44": 5, "scene_50": 5, "scene_49": 5, "scene_41": 5, "scene_95": 5,
    # 第6章 三国鼎立 220-260
    "scene_27": 6, "scene_26": 6, "scene_28": 6, "scene_16": 6, "scene_29": 6,
    # 第7章 一统 260-280（前面已分配的不重复，无新增显式城池）
}

# 按 region 默认章节（取该区在主线中最早出现的章节）
REGION_DEFAULT_CHAPTER = {
    "reg_nanzhong": 1,   # 南中开局
    "reg_jing":    2,    # 荆州刘表第2章已现
    "reg_yu":      1,    # 中原豫州黄巾之乱
    "reg_yan":     1,    # 中原兖州黄巾之乱
    "reg_sili":    2,    # 司隶董卓之乱
    "reg_yang":    3,    # 扬州孙策平江东第3章
    "reg_xu":      3,    # 徐州吕布袁术第3章
    "reg_you":     2,    # 幽州联军会盟第2章
    "reg_ji":      2,    # 冀州联军会盟第2章
    "reg_bing":    2,    # 并州丁原第2章
    "reg_liang":   2,    # 凉州董卓马腾第2章
    "reg_yi":      6,    # 益州刘备入蜀第6章
    "reg_jiao":    5,    # 交州刘备据荆南第5章
}


def add_cities():
    arr, p = load("cities.json")
    for c in arr:
        cid = c.get("id", "")
        region = c.get("region", "")
        ch = CITY_CHAPTER.get(cid) or REGION_DEFAULT_CHAPTER.get(region, 1)
        c["mainline_chapter"] = ch
    save(p, arr)
    print("cities.json: %d entries, mainline_chapter added" % len(arr))
    return arr


# ============ 2. heroes6.json 加 story_role + exclusive_quest_id ============

# 主角（玩家可选）4 名
HERO_PROTAGONIST = {1, 517, 324, 337}

# 历史主角 = 各势力 lord_role_id 反查（取自 factions6）
LORD_ROLE_IDS = {
    548, 418, 401, 337, 434, 230, 358, 506, 518, 184, 164, 412, 582, 517,
    324, 112, 110, 382, 232, 238, 377, 493, 510, 523, 537, 130, 213, 366,
    171, 206, 372, 514, 469, 89,
}


def add_heroes():
    arr, p = load("heroes6.json")
    cnt = {"主角": 0, "历史主角": 0, "普通": 0}
    for h in arr:
        hid = h.get("id", 0)
        if hid in HERO_PROTAGONIST:
            role = "主角"
        elif hid in LORD_ROLE_IDS:
            role = "历史主角"
        else:
            role = "普通"
        h["story_role"] = role
        # exclusive_quest_id：M9 阶段无专属剧情任务（M14 起再补），统一填 0
        h["exclusive_quest_id"] = 0
        cnt[role] += 1
    save(p, arr)
    print("heroes6.json: %d entries, story_role added (主角=%d 历史主角=%d 普通=%d)" % (
        len(arr), cnt["主角"], cnt["历史主角"], cnt["普通"]))
    return arr


# ============ 3. factions6.json 加 storyline_tag + faction_line ============

# 主线势力 id
MAINLINE_FACTIONS = {
    0, 2, 3, 4, 5, 6, 7, 8, 10, 12, 13, 15, 16, 17, 18, 19, 20,
    24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 43, 888888,
}

# 各线归属
FACTION_LINE = {
    16: "魏线",
    15: "蜀线",
    5:  "吴线",
    0:  "自立线",
    888888: "自立线",
    43: "自立线",  # 黑旗军（玩家可加入的自立势力雏形）
    # 其余默认群雄线
}

# 支线势力 id（其余视为主线）
SIDE_FACTIONS = {9, 11, 14, 39, 40, 41, 42, 44, 45}


def add_factions():
    arr, p = load("factions6.json")
    for f in arr:
        fid = f.get("id", -1)
        # storyline_tag
        if fid in SIDE_FACTIONS:
            f["storyline_tag"] = "支线"
        else:
            f["storyline_tag"] = "主线"
        # faction_line
        if fid in FACTION_LINE:
            f["faction_line"] = FACTION_LINE[fid]
        elif fid in (35, 36, 37, 38):
            # 外族势力归群雄线
            f["faction_line"] = "群雄线"
        else:
            f["faction_line"] = "群雄线"
    save(p, arr)
    print("factions6.json: %d entries, storyline_tag + faction_line added" % len(arr))
    return arr


# ============ 4. quests6.json 加 quest_type ============

# 规则：reward_type=2(金钱) → commission 委托；reward_type=4(名声) → life 生活
# 占位任务（id 38-45）默认 commission


def add_quests():
    arr, p = load("quests6.json")
    for q in arr:
        qid = q.get("id", 0)
        rtype = q.get("reward_type", 0)
        if rtype == 2:
            q["quest_type"] = "commission"
        elif rtype == 4:
            q["quest_type"] = "life"
        else:
            q["quest_type"] = "commission"
    save(p, arr)
    print("quests6.json: %d entries, quest_type added" % len(arr))
    return arr


if __name__ == "__main__":
    print("== M9 数据表字段添加 ==")
    add_cities()
    add_heroes()
    add_factions()
    add_quests()
    print("== 完成 ==")
