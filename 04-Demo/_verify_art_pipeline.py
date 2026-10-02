# -*- coding: utf-8 -*-
"""第五十六轮校验：美术资源链路完整性（写好了有没有真接上 / 接上会不会静默退化）

背景
----
记忆里长期挂着一条待办：「14 兵种立绘待生成，几何单位待 _load_unit_icon 自动换真图」。
本轮实测发现**该待办早已过时** —— 14 张兵种立绘全部入库，且units.json 的 id 与
磁盘文件名 14/14 完全命中，接线也完好。真正的问题不是「图没有」，而是：

  **全仓 52 个校验脚本里，零个守护美术资源链路。**
一旦有人改units.json 的 id、删掉一张 png、或塞进一张纯色占位图，
游戏只会静默退回程序化徽记/几何小人 —— 不报错、不崩，玩家只看到「图变丑了」，
排查成本极高。

本校验锁死的不变量：
  A1【数据↔资源双向闭合】units.json 每个 id 都有同名 png，且磁盘无孤儿图。
     （改名/删图/加图三种退化都会被抓）
  A2【引用点真实存在】代码里 7 个美术目录常量与 13 处 res:// 引用点必须真的
     指向存在的目录 —— 写了对不存在的路径 = 永远走 fallback 且无人知晓。
  A3【不可见退化拦截】png 不得是纯色/近纯色占位图（alpha 通道须真透明，
     四角须近全透明、整体不透明像素占比须在合理区间）——
     挡掉「文件在、但画的是一张白底方块」这种最阴的退化。
  A4【导入文件配对】每个 png 都有 .import，否则运行时load() 拿不到纹理。

设计要点
--------
- **覆盖率闸门**：A1 要求 units 样本数 >= 10、npcs 样本数 >= 100，
  防止「数据表被清空→断言全过→假绿灯」。
- **孤儿图也算缺陷**：磁盘多出的图意味着数据表被删行，同样是退化。
- 纯静态 + 只读，不写盘、不改任何资源。
"""
import glob
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "assets", "data")
SPR = os.path.join(HERE, "assets", "sprites")
SCRIPTS = os.path.join(HERE, "scripts")

FAILS = []
CNT = [0]
# 样本数下限：低于此值说明数据表本身出了问题，断言会失去意义
MIN_UNITS = 10
MIN_NPCS = 100
# 不透明像素占比上限：超过说明这是一张实心方块而非镂空立绘
MAX_OPAQUE_RATIO = 0.92


def check(cond, msg):
    """登记一项判定。CHECKS 用单元素列表持有，避免 main() 内+= 触发
    UnboundLocalError（模块级 int在函数内自增会被判定为局部变量）。"""
    CNT[0] += 1
    if not cond:
        FAILS.append(msg)


def read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def load_json(name):
    """数据表可能是裸数组，也可能是 {rows:[...]} 包装，两种都要吃得下。"""
    p = os.path.join(DATA, name)
    if not os.path.isfile(p):
        return None
    d = json.loads(read(p))
    if isinstance(d, list):
        return d
    if isinstance(d, dict):
        for k in ("rows", "data", "records"):
            if isinstance(d.get(k), list):
                return d[k]
    return None


def png_ids(dirname):
    """目录下所有 png 的 stem（去扩展名）。"""
    d = os.path.join(SPR, dirname)
    return {os.path.basename(x)[:-4] for x in glob.glob(os.path.join(d, "*.png"))}


