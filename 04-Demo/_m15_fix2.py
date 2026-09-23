# -*- coding: utf-8 -*-
import io, os
HERE = os.path.dirname(os.path.abspath(__file__))
p = os.path.join(HERE, "_verify_m15.py")
s = io.open(p, encoding="utf-8").read()
# 补 C 行 print 字符串缺的闭合引号：==) -> ==")
if "（hi_* 隐藏任务）==)" in s:
    s = s.replace("（hi_* 隐藏任务）==)", "（hi_* 隐藏任务）==\")")
    io.open(p, "w", encoding="utf-8").write(s)
    print("C 行引号已补")
else:
    print("未匹配：\n" + [x for x in s.split(chr(10)) if "hi_*" in x][0] if "hi_*" in s else "??")
