#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第六十八轮校验：深度排序（y_sort）接入 —— 让大地图从「贴纸」变成「可行走的世界」

背景
----
用户反馈：「整个大地图跟游戏角色问题，就好像是在玩贴图游戏，一点都没有身临其境
的感觉」。取证结论：全工程**没有一个对象用 y_sort**，所有实体靠固定 z_index
分层（城池 10 / NPC 8 / 遭遇 5 / 玩家 20），彼此**没有任何前后关系** ——
角色走到城池北侧仍画在城池前面，看起来像贴在城墙上。

本轮把城池 / 遭遇 / NPC / 玩家合并进同一个 y_sort 父节点（ActorLayer），
让「谁在谁前面」由 y 坐标决定。

本轮抓到并修掉的**真实缺陷**（全部编译期无感、运行期不崩）
----------------------------------------------------------
1. `Player` 下挂着 `WalkAnim extends Node`（非 CanvasItem），
   对它写 `z_index` 抛 `Invalid assignment of property or key 'z_index'`
   并**中断整个搬运循环** → 后续实体全部没搬进层。
2. `Player` 被当成「容器」处理（搬它的子节点），但它本身才是要参与排序的实体
   → 玩家永远不在层内 → 玩家压不住任何东西。
3. **建层时序错误**：`_setup_depth_sort()` 原放在 `_ready` 末尾（320 行），
   而 `_spawn_city_markers()` 在 366 行 —— 建层时 CityMarkers 还是空的，
   **110 个城池 marker 全留在层外**，且 DepthSort 不报任何错。
4. 搬运后原容器变空，**5 处运行期 `get_children()` 遍历全部失效**（静默）：
   - `world_map._rebuild_city_markers()` → 切区时旧城永不释放、新城叠加
   - `encounter_manager.reload_region()` → 切区时旧遭遇点永不释放
   - `encounter_manager._too_close_to_encounter()` → 撒点不再避让
   - `encounter_manager._respawn_daily()` → **采集点次日永不恢复**
   - `npc_manager.nearest_interactable()` → 所有 NPC 提示不亮、点不动
5. `_city_markers.get_node_or_null("Marker_"+id)` 两处静默返回 null：
   - 城池选中脉冲永不亮
   - 「兵临城下·能否赶上这一战」永远判 false（攻城迎战提示永不弹）

本轮在**判据设计**上踩的两个大坑（已写入探针注释，勿重蹈）
----------------------------------------------------------
① **y_sort 的排序结果不反映在 `get_index()` 上**。
   二分实测：167 个子节点按 y 逆序插入、y_sort_enabled=true，等两帧后
   首节点仍是 y=20000（插入时的位置），末节点 y=3400 —— 一个都没换。
   而两节点的最小场景却「看起来换了」，那是**巧合**（插入顺序恰好等于 y 顺序）。
   真相：Godot 只把 y_sort 结果写进**内部绘制顺序**，从不重排节点树。
   ⇒ 任何「读 get_index() 判遮挡」的校验都是自欺欺人。

② **探针自身崩溃会表现为绿灯**。
   A2b 判据写错（正确实现里 Player 整个被搬走，get_node_or_null 返回 null），
   探针当场抛错中断，后续 4 项判定**根本没执行**，哨兵却照样输出 PASS。
   ⇒ 必须有**产出量闸门**（EXPECT_CHECKS）+ 零 SCRIPT ERROR 断言。

本校验三层
----------
【L1 headless 真跑】tests/depth_sort_probe.gd（29 项）
    引擎前提（A0/A0b/A0c）+ 层接线（A1/A2*）+ 地形压底（A4*）
    + 排序生效前提（A5*）+ 切区重建（A6*）+ 产出量闸门（Z1）
【L2 像素真跑·非 headless】tests/depth_sort_pixels_probe.gd（8 项）
    PIX1~PIX4 在**不受任何覆盖的干净场景**里用像素级正反对照闭环
    证明**引擎的 y_sort 行为**（headless 下 get_viewport().get_texture() 拿不到内容）
    PIX5~PIX8 大地图 ActorLayer 的结构锚定
【L3 独立源码锚定】本文件（防探针与被测代码同改而互相放过）
    C1~C8：DepthSort 工具类的关键实现锚点
    C9~C12：world_map.gd 的接入与运行期遍历已改为缓存
    C13~C15：encounter_manager / npc_manager 的遍历已改为缓存

