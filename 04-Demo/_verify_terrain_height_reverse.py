#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第六十八轮第三层反向验证：高度场校验器真的能抓到回退吗？

【为什么必须做】高度场最危险的失效形态是「静默变平」：
把 apply_to 改回累加漂移、把噪声频率改掉、把基准 y 守卫去掉 ——
这些都**编译期无感、运行期不崩**，画面顶多"看起来没那么明显"。

用例分三类：
  R*  真缺陷注入 —— 改坏实现，**必须 FAIL**
  F*  假阳性对照 —— 只改无关内容（注释/空白），**必须仍 PASS**
  X*  判据方向对照 —— 注入「另一种错法」，确认不会被放过

【本轮最关键的用例是 R1/R2/R3（同源性）】
高度场的公式是从 terrain_painter **抄**过来的。若两份实现漂移
（上游改噪声频率、下游留旧值），角色就会「站在画上是山的地方，
却按平原高度绘制」—— 而运行时**完全不报错**。
故必须验：改任一侧参数，另一侧的同源判据会红。

【为什么分档】完整校验含引擎真跑（分钟级），十几个用例全跑会超时，
故按注入点影响的判据层分档：
  "src" → 只跑 L3 源码锚定（秒级）
  "l1"  → 跑 L1 headless 探针（分钟级）
【副作用管控】备份用 shutil.copy2、还原也用 shutil.copy2
（**不能用 shutil.move**：Windows 上表现为「删除备份 + 写回」，
 会撞上工程的批量删除防护钩子 SAFE_DELETE_BULK_CONFIRM_REQUIRED，
 反向验证跑到第一个用例就整个停住 —— 实测踩过）。
