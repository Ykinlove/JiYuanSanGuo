# -*- coding: utf-8 -*-
"""城池视觉融入地形（第六十九轮·第 5 项第七层）· 接线静态复核

用户诉求「让城池融入地图里面，不要再是贴图」。取证后定位到的**根因不是
「功能没做」，而是「接线断了」：

    world_map._apply_height(actor) 会给固定实体抬升，但它找的是名为
    `Art` 或 `Visual` 的**子节点**：

        vis = n2.get_node_or_null(NodePath("Art"))
        if vis == null:
            vis = n2.get_node_or_null(NodePath("Visual"))
        if vis == null or not (vis is Node2D):
            return          # ← 静默 return

    而 CityMarkerArt.build 原先把 Sprite2D / Polygon2D **直接挂在 marker 根上**，
    两者都没有 → 每个城池都走这条静默 return →
    **110 个城池从未被抬升过**，全贴在原始平面上。

    修法只需补一个 `Art` 容器（外加按坡度倾斜），本模块不重复实现抬升逻辑。

本脚本负责「接线是否还在」，防回退。行为正确性由 tests/city_ground_probe.gd
真跑引擎负责。

  L 组·探针驱动（防假绿）
     L0a 探针真正加载执行（未编译失败）
     L0b 产出量闸门（判定总数 >= 19）
     L0c 行为判定零失败 + 探针自 verdict
     L0d 核心判定 M1/M4/M5/M8 均已执行且通过
     L0e 零 SCRIPT ERROR / Parse Error
     L0f 探针不得引用 TerrainPainter（本仓头号 autoload 陷阱）

  A 组·Art 容器接线（本轮核心）
     A1 build 必须按 world 决定是否建 Art 容器
     A2 Art 节点名必须**字面是 "Art"**（_apply_height 按名查找，改名即静默失效）
     A3 绘制主体必须画在 host（Art）上，不得仍直挂 marker 根
     A4 接地投影也必须画在 host 内（留根＝抬升后影子留原地＝悬空）

  B 组·倾斜接线
     B1 build 必须把 mesh 传进来（法线只有 TerrainMesh 有出口）
     B2 倾斜必须在 mesh 就绪时施加
     B3 倾斜必须双向限幅（clampf 到 ±CITY_MAX_TILT_DEG）
     B4 倾斜参数必须与玩家侧一致（同源，MAX_TILT_DEG=14 / GAIN=6.0）
     B5 apply_tilt 必须是 public（world_map 要回头补一次）

  C 组·world_map 侧接线
     C1 _create_marker 必须把 _height_world 与 _terrain_mesh 传进 build
     C2 _setup_terrain_mesh 必须在 mesh 建成后回头补倾斜
     C3 回头补倾斜函数必须幂等且只依赖已缓存的 _terrain_mesh
     C4 不得改 marker.position（交互判定与存档坐标直读它）

  D 组·autoload 兜底
     D1 faction_color 不得裸写 GameState（无头环境会编译失败）
     D2 取单例必须走可容错出口

  Z 组·存档
     Z1 本校验不写玩家存档

反向验证见 _verify_city_ground_reverse.py。
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gs_func import func_body

GODOT = "D:/Godot/Godot_v4.7.2-stable_win64_console.exe"
HERE = os.path.dirname(os.path.abspath(__file__))
CMA = os.path.join(HERE, "scripts", "world", "city_marker_art.gd")
WMAP = os.path.join(HERE, "scripts", "world", "world_map.gd")
PROBE = os.path.join(HERE, "tests", "city_ground_probe.gd")

# 探针的判定总数下限。低于此值说明探针没跑全（MEMORY：协程漏 await 会全空跑）。
PROBE_MIN_ITEMS = 19

results = []


def check(name, ok, detail):
    results.append((name, ok))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def code_only(text):
    """去掉注释行 —— 注释里出现同名词会骗过 in 判定（血泪，已踩两次）。"""
    out = []
    for ln in text.split("\n"):
        s = ln.strip()
        if s.startswith("#"):
            continue
        out.append(ln.split("  #")[0] if "  #" in ln else ln)
    return "\n".join(out)


def main():
    src = read(CMA)
    wmap = read(WMAP)
    body = code_only(src)
    wbody = code_only(wmap)

    # ---------------- L 组·探针驱动 ----------------
    print("\n== L 组·headless 行为探针（真跑引擎） ==")
    check("L0-0 探针文件存在", os.path.exists(PROBE),
          "tests/city_ground_probe.gd")
    probe_out = ""
    if os.path.exists(PROBE):
        pr = subprocess.run(
            [GODOT, "--headless", "--path", HERE, "--script",
             "res://tests/city_ground_probe.gd"],
            cwd=HERE, capture_output=True, text=True,
            encoding="utf-8", errors="replace")
        probe_out = (pr.stdout or "") + (pr.stderr or "")
        # 【血泪】探针编译失败时引擎**仍会吐出上一次的输出缓冲** →
        # 校验器照样读到 PROBE_DONE 19/19，绿灯是假的。必须显式检测。
        load_failed = "Failed to load script" in probe_out
        check("L0-a 探针真正加载执行（未编译失败）", not load_failed,
              "未出现 Failed to load script" if not load_failed
              else "脚本编译失败，判定数是残留缓冲，不可信！")
        m = re.search(r"PROBE_DONE\s+(\d+)/(\d+)", probe_out)
        v = re.search(r"CITY_GROUND_PROBE\s+(PASS|FAIL)", probe_out)
        got = int(m.group(2)) if m else -1
        ok_n = int(m.group(1)) if m else -1
        check("L0-b 产出量闸门（防探针全空跑假绿）",
              got >= PROBE_MIN_ITEMS and not load_failed,
              "判定总数 %s（须 >=%d）；编译失败=%s"
              % (got, PROBE_MIN_ITEMS, load_failed))
        check("L0-c 行为判定零失败",
              ok_n == got and got > 0 and not load_failed,
              "%s/%s 全通过；编译失败=%s" % (ok_n, got, load_failed))
        check("L0-d 探针自 verdict",
              v is not None and v.group(1) == "PASS" and not load_failed,
              "verdict=%s；编译失败=%s"
              % (v.group(1) if v else "无", load_failed))
        for core in ("M1", "M4", "M5", "M8"):
            hit = re.search(r"\[FAIL\]\s*" + core + r"\b", probe_out)
            check("L0-e 核心判定 %s 已执行且通过" % core,
                  core in probe_out and hit is None,
                  "已出现且无 FAIL 行" if hit is None else "出现 FAIL 行")
        se = [ln for ln in probe_out.split("\n")
              if "SCRIPT ERROR" in ln or "Parse Error" in ln]
        check("L0-f 零 SCRIPT ERROR / Parse Error", not se,
              "无" if not se else "实测 %d 条：%s" % (len(se), se[0].strip()))
        # 【本轮血泪】探针里出现 TerrainPainter 就会编译期失败（它的
        # _get_city_mask 调 DataManager，而 --headless --script 不加载
        # autoload）。把它设成红线，防止后人「顺手改回去」。
        pbody = code_only(read(PROBE)) if os.path.exists(PROBE) else ""
        check("L0-g 探针零 TerrainPainter 引用（autoload 陷阱）",
              "TerrainPainter" not in pbody,
              "探针只依赖 TerrainHeight / TerrainMesh / CityMarkerArt" if pbody
              else "探针缺失")
        check("L0-h 探针自带 mesh 替身（法线须真实非 UP）",
              "sample_height" in pbody and "StubPainter" in pbody,
              "法线恒 UP 会让倾斜类判据恒真通过 = 假绿")

    # ---------------- A 组·Art 容器接线 ----------------
    print("\n== A 组·Art 容器接线（本轮核心） ==")
    check("A0a 能提取 build", func_body(src, "func build(") is not None,
          "scripts/world/city_marker_art.gd")
    # 【元判据·血泪】func_body 的参数规范化只剥 "func " 前缀、**不剥 "static "**。
    # 传 "static func build(" 会被当成函数名 "static func build" → 全组判据集体假红。
    # 故在此显式钉住：裸名与 "func xxx(" 两种形态都必须取得到同一份体。
    _fb_bare = func_body(src, "build")
    _fb_pref = func_body(src, "func build(")
    check("A0z func_body 取体非空（防参数形态踩坑）",
          bool(_fb_bare) and bool(_fb_pref) and _fb_bare == _fb_pref
          and len(_fb_bare) > 200,
          "裸名与 func 前缀形态结果一致，体长 %d 字符"
          % len(_fb_bare or ""))
    bd = code_only(func_body(src, "func build(") or "")
    check("A0b 能提取 _build_onto", bool(func_body(src, "func _build_onto(")),
          "绘制主体已拆到 host 上")
    bo = code_only(func_body(src, "func _build_onto(") or "")

    check("A1 build 必须按 world 决定是否建 Art 容器",
          "if world != Vector2.ZERO:" in bd and "Node2D.new()" in bd,
          "无 world（无头测试 / 旧调用方）时退回旧行为")
    # 【关键·字面量】_apply_height 是 get_node_or_null(NodePath("Art")) 按名找的，
    # 改名（哪怕只是改成 "Art2D"）即静默失效 —— 且不报错。
    check("A2【核心】Art 节点名必须字面是 \"Art\"",
          re.search(r'art\.name\s*=\s*"Art"', bd) is not None,
          '_apply_height 写死 get_node_or_null(NodePath("Art"))')
    check("A3【核心】绘制主体画在 host 上，不得直挂 marker 根",
          "_build_onto(host" in bd and "host.add_child" in bo
          and "marker.add_child" not in bo,
          "留在 marker 根 → _apply_height 找不到可视子节点 → 城池永不抬升")
    check("A3b host 必须在有 Art 时取 Art、无 Art 时退回 marker",
          re.search(r"var host: Node2D = art if art != null else marker", bd)
          is not None,
          "两条构建路径都要能画")
    check("A4【核心】接地投影也画在 host 内",
          "_add_shadow(host" in bo,
          "留在 marker 根 → 图标升高、影子留原地 → 读成悬空")

    # ---------------- B 组·倾斜接线 ----------------
    print("\n== B 组·倾斜接线 ==")
    check("B0a 能提取 apply_tilt",
          func_body(src, "func apply_tilt(") is not None,
          "必须是 public：world_map 建好 mesh 后要回头补一次")
    at = code_only(func_body(src, "func apply_tilt(") or "")
    check("B1 build 必须把 mesh 传进来（法线只有 TerrainMesh 有出口）",
          "mesh: TerrainMesh = null" in src and "apply_tilt(art" in bd,
          "TerrainHeight 只有 elevation/lift，没有法线")
    check("B2 倾斜在 mesh 就绪时才施加（时序早于 mesh 不得崩）",
          "if mesh != null:" in bd,
          "_spawn_city_markers 早于 _setup_terrain_mesh，生成时 mesh 必为 null")
    check("B3【核心】倾斜必须双向限幅",
          "clampf(atan2" in at and "CITY_MAX_TILT_DEG" in at,
          "不限幅则陡坡上城池会躺下穿模")
    check("B3b 平地时必须显式归零（不能留下上一次的角度）",
          re.search(r"if weight <= 0\.01:", at) is not None
          and "art.rotation = 0.0" in at,
          "reload_region 后 mesh 变了，残留角度不会自己清")
    check("B4 倾斜参数与玩家侧一致（同源）",
          "const CITY_MAX_TILT_DEG := 14.0" in src
          and "const CITY_TILT_GAIN := 6.0" in src
          and 'const MAX_TILT_DEG := 14.0' in wmap,
          "城与角色在同一张地面上，对坡度的反应必须一致")
    check("B4b 权重公式与玩家侧同源（1-n.z 再乘 gain）",
          re.search(r"clampf\(1\.0 - n\.z, 0\.0, 1\.0\) \* CITY_TILT_GAIN", at)
          is not None,
          "两边各算一份必然对不上")

    # ---------------- C 组·world_map 侧接线 ----------------
    print("\n== C 组·world_map 侧接线 ==")
    cm = code_only(func_body(wmap, "func _create_marker(") or "")
    check("C0a 能提取 _create_marker", bool(cm), "scripts/world/world_map.gd")
    check("C1【核心】_create_marker 必须把 world + mesh 传进 build",
          re.search(r"CityMarkerArt\.build\(\s*marker,\s*city,\s*_height_world"
                    r"\s*,\s*_terrain_mesh\s*\)", cm) is not None,
          "不传则城池既不抬升也不倾斜")
    stm = code_only(func_body(wmap, "func _setup_terrain_mesh(") or "")
    check("C2【核心】mesh 建成后必须回头补倾斜",
          "_apply_city_tilt()" in stm,
          "_spawn_city_markers 跑在 _setup_terrain_mesh 之前，"
          "生成时 mesh 必为 null")
    # 【反向验证 R7 实测漏放后加固】原判据只判「_terrain_mesh = mesh 出现在
    # _apply_city_tilt 之前」，注入 `_terrain_mesh = null` + `_terrain_mesh = mesh`
    # 后正则仍能匹配到后面的 = mesh → 漏放。改为直接判**置空**：
    # mesh 一旦建成就绪，本函数内不得再把它置 null。
    _stm_assigns = re.findall(r"_terrain_mesh\s*=\s*(\S+)", stm)
    check("C2b 补倾斜必须排在 _terrain_mesh 就绪之后（且中途不得置空）",
          re.search(r"_terrain_mesh = mesh.*?_apply_city_tilt\(\)", stm,
                    re.S) is not None
          and "null" not in [a.strip() for a in _stm_assigns],
          "本函数内 _terrain_mesh 赋值序列=%s（不得含 null）" % _stm_assigns)
    act = code_only(func_body(wmap, "func _apply_city_tilt(") or "")
    check("C0b 能提取 _apply_city_tilt", bool(act), "补倾斜入口")
    check("C3 补倾斜只依赖已缓存的 _terrain_mesh（幂等）",
          "if _terrain_mesh == null" in act
          and re.search(r'get_node_or_null\(NodePath\("Art"\)\)', act) is not None,
          "重复调用只是把 rotation 重算成同一个值")
    check("C3b 补倾斜必须读 marker 上的 city_data meta",
          'get_meta("city_data"' in act and "has_meta" not in act.split("city_data")[0][-40:],
          "110 个 marker 的坐标都存在 meta 里")
    check("C3c 遍历的是已缓存的 marker 容器",
          "_city_markers.get_children()" in act,
          "不得每次遍历全场重算")
    # 【反向验证 R11 实测漏放后加固】原判据查字面 `marker.position =`，
    # 而注入的是 `marker.position.y -= 100.0`（`=` 前还有 `.y -=`）→ 漏放。
    # 正则须覆盖**任意成员访问与任意赋值/复合赋值运算符**：
    #   marker.position = / marker.position.y = / marker.position.y -= ...
    _pos_write = re.compile(r"\bmarker\.position\s*(?:\.\w+\s*)?(?:=|\+=|-=|"
                            r"\*=|/=)")
    check("C4【核心】全链路不得改 marker.position",
          _pos_write.search(bd) is None and "n2.position =" not in cm,
          "marker.position 被 _find_nearest_place 距离与存档坐标直读；"
          "已扫到写入=%s"
          % (_pos_write.search(bd).group(0) if _pos_write.search(bd) else "无"))

    # ---------------- D 组·autoload 兜底 ----------------
    print("\n== D 组·autoload 兜底 ==")
    fc = code_only(func_body(src, "func faction_color(") or "")
    check("D1【核心】faction_color 不得裸写 GameState 标识符",
          not re.search(r"^\s*(if|var|.*=\s*)GameState\b", fc, re.M),
          "GameState 是 autoload，--headless --script 下整个模块编译失败")
    check("D1b 取单例必须走 _autoload 兜底",
          '_autoload("GameState")' in fc and '_autoload("DataManager")' in fc,
          "无头环境返回 null 时退回哈希色，不崩")
    au = code_only(func_body(src, "func _autoload(") or "")
    check("D2 _autoload 必须用 Engine 出口（RefCounted 无 is_inside_tree）",
          "Engine.get_main_loop()" in au and "is SceneTree" in au,
          "本类 extends RefCounted，想拿 SceneTree 只能问 Engine")

    # ---------------- Z 组·存档 ----------------
    print("\n== Z 组·存档 ==")
    check("Z1 本校验不写玩家存档",
          not any(k in src + wmap for k in ("save_game(", "write_save")),
          "本脚本只读不写；存档指纹见反向验证 Z2")

    fails = [n for n, ok in results if not ok]
    print("")
    if fails:
        print("[FAIL] %d 项未通过：%s" % (len(fails), fails))
        return 1
    print("[PASS] 城池接地接线全部锁定 ✅（%d 项）" % len(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