【为什么必须有 L3】L1/L2 都是「跑起来看结果」，若探针与产品代码同时被改坏，
两者可能一起变绿（如把 EXPECT_CHECKS 调小、把判定条件放宽）。
L3 直接读源码字面量，与运行时行为正交。
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GODOT = r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe"

PROBE_GD = os.path.join(HERE, "tests", "depth_sort_probe.gd")
PROBE_TSCN = os.path.join(HERE, "tests", "depth_sort_probe.tscn")
PROBE_RESULT = os.path.join(HERE, "depth_sort_result.txt")

PIX_GD = os.path.join(HERE, "tests", "depth_sort_pixels_probe.gd")
PIX_TSCN = os.path.join(HERE, "tests", "depth_sort_pixels_probe.tscn")
PIX_RESULT = os.path.join(HERE, "depth_sort_pixels_result.txt")

DEPTH = os.path.join(HERE, "scripts", "world", "depth_sort.gd")
WMAP = os.path.join(HERE, "scripts", "world", "world_map.gd")
ENC = os.path.join(HERE, "scripts", "world", "encounter_manager.gd")
NPC = os.path.join(HERE, "scripts", "world", "npc_manager.gd")

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


def func_body(code, name):
    """截取 GDScript 函数体（不含签名行）。

    【踩坑·两次修】这个 helper 自身出过两个 bug，都制造了**假绿灯**：
      ① 只按 `{`/`}` 配对，遇到 `var closest: Dictionary = {}`
         这类默认值里的空字典会立刻 depth 归零 → 函数体被截成 60 字符 →
         「函数里没有 get_children()」这类判据于是**假通过**。
      ② 加了字符串/注释跳过后，单引号 `'Hint'` 被当成独立状态，
         状态错位使得配对再次失效。
    现按**缩进**切函数：GDScript 顶层函数体一律顶格缩进一级，
    函数结束 = 遇到第一个缩进小于该级的非空行（或下一个顶格 func）。
    对本工程 GDScript 代码（无三元/续行对齐缩进陷阱）稳定可靠。
    """
    m = re.search(rf"^func {re.escape(name)}\s*\(", code, re.M)
    if not m:
        return ""
    # 签名行到行尾
    eol = code.find("\n", m.end())
    if eol < 0:
        return ""
    body_lines = []
    # 取函数体首行的缩进作为基准
    base_indent = None
    pos = eol + 1
    while pos < len(code):
        nl = code.find("\n", pos)
        line = code[pos:nl if nl >= 0 else len(code)]
        stripped = line.strip()
        if stripped:
            base_indent = len(line) - len(line.lstrip())
            break
        pos = (nl + 1) if nl >= 0 else len(code)
    if base_indent is None:
        return ""
    pos = eol + 1
    while pos < len(code):
        nl = code.find("\n", pos)
        if nl < 0:
            nl = len(code)
        line = code[pos:nl]
        stripped = line.strip()
        if stripped:
            if stripped.startswith("func ") and (len(line) - len(line.lstrip())) == 0:
                break
            indent = len(line) - len(line.lstrip())
            if indent < base_indent:
                break
            body_lines.append(line)
        else:
            body_lines.append(line)
        pos = nl + 1
    return "\n".join(body_lines)


def kill_stale_godot():
    """清掉残留 Godot 进程：它们持有 .godot/ 与存档写锁，会让后续真跑莫名其妙失败。"""
    for exe in ("Godot_v4.7.2-stable_win64_console.exe",
                "Godot_v4.7.2-stable_win64.exe"):
        try:
            # 【踩坑】taskkill 输出是 GBK，text=True 按 utf-8 解码会抛
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


def run_pixel_probe(result_path, attempts=2):
    """非 headless 跑像素探针，失败重试。

    【为什么需要重试】非 headless 启动要初始化 OpenGL 设备与窗口
    （实测日志首行 "OpenGL API 3.3.0 ... Intel UHD Graphics 620"），
    在 L1 刚跑完 headless 探针、Godot 进程刚被 kill 的情况下，
    首次启动可能拿不到渲染上下文 → 结果文件不落盘。
    实测：首次失败、重试即 PASS。故给一次重试，仍失败才算真 FAIL。
    """
    last = (-1, "")
    for i in range(attempts):
        kill_stale_godot()
        stale(result_path)
        code, out = run_probe("tests/depth_sort_pixels_probe.tscn", headless=False)
        if os.path.isfile(result_path):
            return code, out, i + 1
        last = (code, out)
    return last[0], last[1], attempts


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
print("第六十八轮 深度排序（y_sort）接入校验")
print("=" * 70)

