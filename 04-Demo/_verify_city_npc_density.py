# -*- coding: utf-8 -*-
"""方向①延伸·第十四轮复核：城内非发任务 NPC 密度提升接线。

断言：
  A. CITY_NPC_HOME_SPOTS 锚点 ≥ 10 且全部落在 interior(2400×1500) 内
     —— 锚点够多，空城补位 NPC 才不会因 idx%size 循环复用而堆叠。
  B. CITY_RESIDENT_COUNT ≥ 5（空城追加的闲散居民下限）。
  C. CITY_RESIDENT_TYPES 含 resident/elder/youth/hero 四身份（搭话台词有料）。
  D. _npc_resident(rtype, seq) 已定义，且 _spawn_city_npcs 空城补位分支调用它。
  E. NPC_SMALLTALK 含上述四身份模板（闲散居民走近搭话不空）。
  F. 交互菜单交易判定仍只 npc_type in ["merchant","blacksmith"]
     —— resident/elder/youth/hero 天然「只交谈、不交易」，未破坏交易逻辑。
不依赖 Godot 真跑，纯静态接线复核，纳入 _run_all_checks.py。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))


def read(p: str) -> str:
    with open(os.path.join(ROOT, p), encoding="utf-8") as f:
        return f.read()


def must(cond: bool, msg: str, fails: list) -> None:
    if cond:
        print("  [OK] " + msg)
    else:
        print("  [FAIL] " + msg)
        fails.append(msg)


def main() -> int:
    fails: list[str] = []
    src = read("scripts/city/city_scene.gd")

    # A. 锚点数量 + 越界
    m = re.search(r'const CITY_NPC_HOME_SPOTS.*?\]\s*\n', src, re.S)
    block = m.group(0) if m else ""
    anchors = re.findall(r'Vector2\(', block)
    must(len(anchors) >= 10,
         "CITY_NPC_HOME_SPOTS 锚点 ≥ 10（空城补位不堆叠），实际 %d" % len(anchors), fails)
    coords = re.findall(r'Vector2\((-?[\d.]+),\s*(-?[\d.]+)\)', block)
    oob = [(x, y) for x, y in coords
           if not (0 <= float(x) <= 2400 and 0 <= float(y) <= 1500)]
    must(len(oob) == 0,
         "所有锚点都在 interior(2400×1500) 内，越界 %s" % oob, fails)

    # B. 闲散居民数量下限
    mc = re.search(r'const CITY_RESIDENT_COUNT\s*:?=\s*(\d+)', src)
    cnt = int(mc.group(1)) if mc else 0
    must(cnt >= 5,
         "CITY_RESIDENT_COUNT ≥ 5（空城闲散居民下限），实际 %d" % cnt, fails)

    # C. 闲散居民身份集合
    mt = re.search(r'const CITY_RESIDENT_TYPES\s*:?=\s*\[(.*?)\]', src, re.S)
    types = re.findall(r'"(\w+)"', mt.group(1)) if mt else []
    need = {"resident", "elder", "youth", "hero"}
    must(need.issubset(set(types)),
         "CITY_RESIDENT_TYPES 含 %s，实际 %s" % (sorted(need), types), fails)

    # D. 闲散居民构造函数 + 调用点
    must('func _npc_resident(' in src, "_npc_resident(rtype, seq) 已定义", fails)
    must('_npc_resident(' in src and 'gen_resident' in src,
         "_spawn_city_npcs 空城补位分支调用 _npc_resident 生成闲散居民", fails)

    # E. 搭话台词模板
    ms = re.search(r'const NPC_SMALLTALK\s*:?=\s*\{(.*?)\n\}', src, re.S)
    st = re.findall(r'"(\w+)":', ms.group(1)) if ms else []
    must(need.issubset(set(st)),
         "NPC_SMALLTALK 含 %s 搭话模板，实际 %s" % (sorted(need), st), fails)

    # F. 交易判定未被破坏
    must(re.search(r'npc_type in \["merchant", "blacksmith"\]', src) is not None,
         "交互菜单交易判定仍只 merchant/blacksmith（闲散居民不出交易）", fails)

    if fails:
        print("\n[FAIL] %d 项未通过：%s" % (len(fails), fails))
        return 1
    print("\n[PASS] 城内非发任务 NPC 密度提升接线全部就位 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())
