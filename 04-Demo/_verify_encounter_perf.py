#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
第五十四轮校验：遭遇管理器（encounter_manager.gd）每帧性能改造的行为不变量。

背景
----
原 `_process()` 每帧两次 `get_children()` 全量遍历（大地图最多 140 个遭遇点
→ 280 次），且每帧对每个点重复 `has_meta`/`get_meta` 字典查找、`distance_to`
每次开方，最后对 140 个节点无条件写 `Hint.visible`。

本轮改为：生成期登记 `_enc_nodes` / `_manual_nodes` 缓存、`distance_squared_to`
省开方、`_set_hint` 仅变化才写。

**但性能改造极易悄悄改掉行为。** 本校验把三条最容易回归的不变量钉死：

  I1【顺序铁律】`_process` 内 `_triggered_ids.has(...)` 的判定必须出现在
     `_is_manual(...)` 之前。否则已结算的战斗点会落进「走近自动触发」分支，
     被每帧重复触发 → 站着不动反复开战斗场景。这是本轮改造中真实踩到并修掉的坑。
  I2【缓存同步】`_spawn_one` 登记进 `_enc_nodes`，且仅 `_is_manual` 为真时
     登记进 `_manual_nodes`；`reload_region` 必须同时清空两个缓存。
  I3【dist 契约】`nearest_interactable()` 内部用平方距离比较，但返回的 `dist`
     必须 `sqrt(...)` 还原为真实距离。直接返回平方值不会报错，
     只会让 world_map.gd 拿到的距离量级完全错误。

外加两条性能红线：
  P1 `_process` / `nearest_interactable` 内不得再出现 `get_children()`。
  P2 `_process` 内不得出现 `Array[Node2D] = []` 这类每帧新建数组的字面量
     （这是第五十二轮在 `_any_ui_open()` 上刚清掉的反形态，不得回退）。
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, "scripts", "world", "encounter_manager.gd")

FAILS: list[str] = []
CHECKS = 0


def check(cond: bool, msg: str) -> None:
    global CHECKS
    CHECKS += 1
    if not cond:
        FAILS.append(msg)


def strip_comments(src: str) -> str:
    """剥掉整行与行尾注释，避免校验命中解释性注释造成假阳性。"""
    out = []
    for line in src.split("\n"):
        s = line.lstrip()
        if s.startswith("#"):
            out.append("")
            continue
        i = line.find("#")
        out.append(line[:i] if i >= 0 else line)
    return "\n".join(out)


def func_body(src: str, name: str) -> str:
    """截取指定函数（顶格 func）的完整函数体（按缩进收敛）。"""
    lines = src.split("\n")
    start = None
    for idx, ln in enumerate(lines):
        if re.match(rf"^func {re.escape(name)}\s*\(", ln):
            start = idx
            break
    if start is None:
        return ""
    body = []
    for ln in lines[start:]:
        if body and ln.strip() and not ln.startswith(("\t", " ")):
            break  # 遇到下一个顶格声明
        body.append(ln)
    return "\n".join(body)


