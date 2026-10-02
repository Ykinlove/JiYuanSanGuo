# -*- coding: utf-8 -*-
"""四十二轮 四季地形变色 静态复核（TerrainPainter 季节氛围罩 + 冬季北方积雪渐变）"""
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))

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


tp = read(TP)
gs = read(GS)

# ---- A. 季节追踪（事实层） ----
check("A1 GameState.get_season() 存在", "func get_season() -> int:" in gs)
check("A2 GameState.SEASON_WINTER = 3（冬=3）", "const SEASON_WINTER: int = 3" in gs)
check("A3 四季常量齐全（0春1夏2秋3冬）",
      all(k in gs for k in ["SEASON_SPRING: int = 0", "SEASON_SUMMER: int = 1",
                            "SEASON_AUTUMN: int = 2", "SEASON_WINTER: int = 3"]))

# ---- B. 季节氛围罩（TerrainPainter.SEASON_MOOD） ----
check("B1 SEASON_MOOD 常量定义", "const SEASON_MOOD := {" in tp)
check("B2 四季节气罩齐全（0/1/2/3）",
      all(k in tp for k in ["0: Color", "1: Color", "2: Color", "3: Color"]))
check("B3 _draw 末尾按季节叠氛围罩（draw_rect + mood）",
      "var mood := (SEASON_MOOD.get" in tp and "draw_rect(Rect2(Vector2.ZERO, size), mood, true)" in tp)

# ---- C. 季节切换重绘（轻量 _process） ----
check("C1 TerrainPainter 新增 _process", "func _process" in tp)
check("C2 _process 读 GameState.get_season() 并在变化时 queue_redraw()",
      "GameState.get_season()" in tp and "queue_redraw()" in tp
      and "s != _last_season" in tp)
check("C3 _last_season 缓存变量", "var _last_season := -1" in tp)

# ---- D. 冬季北方积雪渐变 ----
check("D1 _get_snow_gradient 生成 GradientTexture2D",
      "func _get_snow_gradient" in tp and "GradientTexture2D.new()" in tp
      and "Gradient.new()" in tp)
check("D2 冬季分支（season == 3）叠积雪渐变（draw_texture_rect + _get_snow_gradient）",
      "season == 3" in tp and "draw_texture_rect(sg, Rect2(Vector2.ZERO, size), false" in tp
      and "_get_snow_gradient()" in tp)
check("D3 积雪渐变变量缓存", "var _snow_grad: Texture2D = null" in tp)

# ---- E. 一致性：冬=3 在两层对齐 ----
check("E1 冬映射一致（TerrainPainter season==3 对应 GameState SEASON_WINTER=3）",
      "season == 3" in tp and "const SEASON_WINTER: int = 3" in gs)

# ---- 汇总 ----
print("PASS %d / FAIL %d" % (len(passes), len(fails)))
for p in passes:
    print("  [PASS] %s" % p)
for f in fails:
    print("  [FAIL] %s" % f)

if fails:
    print("[FAIL] 四季地形变色静态复核未通过：%s" % fails)
    sys.exit(1)
print("[OK] 四季地形变色静态复核全部通过 ✅")
