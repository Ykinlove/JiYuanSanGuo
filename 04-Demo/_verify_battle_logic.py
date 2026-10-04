# -*- coding: utf-8 -*-
"""战斗逻辑审计（第六十八轮·战斗合理化）· 接线静态复核

本轮修的 6 个**真实**缺陷，全部由 tests/battle_logic_probe.gd 真跑引擎抓到。
探针负责「行为是否正确」，本脚本负责「接线是否还在」—— 防回退。

  A 组·伤害基准单一真源（本轮最重要）
     A1 base_damage 必须调 count_factor_of，不能自己再写一份兵力系数
     A2 count_factor_of 必须是 static（calc_damage 是静态函数，调不到实例方法）
     A3 calc_damage 必须调 count_factor_of（不得内联 clamp 表达式）
     A4 base_damage 里不得残留 count / 100.0 这类旧口径

  B 组·索敌合理性
     B1 _acquire_target 必须同时排除 is_gone 与 is_routed
     B2 _do_advance / _do_engage 的目标校验必须同样含 is_routed
     B3 proximity / category 权重必须从 combat.json.ai 读，不硬编码
     B4 combat.json.ai 必须含 proximity_weight 与 category_weight

  C 组·固守语义
     C1 _do_advance 的固守分支不得再写 state = State.IDLE（抖动根因）
     C2 固守待命必须以「不改 state」实现（就地 return）
     C3 _hold_engage_span 必须被调用，且 HOLD_SPAN_MULT 有定义

  D 组·士气与 HP_SCALE 解耦
     D1 take_damage 的士气分母必须先除 HP_SCALE
     D2 不得残留 maxf(1.0, hp_max) 直接当分母
     D3 注释必须说明解耦理由（防止后人"好心"改回去）

  E 组·主角输出契约
     E1 player_strike 必须接受 from: Vector2 参数
     E2 player_ultimate 必须接受 from: Vector2 参数
     E3 两者都必须用 distance_to（欧氏），不得回退到 x 最小近似
     E4 battle_scene 四处调用点必须全部传入 _player.position
     E5 player_ultimate 的 sort_custom 必须走距离排序

反向验证见 _verify_battle_logic_reverse.py。
"""
import json
import os
import re
import subprocess
import sys

# 共用单一真源：本仓库曾有 25 份各自拷贝的 func_body，每份踩过不同的坑。
# 本轮踩了第 6 次（逐行推进括号配平 → start 停在签名行 → 取到空体
# → 5 项假红 + B1/B3/C/D 整段缺失）。已抽到 _gs_func.py 统一维护。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gs_func import func_body

GODOT = "D:/Godot/Godot_v4.7.2-stable_win64_console.exe"
PROBE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "tests", "battle_logic_probe.gd")

HERE = os.path.dirname(os.path.abspath(__file__))
UNIT = os.path.join(HERE, "scripts", "battle", "battle_unit.gd")
DIR = os.path.join(HERE, "scripts", "battle", "battle_director.gd")
SCENE = os.path.join(HERE, "scripts", "battle", "battle_scene.gd")
COMBAT = os.path.join(HERE, "assets", "data", "combat.json")

results = []


def check(name, ok, detail):
    results.append((name, ok))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def code_only(text):
    """剔除注释行：判据不能被注释里的字面量骗过。"""
    out = []
    for ln in text.split("\n"):
        s = ln.strip()
        if s.startswith("#") or s.startswith("##"):
            continue
        out.append(ln)
    return "\n".join(out)


