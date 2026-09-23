# -*- coding: utf-8 -*-
"""修 M13 UI 接线缩进/顺序错误。"""
import io, os
HERE = os.path.dirname(os.path.abspath(__file__))
S = os.path.join(HERE, "scripts")

# a) SelfRulePanel: class_name 必须位于 extends 之前
pp = os.path.join(S, "ui", "self_rule_panel.gd")
s = io.open(pp, encoding="utf-8").read()
if "extends Control\nclass_name SelfRulePanel" in s:
    s = s.replace("extends Control\nclass_name SelfRulePanel",
                  "class_name SelfRulePanel\nextends Control", 1)
    io.open(pp, "w", encoding="utf-8").write(s)
    print("a) SelfRulePanel class_name 前移")
else:
    print("a) 无需改（顺序已对或未匹配）")

# b) world_map: 冻结段 ach_panel 恢复两 tab 缩进（我插入时误为单 tab）
wp = os.path.join(S, "world", "world_map.gd")
s = io.open(wp, encoding="utf-8").read()
old = "\treturn\n\tif _ach_panel.is_open():"
new = "\treturn\n\t\tif _ach_panel.is_open():"
if old in s:
    s = s.replace(old, new, 1)
    io.open(wp, "w", encoding="utf-8").write(s)
    print("b) world_map 冻结段 ach_panel 缩进修复")
else:
    print("b) 未匹配")
