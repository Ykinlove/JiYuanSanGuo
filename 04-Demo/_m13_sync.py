# -*- coding: utf-8 -*-
"""把 self_rule_city 同步进 GameState.to_dict / from_dict / reset（文本替换）。"""
import io, os
HERE = os.path.dirname(os.path.abspath(__file__))
p = os.path.join(HERE, "scripts", "autoload", "game_state.gd")
with io.open(p, encoding="utf-8") as f:
    s = f.read()

# 1) to_dict
s = s.replace(
    '\t\t"self_rule_flag": self_rule_flag,',
    '\t\t"self_rule_flag": self_rule_flag,\n\t\t"self_rule_city": self_rule_city,')
# 2) from_dict
s = s.replace(
    '\tself_rule_flag = int(data.get("self_rule_flag", 0))',
    '\tself_rule_flag = int(data.get("self_rule_flag", 0))\n'
    '\tself_rule_city = str(data.get("self_rule_city", ""))')
# 3) reset
s = s.replace('\tself_rule_flag = 0', '\tself_rule_flag = 0\n\tself_rule_city = ""')

with io.open(p, "w", encoding="utf-8") as f:
    f.write(s)
print("self_rule_city 已同步 to_dict/from_dict/reset")
