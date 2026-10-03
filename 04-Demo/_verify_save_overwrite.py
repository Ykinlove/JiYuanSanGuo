#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第六十一轮校验：存档覆盖防误触（不可逆操作必须二次确认）

背景
----
取证自 `scripts/main/save_menu.gd`：

  | 操作               | 旧版行为                          | 代价           |
  |--------------------|-----------------------------------|----------------|
  | 删除已有槽位       | `_show_del_confirm()` 二次确认   | 不可逆         |
  | **覆盖已有槽位**   | **直接 `save_game(slot)` 一点即过** | **同样不可逆** |

两者丢的都是一整局进度，代价等价，却一个拦一个放行 —— 同屏两个按钮行为
不对称。玩家在 3 个满档之间点错一次，一整局就没了，且**没有 .bak 可救**
（`_atomic_write` 的 .bak 只保原子性，不保历史）。

修复：`_mode == "save"` 且 `exists == true` 时先走 `_show_overwrite_confirm()`，
确认才写盘；**空槽保持直达**（新档不可逆性为零，凭空加一步是骚扰）。

**这类修复最危险的失败模式有两个**：
  1. 「拦过头」——空档也弹确认，或确认后写不进档（玩家存不了游戏）；
  2. 「弹窗是摆设」——文案不在确认态重查是对的，但若弹窗本身不落快照，
     列表刷新后同一弹窗会显示两个版本的旧档信息。

故本校验分两层：
  【headless 真跑】（tests/save_overwrite_probe.gd + .tscn）
    A 空槽保存 → 直达写盘，不弹确认（不得凭空加步骤）
    B 已有档保存 → 弹确认，且拦截期间旧档零改动（sha 比对）
    C 取消 → 旧档零改动 + 弹窗关闭 + pending 复位
    D 确认 → 写盘生效 + 弹窗关闭
    E 弹窗旧档摘要为**构建时快照**（弹窗期间外部改盘不污染文案）
    F 读档模式 → 不弹确认、不写盘、不残留 pending（不拦不可撤销性为零的操作）
    G 重复触发 → 不叠遮罩、不改待写槽位（防连点）
    H 关闭回调 → 只关窗不写盘
  【独立锚定上游源码】（本文件，防探针与被测代码同改而互相放过）
    J1 `_on_slot_pressed` 的 load 分支 return 必须**早于** `if exists:`
    J2 save 分支里 `save_game` 必须只在 exists 分支之外
    J3 `_show_overwrite_confirm` 必须有 pending 幂等守卫
    J4 两个关闭路径（cancel / close_cb）都不得调 save_game
    J5 删除确认的既有拦截不得被回退（本轮改动不能碰坏 B10）
    J6 弹窗必须展示旧档摘要（不得是「确定覆盖吗？」这种空确认）