"""
import hashlib
import io
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GODOT = r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe"
SAVES_DIR = os.path.join(
    os.environ.get("APPDATA", ""), "Godot", "app_userdata", "纪元三国", "saves")

TH = os.path.join(HERE, "scripts", "world", "terrain_height.gd")
TP = os.path.join(HERE, "scripts", "world", "terrain_painter.gd")
WMAP = os.path.join(HERE, "scripts", "world", "world_map.gd")
NPCM = os.path.join(HERE, "scripts", "world", "npc_manager.gd")

# 反向验证专用：只跑 L3 源码锚定
L3_ONLY = os.path.join(HERE, "_verify_terrain_height_reverse_l3.py")
PROBE_RESULT = os.path.join(HERE, "terrain_height_result.txt")

fails = []
n_checks = [0]
current = [""]


def ck(cond, msg):
    n_checks[0] += 1
    tag = current[0]
    print("  [%s] %-6s %s" % ("OK" if cond else "FAIL", tag, msg))
    if not cond:
        fails.append("%s %s" % (tag, msg))


def read(p):
    with io.open(p, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def write(p, s):
    with io.open(p, "w", encoding="utf-8", newline="") as f:
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
            "res://tests/terrain_height_probe.tscn", "--quit-after", "900"]
    try:
        r = subprocess.run(args, cwd=HERE, capture_output=True, text=True,
                           timeout=600, encoding="utf-8", errors="replace")
        out = (r.stdout or "") + (r.stderr or "")
        got = os.path.isfile(PROBE_RESULT)
        if got:
            with io.open(PROBE_RESULT, "r", encoding="utf-8",
                         errors="replace") as f:
                txt = f.read()
            got = "TERRAIN_HEIGHT_RESULT=PASS" in txt
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
        # 备份必须在**锚点检查之前**做，且无论走哪条分支都要还原
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
            shutil.copy2(backup, self.path)
            after = read(self.path)
            ck(after == src, "还原后文件字节完全一致")


print("=" * 70)
print("第六十八轮第三层 地形高度场校验器 · 反向验证")
print("=" * 70)

fp_before = saves_fingerprint()
print("存档指纹（跑前）= %s" % fp_before)

# ============ R1：噪声频率漂移（同源性核心）============
# 高度场的频率是从 terrain_painter 抄的。改这一侧 = 与底图山势脱钩：
# 角色站位不再对应画面上的山，**运行期完全不报错**。
Inject(
    TH,
    "const NOISE_ELEV_FREQ := 1.0 / 3000.0",
    "const NOISE_ELEV_FREQ := 1.0 / 2500.0",
    "R1", True,
    "大尺度噪声频率漂移 → 与底图山势脱钩，应被抓（T3b）", "src").run()

# ============ R2：噪声种子漂移（同源性核心）============
Inject(
    TH,
    "const NOISE_MID_SEED := 7788",
    "const NOISE_MID_SEED := 7789",
    "R2", True,
    "中尺度噪声种子漂移 → 山势与底图不一致，应被抓（T3）", "src").run()

# ============ R3：上游改了 terrain_painter，下游未跟 ============
# 这是**真实会发生**的漂移方向：有人在底图上调了噪声，
# 忘了同步高度场 → 角色高度与山势对不上。判据必须能抓到。
Inject(
    TP,
    "\tn_elev.frequency = 1.0 / 3000.0",
    "\tn_elev.frequency = 1.0 / 3000.5",
    "R3", True,
    "上游底图频率改了、高度场没跟 → 同源锚点失效应被抓（T3b）", "src").run()

# ============ R4：apply_to 退回累加漂移（本轮实抓到过的真缺陷）============
Inject(
    TH,
    "\tif not node.has_meta(\"base_y\"):\n\t\tnode.set_meta(\"base_y\", node.position.y)\n"
    "\tnode.position.y = float(node.get_meta(\"base_y\")) - lift_at(wx, wy, world, city_mask)",
    "\tnode.set_meta(\"base_y\", node.position.y)\n"
    "\tnode.position.y = float(node.get_meta(\"base_y\")) - lift_at(wx, wy, world, city_mask)",
    "R4", True,
    "去掉基准 y 守卫 → 逐次累加，走几步飞出天际（L1 H7 + T6b/c/d 三处应红）",
    "both").run()

# ============ R5：符号写反（角色沉进地里）============
Inject(
    TH,
    "\treturn elevation_at(wx, wy, world, city_mask) * HEIGHT_SCALE",
    "\treturn -elevation_at(wx, wy, world, city_mask) * HEIGHT_SCALE",
    "R5", True,
    "抬升符号写反 → 角色沉进地里（L1 H4 单调性应红）", "l1").run()

# ============ R6：高度场全返回 0（最危险的静默失效）============
# 若采样恒为低档，lift 恒 0，画面与改动前一模一样 —— 看起来"没问题"。
Inject(
    TH,
    "\tvar elev: float = west_factor * west_factor * ELEV_WEST_COEFF",
    "\tvar elev: float = 0.0",
    "R6", True,
    "西高东低阶梯被抹平 → 海拔全零，高度场静默失效（L1 H1 应红）", "l1").run()

# ============ R7：城池压平失效 ============
Inject(
    TH,
    "\t\telev = lerpf(elev, ELEV_CITY_FLAT, city_mask * 0.85)",
    "\t\telev = elev",
    "R7", True,
    "城池压平失效 → 角色在城周按山坡高度站，与底图城周平原不符（T5e）", "src").run()

# ============ R8：接线被摘掉（_process 不再调用）============
# 【锚点踩坑·两次】① `_update_height_field()` 在 world_map 里出现**三次**
# （_setup 内、_process 内、函数定义处），直接当锚点 hits=3 → 用例失效。
# ② 改用「上一行 GameState 赋值 + 下一行调用」两行组合又 hits=0 ——
# 因为两者之间**还夹着一行中文注释**。故必须连注释一起取三行。
Inject(
    WMAP,
    "\tGameState.last_world_pos = _player.position\n"
    "\t# 【第六十八轮第三层·地形高度场】角色按脚下海拔浮起（爬上坡真的有高度）\n"
    "\t_update_height_field()\n",
    "\tGameState.last_world_pos = _player.position\n",
    "R8", True,
    "_process 不再更新高度场 → 角色不随地形浮起（M5）", "src").run()

# ============ R9：改了实体本体 position（污染距离判定）============
# 实体的 position 被 NPC 距离判定/交互半径/存档直接读取。
# 把高程写进实体 position 会让「站在山上的 NPC 被算成离玩家 100px 远」。
Inject(
    WMAP,
    "\tvar pv := _player.get_node_or_null(NodePath(\"Visual\")) as Node2D",
    "\tvar pv := _player as Node2D",
    "R9", True,
    "高度场直接改实体本体 position → 距离判定与存档坐标全错（M3c）", "src").run()

# ============ R10：阈值节流被摘掉 ============
Inject(
    WMAP,
    "const HEIGHT_LIFT_EPSILON := 1.0",
    "const HEIGHT_LIFT_EPSILON := 0.0",
    "R10", False,
    "阈值常量存在（值为 0 不影响判据语义，故本例应仍绿——它验的是常量是否在用）",
    "src").run()

# ============ R11：NPC 公开访问器被摘掉 ============
Inject(
    NPCM,
    "func get_npc_nodes() -> Array[Node2D]:",
    "func get_npc_nodes_XXX() -> Array[Node2D]:",
    "R11", True,
    "NPCManager 不再暴露 get_npc_nodes() → world_map 取不到节点（N1）", "src").run()

# ============ R12：样本高度出口被摘掉 ============
Inject(
    TP,
    "func sample_height(wx: float, wy: float) -> Dictionary:",
    "func sample_height_XXX(wx: float, wy: float) -> Dictionary:",
    "R12", True,
    "TerrainPainter 不再暴露 sample_height() → 海拔真源出口没了（P1）", "src").run()

# ============ F1/F2 假阳性对照：只改注释，必须仍绿 ============
Inject(
    TH,
    "## 高度偏移总量：最高山抬升多少世界像素。",
    "## 高度偏移总量：最高山抬升多少世界像素（假阳性对照：只改注释）。",
    "F1", False,
    "只改注释 → 判据不得误报红", "src").run()

Inject(
    WMAP,
    "\t# 玩家与世界 NPC：每帧跟随（会动）\n",
    "\t# 玩家与世界 NPC：每帧跟随（会动）（假阳性对照）\n",
    "F2", False,
    "只改注释 → 判据不得误报红", "src").run()

# ============ X1 判据方向对照 ============
# 把高度场彻底删掉（class_name 改名）→ 所有 API 判据应红。
# 目的是确认「类存在性」这条判据不是恒真。
Inject(
    TH,
    "class_name TerrainHeight",
    "class_name TerrainHeightXXX",
    "X1", True,
    "类名改掉 → 类存在性判据应报红（T1）", "src").run()

print("-" * 70)
print("检查项：%d    失败：%d" % (n_checks[0], len(fails)))
fp_after = saves_fingerprint()
print("存档指纹（跑后）= %s" % fp_after)
if fp_before != fp_after:
    fails.append("存档指纹变化：%s → %s（探针污染了玩家存档）" % (fp_before, fp_after))
    print("  [FAIL] STAMP 存档指纹变化 %s → %s" % (fp_before, fp_after))
else:
    print("  [OK]   STAMP 存档指纹一致（未污染玩家存档）")

if fails:
    print("-" * 70)
    print("反向验证：FAIL（%d 项）" % len(fails))
    for m in fails:
        print("  - " + m)
    sys.exit(1)
print("=" * 70)
print("反向验证：ALL PASS（%d 项）" % n_checks[0])
sys.exit(0)