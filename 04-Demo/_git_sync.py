# -*- coding: utf-8 -*-
"""一键同步：git add + commit + push

配套项目规则「每次完成一批代码改动后自动同步」，也可手动运行。

用法：
    python _git_sync.py -m "fix(ai): 修复多线开战被早退锁定"
    python _git_sync.py -m "chore: 日常改动" --no-push
    python _git_sync.py --dry-run                 # 只报告有无改动，不做任何写操作
    python _git_sync.py -m "..." --push-timeout 900
"""
import argparse
import os
import subprocess
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def git(args, cwd, timeout=None):
    """执行 git 命令，返回 (returncode, stdout, stderr)。124 表示超时。"""
    try:
        p = subprocess.run(
            ["git"] + args,
            cwd=cwd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return 124, "", "命令超时（%s 秒）" % timeout
    except FileNotFoundError:
        return 127, "", "找不到 git 可执行文件"
    return p.returncode, p.stdout or "", p.stderr or ""


def find_root():
    here = os.path.dirname(os.path.abspath(__file__))
    code, out, _ = git(["rev-parse", "--show-toplevel"], cwd=here, timeout=30)
    if code != 0 or not out.strip():
        print("[FAIL] 当前目录不在 git 仓库内")
        sys.exit(1)
    return out.strip()


def main():
    ap = argparse.ArgumentParser(description="一键同步：git add + commit + push")
    ap.add_argument("-m", "--message", help="提交信息（dry-run 时可省略）")
    ap.add_argument("--branch", default=None, help="推送分支，默认取当前分支")
    ap.add_argument("--no-push", action="store_true", help="只提交，不推送")
    ap.add_argument("--dry-run", action="store_true", help="只报告改动，不做任何写操作")
    ap.add_argument("--push-timeout", type=int, default=600, help="推送超时秒数（默认 600）")
    args = ap.parse_args()

    root = find_root()

    # ---- 1) 改动检测 ----
    code, out, err = git(["status", "--porcelain"], cwd=root, timeout=60)
    if code != 0:
        print("[FAIL] git status 失败：%s" % err.strip())
        sys.exit(1)
    lines = [l for l in out.splitlines() if l.strip()]
    if not lines:
        print("[SKIP] 无改动，无需同步。")
        return

    print("[INFO] 检测到 %d 项改动：" % len(lines))
    for l in lines[:20]:
        print("       " + l)
    if len(lines) > 20:
        print("       ...（其余 %d 项省略）" % (len(lines) - 20))

    if args.dry_run:
        print("[DRY-RUN] 未做任何写操作。")
        return

    if not args.message:
        print('[FAIL] 缺少提交信息，请用 -m "..." 指定')
        sys.exit(1)

    # ---- 2) add + commit ----
    code, _, err = git(["add", "-A"], cwd=root, timeout=120)
    if code != 0:
        print("[FAIL] git add 失败：%s" % err.strip())
        sys.exit(1)

    code, out, err = git(["commit", "-m", args.message], cwd=root, timeout=120)
    if code != 0:
        print("[FAIL] git commit 失败：%s" % (err.strip() or out.strip()))
        sys.exit(1)
    print("[OK] 已提交：%s" % args.message.strip().splitlines()[0])

    if args.no_push:
        print("[SKIP] --no-push，改动保留在本地未推送。")
        return

    # ---- 3) push ----
    branch = args.branch
    if not branch:
        _, b, _ = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd=root, timeout=30)
        branch = (b or "").strip() or "main"

    code, out, err = git(["push", "origin", branch], cwd=root, timeout=args.push_timeout)
    text = (out + err).strip()
    if code == 0:
        print("[OK] 已推送到 origin/%s" % branch)
    elif code == 124:
        print("[WARN] 推送超时（改动已提交，可稍后重推）：%s" % text)
        sys.exit(2)
    else:
        print("[FAIL] 推送失败（改动已提交，仅本地）：%s" % text)
        sys.exit(2)


if __name__ == "__main__":
    main()
