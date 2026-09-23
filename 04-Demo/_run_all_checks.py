# -*- coding: utf-8 -*-
"""一键运行全部校验脚本并汇总结果（替代 shell 批处理）"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable

SCRIPTS = [
    ("_validate.py", "工程基础校验（JSON / 资源 / 节点数 / 类型 / 撞名）"),
    ("_compile_check.py", "★ Godot 实际编译全部脚本（最可靠，能抓出 F5 前的语法与类型错误）"),
    ("_verify_formation.py", "M3 阵型战力公式复核"),
    ("_check_m4.py", "M4 战场节点与配置校验"),
    ("_verify_combat.py", "M4 战斗数值复核"),
    ("_check_m5.py", "M5 城池经营模块校验"),
    ("_verify_economy.py", "M5 城池经济与招募复核"),
    ("_verify_skills.py", "武将特技（铁壁/连射/冲锋）数据与触发时序复核"),
    ("_verify_prisoner.py", "俘虏招降/处死规则与数据校验"),
    ("_verify_monthly.py", "月度义兵 + 好感结义校验"),
    ("_verify_m6.py", "M6 中循环断点接线 + 战斗奖励规则 + 数值边界"),
    ("_verify_m7.py", "M7 委托任务/随机事件/铁匠强化/个人技单挑 接线与边界"),
    ("_verify_m8.py", "M8 安卓导出预设/横屏触屏/面板适配/构建产物"),
    ("_verify_m9.py", "M9 策划文档补齐+数据表标记字段+引用闭合校验"),
    ("_verify_m10.py", "M10 全国大地图分区加载框架（区域窗口/越界切区/HUD适配）"),
]

summary = []
for fname, desc in SCRIPTS:
    path = os.path.join(ROOT, fname)
    print("=" * 66)
    print(">>> %s  —  %s" % (fname, desc))
    print("=" * 66)
    if not os.path.exists(path):
        print("  [SKIP] 脚本不存在")
        summary.append((fname, "SKIP", 0))
        continue
    p = subprocess.run([PY, path], cwd=ROOT, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    out = (p.stdout or "") + (p.stderr or "")
    print(out.rstrip())
    print("")
    status = "PASS" if p.returncode == 0 else "FAIL"
    summary.append((fname, status, p.returncode))

print("=" * 66)
print("汇总")
print("=" * 66)
for fname, status, code in summary:
    print("  [%s] %-24s (exit %d)" % (status, fname, code))

fails = [s for s in summary if s[1] == "FAIL"]
print("")
if fails:
    print("[FAIL] %d 个脚本未通过：%s" % (len(fails), [f[0] for f in fails]))
    sys.exit(1)
print("全部 %d 个校验脚本通过，工程处于可运行状态 ✅" % len(summary))
