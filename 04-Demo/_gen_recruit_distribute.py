# -*- coding: utf-8 -*-
"""需求14/#30：可招募武将分布全城池。

现有 recruit_pool.json 仅 8 名武将、集中在少数城。招募按 city_id 过滤
（DataManager.get_recruit_entries），故需为每张有酒馆的城都安排一名可招武将。

策略：保留原有 8 条带精致 greeting/note 的条目，其余酒馆城用这 8 名武将
轮转补条目，实现「全城池可招」。hero_id 均为 characters.json 已存在的字符串 id。
"""
import json
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(ROOT, "assets", "data")


def load(name):
    with open(os.path.join(DATA, name), encoding="utf-8") as f:
        return json.load(f)


def main():
    pool = load("recruit_pool.json")
    scenes = load("scenes6.json")
    chars = load("characters.json")

    scene_items = scenes if isinstance(scenes, list) else scenes.get("scenes", scenes.get("data", []))
    char_items = chars if isinstance(chars, list) else chars.get("heroes", chars.get("data", []))
    name_map = {str(c.get("id", "")): c.get("name", "") for c in char_items}

    existing = pool.get("pool", [])
    covered = {str(e.get("city_id", "")) for e in existing}
    heroes = [e.get("hero_id") for e in existing]  # 8 名已校验存在的武将

    taverns = [x for x in scene_items
               if x.get("id") != 1 and (x.get("buildings") or {}).get("tavern", 0) == 1]
    taverns.sort(key=lambda x: x["id"])

    added = 0
    idx = 0
    for x in taverns:
        cid = "scene_%d" % int(x["id"])
        if cid in covered:
            continue
        hero = heroes[idx % len(heroes)]
        idx += 1
        diff = 2 + (idx % 4)          # 2..5 难度梯度
        name = name_map.get(hero, hero)
        entry = {
            "hero_id": hero,
            "city_id": cid,
            "level_range": [1, 10],
            "difficulty": diff,
            "gold_extra": 0,
            "require_fame": 5 * diff,
            "note": "%s 亦在此城游历，等候识主。" % name,
            "greeting": "（%s 于%s等候将军。）" % (name, x["name"]),
        }
        existing.append(entry)
        covered.add(cid)
        added += 1

    pool["pool"] = existing
    with open(os.path.join(DATA, "recruit_pool.json"), "w", encoding="utf-8") as f:
        json.dump(pool, f, ensure_ascii=False, indent=2)

    print("新增招募条目: %d | 招募池总数: %d | 酒馆城: %d" % (added, len(existing), len(taverns)))


if __name__ == "__main__":
    main()
