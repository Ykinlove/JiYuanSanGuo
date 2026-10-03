#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第六十八轮第三层校验：地形高度场 —— 让角色真正「行经走于每个地质上面」

背景
----
用户原话：「让角色真正的行经走于每个地质上面，包括山啊、土地什么的，
而不是只在贴图上面走来走去」。

取证结论
--------
`terrain_painter.gd` **内部早已有完整高程模型**（西高东低三级阶梯 +
三层噪声 + 城池周边压平），但它只用来给底图**上色** —— 颜色信息随
`_draw` 结束即丢失。后果：角色走到西部高山与东部平原，绘制高度**完全一样**，
走位与地形的纵深关系不存在 → 观感就是「在一张平铺贴图上滑动」。
y_sort 只解决了「谁盖住谁」，没有解决「谁浮得高」。

本轮改了什么
------------
1. 新增 `scripts/world/terrain_height.gd`（TerrainHeight 静态类）：
   把 terrain_painter 里的高程公式**原样抽成可查询的纯函数**，
   并暴露 `elevation_at / lift_at / apply_to / band_name`。
2. `terrain_painter.sample_height()` 对外出口（海拔真源唯一，不另立副本）。
3. `world_map._setup_height_field()` + `_update_height_field()`：
   玩家、世界 NPC 每帧跟随；城池/遭遇点生成时一次性抬升。

三个关键设计决策（都是踩过坑才定下来的）
----------------------------------------
① **只抬「可视子节点」，绝不改实体的 position**。
   实体的 `position` 被大量逻辑直接读：NPC 距离判定（`distance_to`）、
   交互半径、遭遇点避让、存档坐标。把高程写进实体 position 会让
   「站在山上的 NPC 被算成离玩家 100 像素远」，**所有距离判定全错**。
② **相对基准 y 计算，不是相对当前 y**。
   写成 `node.position.y -= lift` 会逐帧累加，走 100 步飞出天际 ——
   而**第一帧看起来完全正常**。本轮探针 H7 实测抓到该缺陷：
   连调 10 次位移达 -450.234px（单次只该 -45.023）。
③ **有变化阈值（1px）才写坐标**：多数帧高程变化 < 1px，每帧写纯属浪费。

本轮在判据上踩的坑（已写入探针注释）
------------------------------------
- **静态类上不能调实例方法**：写 `TerrainHeight.has_method(...)` 抛
  `Cannot call non-static function ... Make an instance instead`，
  4 个 Parse Error 一起冒出来像产品代码炸了 —— 实为判据自身 bug。
  正解：用「真调一次静态函数」做活体验证。
- **负号搞反的漂移判据**：`apply_to` 向上抬（位移为负），
  写成 `drift = |位移 - lift|` 会把正确的 -45 判成漂移 90。
  正解：`drift = |位移 + lift|`。

本轮在探针上守住的纪律
----------------------
- 产出量闸门 EXPECT_CHECKS=11：探针崩溃必须表现为红灯而非绿灯。
- **高度场最危险的失效形态是「全返回 0」** —— 函数照常被调用、
  只是每人抬 0 像素，画面与改动前一模一样，**看起来"没问题"**。
  故判据必须证明「高程**真的随位置变化**」（H1/H2），而不是「函数被调到了」。

本校验三层
----------
【L1 headless 真跑】tests/terrain_height_probe.gd（12 项）
    H0 API 面 + H1 西部高于东部 + H2 连续性 + H3 区间 + H4 单调/反号
    + H5 确定性 + H6 城池压平 + H7 无累加漂移 + H8 分档单调 + Z1 闸门
【L2 大地图实景接线】同一脚本内加载真实 world_map.tscn，
    断言玩家 Visual / NPC Art 确实被抬升、且抬升量随位置而变
【L3 独立源码锚定】本文件
    T1~T8：高度场公式与 terrain_painter 的**同源性**（参数逐项对齐）
    M1~M5：world_map 接线（阈值节流、可视节点、基准 y、单一真源）
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GODOT = r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe"

