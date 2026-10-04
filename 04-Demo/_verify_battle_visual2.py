# -*- coding: utf-8 -*-
"""战斗演出强化（第六十九轮）· 接线静态复核

用户反馈「战斗场面没有代入感」。取证后定位到**三类**成因，本轮全部修掉，
并由 tests/battle_visual2_probe.gd 真跑引擎验证行为：

  ① 朝向是死代码 —— `_face()` 原式是
        `_body.scale.x = 1.0 if dir.x >= 0.0 else 1.0`
     **两个分支完全相同，等于什么都不做**。战场上一堆左右对称的图钉
     站在原地互砍，没有任何「他冲着我来」的实感。

  ② 阵亡永远轮不到演出 —— `take_damage` 的判定顺序是
        「先判溃散并 return，阵亡判定放在其后」。
     血量见底的那一击必然先把士气打到阈值以下（伤害冲击与 morale_denom
     同源），走 `_begin_rout()` 就 return → **永远到不了 `_die`**。
     后果：被一击打崩的部队直接静默退场，玩家看到「怪凭空消失」。

  ③ 推进没有位移感 —— 只有 position 变化，没有任何残影/轨迹。

本脚本负责「接线是否还在」，防回退。行为正确性由探针负责。

  A 组·朝向容器
     A1 必须存在 _facing 容器（翻转它就是整支部队转身）
     A2 方阵 / 描边 / 兵种徽记 / 军旗 必须挂在 _facing 下
     A3 地面投影必须**留在 _art 下**（影子翻向是错的）
     A4 战况标签必须**不在** _facing 下（翻了就读不清战况）

  B 组·朝向真的翻转
     B1 _face 不得再写两个分支相同的三元表达式
     B2 _face 必须写 _facing_target（且须有 |dir.x| 的正对镜头豁免）
     B3 转身必须插值（FACING_TURN_RATE 有定义且被 move_toward 用到）
     B4 翻向不得穿过 scale.x = 0（必须有「同侧/反向」分支钳位）

  C 组·冲锋轨迹
     C1 必须在推进态调用 _track_advance
     C2 轨迹点数必须封顶（remove_at(0)）
     C3 轨迹必须会淡出

  D 组·阵亡演出
     D1 _play_death 必须对 _facing 做旋转 tween
     D2 倒地方向必须随 _facing_x（不许随机挑一个方向）
     D3 **take_damage 必须先判阵亡再判溃散**（本轮最重要的一条）

反向验证见 _verify_battle_visual2_reverse.py。
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gs_func import func_body
from _gs_save import fp_str, saves_fingerprint

GODOT = "D:/Godot/Godot_v4.7.2-stable_win64_console.exe"
HERE = os.path.dirname(os.path.abspath(__file__))
UNIT = os.path.join(HERE, "scripts", "battle", "battle_unit.gd")
PROBE = os.path.join(HERE, "tests", "battle_visual2_probe.gd")

results = []


def check(name, ok, detail):
    results.append((name, ok))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def main():
    src = read(UNIT)

    # ---------------- L0 组·行为探针（真跑引擎）----------------
    print("\n== L0 组·headless 行为探针（真跑引擎） ==")
    check("L0-0 探针文件存在", os.path.exists(PROBE),
          "tests/battle_visual2_probe.gd")
    probe_out = ""
    if os.path.exists(PROBE):
        pr = subprocess.run(
            [GODOT, "--headless", "--path", HERE, "--script",
             "res://tests/battle_visual2_probe.gd"],
            cwd=HERE, capture_output=True, text=True,
            encoding="utf-8", errors="replace")
        probe_out = (pr.stdout or "") + (pr.stderr or "")
        # 【血泪·沿用 battle_logic 那一课的判据】探针编译失败时引擎**仍会
        # 吐出上一次的输出缓冲** → 校验器照样读到 PROBE_DONE 16/16，
        # 绿灯是假的。必须显式检测 Failed to load script。
        load_failed = "Failed to load script" in probe_out
        check("L0-0b 探针真正加载执行（未编译失败）", not load_failed,
              "未出现 Failed to load script" if not load_failed
              else "脚本编译失败，判定数是残留缓冲，不可信！")
        m = re.search(r"PROBE_DONE\s+(\d+)/(\d+)", probe_out)
        v = re.search(r"BATTLE_VISUAL_PROBE\s+(PASS|FAIL)", probe_out)
        got = int(m.group(2)) if m else -1
        ok_n = int(m.group(1)) if m else -1
        check("L0-a 产出量闸门（防探针全空跑假绿）",
              got >= 21 and not load_failed,
              "判定总数 %s（须 >=21）；编译失败=%s" % (got, load_failed))
        check("L0-b 行为判定零失败",
              ok_n == got and got > 0 and not load_failed,
              "%s/%s 全通过；编译失败=%s" % (ok_n, got, load_failed))
        check("L0-c 探针自 verdict",
              v is not None and v.group(1) == "PASS" and not load_failed,
              "verdict=%s；编译失败=%s"
              % (v.group(1) if v else "无", load_failed))
        for core in ("V2", "V3", "T4", "T5", "D2", "S4"):
            hit = re.search(r"\[FAIL\]\s*" + core, probe_out)
            check("L0-d 核心判定 %s 已执行且通过" % core,
                  core in probe_out and hit is None,
                  "已出现且无 FAIL 行" if hit is None else "出现 FAIL")
        se = [ln for ln in probe_out.split("\n")
              if "SCRIPT ERROR" in ln or "Parse Error" in ln]
        check("L0-e 零 SCRIPT ERROR / Parse Error", not se,
              "无" if not se else "实测 %d 条：%s" % (len(se), se[0].strip()))

    # ---------------- A 组·朝向容器 ----------------
    print("\n== A 组·朝向容器 ==")
    check("A0a 能提取 _build_visual", func_body(src, "func _build_visual(")
          is not None, "scripts/battle/battle_unit.gd")
    bv = func_body(src, "func _build_visual(") or ""
    check("A1 创建了朝向容器 _facing",
          "_facing = Node2D.new()" in bv and '"Facing"' in bv,
          "翻转它即可整支部队转身")
    check("A2a 方阵底座挂在 _facing 下",
          "_facing.add_child(_body)" in bv,
          "_body 若挂在 _art 下，翻转时方阵不会跟转")
    check("A2b 描边挂在 _facing 下",
          "_facing.add_child(_outline)" in bv, "描边随朝向")
    check("A2c 兵种图标挂在 _facing 下",
          "_facing.add_child(_icon)" in bv, "兵种徽记随朝向")
    check("A3 地面投影留在 _art 下（不翻转）",
          "_art.add_child(_shadow)" in bv and "_facing.add_child(_shadow)" not in bv,
          "影子翻向是错的 —— 影子永远该摊在脚下")
    check("A4 血条 / 名牌不挂 _facing（在 self 下）",
          "_facing.add_child(_hp_bg)" not in bv
          and "_facing.add_child(_name_label)" not in bv,
          "翻了就读不清战况 —— 原设计刻意的分层")
    banner = func_body(src, "func _build_banner(") or ""
    # 【判据修订·本轮】原判据要求「旗杆+旗面全挂 `_facing` 下」，理由是
    # 「随朝向」。但 `_facing` 会被 `scale.x` **水平镜像**（转身时先压扁再翻面），
    # 旗面挂在它下面会被翻成反面 —— 这才是真缺陷。并行会话已把旗面移到
    # `_art`（不翻转），方向正确；但**旗杆/旗顶珠仍留在 `_facing` 下**，
    # 于是转身时「翻转的旗杆」与「不翻转的旗面」横向错位。
    # 正解判据：**旗杆与旗面必须同层，且该层不在会翻转的 `_facing` 下**。
    _pole_in_facing = "_facing.add_child(pole)" in banner
    _pole_in_neutral = ("pole_root.add_child(pole)" in banner)or (
        "_art.add_child(pole)" in banner)
    _pendant_neutral = "_art.add_child(_banner_pendant)" in banner
    check("A5 旗杆与旗面同层、且都不在会翻转的 _facing 下",
          (not _pole_in_facing) and _pole_in_neutral and _pendant_neutral,
          "旗面/旗杆/旗顶珠三者须同层；`_facing` 会被 scale.x 水平镜像（转身先压扁"
          "再翻面），挂在它下面会被翻成反面；且若旗杆翻转而旗面不翻转会横向错位。"
          "实测：旗杆在 _facing=%s，同层容器=%s，旗面在 _art=%s"
          % (_pole_in_facing, _pole_in_neutral, _pendant_neutral))
    emblem = func_body(src, "func _build_emblem(") or ""
    check("A6 兵种徽记挂在 _facing 下",
          "_facing.add_child(e)" in emblem,
          "无贴图时的程序化徽记也该随朝向")

    # ---------------- B 组·朝向真的翻转 ----------------
    print("\n== B 组·朝向真的翻转 ==")
    face = func_body(src, "func _face(")
    check("B0a 能提取 _face", face is not None, "scripts/battle/battle_unit.gd")
    face = face or ""
    check("B1【核心】_face 不再是两个分支相同的三元",
          not re.search(r"=\s*1\.0\s+if\b[^=\n]*else\s+1\.0", face),
          "原式 _body.scale.x = 1.0 if dir.x>=0.0 else 1.0 == 什么都不做")
    check("B1b _face 不再直接写 _body.scale",
          "_body.scale" not in face,
          "应写 _facing_target（实际缩放由 _apply_impulse 插值推进）")
    check("B2 _face 写 _facing_target 且有正对镜头豁免",
          "_facing_target" in face and "absf(dir.x)" in face,
          "|dir.x| 过小不触发翻转，避免原地抽搐")
    check("B2b _facing_target 由 dir.x 符号决定",
          re.search(r"_facing_target\s*=\s*1\.0\s+if\s+dir\.x\s*>\s*0", face)
          is not None, "右为 +1 / 左为 -1")
    ap = func_body(src, "func _apply_impulse(") or ""
    # 【血泪】B3 首版写 `move_toward(_facing_x` —— 反向验证 R3（把转身改成
    # 硬切）注完之后**另一处** move_toward（反向转身的钳位分支）仍在，
    # 判据照样绿 → 用例假失败。实测「转身插值」要判的是**同侧插值那一支**
    # 里的 move_toward，必须把目标参数也带上才唯一。
    check("B3 转身用 move_toward 插值（非硬切）",
          re.search(r"move_toward\(\s*_facing_x\s*,\s*_facing_target", ap)
          is not None and "FACING_TURN_RATE" in ap,
          "硬切是「啪」的一下，像贴图在闪")
    check("B4【核心】翻向钳位，绝不穿过 scale.x = 0",
          "move_toward(_facing_x, 0.0" in ap
          and "signf(_facing_x) != signf(_facing_target)" in ap,
          "穿过零的那一帧整层压扁成一条线，视觉爆闪")
    check("B4b 实际缩放写到 _facing.scale",
          "_facing.scale = Vector2(sx, sy)" in ap,
          "翻转发生在朝向层（与受击形变一次性合成，见 S 组）")
    check("B4c 朝向容器为空时防御",
          "if _facing != null" in ap, "缺节点不崩")

    # ---------------- C 组·冲锋轨迹 ----------------
    print("\n== C 组·冲锋轨迹 ==")
    check("C0a 能提取 _track_advance", func_body(src, "func _track_advance(")
          is not None, "scripts/battle/battle_unit.gd")
    ta = func_body(src, "func _track_advance(") or ""
    check("C1【核心】推进时记账轨迹",
          "if state == State.ADVANCE:" in src and "_track_advance()" in src,
          "只有 position 变化时看着像滑步")
    check("C1b 轨迹节点已建且命名（探针按名字取）",
          '_charge_trail.name = "ChargeTrail"' in bv
          and "_charge_trail = Line2D.new()" in bv,
          "无命名 → 探针 get_node 取不到，测了个寂寞")
    check("C2 点数封顶（remove_at 截断）",
          "CHARGE_TRAIL_MAX" in ta and "remove_at(0)" in ta,
          "否则一条无限长的线扫过整个战场")
    check("C2b 站定不记新点",
          "distance_squared_to(_last_pos) < 1.0" in ta and "return" in ta,
          "原地微抖也画线")
    check("C3【核心】轨迹会淡出",
          "_charge_trail.default_color.a" in ap and "delta * 1.2" in ap,
          "站定后就该消失，不能永久拖一条线")
    check("C3b 记账时把 alpha 拉回（与淡出配对）",
          "_charge_trail.default_color.a = 0.55" in ta,
          "在推进时保持可见")
    check("C4 CHARGE_TRAIL_MAX 常量有定义",
          "const CHARGE_TRAIL_MAX" in src, "探针按此常量判封顶")

    # ---------------- D 组·阵亡演出 ----------------
    print("\n== D 组·阵亡演出 ==")
    check("D0a 能提取 _play_death", func_body(src, "func _play_death(")
          is not None, "scripts/battle/battle_unit.gd")
    pd = func_body(src, "func _play_death(") or ""
    check("D1【核心】_play_death 让朝向层歪倒",
          '"rotation"' in pd and "_facing" in pd,
          "原来只有沉下去+缩小+淡出，方向是抽象的 —— 是「消失」不是「倒下」")
    check("D1b 倒地 tween 有缓动（不是线性）",
          "Tween.TRANS_QUAD" in pd and "Tween.EASE_IN" in pd,
          "顺着力矩加速扑倒才有重量感")
    check("D1c 倒地角度用常量（可调且被探针锁）",
          "DEATH_FALL_ANGLE" in pd and "const DEATH_FALL_ANGLE" in src,
          "0.42 弧度 ≈ 24°")
    check("D2 倒地方向随 _facing_x（不许随机挑方向）",
          re.search(r"_facing_x\s*\*\s*DEATH_FALL_ANGLE", pd) is not None,
          "朝右打 +0.42 = 顺时针前扑；朝左则 -0.42")
    check("D2b 注释写明 Godot 2D 旋转方向（防后人改成后仰）",
          "y 轴朝下" in pd, "正 rotation = 顺时针 = 向前扑")

    td = func_body(src, "func take_damage(") or ""
    check("D0b 能提取 take_damage", bool(td), "scripts/battle/battle_unit.gd")
    # 【本轮最重要的判据】判定顺序：阵亡必须在溃散**之前**，且判完就 return。
    # 【血泪】不能用 `td.find("_begin_rout()")` 取首次匹配 —— 本函数注释里
    # 就写着「走 _begin_rout() 就 return」，那个词出现在 1891，比真正的
    # 调用（2232）还早 → 判据把注释当代码，恒假红。
    # 正解：逐行扫描、**跳过注释行**，只取真正的调用位置。
    die_i = rout_i = -1
    for ln in td.split("\n"):
        st = ln.strip()
        if st.startswith("#"):
            continue
        if rout_i == -1 and "_begin_rout()" in st:
            rout_i = 1
        if "_die(false)" in st and die_i == -1:
            die_i = 0 if rout_i == -1 else 1
    check("D3【核心·本轮最重要】take_damage 先判阵亡再判溃散",
          die_i == 0 and rout_i == 1,
          "原式先判溃散并 return → 血量见底那一击必然先崩士气 → 永远到不了 _die")
    check("D3b 阵亡分支必须 return（不给溃散留机会）",
          re.search(r"if hp <= 0\.0 or count <= 0:\s*\n\s*_die\(false\)\s*\n\s*return",
                    td) is not None,
          "全灭就是全灭，不该再走溃散")
    check("D3c 注释说明了这个顺序为什么重要",
          "永远到不了 _die" in td or "静默退场" in td,
          "防后人\"好心\"改回先判溃散")

    # ---------------- S 组·受击形变 ----------------
    print("\n== S 组·受击形变 ==")
    rf = func_body(src, "func _refresh_flash(") or ""
    check("S0a 能提取 _refresh_flash", bool(rf), "scripts/battle/battle_unit.gd")
    # 【血泪】_refresh_flash 的**注释**里就写着「已在 _apply_impulse 合成」
    # 和 `HIT_SQUASH` / `_facing.scale` 这些词 → 直接 in 全文会误判。
    # 正解：只看**非注释行**（复用 battle_logic 那课的教训）。
    rf_code = "\n".join(ln for ln in rf.split("\n")
                         if not ln.strip().startswith("#"))
    check("S1【核心】形变收敛在 _apply_impulse 而非 _refresh_flash",
          "HIT_SQUASH" not in rf_code
          and "_facing.scale" not in rf_code,
          "tick 顺序是 _refresh_flash → _apply_impulse（最后统一合成到本体），"
          "在 _refresh_flash 里写会被后面的 _facing.scale.x 整个覆盖")
    check("S1b _apply_impulse 里朝向+形变一次性合成",
          re.search(r"var sx := _facing_x \* \(1\.0 - HIT_SQUASH_X", ap)
          is not None,
          "分两次写会被后者覆盖 —— 这是本函数既有的设计约定")
    check("S2【核心】形变必须乘 _facing_x（否则挨打会篡改朝向）",
          "_facing_x * (1.0 - HIT_SQUASH_X" in ap,
          "漏乘则朝左的部队挨一下就被静默重置为朝右")
    check("S3 两个形变常量都有定义",
          "const HIT_SQUASH_X" in src and "const HIT_SQUASH_Y" in src,
          "0.18 压扁 / 0.12 微涨；再大就变橡皮糖")
    pd2 = func_body(src, "func _play_death(") or ""
    check("S4【核心】阵亡时形变清零",
          "_facing.scale = Vector2(_facing_x, 1.0)" in pd2,
          "_dead 置真后 _refresh_flash 直接 return，不清零就会定格在"
          "最后一次压扁量上、跟着倒地一起歪")
    check("S4b 注释说明了为何要清零",
          "压扁量" in pd2, "防后人当冗余删掉")

    # ---------------- Z 组·存档 ----------------
    print("\n== Z 组·存档 ==")
    check("Z1 本校验不写玩家存档",
          not any(k in src for k in ("_save(", "save_game", "write_save")),
          "本脚本只读不写；存档指纹见反向验证 Z2")

    fails = [n for n, ok in results if not ok]
    print("")
    if fails:
        print("[FAIL] %d 项未通过：%s" % (len(fails), fails))
        return 1
    print("[PASS] 战斗演出强化接线全部锁定 ✅（%d 项）" % len(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