def main() -> int:
    if not os.path.isfile(TARGET):
        print("[FAIL] 找不到 encounter_manager.gd")
        return 1

    with open(TARGET, "r", encoding="utf-8") as f:
        raw = f.read()
    src = strip_comments(raw)
    code = src  # 校验全部基于剥注释后的代码

    # ---------- I1 顺序铁律 ----------
    proc = func_body(code, "_process")
    check(bool(proc), "I1 前置：源码里找不到 _process")

    i_has = proc.find("_triggered_ids.has(")
    i_is_manual = proc.find("_is_manual(")
    check(i_has >= 0, "I1 失败：_process 内没有 _triggered_ids 结算标记判定")
    check(i_is_manual >= 0, "I1 失败：_process 内没有 _is_manual 类型判定")
    if i_has >= 0 and i_is_manual >= 0:
        check(
            i_has < i_is_manual,
            "I1 失败（行为回归·战斗怪会被每帧重复触发）：_process 里 "
            "_triggered_ids 判定(%d) 必须早于 _is_manual 判定(%d)。"
            "顺序颠倒后，已结算的战斗点会落进「走近自动触发」分支，"
            "站着不动也会反复开战斗场景。" % (i_has, i_is_manual),
        )

    # I1 附赠：已结算分支不得再走战斗触发（同一 continue 结构）
    check(
        "for node in get_children()" not in proc,
        "P1 失败（每帧性能回退）：_process 内仍出现 get_children() 全量遍历。"
        "应改走 _enc_nodes / _manual_nodes 缓存数组。",
    )
    check(
        not re.search(r"var\s+\w+\s*:\s*Array\[Node2D\]\s*=\s*\[\]", proc),
        "P2 失败（每帧分配回退）：_process 内新建了 Array[Node2D] = [] 字面量。"
        "每帧分配数组正是第五十二轮从 _any_ui_open() 清掉的反形态，不得回退。",
    )

    # ---------- 提示唯一性（I1 同族，防「同屏两串 ▲ 可交互」） ----------
    check(
        "_set_hint(node, node == near_manual)" in proc,
        "I1b 失败（提示唯一性回归）：_process 必须用恒等式写法 "
        "`_set_hint(node, node == near_manual)` 统一刷新提示。"
        "若改成「谁不是最近就收起谁」，会有遍历顺序依赖——远点先被访问并临时"
        "占位 near_manual、随后被近点抢走后走不到收起分支，上一帧亮着的提示"
        "会留在屏幕上，同屏出现两串「▲ 可交互」。",
    )

    # ---------- I2 缓存同步 ----------
    spawn = func_body(code, "_spawn_one")
    check(
        "_enc_nodes.append(node)" in spawn,
        "I2 失败：_spawn_one 未把新节点登记进 _enc_nodes，_process 会漏掉该遭遇点。",
    )
    # _manual_nodes 登记必须在 Hint 创建的同一个 _is_manual 分支内
    hint_idx = spawn.find('hint.name = "Hint"')
    manual_idx = spawn.find("_manual_nodes.append(node)")
    check(
        hint_idx >= 0 and manual_idx > hint_idx,
        "I2 失败：_manual_nodes.append 未放在 Hint 创建之后，"
        "提示节点尚未存在就被登记进提示刷新子集。",
    )

    reload_fn = func_body(code, "reload_region")
    check(
        "_enc_nodes.clear()" in reload_fn,
        "I2 失败：reload_region 未清空 _enc_nodes，跨区重载后 _process "
        "会遍历到上一区域已 queue_free 的节点。",
    )
    check(
        "_manual_nodes.clear()" in reload_fn,
        "I2 失败：reload_region 未清空 _manual_nodes，提示刷新子集与真实节点集不同步。",
    )

    # 两个缓存成员必须真实声明为 Array[Node2D]
    for name in ("_enc_nodes", "_manual_nodes"):
        check(
            re.search(rf"var\s+{name}\s*:\s*Array\[Node2D\]\s*=\s*\[\]", code) is not None,
            f"I2 失败：成员 {name} 未以 `var {name}: Array[Node2D] = []` 声明。",
        )

    # ---------- I3 dist 契约 ----------
    near = func_body(code, "nearest_interactable")
    check(bool(near), "I3 前置：源码里找不到 nearest_interactable")
    check(
        "get_children()" not in near,
        "P1 失败（每帧性能回退）：nearest_interactable 内仍出现 get_children()，"
        "应改走 _enc_nodes 缓存。",
    )
    check(
        "distance_squared_to" in near,
        "I3 失败：nearest_interactable 未使用 distance_squared_to。",
    )
    # 返回的 dist 必须经 sqrt 还原
    dist_idx = near.find('"dist"')
    check(dist_idx >= 0, "I3 失败：nearest_interactable 未返回 dist 字段。")
    if dist_idx >= 0:
        line = near[dist_idx: near.find("\n", dist_idx)]
        check(
            "sqrt(" in line,
            "I3 失败（静默量纲错误）：返回的 dist 必须是 sqrt(平方距离) 还原后的真实"
            "距离，不能直接返回 best_d2。直接返回平方值不会报错，只会让 "
            "world_map.gd 拿到的距离量级完全错误。当前行：%s" % line.strip(),
        )
    check(
        re.search(r'"dist"\s*:\s*best_d2\b', near) is None,
        "I3 失败：dist 直接取了平方距离 best_d2，必须 sqrt 还原。",
    )

    # ---------- 平方距离比较的半径也必须同步平方化 ----------
    check(
        "INTERACT_RADIUS * INTERACT_RADIUS" in near,
        "I3 失败：nearest_interactable 用了平方距离，但半径仍是未平方的 "
        "INTERACT_RADIUS —— 半径被平方后才可比，否则交互范围会失真。",
    )

    # ---------- 汇总 ----------
    print("=" * 62)
    print("第五十四轮 遭遇管理器性能改造 · 行为不变量校验")
    print("=" * 62)
    print(f"  目标文件：{os.path.relpath(TARGET, HERE)}")
    print(f"  判定项：{CHECKS}")
    if FAILS:
        print(f"  结果：FAIL（{len(FAILS)} 项）")
        print("-" * 62)
        for m in FAILS:
            print("  [FAIL] " + m)
        return 1
    print("  结果：PASS（0 FAIL）")
    print("-" * 62)
    print("  I1 顺序铁律：_triggered_ids 判定早于 _is_manual 判定 ✓")
    print("  I1b 提示唯一性：恒等式 _set_hint(node, node == near_manual) ✓")
    print("  I2 缓存同步：_enc_nodes / _manual_nodes 登记与清空成对 ✓")
    print("  I3 dist 契约：sqrt 还原真实距离，半径同步平方化 ✓")
    print("  P1 无每帧 get_children() 全量遍历 ✓")
    print("  P2 无每帧数组分配 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())