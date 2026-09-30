# -*- coding: utf-8 -*-
"""方向④复核：任务/背包/成就三面板进出动画统一接线。

断言：
  A. ui_theme.gd 提供 modal_enter / modal_exit 两个公开助手，且 modal_exit 通过
     tween.finished 回调 on_done（退出动画结束后才真正隐藏 + 发信号）。
  B. 三面板各自存 _modal 句柄，在 open() 调 modal_enter、在 close_panel() 与
     _on_menu_return() 调 modal_exit。
  C. 退出时原信号（closed / menu_return_requested）仍在 on_done 里发出，且最终
     visible = false（不破坏"面板关闭"语义）。
不依赖 Godot 真跑，纯静态接线复核，纳入 _run_all_checks.py。
"""
import os
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

    theme = read("scripts/ui/ui_theme.gd")
    print("== A. UITheme 动画助手 ==")
    must('static func modal_enter(' in theme, "UITheme.modal_enter 已定义", fails)
    must('static func modal_exit(' in theme, "UITheme.modal_exit 已定义", fails)
    must('tw.finished.connect(on_done)' in theme,
         "modal_exit 经 tween.finished 回调 on_done（退出后隐藏）", fails)

    panels = {
        "quest_panel.gd": "scripts/ui/quest_panel.gd",
        "backpack_panel.gd": "scripts/ui/backpack_panel.gd",
        "achievement_panel.gd": "scripts/ui/achievement_panel.gd",
    }
    for name, path in panels.items():
        src = read(path)
        print("== B/C. %s 接线 ==" % name)
        must('_modal = m' in src or '_modal = m\n' in src or '_modal=m' in src,
             "  _ready 中存 _modal 句柄", fails)
        must('UITheme.modal_enter(_modal)' in src,
             "  open() 调 modal_enter（进入淡入）", fails)
        # close_panel 与 _on_menu_return 都走 modal_exit
        must(src.count('UITheme.modal_exit(_modal') >= 2,
             "  close_panel / _on_menu_return 各调 modal_exit（≥2 处）", fails)
        must('menu_return_requested.emit()' in src,
             "  退出后仍发 menu_return_requested 信号", fails)
        must('visible = false' in src,
             "  退出 on_done 仍设 visible = false（关闭语义保留）", fails)
        # 背包/成就额外发 closed
        if name in ("backpack_panel.gd", "achievement_panel.gd"):
            must('closed.emit()' in src,
                 "  退出后仍发 closed 信号", fails)

    if fails:
        print("\n[FAIL] %d 项未通过：%s" % (len(fails), fails))
        return 1
    print("\n[PASS] 方向④ UI 面板进出动画接线全部就位 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())
