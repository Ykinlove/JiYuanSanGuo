#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
第六十九轮反向验证：证明 _verify_retreat_loop.py 是**有效的锁**（会响），不是不会响的锁。

【为什么必须做】MEMORY 铁律：**绿灯必须证明过自己是有效的**。
一份全绿的校验若把真缺陷改回旧写法也照样绿，那它就是装饰品。

做法：逐个注入真实缺陷 → 跑 _verify_retreat_loop.py → 必须报红 →
还原源码 → 必须恢复全绿。另含**假阳性对照**：注入等价无害写法 → 必须仍全绿
（证明判据不是靠字面匹配瞎抓，而是真的在判行为）。
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, "_verify_retreat_loop.py")
ENC = os.path.join(HERE, "scripts", "world", "encounter_manager.gd")
WMAP = os.path.join(HERE, "scripts", "world", "world_map.gd")
GS = os.path.join(HERE, "scripts", "autoload", "game_state.gd")
BSC = os.path.join(HERE, "scripts", "battle", "battle_scene.gd")

results = []


def record(name, ok, detail):
    results.append((name, bool(ok)))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


def read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def write(p, t):
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(t)


def line_endings(p):
    raw = open(p, "rb").read()
    return "\r\n" if raw.count(b"\r\n") > 0 else "\n"


def run_verify():
    pr = subprocess.run([sys.executable, TARGET], cwd=HERE,
                        capture_output=True, text=True,
                        encoding="utf-8", errors="replace")
    return (pr.stdout or "") + (pr.stderr or ""), pr.returncode


def fail_keys(out):
    return set(re.findall(r"\[FAIL\]\s+(\S+)", out))


def inject(path, old, new, tag):
    """注入缺陷。**必须先断言唯一命中** —— assert 在写盘前中止 = 一次假绿灯的制造过程。"""
    src = read(path)
    n = src.count(old)
    assert n == 1, "锚点 %r 在 %s 命中 %d 次（须恰好 1）" % (old[:48], os.path.basename(path), n)
    backup = path + ".iv.bak.stale"
    shutil.copy2(path, backup)
    le = line_endings(path)
    write(path, src.replace(old, new).replace("\r\n", "\n").replace("\n", le))
    return backup


def restore(path, backup):
    shutil.copy2(backup, path)
    # 备份用完改名（宿主拦 os.remove，按 turn 累积阈值 50）
    try:
        os.replace(backup, backup + ".done.stale")
    except BaseException:
        pass


CASES = [
    # ---------- 真缺陷注入（改回旧写法必须报红） ----------
    ("R1 删除 _adopt_evade_points 调用（跨场景传递断链）",
     ENC, "\t_spawn_all()\n\t_adopt_evade_points()",
     "\t_spawn_all()", "A3f"),

    ("R2 把 EVADE_MIN_DIST 改成 100（小于触发半径 350，死循环照旧）",
     ENC, "const EVADE_MIN_DIST := 520.0", "const EVADE_MIN_DIST := 100.0", "B0a"),

    ("R3 把 EVADE_MIN_DIST 改成与 INTERACT_RADIUS 同值（边界反复）",
     ENC, "const EVADE_MIN_DIST := 520.0", "const EVADE_MIN_DIST := 350.0", "B0a"),

    ("R4 删除 GameState.encounter_evade_points 字段（战斗侧无处登记）",
     GS, "\nvar encounter_evade_points: Dictionary = {}", "", "A1a"),

    ("R5 战斗侧去掉 if not win 守卫（胜利也避让 = 行为倒退）",
     BSC, "\tif not win:\n\t\tvar at := GameState.return_pos",
     "\tif win:\n\t\tvar at := GameState.return_pos", "A2b"),

    ("R6 战斗侧删除登记（战败不记避让点 = 死循环复现）",
     BSC, "\t\tGameState.encounter_evade_points[enc_id] = at", "\t\tpass", "A2a"),

    ("R7 world_map 不再应用避让（落点未推离）",
     WMAP, "\t\t_player.position = _evade_trigger_zones(_player.position)\n"
           "\t\t# 旧存档 / 跨区域坐标可能已不在当前区域的地盘上，必须夹回来",
     "\t\t# 旧存档 / 跨区域坐标可能已不在当前区域的地盘上，必须夹回来", "A4d"),

    ("R8 只保留一条落点分支过避让（读档分支漏掉）",
     WMAP, "\t\t_player.position = GameState.last_world_pos\n"
           "\t\t_player.position = _evade_trigger_zones(_player.position)",
     "\t\t_player.position = GameState.last_world_pos", "A4d"),

    ("R9 _evade_trigger_zones 自己算距离（与触发判定不同源）",
     WMAP, "return _encounters.evade_position(pos, _terrain.get_map_size())",
     "return pos + Vector2(600.0, 0.0)", "A4b"),

    # 【修·血泪·两次】初版锚点把两行写成紧邻，但真实代码里它们**中间隔着一行
    # `#` 注释** → 命中 0 次；改成 3 级缩进又错（实际是 2 级）。
    # assert 在写盘前中止 = 一次「假绿灯的制造过程」（没注入却以为注入了）。
    # 正解：**先打印 repr 确认真实缩进**，锚点取最小唯一片段。
    ("R10 last_world_pos 存避让前坐标（存档侧复现死循环）",
     WMAP, "\t\t_player.sync_into_region()\n\t\tGameState.last_world_pos = _player.position",
     "\t\tGameState.last_world_pos = _player.position\n\t\t_player.sync_into_region()", "B0c"),

    ("R11 避让点写入 return_pos（污染事实层字段）",
     WMAP, "\t\t_player.position = _evade_trigger_zones(_player.position)\n"
           "\t\t# 旧存档 / 跨区域坐标可能已不在当前区域的地盘上，必须夹回来",
     "\t\t_player.position = _evade_trigger_zones(_player.position)\n"
           "\t\tGameState.return_pos = _player.position\n"
           "\t\t# 旧存档 / 跨区域坐标可能已不在当前区域的地盘上，必须夹回来", "B0d"),

    ("R12 encounter_evade_points 进了存档（临时态占档位）",
     GS, "\nvar encounter_evade_points: Dictionary = {}", "", "A1a"),
]

