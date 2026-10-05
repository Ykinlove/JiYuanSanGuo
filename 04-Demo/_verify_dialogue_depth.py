# -*- coding: utf-8 -*-
"""第十六轮 主线/支线剧情深写 —— 静态复核。
仅校验『提质』后的结构性不变量（不依赖备份，可独立复跑）：
  A. 节点总数恒为 193（原 192 减去死数据节点 menghuo_quest，再加第七十四轮
     新增且已接线的 mj_ch1_start，详见下方 A 项注释）
  B. 本次扩写的 33 个节点 lines>=4 且字数较扩写前明显提升（均值门槛）
  C. 全库「普通节点」最薄节点仍 >=89（回归护栏：不产生新薄节点）
  D. 括号/引号配对全绿；next 悬空=0
  E. 动态令牌范围合规：{quest}/{quest_goal} 仅出现在 _pending/_turnin；其余令牌均属白名单
扩写时只改 lines，speaker/options/next/id 零改；本脚本用 D/E 覆盖接线完整性。"""
import json
import re
import sys

PATH = "assets/data/dialogues.json"

# 本轮扩写的节点（主线 13 章节过场 + 支线 20 人物知识/闲聊）
EXPANDED = [
    # 主线：章节过场
    "mj_ch1_start",
    "mj_ch1_end", "mj_ch2_start", "mj_ch2_end", "mj_ch3_start", "mj_ch3_end",
    "mj_ch4_start", "mj_ch4_end", "mj_ch5_start", "mj_ch5_end", "mj_ch6_start",
    "mj_ch6_end", "mj_ch7_start", "mj_ch7_end",
    # 支线：人物知识/闲聊
    "zhouyu_lore", "wutugu_lore", "zhaoyu_lore", "yicheng_lore", "menghuo_lore",
    "zhudawang_lore", "mentor_liming_lore", "mentor_yangzixuan_lore",
    "mentor_yangleipeng_lore", "yushi_lore", "jinhuan_lore", "scout_lore",
    "liubei_lore", "lusu_lore", "han_envoy_lore", "zhuge_lore", "jianggan_lore",
    "strategist_lore", "historian_lore", "bamen_lore",
]

# 扩写前「other」桶（非 mj、非 quest 记忆节点）字数均值基线
BASELINE_OTHER_MEAN = 134.7

TOK_WHITELIST = {"name", "guohao", "capital", "year", "faction", "quest", "quest_goal"}


def chars(n):
    return sum(len(l) for l in n.get("lines", []))


def cat(id_):
    if "_pending" in id_ or "_turnin" in id_:
        return "quest_mem"
    if "_intro" in id_:
        return "quest_intro"
    if id_.startswith("mj_"):
        return "mj"
    return "other"


def fail(msg):
    print("  [FAIL] " + msg)
    sys.exit(1)


def main():
    d = json.load(open(PATH, encoding="utf-8"))
    by = {n["id"]: n for n in d}

    # A. 节点总数
    # 193 =原 192（已减去死数据节点 menghuo_quest，该节点是 menghuo_lore 的
    # 重复副本，从未被任何 next 指向、也无 NPC 以其为对话根，玩家永远看不到）
    #       + 第七十四轮新增的 mj_ch1_start。
    #
    # 【为什么加这个节点（不是删旁白去迁就旧数字）】实测取证：二~七章每一章
    # 都有 _start 旁白并由 on_quest_completed → chapter_intro_flag 排期，
    # **唯独第一章的 mj_ch1_start 从来没有任何代码排期过**，玩家从 intro
    #（落脚南中）直接进第一章（打黄巾），中间缺「中平元年末·广宗战前」
    # 这一拍铺垫。补数据侧的同时补了接线（MainlineService.schedule_ch1_start
    # 由 dialogue_ui 的 flag_intro 调用 + world_map 消费队列），
    # 因此这不是死数据，是**可达**节点。
    if len(d) != 193:
        fail("节点总数 %d != 193" % len(d))

    # B. 扩写节点提质：lines>=4 且字数门槛
    for nid in EXPANDED:
        if nid not in by:
            fail("扩写节点缺失: %s" % nid)
        n = by[nid]
        if len(n.get("lines", [])) < 4:
            fail("%s lines<4 (%d)" % (nid, len(n["lines"])))
        if chars(n) < 110:
            fail("%s 字数偏薄 %d (<110)" % (nid, chars(n)))
    expanded_mean = sum(chars(by[x]) for x in EXPANDED) / len(EXPANDED)
    print("  [OK] 扩写节点 %d 个，lines 均>=4，扩写后均值 %.1f 字" % (len(EXPANDED), expanded_mean))

    # C. 普通节点回归护栏：最薄 >=89 且全库无 lines<3 且字数<50 的薄节点
    other = [n for n in d if cat(n["id"]) == "other"]
    other_mean = sum(chars(n) for n in other) / len(other)
    thinnest = min(chars(n) for n in other)
    if thinnest < 89:
        fail("普通节点最薄 %d < 89（产生新薄节点）" % thinnest)
    if other_mean < 145:
        fail("普通节点均值 %.1f < 145（未达提质门槛，基线 %.1f）" % (other_mean, BASELINE_OTHER_MEAN))
    print("  [OK] 普通节点均值 %.1f（基线 %.1f，提升 %.1f）| 最薄 %d"
          % (other_mean, BASELINE_OTHER_MEAN, other_mean - BASELINE_OTHER_MEAN, thinnest))
    thin = [n["id"] for n in d if len(n.get("lines", [])) < 3 and chars(n) < 50]
    if thin:
        fail("存在薄节点: %s" % thin)

    # D. 括号/引号配对（字符串拼接后统计）
    text = "".join(l for n in d for l in n.get("lines", []))
    for a, o in [("（", "）"), ("“", "”"), ("「", "」"), ("『", "』")]:
        if text.count(a) != text.count(o):
            fail("括号/引号不配对 %s%s : 开%d 闭%d" % (a, o, text.count(a), text.count(o)))
    print("  [OK] 括号/引号配对全绿")

    # next 悬空
    ids = set(by.keys())
    dangling = []
    for n in d:
        for opt in n.get("options", []):
            nx = opt.get("next", "")
            if nx and nx not in ids:
                dangling.append((n["id"], nx))
    if dangling:
        fail("next 悬空: %s" % dangling)
    print("  [OK] next 悬空 = 0")

    # E. 令牌范围
    bad = []
    for n in d:
        scope_ok = n["id"].endswith("_pending") or n["id"].endswith("_turnin")
        blob = n.get("lines", []) + [o.get("text", "") for o in n.get("options", [])]
        for l in blob:
            for m in re.findall(r"\{([^{}]*)\}", l):
                if m not in TOK_WHITELIST:
                    bad.append((n["id"], m))
                if m in ("quest", "quest_goal") and not scope_ok:
                    bad.append((n["id"], "令牌越界:" + m))
    if bad:
        fail("令牌异常: %s" % bad)
    print("  [OK] 动态令牌范围合规（{quest*}} 仅限 _pending/_turnin）")

    print("\n[PASS] 第十六轮 主线/支线剧情深写 静态复核通过 ✅")


if __name__ == "__main__":
    main()
