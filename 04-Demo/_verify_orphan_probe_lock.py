#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第六十四轮校验：复活被孤立的回归锁（死锁的探针 = 没上锁）

取证
----
`tests/` 下 30 个探针逐个核对「是否被任何 .py 校验器消费」，10 个 **零消费**：

    art2_probe / art_probe / bigmap_probe / cloud_bench_probe / dialogue_zoom_probe
    / shot_probe                       → 诊断型（0 个判定函数，只打印）
    battle_blackout_probe             → 诊断型（已被 _verify_battle_blackout.py 静态覆盖）
    **encounter_loop_probe (7 判定)**  → 判定型，锁 72107b8 修的真实 bug
    **ui_return_probe  (17 判定)**     → 判定型，锁第五十轮修的真实 bug

后两个是**判定型且锁着已修的真实缺陷**，却没有任何 .py 驱动它们：

| 探针 | 锁住的 bug | 后果 |
|---|---|---|
| encounter_loop_probe | 72107b8「战败撤退当日按 enc_id 拦截原地重生」——`EncounterManager._is_resolved`（encounter_manager.gd:465） | 死了：改回旧写法，没有任何校验会红 |
| ui_return_probe | 第五十轮「点人物弹菜单」+ 轮盘居中 viewport 坐标系错位 | 死了：同上 |

且二者的结果文件（encounter_loop_result.txt / ui_probe_result.txt）
**早于 .gitignore 规则入库**，至今仍被 git 跟踪 —— 忽略规则对已跟踪文件无效，
仓库里躺着两份 2026-09-28 的过期快照，review 时极易误读成「当前状态」。

本轮做两件事：
  1. 修 ui_return_probe 的三处**过时判据**（先证伪：产品无回归）
  2. 补 _verify_orphan_probe_lock.py 把两个探针接回聚合，并 git rm --cached 过期快照

过时判据取证（三处，均为探针没跟上实现，**不是产品回归**）：
  ① 返回按钮文本：探针找 "←"，实现是 `button("返 回", ...)`（ui_theme.gd:418，
     第五十轮 UI 规范改文字）→ A 段恒 null。
  ② 面板关闭时序：`close_panel()` 走 `UITheme.modal_exit()` 的 0.14s Tween，
     `visible=false` 在 `tw.finished` 里（ui_theme.gd:335-347），探针只等 1 帧
     （~0.016s）→ 「面板已关」恒 false。
  ③ 列表行按钮筛选：`_find_first_list_button` 只排除 "←"/"✕"，而 "返 回"
     的 `custom_minimum_size.y ≥ 84` **先于任何武将行被匹配** → 探针按下的是
     返回键，picked 永不发射。实证：DBG first=true text=返 回 / fired=false。