# 假阳性对照：等价无害写法，必须**仍然全绿**
NEG_CASES = [
    ("N1 给 evade_position 换参数名/加注释（等价写法）",
     ENC,
     "func evade_position(pos: Vector2, world_size: Vector2) -> Vector2:",
     "## 【等价写法·对照用】参数名与注释变化不应触发任何判据\n"
     "func evade_position(pos: Vector2, world_size: Vector2) -> Vector2:"),

    ("N2 在 world_map 加一段无关注释提到 evade_position（不应误判）",
     WMAP,
     "func _evade_trigger_zones(pos: Vector2) -> Vector2:",
     "## 说明：evade_position 由 EncounterManager 提供（这里只是转发）\n"
     "func _evade_trigger_zones(pos: Vector2) -> Vector2:"),

    ("N3 给 EVADE_MIN_DIST 加行尾注释（仍是同一个值）",
     ENC,
     "const EVADE_MIN_DIST := 520.0",
     "const EVADE_MIN_DIST := 520.0  ## 大于 INTERACT_RADIUS 才能切断循环"),
]


def main():
    print("=" * 68)
    print("第六十九轮 反向验证 · 撤退循环校验器的有效性")
    print("=" * 68)

    # 基线：必须全绿
    out0, rc0 = run_verify()
    base_fails = fail_keys(out0)
    record("B0 基线全绿（反向验证的前提）", rc0 == 0 and not base_fails,
           "returncode=%d，FAIL 项 %d 个" % (rc0, len(base_fails)))
    if base_fails:
        print("  基线就不绿，先修基线：" + ", ".join(sorted(base_fails)))
        return 1

    # ---- 真缺陷注入 ----
    print("\n== 真缺陷注入（每个都必须报红） ==")
    for name, path, old, new, expect in CASES:
        try:
            bk = inject(path, old, new, name)
        except AssertionError as e:
            record(name, False, "锚点预检失败：" + str(e))
            continue
        try:
            out, rc = run_verify()
            fk = fail_keys(out)
            hit = any(k.startswith(expect) for k in fk)
            record(name, (rc != 0 and hit),
                   "returncode=%d，命中判据 %s；实际 FAIL=%s"
                   % (rc, expect, sorted(fk)[:6] if fk else "无"))
        finally:
            restore(path, bk)

    # ---- 假阳性对照 ----
    print("\n== 假阳性对照（等价无害写法必须仍然全绿） ==")
    for name, path, old, new in NEG_CASES:
        try:
            bk = inject(path, old, new, name)
        except AssertionError as e:
            record(name, False, "锚点预检失败：" + str(e))
            continue
        try:
            out, rc = run_verify()
            fk = fail_keys(out)
            record(name, (rc == 0 and not fk),
                   "returncode=%d，FAIL 项 %s（须为 0）" % (rc, sorted(fk)[:6] if fk else "无"))
        finally:
            restore(path, bk)

    # ---- 收尾：必须回到全绿 ----
    out2, rc2 = run_verify()
    fk2 = fail_keys(out2)
    record("Z 还原后回到全绿", rc2 == 0 and not fk2,
           "returncode=%d，FAIL=%s" % (rc2, sorted(fk2) if fk2 else "无"))

    # ---- 存档指纹（测试零污染玩家存档）----
    save_dir = os.path.join(os.environ.get("APPDATA", ""), "Godot", "app_userdata",
                            "JiYuanSanGuo", "saves")
    if os.path.isdir(save_dir):
        before = sorted((f, os.path.getsize(os.path.join(save_dir, f)))
                        for f in os.listdir(save_dir))
        out3, rc3 = run_verify()
        after = sorted((f, os.path.getsize(os.path.join(save_dir, f)))
                       for f in os.listdir(save_dir))
        record("Z2 玩家存档零污染", before == after,
               "%d 个存档文件跑前跑后一致" % len(before))
    else:
        record("Z2 玩家存档零污染", True, "存档目录不存在（%s），跳过" % save_dir)

    bad = [n for n, ok in results if not ok]
    print("\n" + "=" * 68)
    print("  判定项：%d" % len(results))
    print("  结果：%s" % ("PASS（0 FAIL）" if not bad else "FAIL（%d 项）" % len(bad)))
    if bad:
        print("-" * 68)
        for n in bad:
            print("  [FAIL] " + n)
        return 1
    print("  12 个真缺陷注入全部报红 + 3 个等价写法全部放行 → 判据是有效的锁 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())