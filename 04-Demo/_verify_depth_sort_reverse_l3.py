#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""反向验证专用：只跑 _verify_depth_sort.py 的 L3 源码锚定层（秒级）。

【为什么拆出来】完整校验含两轮引擎真跑（每轮 1~3 分钟），
13 个反向用例全跑一遍会超过 30 分钟被 SIGTERM 杀掉。
本脚本复用主校验器**同一套 helper 与同一套判据**（从主文件动态载入，
不复制粘贴 —— 复制粘贴就会出现「两份判据不一致」的老问题），
只跑 L3 那一段。判据与主校验器**同源**，因此反验证结果对主校验器有效。
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "_verify_depth_sort.py")

# 从主校验器**动态切段**执行，而非复制粘贴判据 ——
# 复制粘贴就会出现「两份判据不一致」的老问题，反验证结果对不上主校验器。
# 【边界】235 行之前 = helper + 路径常量 + FAILS/CNT（无副作用）
#        281~363 行 = L3 源码锚定判据（唯一要跑的那段）
src = open(MAIN, "r", encoding="utf-8", errors="replace").read()
head_end = src.index('print("=" * 70)')
l3_start = src.index('# ================= L3 独立源码锚定')
l3_end = src.index('# ================= 汇总')
body = src[:head_end] + "\n" + src[l3_start:l3_end]
ns = {"__name__": "dsmain_l3", "__file__": MAIN}
exec(compile(body, MAIN, "exec"), ns)

fails = ns["FAILS"]
cnt = ns["CNT"]

for f in fails:
    print("  [FAIL] " + f)
print("L3 判定 %d 项 / 失败 %d" % (cnt[0], len(fails)))
if fails:
    print("DEPTH_SORT_L3=FAIL")
    sys.exit(1)
print("DEPTH_SORT_L3=PASS（%d 项全绿）" % cnt[0])
sys.exit(0)
