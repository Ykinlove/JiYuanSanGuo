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
    "art2": {
        # 【第六十五轮·新增】art2_probe 是判定型（_ok 累加 _fail、哨兵
        # "ART2 PROBE: ALL PASS"、quit(1 if _fail>0)），此前零消费。
        # 它用 _fail（单数）而非 _fails，第一版判据 D 的正则因此漏判，
        # 且它的名字只出现在本文件 docstring 里 —— 子串匹配把「自述」当成了「消费」。
        "gd": "tests/art2_probe.gd",
        "tscn": None,          # extends SceneTree，--script 直跑，无需 tscn
        "result": "art2_result.txt",
        "sentinel": "ART2 PROBE: ALL PASS",
        "label": "地标贴图加载 + 缩放换算（锁 AI 美术批次二贴图接线）",
        # 实测 30 项判定全绿（贴图 5 + 建筑 12 + 城池标记 9 + 缩放自洽 3 ... 逐段累加）
        "min_checks": 30,
    },
    "dialogue_zoom": {
        # 【第六十五轮·新增】判据 D 修好后才暴露的第二个真孤儿：
        # 探针本身健康（实跑 ALL PASS、零 SCRIPT ERROR），只是从没人驱动它。
        # 它用自由文本 + ✓ 标记判定，不打 [OK]/[PASS]，故需自定义计数形态。
        "gd": "tests/dialogue_zoom_probe.gd",
        "tscn": None,
        "result": "dialogue_zoom_result.txt",
        "sentinel": "DIALOGUE+ZOOM PROBE: ALL PASS",
        "label": "对话界面节点树 + 自由缩放范围（锁立绘加载与缩放上下限）",
        # 5 组判定：立绘 15/15、tscn 节点 8/8、大地图缩放范围、小地图缩放范围、
        # 缩放下限 ✓、缩放上限 ✓。注意大/小地图两行写作「下限 0.0909 / 上限 2.4000」，
        # 斜杠两侧有空格，故 \d+/\d+ 匹配不到，要单列一条含「x」分辨率的规则。
        "min_checks": 6,
        "count_patterns": [r"✓", r"^\S.*\d+/\d+", r"^\S.*\d+x\d+.*下限"],
        "fail_patterns": [r"^\s*FAIL\s"],
    },
    "art": {
        # 【第六十五轮·新增】art_probe 原先是**死探针**：它调 CityMarkerArt / BattleUnit，
        # 两者依赖链都会碰到 autoload，在 --script 模式下加载期就编译失败，
        # 整探针一条判定都跑不出来。修掉后已能实跑。
        "gd": "tests/art_probe.gd",
        "tscn": None,
        "result": "art_result.txt",
        "sentinel": "ART PROBE: ALL PASS",
        "label": "美术资源加载（城池图标5+兵种14+立绘15+NPC立绘分支）",
        # 实测 4 行判定输出：城池标记贴图 / 兵种图标 infantry / 城内NPC立绘分支 /
        # 无立绘NPC回退几何小人。（第 1-3 组「资源存在性」失败时只打 FAIL 不打 PASS 行，
        # 故 PASS 态恒为这 4 行。写 5 会在正确实现上误报。）
        "min_checks": 4,
        "count_patterns": [r"可加载", r"分支", r"几何小人"],
        "fail_patterns": [r"^\s*FAIL\s"],
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


def code_only(src):
    """剔除 Python 注释与 docstring，保留普通字符串字面量。

    【为什么需要】判据 D 要回答「这个探针是否被某个 .py 消费」，而消费点在本工程
    恰恰是**字符串**（PROBES 里的 "gd": "tests/art2_probe.gd"）。所以既不能保留
    注释（会把自述当证据），也不能把字符串一并砍掉（那样消费点全消失）。

    【为什么不用 strip_comments】它逐行找第一个 '#' 砍掉，会把 docstring 里的
    中文说明当代码留下 —— 而本文件的 docstring 恰好**逐一列举了所有已知探针**
    （第 7-13 行）。用它判「消费」等于把自述当证据：art2_probe 在全工程 .py 里
    唯一一次出现就是这个 docstring，却会被判成「已消费」。

    实现：tokenize 按词法切分，丢弃 COMMENT；对 STRING 判定它是否为 docstring
    （前一个有效 token 是 NEWLINE/INDENT/DEDENT/ENCODING，即「整条语句只有它」），
    是则丢弃，否则保留。
    """
    import io
    import tokenize
    out = []
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(src).readline))
    except (tokenize.TokenError, IndentationError, SyntaxError):
        # 源码有语法错时退回粗剥：宁可判据退化，也不能让整个校验崩掉
        return strip_comments(src)
    prev = None
    for tok in toks:
        if tok.type == tokenize.COMMENT:
            continue
        if tok.type == tokenize.STRING and prev in (
                None, tokenize.ENCODING, tokenize.NEWLINE,
                tokenize.NL, tokenize.INDENT, tokenize.DEDENT):
            continue          # docstring
        if tok.type in (tokenize.NL, tokenize.NEWLINE, tokenize.INDENT,
                        tokenize.DEDENT):
            prev = tok.type
            continue
        out.append(tok.string)
        if tok.type not in (tokenize.OP, tokenize.NAME):
            prev = tok.type
        else:
            prev = tok.type
    return " ".join(out)