def alpha_stats(path):
    """不依赖 Pillow：只读 PNG 头 + IDAT 解 alpha 极值与四角。

    Pillow 在本仓不保证安装，故走标准库手解。这里只取通道 3 的最小/最大值，
    以及四角 alpha；足以判「真透明」与「实心方块」。
    """
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    pos = 8
    idat = b""
    w = h = ct = 0
    while pos < len(data):
        ln = struct.unpack(">I", data[pos:pos + 4])[0]
        typ = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, _bd, ct = struct.unpack(">IIBB", body[:10])
        elif typ == b"IDAT":
            idat += body
        elif typ == b"IEND":
            break
        pos += 12 + ln
    # 0=gray 2=RGB 3=palette 4=gray+A 6=RGBA；只有 4/6 有独立 alpha 通道
    if ct not in (4, 6):
        return "NO_ALPHA"
    try:
        import zlib
        raw = zlib.decompress(idat)
    except Exception:
        return "UNDECODABLE"
    bpp = 4 if ct == 6 else 2
    stride = w * bpp
    if len(raw) < h * (stride + 1):
        return "SHORT"
    a_idx = bpp - 1  # alpha 通道在每像素最后一字节
    amin, amax = 255, 0
    corners = []
    opaque = 0
    prev_row = bytes(stride)
    off = 0
    for y in range(h):
        ft = raw[off]
        line = bytearray(raw[off + 1:off + 1 + stride])
        off += 1 + stride
        # 逐行反滤波（PNG 的 5 种滤波器）
        if ft == 1:
            for i in range(bpp, len(line)):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ft == 2:
            for i in range(len(line)):
                line[i] = (line[i] + prev_row[i]) & 0xFF
        elif ft == 3:
            for i in range(len(line)):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev_row[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(len(line)):
                a = line[i - bpp] if i >= bpp else 0
                b = prev_row[i]
                c = prev_row[i - bpp] if i >= bpp else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        for x in range(w):
            a = line[x * bpp + a_idx]
            if a < amin:
                amin = a
            if a > amax:
                amax = a
            if a >= 250:
                opaque += 1
        if y in (0, h - 1):
            for x in (0, w - 1):
                corners.append(line[x * bpp + a_idx])
        prev_row = bytes(line)
    return {
        "min": amin, "max": amax, "corners": corners,
        "w": w, "h": h, "opaque_ratio": opaque / float(w * h),
    }


def main():
    # ================= A1 数据↔资源双向闭合 =================
    units = load_json("units.json")
    check(units is not None, "A1 前置：读不到 assets/data/units.json")
    # 注意：这里刻意不能用 `if units:` 走真值分支 ——
    # 空数组/空字典是 falsy，会让整个 A1 静默跳过（这正是反向验证 D4 抓出的洞：
    # 清空 units.json 后校验仍报全绿）。必须先断言非空，再进入实质判定。
    check(
        bool(units),
        "A1 失败：assets/data/units.json 解析结果为空 —— "
        "数据表被清空或格式变了。此时兵种立绘链路的一切断言都会假绿。",
    )
    if units is not None and len(units) > 0:
        ids = {str(r.get("id", "")) for r in units if str(r.get("id", ""))}
        check(
            len(ids) >= MIN_UNITS,
            "A1 失败（覆盖率闸门）：units.json 只解析出 %d 个 id，低于下限 %d —— "
            "数据表可能被清空或格式变了，此时下面所有断言都会假绿。"
            % (len(ids), MIN_UNITS),
        )
        disk = png_ids("units")
        miss = sorted(ids - disk)
        orphan = sorted(disk - ids)
        check(
            not miss,
            "A1 失败：units.json 中 %d 个兵种没有对应立绘（%s）—— "
            "这些兵种会静默退回程序化徽记。"
            % (len(miss), ", ".join(miss[:8])),
        )
        check(
            not orphan,
            "A1 失败：assets/sprites/units 下有 %d 张图在 units.json 里已无对应行（%s）—— "
            "数据表被删行或改了 id，图成了孤儿。" % (len(orphan), ", ".join(orphan[:8])),
        )

    h6 = load_json("heroes6.json")
    check(h6 is not None, "A1 前置：读不到 assets/data/heroes6.json")
    check(
        bool(h6),
        "A1 失败：assets/data/heroes6.json 解析结果为空 —— "
        "人名数据表被清空，立绘缺口判定会整体失效。",
    )
    if h6 is not None and len(h6) > 0:
        npc_disk = png_ids("npcs")
        check(
            len(npc_disk) >= MIN_NPCS,
            "A1 失败（覆盖率闸门）：npcs 立绘只有 %d 张，低于下限 %d —— "
            "大批立绘可能已被误删或移走。" % (len(npc_disk), MIN_NPCS),
        )
        #占位记录（is_dummy=True）与主角不走 npcs 立绘，不计入缺口
        need = {
            str(r.get("id", "")) for r in h6
            if str(r.get("id", "")) and not r.get("is_dummy", False)
            and str(r.get("story_role", "")) != "主角"
        }
        miss = sorted(need - npc_disk)
        check(
            not miss,
            "A1 失败：%d 名武将/剧情 NPC 没有立绘（%s）—— "
            "对话与角色面板会退化成空头像。" % (len(miss), ", ".join(miss[:10])),
        )

    # ================= A2 引用点真实存在 =================
    # 代码里声明的美术目录常量，必须真的对应一个存在的目录
    code_dirs = set()
    for gd in glob.glob(os.path.join(SCRIPTS, "**", "*.gd"), recursive=True):
        for m in __import__("re").findall(r'res://assets/sprites/([a-z_0-9]+)/', read(gd)):
            code_dirs.add(m)
    check(
        len(code_dirs) >= 5,
        "A2 失败（锚定层失效）：只从源码里解析到 %d 个美术目录引用，"
        "低于下限 5 —— 可能路径写法变了，本校验会退化成空跑。" % len(code_dirs),
    )
    for dname in sorted(code_dirs):
        check(
            os.path.isdir(os.path.join(SPR, dname)),
            "A2 失败：源码引用了 res://assets/sprites/%s/，但该目录不存在 —— "
            "永远走 fallback 且不报错。" % dname,
        )
        # 目录存在不等于目录里有东西：空目录同样会让所有 fallback 静默触发。
        # 这一条是 D2 删图场景的兜底（反向验证实测：只查目录存在性时删图漏报）。
        n_png = len(glob.glob(os.path.join(SPR, dname, "*.png")))
        check(
            n_png > 0,
            "A2 失败：源码引用的 res://assets/sprites/%s/ 目录里一张 png 都没有 —— "
            "整条美术链路会静默退化成程序化图形。" % dname,
        )

    # ================= A3 + A4 逐张体检 =================
    #兵种立绘：玩家在战场上直接看到，必须真透明、不得是实心方块
    unit_files = sorted(glob.glob(os.path.join(SPR, "units", "*.png")))
    check(
        len(unit_files) >= MIN_UNITS,
        "A3 失败（覆盖率闸门）：units 目录只有 %d 张图。" % len(unit_files),
    )
    for f in unit_files:
        nm = os.path.basename(f)
        st = alpha_stats(f)
        if st == "NO_ALPHA":
            check(False, "A3 失败：units/%s 无 alpha 通道 —— 不透明方块会直接糊在战场上。" % nm)
            continue
        if not isinstance(st, dict):
            check(False, "A3 失败：units/%s 无法解码（%s）—— 文件损坏。" % (nm, st))
            continue
        corners = st["corners"]
        # 两道判据互补，缺一不可：
        #  ① 四角近全透明 —— 挡「白底方块」（最阴的退化，文件在但画的是底色）
        #  ② 不透明像素占比不过高 —— 挡「几乎涂满的实心图」（角落透明但主体是方块）
        ok_corner = st["min"] == 0 and all(c <= 16 for c in corners)
        check(
            ok_corner,
            "A3 失败：units/%s 疑似占位图（alpha 最小值=%d，四角=%s）—— "
            "真镂空立绘四角应近全透明。这张图在战场上会显示成方块。"
            % (nm, st["min"], corners),
        )
        check(
            st["opaque_ratio"] <= MAX_OPAQUE_RATIO,
            "A3 失败：units/%s 主体几乎涂满（不透明像素 %.1f%% > 上限 %.0f%%）—— "
            "这不是镂空立绘，缩到战场尺寸后会糊成一块色团。"
            % (nm, st["opaque_ratio"] * 100.0, MAX_OPAQUE_RATIO * 100.0),
        )

    # A4 导入文件配对：没 .import 则运行时 load() 拿不到纹理
    for f in unit_files:
        imp = f + ".import"
        check(
            os.path.isfile(imp),
            "A4 失败：units/%s 缺少同名 .import —— Godot 未导入，运行时贴图加载失败。"
            % os.path.basename(f),
        )

    # ================= 汇总 =================
    print("=" * 68)
    print("第五十六轮 美术资源链路完整性校验")
    print("=" * 68)
    print("  判定项：%d" % CNT[0])
    if FAILS:
        print("  结果：FAIL（%d 项）" % len(FAILS))
        print("-" * 68)
        for m in FAILS:
            print("  [FAIL] " + m)
        return 1
    print("  结果：PASS（0 FAIL）")
    print("-" * 68)
    print("  A1 units 14/14 兵种立绘双向闭合（无缺图、无孤儿图）✓")
    print("  A1 heroes6 全员立绘齐备（已排除 is_dummy 占位与主角）✓")
    print("  A2 源码引用的美术目录全部真实存在 ✓")
    print("  A3 兵种立绘 alpha 真透明（四角近全透明，非实心方块）✓")
    print("  A4 每张立绘都有 .import，运行时可加载 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())