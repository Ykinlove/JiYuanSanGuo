# -*- coding: utf-8 -*-
"""物品经济判据的反向验证（第七十五轮）

**绿灯必须证明过自己是有效的。** 本脚本把被测逻辑逐处改坏，
确认 _verify_item_economy.py 真的会报红 —— 而不是无论怎么改都全绿。

注入清单（每条对应一个真实缺陷模式）：
  I1  删掉 turn_in 里的 _grant_reward_items 调用   ⇒ B1 报红
  I2  商城塞进材料（违反 cat≠1/8 红线）          ⇒ A4 + 探针 A3 报红
  I3  看广告档塞进装备（违反防刷红线）            ⇒ A5 + 探针 A4 报红
  I4  删掉 from_dict 里的 _restore_int_keys        ⇒ 探针 H2/H3/H5 FAIL
  I5  任务奖励 id 改成不存在的 999999              ⇒ A7b + A8 报红
  I6  删掉 ad_claimed 冷却写入                     ⇒ 探针 E6/E6b FAIL
  I7  锻造改成「扣一部分料再发现不够」              ⇒ 探针 D8b FAIL
  I8  从 exchange 删掉一批材料（覆盖率跌破 95%）   ⇒ A9 报红
  I9  删掉开新档的清空                              ⇒ B12 报红

★ 反向验证的两条铁律（MEMORY）：
  ① 注入脚本里**不得留被注入对象的完整名字字面量** ——
     否则注入脚本自己成了判据的「消费者」，用例 100% 漏放。
     本文件用运行���拼接（如 "ad_" + "claimed"）绕开。
  ② 样本必须真落在判据的扫描范围内 —— 判据扫 *_verify_*.py 就不能把样本放别处。
     本轮判据扫源码 .gd 与数据 .json，注入都在这两处，符合。
"""
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = HERE
GODOT = r"D:/Godot/Godot_v4.7.2-stable_win64_console.exe"
VERIFY = os.path.join(HERE, "_verify_item_economy.py")

P_QUEST = os.path.join(HERE, "scripts", "services", "quest_service.gd")
P_CRAFT = os.path.join(HERE, "scripts", "services", "craft_service.gd")
P_ECON = os.path.join(HERE, "scripts", "services", "item_economy_service.gd")
P_GS = os.path.join(HERE, "scripts", "autoload", "game_state.gd")
P_DATA = os.path.join(HERE, "assets", "data", "item_economy.json")
P_QDATA = os.path.join(HERE, "assets", "data", "quests.json")

BACKUP_SUFFIX = ".revbak"


def readb(p):
    with open(p, "rb") as f:
        return f.read()


def writeb(p, b):
    with open(p, "wb") as f:
        f.write(b)


def backup(paths):
    made = []
    for p in paths:
        if os.path.exists(p + BACKUP_SUFFIX):
            os.remove(p + BACKUP_SUFFIX)
        shutil.copy2(p, p + BACKUP_SUFFIX)
        made.append(p)
    return made


def restore(paths):
    for p in paths:
        b = p + BACKUP_SUFFIX
        if os.path.exists(b):
            os.replace(b, p)


def run_verify():
    p = subprocess.run([sys.executable, VERIFY], capture_output=True, cwd=ROOT,
                       encoding="gbk", errors="replace", timeout=600)
    out = p.stdout or ""
    return p.returncode, out


def failed_tags(out):
    """从校验器输出里抽出 FAIL 标签。"""
    tags = []
    for ln in out.splitlines():
        if "[FAIL]" in ln:
            m = re.search(r"\[FAIL\]\s+(\S+)", ln)
            if m:
                tags.append(m.group(1))
    return tags


TARGETS = [P_QUEST, P_CRAFT, P_ECON, P_GS, P_DATA, P_QDATA]

RESULTS = []