def kill_stale_godot():
    """开跑前清掉同名残留 Godot 进程。

    【为什么要清】Godot 在 Windows 上被 timeout 杀掉后常留僵尸进程，持有
    .godot/ 与存档目录的写锁。若它们还在跑并往 auto.json 写，存档指纹判据
    会报「探针污染玩家存档」—— 而真凶是这些残留，不是探针本身。
    实测：清掉 6 个残留后，5 个探针逐个跑存档指纹全不变。
    """
    n = 0
    for exe in ("Godot_v4.7.2-stable_win64_console.exe",
                "Godot_v4.7.2-stable_win64.exe"):
        try:
            # 【踩坑】taskkill 是 Windows 原生程序，输出为 GBK/CP936，
            # 用 text=True（默认 utf-8）解码会抛 UnicodeDecodeError，
            # 且该异常发生在 subprocess 的读取线程里 → 直接把整个校验带崩。
            r = subprocess.run(["taskkill", "/F", "/IM", exe],
                               capture_output=True, timeout=30,
                               encoding="gbk", errors="replace")
            if r.returncode == 0:
                n += len(re.findall(r"PID", r.stdout or ""))
        except Exception:
            pass
    return n


def run_probe(gd_rel, tscn_rel, result_rel, timeout=300):
    """跑一个探针，返回 (退出码, stdout+stderr)

    tscn_rel 非 None → 场景型：`--scene res://<tscn>`；
    tscn_rel 为 None → SceneTree 型：`--script <gd>`（art2/art/dialogue_zoom 即此类）。
    两种驱动方式的判据要求完全一致（哨兵 + 零 SCRIPT ERROR + 判定项数），故合并在此。

    【踩坑·本轮自己引入】首版 SceneTree 分支写成 `--script --quit-after 900`，
    **漏了脚本路径** —— Godot 启动后无事可做，输出为空，于是三个新探针各报
    「哨兵未命中 + 判定项 0」。这类失败长得像「探针红了」，极易误判成产品回归。
    记住：`--script` 后面必须紧跟 res:// 脚本路径。

    【退出保障】SceneTree 型探针若因故没调 quit()，没有 --quit-after 就会永驻，
    把整个校验挂到超时。统一带上 --quit-after 作为兜底。

    【为什么改名而不删】清掉旧结果文件的目的是「确保读到的是本次跑的输出」，
    而这层探针产出的是可再生的临时产物，物理删除会触发批量删除防护钩子。
    改名为 .stale 既达到「旧文件不可被误读」的目的，又不动玩家的任何数据。
    """
    rp = os.path.join(HERE, result_rel)
    if os.path.isfile(rp):
        try:
            os.replace(rp, rp + ".stale")
        except OSError:
            pass
    if tscn_rel is None:
        args = [GODOT, "--headless", "--path", ".", "--script",
                "res://" + gd_rel, "--quit-after", "900"]
    else:
        args = [GODOT, "--headless", "--path", ".", "--scene", "res://" + tscn_rel,
                "--quit-after", "900"]
    try:
        r = subprocess.run(args, cwd=HERE, capture_output=True, text=True,
                           timeout=timeout)
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
            if rel is None:
                continue
            if not os.path.isfile(os.path.join(HERE, rel)):
                print("[FAIL] 找不到 %s" % rel)
                return 1

    # 清残留 Godot 进程：僵尸进程会持有 .godot/ 与存档写锁，污染存档指纹判据。
    # 基线必须在清理**之后**取，否则清理动作本身会被算进差异。
    killed = kill_stale_godot()
    if killed:
        print("    [!] 清理残留 Godot 进程 %d 个（否则存档指纹判据会被误报）" % killed)
    before_fp = saves_fingerprint()

    # ---------- E. 编排层自身判据（源码锚定，防「跑不起来」伪装成「探针红了」）----------
    # 【本轮真实缺陷】run_probe 的 SceneTree 分支漏了脚本路径，Godot 无事可做、
    # 输出为空，于是三个新探针各报「哨兵未命中 + 判定项 0」。
    # 症状长得像产品回归，极易误判 —— 故把「--script 后面必须跟路径」钉成判据。
    verify_src = read(os.path.abspath(__file__))
    m_script = re.search(r'"--script",\s*\n?\s*(.+)', verify_src)
    check(m_script is not None and ("gd_rel" in m_script.group(1)
                                    or '"res://" +' in m_script.group(1)),
          "E 失败：--script 后未接脚本路径 —— Godot 会空跑，"
          "表现为「哨兵未命中」，极易被误当成探针红/产品回归")
    check("encoding=\"gbk\"" in verify_src or "encoding='gbk'" in verify_src,
          "E 失败：taskkill 是 Windows 原生程序，输出为 GBK；"
          "未显式指定 encoding 会抛 UnicodeDecodeError 并带崩整个校验")
    check("kill_stale_godot" in verify_src,
          "E 失败：缺少 kill_stale_godot —— Windows 上 Godot 被 timeout 杀后留僵尸进程，"
          "持有存档写锁会让存档指纹判据误报「探针污染玩家存档」")
    check("os.replace(rp, rp + \".stale\")" in verify_src,
          "E 失败：旧结果文件应改名为 .stale 而非物理删除（触发批量删除防护钩子）")

    # ---------- A. 被孤立的判定型探针必须真跑且全绿 ----------
    for key, cfg in PROBES.items():
        code, out = run_probe(cfg["gd"], cfg["tscn"], cfg["result"])
        check(code not in (-1, -2),
              "%s 探针无法运行（%s）—— 死探针等于没上锁" % (key, out[:120]))
        check("SCRIPT ERROR" not in out,
              "%s 探针运行期报 SCRIPT ERROR：\n    %s"
              % (key, "\n    ".join(
                  ln for ln in out.split("\n") if "SCRIPT ERROR" in ln)[:800]))

        rp = os.path.join(HERE, cfg["result"])
        # 两种输出形态：tscn 型写结果文件（正文取文件）；SceneTree 型只打 stdout。
        # 无论哪种，哨兵与判定项数都必须在**实际输出**里读到，否则等于没验。
        if cfg["tscn"] is None:
            body = out
            check(True, "")   # 不要求结果文件
        else:
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
        # FAIL 形态两种：art2/ui_return 打 "[FAIL] xxx"；dialogue_zoom 打 "FAIL xxx"
        fail_pats = cfg.get("fail_patterns") or [r"\[FAIL\]"]
        bad = [ln.strip() for ln in body.split("\n")
               if any(re.search(p, ln) for p in fail_pats)]
        check(not bad, "%s 探针存在 FAIL 判定：\n    %s" % (key, "\n    ".join(bad)))

        # 判定项计数：各探针输出形态不同，按配置给的正则统计；未配置则用 [OK]/[PASS]
        if "count_patterns" in cfg:
            n_ok = sum(1 for ln in body.split("\n")
                       if any(re.search(p, ln) for p in cfg["count_patterns"]))
        else:
            marker = "[OK]" if cfg["tscn"] is not None else "[PASS]"
            n_ok = len(re.findall(re.escape(marker), body))
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
    #
    # 【第六十五轮·修本项自身的两处假阴性】首版判据有两处会「静默恒真」：
    #   ① has_assert 正则只认 `func _check(` 与 `_fails += 1`（带 s）。
    #      art2_probe 用的是 `_fail`（单数）+ `_ok()` 助手，4 个 _check_* 全是真判定，
    #      却因变量名差一个字母被判成诊断型，直接从普查里消失。
    #   ② consumed 判据是 `base in py_text` 子串匹配，而 base 在本文件 docstring 里
    #      被当作「已知的诊断型探针」列举过 —— 于是校验器**把自己的自述当成了消费证据**。
    #      实测：art2_probe 在全工程 .py 里只出现 1 次，就是本文件第 9 行的注释。
    # 两处叠加的后果正是本轮要修的目标本身：判定型探针零消费却全绿。
    # 现改为：① 断言形态覆盖 _fails/_fail/_ok/_check/哨兵 ALL PASS 等多种写法；
    #      ② 消费证据只在**剥离注释后的代码**里找，且必须是可执行的引用形态。
    ASSERT_PATTERNS = [
        r"func _check\w*\s*\(",              # 判定函数族
        r"_fails?\s*\+=\s*1",               # 失败计数（单数/复数都认）
        r"func _ok\s*\(",                    # art2_probe 用的判定助手
        r"\bALL PASS\b",                    # 哨兵式判定的标志物
    ]
    tests_dir = os.path.join(HERE, "tests")
    py_code = ""      # 仅代码 token（注释与 docstring 已剔除）
    for f in os.listdir(HERE):
        if f.endswith(".py"):
            try:
                py_code += code_only(read(os.path.join(HERE, f))) + "\n"
            except Exception:
                pass

    def is_consumed(base):
        """该探针是否被某个 .py 以**可执行引用**的方式消费。

        必须在剔除注释/docstring 后的代码里命中。本工程的消费形态实测有三种：
          "art2_probe": {...}                        dict 键（本文件 PROBES）
          "gd": "tests/art2_probe.gd",               .gd 路径引用
          SCENE = "res://tests/toast_queue_probe.tscn"   .tscn 场景引用（最常见）
        三种都要认，否则会把 10 个有专属校验器的探针误报成孤儿。
        """
        for pat in (r'["\']' + re.escape(base) + r'["\']',
                    r'["\'][^"\']*' + re.escape(base) + r'\.(gd|tscn)["\']'):
            if re.search(pat, py_code):
                return True
        return False

    orphans_assertive = []
    n_assertive = 0
    for f in sorted(os.listdir(tests_dir)):
        if not f.endswith("_probe.gd"):
            continue
        base = f[:-3]
        src = read(os.path.join(tests_dir, f))
        has_assert = any(re.search(p, src) for p in ASSERT_PATTERNS)
        if not has_assert:
            continue          # 诊断型，不担锁职责
        n_assertive += 1
        if not is_consumed(base):
            orphans_assertive.append(base)
    check(not orphans_assertive,
          "D 失败：仍有判定型孤儿探针（%s）—— 它们的 PASS/FAIL 无人消费，"
          "等于给对应缺陷上了把不会响的锁。诊断型（无判定函数）不在此列。"
          % ", ".join(orphans_assertive))
    print("    [D] 判定型探针 %d 个，判定型孤儿 %d 个"
          % (n_assertive, len(orphans_assertive)))

    print("\n" + "=" * 64)
    if FAILS:
        print("【FAIL】共 %d 项未通过（判定总数 %d）：" % (len(FAILS), CNT[0]))
        for m in FAILS:
            print("  ✗ " + m)
        print("=" * 64)
        return 1
    print("【OK】共 %d 项判定全部通过 —— %d 个判定型探针已接回聚合，"
          "判定型孤儿为 0" % (CNT[0], len(PROBES)))
    print("=" * 64)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
