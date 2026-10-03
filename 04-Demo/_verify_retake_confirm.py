#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
第五十五轮校验：收复军「弃城」二次确认（retake_popup.gd）行为不变量。

背景
----
兵临城下弹窗给出「迎 战 / 弃 城」两个**同高同宽（均 TOUCH_H=84）平级**按钮。
「迎 战」进战场，可反悔；「弃 城」不可逆 —— 直接失地、前功尽弃。
手机上一次点错就永久丢城，属典型高代价误触。项目已有二次确认范式
（处死俘虏、解散部队），弃城此前独缺同款保护。

改造：点「弃 城」先进确认态，必须再点一次（或点「确认弃城」）才真弃；
      「迎 战」直通不拦；「取 消」完整还原描述与初始态。

本校验锁死的不变量：
  R1【不可逆操作必须有二次确认】弃城路径上不得存在「一点即结算」的直通分支。
  R2【状态可复位】open() 必须复位 _flee_btn_armed / 按钮文案 / 确认行可见性，
     否则复用弹窗时会带上一次的确认态。
  R3【取消要完整还原】取消必须把描述还原为 open() 的原文（_base_text），
     否则反复点「弃 城」会让描述无限追加。
  R4【确认行初始隐藏】确认行建好即 visible=false，不得默认就摆在选择行旁边。
  R5【触控铁律】确认行上的按钮高度必须走 UITheme.TOUCH_H，不得低于 84px。
  R6【信号绑定方式】按钮必须用方法绑定（_on_xxx），不得用 lambda 捕获。
  R7【迎战不受影响】fight 分支必须直通 _decide(true)，不被确认态拦截。
  R8【音效反馈】进入确认态播确认音、取消播取消音（与项目内二次确认范式一致）。
  R9【同一屏不得出现两个势力名】确认态文案必须用 open() 传入的势力名快照，
     不得回头重查 GameState.city_claims —— 正文用快照、确认态用实时值时，
     两次点击之间若该城归属被势力 AI 改写，同一弹窗会先后显示两个不同势力名。
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, "scripts", "ui", "retake_popup.gd")

FAILS: list[str] = []
CHECKS = 0


def check(cond: bool, msg: str) -> None:
    global CHECKS
    CHECKS += 1
    if not cond:
        FAILS.append(msg)


def strip_comments(src: str) -> str:
    out = []
    for line in src.split("\n"):
        s = line.lstrip()
        if s.startswith("#"):
            out.append("")
            continue
        i = line.find("#")
        out.append(line[:i] if i >= 0 else line)
    return "\n".join(out)


def func_body(src, name):
    """提取函数体：先按括号配平吃掉完整签名（**可跨行**），再按缩进定界取体。

    【参数两种历史形态都要支持】（本轮统一时踩过：只认裸名会让 9 个
     用「完整签名片段」调用的校验器集体返回 None → 假红）
      · 裸名：      "_process"
      · 带 func 前缀："func add_legs("
      · 带参数字面： "func _process(delta"
    统一规约为：去掉 "func " 前缀 → 取首个 "(" 之前的部分 → 即函数名。

    【血泪·五次踩坑的最终形态，勿再简化】
      1) 只按 {}/} 配对 → 遇 `var x: Dictionary = {}` 立刻 depth 归零 → 体被截成几十字符
      2) 加字符串跳过后被单引号 'Hint' 搞乱状态
      3) 正则只写 ^func → 匹配不到 `static func` → 判据集体假红
      4) 按「第一个换行」当签名结束 → 截到的是签名续行（缩进更深）→ 真体缩进更小 → 立即 break
      5) **基线缩进取错行**：拿「签名后第一行代码」当基线，而该行通常是 `if`（1 tab），
         体里同级的 `if`/`var`（也是 1 tab）会被判成「函数结束」→ 体被截断 → 判据假红。
         正解：基线 = **函数签名行自身的缩进**（顶层函数恒为 0）。
    """
    fname = name.strip()
    if fname.startswith("func "):
        fname = fname[5:]
    fname = fname.split("(")[0].strip()
    if not fname:
        return None
    m = re.search(r"^(?:static\s+)?func\s+%s\s*\(" % re.escape(fname), src, re.M)
    if not m:
        return None
    i = src.find("(", m.start())
    depth = 0
    j = i
    while j < len(src):
        if src[j] == "(":
            depth += 1
        elif src[j] == ")":
            depth -= 1
            if depth == 0:
                break
        j += 1
    sig_line_start = src.rfind("\n", 0, m.start()) + 1
    head = src[sig_line_start:m.start()]
    baseline = len(head) - len(head.lstrip("\t"))
    k = src.find("\n", j)
    lines = src[k + 1:].split("\n")
    out = []
    for ln in lines:
        s = ln.strip()
        if s == "":
            out.append(ln)
            continue
        ind = len(ln) - len(ln.lstrip("\t"))
        if ind <= baseline:
            break
        out.append(ln)
    return "\n".join(out)