def case(tag, expect_substr, paths, mutate, restore_first=True):
    """跑一次注入 → 跑判据 → 恢复。"""
    backup(paths)
    try:
        raw_before = {p: readb(p) for p in paths}
        ok, info = mutate({p: readb(p) for p in paths})
        if not ok:
            RESULTS.append((tag, "SKIP", info))
            return
        for p, nb in ((paths, None),):
            pass
        # mutate 返回新内容（注入器自行写盘）
        # 判「anchor 失败」：若内容与改前完全一致，说明注入没生效
        unchanged = [p for p in paths if readb(p) == raw_before[p]]
        if unchanged:
            RESULTS.append((tag, "FAIL-注入未生效", "锚点未命中：" + str(unchanged)))
            return
        rc, out = run_verify()
        tags = failed_tags(out)
        hit = any(expect_substr in t for t in tags)
        if rc != 0 and hit:
            RESULTS.append((tag, "PASS", "报红项含「%s」，共 %d 项" % (expect_substr, len(tags))))
        else:
            RESULTS.append((tag, "FAIL-判据功效不足",
                            "returncode=%d 红项=%s（期望含 %s）" % (rc, tags[:6], expect_substr)))
    finally:
        restore(paths)


def m_quest_no_grant(m):
    """I1 删掉 turn_in 里的 _grant_reward_items 调用"""
    p = P_QUEST
    s = m[p].decode("utf-8")
    tgt = "\t_grant_reward_items(rewards, parts)\n"
    if "\r\n" in s:
        tgt = tgt.replace("\n", "\r\n")
    if s.count(tgt) != 1:
        return False, "锚点数=%d" % s.count(tgt)
    s2 = s.replace(tgt, "", 1)
    if s2 == s:
        return False, "替换后无变化"
    writeb(p, s2.encode("utf-8"))
    return True, ""


def m_mall_add_material(m):
    """I2 商城塞材料：用运行时拼接构造 id 字段名，避免本脚本成为消费者"""
    p = P_DATA
    d = json.loads(m[p].decode("utf-8"))
    # 拼接字段名，不写字面量
    k = "item" + "_id"
    if d["mall"]["goods"][0][k] in (1, 8):
        return False, "首个商品已是材料"
    d["mall"]["goods"][0][k] = 1     # 木头 = 材料
    writeb(p, json.dumps(d, ensure_ascii=False, indent=2).encode("utf-8"))
    return True, ""


def m_ad_add_equip(m):
    """I3 广告档塞装备"""
    p = P_DATA
    d = json.loads(m[p].decode("utf-8"))
    k = "item" + "_id"
    t = d["reward_ad"]["tiers"][0]
    if not t.get("items"):
        t["items"] = []
    t["items"].append({k: 136, "count": 1})   # 轩辕剑 = 武器
    writeb(p, json.dumps(d, ensure_ascii=False, indent=2).encode("utf-8"))
    return True, ""


def m_gs_drop_restore(m):
    """I4 删掉 from_dict 里的 _restore_int_keys（存档往返会丢当日额度）"""
    p = P_GS
    s = m[p].decode("utf-8")
    nl = "\r\n" if "\r\n" in s else "\n"
    for v in ("_ct", "_at", "_et"):
        tgt = "\t%s = _restore_int_keys(_%s) if _%s is Dictionary else {}" % (v, v, v)
        tgt = tgt.replace("\n", nl)
        if tgt not in s:
            return False, "锚点 %s 未命中" % v
        s = s.replace(tgt, "\t%s = _%s if _%s is Dictionary else {}" % (v, v, v), 1)
    writeb(p, s.encode("utf-8"))
    return True, ""


def m_quest_bad_id(m):
    """I5 任务奖励 id 改成不存在的值"""
    p = P_QDATA
    s = m[p].decode("utf-8")
    mm = re.search(r'"items": \[\{"item_id":\s*(\d+)', s)
    if not mm:
        return False, "未找到 items 锚点"
    s2 = s[:mm.start(1)] + "999999" + s[mm.end(1):]
    writeb(p, s2.encode("utf-8"))
    return True, ""


def m_eco_no_cooldown(m):
    """I6 删掉 ad_claimed 冷却写入 —— 运行时拼接，不留完整字面量"""
    p = P_ECON
    s = m[p].decode("utf-8")
    key = "ad_" + "claimed"
    tgt_variants = [
        "\tGameState.%s[tier_id] = GameState.total_days()\n" % key,
        "\tGameState.%s[tier_id] = GameState.total_days()\r\n" % key,
    ]
    for t in tgt_variants:
        if t in s:
            s2 = s.replace(t, "", 1)
            writeb(p, s2.encode("utf-8"))
            return True, ""
    return False, "未找到冷却写入锚点"


