#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第六十八轮第二层校验：城内深度排序 —— 让城内也从「贴图」变成「可行走的世界」

背景
----
大地图已在第六十八轮第一层接入 y_sort（见 _verify_depth_sort.py），但城内
**完全没有**：所有东西都挂在 `_interior` 下靠 add_child 顺序决定前后，玩家还被
硬设 `z_index = 20` 压在一切之上。

取证结论（这是本轮改动依据）
--------------------------
1. 城内 `Interior` 的子节点序是 `Ground → 建筑们 → Player → CityNPC_… → Atmos →
   NightVeil`，**零 y_sort**。
2. `_player.z_index = 20` —— 主角从**任何方向**走近建筑都画在屋顶前面，
   视觉上像贴在城墙上而不是走在墙后。这就是用户说的「像贴图游戏」。
3. 城内的拓扑与大地图**完全不同**：
   `CityScene(Control) → WorldView(SubViewportContainer) → SubViewport → Interior`
   相机还挂在 Player **内部**。SubViewport 是独立 Viewport，
   所以大地图那套结论**不能直接照搬**，必须先在本拓扑上真跑一遍（先证伪）。
4. `CityInteriorArt.build` 的贴图锚点在**地基**（`sp.position.y = -h`），
   与 NPC/玩家同一坐标系 → y_sort 直接可用，无需偏移修正。

本轮改了什么
------------
1. `_setup_depth_sort()`：在 `_build_interior()` **最后**（NPC 全部生成之后）
   建 ActorLayer，把建筑（B_ 前缀）/ 玩家（本体）/ 城内 NPC（CityNPC_ 前缀）
   搬入并开 y_sort；地面 `pin_terrain(z=-100)`。
2. 移除 `_player.z_index = 20`（它是「贴图感」的最主要来源）。
3. 氛围层/夜色层/雨雪层改用**显式 z_index**（Atmos 80 / NightVeil 90 /
   Weather 100），并**删除两处依赖树序的 `move_child`**：
   y_sort 接入后实体整体成为排序单元，`_interior.move_child(_atmos,
   _player.get_index())` 里的 `_player.get_index()` 已变成**层内索引**，
   拿去 move_child 会把粒子层塞到完全无关的位置，且不报任何错。
4. `_build_interior()` 清场时把 `_actor_layer` 句柄置空：否则重进城时会与
   新建同名层分裂成 `@ActorLayer@2`，探针按名取层会取到空的那个。

本轮在判据上踩的坑（已写入探针注释）
------------------------------------
**跨类型取节点必须用共同基类**：夜幕层最初写成 `as Node2D`，而它是
`ColorRect`（Control）→ 强转 null → C12 报「夜色层不存在」的**假红**。
当时产品代码完全正确（实测 NightVeil z=90），是判据自己错了。

本轮在探针上守住的纪律
----------------------
- 产出量闸门 EXPECT_CHECKS=22：探针抛错中断时哨兵仍会报 PASS，
  必须断言判定数达标 + 零 SCRIPT ERROR，让崩溃无处藏身。
- **不读 get_index() 判遮挡**：已实测证伪（Godot 只把 y_sort 写进内部绘制
  顺序，从不重排节点树）。遮挡正确性由 L2 像素正反对照闭环证明。
- 建筑数量基准取自**运行中场景**（层内 + 层外合并去重），不硬编码常量副本。

本校验三层
----------
【L1 headless 真跑】tests/city_depth_sort_probe.gd（23 项）
    C0 先证伪引擎行为 + C1~C15 层接线/实体入层/层级/相机存活 + Z1 产出量闸门
【L2 像素真跑·非 headless】tests/city_depth_sort_pixels_probe.gd（8 项）
    PIX1~PIX4 干净场景像素正反对照闭环（证明引擎 y_sort 行为）
    PIX5~PIX8 真实城内场景 ActorLayer 结构锚定
【L3 独立源码锚定】本文件（防探针与被测代码同改而互相放过）
    S1~S6：city_scene.gd 的接入与层级常量；D1~D3：DepthSort 复用正确
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GODOT = r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe"

PROBE_GD = os.path.join(HERE, "tests", "city_depth_sort_probe.gd")
PROBE_TSCN = os.path.join(HERE, "tests", "city_depth_sort_probe.tscn")
PROBE_RESULT = os.path.join(HERE, "city_depth_sort_result.txt")

PIX_GD = os.path.join(HERE, "tests", "city_depth_sort_pixels_probe.gd")
PIX_TSCN = os.path.join(HERE, "tests", "city_depth_sort_pixels_probe.tscn")
PIX_RESULT = os.path.join(HERE, "city_depth_sort_pixels_result.txt")

