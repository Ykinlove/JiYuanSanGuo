#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第六十三轮校验：自立建国二次确认（本工程最重的不可逆操作一点即过）

背景（取证，非推测）
--------------------
`SelfRuleService.found_self_rule()` 落地 4 项**全部不可逆**的全局变更：

| 变更 | 位置 | 可逆性 |
|---|---|---|
| `is_self_rule = true` | self_rule_service.gd:138 | **本局不可逆** —— 全工程唯一的 `is_self_rule = false` 只在 `GameState.reset()`（开新档）；game_state.gd:1256 |
| 全势力关系 `modify(fid, -10)` | self_rule_service.gd:147-149 | 不可逆（外交手段只加不返） |
| `join_intent = 0` | self_rule_service.gd:152 | 投靠意向作废，无法再面见主公 |
| 失败结局线开启 | `check_ending()` 逐月跑（game_state.gd:715） | `infamy>=80` 即 `ending_triggered=true` 终局，不可重开 |

而入口 `SelfRulePanel._on_confirm()` 原先**一点即过**，无任何确认。

同屏反证（最硬的一条）：城内「处死俘虏」（city_scene.gd:1617）与「解散部队」
（city_scene.gd:1822）都是不可逆资源销毁，第五十一轮已各自补上 `make_sub_modal`
二次确认；主菜单「开新的征程」（main_menu.gd:49）也有。**唯独最重的自立建国没有** ——
同类型操作里最不可逆的那个反而最不设防。

修复：`_on_confirm()` 的未自立分支先跑 `can_attempt` 门禁，再走
`_show_found_confirm()`；确认后才调 `_do_found()`。

**刻意不拦**（避免矫枉过正）：已自立后的「改国号」是可逆的（随时能再改回去），
不弹确认。`can_attempt` 不通过 / 国号空白时也不弹 —— 本来就建不了国，
弹「不可逆」确认窗等于给玩家看一个根本执行不了的后果。

本轮要防的四种失败：
  1. 拦不足 → 弹窗只是样子，确认前后 GameState 都被改；
  2. 拦过头 → 改国号（可逆）也弹 / 前置不满足也弹（凭空加步骤）；
  3. 文案骗人 → 写「可撤销/可回退」当兜底；
  4. 文案不全 → 没点明势力关系下降与结局不可重开，玩家不知道代价。

两层校验：
  【headless 真跑】（tests/self_rule_guard_probe.gd + .tscn，39 项）
    A 点「自立建国」→ 弹确认，拦截期六项内存态零改动
    B 取消 → 未建国 + 关系未降 + join_intent 未动
    C 确认 → is_self_rule/国号/旗帜/都城写入 + 3/3 家势力各降 10 + join_intent 作废
    D 已自立后改国号**不**弹确认（可逆不加步骤）
    E 文案点明不可逆 + 势力关系 + 投靠作废 + 覆灭结局 + 无虚假兜底
    F 弹窗国号/旗帜为构建时快照
    G 连点 3 次不叠遮罩、不改待建参数
    H 关闭回调只关窗不建国
    I 信物未齐 / 国号空白 / 已投靠势力 → 不弹确认窗
  【独立锚定上游源码】（本文件，防探针与被测代码同改而互相放过）
    J1 未自立分支必须经`_show_found_confirm` 且先 return
    J2 实际建国动作只在 `_do_found` 里，`_on_confirm` 不得直调 found_self_rule
    J3 `_show_found_confirm` 幂等守卫 + 三项快照
    J4 关闭路径不得建国
    J5 改国号分支不得弹确认（可逆操作不加步骤）
    J6 国号空白判定必须 strip_edges（只输空格不得放行到确认窗）
    J7 文案不得含「可撤销/可回退」类虚假兜底
    J8 第六十一/六十二轮的存档确认不得回退
