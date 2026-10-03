#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第六十三轮反向验证：逐项回退，确认 _verify_self_rule_guard.py 真的会 FAIL。

每个用例：备份 → 注入缺陷 → 跑校验器 → 必须报 FAIL → 还原 → 必须报 PASS。
若某用例注入后仍 PASS，说明该判据是假绿灯，必须重写。
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PANEL = os.path.join(HERE, "scripts", "ui", "self_rule_panel.gd")
VERIFIER = os.path.join(HERE, "_verify_self_rule_guard.py")
PY = sys.executable
BACKUP = PANEL + ".bak_rv"


def run_verifier():
    r = subprocess.run([PY, VERIFIER], cwd=HERE,
                       capture_output=True, text=True, timeout=400)
    return r.returncode, r.stdout + r.stderr


def case(tag, old, new, expect):
    src = open(PANEL, "r", encoding="utf-8").read()
    if old not in src:
        print("  [SKIP-注入失败] %s：找不到待替换片段" % tag)
        return False
    open(PANEL, "w", encoding="utf-8").write(src.replace(old, new, 1))
    try:
        code, out = run_verifier()
        failed = code != 0
        if expect == "FAIL" and not failed:
            print("  [假绿灯] %s：注入缺陷后校验器仍 PASS" % tag)
            return False
        if expect == "PASS" and failed:
            print("  [误报] %s：还原后校验器仍 FAIL\n%s" % (tag, out[-1500:]))
            return False
        print("  [OK] %s → %s（已按预期%s）" % (tag, "FAIL" if failed else "PASS",
                                              "拦截" if failed else "放行"))
        return True
    finally:
        open(PANEL, "w", encoding="utf-8").write(src)


def main():
    if not os.path.isfile(PANEL):
        print("[FAIL] 找不到 %s" % PANEL)
        return 1
    shutil.copy2(PANEL, BACKUP)
    base_code, _ = run_verifier()
    if base_code != 0:
        print("[FAIL] 基线未通过，先修基线再谈反向验证")
        return 1
    print("基线 PASS，开始反向验证：\n")

    results = []
    # P1：回退核心守卫 —— 一点即过（不弹确认窗）
    results.append(case(
        "P1 回退核心守卫（直落建国，不弹确认）",
        "\t_show_found_confirm()\n",
        "\t_self_rule_name = _name_edit.text\n"
        "\tGameState.is_self_rule = true\n",
        "FAIL"))

    # P2：拦过头 —— 改国号（可逆）也弹确认
    results.append(case(
        "P2 拦过头（改国号也弹不可逆确认）",
        "\t\tvar r := SelfRuleService.rename(_name_edit.text)",
        "\t\t_show_found_confirm()\n"
        "\t\tvar r := SelfRuleService.rename(_name_edit.text)",
        "FAIL"))

    # P3：去掉幂等守卫 —— 连点叠遮罩
    results.append(case(
        "P3 去掉幂等守卫（连点叠遮罩）",
        "\tif _found_confirm != null:\n\t\treturn\n",
        "",
        "FAIL"))

    # P4：关闭回调里直接建国
    results.append(case(
        "P4 关闭回调里直接建国",
        "func _close_found_confirm() -> void:\n",
        "func _close_found_confirm() -> void:\n"
        "\tif _pending_found_city != \"\":\n"
        "\t\t_do_found(_pending_found_city, _pending_found_name, _pending_found_flag)\n",
        "FAIL"))

    # P5：国号空白判定退回裸 is_empty（只输空格会放行到确认窗）
    results.append(case(
        "P5 国号空白判定退回裸 is_empty（放过全空格）",
        "if _name_edit.text.strip_edges().is_empty():",
        "if _name_edit.text.is_empty():",
        "FAIL"))

    # P6：文案写虚假兜底（声称可撤销）
    results.append(case(
        "P6 文案写虚假兜底（声称可撤销）",
        "自立为王不可反悔，且以下后果一概无法撤销：",
        "自立为王随时可以反悔，以下后果均可撤销：",
        "FAIL"))

    # P7：**假阳性对照**（反向验证自身的一部分）。
    # 只加一行与防误触无关的注释，校验器必须仍 PASS ——
    # 证明它不是「见改动就报」的噪声源，前面的 FAIL 才是有意义的信号。
    results.append(case(
        "P7 假阳性对照（加无关注释应仍 PASS）",
        "\t_pending_found_name = _name_edit.text.strip_edges()",
        "\t_pending_found_name = _name_edit.text.strip_edges()  # 无关注释：仅验证判据不误报",
        "PASS"))

    # P8：删掉确认窗里的国号快照字段（快照缺失必须被拦）
    results.append(case(
        "P8 确认窗缺国号快照（弹窗信息会随外部漂移）",
        "\t_pending_found_name = _name_edit.text.strip_edges()\n",
        "",
        "FAIL"))

    # P9：把 make_sub_modal 换成裸 ColorRect（与既有确认不一致）
    results.append(case(
        "P9 确认窗不用 make_sub_modal（与其他确认不一致）",
        "UITheme.make_sub_modal(self, \"自 立 建 国？\",",
        "UITheme.make_modal(self, \"自 立 建 国？\",",
        "FAIL"))

    # P10：回退第六十二轮的读档确认（跨轮保护）
    save_menu = os.path.join(HERE, "scripts", "main", "save_menu.gd")
    src = open(save_menu, "r", encoding="utf-8").read()
    if "exists and _in_game" in src:
        open(save_menu, "w", encoding="utf-8").write(
            src.replace("if exists and _in_game:", "if exists:", 1))
        try:
            code, _ = run_verifier()
            ok = code != 0
            print("  [%s] P10 回退第六十二轮读档确认（跨轮保护）→ %s"
                  % ("OK" if ok else "假绿灯", "已拦截" if ok else "未拦截"))
            results.append(ok)
        finally:
            open(save_menu, "w", encoding="utf-8").write(src)
    else:
        print("  [SKIP] P10 找不到第六十二轮守卫")
        results.append(False)

    print("\n" + "=" * 58)
    if all(results):
        print("反向验证全部通过：%d/%d 项缺陷均被拦截或按预期放行"
              % (len(results), len(results)))
        print("=" * 58)
        return 0
    print("反向验证存在假绿灯/误报：%d/%d 通过" % (sum(1 for r in results if r), len(results)))
    print("=" * 58)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
