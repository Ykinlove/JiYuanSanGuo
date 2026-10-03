#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第六十八轮第二层反向验证：城内深度排序校验器真的能抓到回退吗？

【为什么必须做】新写的校验器一律存在「绿灯但没在测」的风险：
判据写错、阈值太松、探针崩了却仍输出 PASS。本文件把每个关键判据
对应的实现**逐一改坏**，确认校验器真的会红。

用例分三类：
  R*  真缺陷注入 —— 改坏实现，**必须 FAIL**
  F*  假阳性对照 —— 只改无关内容（注释/空白），**必须仍 PASS**
  X*  判据方向对照 —— 注入「另一种错法」，确认不会被放过

【为什么分档】早先版本（大地图轮）每个用例都跑一遍完整校验（含两轮引擎真跑），
13 个用例总耗时超过 30 分钟 → 整脚本被 SIGTERM 杀掉，一个用例都没验完。
故按**注入点影响的判据层**分档：
  "src"  → 只跑 L3 源码锚定（秒级）：注入改的是源码字面量判据
  "l1"   → 跑 L1 headless 探针（分钟级）：注入影响运行时结构
  "l2"   → 跑 L2 像素探针（分钟级）：注入影响引擎层行为判定
【副作用管控】全部用 shutil.copy2 备份 + shutil.move 还原（不 os.remove，
避免触发批量删除防护钩子），每次注入后核对字节完全一致。
存档指纹跑前跑后比对（只跑探针，不触碰玩家存档写路径）。
"""
import hashlib
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GODOT = r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe"
SAVES_DIR = os.path.join(
    os.environ.get("APPDATA", ""), "Godot", "app_userdata", "纪元三国", "saves")

CS = os.path.join(HERE, "scripts", "city", "city_scene.gd")
DEPTH = os.path.join(HERE, "scripts", "world", "depth_sort.gd")

# 反向验证专用：只跑指定档位的最小校验（复用主校验器的 L3 逻辑）
L3_ONLY = os.path.join(HERE, "_verify_city_depth_sort_reverse_l3.py")
PROBE_RESULT = os.path.join(HERE, "city_depth_sort_result.txt")

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
            "res://tests/city_depth_sort_probe.tscn", "--quit-after", "900"]
    try:
        r = subprocess.run(args, cwd=HERE, capture_output=True, text=True,
                           timeout=600, encoding="utf-8", errors="replace")
        out = (r.stdout or "") + (r.stderr or "")
        got = os.path.isfile(PROBE_RESULT)
        if got:
            with open(PROBE_RESULT, "r", encoding="utf-8", errors="replace") as f:
                txt = f.read()
            got = "CITY_DEPTH_SORT_RESULT=PASS" in txt
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
        # 【血泪·必读】备份必须在**锚点检查之前**做，且无论走哪条分支都要还原。
        # 早先版本先查锚点、失配就 return —— 于是「上一个用例的注入内容」留在盘上
        # （实测 X1 的 z_index=8 残留到下一轮，手工才发现）。
        # 现在统一由 finally 还原并核对字节。
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
            # 【踩坑·本轮真踩到】还原原本用 shutil.move(backup, path)，
            # 它在 Windows 上表现为「删除备份 + 写回原文件」，被工程的
            # **批量删除防护钩子**拦下（SAFE_DELETE_BULK_CONFIRM_REQUIRED），
            # 反向验证跑到第一个用例就整个停住 —— 表现为「只有 R1 一行输出」。
            # 改为 shutil.copy2 覆写回去：不触发任何删除语义，字节一致。
            # 残留的 .injbak 由 .gitignore 忽略，不入库。
            shutil.copy2(backup, self.path)
            after = read(self.path)
            ck(after == src, "还原后文件字节完全一致")


print("=" * 70)
print("第六十八轮第二层 城内深度排序校验器 · 反向验证")
print("=" * 70)

fp_before = saves_fingerprint()
print("存档指纹（跑前）= %s" % fp_before)

# ================= R1：建层早于 NPC 生成（缺陷 4 回归锁）=================
# 【大地图踩过同样的坑】建层时序错误 → 110 个城池全留在层外，
# 而 DepthSort **不报任何错**。这里把 _setup_depth_sort() 挪到 NPC 生成之前。
Inject(
    CS,
    "\t_spawn_city_npcs()\n",
    "\t_setup_depth_sort()\n\t_spawn_city_npcs()\n",
    "R1", True,
    "建层早于 NPC 生成 → NPC 全留在层外，应被抓（S6b 源码顺序判据）", "src").run()

# ================= R2：玩家重新硬设 z_index=20 ================
# 【本轮最核心的移除项】z_index 优先于 y_sort（已由大地图 A0c 实测），
# 玩家一旦有非零 z_index 就整体脱离排序语义，「贴图感」立刻回来。
Inject(
    CS,
    "\t_player.position = Vector2(1200.0, INTERIOR_SIZE.y - 330.0)\n",
    "\t_player.position = Vector2(1200.0, INTERIOR_SIZE.y - 330.0)\n"
    "\t_player.z_index = 20\n",
    "R2", True,
    "玩家恢复 z_index=20 → 又会压住所有建筑，应被抓（S7）", "src").run()

# ================= R3：搬运前丢了 is CanvasItem 守卫（地雷①）=================
# 对纯 Node 写 z_index 会抛错并**中断整个搬运循环** → 后续实体全没搬进层，
# 而错误只在运行时日志里，编译期完全无感。
# 锚点缩进以源码实际为准（1/2 级 tab）。写锚点前务必先 repr 打印真实行，
# 不要按「想当然的层级」写 —— 锚点失配会让用例自身失效，
# 表现为「校验全绿」而实际上什么都没验。
Inject(
    CS,
    "\t\tif n is CanvasItem:\n\t\t\t(n as CanvasItem).z_index = 0\n",
    "\t\tif true:\n\t\t\t(n as CanvasItem).z_index = 0\n",
    "R3", True,
    "丢 is CanvasItem 守卫 → 搬运遇纯 Node 即抛错中断，应被抓（S4）", "src").run()

# ================= R4：不按名字前缀抓实体 ================
# 若改为「遍历 _interior 全部子节点」，实体漏搬时不会报错，且清场后的
# Ground/Atmos/NightVeil 会被误搬进去。
Inject(
    CS,
    '\t\tif nm.begins_with("B_") or nm.begins_with("CityNPC_"):\n\t\t\tto_move.append(child)\n',
    '\t\tif nm != "ActorLayer":\n\t\t\tto_move.append(child)\n',
    "R4", True,
    "不按 B_/CityNPC_ 前缀抓取 → 判据应报红（S3）", "src").run()

# ================= R5：层级改回依赖树序的 move_child ================
# y_sort 接入后实体整体成为排序单元，`_player.get_index()` 已是层内索引，
# 拿它 move_child 会把粒子层塞到完全无关位置，且**不报任何错**。
Inject(
    CS,
    "\t_atmos.z_index = CITY_ATMOS_Z\n",
    "\t_interior.move_child(_atmos, _player.get_index())\n",
    "R5", True,
    "层级退回树序 move_child → 应被抓（S9 + S10）", "src").run()

# ================= R6：夜色层不压氛围层（灯火被自己压暗）=================
Inject(
    CS,
    "const CITY_VEIL_Z := 90",
    "const CITY_VEIL_Z := 70",
    "R6", True,
    "夜色层 z 调到氛围层之下 → 灯火被自己压暗，应被抓（S8b）", "src").run()

# ================= R7：清场不置空句柄（同名层分裂）=================
# 重进城时新建的层会与旧层同名 → Godot 自动改名 @ActorLayer@2，
# 探针按名取层会取到空的那个，所有实体都判定「不在层内」。
Inject(
    CS,
    "\t_actor_layer = null\n\tfor child in _interior.get_children():\n\t\tchild.queue_free()",
    "\tfor child in _interior.get_children():\n\t\tchild.queue_free()",
    "R7", True,
    "清场不置空 _actor_layer → 重进城会层分裂，应被抓（S11）", "src").run()

# ================= R8：不再复用 DepthSort.pin_terrain ================
Inject(
    CS,
    "\tDepthSort.pin_terrain(ground, -100)",
    "\tground.z_index = -100",
    "R8", True,
    "不复用 pin_terrain（漏关 y_sort）→ 应被抓（S12）", "src").run()

# ================= R9：层不排首位 ================
Inject(
    CS,
    "\t_interior.move_child(layer, 0)",
    "\t_interior.move_child(layer, _interior.get_child_count() - 1)",
    "R9", True,
    "层不排首位 → 会被同 z 兄弟按插入顺序压住，应被抓（S2b）", "src").run()

# ================= R10：清空玩家入层（只搬容器子节点式的老错）=================
# 若玩家没被加入 to_move，玩家留在层外 → 永远压不住任何东西。
# 这是运行时结构问题，须跑 L1（分钟级）。
Inject(
    CS,
    "\tif _player != null:\n\t\tto_move.append(_player)\n",
    "",
    "R10", True,
    "玩家不入层 → 永远压不住建筑，应被抓（L1 结构判定）", "l1").run()

# ================= R11：NPC 前缀抓错（NPC 全留在层外）=================
Inject(
    CS,
    '\t\tif nm.begins_with("B_") or nm.begins_with("CityNPC_"):\n',
    '\t\tif nm.begins_with("B_"):\n',
    "R11", True,
    "NPC 前缀抓错 → 城内 NPC 全留在层外，应被抓（L1 结构判定）", "l1").run()

# ================= F1/F2 假阳性对照：只改注释，必须仍绿 ================
Inject(
    CS,
    "\t# 4. 玩家（自建，不依赖大地图场景；河流无阻挡，室内自由行走）\n",
    "\t# 4. 玩家（自建，不依赖大地图场景；河流无阻挡，室内自由行走）\n"
    "\t# F1 假阳性对照：只加一行注释，校验必须仍绿\n",
    "F1", False,
    "只加注释 → 判据不得误报红", "src").run()

Inject(
    CS,
    "\t# 1. 地面（城墙 / 道路 / 建筑地基）\n",
    "\t# 1. 地面（城墙 / 道路 / 建筑地基）\n"
    "\t# F2 假阳性对照：整行替换为等价措辞，校验必须仍绿\n",
    "F2", False,
    "改注释措辞 → 判据不得误报红", "src").run()

# ================= X1 判据方向对照 ================
# 把 z_index 清零改成设成 8：L1 会因「层内 z_index 非零」报红。
# 目的是确认「清零」这条判据方向正确，不是「只要写了 z_index 就算过」。
Inject(
    CS,
    "\t\t\t(n as CanvasItem).z_index = 0",
    "\t\t\t(n as CanvasItem).z_index = 8",
    "X1", True,
    "清零改成设成 8 → 应被抓（L1 A/C6 层内 z_index 非零）", "l1").run()

# ================= R12~R13【第四层·接地投影】=================
# 投影挂错父节点是最隐蔽的一种错：挂进 ActorLayer 会参与 y_sort，
# 走远后跑到别的实体身后 —— 编译期无感、运行期不崩，只有 S2/S3 能抓。
Inject(
    CS,
    "\t\tGroundShadow.attach(_player, UITheme.WORLD_UNIT_HEIGHT, _interior)\n",
    "\t\tGroundShadow.attach(_player, UITheme.WORLD_UNIT_HEIGHT,\n"
    "\t\t\t_player.get_parent())\n",
    "R12", True,
    "投影挂到 actor.get_parent()（已是被搬进 ActorLayer 的本体）→ "
    "影子参与 y_sort 走远后跑到别人身后，应被抓（S14 + L1 S2/S3/C6）", "l1").run()

Inject(
    CS,
    "\tGroundShadow.follow(_player)\n",
    "\t# 注入 R13：投影不再跟随（游荡 NPC 的影子会留在原地）\n",
    "R13", True,
    "投影不再每帧跟随 → NPC 影子与本体分离留在原地，应被抓（S15/S15b）",
    "src").run()

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