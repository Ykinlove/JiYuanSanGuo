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
    """I1 删掉 turn_in 里的 _grant_reward_items 调用（字节级锚点）
    ★ 锚点函数名用运行期拼接：避免本注入脚本自己成为判据的「消费者」
      （判据 B1 扫 quest_service.gd，不扫本文件，但同名拼接更保险）。
    """
    p = P_QUEST
    b = m[p]
    crlf = b.count(b"\r\n") == b.count(b"\n")
    nl = b"\r\n" if crlf else b"\n"
    fn = ("_grant_reward" + "_items").encode("ascii")
    tgt = b"\t" + fn + b"(rewards, parts)" + nl
    if tgt not in b:
        return False, "锚点未命中（crlf=%s）" % crlf
    writeb(p, b.replace(tgt, b"", 1))
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
    """I4 删掉 from_dict 里的 _restore_int_keys（存档往返会丢当日额度）

    ★ 锚点写法：按**字节**构造，不在字符串里混 \\n / \\r\\n 两种形态。
      首版用 `tgt.replace("\\n", nl)` 处理行尾，结果 \\r\\n 里的 \\n 也被换成 \\r\\r\\n，
      锚点永远不命中 —— 症状是「注入未生效」而不是明确的锚点报错，极易误判成判据功效不足。
      现在直接 rb 读、拼 bytes、wb 写，行尾是 CRLF 还是 LF 都不影响。
    """
    p = P_GS
    b = m[p]
    crlf = b.count(b"\r\n") == b.count(b"\n")
    nl = b"\r\n" if crlf else b"\n"
    n = 0
    # ★ 左边是**字段名**（craft_today/ad_today/exchange_today），右边才是临时变量（_ct/_at/_et）。
    #   首版把左边也写成临时变量名 ⇒ 锚点永远不命中，症状是 SKIP 而非明确报错。
    for field, var in ((b"craft_today", b"_ct"), (b"ad_today", b"_at"),
                       (b"exchange_today", b"_et")):
        tgt = b"\t" + field + b" = _restore_int_keys(" + var + b") if " + var \
            + b" is Dictionary else {}"
        if tgt not in b:
            return False, "锚点 %s 未命中（crlf=%s）" % (field.decode(), crlf)
        b = b.replace(tgt, b"\t" + field + b" = " + var + b" if " + var
                      + b" is Dictionary else {}", 1)
        n += 1
    writeb(p, b)
    return True, "替换 %d 处" % n


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
    """I6 删掉广告冷却写入（字节级锚点 + 运行期拼键名）"""
    p = P_ECON
    b = m[p]
    crlf = b.count(b"\r\n") == b.count(b"\n")
    nl = b"\r\n" if crlf else b"\n"
    key = ("ad_" + "claimed").encode("ascii")
    tgt = b"\tGameState." + key + b"[tier_id] = GameState.total_days()" + nl
    if tgt not in b:
        return False, "未找到冷却写入锚点（crlf=%s）" % crlf
    writeb(p, b.replace(tgt, b"", 1))
    return True, ""


def m_craft_partial_deduct(m):
    """I7 锻造改成「边扣边发现不够」—— 玩家会白丢材料（字节级锚点）

    ★ 字节字面量只能含 ASCII：中文注释必须 .encode("utf-8")，
      直接写在 b"..." 里是 SyntaxError（不是运行期错误，会让整个反向脚本起不来）。
    """
    p = P_CRAFT
    b = m[p]
    crlf = b.count(b"\r\n") == b.count(b"\n")
    nl = b"\r\n" if crlf else b"\n"
    note = "\t# [INJECT] 守卫被削弱：不再全量校验材料".encode("utf-8")
    old = nl.join([
        b'\tvar gate := can_craft(item6_id)',
        b'\tif not bool(gate.get("ok", false)):',
        ('\t\treturn {"ok": false, "msg": str(gate.get("reason", "不可锻造"))}').encode("utf-8"),
    ])
    if old not in b:
        old2 = b'\tvar gate := can_craft(item6_id)'
        if old2 not in b:
            return False, "未找到 can_craft 守卫锚点（crlf=%s）" % crlf
        i = b.find(old2)
        seg_end = i + len(old2)
        for _ in range(3):
            j = b.find(nl, seg_end)
            if j < 0:
                return False, "守卫段不完整"
            seg_end = j + len(nl)
        writeb(p, b[:i] + note + nl + b[seg_end:])
        return True, "按行删除守卫"
    new = note + nl + b'\tvar gate := {"ok": true, "reason": ""}'
    writeb(p, b.replace(old, new, 1))
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
    """I9 删掉开新档的清空（同样按字节处理，理由同 I4）"""
    p = P_GS
    b = m[p]
    crlf = b.count(b"\r\n") == b.count(b"\n")
    nl = b"\r\n" if crlf else b"\n"
    parts = [b"\tcraft_today = {}", b"\tad_today = {}",
             b"\tad_claimed = {}", b"\texchange_today = {}"]
    tgt = nl.join(parts)
    if tgt not in b:
        return False, "开新档清空锚点未命中（crlf=%s）" % crlf
    b2 = b.replace(tgt, "\t# [INJECT] 新档清空被删".encode("utf-8"), 1)
    writeb(p, b2)
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
