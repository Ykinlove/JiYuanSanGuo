# -*- coding: utf-8 -*-
import io, os
HERE = os.path.dirname(os.path.abspath(__file__))
p = os.path.join(HERE, "_run_all_checks.py")
with io.open(p, encoding="utf-8") as f:
    s = f.read()
anchor = '("_verify_m14.py", "M13 自立称王（SelfRuleService/信物/立业）"),'
if "_verify_m15.py" not in s:
    s = s.replace(anchor, anchor + '\n    ("_verify_m15.py", "M15 彩蛋与隐藏事件（隐藏资源点/通道/上香虎符链）"),')
    with io.open(p, "w", encoding="utf-8") as f:
        f.write(s)
    print("已注册 _verify_m15")
else:
    print("已存在，跳过")