PROBE_GD = os.path.join(HERE, "tests", "terrain_height_probe.gd")
PROBE_TSCN = os.path.join(HERE, "tests", "terrain_height_probe.tscn")
PROBE_RESULT = os.path.join(HERE, "terrain_height_result.txt")

TH = os.path.join(HERE, "scripts", "world", "terrain_height.gd")
TP = os.path.join(HERE, "scripts", "world", "terrain_painter.gd")
WMAP = os.path.join(HERE, "scripts", "world", "world_map.gd")
NPCM = os.path.join(HERE, "scripts", "world", "npc_manager.gd")

FAILS = []
CNT = [0]


def check(cond, msg):
    CNT[0] += 1
    if not cond:
        FAILS.append(msg)
    return bool(cond)


def read(p):
    with open(p, "r", encoding="utf-8", errors="replace") as f:
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

def kill_stale_godot():
    """清掉残留 Godot 进程：持有 .godot/ 与存档写锁，会让后续真跑莫名失败。"""
    for exe in ("Godot_v4.7.2-stable_win64_console.exe",
                "Godot_v4.7.2-stable_win64.exe"):
        try:
            # 【踩坑】taskkill 输出是 GBK；text=True 按 utf-8 解码会抛
            # UnicodeDecodeError，且异常发生在 subprocess 读取线程里 → 整校验崩掉。
            subprocess.run(["taskkill", "/F", "/IM", exe], capture_output=True,
                           timeout=30, encoding="gbk", errors="replace")
        except Exception:
            pass


def run_probe(tscn, timeout=420, headless=True):
    args = [GODOT]
    if headless:
        args.append("--headless")
    args += ["--path", ".", "--scene", "res://" + tscn.replace("\\", "/"),
             "--quit-after", "3000"]
    try:
        r = subprocess.run(args, cwd=HERE, capture_output=True, text=True,
                           timeout=timeout, encoding="utf-8", errors="replace")
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT"
    except FileNotFoundError:
        return -2, "NO_GODOT"


def parse_result(path):
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return [ln.rstrip("\n") for ln in f]


def stale(path):
    """把旧结果改名而非删除：避免触发批量删除防护钩子。"""
    if os.path.isfile(path):
        try:
            os.replace(path, path + ".stale")
        except OSError:
            pass


print("=" * 70)
print("地形高度场校验（第六十八轮·第 5 项第三层）")
print("=" * 70)

# ============================== L1 headless 真跑 ==============================
print("[L1] headless 真跑 tests/terrain_height_probe.gd ...")
kill_stale_godot()
stale(PROBE_RESULT)
code, out = run_probe("tests/terrain_height_probe.tscn")
lines = parse_result(PROBE_RESULT)
check(lines is not None, "L1 探针未产出结果文件（崩溃或未启动）")
if lines:
    check(any("TERRAIN_HEIGHT_RESULT=PASS" in ln for ln in lines),
          "L1 哨兵未报 PASS：" + " / ".join(
              ln for ln in lines if ln.startswith("[FAIL]"))[:400])
    check(any("TERRAIN_HEIGHT_FAILS=0" in ln for ln in lines), "L1 存在 FAIL 项")
    n = sum(1 for ln in lines if ln.startswith("[OK]") or ln.startswith("[FAIL]"))
    check(n >= 11, "L1 判定产出量不足（探针中途崩溃）：实到 " + str(n) + " 项")
    check("SCRIPT ERROR" not in out, "L1 引擎日志出现 SCRIPT ERROR")
    for ln in lines:
        if ln.startswith("[FAIL]"):
            print("    FAIL " + ln)
else:
    print("    （无结果文件，引擎输出末尾：")
    print("    " + out[-800:].replace("\n", "\n    "))
    print("    ）")

# ============================== L3 独立源码锚定 ==============================
print("[L3] 独立源码锚定 ...")
if not os.path.isfile(TH):
    check(False, "L3 读不到 terrain_height.gd")
