# -*- coding: utf-8 -*-
"""四十三轮 季节定义一致性 静态复核（DayNightTint 与 TerrainPainter 同走 GameState.get_season() 单一来源）

锁定的不变量：
  - 季节事实层的唯一权威是 GameState.get_season()（1-3春/4-6夏/7-9秋/10-12冬），
    配套常量 SEASON_SPRING=0 / SUMMER=1 / AUTUMN=2 / WINTER=3。
  - 世界演出层（DayNightTint 大气染色、TerrainPainter 地形氛围罩）都必须从这唯一来源取季节，
    不得各自按 GameState.month 重新划分季节区间——否则会出现
    「一月二月地形归春（嫩绿）而大气归冬（霜蓝）」这类视觉打架（四十三轮修复前即此缺陷）。
"""
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))

DNT = os.path.join(ROOT, "scripts", "world", "day_night_tint.gd")
TP = os.path.join(ROOT, "scripts", "world", "terrain_painter.gd")
GS = os.path.join(ROOT, "scripts", "autoload", "game_state.gd")

passes, fails = [], []


def check(name, cond):
    (passes if cond else fails).append(name)


def read(path):
    if not os.path.exists(path):
        return ""
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


dnt = read(DNT)
tp = read(TP)
gs = read(GS)

# ---- A. 季节事实层（单一来源） ----
check("A1 GameState.get_season() 存在", "func get_season() -> int:" in gs)
check("A2 四季常量齐全（0春1夏2秋3冬）",
      all(k in gs for k in ["SEASON_SPRING: int = 0", "SEASON_SUMMER: int = 1",
                            "SEASON_AUTUMN: int = 2", "SEASON_WINTER: int = 3"]))

# ---- B. DayNightTint 走 get_season 单一来源 ----
check("B1 _season_color() 存在", "func _season_color() -> Color:" in dnt)
check("B2 _season_color 从 GameState.get_season() 取季节",
      "func _season_color() -> Color:" in dnt and "GameState.get_season()" in dnt)
check("B3 _season_color 用 SEASON_* 常量分支（春/夏/秋/冬）",
      all(k in dnt for k in ["GameState.SEASON_SPRING", "GameState.SEASON_SUMMER",
                             "GameState.SEASON_AUTUMN", "GameState.SEASON_WINTER"]))
# 核心锁：旧实现按 GameState.month 自定 3-5/6-8/9-11 区间 → 与 get_season 在 1/2/12 月冲突。
# 现在季节判定不得再依赖 month。
check("B4 _season_color 不再用 GameState.month 推导季节（旧 bug 不回归）",
      "_season_color" in dnt and "GameState.month" not in dnt)
check("B5 头部注释不再宣称『按 GameState.month』（口径同步）",
      "按 GameState.month" not in dnt)

# ---- C. TerrainPainter 同走 get_season 单一来源 ----
check("C1 TerrainPainter 调 GameState.get_season()", "GameState.get_season()" in tp)
check("C2 TerrainPainter 季节切换检测（_process 内 s != _last_season）",
      "s != _last_season" in tp and "queue_redraw()" in tp)

# ---- D. 双源一致性：两套演出层都依赖同一权威 ----
check("D1 DayNightTint 与 TerrainPainter 都引用 GameState.get_season()",
      "GameState.get_season()" in dnt and "GameState.get_season()" in tp)
check("D2 两者都依赖 SEASON_WINTER=3（冬映射对齐）",
      all(k in gs for k in ["SEASON_WINTER: int = 3"])
      and "GameState.SEASON_WINTER" in dnt and "season == 3" in tp)

# ---- 汇总 ----
print("PASS %d / FAIL %d" % (len(passes), len(fails)))
for p in passes:
    print("  [PASS] %s" % p)
for f in fails:
    print("  [FAIL] %s" % f)

if fails:
    print("[FAIL] 季节定义一致性静态复核未通过：%s" % fails)
    sys.exit(1)
print("[OK] 季节定义一致性静态复核全部通过 ✅")
