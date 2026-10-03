#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第六十二轮校验：游戏内读档防误触（丢弃未保存进度必须二次确认）

背景（取证，非推测）
--------------------
| 证据 | 命令/位置 | 事实 |
|---|---|---|
| 自动存档触发点 | `grep -rn "auto_save\\|save_game(AUTO_SLOT"` | 仅 create_hero.gd:831、battle_scene.gd:1960 两处 |
| 游戏内写盘 | `grep -rn "SaveManager\\." scripts/world\\|city\\|ui` | **零命中** |
| 读档覆盖范围 | `GameState.from_dict()` | 79 个字段**全量覆盖**内存态 |

即：跑商、招兵、占地、推进月份全部只存在内存里。战斗后跑商赚 3000 金 →
系统面板点「读取存档」= 一整段进度被`from_dict` 全量覆盖，**零确认**。

同屏反证（这是最硬的一条）：`settings_panel.gd:73` 的「返回主菜单」明确
提示"未保存的进度将丢失（自动存档已保留）"并弹 ConfirmationDialog；
一屏之隔的「读取存档」同样丢进度，却一点即过 —— 行为不对称。

修复：`_mode == "load"` 且 `exists` 且 `_in_game` 时先走 `_show_load_confirm()`。
`_in_game` 由 `open_as(..., in_game)` 显式传入（游戏内 true / 主菜单 false）——
**不拿 pending_return 反推**，那是表现层字段（返回哪个场景），
拿它承载「有没有对局」是耦合。

本轮要防的四种失败：
  1. 拦过头 → 主菜单读档也弹确认（凭空加步骤）/ 空槽也弹；
  2. 拦不足 → 弹窗只是样子，确认前后GameState 都被覆盖；
  3. 文案骗人 → 写「自动存档已保留」当兜底（自动档只在创角/战斗结算写，
     读档后玩家回不到那个时间点，这句承诺不成立）；
  4. 入口漏改 → settings_panel / main_menu 只改一处，另一处仍按旧语义。

两层校验：
  【headless 真跑】（tests/save_load_guard_probe.gd + .tscn）
    A 游戏内点已有档 → 弹确认，期间当前进度零改动
    B 取消 → 进度保住 + 弹窗关闭 + pending 复位
    C 确认 → GameState 真被目标档覆盖（角色名/金币/公元年月）
    D 主菜单进入 → 不弹确认，且直达读档（不拦过头）
    E 文案点明丢失范围 + 无虚假兜底承诺
    F 目标档摘要为构建时快照（弹窗期间外部改盘不污染）
    G 重复触发 → 不叠遮罩、不改待读槽位
    H 关闭回调 → 只关窗不读档
    I 游戏内点空槽 → 不进确认分支
  【独立锚定上游源码】（本文件，防探针与被测代码同改而互相放过）
    K1 load 分支的三重守卫：exists && _in_game 才进确认
    K2 实际读档动作只在 _do_load 里，且 _on_slot_pressed 不直接调 load_game
    K3 _show_load_confirm 必须有幂等守卫 + 目标档快照
    K4 关闭路径（cancel / close_cb）都不得调 _do_load / load_game
    K5 三个入口的 in_game 取值必须正确（settings_panel true / main_menu false）
    K6 文案不得含"自动存档已保留"（不成立的兜底承诺）
    K7 第六十一轮的覆盖确认不得被回退