def m_craft_partial_deduct(m):
    """I7 锻造改成「边扣边发现不够」—— 玩家会白丢材料"""
    p = P_CRAFT
    s = m[p].decode("utf-8")
    nl = "\r\n" if "\r\n" in s else "\n"
    old = ('\tvar gate := can_craft(item6_id)' + nl
           + '\tif not bool(gate.get("ok", false)):' + nl
           + '\t\treturn {"ok": false, "msg": str(gate.get("reason", "不可锻造"))}')
    if old not in s:
        return False, "未找到 can_craft 守卫锚点"
    # 注入：守卫改为「只看等级与日限次」，材料校验挪到逐项扣料时
    new = ('\t# [INJECT] 守卫被削弱：不再全量校验材料' + nl
           + '\tvar gate := {"ok": true, "reason": ""}')
    s2 = s.replace(old, new, 1)
    writeb(p, s2.encode("utf-8"))
    return True, ""


def m_exchange_drop(m):
    """I8 从 exchange 删掉一批材料，覆盖率跌破阈值"""
    p = P_DATA
    d = json.loads(m[p].decode("utf-8"))
    k = "item" + "_id"
    g = d["exchange"]["goods"]
    if len(g) <= 5:
        return False, "exchange 条目过少"
    del g[:12]        # 删掉前 12 条（多为被配方大量引用的材料）
    writeb(p, json.dumps(d, ensure_ascii=False, indent=2).encode("utf-8"))
    return True, ""


def m_gs_no_newgame_clear(m):
    """I9 删掉开新档的清空"""
    p = P_GS
    s = m[p].decode("utf-8")
    nl = "\r\n" if "\r\n" in s else "\n"
    tgt = "\tcraft_today = {}" + nl + "\tad_today = {}" + nl \
        + "\tad_claimed = {}" + nl + "\texchange_today = {}"
    if tgt not in s:
        return False, "开新档清空锚点未命中"
    s2 = s.replace(tgt, "\t# [INJECT] 新档清空被删", 1)
    writeb(p, s2.encode("utf-8"))
    return True, ""


print("")
print("=" * 64)
print("物品经济判据 · 反向验证（9 注入）")
print("=" * 64)

print("")
print("--- I1 删 turn_in 的物品发放调用 ⇒ 期望 B1 报红")
case("I1 turn_in 不发物品", "B1", [P_QUEST], m_quest_no_grant)

print("--- I2 商城塞进材料 ⇒ 期望 A4 报红")
case("I2 商城混入材料", "A4", [P_DATA], m_mall_add_material)

print("--- I3 广告档塞进装备 ⇒ 期望 A5 报红")
case("I3 广告产出装备", "A5", [P_DATA], m_ad_add_equip)

print("--- I4 删 _restore_int_keys ⇒ 期望探针 H2/H3/H5 报红（表现为 C2 FAIL）")
case("I4 日号键不归一", "C2", [P_GS], m_gs_drop_restore)

print("--- I5 任务奖励 id 悬空 ⇒ 期望 A7b 报红")
case("I5 任务奖励悬空 id", "A7b", [P_QDATA], m_quest_bad_id)

print("--- I6 删广告冷却写入 ⇒ 期望探针 E6 报红（表现为 C2 FAIL）")
case("I6 广告无冷却", "C2", [P_ECON], m_eco_no_cooldown)

print("--- I7 锻造守卫削弱 ⇒ 期望探针 D8b 报红（表现为 C2 FAIL）")
case("I7 锻造边扣边发现", "C2", [P_CRAFT], m_craft_partial_deduct)

print("--- I8 删 12 条集市材料 ⇒ 期望 A9 报红")
case("I8 覆盖率跌破阈值", "A9", [P_DATA], m_exchange_drop)

print("--- I9 删开新档清空 ⇒ 期望 B12 报红")
case("I9 新档不清额度", "B12", [P_GS], m_gs_no_newgame_clear)

# ---- 汇总 ----
print("")
print("=" * 64)
fails = [r for r in RESULTS if r[1] != "PASS"]
for tag, st, info in RESULTS:
    print("  %-6s %-22s %s" % (st.split("-")[0], tag, info[:70]))
print("")
print("反向验证：%d 条，PASS %d，FAIL %d" % (len(RESULTS), len(RESULTS) - len(fails), len(fails)))
if fails:
    for t, st, i in fails:
        print("  !! %s %s —— %s" % (st, t, i))
    print("!! 判据功效不足：上述注入没有让校验报红，绿灯不可信")
print("=" * 64)
sys.exit(1 if fails else 0)
