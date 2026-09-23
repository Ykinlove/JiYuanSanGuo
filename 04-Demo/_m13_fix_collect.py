# -*- coding: utf-8 -*-
"""把 M13 新增任务的 collect 目标修正为 items.json 已存在物品（满足 _verify_m7 引用闭合）。"""
import io, json, os
HERE = os.path.dirname(os.path.abspath(__file__))
p = os.path.join(HERE, "assets", "data", "quests.json")
with io.open(p, encoding="utf-8") as f:
    arr = json.load(f)
fix = {
    "br_fenglong": "treasure_dragon_eye",
    "br_guandu": "material_fine_iron",
    "br_hanzhong": "material_herb",
    "hi_huful": "material_herb",
    "hi_huatuo": "material_herb",
}
cnt = 0
for q in arr:
    if q.get("id") in fix:
        for o in q.get("objectives", []):
            if o.get("type") == "collect":
                o["target"] = fix[q["id"]]
                cnt += 1
with io.open(p, "w", encoding="utf-8") as f:
    json.dump(arr, f, ensure_ascii=False, indent=2)
with io.open(p, "a", encoding="utf-8") as f:
    f.write("\n")
print("修正 collect 目标 %d 处" % cnt)
