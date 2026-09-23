# -*- coding: utf-8 -*-
"""修 _verify_m15.py 三处 print 缺闭合引号。"""
import io, os
HERE = os.path.dirname(os.path.abspath(__file__))
p = os.path.join(HERE, "_verify_m15.py")
s = io.open(p, encoding="utf-8").read()
fixes = {
    'print("== B. 隐藏要素 loot 物品引用闭合 ==)': 'print("== B. 隐藏要素 loot 物品引用闭合 ==")',
    'print("== C. 隐藏事件链（quests.json hi_* 隐藏任务）==)': 'print("== C. 隐藏事件链（hi_* 隐藏任务）==)',
    'print("== D. 不破坏既有遭遇 ==)': 'print("== D. 不破坏既有遭遇 ==")',
}
n = 0
for old, new in fixes.items():
    if old in s:
        s = s.replace(old, new, 1); n += 1
io.open(p, "w", encoding="utf-8").write(s)
print("修正 %d 处" % n)