else:
    th_raw = read(TH)
    th = strip_comments(th_raw)
    tp = strip_comments(read(TP)) if os.path.isfile(TP) else ""
    wmap = strip_comments(read(WMAP)) if os.path.isfile(WMAP) else ""

    # --- T1 静态类可寻址 ---
    # 【踩坑·判据自身 bug·本轮反向验证抓到】原先写的是子串判断
    #     "class_name TerrainHeight" in th_raw
    # 它在把类名改成 `class_name TerrainHeightXXX` 后**依然为真** ——
    # 因为是子串匹配！反向验证 X1 因此报了假绿（exit=0）。
    # 正解：要求 `TerrainHeight` 后面**紧跟行尾**（不含其它标识符字符）。
    check(re.search(r"^class_name\s+TerrainHeight\s*$", th_raw, re.M) is not None,
          "T1 缺 class_name TerrainHeight（或类名被加了后缀）")

    # --- T2~T5 **同源性**：高度场参数必须与 terrain_painter 逐项对齐 ---
    # 【本轮最重要的一条判据】这两处一旦漂移，角色站位就会与底图山势对不上：
    # 「画上是山，角色却按平原高度站」。而这种不一致**运行时完全不报错**。
    def const_num(src, name):
        """读取 `const NAME := <值>` 的数值。

        【踩坑·本轮踩到】值可能是**表达式**（`1.0 / 3000.0`）而非纯字面量，
        早先的正则只匹配到 "1.0"（数值部分），
        于是把 `1.0 / 3000.0` 读成 1.0 —— 判据数值全错却仍可能"通过"。
        正解：抓到整行右值后**求值**，表达式与纯数字都能处理。
        """
        m = re.search(rf"const\s+{re.escape(name)}\s*:=\s*([^\n#]+)", src)
        if not m:
            return None
        expr = m.group(1).strip()
        try:
            return float(eval(expr, {"__builtins__": {}}, {}))
        except Exception:
            return None

    # 从 terrain_painter 的高程段抠出实际使用的字面量
    geo_body = func_body(tp, "_make_geo_image_for_rect")
    check(geo_body != "", "T2a 取不到 terrain_painter._make_geo_image_for_rect 函数体")

    pairs = [
        ("大尺度噪声权重", "ELEV_NOISE_MAIN", "0.4"),
        ("中尺度噪声权重", "ELEV_NOISE_MID", "0.18"),
        ("西部隆起幅度", "ELEV_WEST_COEFF", "0.8"),
        ("城池压平目标", "ELEV_CITY_FLAT", "0.28"),
    ]
    for label, const_name, expect in pairs:
        v = const_num(th, const_name)
        check(v is not None and abs(v - float(expect)) < 1e-6,
              "T2 %s：terrain_height.%s=%s，应与 terrain_painter 同为 %s"
              % (label, const_name, v, expect))

    # 噪声种子/频率：terrain_painter 里是 n_elev.seed = 2026 这类赋值语句。
    # 【踩坑·判据自身 bug】首版这里拿「种子常量名」去比频率字面量
    # （拿 NOISE_ELEV_SEED 去找 "1.0 / 3000.0"）—— 名字对不上，报了 3 条假红。
    # 正解：种子比 *SEED、频率比 *FREQ，各自对应。
    seed_pairs = [
        ("NOISE_ELEV_SEED", "NOISE_ELEV_FREQ", "2026", "1.0 / 3000.0"),
        ("NOISE_MID_SEED", "NOISE_MID_FREQ", "7788", "1.0 / 1100.0"),
        ("NOISE_HUMID_SEED", "NOISE_HUMID_FREQ", "5566", "1.0 / 2200.0"),
    ]
    for sname, fname, seed, freq in seed_pairs:
        v = const_num(th, sname)
        check(v is not None and int(v) == int(seed),
              "T3 %s=%s，应与 terrain_painter 同为 %s" % (sname, v, seed))
        check(re.search(rf"const\s+{fname}\s*:=\s*{re.escape(freq)}\s*$",
                        th, re.M) is not None,
              "T3b %s 应与 terrain_painter 同为 %s" % (fname, freq))

    # 直接比对 terrain_painter 源码里的种子/频率赋值，证明同源。
    # 【踩坑·判据自身 bug·本轮反向验证 R3 抓到假绿】
    # 原先只验证「painter 里存在 `.seed = 2026` 这样的赋值」，
    # 但**从不核对 painter 侧的实际频率值**。于是把 painter 的
    # `n_elev.frequency` 从 1.0/3000.0 改成 1.0/3000.5 时，判据全绿 ——
    # 而这正是「上游改了底图、下游高度场没跟」的真实漂移方向，
    # 后果是「画上是山、角色按另一套山势的高度绘制」。
    # 正解：**双向**核对 —— 两侧频率表达式必须**逐字相同**。
    if tp:
        for seed in ("2026", "7788", "5566"):
            check(re.search(r"\.seed\s*=\s*" + seed, tp) is not None,
                  "T4 terrain_painter 中已无 seed=" + seed + "（同源锚点漂移）")

        freq_map = [
            ("n_elev", "NOISE_ELEV_FREQ"),
            ("n_mid", "NOISE_MID_FREQ"),
            ("n_humid", "NOISE_HUMID_FREQ"),
        ]
        for pname, cname in freq_map:
            pm = re.search(rf"{pname}\.frequency\s*=\s*([^\n#]+)", tp)
            th_freq = const_num(th, cname)
            # painter 侧是表达式（"1.0 / 3000.0"），求值后与 height 常量比对
            painter_val = None
            if pm:
                try:
                    painter_val = eval(pm.group(1).strip(), {"__builtins__": {}}, {})
                except Exception:
                    painter_val = None
            check(painter_val is not None and th_freq is not None
                  and abs(painter_val - th_freq) < 1e-9,
                  "T4b 同源性：%s.frequency(painter)=%s 与 %s(height)=%s 必须相等"
                  % (pname, pm.group(1).strip() if pm else "N/A", cname, th_freq))

    # --- T5 高度场公式的结构：西高东低 + clamp ---
    base_body = func_body(th, "base_elevation")
    check(base_body != "", "T5a 取不到 base_elevation 函数体")
    check("west_factor * west_factor" in base_body,
          "T5b base_elevation 缺少 west_factor^2（西高东低阶梯）")
    check("clampf" in base_body, "T5c base_elevation 未 clamp 到 [0,1]")

    elev_body = func_body(th, "elevation_at")
    check(elev_body != "", "T5d 取不到 elevation_at 函数体")
    check("ELEV_CITY_FLAT" in elev_body,
          "T5e elevation_at 未做城池压平（角色站位会与底图城周平原不符）")

    # --- T6 apply_to 必须相对基准 y（累加漂移回归锁）---
    apply_body = func_body(th, "apply_to")
    check(apply_body != "", "T6a 取不到 apply_to 函数体")
    check('has_meta("base_y")' in apply_body,
          "T6b apply_to 未用 has_meta 守卫基准 y（会逐次累加，走几步飞出天际）")
    check("node.position.y = float(node.get_meta(\"base_y\"))" in apply_body
          or 'get_meta("base_y")' in apply_body,
          "T6c apply_to 未基于 base_y 计算 y")
    # 反写：不得存在「**无条件**每次重设基准 y」的写法。
    # 【踩坑·判据自身 bug·本轮踩到】首版正则是
    #     set_meta("base_y", position.y) \n \s* node.position.y
    # 它在**正确的实现上也会命中**：因为正确写法就是
    #     if not node.has_meta("base_y"):          ← 守卫
    #         node.set_meta("base_y", ...)          ← 只在守卫内首次设置
    #     node.position.y = ...get_meta("base_y")...
    # 即 set_meta 与后续赋值**本来就连着**，正则无法区分
    # 「无条件重设（错）」与「守卫内首次设置（对）」→ 报假红。
    # 正解：结构化判定 —— 取 set_meta 的**行**与**列**，
    # 要求它所在的行缩进严格深于 `if not ...has_meta` 那行（即确在守卫体内）。
    m_set = re.search(r'^([ \t]*)node\.set_meta\("base_y",', th, re.M)
    m_guard = re.search(r'^([ \t]*)if not node\.has_meta\("base_y"\):', th, re.M)
    guarded_ok = False
    if m_set and m_guard:
        guarded_ok = len(m_set.group(1)) > len(m_guard.group(1))
    elif m_set and not m_guard:
        guarded_ok = False      # 无守卫 = 正是要抓的累加漂移写法
    check(guarded_ok,
          "T6d set_meta(base_y) 必须位于 `if not has_meta` 守卫体内"
          "（无守卫 = 每次重设基准 = 逐次累加，走几步飞出天际）")

    # --- M1~M5 world_map 接线 ---
    if wmap:
        setup_body = func_body(wmap, "_setup_height_field")
        upd_body = func_body(wmap, "_update_height_field")
        check(setup_body != "", "M1a 取不到 _setup_height_field 函数体")
        check(upd_body != "", "M1b 取不到 _update_height_field 函数体")

        # M2 单一真源：世界尺寸必须向 TerrainPainter 取，不在本文件存副本
        check("_terrain.get_world_size()" in setup_body,
              "M2 世界尺寸未向 TerrainPainter 取（副本会与 terrain.json 漂移）")

        # M3 可视节点：只抬 Visual/Art，绝不改实体 position
        check('get_node_or_null(NodePath("Visual"))' in upd_body,
              "M3 玩家未按 Visual 子节点抬升")
        check('get_node_or_null(NodePath("Art"))' in upd_body,
              "M3b 世界 NPC 未按 Art 子节点抬升")
        check("_player.position.y =" not in upd_body,
              "M3c 高度场改了玩家实体 position（会污染距离判定与存档坐标）")

        # M4 变化阈值节流
        # 【踩坑·判据自身 bug】首版找字面量 "HEIGHT_LIFT_EPSILON >="，
        # 而真实写法是 `absf(lift - prev) >= HEIGHT_LIFT_EPSILON`
        # （阈值在右、比较是 absf(...)）→ 报假红。
        # 正解：只断言「用到了该常量且做了一次比较」，不锁死书写形式。
        check("HEIGHT_LIFT_EPSILON :=" in wmap,
              "M4a 未定义变化阈值常量 HEIGHT_LIFT_EPSILON")
        check(re.search(r"HEIGHT_LIFT_EPSILON\s*\)?\s*(?:and|or)?[^=]*>=",
                        upd_body) is not None
            or re.search(r">=\s*HEIGHT_LIFT_EPSILON", upd_body) is not None,
              "M4b 高度更新未用变化阈值做节流（每帧写坐标属无谓开销）")

        # M5 必须每帧被调用
        proc_body = func_body(wmap, "_process")
        check("_update_height_field()" in proc_body,
              "M5 _process 未调用 _update_height_field（角色不会随地形浮起）")

    # --- N1 NPCManager 必须提供公开访问器 ---
    if os.path.isfile(NPCM):
        npcm = strip_comments(read(NPCM))
        # 【同 P1】须用正则锁 `(`，子串匹配会被 `get_npc_nodes_XXX` 骗过
        check(re.search(r"^func\s+get_npc_nodes\s*\(", npcm, re.M) is not None,
              "N1 npc_manager 未暴露 get_npc_nodes()（world_map 会跨类访问私有成员）")

    # --- P1 TerrainPainter 必须是对外出口 ---
    # 【踩坑·判据自身 bug·本轮反向验证 R12 抓到假绿】
    # 原先写 `"func sample_height" in tp`，把函数改名成
    # `sample_height_XXX` 后**依然为真**（子串匹配）。
    # 正则要求 `sample_height` 后面紧跟 `(`，才算真有这个函数。
    if tp:
        check(re.search(r"^func\s+sample_height\s*\(", tp, re.M) is not None,
              "P1 terrain_painter 未暴露 sample_height()（海拔真源必须唯一出口）")
        check(re.search(r"^func\s+get_world_size\s*\(", tp, re.M) is not None,
              "P1b terrain_painter 未暴露 get_world_size()")

# ============================== 汇总 ==============================
print("-" * 70)
print("检查项：%d    失败：%d" % (CNT[0], len(FAILS)))
if FAILS:
    print("FAIL 列表：")
    for m in FAILS:
        print("  - " + m)
    print("=" * 70)
    print("结果：FAIL（%d 项）" % len(FAILS))
    sys.exit(1)
print("=" * 70)
print("结果：ALL PASS（%d 项）" % CNT[0])
sys.exit(0)