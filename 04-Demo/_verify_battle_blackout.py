# -*- coding: utf-8 -*-
"""战斗黑屏回归锁（2026-10-01）· 静态复核

玩家反馈「进入战斗页面后，黑屏报错」。取证后确认是**两件独立的事**叠加：

  ① 报错：battle_scene / battle_unit 共 6 处写了 Godot 4 根本不存在的
     `PropertyTweener.as_ease_in_out()`，运行时刷 "Invalid call" 红字。
     编译期查不出来（GDScript 动态解析），只有真跑才暴露。
  ② 黑屏：战前决断面板铺了 alpha=0.70 的近黑全屏压暗层，
     战场背景（深绿 0.16）× 0.30 ≈ 0.05 —— 屏幕近乎纯黑，
     面板本身又是近黑（0.07），于是"进战斗＝一片黑"。

本校验把这两类成因都钉死，防止后人改回去。
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def read(p):
    with open(os.path.join(HERE, p), "r", encoding="utf-8") as f:
        return f.read()


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

results = []


def check(name, ok, detail):
    results.append((name, ok, detail))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


def walk_gd():
    """遍历工程内所有 .gd（跳过 _legacy 之类目录不做特殊处理，全量扫）"""
    out = []
    for root, _dirs, files in os.walk(os.path.join(HERE, "scripts")):
        for fn in files:
            if fn.endswith(".gd"):
                out.append(os.path.join(root, fn))
    for root, _dirs, files in os.walk(os.path.join(HERE, "tests")):
        for fn in files:
            if fn.endswith(".gd"):
                out.append(os.path.join(root, fn))
    return out


print("=" * 68)
print("战斗黑屏回归锁 · 静态复核")
print("=" * 68)

# ---------------------------------------------------------------- A 段
print("\n[A] 伪补间 API（编译期查不出，只有真跑才报错）")
# Godot 4 的 PropertyTweener 只有 set_trans()/set_ease()，没有 as_* 系列
BAD_API = ["as_ease_in_out", "as_ease_in", "as_ease_out", "as_relative"]
hits = []
for p in walk_gd():
    src = read(os.path.relpath(p, HERE))
    for ln_no, line in enumerate(src.splitlines(), 1):
        for bad in BAD_API:
            if ("." + bad + "(") in line:
                hits.append("%s:%d %s" % (os.path.relpath(p, HERE), ln_no, bad))
check("全工程无 as_ease_in_out 等伪补间 API", not hits,
      "全部干净" if not hits else "仍存在 -> " + "; ".join(hits[:5]))

# 正确写法必须真的落地（否则等于把摆动直接删了）
bs = read("scripts/battle/battle_scene.gd")
bu = read("scripts/battle/battle_unit.gd")
n_ok = (bs.count("set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)")
        + bu.count("set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)"))
check("已改用 set_trans/set_ease 正确写法（%d 处）" % n_ok, n_ok >= 6,
      "battle_scene + battle_unit 共 %d 处" % n_ok)

# ---------------------------------------------------------------- B 段
print("\n[B] 战前决断遮罩强度（黑屏直接成因）")
m = re.search(r"const\s+PREPARE_DIM_ALPHA\s*:=\s*([0-9.]+)", bs)
check("PREPARE_DIM_ALPHA 已提为常量（不硬编码在方法里）", m is not None,
      m.group(0) if m else "未找到常量定义")
if m:
    val = float(m.group(1))
    check("遮罩强度 %0.2f ≤ 0.50（战场不被压成黑屏）" % val, val <= 0.50,
          "0.70 时背景残亮 0.048（近纯黑），现值对应残亮 %0.3f" % (0.16 * (1.0 - val)))

check("决断面板不再用近黑 self_modulate",
      "panel.self_modulate = Color(0.07" not in bs,
      "已改为 StyleBoxFlat 漆木底 + 描金边")
check("PREPARE_PANEL_COLOR 已定义", "const PREPARE_PANEL_COLOR" in bs,
      "面板底色常量化")
check("PREPARE_PANEL_BORDER 已定义", "const PREPARE_PANEL_BORDER" in bs,
      "面板描边常量化")

# ---------------------------------------------------------------- C 段
print("\n[C] 回归锁是否真的接进探针（否则改回去也不会红）")
pr = read("tests/probe_runner.gd")
check("探针断言开场黑幕真的淡出回收", "_curtain == null" in pr,
      "覆盖『黑幕不淡出』这一类黑屏")
check("探针断言遮罩强度上限", "≤ 0.50" in pr or "0.50" in pr,
      "覆盖『遮罩把战场压黑』这一类黑屏")
check("探针用 is_visible_in_tree 判实际可见", "is_visible_in_tree()" in pr,
      "避免常驻隐藏弹窗造成假阳性")

# ---------------------------------------------------------------- D 段
print("\n[D] 同类隐患：遍历 party 未做类型防御")
# 【血泪·判据不能锚在字面写法上】原判据用 `src.find("for h in GameState.party")`
# 做锚点，只能匹配「直接取 autoload 属性」这一种写法。skill_service 后来为了
# 无头可测改走 `gs.get("party")`（gs 来自 autoload 兜底），锚点找不到 → find
# 返回 -1 → body 变成 src 的**最后 400 字符** → 判据假红，
# 而产品代码的类型防御其实好好地在那儿。
# 正解：锚点只认「语义」（遍历 party），不认「写法」。
_PARTY_LOOP = re.compile(r"for\s+\w+\s+in\s+[^\n]*party")
for label, path in [("quest_service", "scripts/services/quest_service.gd"),
                    ("duel_service", "scripts/services/duel_service.gd"),
                    ("skill_service", "scripts/services/skill_service.gd")]:
    src = read(path)
    spots = [m.start() for m in _PARTY_LOOP.finditer(src)]
    # 每一个 party 遍历都必须带类型防御，任一漏判即红
    unguarded = [i for i in spots
                 if "is Dictionary" not in src[i:i + 400]]
    check("%s 遍历 party 有类型防御" % label,
          bool(spots) and not unguarded,
          "无防御时脏存档会抛 Nonexistent function 'get' in base 'String'")

# ---------------------------------------------------------------- E 段
print("\n[E] 战斗主角真立绘（几何五边形退役）")
check("立绘读取函数已接（创角选的形象进战场）",
      "func _load_player_portrait(" in bs and "player_portrait" in bs,
      "resources/sprites/player/<player_portrait>.png")
check("立绘高度常量化", "const PLAYER_PORTRAIT_H" in bs, "与大地图 120px 统一")
pp = func_body(bs, "func _build_player_portrait(")
check("立绘分支挂影子联动（行走落地感）",
      "Shadow" in pp and "shadow_node" in func_body(bs, "func _build_player_visual("),
      "抬脚影子缩小变淡")
gm = func_body(bs, "func _build_player_geometric(")
check("几何兜底分支保留（缺资源不崩）", "Polygon2D.new()" in gm, "五边形 + 描边")
vb = func_body(bs, "func _build_player_visual(")
check("兜底分支仍装双腿（行走动作）",
      "add_legs(" in vb and "_load_player_portrait(" in vb, "无立绘时也有腿")

print("")
fails = [r for r in results if not r[1]]
if fails:
    print("[FAIL] 战斗黑屏回归锁 %d 项未通过" % len(fails))
    sys.exit(1)
print("战斗黑屏回归锁全部通过 ✅（共 %d 项）" % len(results))