【副作用管控】探针真实读写 `user://saves/`，跑前跑后做目录指纹比对。
"""
import hashlib
import os
import re
import subprocess
import sys
import _safe_cleanup

HERE = os.path.dirname(os.path.abspath(__file__))
SAVE_MENU = os.path.join(HERE, "scripts", "main", "save_menu.gd")
SETTINGS = os.path.join(HERE, "scripts", "ui", "settings_panel.gd")
MAIN_MENU = os.path.join(HERE, "scripts", "main", "main_menu.gd")
PROBE_GD = os.path.join(HERE, "tests", "save_load_guard_probe.gd")
PROBE_TSCN = os.path.join(HERE, "tests", "save_load_guard_probe.tscn")
RESULT = os.path.join(HERE, "save_load_guard_result.txt")
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


def func_body(code, name):
    m = re.search(rf"^func {re.escape(name)}\s*\(", code, re.M)
    if not m:
        return ""
    start = m.start()
    nxt = re.search(r"^func ", code[m.end():], re.M)
    end = m.end() + nxt.start() if nxt else len(code)
    return code[start:end]


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
    for p in (SAVE_MENU, SETTINGS, MAIN_MENU, PROBE_GD, PROBE_TSCN):
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
            [GODOT, "--headless", "--path", ".", "tests/save_load_guard_probe.tscn"],
            cwd=HERE, capture_output=True, text=True, timeout=300,
        )
    except subprocess.TimeoutExpired:
        FAILS.append("headless 探针超时 —— 很可能漏了 get_tree().quit()"
                     "或协程调用处漏写 await（Parse Error 会让脚本加载失败、"
                     "场景空跑、进程不退出）")
    except FileNotFoundError:
        FAILS.append("找不到 Godot 可执行文件: " + GODOT)

    after_fp = saves_fingerprint()
    check(
        before_fp == after_fp,
        "探针污染了玩家存档目录 user://saves/ —— 跑前/跑后指纹不一致。\n"
        "    跑前：%s\n    跑后：%s" % (before_fp, after_fp),
    )

    rlines = []
    if os.path.isfile(RESULT):
        rlines = read(RESULT).splitlines()
    check(bool(rlines), "headless 探针未产出结果文件 —— 引擎可能报 SCRIPT ERROR")

    if rlines:
        check(
            not any(ln.strip() == "SAVE_LOAD_GUARD_FAIL" for ln in rlines),
            "headless 探针判定 FAIL：\n    " + "\n    ".join(
                ln.strip() for ln in rlines if ln.strip().startswith("[")),
        )
        for tag in ("A_INGAME_BLOCKED", "B_CANCEL_NOLOAD", "C_CONFIRM_LOADS",
                    "D_MENU_DIRECT", "E_COPY_WARNINGS", "F_SNAPSHOT_SOURCE",
                    "G_NO_DOUBLE_MODAL", "H_CLOSE_NOLOAD", "I_EMPTY_NOGUARD"):
            val = ""
            for ln in rlines:
                if ln.startswith(tag + "="):
                    val = ln.split("=", 1)[1].strip()
            check(val == "true", "headless 判定 %s 未通过（实际=%r）" % (tag, val))
        for ln in rlines:
            if ln.startswith("C_DETAIL") or ln.startswith("RESTORE"):
                print("    [取证] " + ln.strip())

    check(len(raw) > 6000,
          "锚定层失效：探针读到的源码长度异常小，可能未真正锚定 save_menu.gd")

    # ================= K1–K7 独立锚定上游源码 =================
    osp = func_body(code, "_on_slot_pressed")
    check(bool(osp), "K1 前置：找不到 _on_slot_pressed")
    if osp:
        seg = "\n".join(ln.strip() for ln in osp.split("\n") if ln.strip())
        # 【判据形态对齐·第一次踩坑】先按行找守卫行号，不要用 replace 拼串再 split ——
        # 首版把 "if exists and _in_game:" 做了去括号替换，又用原串去 split，
        # 两步互斥导致永远匹配不到（返回 -1），误报「结构次序错」。
        glines = [ln.strip() for ln in osp.split("\n") if ln.strip()]
        gi = next(
            (i for i, ln in enumerate(glines)
             if re.match(r"^if\s+exists\s+and\s+_in_game\s*:$", ln)),
            None,
        )
        check(
            gi is not None,
            "K1 失败：load 分支的守卫不是 `if exists and _in_game:` —— "
            "必须同时满足「槽位有档」与「当前有进行中对局」才拦。"
            "只判 exists 会拦掉主菜单读档；只判 _in_game 会拦掉空槽。",
        )
        if gi is not None:
            # 守卫命中后必须先 return，再直读 —— 弹窗不得形同虚设
            after = glines[gi + 1:]
            show_i = next((i for i, ln in enumerate(after)
                           if "_show_load_confirm" in ln), -1)
            ret_i = next((i for i, ln in enumerate(after) if ln == "return"), -1)
            do_i = next((i for i, ln in enumerate(after)
                         if ln.startswith("_do_load")), -1)
            check(
                show_i == 0 and ret_i == 1 and do_i >= 2,
                "K1/K2 失败：守卫分支结构必须是「弹确认 → return → 直读」，"
                "实际次序：show_load_confirm@%d return@%d _do_load@%d"
                "（期望 0 / 1 / ≥2）。守卫行之后的内容：%r"
                % (show_i, ret_i, do_i, after[:4]),
            )
        # _on_slot_pressed 不得直接调 load_game（读档动作须集中到 _do_load）
        check(
            "load_game" not in seg,
            "K2 失败：_on_slot_pressed 里直接调了 load_game —— "
            "读档动作必须集中在 _do_load，确认/直读两条路径共用，"
            "否则容易只改一处导致确认后仍直读。",
        )
        check(
            "_do_load" in seg,
            "K2 失败：_on_slot_pressed 里找不到 _do_load —— 读档路径断了。",
        )

    # K3：_show_load_confirm 幂等守卫 + 目标档快照
    sl = func_body(code, "_show_load_confirm")
    check(bool(sl), "K3 前置：找不到 _show_load_confirm")
    if sl:
        glines = [ln.strip() for ln in sl.split("\n") if ln.strip()]
        gi = next((i for i, ln in enumerate(glines)
                   if re.match(r"^if\s+_ld_confirm\s*!=\s*null\s*:$", ln)), None)
        check(gi is not None,
              "K3 失败：_show_load_confirm 没有幂等守卫 —— "
              "连点/双击会叠出第二层遮罩，并把待读槽位改成另一个。")
        if gi is not None:
            check(gi + 1 < len(glines) and glines[gi + 1] == "return",
                  "K3 失败：幂等守卫命中后没有 return（守卫行后紧邻 %r）—— "
                  "遮罩叠了、pending 也被覆盖，连点会读错槽位。"
                  % (glines[gi + 1] if gi + 1 < len(glines) else "<无>"))
        for f in ("_ld_target_name", "_ld_target_level", "_ld_target_date"):
            check(re.search(rf"{re.escape(f)}\s*=(?!=)", sl) is not None,
                  "K3 失败：_show_load_confirm 未把 %s 写进快照 —— "
                  "弹窗无法展示「要跳去哪」，确认只剩形式。" % f)
        # 【判据形态对齐·第二次踩坑】不能对整个函数查「不得有读档调用」——
        # 「确认读取」按钮的 pressed 回调里**本来就该**有 _do_load。
        # 真正要禁的是「弹窗构造阶段就读档」（即不点确认也读）。
        # 故只取「构造区段」：从函数头到 ok 按钮创建之前。
        slines = [ln.strip() for ln in sl.split("\n") if ln.strip()]
        ok_i = next((i for i, ln in enumerate(slines)
                     if 'UITheme.button("确认读取"' in ln), None)
        check(
            ok_i is not None,
            "K3 前置：_show_load_confirm 里找不到「确认读取」按钮的创建行",
        )
        if ok_i is not None:
            ctor = "\n".join(slines[:ok_i])
            check(
                "load_game" not in ctor and "_do_load" not in ctor,
                "K3 失败：_show_load_confirm 在**构造弹窗阶段**就调用了读档 —— "
                "弹窗一弹出即读档，防误触直接失效。读档只能出现在确认按钮回调里。",
            )
            # 反向：确认按钮回调里必须有读档调用（拦过头防护）
            tail = "\n".join(slines[ok_i:])
            check(
                "_do_load" in tail,
                "K3 失败：确认按钮回调里没有 _do_load —— "
                "拦截过头，玩家点了确认读不进档。",
            )

    # K4：关闭路径不得读档
    cl = func_body(code, "_close_load_confirm")
    check(bool(cl), "K4 前置：找不到 _close_load_confirm")
    if cl:
        check("load_game" not in cl and "_do_load" not in cl,
              "K4 失败：_close_load_confirm 里调用了读档 —— "
              "关窗/撤销路径读档，防误触直接失效。")

    # K5：三个入口的 in_game 取值
    sp = read(SETTINGS)
    mm = read(MAIN_MENU)
    sp_calls = re.findall(r'SaveMenu\.open_as\("(\w+)",\s*([^)]*)\)', sp)
    check(len(sp_calls) == 2,
          "K5 前置：settings_panel 里应有两处 open_as 调用（save/load），"
          "实际 %d 处" % len(sp_calls))
    for mode, args in sp_calls:
        check("true" in args,
              "K5 失败：settings_panel 的 open_as(\"%s\", ...) 未传 in_game=true —— "
              "游戏内读档不会弹确认，未保存进度仍被无声丢弃。args=%r" % (mode, args))
    mm_calls = re.findall(r'SaveMenu\.open_as\("(\w+)",\s*([^)]*)\)', mm)
    check(len(mm_calls) >= 1,
          "K5 前置：main_menu 里找不到 open_as 调用")
    for mode, args in mm_calls:
        check("false" in args,
              "K5 失败：main_menu 的 open_as(\"%s\", ...) 应传 in_game=false —— "
              "主菜单无进行中对局，读档不丢任何东西，加确认是骚扰。args=%r"
              % (mode, args))
    # 默认值也必须是安全的 false（漏传时不至于误拦）
    m_def = re.search(r"static\s+func\s+open_as\s*\([^)]*in_game[^)]*\)", raw)
    check(m_def is not None, "K5 失败：找不到 open_as 的 in_game 形参")
    if m_def:
        m_fb = re.search(r"in_game\s*:\s*bool\s*=\s*(\w+)", m_def.group(0))
        check(
            m_fb is not None and m_fb.group(1) == "false",
            "K5 失败：in_game 形参默认值必须是 false —— "
            "漏传时（如将来新增入口忘了传）不该误拦玩家读档。实际默认=%r"
            % (m_fb.group(1) if m_fb else "<无默认值>"),
        )

    # K6：文案不得含不成立的兜底承诺
    # 【判据形态对齐·第三次踩坑】必须用 strip_comments 后的 code，
    # 不能查 raw —— 本函数自己在注释里写了「settings_panel 的返回主菜单提示
    # 就这么写的」这句对照说明，注释里出现该短语属正常，判 raw 会误报。
    check("自动存档已保留" not in code,
          "K6 失败：save_menu 的可执行代码里出现「自动存档已保留」—— "
          "自动档只在创角与战斗结算写，读档后玩家回不到那个时间点，"
          "这句兜底承诺不成立，等于骗玩家。")
    # 正面：读档文案必须点明「未保存的进度」与丢失范围
    sl_txt = func_body(code, "_show_load_confirm")
    for kw, why in (
        ("未保存的进度", "玩家不知道要点掉什么"),
        ("跑商", "泛泛一句「进度会丢」不足以让玩家判断该不该读"),
        ("时间推进", "同上"),
    ):
        check(kw in sl_txt,
              "K6 失败：读档确认文案缺少「%s」—— %s" % (kw, why))
    # 反向：settings_panel 那句是**另一个场景**的合法文案（回主菜单后还能继续读自动档），
    # 不许顺手改掉，否则是把正确文案改坏
    sp_code = strip_comments(sp)
    check("自动存档已保留" in sp_code,
          "K6 失败：settings_panel 的「返回主菜单」确认文案被改掉了 —— "
          "那句在该场景是成立的（回主菜单后可再继续读自动档），"
          "本轮不得连带修改。")

    # K7：第六十一轮的覆盖确认不得被回退
    so = func_body(code, "_show_overwrite_confirm")
    check(bool(so), "K7 前置：找不到 _show_overwrite_confirm（第六十一轮成果被删）")
    if so:
        check(re.search(r"if\s+_ovr_confirm\s*!=\s*null\s*:", so) is not None,
              "K7 失败：覆盖确认的幂等守卫被回退 —— "
              "第六十一轮的防误触被破坏。")
    cov = func_body(code, "_close_overwrite_confirm")
    if cov:
        check("save_game" not in cov,
              "K7 失败：_close_overwrite_confirm 里调了 save_game —— "
              "第六十一轮的关闭路径被破坏。")

    # ================= 汇总 =================
    print("=" * 68)
    print("第六十二轮 游戏内读档防误触 · 校验")
    print("=" * 68)
    print("  目标文件：scripts\\main\\save_menu.gd")
    print("          scripts\\ui\\settings_panel.gd")
    print("          scripts\\main\\main_menu.gd")
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
    print("    A 游戏内点已有档 → 弹确认，期间当前进度零改动 ✓")
    print("    B 取消 → 进度保住 + 弹窗关闭 + pending 复位 ✓")
    print("    C 确认 → GameState 真被目标档覆盖（角色名/金币/公元年月）✓")
    print("    D 主菜单进入 → 不弹确认且直达读档（不拦过头）✓")
    print("    E 文案点明丢失范围 + 无虚假兜底承诺 ✓")
    print("    F 目标档摘要为构建时快照，弹窗期间外部改盘不污染 ✓")
    print("    G 重复触发 → 不叠遮罩、不改待读槽位 ✓")
    print("    H 关闭回调 → 只关窗不读档 ✓")
    print("    I 游戏内点空槽 → 不进确认分支 ✓")
    print("  [独立锚定上游源码]")
    print("    K1 load 分支三重守卫 exists and _in_game + 先 return ✓")
    print("    K2 读档动作集中在 _do_load，_on_slot_pressed 不直调 load_game ✓")
    print("    K3 _show_load_confirm 幂等守卫 + 目标档三项快照 ✓")
    print("    K4 关闭路径不含读档调用 ✓")
    print("    K5 settings_panel 传 true / main_menu 传 false / 形参默认 false ✓")
    print("    K6 文案无「自动存档已保留」类不成立兜底 ✓")
    print("    K7 第六十一轮覆盖确认未被回退 ✓")
    print("  [副作用管控]")
    print("    存档目录跑前/跑后指纹一致（探针零残留）✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())