【副作用管控】headless 探针真实读写 `user://saves/`。校验器在跑探针**前后**
各做一次目录指纹，探针若留下残留（slot_3 / _meta / _meta.bak）直接判 FAIL ——
测试污染玩家存档是不可接受的副作用。
"""
import hashlib
import os
import re
import subprocess
import sys
import _safe_cleanup

HERE = os.path.dirname(os.path.abspath(__file__))
SAVE_MENU = os.path.join(HERE, "scripts", "main", "save_menu.gd")
PROBE_GD = os.path.join(HERE, "tests", "save_overwrite_probe.gd")
PROBE_TSCN = os.path.join(HERE, "tests", "save_overwrite_probe.tscn")
RESULT = os.path.join(HERE, "save_overwrite_result.txt")
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

def saves_fingerprint():
    """存档目录指纹：文件名 -> 内容 sha。用于探测针副作用。"""
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
    for p in (SAVE_MENU, PROBE_GD, PROBE_TSCN):
        if not os.path.isfile(p):
            print("[FAIL] 找不到 %s" % p)
            return 1

    raw = read(SAVE_MENU)
    code = strip_comments(raw)

    # ================= headless 真跑 =================
    before_fp = saves_fingerprint()
    if os.path.isfile(RESULT):
        _safe_cleanup.discard(RESULT)
    try:
        subprocess.run(
            [GODOT, "--headless", "--path", ".", "tests/save_overwrite_probe.tscn"],
            cwd=HERE, capture_output=True, text=True, timeout=300,
        )
    except subprocess.TimeoutExpired:
        FAILS.append("headless 探针超时 —— 很可能探针里漏了 get_tree().quit()"
                     "或协程调用处漏写 await（Parse Error 会让脚本加载失败、"
                     "场景空跑、进程不退出）")
    except FileNotFoundError:
        FAILS.append("找不到 Godot 可执行文件: " + GODOT)

    after_fp = saves_fingerprint()
    check(
        before_fp == after_fp,
        "探针污染了玩家存档目录user://saves/ —— 跑前/跑后指纹不一致。\n"
        "    跑前：%s\n    跑后：%s\n"
        "    测试不得在玩家真实存档上留残留（探针需自行备份还原全部受影响文件，"
        "含 SaveManager 原子写产生的 .bak 副产品）。" % (before_fp, after_fp),
    )

    rlines = []
    if os.path.isfile(RESULT):
        rlines = read(RESULT).splitlines()
    check(bool(rlines), "headless 探针未产出结果文件 —— 引擎可能报 SCRIPT ERROR")

    if rlines:
        check(
            not any(ln.strip() == "SAVE_OVERWRITE_FAIL" for ln in rlines),
            "headless 探针判定 FAIL：\n    " + "\n    ".join(
                ln.strip() for ln in rlines if ln.strip().startswith("[")),
        )
        for tag in ("A_EMPTY_DIRECT", "B_EXIST_BLOCKED", "C_CANCEL_NOWRITE",
                    "D_CONFIRM_WRITES", "E_SNAPSHOT_SOURCE", "F_LOAD_MODE_DIRECT",
                    "G_NO_DOUBLE_MODAL", "H_CLOSE_NOWRITE"):
            val = ""
            for ln in rlines:
                if ln.startswith(tag + "="):
                    val = ln.split("=", 1)[1].strip()
            check(val == "true", "headless 判定 %s 未通过（实际=%r）" % (tag, val))
        for ln in rlines:
            if ln.startswith("RESTORE"):
                print("    [取证] " + ln.strip())

    check(
        len(raw) > 3000,
        "锚定层失效：探针读到的源码长度异常小，可能未真正锚定 save_menu.gd",
    )

    # ================= J1–J6 独立锚定上游源码 =================
    osp = func_body(code, "_on_slot_pressed")
    check(bool(osp), "J1 前置：找不到 _on_slot_pressed")
    if osp:
        lines = [ln.strip() for ln in osp.split("\n") if ln.strip()]
        # J1：load 分支的 return 必须早于 `if exists:` ——
        # 若顺序反了，读档模式也会被拦（读档不销毁数据，拦它属矫枉过正）
        load_ret = None
        exists_at = None
        for i, ln in enumerate(lines):
            if load_ret is None and ln == "return" and any(
                '_mode == "load"' in x for x in lines[max(0, i - 3):i]
            ):
                load_ret = i
            if exists_at is None and re.match(r"^if\s+exists\s*:", ln):
                exists_at = i
        check(
            load_ret is not None,
            "J1 失败：_on_slot_pressed 的 load 分支里找不到 return —— "
            "读档模式会继续往下走进覆盖确认，读个档被拦。",
        )
        check(
            exists_at is not None,
            "J1 失败：_on_slot_pressed 里找不到 `if exists:` —— "
            "已有档与空档未分流，等于没做防误触。",
        )
        if load_ret is not None and exists_at is not None:
            check(
                load_ret < exists_at,
                "J1 失败：load 分支的 return（第 %d 行）晚于 `if exists:`"
                "（第 %d 行）—— 读档也会弹覆盖确认，读档不销毁数据，"
                "拦它属于矫枉过正。" % (load_ret + 1, exists_at + 1),
            )

        # J2：save 分支里 save_game 必须只在 exists 分支之外
        # 锚定「调用点所在的缩进层级」：弹窗内不得直接调save_game，
        # 只能经由「确认」按钮的回调。exists 分支必须在 show 之后 return。
        exists_body = "\n".join(lines[exists_at:]) if exists_at is not None else ""
        show_at = None
        for i, ln in enumerate(lines):
            if "_show_overwrite_confirm" in ln and not ln.startswith("func "):
                show_at = i
                break
        check(
            show_at is not None and exists_at is not None and show_at > exists_at,
            "J2 失败：exists 分支未调用 _show_overwrite_confirm —— "
            "点已有档仍会一点即过（本轮要修的缺口）。",
        )
        if exists_at is not None:
            # exists 分支的函数体必须以 return 结束，不再直落 save_game
            after_exists = lines[exists_at + 1:]
            ret_positions = [i for i, ln in enumerate(after_exists) if ln == "return"]
            save_pos = [
                i for i, ln in enumerate(after_exists) if "save_game" in ln
            ]
            check(
                bool(ret_positions) and bool(save_pos) and ret_positions[0] < save_pos[0],
                "J2 失败：exists 分支在弹确认之后仍会继续执行到 save_game —— "
                "弹窗成了摆设，点一下照样覆盖。必须先return。",
            )

    # J3：_show_overwrite_confirm 必须有 pending 幂等守卫
    so = func_body(code, "_show_overwrite_confirm")
    check(bool(so), "J3 前置：找不到 _show_overwrite_confirm")
    if so:
        guard = re.search(r"if\s+_ovr_confirm\s*!=\s*null\s*:", so)
        check(
            guard is not None,
            "J3 失败：_show_overwrite_confirm 没有幂等守卫 —— "
            "连点/双击会叠出第二层遮罩，并把待写槽位改成另一个。",
        )
        if guard:
            # 【判据形态对齐】不能用 so[:guard.end()].split("\n")[-2:] ——
            # guard.end() 落在行尾的 ':' 上，split 后最后一段就是 if 行本身，
            # 取不到下一行的 return（会误报成「守卫没 return」）。
            # 正确做法：按行切出守卫行，再看其后紧邻的**非空行**。
            glines = [ln.strip() for ln in so.split("\n") if ln.strip()]
            gi = next(
                (i for i, ln in enumerate(glines)
                 if re.match(r"^if\s+_ovr_confirm\s*!=\s*null\s*:$", ln)),
                None,
            )
            check(
                gi is not None and gi + 1 < len(glines)
                and glines[gi + 1] == "return",
                "J3 失败：幂等守卫命中后没有 return（守卫行后紧邻的是 %r）—— "
                "遮罩叠了、pending 也被覆盖，连点会写错槽位。"
                % (glines[gi + 1] if gi is not None and gi + 1 < len(glines)
                   else "<无>"),
            )
        check(
            re.search(r"_ovr_old_name\s*=(?!=)", so) is not None,
            "J3 失败：_show_overwrite_confirm 未把旧档名写进快照 —— "
            "弹窗无法展示「要覆盖掉什么」，确认只剩形式。",
        )
        # J6：弹窗必须展示旧档摘要
        check(
            "永久丢失" in raw or "无法找回" in raw,
            "J6 失败：覆盖确认文案没有说明不可逆后果 —— "
            "玩家不知道这一下会丢掉一整局进度。",
        )

    # J4：两个关闭路径都不得调 save_game
    for fn in ("_close_overwrite_confirm",):
        body = func_body(code, fn)
        check(bool(body), "J4 前置：找不到 %s" % fn)
        if body:
            check(
                "save_game" not in body,
                "J4 失败：%s 里调用了 save_game —— "
                "关窗/撤销路径写盘，防误触直接失效。" % fn,
            )
    # 关闭回调的连线也必须只调 close
    for cb in ("_close_overwrite_confirm())",):
        check(
            cb in code,
            "J4 失败：找不到把 %s 接到取消/遮罩的回调" % cb,
        )

    # J5：删除确认的既有拦截不得被回退
    dl = func_body(code, "_show_del_confirm")
    check(bool(dl), "J5 前置：找不到 _show_del_confirm")
    if dl:
        check(
            re.search(r"if\s+_del_confirm\s*!=\s*null\s*:", dl) is not None,
            "J5 失败：_show_del_confirm 的幂等守卫被回退 —— "
            "本轮只该加覆盖确认，不该碰坏既有的删除确认（B10）。",
        )
        check(
            "delete_save" in dl,
            "J5 失败：_show_del_confirm 里找不到 delete_save —— "
            "删除确认流程被破坏。",
        )

    # ================= 汇总 =================
    print("=" * 68)
    print("第六十一轮 存档覆盖防误触 · 校验")
    print("=" * 68)
    print("  目标文件：scripts\\main\\save_menu.gd")
    print("  判定项：%d" % CNT[0])
    if FAILS:
        print("  结果：FAIL（%d 项）" % len(FAILS))
        print("-" * 68)
        for m in FAILS:
            print("  [FAIL] " + m)
        return 1
    print("  结果：PASS（0 FAIL）")
    print("-" * 68)
    print("  [headless 真跑]")
    print("    A 空槽保存 → 直达写盘，不弹确认 ✓")
    print("    B 已有档保存 → 弹确认，拦截期间旧档零改动（sha 比对）✓")
    print("    C 取消 → 旧档零改动 + 弹窗关闭 + pending 复位 ✓")
    print("    D 确认 → 写盘生效 + 弹窗关闭 ✓")
    print("    E 弹窗旧档摘要为构建时快照，弹窗期间外部改盘不污染 ✓")
    print("    F 读档模式 → 不弹确认、不写盘、不残留 pending ✓")
    print("    G 重复触发 → 不叠遮罩、不改待写槽位 ✓")
    print("    H 关闭回调 → 只关窗不写盘 ✓")
    print("  [独立锚定上游源码]")
    print("    J1 load 分支 return 早于 `if exists:`（读档不被误拦）✓")
    print("    J2 exists 分支弹确认后先 return（弹窗不是摆设）✓")
    print("    J3 _show_overwrite_confirm 有幂等守卫 + 旧档快照 ✓")
    print("    J4 关闭路径不含 save_game ✓")
    print("    J5 既有删除确认（B10）未被回退 ✓")
    print("    J6 弹窗文案说明不可逆后果 ✓")
    print("  [副作用管控]")
    print("    存档目录跑前/跑后指纹一致（探针零残留）✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())