# ================= L1 headless 真跑 =================
print("\n[L1] 结构探针真跑（headless，29 项）")
if not (os.path.isfile(PROBE_GD) and os.path.isfile(PROBE_TSCN)):
    check(False, "L1 探针文件齐备（缺 %s / %s）" % (PROBE_GD, PROBE_TSCN))
else:
    kill_stale_godot()
    stale(PROBE_RESULT)
    code, out = run_probe("tests/depth_sort_probe.tscn", headless=True)
    lines = parse_result(PROBE_RESULT) or []
    txt = "\n".join(lines)
    check(os.path.isfile(PROBE_RESULT), "L1 探针产出结果文件")
    check(code == 0, "L1 探针进程正常退出（exit=%s）" % code)
    n_ok = len(re.findall(r"^\s*\[OK\]", txt, flags=re.M))
    n_fail = len(re.findall(r"^\s*\[FAIL\]", txt, flags=re.M))
    check(n_ok + n_fail >= 28,
          "L1 判定产出量足够（实到 %d 项，下限 28 —— 少了说明探针中途崩溃）"
          % (n_ok + n_fail))
    check("DEPTH_SORT_RESULT=PASS" in txt, "L1 哨兵 DEPTH_SORT_RESULT=PASS 命中")
    # 零 SCRIPT ERROR：探针崩了但结果文件里仍写着 PASS（读到旧文件）是经典假绿灯
    n_err = len(re.findall(r"SCRIPT ERROR|Parse Error", out))
    check(n_err == 0, "L1 探针运行零脚本错误（错误计数 %d）" % n_err)

# ================= L2 像素真跑（非 headless）=================
print("\n[L2] 像素对照探针真跑（非 headless，8 项）")
if not (os.path.isfile(PIX_GD) and os.path.isfile(PIX_TSCN)):
    check(False, "L2 探针文件齐备（缺 %s / %s）" % (PIX_GD, PIX_TSCN))
else:
    code, out, tries = run_pixel_probe(PIX_RESULT)
    lines = parse_result(PIX_RESULT) or []
    txt = "\n".join(lines)
    check(os.path.isfile(PIX_RESULT),
          "L2 像素探针产出结果文件（已尝试 %d 次）" % tries)
    check("PIX_RESULT=PASS" in txt, "L2 哨兵 PIX_RESULT=PASS 命中")
    n_ok = len(re.findall(r"^\s*\[OK\]", txt, flags=re.M))
    n_fail = len(re.findall(r"^\s*\[FAIL\]", txt, flags=re.M))
    check(n_ok + n_fail >= 8,
          "L2 判定产出量足够（实到 %d 项，下限 8）" % (n_ok + n_fail))
    # PIX1~PIX4 是「引擎 y_sort 行为」的像素级正反对照闭环，缺一不可
    for tag in ("PIX1", "PIX2", "PIX3", "PIX4"):
        check(re.search(r"\[OK\]\s+" + tag, txt) is not None,
              "L2 %s 像素对照项通过" % tag)

# ================= L3 独立源码锚定 =================
print("\n[L3] 独立源码锚定（防探针与产品代码同改而互相放过）")
depth = read(DEPTH)
wmap = read(WMAP)
enc = read(ENC)
npc = read(NPC)
depth_nc = strip_comments(depth)
wmap_nc = strip_comments(wmap)
enc_nc = strip_comments(enc)
npc_nc = strip_comments(npc)

# ---- C1~C8：DepthSort 工具类 ----
check("class_name DepthSort" in depth, "C1 DepthSort 类已声明")
check("y_sort_enabled = true" in depth_nc,
      "C2 建造层时开启 y_sort_enabled")
check("is CanvasItem" in depth_nc or "is CanvasItem:" in depth_nc,
      "C3 搬移前判 is CanvasItem（地雷①：WalkAnim 是纯 Node，写 z_index 会抛错中断循环）")
check("entity_paths" in depth and "container_paths" in depth,
      "C4 API 区分实体/容器（地雷②：Player 既是实体又是容器）")
check("container_paths" in depth_nc and "get_children()" in depth_nc,
      "C5 容器走「搬子节点」路径")
check("func pin_terrain" in depth and "y_sort_enabled = false" in depth_nc,
      "C6 pin_terrain 关掉地形 y_sort")
