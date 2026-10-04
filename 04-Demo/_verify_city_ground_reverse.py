# -*- coding: utf-8 -*-
"""城池视觉融入地形（第六十九轮·第 5 项第七层）· 反向验证

校验器全绿本身不证明它有效。本脚本把本轮修的缺陷逐一**重新注入**产品代码，
确认 _verify_city_ground.py 真的会报红。

铁律（照抄自 MEMORY，踩过太多次）：
  · 还原一律 shutil.copy2 覆写；清理一律 os.replace(x, x+".stale")
    且 except BaseException（钩子抛的不是 OSError）。
  · 锚点用**最小唯一锚点**，注入前先断言 count(锚点)==1。
    assert 在写盘前中止 → 文件未被破坏 → 这是一次「假绿灯的制造」。
  · 判据名有前缀关系时不可用子串匹配 → 正则 + \\b 整段词元比对。
  · 判据读的是磁盘文件，注入必须落盘到判据实际扫描的那个文件。
  · 反向验证脚本里**不得留被注入对象的完整名字字面量**（否则自己成消费者）。

用例分两类：
  · 真缺陷注入（期望 FAIL）—— 校验器必须抓到
  · 假阳性对照（期望 PASS）—— 合法的等价写法不该被判红
"""
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gs_save import fp_str, saves_fingerprint

HERE = os.path.dirname(os.path.abspath(__file__))
CMA = os.path.join(HERE, "scripts", "world", "city_marker_art.gd")
WMAP = os.path.join(HERE, "scripts", "world", "world_map.gd")
VERIFY = os.path.join(HERE, "_verify_city_ground.py")

# 被注入对象的完整名字 —— 运行时拼接，避免本脚本自己成"消费者"
F_APPLY_TILT = "apply_" + "tilt"
F_APPLY_CITY = "_apply_city_" + "tilt"
F_ADD_SHADOW = "_add_" + "shadow"
F_FACTION = "faction_" + "color"
F_AUTOLOAD = "_auto" + "load"
F_TILT_GAIN = "CITY_TILT_" + "GAIN"


def read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def write(p, s):
    """原样写回，保留原文件行尾风格（本仓 CRLF / LF 混用）。"""
    raw = open(p, "rb").read()
    nl = "\r\n" if raw.count(b"\r\n") > 0 else "\n"
    with open(p, "wb") as f:
        f.write(s.replace("\n", nl).encode("utf-8"))


def run_verify():
    r = subprocess.run([sys.executable, VERIFY], capture_output=True, cwd=HERE)
    # 强制 UTF-8 容错解码：Windows 上子进程输出可能是 GBK
    out = r.stdout.decode("utf-8", errors="replace")
    if r.stderr:
        out += r.stderr.decode("utf-8", errors="replace")
    return r.returncode, out