【副作用管控】两探针只动内存态 UI，不碰存档；仍对 user://saves/ 做跑前跑后指纹比对。
"""
import hashlib
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
GODOT = r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe"
SAVES_DIR = os.path.join(
    os.environ.get("APPDATA", ""), "Godot", "app_userdata", "纪元三国", "saves"
)

# 探针 -> (结果文件, 结果哨兵行, 必须零 FAIL 时的判定前缀)
PROBES = {
    "encounter_loop": {
        "gd": "tests/encounter_loop_probe.gd",
        "tscn": "tests/encounter_loop_probe.tscn",
        "result": "encounter_loop_result.txt",
        "sentinel": "ENCOUNTER_LOOP_RESULT=PASS",
        "label": "遭遇撤退循环（锁 72107b8 战败当日原地重生）",
        "min_checks": 5,
    },
    "ui_return": {
        "gd": "tests/ui_return_probe.gd",
        "tscn": "tests/ui_return_probe.tscn",
        "result": "ui_probe_result.txt",
        "sentinel": "UI_PROBE_RESULT=PASS",
        "label": "UI 返回流程 + 轮盘居中（锁第五十轮「点人物弹菜单」）",
        # 【阈值取实测可达上限，不取 grep 到的调用点数】
        # 探针共 15 个 _check 调用点，其中「人物志列表为空（无法触发选人）」
        # 位于 else 分支 —— 只在列表为空（即失败路径）时才走到，正常流程永不到达。
        # 故正常跑满应为 14；写 15 会让校验在正确实现上误报。
        "min_checks": 14,
    },
}

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


def run_probe(tscn_rel, result_rel, timeout=300):
    """跑一个探针场景，返回 (退出码, stdout+stderr)"""
    rp = os.path.join(HERE, result_rel)
    if os.path.isfile(rp):
        os.remove(rp)
    try:
        r = subprocess.run(
            [GODOT, "--headless", "--path", ".", "--scene", "res://" + tscn_rel,
             "--quit-after", "900"],
            cwd=HERE, capture_output=True, text=True, timeout=timeout,
        )
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT"
    except FileNotFoundError:
        return -2, "NO_GODOT"


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


def git_tracked(basename):
    """该结果文件是否仍被 git 跟踪。

    【踩坑记录·R4 反向验证抓出来的真实死判据】
    首版这里传的是仓库根相对路径（"04-Demo/xxx.txt"），但 subprocess 的 cwd=HERE
    已经是 04-Demo —— git 解析 pathspec 时以 cwd 为基准，于是永远得到
    "did not match any file(s) known to git"，C 项恒为「未被跟踪」。
    换言之：即便有人 git add 把过期快照重新入库，这道锁也不会响。
    git ls-files 同样以 cwd 为基准，故这里必须传**纯文件名**。
    """
    r = subprocess.run(["git", "ls-files", "--error-unmatch", basename],
                       cwd=HERE, capture_output=True, text=True)
    return r.returncode == 0


def main():
    # ---------- 前置：文件都在 ----------
    for key, cfg in PROBES.items():
        for rel in (cfg["gd"], cfg["tscn"]):
            if not os.path.isfile(os.path.join(HERE, rel)):
                print("[FAIL] 找不到 %s" % rel)
                return 1

    before_fp = saves_fingerprint()

    # ---------- A. 两个孤立探针必须真跑且全绿 ----------
    for key, cfg in PROBES.items():
        code, out = run_probe(cfg["tscn"], cfg["result"])
        check(code not in (-1, -2),
              "%s 探针无法运行（%s）—— 死探针等于没上锁" % (key, out[:120]))
        check("SCRIPT ERROR" not in out,
              "%s 探针运行期报 SCRIPT ERROR：\n    %s"
              % (key, "\n    ".join(
                  ln for ln in out.split("\n") if "SCRIPT ERROR" in ln)[:800]))

        rp = os.path.join(HERE, cfg["result"])
        check(os.path.isfile(rp),
              "%s 探针未产出结果文件 %s" % (key, cfg["result"]))
        if not os.path.isfile(rp):
            continue
        body = read(rp)
        check(cfg["sentinel"] in body,
              "%s 探针判定未 PASS（期望哨兵 %r）—— 回归锁已红：\n    %s"
              % (key, cfg["sentinel"],
                 "\n    ".join(ln for ln in body.split("\n")
                            if "[FAIL]" in ln)[:900]))
        bad = [ln.strip() for ln in body.split("\n") if "[FAIL]" in ln]
        check(not bad, "%s 探针存在 FAIL 判定：\n    %s" % (key, "\n    ".join(bad)))

        n_ok = len(re.findall(r"\[OK\]", body))
        check(n_ok >= cfg["min_checks"],
              "%s 探针判定项数异常（期望 ≥%d，实际 %d）—— 覆盖面被裁剪，"
              "回归锁范围缩小" % (key, cfg["min_checks"], n_ok))
        print("    [%s] %s：%d 项判定全绿" % (key, cfg["label"], n_ok))

    after_fp = saves_fingerprint()
    check(before_fp == after_fp,
          "探针污染了玩家存档目录 —— 跑前/跑后指纹不一致。\n"
          "    跑前：%s\n    跑后：%s" % (before_fp, after_fp))

    # ---------- B. 过时判据不得回退（钉死本轮修的三处）----------
    ur = strip_comments(read(os.path.join(HERE, "tests", "ui_return_probe.gd")))

    # B1 返回按钮判据必须同时接受 "返 回"（现实现）与 "←"（防将来回退）
    check('"返 回"' in ur and '"←"' in ur,
          "B1 失败：返回按钮判据必须同时接受「返 回」与「←」—— "
          "第五十轮后实现是 button(\"返 回\", ...)，只认 \"←\" 会让 A 段恒 FAIL。")

    # B2 面板关闭必须等补间播完，不能只等一帧
    check("_await_modal_exit" in ur,
          "B2 失败：探针缺少 _await_modal_exit —— close_panel 走 modal_exit 的 "
          "0.14s Tween，visible 在 tw.finished 才置 false，只等 1 帧会假 FAIL。")
    n_await = ur.count("await _await_modal_exit()")
    check(n_await >= 2,
          "B2b 失败：只有 %d 处等补间（A 段返回、C 段关闭各需一处）—— "
          "少一处就有一项恒假 FAIL。" % n_await)

    # B3 列表行筛选必须排除标题行控件
    check(re.search(r'if\s+t\s*==\s*"返 回"', ur) is not None,
          "B3 失败：_find_first_list_button 未排除「返 回」—— 它的高度 ≥84 会"
          "先于任何武将行被匹配，探针按下返回键导致 picked 永不发射、详情页不打开。")

    # ---------- C. 过期结果快照不得再被 git 跟踪 ----------
    # .gitignore 规则对「已跟踪文件」无效：文件入库在先、规则加在后，规则形同虚设，
    # 仓库里会长期躺着过期快照，review 时极易误读成当前状态。
    for key, cfg in PROBES.items():
        fname = cfg["result"]
        check(not git_tracked(fname),
              "C 失败：%s 仍被 git 跟踪 —— .gitignore 规则对已跟踪文件无效，"
              "需 git rm --cached 让规则生效（该文件是探针每次运行重写的产物，"
              "不应入库）。" % fname)

    # ---------- D. 孤儿探针普查：判定型孤儿必须为 0 ----------
    # 诊断型（无判定函数）允许存在 —— 它们是人工排查工具，不承担回归锁职责。
    # 判定型孤儿 = 有 PASS/FAIL 判定却无人消费 = 死锁，必须为 0。
    tests_dir = os.path.join(HERE, "tests")
    py_text = ""
    for f in os.listdir(HERE):
        if f.endswith(".py"):
            try:
                py_text += read(os.path.join(HERE, f))
            except Exception:
                pass
    orphans_assertive = []
    for f in sorted(os.listdir(tests_dir)):
        if not f.endswith("_probe.gd"):
            continue
        base = f[:-3]
        src = read(os.path.join(tests_dir, f))
        has_assert = bool(re.search(r"func _check\(|_fails\s*\+=\s*1", src))
        consumed = base in py_text
        if has_assert and not consumed:
            orphans_assertive.append(base)
    check(not orphans_assertive,
          "D 失败：仍有判定型孤儿探针（%s）—— 它们的 PASS/FAIL 无人消费，"
          "等于给对应缺陷上了把不会响的锁。诊断型（无判定函数）不在此列。"
          % ", ".join(orphans_assertive))

    print("\n" + "=" * 64)
    if FAILS:
        print("【FAIL】共 %d 项未通过（判定总数 %d）：" % (len(FAILS), CNT[0]))
        for m in FAILS:
            print("  ✗ " + m)
        print("=" * 64)
        return 1
    print("【OK】共 %d 项判定全部通过 —— 2 个死回归锁已复活并接回聚合"
          % CNT[0])
    print("=" * 64)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