"""
import hashlib
import os
import re
import subprocess
import _safe_cleanup

HERE = os.path.dirname(os.path.abspath(__file__))
PANEL = os.path.join(HERE, "scripts", "ui", "self_rule_panel.gd")
SVC = os.path.join(HERE, "scripts", "services", "self_rule_service.gd")
GAMESTATE = os.path.join(HERE, "scripts", "autoload", "game_state.gd")
SAVE_MENU = os.path.join(HERE, "scripts", "main", "save_menu.gd")
PROBE_GD = os.path.join(HERE, "tests", "self_rule_guard_probe.gd")
PROBE_TSCN = os.path.join(HERE, "tests", "self_rule_guard_probe.tscn")
RESULT = os.path.join(HERE, "self_rule_guard_result.txt")
SAVES_DIR = os.path.join(
    os.environ.get("APPDATA", ""), "Godot", "app_userdata", "纪元三国", "saves"
)
GODOT = r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe"

FAILS = []
CNT = [0]


def check(cond, msg):
    CNT[0] += 1
    if not cond:
        FAILS.append(msg)


def read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def strip_comments(src):
    """去注释：只留可执行代码。判据必须查代码，不能查注释——
    本轮自写注释里就含「不可逆」等词，查 raw 会命中自己写的说明。"""
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

def norm_lines(body):
    return [ln.strip() for ln in body.split("\n") if ln.strip()]


def saves_fingerprint():
    fp = {}
    if not os.path.isdir(SAVES_DIR):
        return fp
    for name in sorted(os.listdir(SAVES_DIR)):
        p = os.path.join(SAVES_DIR, name)
        if not os.path.isfile(p):
            continue
        with open(p, "rb") as f:
            fp[name] = hashlib.sha256(f.read()).hexdigest()[:16]
    return fp


def main():
    for p in (PANEL, SVC, GAMESTATE, SAVE_MENU, PROBE_GD, PROBE_TSCN):
        if not os.path.isfile(p):
            print("[FAIL] 找不到 %s" % p)
            return 1

    raw = read(PANEL)
    code = strip_comments(raw)
    svc = read(SVC)
    save_raw = read(SAVE_MENU)

    # ================= headless 真跑 =================
    before_fp = saves_fingerprint()
    if os.path.isfile(RESULT):
        _safe_cleanup.discard(RESULT)
    try:
        subprocess.run(
            [GODOT, "--headless", "--path", ".",
             "--scene", "res://tests/self_rule_guard_probe.tscn",
             "--quit-after", "900"],
            cwd=HERE, capture_output=True, text=True, timeout=300,
        )
    except subprocess.TimeoutExpired:
        FAILS.append("headless 探针超时 —— 多半是 _run() 或某个 _check_* 漏了 await，"
                     "或探针未退出")
    except FileNotFoundError:
        FAILS.append("找不到 Godot 可执行文件: " + GODOT)

    after_fp = saves_fingerprint()
    check(
        before_fp == after_fp,
        "探针污染了玩家存档目录 —— 跑前/跑后指纹不一致。\n"
        "    跑前：%s\n    跑后：%s" % (before_fp, after_fp),
    )

    rlines = []
    if os.path.isfile(RESULT):
        rlines = read(RESULT).splitlines()
    check(bool(rlines), "headless 探针未产出结果文件 —— 引擎可能报 SCRIPT ERROR")

    if rlines:
        fails = [ln.strip() for ln in rlines if "] FAIL" in ln]
        check(not fails, "headless 探针判定 FAIL：\n    " + "\n    ".join(fails))
        total = next((ln for ln in rlines if ln.startswith("TOTAL")), "")
        check("TOTAL 39" in total,
              "headless 判定项数异常（期望 39，实际 %r）—— "
              "探针可能被裁剪，防误触覆盖面缩小" % total.strip())
        for ln in rlines:
            if ln.strip().startswith("["):
                print("    " + ln.strip())

    check(len(raw) > 4000,
          "锚定层失效：读到的 self_rule_panel.gd 长度异常小，可能未真正锚定")

    # ================= J1–J8 独立锚定上游源码 =================

    # --- J1：未自立分支必须先 return ---
    oc = func_body(code, "_on_confirm")
    check(bool(oc), "J1 前置：找不到 _on_confirm")
    if oc:
        lines = norm_lines(oc)
        call_i = next((i for i, ln in enumerate(lines)
                       if "_show_found_confirm()" in ln), None)
        check(
            call_i is not None,
            "J1 失败：_on_confirm 的未自立分支没有走 _show_found_confirm() —— "
            "不可逆的建国一点即过，等于没修。",
        )
        if call_i is not None:
            # 【判据形态对齐·修正】不能硬要求「下一行是 return」——那是第六十二轮
            # save_menu 的形状（`if guard: _show_x(); return; _do_load()`）。
            # 本函数用的是另一种同样正确的形状：前置守卫各自提前 return，
            # 弹窗调用是**函数的终止语句**，其后没有任何可执行代码。
            # 真正要防的是「弹完窗之后还有代码继续建国」，故判据改为：
            # _show_found_confirm() 之后不得残留任何可执行语句。
            tail = [ln for ln in lines[call_i + 1:]
                    if ln and not ln.startswith("##")]
            check(
                not tail,
                "J1 失败：_show_found_confirm() 之后仍有可执行语句 %r —— "
                "弹完确认窗还会继续往下执行建国动作，防误触形同虚设。"
                "该调用应是本函数的终止语句。" % tail[:3],
            )
        # 门禁顺序：can_attempt 必须早于 _show_found_confirm
        pre_i = next((i for i, ln in enumerate(lines)
                      if "can_attempt" in ln), None)
        check(
            pre_i is not None and call_i is not None and pre_i < call_i,
            "J1b 失败：can_attempt 门禁必须早于 _show_found_confirm —— "
            "前置不满足时不该弹「不可逆」确认窗（那等于让玩家确认一个"
            "根本执行不了的后果）。",
        )

    # --- J2：实际建国动作只在 _do_found ---
    if oc:
        check(
            "found_self_rule" not in oc,
            "J2 失败：_on_confirm 仍直接调 SelfRuleService.found_self_rule —— "
            "实际建国动作必须抽到 _do_found，确认/直进两条路径共用，"
            "避免逻辑分叉后又漏掉确认。",
        )
    df = func_body(code, "_do_found")
    check(bool(df), "J2 前置：找不到 _do_found")
    if df:
        check(
            "found_self_rule" in df,
            "J2b 失败：_do_found 里没有调用 found_self_rule —— 确认后不会真建国。",
        )
    check(
        re.search(r"_do_found\s*\(", code) is not None,
        "J2c 失败：全工程没有 _do_found 的调用点，确认按钮接不到实际动作。",
    )

    # --- J3：幂等守卫 + 三项快照 ---
    sc = func_body(code, "_show_found_confirm")
    check(bool(sc), "J3 前置：找不到 _show_found_confirm")
    if sc:
        check(
            re.search(r"if\s+_found_confirm\s*!=\s*null", sc) is not None,
            "J3 失败：_show_found_confirm 缺幂等守卫 —— 连点会叠多层遮罩。",
        )
        for field, src in (
            ("_pending_found_city", "_self_rule_city"),
            ("_pending_found_name", "_name_edit.text"),
            ("_pending_found_flag", "_flag_selected"),
        ):
            pat = rf"{re.escape(field)}\s*=\s*{re.escape(src)}"
            check(
                re.search(pat, sc) is not None,
                "J3b 失败：_show_found_confirm 未从 %s 取构建时快照到 %s —— "
                "弹窗信息会随外部状态漂移。" % (src, field),
            )
        check(
            "make_sub_modal" in sc,
            "J3c 失败：确认窗没用 UITheme.make_sub_modal —— "
            "与处死俘虏/解散部队/删档/读档的确认不一致。",
        )

    # --- J4：关闭路径不得建国 ---
    cc = func_body(code, "_close_found_confirm")
    check(bool(cc), "J4 前置：找不到 _close_found_confirm")
    if cc:
        check(
            "_do_found" not in cc and "found_self_rule" not in cc,
            "J4 失败：_close_found_confirm 里出现建国调用 —— "
            "点遮罩/点取消会直接建国，防误触形同虚设。",
        )
        check(
            "_pending_found_city" in cc and "_pending_found_name" in cc,
            "J4b 失败：_close_found_confirm 未清空待建参数 —— "
            "下次开面板会残留上一轮的国号/都城。",
        )
    if sc:
        # 确认按钮回调必须调 _do_found（构造阶段不得直接建国）
        ok_i = next((i for i, ln in enumerate(norm_lines(sc))
                     if "确认建国" in ln), None)
        check(ok_i is not None, "J4c 失败：确认窗里找不到「确认建国」按钮")
        if ok_i is not None:
            seg = norm_lines(sc)[ok_i:ok_i + 12]
            joined = "\n".join(seg)
            check(
                "_do_found" in joined,
                "J4d 失败：确认按钮回调没有调 _do_found —— 点了确认不会建国。",
            )
            check(
                joined.index("_close_found_confirm()") < joined.index("_do_found"),
                "J4e 失败：确认回调必须先关窗再建国，"
                "否则遮罩会留在已建国的界面上。",
            )

    # --- J5：改国号分支不得弹确认（可逆操作不加步骤）---
    if oc:
        seg = oc.split("SelfRuleService.rename")[0]
        check(
            "_show_found_confirm" not in seg,
            "J5 失败：改国号（可逆操作）分支里也调了 _show_found_confirm —— "
            "凭空给玩家加一步确认，属于矫枉过正。",
        )
        check(
            "is_self_rule" in seg,
            "J5b 失败：_on_confirm 缺少 is_self_rule 分流 —— "
            "已自立与未自立是两条语义完全不同的路径。",
        )

    # --- J6：国号空白必须 strip_edges ---
    if oc:
        check(
            re.search(r"strip_edges\(\)\.is_empty\(\)", oc) is not None,
            "J6 失败：国号空白判定没用 strip_edges().is_empty() —— "
            "玩家只输入空格会一路走到「不可逆」确认窗，"
            "点完确认才被 found_self_rule 拒掉（白吓一跳，代价为零）。",
        )
        check(
            not re.search(r"_name_edit\.text\.is_empty\(\)", oc),
            "J6b 失败：仍存在 `_name_edit.text.is_empty()` 裸判定 —— "
            "对全空格输入放行。",
        )

    # --- J7：文案无虚假兜底 ---
    if sc:
        for bad in ("可撤销", "可回退", "可以反悔", "随时能反悔"):
            check(
                bad not in sc,
                "J7 失败：确认文案含「%s」类虚假兜底承诺 —— "
                "建国在本局内不可逆（is_self_rule 唯一复位点是开新档）。" % bad,
            )
        for must, why in (
            ("不可", "未点明不可逆"),
            ("势力关系", "未点明全势力关系下降"),
            ("投靠", "未点明投靠意向作废"),
            ("覆灭", "未点明失败结局不可重开"),
        ):
            check(
                must in sc,
                "J7b 失败：确认文案%s —— 玩家点确认前有权知道代价。" % why,
            )

    # --- J8：前两轮存档确认不得回退 ---
    check(
        "exists and _in_game" in strip_comments(save_raw),
        "J8 失败：第六十二轮的游戏内读档确认守卫被回退。",
    )
    check(
        "_show_overwrite_confirm" in strip_comments(save_raw),
        "J8b 失败：第六十一轮的覆盖存档确认被回退。",
    )

    # ================= 服务层取证回显 =================
    check(
        "RIVAL_RELATION_DELTA := -10" in svc,
        "取证失效：RIVAL_RELATION_DELTA 不再是 -10，"
        "确认文案里的「各降 %d 点」需与常量同步" % 0,
    )
    gs = read(GAMESTATE)
    resets = re.findall(r"is_self_rule\s*=\s*false", gs)
    check(
        len(resets) == 1,
        "取证失效：is_self_rule = false 出现 %d 处（预期仅 GameState.reset() 一处）—— "
        "若新增了复位路径，「本局不可逆」的文案前提需重写。" % len(resets),
    )

    # ================= 汇总 =================
    print("\n" + "=" * 62)
    if FAILS:
        print("【FAIL】共 %d 项未通过（判定总数 %d）：" % (len(FAILS), CNT[0]))
        for m in FAILS:
            print("  ✗ " + m)
        print("=" * 62)
        return 1
    print("【OK】共 %d 项判定全部通过 —— 自立建国已加不可逆二次确认" % CNT[0])
    print("=" * 62)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
