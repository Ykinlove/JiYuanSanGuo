# -*- coding: utf-8 -*-
"""_m15_add_hidden.py — M15 彩蛋与隐藏事件：向 encounters.json 追加隐藏要素遭遇。

隐藏要素设计（参考 04-立项文档 §2.3 / D-04 §2.3 / D-02）：
  - 毒龙潭（隐藏资源点，出猛毒箭材）
  - 翡翠矿洞（隐藏资源点，解锁藤甲兵科技）
  - 巫医祭坛（隐藏资源点，伤病恢复）
  - 泰山监狱暗道（隐藏通道，宝藏）
均为 type=treasure（宝箱式），加 secret=true 隐藏标识，低权重（稀有出现），
loot 全部用 items.json 中已存在的物品（满足 _verify_m7 的引用闭合）。
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


HIDDEN = [
    {
        "id": "enc_hidden_dragon_pool", "name": "毒龙潭", "type": "treasure",
        "icon_color": "#2E7D5B", "secret": True, "weight": 3,
        "regions": ["reg_nanzhong"],
        "loot_table": ["material_beast_hide", "material_red_iron"],
        "rewards": {"exp": [120, 260], "fame": 6},
        "description": "南中瘴气深处的毒龙潭，潭边生有剧毒草木。取其毒材可淬猛毒箭（隐藏资源点）。"
    },
    {
        "id": "enc_hidden_jade_mine", "name": "翡翠矿洞", "type": "treasure",
        "icon_color": "#3FB89A", "secret": True, "weight": 3,
        "regions": ["reg_nanzhong"],
        "loot_table": ["material_fine_iron", "material_red_iron"],
        "rewards": {"exp": [150, 300], "fame": 8, "unlock": "talent_rattan"},
        "description": "南中翡翠矿洞，产珍稀矿材。集齐可解锁藤甲兵科技（隐藏资源点，04 §2.3 翡翠矿洞）。"
    },
    {
        "id": "enc_hidden_shaman_altar", "name": "巫医祭坛", "type": "treasure",
        "icon_color": "#8E6BB8", "secret": True, "weight": 2,
        "regions": ["reg_nanzhong"],
        "loot_table": ["material_herb", "treasure_lunyu"],
        "rewards": {"exp": [100, 220], "fame": 5, "unlock": "heal_2x"},
        "description": "南蛮巫医祭坛，灵药恢复伤病加倍。取灵药，伤病恢复×2（04 §2.3 巫医祭坛）。"
    },
    {
        "id": "enc_hidden_prison_pass", "name": "泰山暗道", "type": "treasure",
        "icon_color": "#C78B3E", "secret": True, "weight": 2,
        "regions": ["reg_yan"],
        "loot_table": ["treasure_dragon_eye", "treasure_lunyu"],
        "rewards": {"exp": [180, 360], "fame": 10},
        "description": "泰山监狱旁有暗道直通山外，内藏前人遗宝（04 §2.3 隐藏通道）。"
    },
]


def add_hidden():
    arr, p = load("encounters.json")
    existing = {e.get("id") for e in arr}
    added = 0
    for e in HIDDEN:
        if e["id"] in existing:
            continue
        arr.append(e)
        added += 1
    save(p, arr)
    print("encounters.json: +%d 隐藏要素 (现共 %d)" % (added, len(arr)))


if __name__ == "__main__":
    print("== M15 彩蛋与隐藏事件：隐藏遭遇数据 ==")
    add_hidden()
    print("== 完成 ==")
