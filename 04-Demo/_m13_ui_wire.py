# -*- coding: utf-8 -*-
"""M13 自立祠堂触发 UI 接线：修 self_rule_panel.gd 换行、加主菜单「自立」项、接入 world_map。"""
import io, os, re

HERE = os.path.dirname(os.path.abspath(__file__))

def read(p):
    with io.open(p, encoding="utf-8") as f:
        return f.read()

def write(p, s):
    with io.open(p, "w", encoding="utf-8") as f:
        f.write(s)

S = os.path.join(HERE, "scripts")

# 1) 修 self_rule_panel.gd：join 分隔改为真换行
pp = os.path.join(S, "ui", "self_rule_panel.gd")
s = read(pp)
new_line = '\t_status.text = "\\n".join(lines)'
s2 = re.sub(r'_status\.text = .*\n', new_line + "\n", s, count=1)
if s2 != s and 'join(lines)' in s2:
    write(pp, s2)
    print("1) self_rule_panel.gd 换行已修")
else:
    print("1) WARN self_rule_panel.gd 未匹配（可能已是 \\n）")

# 2) main_menu_wheel.gd：加「自立」项
mp = os.path.join(S, "ui", "main_menu_wheel.gd")
s = read(mp)
anchor = '	{ "action": "diplo",   "label": "外交",     "glyph": "交", "col": Color(0.95, 0.72, 0.55) },'
add = anchor + '\n	{ "action": "self_rule", "label": "自立", "glyph": "王", "col": Color(0.86, 0.62, 0.40) },'
if anchor in s and "self_rule" not in s:
    write(mp, s.replace(anchor, add, 1))
    print("2) main_menu_wheel.gd 已加「自立」")
else:
    print("2) main_menu_wheel.gd（已有或未匹配）")

# 3) world_map.gd 接入
wp = os.path.join(S, "world", "world_map.gd")
s = read(wp)
changed = []

# 3a) 声明
decl_old = 'var _ach_panel: AchievementPanel'
decl_new = 'var _ach_panel: AchievementPanel\nvar _self_rule: SelfRulePanel'
if decl_old in s and "var _self_rule" not in s:
    s = s.replace(decl_old, decl_new, 1); changed.append("声明")
if "SelfRulePanel" in s and "(SelfRulePanel" not in s:
    print("   WARN 声明需确认")  # 占位

# 3b) _ready 实例化
act_old = "_ach_panel = AchievementPanel.new()"
act_new = "_ach_panel = AchievementPanel.new()\n\t_self_rule = SelfRulePanel.new()\n\t_self_rule.name = \"SelfRulePanel\"\n\t$UI.add_child(_self_rule)"
if act_old in s and "_self_rule = SelfRulePanel.new()" not in s:
    s = s.replace(act_old, act_new, 1); changed.append("实例化")

# 3c) _on_wheel_selected 加 self_rule case（插在 "achieve" 前，主菜单即可进自立）
wh_old = '\t\t"achieve":'
wh_new = '\t\t"self_rule":\n\t\t\t_self_rule.open(GameState.current_city_id)\n\t\t"achieve":'
if wh_old in s and '"self_rule":' not in s:
    s = s.replace(wh_old, wh_new, 1); changed.append("wheel-case")

# 3d) _process 冻结加 self_rule
fr_old = "if _ach_panel.is_open():"
fr_new = "if _self_rule.is_open():\n\t\t_player.halt()\n\t\treturn\n\tif _ach_panel.is_open():"
if fr_old in s and "_self_rule.is_open()" not in s:
    s = s.replace(fr_old, fr_new, 1); changed.append("冻结")

write(wp, s)
print("3) world_map.gd 接入: %s" % (changed if changed else "均未匹配(需人工核对)"))
