# -*- coding: utf-8 -*-
"""UI 层级判定集合校验（_any_ui_open 面板表）

背景（第五十二轮）：`_any_ui_open()` 判定「是否有全屏/模态界面正在打开」，
world_map / city_scene 的 _process 每帧调它 2~3 次。优化前它每次都新建
一个 12~13 元素的 Array 字面量（每帧堆分配），并对每个面板做一次
`has_method("is_open")` 反射查询（而全工程面板均已实现该方法，恒为真）。
改为 `_ready()` 里一次性填 `_ui_panels` 成员表 + 直接调 is_open()。

**风险点**：这是**行为等价性敏感**的改造。判定集合一旦漏项，就会出现
「面板开着但人还在跑」——玩家在弹出的设置面板上点击行走，人物照走，
界面层级错乱，且**不崩溃、不报错**，编译期与运行时探针都抓不到。

所以本校验把「改造前的原始集合」固化为红线：
    1. world_map 的 _ui_panels 必须覆盖原 13 项
    2. city_scene 的 _ui_panels 必须覆盖原 12 项
    3. 两个场景的 _any_ui_open() 都不得再有 has_method 反射
    4. _any_ui_open() 都不得再在函数体内新建 Array 字面量（每帧分配）
    5. 集合里的每个字段名都必须在该脚本里真实声明过（防手滑改名/拼错）

判据全绿才算通过。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))

# 优化前 world_map.gd / city_scene.gd 里 _any_ui_open() 的原始面板集合
WORLD_MAP_ORIG = [
    "_dialogue", "_panel", "_trade", "_quest_panel", "_event_popup",
    "_menu_wheel", "_hero_dex", "_attr_panel", "_self_rule", "_ach_panel",
    "_diplomacy", "_settings", "_backpack",
]
CITY_ORIG = [
    "_quest_panel", "_menu_wheel", "_hero_dex", "_panel", "_attr_panel",
    "_ach_panel", "_diplomacy", "_self_rule", "_settings", "_dialogue",
    "_trade", "_backpack",
]

CASES = [
    ("scripts/world/world_map.gd", "大地图", WORLD_MAP_ORIG),
    ("scripts/city/city_scene.gd", "城内", CITY_ORIG),
]


def _extract_ui_panels(src: str):
    """取 _ui_panels = [ ... ] 里的成员名列表（取第一个赋值处）"""
    m = re.search(r"_ui_panels\s*=\s*\[(.*?)\]", src, re.S)
    if not m:
        return None
    return re.findall(r"_[A-Za-z0-9_]+", m.group(1))


def _extract_any_ui_open_body(src: str):
    """取 _any_ui_open() 的函数体"""
    m = re.search(r"func _any_ui_open\(\)[^\n]*:\n(.*?)(?=\n\nfunc |\n\nvar |\n\n##)",
                  src, re.S)
    return m.group(1) if m else None


def _strip_comments(src: str):
    """去掉 # 注释行/行尾注释。

    必须做：校验器会扫 has_method / 数组字面量等模式，而这些词常常出现在
    我自己写的解释性注释里（如「旧写法每帧新建数组 + has_method 反射」）。
    首版没过滤注释，把注释判成了代码违规 —— 这是**假阳性**，
    比漏报更危险：假阳性会让人去改本来正确的代码。
    """
    out = []
    for line in src.splitlines():
        s = line.strip()
        if s.startswith("#"):
            continue
        # 去掉行尾注释（注意不误伤字符串里的 #，本工程数据表用 #RRGGBB 但不在 .gd 里）
        idx = line.find("#")
        if idx >= 0:
            line = line[:idx]
        out.append(line)
    return "\n".join(out)


def main() -> int:
    fails = []
    checks = 0

    for rel, label, orig in CASES:
        path = os.path.join(ROOT, rel)
        if not os.path.exists(path):
            fails.append("[%s] 文件不存在：%s" % (label, rel))
            continue
        with open(path, encoding="utf-8") as f:
            raw = f.read()
        # 注释只在「扫描违规模式」时剥掉；查成员声明/赋值仍用原文
        src = _strip_comments(raw)

        # --- 1. 存在 _ui_panels 成员表且填了原始集合 ---
        got = _extract_ui_panels(raw)
        checks += 1
        if got is None:
            fails.append("[%s] 找不到 _ui_panels = [...] 赋值（应改为成员表）" % label)
        else:
            missing = [p for p in orig if p not in got]
            checks += 1
            if missing:
                fails.append("[%s] _ui_panels 漏了面板：%s（漏项会导致「面板开着人还在跑」）"
                             % (label, missing))
            extra = [p for p in got if p not in orig]
            checks += 1
            if extra:
                # 多加不是「漏判」而是「多判」，会改变玩法语义（本来能走的地方不能走），
                # 属未经确认的行为变更，同样必须报出来
                fails.append("[%s] _ui_panels 多出面板：%s（会改变玩法语义，需单独确认）"
                             % (label, extra))

            # --- 2. 集合成员必须是本脚本真实声明过的字段（防改名/拼错静默失效）---
            for name in got:
                checks += 1
                if not re.search(r"(?:var|@onready var)\s+%s\b" % re.escape(name), raw):
                    fails.append("[%s] _ui_panels 里的 %s 在本脚本没有声明，"
                                 "运行时会取到 null 导致漏判" % (label, name))

        # --- 3. _any_ui_open 体内不得再有 has_method 反射 ---
        body = _extract_any_ui_open_body(src)
        checks += 1
        if body is None:
            fails.append("[%s] 找不到 _any_ui_open() 函数体" % label)
        else:
            if "has_method" in body:
                fails.append("[%s] _any_ui_open() 仍用 has_method 反射"
                             "（每帧×每面板一次，纯浪费）" % label)
            # --- 4. 函数体内不得新建数组字面量（每帧堆分配）---
            checks += 1
            if re.search(r"var\s+\w+\s*:\s*Array\s*=\s*\[", body):
                fails.append("[%s] _any_ui_open() 体内仍在新建数组字面量，"
                             "每帧白白堆分配" % label)

    print("=" * 62)
    print("UI 层级判定集合校验（_any_ui_open 面板表）")
    print("=" * 62)
    print("  判定项：%d" % checks)
    if fails:
        for ln in fails:
            print("  [FAIL] " + ln)
        print("")
        print("UI 层级判定校验失败：%d 项不符合" % len(fails))
        return 1

    print("  [OK] 大地图 13 项 / 城内 12 项判定集合与改造前逐项一致")
    print("  [OK] 无 has_method 反射、函数体内无每帧数组分配")
    print("  [OK] 集合成员均在各自脚本中真实声明")
    print("")
    print("UI 层级判定校验通过 ✅（%d 项判定全绿，漏项/多项均会被拦下）" % checks)
    return 0


if __name__ == "__main__":
    sys.exit(main())