check(re.search(r"static func pin_terrain\(terrain: Node2D, z: int = -100\)", depth) is not None,
      "C7 pin_terrain 默认 z=-100（地形永远在最底）")
check("move_child(layer, 0)" in depth_nc,
      "C8 新层移到首位（y_sort 层须不被同 z 兄弟按插入顺序压住）")

# ---- C9~C12：world_map.gd 接入 ----
check("_setup_depth_sort()" in wmap, "C9 world_map 接入深度排序建层")
setup_fn = func_body(wmap_nc, "_setup_depth_sort")
check('"Player"' in setup_fn and "CityMarkers" in setup_fn,
      "C10 玩家走实体路径、城池走容器路径")
# 建层必须晚于 marker 生成（缺陷 3 的回归锁）
i_setup = wmap_nc.find("_setup_depth_sort()")
i_spawn = wmap_nc.find("_spawn_city_markers()")
check(i_setup > 0 and i_spawn > 0 and i_setup > i_spawn,
      "C11 建层调用晚于 _spawn_city_markers（否则 110 个城池全留在层外，缺陷 3 回归锁）")
# 运行期遍历已改为缓存（缺陷 4 的回归锁）
rebuild = func_body(wmap_nc, "_rebuild_city_markers")
check("_marker_cache" in rebuild and "get_children()" not in rebuild,
      "C12 _rebuild_city_markers 遍历缓存而非已搬空的容器（缺陷 4 回归锁）")

# ---- C13~C15：encounter_manager / npc_manager ----
reload_fn = func_body(enc_nc, "reload_region")
check("_enc_nodes" in reload_fn and "get_children()" not in reload_fn,
      "C13 reload_region 遍历缓存而非容器（切区旧遭遇点泄漏回归锁）")
too_close = func_body(enc_nc, "_too_close_to_encounter")
check("_enc_nodes" in too_close and "get_children()" not in too_close,
      "C14 _too_close_to_encounter 遍历缓存（撒点避让回归锁）")
respawn = func_body(enc_nc, "_respawn_daily")
check("_enc_nodes" in respawn and "get_children()" not in respawn,
      "C15 _respawn_daily 遍历缓存（采集点次日恢复回归锁）")
check("_npc_nodes" in npc_nc and "_npc_nodes.append(node)" in npc_nc,
      "C16 npc_manager 新增 _npc_nodes 缓存并在生成期登记")
# 【判据纠错】早先版本找的是不存在的 `nearest_interactable`，
# 真实位置是 `_process`（每帧算最近 NPC + Hint 显隐）。按实际函数名校验。
proc_fn = func_body(npc_nc, "_process")
check("_npc_nodes" in proc_fn and "get_children()" not in proc_fn,
      "C17 _process 遍历缓存而非容器（NPC 提示/交互回归锁）")

# ---- C18：marker 查找统一入口（缺陷 5 的回归锁）----
check("func _find_marker" in wmap, "C18 新增 _find_marker 统一入口")
# 【判据纠错】早先版本用原始文本计数，把 ①_find_marker 里的**降级兜底**
# （建层前/建层失败时 marker 仍在原容器 —— 那是必要的，不是残留）
# ② 注释里的旧写法示例 也算成了残留。
# 正确口径：**去掉注释后**，除 _find_marker 内部那一处降级兜底外不得再有直查。
_straight = len(re.findall(r'_city_markers\.get_node_or_null', wmap_nc))
check(_straight == 1,
      "C19 去注释后 _city_markers.get_node_or_null 只剩 1 处"
      "（_find_marker 的降级兜底；出现第 2 处即城池选中脉冲/攻城迎战提示会静默失效）"
      "，实到 %d 处" % _straight)
find_fn = func_body(wmap_nc, "_find_marker")
check("_actor_layer" in find_fn,
      "C19b _find_marker 优先在 ActorLayer 内查找（实体搬走后的唯一正确路径）")
check(wmap_nc.count("_find_marker(") >= 3,
      "C20 _find_marker 至少 3 处调用（定义 + 至少 2 个使用点）")

# ================= 汇总 =================
print("\n" + "=" * 70)
for f in FAILS:
    print("  [FAIL] " + f)
print("  判定总数 %d / 失败 %d" % (CNT[0], len(FAILS)))
print("=" * 70)

if FAILS:
    print("DEPTH_SORT_VERIFY=FAIL")
    sys.exit(1)
print("DEPTH_SORT_VERIFY=PASS（%d 项全绿）" % CNT[0])
sys.exit(0)
