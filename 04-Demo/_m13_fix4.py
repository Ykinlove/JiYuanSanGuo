# -*- coding: utf-8 -*-
"""修 world_map.gd 中 ach_panel 冻结块 body 缩进（两 tab → 三 tab）。"""
import io, os
HERE = os.path.dirname(os.path.abspath(__file__))
p = os.path.join(HERE, "scripts", "world", "world_map.gd")
s = io.open(p, encoding="utf-8").read()
old = "\t\tif _ach_panel.is_open():\n\t\t_player.halt()\n\t\treturn\n"
new = "\t\tif _ach_panel.is_open():\n\t\t\t_player.halt()\n\t\t\treturn\n"
if old in s:
    s = s.replace(old, new, 1)
    io.open(p, "w", encoding="utf-8").write(s)
    print("ach 冻结块 body 缩进已修")
else:
    print("未匹配，需核对")
