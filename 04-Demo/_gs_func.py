# -*- coding: utf-8 -*-
"""GDScript 函数体提取器（校验器共用的单一真源）。

【为什么抽成共享模块】本仓库曾有 25 个校验器各自拷了一份 func_body，
且每份都踩过不同的坑（六次假红/假绿）。拷贝 = 各自漂移 = 反复踩坑。
改这一处即改 25 处。

【血泪·六次踩坑的最终形态，勿再简化】
  1) 只按 {}/} 配对 → 遇 `var x: Dictionary = {}` 立刻 depth 归零 → 体被截成几十字符
  2) 加字符串跳过后被单引号 'Hint' 搞乱状态
  3) 正则只写 ^func → 匹配不到 `static func` → 判据集体假红
  4) 按「第一个换行」当签名结束 → 截到签名续行（缩进更深）→ 真体缩进更小 → 立即 break
  5) 基线缩进取错行：拿「签名后第一行代码」当基线，而它通常是 `if`（1 tab），
     体里同级 `if`/`var` 也是 1 tab → 被判成「函数结束」→ 体被截断
     正解：基线 = **函数签名行自身的缩进**（顶层函数恒为 0）
  6) 【本轮新增】逐行推进括号配平后，start 停在**签名行自身**，
     下一行虽该收进体却被 `ind <= baseline` 立即 break → 取到空体 →
     判据集体假红（5 项 A/B 组 + B1/B3/C/D 组整段缺失）。
     正解：用 `src.find(chr(10), j)` 从**签名结束位置之后**取下一行，
     即按字符扫描 j（签名右括号位置）而不是按行。

【参数两种历史形态都要支持】（某次统一时踩过：只认裸名会让 9 个
 用「完整签名片段」调用的校验器集体返回 None → 假红）
  · 裸名：      "_process"
  · 带 func 前缀："func add_legs("
  · 带参数字面： "func _process(delta"
统一规约为：去掉 "func " 前缀 → 取首个 "(" 之前的部分 → 函数名。
"""
import re


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
