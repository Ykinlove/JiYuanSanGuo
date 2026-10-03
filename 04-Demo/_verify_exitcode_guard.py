# -*- coding: utf-8 -*-
"""
_verify_exitcode_guard.py — 判定型校验器「退出码传导」体检

【为什么要有这个脚本】第六十七轮在 _verify_combat.py 里挖出一个元缺陷：
该文件有 30 处 check() 判定，判定全红时只打印「失败项」然后正常收尾，
退出码恒为 0；而 _run_all_checks.py 用 `returncode == 0` 判 PASS ——
于是这把锁**永远不会响**。它比没有锁更危险：让人误以为战斗数值被守着。

这不是个案能靠肉眼发现的：一个文件「打印了 FAIL」和「退出码非 0」
是两件事，只有真跑一次注入才知道。所以这里把「体检」本身做成可执行判据。

【判据逻辑】
  对每个被聚合器驱动的校验器判定它是否**判定型**：
    判定型特征 = 源码里有 check(/results.append/fails += /_fails 等判定累积，
                 或用了 assert（失败会自然抛异常 → 非零退出）。
  判定型必须满足「失败能传导到非零退出码」，满足以下任一即可：
    · 源码含 sys.exit( / SystemExit（按当前判定结果决定退出码）
    · 源码用 assert 做判定（AssertionError 自然非零）
  若两者皆无 → 判红（不会响的锁）。

【不做的判断】本脚本**不执行**被检脚本（避免并发 Godot / 副作用），
只做静态结构判定。真正的「注入后会不会红」由各轮的 *_reverse.py 负责。
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# 判定型特征：至少命中一个才算「有判定、会因缺陷而红」
JUDGE_PATTERNS = [
    (r"\bcheck\s*\(", "check() 判定"),
    (r"results\.append", "results.append 判定累积"),
    (r"\bfails\s*\+=\s*1", "fails += 1 判定累积"),
    (r"_fails", "_fails 判定累积"),
    (r"^\s*assert\s", "assert 断言"),
    (r"\bprint_fail\b", "print_fail 判定"),
]

# 退出码传导：命中任一即视为「红了会传出去」
EXIT_PATTERNS = [
    (r"sys\.exit\s*\(", "sys.exit(...)"),
    (r"SystemExit\s*\(", "SystemExit(...)"),
    (r"^\s*assert\s", "assert 断言（AssertionError 自然非零退出）"),
    (r"os\._exit\s*\(", "os._exit(...)"),
    (r"raise\s+\w*Error", "raise Error（非零退出）"),
]

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print("  [%s] %s%s" % ("PASS" if ok else "FAIL", name, ("  " + detail) if detail else ""))
    return bool(ok)


def analyze(path):
    """返回 (是否判定型, 是否传导退出码, 命中的判定特征, 命中的退出特征)"""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        src = f.read()
    # 去掉注释与字符串，避免注释里的 "check(" 造成假判定
    code_lines = []
    for line in src.splitlines():
        s = line.strip()
        if s.startswith("#") or s.startswith("##"):
            continue
        code_lines.append(line.split("  #")[0])
    code = "\n".join(code_lines)
    # 去掉三引号块（docstring）
    code = re.sub(r'"""[\s\S]*?"""', "", code)
    judge = [(n, re.search(p, code, re.M)) for p, n in JUDGE_PATTERNS]
    judge = [n for n, m in judge if m]
    ex = [(n, re.search(p, code, re.M)) for p, n in EXIT_PATTERNS]
    ex = [n for n, m in ex if m]
    return (len(judge) > 0, len(ex) > 0, judge, ex)


print("=" * 74)
print("判定型校验器 · 退出码传导体检（不会响的锁普查）")
print("=" * 74)

# 聚合器真正驱动的清单
agg_path = os.path.join(HERE, "_run_all_checks.py")
with open(agg_path, "r", encoding="utf-8", errors="replace") as f:
    agg = f.read()
driven = re.findall(r'\(\s*"(_[a-z0-9_]+\.py)"', agg)
print("聚合器驱动 %d 个脚本\n" % len(driven))

silent = []
for name in driven:
    path = os.path.join(HERE, name)
    if not os.path.exists(path):
        check("%s 文件存在" % name, False, "聚合清单里的文件不存在")
        continue
    is_judge, has_exit, judge, ex = analyze(path)
    if not is_judge:
        print("  [SKIP] %-36s 无判定累积（纯工具/驱动脚本，退出码无判据意义）" % name)
        continue
    ok = has_exit
    detail = "判定特征[%s] / 退出码[%s]" % ("、".join(judge[:2]), "、".join(ex[:2]) or "无")
    check("%s 失败会传导到退出码" % name, ok, detail)
    if not ok:
        silent.append(name)

print()
if silent:
    print("⚠ 发现 %d 个不会响的锁（有判定但退出码恒 0）：" % len(silent))
    for n in silent:
        print("  - " + n)
    print("   后果：这些脚本判定全红时 _run_all_checks 仍记 PASS。")
    print("   修法：在汇总处补 sys.exit(1)。")
else:
    print("✅ 全部判定型校验器均会把失败传导到退出码。")

print()
print("=" * 74)
passed = sum(1 for _, ok, _ in results if ok)
print("体检结果：%d / %d 通过" % (passed, len(results)))
if passed < len(results):
    print("失败项：")
    for n, ok, d in results:
        if not ok:
            print("  - " + n + " :: " + d)
    print("=" * 74)
    sys.exit(1)
print("=" * 74)