def main() -> int:
    if not os.path.isfile(TARGET):
        print("[FAIL] 找不到 retake_popup.gd")
        return 1

    with open(TARGET, "r", encoding="utf-8") as f:
        raw = f.read()
    code = strip_comments(raw)

    # ---------- R1 不可逆操作必须有二次确认 ----------
    flee = func_body(code, "_on_flee_pressed")
    check(bool(flee), "R1 前置：找不到 _on_flee_pressed（弃城入口）")
    if flee:
        # 弃城入口里不得直接调用 _decide(false)
        check(
            "_decide(false)" not in flee,
            "R1 失败（高代价误触未防）：_on_flee_pressed 内直接调用了 _decide(false)，"
            "点一次「弃城」就永久失地。必须先进确认态。",
        )
        check(
            "_flee_btn_armed" in flee,
            "R1 失败：_on_flee_pressed 未依据 _flee_btn_armed 做二次确认闸门。",
        )
        check(
            "_confirm_row.visible = true" in flee,
            "R1 失败：进入弃城确认态时未显示确认行，玩家看不到需要再确认。",
        )

    confirm = func_body(code, "_on_confirm_flee")
    check(bool(confirm), "R2 前置：找不到 _on_confirm_flee（弃城确认出口）")
    check(
        "_decide(false)" in confirm,
        "R1 失败：_on_confirm_flee 未真正结算弃城，二次确认形同虚设。",
    )

    # ---------- R2 状态可复位 ----------
    open_fn = func_body(code, "open")
    check(bool(open_fn), "R2 前置：找不到 open")
    for token, why in (
        ("_flee_btn_armed = false", "确认态标志未复位，复用弹窗会带上一次的确认态"),
        ('_flee_btn.text = "弃 城"', "弃城按钮文案未复位"),
        ("_confirm_row.visible = false", "确认行未复位隐藏"),
    ):
        check(token in open_fn, "R2 失败：open() 中「%s」—— %s" % (token, why))
    check(
        "_base_text = _desc.text" in open_fn,
        "R2 失败：open() 未把初始描述存入 _base_text，取消时无法还原文案。",
    )

    # ---------- R3 取消要完整还原 ----------
    cancel = func_body(code, "_on_cancel_flee")
    check(bool(cancel), "R3 前置：找不到 _on_cancel_flee")
    check(
        "_flee_btn_armed = false" in cancel,
        "R3 失败：取消未复位确认态标志。",
    )
    check(
        "_confirm_row.visible = false" in cancel,
        "R3 失败：取消未隐藏确认行。",
    )
    check(
        "_desc.text = _base_text" in func_body(code, "_restore_desc"),
        "R3 失败：_restore_desc 未把描述还原为 open() 原文 —— "
        "反复点「弃城」会让描述无限追加。",
    )

    # ---------- R4 确认行初始隐藏 ----------
    build = func_body(code, "_build_ui")
    check(bool(build), "R4 前置：找不到 _build_ui")
    check(
        "_confirm_row.visible = false" in build,
        "R4 失败：确认行建好时未置 visible=false，会默认就摆在选择行旁边。",
    )

    # ---------- R5 触控铁律 ----------
    btns = re.findall(r'UITheme\.button\([^)]*TOUCH_H[^)]*\)', code)
    check(
        len(btns) >= 4,
        "R5 失败（触控铁律·违规）：弹窗内按钮走 UITheme.TOUCH_H 的仅 %d 处，"
        "应至少 4 处（迎 战 / 弃 城 / 取 消 / 确认弃城）。"
        "低于 84px 的按钮在手机上难点中。" % len(btns),
    )
    # 确认行两个按钮必须用 UITheme.button（工厂强制 TOUCH_H）
    confirm_row_seg = ""
    if "_confirm_row = HBoxContainer.new()" in build:
        confirm_row_seg = build[build.find("_confirm_row = HBoxContainer.new()"):]
    check(
        confirm_row_seg.count("UITheme.button(") >= 2,
        "R5 失败：确认行上的「取 消 / 确认弃城」未走 UITheme.button 工厂，"
        "触控高度无保障。",
    )

    # ---------- R6 信号绑定方式 ----------
    check(
        ".pressed.connect(func(" not in code,
        "R6 失败：按钮信号仍用 lambda 捕获绑定（func(...)）—— "
        "项目铁律要求方法绑定，避免僵尸 handler。",
    )
    for fn in ("_on_fight_pressed", "_on_flee_pressed", "_on_cancel_flee", "_on_confirm_flee"):
        check(
            func_body(code, fn) != "",
            "R6 失败：缺少 %s 处理函数（按钮必须方法绑定，不得用 lambda）" % fn,
        )

    # ---------- R7 迎战不受影响 ----------
    fight = func_body(code, "_on_fight_pressed")
    check(
        "_decide(true)" in fight,
        "R7 失败：迎戰未直通 _decide(true)，或被确认态误拦 —— "
        "迎战可反悔，不该加二次确认（否则平白多一步，妨碍救火）。",
    )
    check(
        "_flee_btn_armed" not in fight,
        "R7 失败：迎战路径引用了弃城确认态标志，两者不应耦合。",
    )

    # ---------- R8 音效反馈 ----------
    check(
        "sfx_confirm()" in flee,
        "R8 失败：进入确认态未播确认音（与项目内二次确认范式不一致）。",
    )
    check(
        "sfx_cancel()" in cancel,
        "R8 失败：取消未播取消音。",
    )

    # ---------- R9 同一屏势力名一致性 ----------
    check(
        "_enemy_name" in flee,
        "R9 失败：确认态文案未引用 open() 的势力名快照 _enemy_name。",
    )
    check(
        "city_claims" not in flee,
        "R9 失败（同一屏双势力名）：_on_flee_pressed 内重查了 GameState.city_claims —— "
        "正文用 open() 快照、确认态用实时值，两次点击之间该城归属若被势力 AI 改写，"
        "同一弹窗会先后显示两个不同的势力名。必须统一用快照。",
    )
    check(
        "_enemy_name = faction_name" in open_fn,
        "R9 失败：open() 未把 faction_name 存入 _enemy_name 快照。",
    )

    # ---------- 汇总 ----------
    print("=" * 62)
    print("第五十五轮 弃城二次确认 · 防误触行为校验")
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
    print("  R1 弃城一点即结算的直通分支已消除（须二次确认） ✓")
    print("  R2 open() 复位确认态/文案/确认行 ✓")
    print("  R3 取消完整还原描述为 open() 原文 ✓")
    print("  R4 确认行建好即隐藏 ✓")
    print("  R5 四个按钮均走 TOUCH_H 工厂（≥84px） ✓")
    print("  R6 全部按钮方法绑定，无 lambda ✓")
    print("  R7 迎戰直通不受确认态影响 ✓")
    print("  R8 进入确认播确认音、取消播取消音 ✓")
    print("  R9 确认态势力名用 open() 快照，同屏不会出现两个势力名 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())