CS = os.path.join(HERE, "scripts", "city", "city_scene.gd")
WMAP = os.path.join(HERE, "scripts", "world", "world_map.gd")
DEPTH = os.path.join(HERE, "scripts", "world", "depth_sort.gd")

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
    """截取 GDScript 函数体（不含签名）—— 逐行扫描 + 缩进定界。

    【这个 helper 已被本项目坑了四次，全部记录在此，勿再退化】
    ① 只按 `{`/`}` 配对 → 遇 `var x: Dictionary = {}` 立刻 depth 归零，
       函数体被截成 60 字符 → 「函数里没有 xxx」类判据**假通过**。
    ② 加字符串跳过后被单引号 `'Hint'` 搞乱状态 → 配对再次失效。
    ③ 正则只写 `^func NAME` → **`static func` 一个都匹配不到**，
       func_body 全返回 "" → 判据集体假红（实测 13 条）。
    ④ 签名**跨多行**时按「第一个换行」当签名结束 → 截到的"函数体"其实是
       签名的续行（缩进更深）→ 下一行真正函数体缩进更小 → 立即 break →
       函数体被截成一行（实测 4 条假红）。

    现行实现：**先按括号配平吃掉完整签名（可跨行），再按缩进定界取体**。
    这样两种签名形态（单行 / 多行、func / static func）都正确。
    """
    lines = code.split("\n")
    sig_re = re.compile(rf"^(static\s+)?func\s+{re.escape(name)}\s*\(")
    start = -1
    for i, ln in enumerate(lines):
        if sig_re.match(ln):
            start = i
            break
    if start < 0:
        return ""
    # ① 括号配平吃掉完整签名
    depth = 0
    sig_end = start
    in_sig = False
    for i in range(start, len(lines)):
        for ch in lines[i]:
            if ch == "(":
                depth += 1
                in_sig = True
            elif ch == ")":
                depth -= 1
        sig_end = i
        if in_sig and depth <= 0:
            break
    # ② 按缩进定界取函数体
    body = []
    base_indent = None
    for ln in lines[sig_end + 1:]:
        if ln.strip():
            indent = len(ln) - len(ln.lstrip())
            if base_indent is None:
                base_indent = indent
                if indent == 0:
                    return ""
            if indent < base_indent:
                break
            if indent == 0 and re.match(r"^(static\s+)?(func|const|var)\b", ln):
                break
            body.append(ln)
        else:
            body.append(ln)
    return "\n".join(body)


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


def run_pixel_probe(result_path, attempts=2):
    """非 headless 跑像素探针，失败重试。

    【为什么需要重试】非 headless 启动要初始化 OpenGL 设备与窗口；
    紧跟在 headless 探针后（Godot 刚被 kill）首次可能拿不到渲染上下文
    → 结果文件不落盘。实测首次失败、重试即 PASS，故给一次重试。
    """
    last = (-1, "")
    for i in range(attempts):
        kill_stale_godot()
        stale(result_path)
        code, out = run_probe("tests/city_depth_sort_pixels_probe.tscn",
                              headless=False)
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
print("城内深度排序校验（第六十八轮·第 5 项第二层）")
print("=" * 70)

# ============================== L1 headless 真跑 ==============================
print("[L1] headless 真跑 tests/city_depth_sort_probe.gd ...")
kill_stale_godot()
stale(PROBE_RESULT)
code, out = run_probe("tests/city_depth_sort_probe.tscn")
lines = parse_result(PROBE_RESULT)
check(lines is not None, "L1 探针未产出结果文件（崩溃或未启动）")
if lines:
    check(any("CITY_DEPTH_SORT_RESULT=PASS" in ln for ln in lines),
          "L1 哨兵未报 PASS：" + " / ".join(
              ln for ln in lines if ln.startswith("[FAIL]"))[:400])
    check(any("CITY_DEPTH_SORT_FAILS=0" in ln for ln in lines),
          "L1 存在 FAIL 项")
    # 产出量闸门：探针抛错中断时哨兵仍会报 PASS（只跑了 10 项却报成功）。
    oks = 0
    for ln in lines:
        if ln.startswith("[OK]"):
            oks += 1
        if ln.startswith("[FAIL]"):
            oks += 1
    check(oks >= 22, "L1 判定产出量不足（探针中途崩溃）：实到 " + str(oks) + " 项")
    check("SCRIPT ERROR" not in out, "L1 引擎日志出现 SCRIPT ERROR")
    for ln in lines:
        if ln.startswith("[FAIL]"):
            print("    FAIL " + ln)
else:
    print("    （无结果文件，引擎输出末尾：")
    print("    " + out[-800:].replace("\n", "\n    "))
    print("    ）")

