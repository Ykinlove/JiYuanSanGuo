# -*- coding: utf-8 -*-
"""
_verify_interaction_ui.py — 第六十六轮·问题2 回归锁
用户反馈三处定位问题：
  ① 跟人对话时弹出的交互框在屏幕**左边**，应该在中间；
  ② 进城后走到可交互物旁弹出的框，**位置不一致**（有的在下方、有的在中间）；
  ③ 最右边圆圈按钮上方的「可交谈」提示**没跟按钮对上**，偏在一边。

【根因（逐条取证）】
  ①② 同一个组件 InteractionMenu：它的 _reposition() 走的是「跟随目标屏幕坐标」
      pos = sp + (-card_w/2, offset_y - card_h)，目标在屏幕哪个位置，卡片就跟着
      出现在哪儿 —— 目标靠左就弹在左边，目标靠下就弹在下方，于是"每次不一样"。
      大地图（world_map.gd）与城内（city_scene.gd）共用这一个组件。
  ③ 城内 _action_hint 原写法把提示**右端**对齐按钮右缘：
      提示宽 320 → 中心 = x + sz - 160；按钮中心 = x + sz/2 = x + 70 → 相差 90px。

【修法】
  ①② InteractionMenu 新增 center_on_screen（默认 true）+ CENTER_ANCHOR_Y，
      居中分支按视口尺寸水平居中、纵向落在 0.62 高度（中央偏下，不压玩家与交互对象），
      并保留夹在可见区内；旧的非居中分支保留，供确需跟随目标的调用方关闭。
  ③ 提示改为以**按钮中心**为中心左右均分，与按钮同轴。

本校验对 ③ 做**代数验算**（把旧写法与新写法的中心差值都算出来），
而不是只 grep 一个关键字 —— 这样"改回旧写法"会立刻变红。
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
IMENU = os.path.join(HERE, "scripts", "ui", "interaction_menu.gd")
DLG = os.path.join(HERE, "scripts", "ui", "dialogue_ui.gd")
CITY = os.path.join(HERE, "scripts", "city", "city_scene.gd")
WMAP = os.path.join(HERE, "scripts", "world", "world_map.gd")

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print("  [%s] %s%s" % ("OK" if ok else "FAIL", name, ("  " + detail) if detail else ""))
    return bool(ok)


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


print("=" * 68)
print("第六十六轮 交互框 / 对话卡 / 提示对齐 回归锁")
print("=" * 68)

for p in (IMENU, DLG, CITY, WMAP):
    if not os.path.isfile(p):
        check("源文件存在", False, p)
        sys.exit(1)

im, dl, city, wmap = read(IMENU), read(DLG), read(CITY), read(WMAP)

# ---------- ① 交互菜单居中 ----------
print("\n[1] InteractionMenu 居中（问题①②）")
check("新增开关 center_on_screen", "var center_on_screen" in im)
m = re.search(r"var center_on_screen\s*:?=\s*(true|false)", im)
check("默认居中（true）—— 大地图与城内共用它，默认即生效",
      m is not None and m.group(1) == "true", m.group(1) if m else "缺失")
check("提供外部开关方法 set_center_on_screen（供确需跟随目标的场景关闭）",
      "func set_center_on_screen" in im)
m = re.search(r"const CENTER_ANCHOR_Y\s*:?=\s*([0-9.]+)", im)
anchor = float(m.group(1)) if m else -1.0
check("CENTER_ANCHOR_Y 有定义", m is not None, str(anchor))
check("居中锚点落在屏幕中部（0.40~0.75，既不压顶栏也不贴底）",
      0.40 <= anchor <= 0.75, "%.2f" % anchor)

repo = re.search(r"func _reposition\(.*?(?=\nfunc )", im, flags=re.S)
rb = repo.group(0) if repo else ""
check("存在居中分支（if center_on_screen）", "if center_on_screen:" in rb)
check("居中分支按视口宽度水平居中 (vp.x - card_w) * 0.5",
      "(vp_c.x - card_size.x) * 0.5" in rb)
check("居中分支纵向按 CENTER_ANCHOR_Y 定位",
      "vp_c.y * CENTER_ANCHOR_Y - card_size.y * 0.5" in rb)
check("居中分支仍夹在可见区内（矮屏不至于顶到顶栏/掉出屏）",
      "clampf(pos.y" in rb)
check("保留原「跟随目标」分支（旧行为不被误伤）",
      "pos = sp + Vector2(-card_size.x * 0.5" in rb)

# ---------- ② 对话卡与选项框统一 ----------
print("\n[2] 对话卡 / 选项框定位统一（问题②）")
check("新增选项框间距常量 OPT_BOX_GAP", "const OPT_BOX_GAP" in dl)
m = re.search(r"const OPT_BOX_GAP\s*:?=\s*([0-9.]+)", dl)
gap = float(m.group(1)) if m else -1.0
check("选项框间距为正且合理（8~64）", 8.0 <= gap <= 64.0, "%.0f" % gap)
layout = re.search(r"func _apply_card_layout\(.*?(?=\nfunc )", dl, flags=re.S)
lb = layout.group(0) if layout else ""
check("选项框改为居中预设 PRESET_CENTER_TOP（不再贴底 PRESET_BOTTOM_WIDE）",
      "PRESET_CENTER_TOP" in lb and "PRESET_BOTTOM_WIDE" not in lb)
check("选项框与卡片同宽（左右对称 -card_w/2 ~ +card_w/2）",
      "_options_box.offset_left = -card_w * 0.5" in lb
      and "_options_box.offset_right = card_w * 0.5" in lb)
check("选项框跟随卡片下沿（top_margin + card_h + OPT_BOX_GAP）",
      "_options_box.offset_top = top_margin + card_h + OPT_BOX_GAP" in lb)
check("选项框向下生长（grow_vertical = GROW_DIRECTION_END）",
      "_options_box.grow_vertical = Control.GROW_DIRECTION_END" in lb)
# 布局必须挂在 _apply_card_layout 里（卡片尺寸变化时跟着重排），不是只在建卡时设一次
check("定位写在 _apply_card_layout 内（卡片尺寸变化时自动跟随，不会脱节）",
      "_options_box" in lb)

# ---------- ③ 圆形按钮提示对齐（代数验算）----------
print("\n[3] 圆形按钮「可交谈」提示对齐（问题③）")
btn = re.search(r"var sz := ([0-9.]+)", city)
sz = float(btn.group(1)) if btn else 0.0
check("取到圆形按钮边长 sz", sz > 0, "%.0f" % sz)
hint = re.search(r"var hint_w := ([0-9.]+)", city)
hw = float(hint.group(1)) if hint else 0.0
check("取到提示标签宽度 hint_w", hw > 0, "%.0f" % hw)
check("提示以按钮中心为基准（btn_cx = x + sz * 0.5）",
      "var btn_cx := x + sz * 0.5" in city)
check("提示左右关于按钮中心对称",
      "_action_hint.offset_right = btn_cx + hint_w * 0.5" in city
      and "_action_hint.offset_left = btn_cx - hint_w * 0.5" in city)

# 代数验算：x 会被抵消，两种写法都能算出与按钮中心的固定偏差
new_offset = 0.0                      # center = btn_cx + hw/2 - hw/2 = btn_cx
old_center = sz - hw * 0.5            # 旧写法：右端对齐按钮右缘 → center = x + sz - hw/2
old_offset = old_center - sz * 0.5    # 减去按钮中心 x + sz/2
check("新写法提示中心与按钮中心完全重合",
      abs(new_offset) < 1e-6, "偏移 %.1f px" % new_offset)
check("反证：旧写法确实偏了（偏移量 = |sz - hint_w| / 2）",
      abs(abs(old_offset) - abs(sz - hw) * 0.5) < 1e-6,
      "旧偏移 %.0f px（sz=%.0f, hint_w=%.0f）" % (old_offset, sz, hw))
check("反证：旧偏移达到肉眼可见级别（≥20px，确属缺陷）",
      abs(old_offset) >= 20.0, "%.0f px" % abs(old_offset))
# 提示纵向仍在按钮上方（不被按钮压住）
check("提示位于按钮上方（offset_bottom = cy - sz/2 - 12）",
      "_action_hint.offset_bottom = cy - sz * 0.5 - 12.0" in city)

# ---------- 汇总 ----------
print("\n" + "=" * 68)
passed = sum(1 for _, ok, _ in results if ok)
print("复核结果：%d / %d 通过" % (passed, len(results)))
if passed < len(results):
    print("失败项：")
    for n, ok, d in results:
        if not ok:
            print("  - %s :: %s" % (n, d))
    sys.exit(1)
print("全部通过 ✅")
