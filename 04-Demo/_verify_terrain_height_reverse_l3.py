#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""反向验证专用：只跑 _verify_terrain_height.py 的 L3 源码锚定层（秒级）。

【为什么拆出来】完整校验含引擎真跑（分钟级），十几个反向用例全跑会超时。
本脚本从主校验器**动态切段**执行（不复制粘贴判据 —— 复制粘贴就会出现
「两份判据不一致」的老问题，反验证结果对不上主校验器），只跑 L3 那一段。
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "_verify_terrain_height.py")

src = open(MAIN, "r", encoding="utf-8", errors="replace").read()
head_end = src.index('print("=" * 70)')
l3_start = src.index('# ============================== L3 独立源码锚定')
l3_end = src.index('# ============================== 汇总')
body = src[:head_end] + "\n" + src[l3_start:l3_end]
ns = {"__name__": "thmain_l3", "__file__": MAIN}
exec(compile(body, MAIN, "exec"), ns)

fails = ns["FAILS"]
cnt = ns["CNT"]

for f in fails:
    print("  [FAIL] " + f)
print("L3 判定 %d 项 / 失败 %d" % (cnt[0], len(fails)))
if fails:
    print("TERRAIN_HEIGHT_L3=FAIL")
    sys.exit(1)
print("TERRAIN_HEIGHT_L3=PASS（%d 项全绿）" % cnt[0])
sys.exit(0)