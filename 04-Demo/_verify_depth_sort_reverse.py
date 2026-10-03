#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第六十八轮反向验证：深度排序校验器真的能抓到回退吗？

【为什么必须做】新写的校验器一律存在「绿灯但没在测」的风险：
判据写错、阈值太松、探针崩了却仍输出 PASS。本文件把每个关键判据
对应的实现**逐一改坏**，确认校验器真的会红。

用例分三类：
  R*  真缺陷注入 —— 改坏实现，**必须 FAIL**
  F*  假阳性对照 —— 只改无关内容（注释/空白），**必须仍 PASS**
  X*  判据方向对照 —— 注入「另一种错法」，确认不会被放过

【为什么分档】早先版本每个用例都跑一遍完整校验（含两轮引擎真跑），
13 个用例总耗时超过 30 分钟 → 整脚本被 SIGTERM 杀掉，一个用例都没验完。
故按**注入点影响的判据层**分档：
  "src"  → 只跑 L3 源码锚定（秒级）：注入改的是源码字面量判据
  "l1"   → 跑 L1 headless 探针（分钟级）：注入影响运行时结构
  "both" → 跑 L1 + L3
【副作用管控】全部用 shutil.copy2 备份 + shutil.copy2 还原（**还原也必须是
copy2，不能用 shutil.move** —— move 在 Windows 上＝删除源+写回，其删除动作会撞
批量删除防护钩子，实测计数破阈值后整轮还原被拦、退出码非 0，表现为大批假红），
每次注入后核对字节完全一致。
存档指纹跑前跑后比对（只跑 headless 探针，不触碰玩家存档写路径）。
"""
import hashlib
import io
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GODOT = r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe"
SAVES_DIR = os.path.join(
    os.environ.get("APPDATA", ""), "Godot", "app_userdata", "纪元三国", "saves")

DEPTH = os.path.join(HERE, "scripts", "world", "depth_sort.gd")
WMAP = os.path.join(HERE, "scripts", "world", "world_map.gd")
ENC = os.path.join(HERE, "scripts", "world", "encounter_manager.gd")
NPC = os.path.join(HERE, "scripts", "world", "npc_manager.gd")

# 反向验证专用：只跑指定档位的最小校验（复用主校验器的 L3 逻辑）
L3_ONLY = os.path.join(HERE, "_verify_depth_sort_reverse_l3.py")
PROBE_TSCN = os.path.join(HERE, "tests", "depth_sort_probe.tscn")
PROBE_RESULT = os.path.join(HERE, "depth_sort_result.txt")

fails = []
n_checks = [0]
current = [""]


def ck(cond, msg):
    n_checks[0] += 1
    tag = current[0]
    line = "  [%s] %-6s %s" % ("OK" if cond else "FAIL", tag, msg)
    print(line)
    if not cond:
        fails.append("%s %s" % (tag, msg))


def read(p):
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def write(p, s):
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s)


def kill_stale_godot():
    for exe in ("Godot_v4.7.2-stable_win64_console.exe",
                "Godot_v4.7.2-stable_win64.exe"):
        try:
            subprocess.run(["taskkill", "/F", "/IM", exe], capture_output=True,
                           timeout=30, encoding="gbk", errors="replace")
        except Exception:
            pass


def saves_fingerprint():
    h = hashlib.sha256()
    if not os.path.isdir(SAVES_DIR):
        return "NO_DIR"
    for fn in sorted(os.listdir(SAVES_DIR)):
        p = os.path.join(SAVES_DIR, fn)
        if os.path.isfile(p):
            h.update(fn.encode("utf-8"))
            try:
                with open(p, "rb") as f:
                    h.update(f.read())
            except OSError:
                pass
    return h.hexdigest()[:16]


def run_l3_only():
    """只跑 L3 源码锚定（秒级）。"""
    if not os.path.isfile(L3_ONLY):
        return -3, "L3_ONLY_MISSING"
    try:
        r = subprocess.run([sys.executable, L3_ONLY], cwd=HERE,
                           capture_output=True, text=True, timeout=180,
                           encoding="utf-8", errors="replace")
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT"


def run_l1_probe():
    """只跑 L1 headless 探针（分钟级）。"""
    kill_stale_godot()
    if os.path.isfile(PROBE_RESULT):
        try:
            os.replace(PROBE_RESULT, PROBE_RESULT + ".stale")
        except OSError:
            pass
    args = [GODOT, "--headless", "--path", ".", "--scene",
            "res://tests/depth_sort_probe.tscn", "--quit-after", "900"]
    try:
        r = subprocess.run(args, cwd=HERE, capture_output=True, text=True,
                           timeout=600, encoding="utf-8", errors="replace")
        out = (r.stdout or "") + (r.stderr or "")
        got = os.path.isfile(PROBE_RESULT)
        if got:
            with open(PROBE_RESULT, "r", encoding="utf-8", errors="replace") as f:
                txt = f.read()
            got = "DEPTH_SORT_RESULT=PASS" in txt
        return (0 if got else 1), out
    except subprocess.TimeoutExpired:
        return -1, "TIMEOUT"
    except FileNotFoundError:
        return -2, "NO_GODOT"


def run_layer(layer):
    if layer == "src":
        return run_l3_only()
    if layer == "l1":
        return run_l1_probe()
    if layer == "both":
        c1, o1 = run_l1_probe()
        c2, o2 = run_l3_only()
        return (0 if (c1 == 0 and c2 == 0) else 1), o1 + o2
    return -4, "BAD_LAYER"


class Inject(object):
    """一次注入：改文件 → 跑指定档位校验 → 还原 → 核对字节一致"""

    def __init__(self, path, old, new, tag, expect_fail=True, note="", layer="src"):
        self.path = path
        self.old = old
        self.new = new
        self.tag = tag
        self.expect_fail = expect_fail
        self.note = note
        self.layer = layer

    def run(self):
        current[0] = self.tag
        src = read(self.path)
        backup = self.path + ".injbak"
        # 【血泪·必读】备份必须在**锚点检查之前**做，且锚点失配时也要还原。
        # 早先版本先查锚点、失配就 return —— 于是「上一个用例的注入内容」留在盘上
        # （实测 X1 的 z_index=8 残留到下一轮，手工才发现）。
        # 现在无论走哪条分支，都由 finally 统一还原并核对字节。
        shutil.copy2(self.path, backup)
        try:
            cnt = src.count(self.old)
            if cnt != 1:
                ck(False, "锚点命中数=%d（应为 1），用例本身失效：%r"
                   % (cnt, self.old[:60]))
                return
            write(self.path, src.replace(self.old, self.new))
            code, out = run_layer(self.layer)
            red = (code != 0)
            if self.expect_fail:
                ck(red, "注入后校验报红（exit=%s, layer=%s）%s"
                   % (code, self.layer, self.note))
            else:
                ck(not red, "假阳性对照：注入无关改动后仍绿（exit=%s, layer=%s）%s"
                   % (code, self.layer, self.note))
        finally:
            # 【血泪·必读】还原必须用 shutil.copy2 而非 shutil.move。
            # shutil.move 在 Windows 上是「删除源 + 写回」，其中的删除动作会撞上
            # 宿主的批量删除防护钩子（SAFE_DELETE_BULK_CONFIRM_REQUIRED）。
            # 本脚本一个用例一次 move，整轮十几个用例 + 聚合里其他脚本的清理叠加，
            # 计数轻易突破阈值(50) → 还原被拦 → .injbak 残留 + 退出码非 0 →
            # 聚合里表现为一批「环境性假红」（实测 count 冲到 140，19 个脚本假红）。
            # 副本多留一个 .injbak 无害（已 gitignore），但退出码必须可靠。
            shutil.copy2(backup, self.path)
            after = read(self.path)
            ck(after == src, "还原后文件字节完全一致")


print("=" * 70)
print("第六十八轮 深度排序校验器 · 反向验证")
print("=" * 70)

fp_before = saves_fingerprint()
print("存档指纹（跑前）= %s" % fp_before)

# ============ R1：实体 z_index 不清零（会覆盖 y_sort）============
Inject(
    DEPTH,
    "\tif node is CanvasItem:\n\t\t(node as CanvasItem).z_index = 0",
    "\tif false:\n\t\t(node as CanvasItem).z_index = 0",
    "R1", True, "实体 z_index 不清零 → 应被抓", "src").run()

# ============ R2：建层早于 marker 生成（缺陷 3 回归锁）============
Inject(
    WMAP,
    "\t_spawn_city_markers()\n\t# 【第六十八轮·深度排序】必须在 _spawn_city_markers()",
    "\t# 注入 R2：marker 生成被跳过\n\t# 【第六十八轮·深度排序】必须在 _spawn_city_markers()",
    "R2", True, "删掉 marker 生成在建层之前 → 应被抓（C11 源码顺序判据）", "src").run()

# ============ R3：rebuild 又改回遍历空容器（缺陷 4 回归锁）============
Inject(
    WMAP,
    "\tfor c in _marker_cache:\n\t\tif not is_instance_valid(c):\n\t\t\tcontinue\n\t\tif c.get_parent() != null:\n\t\t\tc.get_parent().remove_child(c)\n\t\tc.queue_free()",
    "\tfor c in _city_markers.get_children():\n\t\t_city_markers.remove_child(c)\n\t\tc.queue_free()",
    "R3", True, "rebuild 改回遍历空容器 → 应被抓", "src").run()

# ============ R4：reload_region 改回遍历容器（采集点永不恢复）============
Inject(
    ENC,
    "\tfor c in _enc_nodes:\n\t\tif is_instance_valid(c):\n\t\t\tc.queue_free()",
    "\tfor c in get_children():\n\t\tc.queue_free()",
    "R4", True, "reload_region 改回遍历容器 → 应被抓", "src").run()

# ============ R5：_respawn_daily 改回遍历容器（采集点次日不恢复）============
Inject(
    ENC,
    "func _respawn_daily() -> void:\n\tfor node in _enc_nodes:",
    "func _respawn_daily() -> void:\n\tfor node in get_children():",
    "R5", True, "_respawn_daily 改回遍历容器 → 应被抓", "src").run()

# ============ R6：npc _process 改回遍历容器（NPC 提示全失效）============
Inject(
    NPC,
    "\tfor node in _npc_nodes:\n\t\tif not (node is Node2D) or not node.has_meta(\"npc\"):",
    "\tfor node in get_children():\n\t\tif not (node is Node2D) or not node.has_meta(\"npc\"):",
    "R6", True, "npc _process 改回遍历容器 → 应被抓", "src").run()

# ============ R7：新增一处绕过统一入口的直查（缺陷 5 回归锁）============
# 在 _is_player_near_city 里塞第二个 _city_markers.get_node_or_null 直查，
# 模拟「新写代码忘了改用统一入口」——这正是缺陷 5 的复发形态。
Inject(
    WMAP,
    "\tvar marker := _find_marker(city_id)",
    "\tvar marker := _city_markers.get_node_or_null(\"Marker_\" + city_id)",
    "R7", True, "新增绕过统一入口的直查 → 应被抓（C19 计数变 2）", "src").run()

# ============ R8：is CanvasItem 守卫被去掉（地雷①）============
Inject(
    DEPTH,
    "\tif node is CanvasItem:\n\t\t(node as CanvasItem).z_index = 0",
    "\t(node as CanvasItem).z_index = 0",
    "R8", True, "去掉 is CanvasItem 守卫 → 应被抓（Player/WalkAnim 抛错中断）", "src").run()

# ============ R9：pin_terrain 不再关 y_sort ============
Inject(
    DEPTH,
    "\tterrain.y_sort_enabled = false\n\tterrain.z_index = z",
    "\tterrain.y_sort_enabled = true\n\tterrain.z_index = z",
    "R9", True, "地形误开 y_sort → 应被抓", "src").run()

# ============ R10：层不 move_child 到首位 ============
Inject(
    DEPTH,
    "\tworld_root.move_child(layer, 0)",
    "\tpass",
    "R10", True, "层不置首位 → 应被抓", "l1").run()

# ============ R11：_find_marker 去掉 ActorLayer 优先 ============
Inject(
    WMAP,
    "\tif _actor_layer != null:\n\t\tvar m := _actor_layer.get_node_or_null(path) as Node2D\n\t\tif m != null:\n\t\t\treturn m",
    "\tif false:\n\t\tpass",
    "R11", True, "_find_marker 不查 ActorLayer → 应被抓", "src").run()

# ============ R12：运行时层 —— 让切区重建不再搬回层里 ============
# 去掉 _on_reparent_requested 里的搬运（只留信号连接），
# 切区后新生成的遭遇点会留在空容器里 → L1 的 A6 组必须报红。
Inject(
    WMAP,
    "\t\t\tif child.get_parent() == _actor_layer:",
    "\t\t\tif true:",
    "R12", True, "切区重建不再搬回层内 → L1 A6 组应报红", "l1").run()

# ============ F1/F2：假阳性对照（只改注释）============
Inject(
    DEPTH,
    "## 地形层专用：关掉 y_sort 并压到最底。",
    "## 地形层专用：关掉 y_sort 并压到最底。（假阳性对照：仅改注释）",
    "F1", False, "仅改注释（DepthSort）", "src").run()

Inject(
    ENC,
    "func _too_close_to_encounter(pos: Vector2) -> bool:",
    "func _too_close_to_encounter(pos: Vector2) -> bool:  # 假阳性对照：仅改注释",
    "F2", False, "仅改注释（encounter_manager）", "src").run()

# ============ X1：判据方向对照 ——
# 把「层内实体 z_index 必须全 0」反向（允许非 0），
# 若判据真的在断这条，PIX/结构探针与 C 系列都该红。
Inject(
    DEPTH,
    "\tif node is CanvasItem:\n\t\t(node as CanvasItem).z_index = 0",
    "\tif node is CanvasItem:\n\t\t(node as CanvasItem).z_index = 8",
    "X1", True, "实体 z_index 改成 8（会盖过 y_sort）→ 应被抓", "l1").run()

fp_after = saves_fingerprint()
print("存档指纹（跑后）= %s" % fp_after)
ck(fp_before == fp_after, "存档未被污染（指纹一致）")

print("\n" + "=" * 70)
for f in fails:
    print("  [FAIL] " + f)
print("  用例 %d 项 / 失败 %d" % (n_checks[0], len(fails)))
print("=" * 70)
if fails:
    print("DEPTH_SORT_REVERSE=FAIL")
    sys.exit(1)
print("DEPTH_SORT_REVERSE=PASS（%d 项全绿）" % n_checks[0])
sys.exit(0)