# ============================== L2 像素真跑（非 headless）==============================
print("[L2] 非 headless 像素真跑 tests/city_depth_sort_pixels_probe.gd ...")
code2, out2, tries = run_pixel_probe(PIX_RESULT)
lines2 = parse_result(PIX_RESULT)
check(lines2 is not None, "L2 像素探针未产出结果文件（OpenGL 上下文拿不到）")
if lines2:
    check(any("CITY_PIX_RESULT=PASS" in ln for ln in lines2),
          "L2 像素哨兵未报 PASS：" + " / ".join(
              ln for ln in lines2 if ln.startswith("[FAIL]"))[:400])
    for ln in lines2:
        if ln.startswith("[FAIL]"):
            print("    FAIL " + ln)
else:
    print("    （无结果文件，引擎输出末尾：")
    print("    " + out2[-800:].replace("\n", "\n    "))
    print("    ）")

# ============================== L3 独立源码锚定 ==============================
print("[L3] 独立源码锚定 ...")
if not os.path.isfile(CS):
    check(False, "L3 读不到 city_scene.gd")
else:
    cs_raw = read(CS)
    cs = strip_comments(cs_raw)

    # --- S1 建层函数存在且开 y_sort ---
    check("func _setup_depth_sort" in cs_raw,
          "S1 city_scene.gd 缺少 _setup_depth_sort()")

    setup_body = func_body(cs, "_setup_depth_sort")
    check(setup_body != "", "S1b 取不到 _setup_depth_sort 函数体")

    # S2 层必须开 y_sort 且排在首位（不被同 z 兄弟压住）
    check("layer.y_sort_enabled = true" in setup_body,
          "S2 _setup_depth_sort 未开启 y_sort")
    check("move_child(layer, 0)" in setup_body,
          "S2b ActorLayer 未排到首位（会被同 z 兄弟按插入顺序压住）")

    # S3 按名字前缀抓实体（而不是靠遍历顺序猜）
    check('begins_with("B_")' in setup_body and 'begins_with("CityNPC_")' in setup_body,
          "S3 未按 B_/CityNPC_ 前缀抓取建筑与 NPC（漏搬时不会报错）")

    # S4 地雷：非 CanvasItem 写 z_index 会抛错并中断整个搬运循环
    check("is CanvasItem" in setup_body,
          "S4 搬运前未判 is CanvasItem（对纯 Node 写 z_index 会抛错并中断循环）")

    # S5 玩家走实体路径（搬本体）
    check("_player" in setup_body and "layer.add_child(n)" in setup_body,
          "S5 玩家未作为实体搬本体入层")

    # --- S6 接入时序：建层必须在 NPC 全部生成之后 ---
    # 【大地图踩过的坑】建层早于实体生成 → 110 个城池全留在层外，且**不报任何错**。
    i_spawn = cs_raw.find("_spawn_city_npcs()")
    i_setup = cs_raw.find("_setup_depth_sort()")
    check(i_spawn >= 0 and i_setup >= 0, "S6 找不到关键调用点")
    check(i_spawn >= 0 and i_setup >= 0 and i_setup > i_spawn,
          "S6b _setup_depth_sort() 早于 _spawn_city_npcs() —— NPC 会全留在层外")

    # --- S7 玩家 z_index=20 必须已移除 ---
    # 【血泪·静态校验按源码字面切段】新增同字面结构会切坏，故用反写：
    # 断言「不存在 `_player.z_index = <数字>`」而不是断言某行存在。
    check(re.search(r"^\s*_player\.z_index\s*=", cs, re.M) is None,
          "S7 玩家仍被硬设 z_index（贴图感的最大来源，必须靠 y_sort 决定前后）")

    # --- S8 层级常量存在且次序正确 ---
    def const_int(name):
        m = re.search(rf"^const {name}\s*:=\s*(-?\d+)", cs, re.M)
        return int(m.group(1)) if m else None

    z_atmos = const_int("CITY_ATMOS_Z")
    z_veil = const_int("CITY_VEIL_Z")
    z_weather = const_int("CITY_WEATHER_Z")
    check(z_atmos is not None and z_veil is not None and z_weather is not None,
          "S8 层级常量 CITY_ATMOS_Z/CITY_VEIL_Z/CITY_WEATHER_Z 缺失")
    if None not in (z_atmos, z_veil, z_weather):
        check(z_atmos < z_veil < z_weather,
              "S8b 层级次序错误，应为 Atmos < NightVeil < Weather，实为 "
              + str(z_atmos) + "/" + str(z_veil) + "/" + str(z_weather))
        check(z_atmos > 0, "S8c 氛围层 z 必须为正（否则压到实体之下，粒子被建筑盖住）")

    # --- S9 两处依赖树序的 move_child 必须已删 ---
    # y_sort 后 `_player.get_index()` 是**层内索引**，拿去 move_child 会插错位置且不报错。
    check("_interior.move_child(_atmos" not in cs,
          "S9 仍用 _interior.move_child(_atmos, ...) 按树序插层（y_sort 后必然失效）")
    check("_interior.move_child(_night_veil" not in cs,
          "S9b 仍用 move_child 插夜色层（已改显式 z_index）")

    # --- S10 三个 z 赋值点必须真写出去（常量定义了但没用 = 空判据通过）---
    check("_atmos.z_index = CITY_ATMOS_Z" in cs,
          "S10 _atmos 未写入显式 z_index")
    check("_night_veil.z_index = CITY_VEIL_Z" in cs,
          "S10b _night_veil 未写入显式 z_index")
    check("_weather_fx.z_index = CITY_WEATHER_Z" in cs,
          "S10c _weather_fx 未写入显式 z_index")

    # --- S11 清场时句柄置空（防同名层分裂成 @ActorLayer@2）---
    build_body = func_body(cs, "_build_interior")
    check("_actor_layer = null" in build_body,
          "S11 _build_interior 清场未置空 _actor_layer（重进城会分裂出 @ActorLayer@2）")

    # --- S12 复用 DepthSort.pin_terrain 压地（不在城内重造一套）---
    check("DepthSort.pin_terrain" in setup_body,
          "S12 未复用 DepthSort.pin_terrain 压地（两套压地逻辑必然漂移）")

    # --- S13~S16【第四层·接地投影】---
    # 【为什么必须有】高度场把角色浮起来后，若脚下无影反而更假；
    # 而「影子挂错父节点」是最隐蔽的一种错 —— 它会挂进 ActorLayer 参与
    # y_sort（走远后跑到别人身后），**编译期无感、运行期不崩**。
    sh_fn = func_body(cs, "_setup_ground_shadows")
    check("func _setup_ground_shadows" in cs_raw,
          "S13 city_scene.gd 缺少 _setup_ground_shadows()（角色浮空无影）")
    check("GroundShadow.attach" in sh_fn,
          "S13b 未调用 GroundShadow.attach（投影没接上）")
    # 【关键】必须传 _interior 作地面容器；不传则内部退回 actor.get_parent()
    check("_interior)" in sh_fn,
          "S14 投影未显式指定地面容器 _interior"
          "（退回 actor.get_parent() 会被卷进 ActorLayer 参与 y_sort）")
    # 城内 NPC 游荡 → 影子必须每帧跟随，否则与本体分离留在原地
    proc_cs = func_body(cs, "_process")
    # 【踩坑·判据自身 bug·反向验证 R13 抓到假绿】
    # 原先只判 `"GroundShadow.follow" in proc_cs`。但城内有**两处** follow
    # （玩家一行 + NPC 循环一行），删掉玩家那行后 NPC 的仍在 → 子串仍命中 →
    # 判据假绿。必须**逐个目标精确断言**，只查「有没有」等于没查。
    check("GroundShadow.follow(_player)" in proc_cs,
          "S15 玩家的投影未每帧跟随（移动时影子会留在原地）")
    check(re.search(r"GroundShadow\.follow\s*\(\s*entry\.get\(\"node\"\)", proc_cs)
          is not None or "GroundShadow.follow(n" in proc_cs,
          "S15b 城内 NPC（游荡）的投影未每帧跟随（影子会与本体分离）")
    # 跟随必须写在 `_player == null` 的提前 return **之前**：
    # 否则 _player 为 null 时 NPC 影子也不再更新。
    head_before_null = proc_cs.split("_player == null")[0]
    check("GroundShadow.follow" in head_before_null,
          "S15c 投影跟随写在了 `_player == null` 提前 return **之后**"
          "（NPC 影子将不更新）")

    # 大地图侧同样要接
    if os.path.isfile(WMAP):
        wm = strip_comments(read(WMAP))
        check("GroundShadow.attach" in wm,
              "S16 大地图未接接地投影（玩家/NPC 浮空无影）")
        sh_wm = func_body(wm, "_setup_ground_shadows")
        check("self)" in sh_wm,
              "S16b 大地图投影未把场景根作地面容器传入（同 S14 的坑）")

    # --- D1~D3 DepthSort 工具类未被改坏（两处共用，改坏会同时打脸两层校验）---
    if os.path.isfile(DEPTH):
        dp = strip_comments(read(DEPTH))
        check("func build_actor_layer" in dp,
              "D1 DepthSort.build_actor_layer 签名被改")
        check("is CanvasItem" in dp,
              "D2 DepthSort._reattain 丢了 is CanvasItem 守卫（地雷①）")
        check("entity_paths" in dp and "container_paths" in dp,
              "D3 DepthSort 丢了 entity_paths/container_paths 双路径（地雷②：玩家会留在层外）")
    else:
        check(False, "D0 读不到 depth_sort.gd")

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