def main():
    results = []
    fp_before = fp_str(saves_fingerprint())

    def inject(path, anchor, repl, tag):
        """注入一个真缺陷到指定文件，跑校验器，再还原。"""
        src = read(path)
        assert src.count(anchor) == 1, \
            "%s 锚点不唯一(%d)：%r" % (tag, src.count(anchor), anchor[:60])
        bak = path + ".rvbak"
        shutil.copy2(path, bak)
        write(path, src.replace(anchor, repl))
        rc, out = run_verify()
        shutil.copy2(bak, path)
        try:
            os.replace(bak, bak + ".stale")
        except BaseException:
            pass
        return rc, out

    def case(tag, name, path, anchor, repl, expect_keys):
        rc, out = inject(path, anchor, repl, tag)
        hit = [k for k in expect_keys
               if re.search(r"\[FAIL\]\s+" + re.escape(k) + r"\b", out)]
        ok = rc != 0 and len(hit) > 0
        results.append((name, ok))
        print(("  [PASS] " if ok else "  [FAIL] ") + name
              + ("　抓到=%s" % hit if hit else ""))
        if not ok and rc == 0:
            print("        （判据未报红，rc=0）")

    print("== 真缺陷注入（期望校验器报红） ==")

    # R1【本轮核心·原缺陷回归】Art 节点改名 → _apply_height 按名找不到 → 静默失效
    case("R1", "R1 Art 节点改名（原缺陷回归：_apply_height 找不到可视子节点）",
         CMA,
         '\tart.name = "Art"',
         '\tart.name = "ArtNode"',
         ["A2", "L0-c", "L0-d", "M1"])

    # R2【本轮核心·原缺陷回归】绘制主体改回直挂 marker 根
    case("R2", "R2 绘制主体改回直挂 marker 根（原缺陷：城池永不抬升）",
         CMA,
         "\tvar host: Node2D = art if art != null else marker",
         "\tvar host: Node2D = marker",
         ["A3b", "A3", "M3"])

    # R3 接地投影改挂 marker 根（抬升后影子留原地 = 悬空）
    case("R3", "R3 接地投影改挂 marker 根（抬升后影子留原地＝悬空）",
         CMA,
         "\t\t" + F_ADD_SHADOW + "(host, target * 0.30, 0.5)",
         "\t\t" + F_ADD_SHADOW + "(marker, target * 0.30, 0.5)",
         ["A4", "M8"])

    # R4 倾斜不限幅（陡坡上城池躺下穿模）
    case("R4", "R4 倾斜去掉双向限幅（陡坡上城池躺下穿模）",
         CMA,
         "\tart.rotation = clampf(atan2(-n.x, n.y) * weight,\n"
         "\t\t-deg_to_rad(CITY_MAX_TILT_DEG), deg_to_rad(CITY_MAX_TILT_DEG))",
         "\tart.rotation = atan2(-n.x, n.y) * weight",
         ["B3", "M5"])

    # R5 mesh 不传进 build（法线断链 → 永不倾斜）
    case("R5", "R5 _create_marker 不传 mesh（法线断链，城池永不倾斜）",
         WMAP,
         "CityMarkerArt.build(marker, city, _height_world, _terrain_mesh)",
         "CityMarkerArt.build(marker, city, _height_world, null)",
         ["C1", "L0-c", "L0-d"])

    # R6 去掉回头补倾斜（生成早于 mesh → 那批城池永远没有倾斜）
    case("R6", "R6 去掉回头补倾斜（生成早于 mesh 的那批城池永远不倾斜）",
         WMAP,
         "\t_apply_city_tilt()\n",
         "\tpass\n",
         ["C2", "C2b", "M6"])

    # R7 回头补倾斜排在 _terrain_mesh 赋值之前（拿 null mesh 去算）
    case("R7", "R7 补倾斜排在 mesh 赋值之前（拿 null mesh 算）",
         WMAP,
         "\t_terrain_mesh = mesh\n",
         "\t_terrain_mesh = null\n\t_terrain_mesh = mesh\n",
         ["C2b"])

    # R8 apply_tilt 改回非 public（world_map 调不到 → 编译错）
    case("R8", "R8 " + F_APPLY_TILT + " 改回私有（world_map 补倾斜时编译失败）",
         CMA,
         "static func " + F_APPLY_TILT + "(",
         "static func _" + F_APPLY_TILT + "(",
         ["B0a", "L0-c"])

    # R9 倾斜参数与玩家侧脱钩（城歪 20°、角色只歪 14°）
    case("R9", "R9 倾斜参数与玩家侧脱钩（" + F_TILT_GAIN + " 改成 12.0）",
         CMA,
         "const CITY_TILT_GAIN := 6.0",
         "const CITY_TILT_GAIN := 12.0",
         ["B4", "M7"])

    # R10 faction_color 退回裸 GameState（无头环境整个模块编译失败）
    case("R10", "R10 " + F_FACTION + " 退回裸 GameState 标识符（无头编译失败）",
         CMA,
         '\tvar gs := ' + F_AUTOLOAD + '("GameState")',
         "\tvar gs: Object = GameState",
         ["D1", "L0-c"])

    # R11 直接改 marker.position（交互判定与存档坐标全错）
    case("R11", "R11 在 build 里改 marker.position（交互判定与存档坐标全错）",
         CMA,
         "\tvar host: Node2D = art if art != null else marker",
         "\tmarker.position.y -= 100.0\n"
         "\tvar host: Node2D = art if art != null else marker",
         ["C4"])

    # ---------- 假阳性对照（期望校验器仍全绿）----------
    print("\n== 假阳性对照（合法等价写法不该被判红） ==")

    def false_positive(tag, name, path, anchor, repl):
        src = read(path)
        assert src.count(anchor) == 1, \
            "%s 锚点不唯一(%d)" % (tag, src.count(anchor))
        bak = path + ".rvbak"
        shutil.copy2(path, bak)
        write(path, src.replace(anchor, repl))
        rc, out = run_verify()
        shutil.copy2(bak, path)
        try:
            os.replace(bak, bak + ".stale")
        except BaseException:
            pass
        ok = rc == 0
        results.append((name, ok))
        print(("  [PASS] " if ok else "  [FAIL] ") + name)
        if not ok:
            tail = [ln for ln in out.split("\n") if "[FAIL]" in ln]
            print("        误报：%s" % (tail[:3] if tail else out[-300:]))

    # F1 给 Art 命名那行加行尾注释（接线完全不变，判据用的是正则）
    false_positive(
        "F1", "F1 Art 命名行加行尾注释（接线不变）不应被误判",
        CMA, '\tart.name = "Art"', '\tart.name = "Art"  # 抬升容器')

    # F2 在 _build_onto 里加一个与判据无关的局部变量（纯噪声）
    false_positive(
        "F2", "F2 _build_onto 里加无关局部变量（纯噪声）不应被误判",
        CMA,
        '\tvar t := str(city.get("type", "city"))',
        '\tvar _unused_noise := 0\n\tvar t := str(city.get("type", "city"))')

    # ---------- 收尾 ----------
    print("")
    rc, out = run_verify()
    ok = rc == 0
    results.append(("Z1 全部注入还原后校验器恢复全绿", ok))
    print(("  [PASS] " if ok else "  [FAIL] ")
          + "Z1 全部注入还原后，校验器恢复全绿")
    if not ok:
        print(out[-1500:])

    fp_after = fp_str(saves_fingerprint())
    ok_fp = fp_before == fp_after
    results.append(("Z2 存档指纹一致", ok_fp))
    print(("  [PASS] " if ok_fp else "  [FAIL] ")
          + "Z2 存档指纹一致 :: 前=[%s] 后=[%s]" % (fp_before, fp_after))

    fails = [n for n, ok in results if not ok]
    print("")
    if fails:
        print("[FAIL] %d 项未通过：%s" % (len(fails), fails))
        return 1
    print("[PASS] 反向验证全部通过（%d 项）—— 校验器确实有效" % len(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