def main():
    # ===================== L0：headless 行为探针 =====================
    # 【为什么要驱动探针】探针的 PASS/FAIL 必须有人消费，
    # 否则就是「给缺陷上了把不会响的锁」——_verify_orphan_probe_lock.py
    # 会在聚合里把这判成孤儿探针。本段就是那个消费者。
    # 【产出量闸门】不能只看 verdict=PASS：探针若因编译失败而全空跑，
    # 也可能吐出 PASS（MEMORY 铁律）。必须同时验 checks 数量与失败数。
    print("== L0 组·headless 行为探针（真跑引擎） ==")
    check("L0-0 探针文件存在", os.path.exists(PROBE), "tests/battle_logic_probe.gd")
    probe_out = ""
    if os.path.exists(PROBE):
        pr = subprocess.run(
            [GODOT, "--headless", "--path", HERE, "--script",
             "res://tests/battle_logic_probe.gd"],
            cwd=HERE, capture_output=True, text=True,
            encoding="utf-8", errors="replace")
        probe_out = (pr.stdout or "") + (pr.stderr or "")
        # 【本轮踩到的血泪坑·务必看懂】
        #   `--headless --script` **不加载 autoload**（MEMORY 铁律）。
        #   battle_unit.gd 的依赖链上有 CombatFeelService → DataManager，
        #   于是**探针脚本整体编译失败**：
        #       SCRIPT ERROR: Compile Error: Identifier not found: DataManager
        #       ERROR: Failed to load script ... with error "Compilation failed"
        #   但引擎**仍会把上一次的输出缓冲吐出来** → 校验器照样读到
        #   "PROBE_DONE 32/32" → **绿灯是假的，探针一次都没真跑过**。
        #   （对照：battle_ground_probe 不依赖 battle_unit，能真跑。）
        #   按铁律「修法在探针侧、不改生产代码」，这里判据必须
        #   **显式区分真跑与编译失败**，否则就是一把不会响的锁。
        load_failed = "Failed to load script" in probe_out
        check("L0-0b 探针真正加载执行（未编译失败）", not load_failed,
              "未出现 Failed to load script —— 判定数才是真的"
              if not load_failed else
              "脚本编译失败（autoload 依赖），判定数是残留缓冲，不可信！")

        m = re.search(r"PROBE_DONE\s+(\d+)/(\d+)", probe_out)
        v = re.search(r"BATTLE_LOGIC_PROBE\s+(PASS|FAIL)", probe_out)
        got = int(m.group(2)) if m else -1
        ok_n = int(m.group(1)) if m else -1
        check("L0-a 产出量闸门（防探针全空跑假绿）",
              got >= 32 and not load_failed,
              "判定总数 %s（须 >=32）；编译失败=%s" % (got, load_failed))
        # 【第七十轮·补·失败路径不得掩盖真相】原来只报「32/33 全通过」，
        #   读者根本不知道**是哪一条**判据红了 —— 现场因此完全无法定位：
        #   探针偶发失败 / 判据写错 / 探针没跑，三种病因长得一模一样。
        #   实测踩了整整一轮才靠手动复现才找到是 C2 的统计功效不足。
        #   正解：失败时把探针的 FAIL 行原样点名。
        probe_fails = re.findall(r"^\s*\[FAIL\]\s*(.+)$", probe_out, re.M)
        check("L0-b 行为判定零失败", ok_n == got and got > 0 and not load_failed,
              "%s/%s 全通过；编译失败=%s" % (ok_n, got, load_failed)
              + ("；红项=" + " ｜ ".join(probe_fails) if probe_fails else ""))
        check("L0-c 探针自 verdict", v is not None and v.group(1) == "PASS"
              and not load_failed,
              "verdict=%s；编译失败=%s"
              % (v.group(1) if v else "无", load_failed))
        for core in ("C2", "D3", "E2", "F3"):
            hit = re.search(r"\[FAIL\]\s*" + core, probe_out)
            check("L0-d 核心判定 %s 已执行且通过" % core,
                  core in probe_out and hit is None,
                  "已出现且无 FAIL 行" if hit is None else "出现 FAIL")
        # 【本轮实测：这里必然有 2 条 ×2 重的 SCRIPT ERROR，且不是缺陷】
        #   `--headless --script` 不加载 autoload（MEMORY 铁律），
        #   而 CombatFeelService 依赖 DataManager → 加载期编译失败，
        #   报 "Identifier not found: DataManager"。
        #   它**不影响任何判定**（BattleUnit 的伤害/索敌/状态机都不经过表现层），
        #   且按铁律「修法在探针侧、不改生产代码」——所以这里锁的是
        #   「不得出现**除这条已知豁免之外**的 SCRIPT ERROR」：
        #   出现新错误说明探针引入了 autoload 依赖路径，必须报红。
        KNOWN = ("Identifier not found: DataManager",
                 "Failed to compile depended scripts")
        all_errs = re.findall(r"SCRIPT ERROR: ([^\n]+)", probe_out)
        unexpected = [e for e in all_errs
                      if not any(k in e for k in KNOWN)]
        check("L0-e 无豁免之外的 SCRIPT ERROR", len(unexpected) == 0,
              "已知豁免 %d 条（autoload 铁律），新增 %d 条：%s"
              % (len(all_errs) - len(unexpected), len(unexpected),
                 unexpected[:3] if unexpected else "无"))

    unit = read(UNIT)
    dir_ = read(DIR)
    scene = read(SCENE)
    with open(COMBAT, encoding="utf-8") as f:
        combat = json.load(f)

    print("== A 组·伤害基准单一真源 ==")
    body_base = func_body(unit, "base_damage")
    body_cf = func_body(unit, "count_factor_of")
    body_calc = func_body(unit, "calc_damage")
    check("A0a", body_base is not None, "能提取 base_damage")
    check("A0b", body_cf is not None, "能提取 count_factor_of")
    check("A0c", body_calc is not None, "能提取 calc_damage")
    if body_base is None or body_cf is None or body_calc is None:
        return finish()

    cb = code_only(body_base)
    # 【判据自纠】不能写死 "count_factor_of("：base_damage 调的是实例包装
    # _count_factor()（它是唯一面向实例的调用出口），后者才转发到静态
    # 真源。判据要认「两个出口都存在且 base_damage 用了实例那个」，
    # 写死某一个名字会在别人重构包装层时假红。
    check("A1", "_count_factor()" in cb and "func _count_factor()" in unit,
          "base_damage 走 _count_factor() 包装（不是自写一份系数）")
    check("A1b", "return count_factor_of(count, count_max)" in code_only(
              func_body(unit, "_count_factor") or ""),
          "_count_factor() 转发到静态真源 count_factor_of(count, count_max)")
    check("A2", "static func count_factor_of" in unit,
          "count_factor_of 声明为 static（calc_damage 是静态函数）")
    check("A3", "count_factor_of(attacker.count, attacker.count_max)" in code_only(body_calc),
          "calc_damage 调 count_factor_of 且传入 attacker 的 count/count_max")
    check("A4", "count) / 100.0" not in cb and "float(count) / 100.0" not in cb,
          "base_damage 里已无 count/100.0 旧口径")
    # 内联 clamp 不得残留在 calc_damage（必须走单一真源）
    check("A5", "clampf(float(attacker.count)" not in code_only(body_calc),
          "calc_damage 里不再内联兵力系数 clamp 表达式")
    # count_factor_of 的公式本身必须锁住（防有人改坏缩放曲线）
    # 【判据自纠·反向验证 P1 抓到的假绿】原先判字面量 "0.7 + 0.3"，
    # 别人把 0.3 写成 0.30（完全等价）就报红 —— 判数值不该判字面量形态。
    # 正解：用正则抽**数值**再比较，形态与精度无关。
    #     【又踩一次正则坑】clampf\([^,]+,... 里的 [^,]+ 撞上
    #     "float(cnt), maxf(30.0," 的逗号就断了；改锚行尾后又踩第二下 ——
    #     GDScript 行尾是 `..., 1.0)` **单**括号收尾（无 C 的花括号），
    #     我按双括号写 `)\s*\)\s*$` 永远不匹配。
    #     正解：只匹配最后一个钳位对 `, (lo), (hi))` 之前的形态，
    #     用 "逗号 + lo + 逗号 + hi + 行尾单括号" 精确锚定。
    m_scale = re.search(r"\*\s*([0-9.]+)\s*\+\s*([0-9.]+)", body_cf)
    m_clamp = re.search(r",\s*([0-9.]+)\s*,\s*([0-9.]+)\s*\)\s*$",
                        body_cf.strip())
    ok_a6 = bool(m_scale) and bool(m_clamp) \
        and abs(float(m_scale.group(1)) - 0.7) < 1e-9 \
        and abs(float(m_scale.group(2)) - 0.3) < 1e-9 \
        and abs(float(m_clamp.group(1)) - 0.3) < 1e-9 \
        and abs(float(m_clamp.group(2)) - 1.0) < 1e-9
    check("A6", ok_a6,
          "count_factor_of 的数值形态未变（*0.7+0.3，钳位 0.3~1.0；按数值不按字面量判定）")

    print("== B 组·索敌合理性 ==")
    body_acq = func_body(unit, "_acquire_target")
    check("B0", body_acq is not None, "能提取 _acquire_target")
    if body_acq:
        ca = code_only(body_acq)
        check("B1", "e.is_gone()" in ca and "e.is_routed()" in ca,
              "_acquire_target 同时排除已阵亡与已溃散")
        check("B3", 'ai_cfg.get("proximity_weight"' in ca
              and 'ai_cfg.get("category_weight"' in ca,
              "proximity/category 权重从 combat.json.ai 读，不硬编码")
        check("B3b", "proximity * 1.2" not in ca,
              "proximity 权重不再是硬编码 1.2")
    body_adv = func_body(unit, "_do_advance")
    body_eng = func_body(unit, "_do_engage")
    check("B2a", body_adv is not None and "is_routed()" in code_only(body_adv),
          "_do_advance 的目标校验含 is_routed")
    check("B2b", body_eng is not None and "is_routed()" in code_only(body_eng),
          "_do_engage 的目标校验含 is_routed")
    ai = combat.get("ai", {})
    check("B4", isinstance(ai.get("proximity_weight"), (int, float))
          and isinstance(ai.get("category_weight"), (int, float)),
          "combat.json.ai 含 proximity_weight(%s) / category_weight(%s)"
          % (ai.get("proximity_weight"), ai.get("category_weight")))
    check("B4b", float(ai.get("proximity_weight", 9)) <=
          float(ai.get("counter_weight", 0)) + float(ai.get("weak_hp_weight", 0)),
          "proximity_weight(%s) ≤ counter+weak 之和"
          % ai.get("proximity_weight"))

    print("== C 组·固守语义 ==")
    if body_adv:
        cad = code_only(body_adv)
        # 固守分支里不得再切 IDLE（抖动根因）
        hold_idx = cad.find("hold_position")
        seg = cad[hold_idx:] if hold_idx >= 0 else ""
        check("C1", "state = State.IDLE" not in seg,
              "固守分支不再写 state = State.IDLE（IDLE↔ADVANCE 抖动根因）")
        check("C2", "_hold_engage_span()" in cad,
              "固守判定改用 _hold_engage_span()")
        check("C2b", re.search(r"if hold_position.*_hold_engage_span\(\):\s*\n\s*return",
                               cad) is not None,
              "固守超界时是就地 return（不改 state），而非切状态")
    check("C3", "const HOLD_SPAN_MULT" in unit and "func _hold_engage_span" in unit,
          "HOLD_SPAN_MULT 与 _hold_engage_span 均有定义")

    print("== D 组·士气与 HP_SCALE 解耦 ==")
    body_td = func_body(unit, "take_damage")
    check("D0", body_td is not None, "能提取 take_damage")
    if body_td:
        ct = code_only(body_td)
        check("D1", "hp_max / HP_SCALE" in ct,
              "士气分母先除 HP_SCALE（与战斗总时长旋钮解耦）")
        check("D2", "morale_denom" in ct and "hp_max / HP_SCALE" in ct,
          "士气分母走 morale_denom 局部变量且先除 HP_SCALE（非内联 hp_max）")
        check("D3", "HP_SCALE" in body_td and "解耦" in body_td,
              "注释说明了为什么必须解耦（防后人好心改回去）")
    # 固守减伤仍必须在 calc_damage 里
    if body_calc:
        check("D4", "defender.hold_position" in code_only(body_calc),
              "防守方固守减伤仍在 calc_damage 内")

    print("== E 组·主角输出契约 ==")
    body_ps = func_body(dir_, "player_strike")
    body_pu = func_body(dir_, "player_ultimate")
    check("E0a", body_ps is not None, "能提取 player_strike")
    check("E0b", body_pu is not None, "能提取 player_ultimate")
    # 【判据自纠·作用域】from: Vector2 在**签名行**上，而 func_body 按
    # 定义只返回函数体（签名之后的部分）→ 拿体去搜签名参数必然落空。
    # 签名类判据必须查全文件，用行级正则锁定「紧跟 damage: float 之后」。
    sig_ps = re.search(r"^func player_strike\(damage: float,\s*from:\s*Vector2[^\)]*\)",
                       dir_, re.M)
    sig_pu = re.search(r"^func player_ultimate\(damage: float,\s*from:\s*Vector2[^\)]*\)",
                       dir_, re.M)
    check("E1", sig_ps is not None,
          "player_strike 签名接受 from: Vector2 参数（带默认值）")
    if body_ps:
        cps = code_only(body_ps)
        check("E3a", "distance_to" in cps,
              "player_strike 用欧氏距离（不再是 x 最小近似）")
    check("E2", sig_pu is not None,
          "player_ultimate 签名接受 from: Vector2 参数（带默认值）")
    if body_pu:
        cpu = code_only(body_pu)
        check("E5", "from.distance_to(a.position)" in cpu,
              "player_ultimate 的 sort_custom 走距离排序")
        check("E5b", "a.position.x < b.position.x" in cpu,
              "player_ultimate 保留 x 排序为无主角位置时的兜底")

    # E4：四处调用点全部传参（漏一处 = 修复形同虚设）
    ok_list = []
    for m in re.finditer(r"player_strike\(", scene):
        i = m.end() - 1
        depth = 0
        j = i
        while j < len(scene):
            if scene[j] == "(":
                depth += 1
            elif scene[j] == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        args = scene[i + 1:j]
        if "damage: float" in args:
            continue
        ok_list.append("_player.position" in args)
    check("E4a", len(ok_list) >= 2 and all(ok_list),
          "battle_scene 的 player_strike 调用点逐个传入 _player.position（%d 处）"
          % len(ok_list))
    calls_pu = re.findall(r"player_ultimate\(([^\n]*)", scene)
    calls_pu_body = [c for c in calls_pu if "damage: float" not in c]
    # 【判据自纠】原式用 scene.count("_player.position)") 全文件计数，
    # 会被无关调用凑数 → 漏传参数也可能照样绿。改为**逐调用点**判定：
    # 用括号配平扫描（不能用 [^)]*，跨不过 randf_range(...) 里的括号），
    # 取出每个调用的完整实参列表，再看是否含 _player.position。
    ok_list = []
    for m in re.finditer(r"player_ultimate\(", scene):
        i = m.end() - 1
        depth = 0
        j = i
        while j < len(scene):
            if scene[j] == "(":
                depth += 1
            elif scene[j] == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        args = scene[i + 1:j]
        if "damage: float" in args:
            continue          # 那是定义处签名，不是调用
        ok_list.append("_player.position" in args)
    check("E4b", len(ok_list) >= 2 and all(ok_list),
          "battle_scene 的 player_ultimate 调用点逐个传入 _player.position（%d 处）"
          % len(ok_list))

    return finish()


def finish():
    fails = [n for n, ok in results if not ok]
    print("")
    if fails:
        print("[FAIL] %d 项未通过：%s" % (len(fails), fails))
        return 1
    print("[PASS] 战斗逻辑合理化接线全部锁定 ✅（%d 项）" % len(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())