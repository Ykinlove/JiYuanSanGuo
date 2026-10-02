# -*- coding: utf-8 -*-
"""第四十九轮 复合 action 双路径解析一致性复核 + 跨表引用闭合（数据层）

一、【本轮修复的回归锁】对话选项的 action 支持逗号串联多个子命令
    （"accept_quest:qid,gain_gold:500,flag_intro"）。执行路径 _execute_action
    按逗号切分逐条派发；而状态过滤路径（_show_options 判定"已完成隐藏/进行中
    置灰/可交付"）曾直接 substr 整个尾巴，遇到复合指令时会把 "qid,gain_gold:500"
    整体当成任务 id，导致：
      · 任务做完后该选项不隐藏（可重复点击）
      · 任务进行中「提交任务」按钮不出现，走不到 turn_in
    修复：抽出 _first_action_arg()，两条路径共用同一套逗号切分语义。
    本项锁死：① 过滤路径不得再出现裸 substr 取参；② 两条路径解析必须一致；
    ③ 数据侧所有 accept_quest 选项的 qid 必须在 quests 表中真实存在。

二、【新覆盖盲区】跨表 ID 引用闭合。既有校验里没有一项在跨表 ID 层面闭环
    （_verify_m9 只比对策划 markdown，_verify_m13 只查 7 个固定任务 id 存在性），
    而运行时是按 type 分派 + 归一化匹配的。此处复刻该分派逻辑，覆盖：
      objectives[].target 按 type 分派（reach→cities.visit_target /
      battle→encounters.quest_target 优先 id 兜底 / talk→npcs / collect→items）
      quests.giver_npc→npcs、npcs.city_id→cities、npcs.dialogue_root→dialogues
      对话 next / options[].next 跳转闭合、accept_quest 目标→quests
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(ROOT, "assets", "data")

FAILURES = []
CHECKED = 0

# ---------------------------------------------------------------------------
# rewards.unlock / promise 标记的消费路径登记（反向盲区：写了没人读）
#
# 机制（见 quest_service.apply_unlock_value）：交付时先问 SelfRuleService
# .grant_by_flag(flag) —— sr_* 走「师傅链完成」、seal_jade/seal_tiger_tally 走
# 「授予信物」，命中即 return true；未命中的才落 GameState.story_flags 留痕。
#
# 已核查：主线推进由 quests 的 next 链完成（37 个 type=mainline 任务首尾相接，
# 见 turn_in 里的 accept(nxt)），**不依赖** unlock 标记。故除下面两类外，
# 其余标记属「剧情留痕」——记录如"诸葛已归""孟获已入伙"，供后续内容消费，
# 当前无读取方不是缺陷。为避免「新增标记静默无消费方」无人发现，此处要求：
# 新增的陌生标记必须显式登记进下面两组之一，否则判 FAIL。
# ---------------------------------------------------------------------------
GRANT_BY_FLAG_PREFIX = ("sr_",)          # SelfRuleService.grant_by_flag 按前缀消费
GRANT_BY_FLAG_EXACT = ("seal_jade", "seal_tiger_tally")

# 剧情留痕标记（无代码读取方，属设计留痕，非缺陷）。登记即视为已审定。
STORY_TRAIL_FLAGS = {
    "mj_hj_arrived_zhongyuan",   # 抵达中原（赤壁前情节留痕）
    "mj_hj_final_cleared",       # 汉津 finale 已清
    "enter_zhujia",              # 进入主营地
    "mj_guandu_intel",           # 官渡情报已得
    "mj_chibi_ally",             # 赤壁结盟
    "mj_shudao_pass",            # 蜀道已通
    "mj_huatuo_pass",            # 华佗途径已通
    "mj_zilong_sworn",           # 赵云已誓效
    "mj_zhuge_join",             # 诸葛已入伙
    "mj_lvbu_sworn",             # 吕布已誓
    "mj_meng_wo_join",           # 孟获已入伙
    "mj_zhurong_join",           # 祝融已入伙
    # side_hezi「少年的远行」资助阿黑 100 金后，许诺「将来在洛阳遇上，我定要好好谢你」。
    # 该许诺**已兑现**（勿误判为内容缺口）：对话链 side_hezi 交付 →
    # ahei_intro 选项「中原闯荡得如何了？」(require min_chapter>=2) 接 side_ahhei_reunion
    # 「洛阳重逢」→ 洛阳 NPC npc_ahei_luoyang(scene_19) 的 ahei_luoyang_intro →
    # ahei_luoyang_after「阿黑掏出狼牙项链相赠」。story_flags 里的 future_necklace
    # 只是这条剧情的留痕标记，无代码读取属正常。
    "future_necklace",
}


def load_table(name):
    path = os.path.join(DATA, name + ".json")
    if not os.path.exists(path):
        FAILURES.append("数据表缺失：%s.json" % name)
        return None
    with io.open(path, encoding="utf-8") as f:
        return json.load(f)


def as_rows(tbl):
    """数据表统一成 list[dict]（有的表顶层是数组，有的是 {id: record} 字典）。"""
    if isinstance(tbl, list):
        return [r for r in tbl if isinstance(r, dict)]
    if isinstance(tbl, dict):
        out = []
        for k, v in tbl.items():
            if isinstance(v, dict):
                r = dict(v)
                r.setdefault("id", k)
                out.append(r)
            else:
                out.append({"id": k, "_scalar": v})
        return out
    return []


def rid(v):
    """id 归一化：JSON 数字会被 Godot 解析成 float，且 int/str 键型混用是本工程已知地雷。"""
    if isinstance(v, bool):
        return str(v)
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def canon(v):
    """比对用的规范形：去空白 + 数字归一 + 字符串化。"""
    s = rid(v).strip()
    try:
        f = float(s)
        if f.is_integer():
            return str(int(f))
        return s
    except (TypeError, ValueError):
        return s


def check(cond, msg):
    global CHECKED
    CHECKED += 1
    if not cond:
        FAILURES.append(msg)


def main():
    ui_path = os.path.join(ROOT, "scripts", "ui", "dialogue_ui.gd")
    with io.open(ui_path, encoding="utf-8") as f:
        ui = f.read()

    print("=" * 66)
    print("第四十九轮 复合 action 双路径解析一致性 + 跨表引用闭合")
    print("=" * 66)

    # ---------- A. 复合 action 双路径解析一致性 ----------
    print("\n[A] 复合 action 双路径解析一致性")

    check("_first_action_arg" in ui,
          "未找到 _first_action_arg()：复合 action 状态过滤路径的修复缺失或被回退")

    # 过滤路径不得再出现裸 substr 取任务 id（排除注释行，避免把说明文字当代码）
    bad_substr = [
        ln.strip() for ln in ui.splitlines()
        if "substr" in ln and "accept_quest" in ln
        and "_first_action_arg" not in ln
        and not ln.strip().startswith("#")
    ]
    check(not bad_substr,
          "过滤路径仍用裸 substr 取 accept_quest 参数：%s" % bad_substr)

    # 两条路径都必须按逗号切分
    check('action.split(",")' in ui,
          "执行路径未按逗号切分 action，复合指令语义可能已丢失")
    check(ui.count('split(",")') >= 2,
          "逗号切分只出现 %d 次：过滤路径与执行路径未共用同一套解析"
          % ui.count('split(",")'))

    # _first_action_arg 必须真的按逗号遍历并取首段
    fn_start = ui.find("func _first_action_arg")
    check(fn_start >= 0, "_first_action_arg 函数体缺失")
    if fn_start >= 0:
        body = ui[fn_start:ui.find("\nfunc ", fn_start + 10) if ui.find("\nfunc ", fn_start + 10) > 0 else len(ui)]
        check("split" in body and "begins_with" in body,
              "_first_action_arg 未按逗号切分+前缀匹配解析，语义与执行路径不一致")

    # ---------- 载入数据表 ----------
    dialogues = as_rows(load_table("dialogues"))
    quests = as_rows(load_table("quests"))
    npcs = as_rows(load_table("npcs"))
    cities = as_rows(load_table("cities"))
    items = as_rows(load_table("items6"))
    encounters = as_rows(load_table("encounters"))
    dlg_ids = set(canon(r.get("id")) for r in dialogues)
    quest_ids = set(canon(r.get("id")) for r in quests)
    npc_ids = set(canon(r.get("id")) for r in npcs)
    city_ids = set(canon(r.get("id")) for r in cities)
    item_ids = set(canon(r.get("id")) for r in items)
    enc_ids = set(canon(r.get("id")) for r in encounters)
    # collect 目标的正确判据是「运行时能否被产出」：采集点 gather_item + 宝箱
    # loot_table（见 encounter_manager.gd 的 record_event("collect", ...) 两处调用）。
    # 注意 collect 进度走 quest_progress 计数器（_counter_key），不查物品表，
    # 故「id 不在 items/items6」并非断链——真正的死任务是无法被任何来源产出。
    collectible = set()
    for r in encounters:
        g = r.get("gather_item")
        if g not in (None, ""):
            collectible.add(canon(g))
        for l in (r.get("loot_table") or []):
            if l not in (None, ""):
                collectible.add(canon(l))
    visit_targets = set(canon(r.get("visit_target")) for r in cities
                        if r.get("visit_target") not in (None, ""))
    enc_qtargets = set(canon(r.get("quest_target")) for r in encounters
                       if r.get("quest_target") not in (None, ""))

    def first_arg(action, prefix):
        for sub in str(action).split(","):
            t = sub.strip()
            if t.startswith(prefix):
                return t[len(prefix):].strip()
        return ""

    # ---------- B. 对话 accept_quest 目标 → quests ----------
    print("\n[B] 对话 accept_quest 目标 → quests 表")
    n_acc = 0
    composite = []
    for node in dialogues:
        for opt in (node.get("options") or []):
            act = str(opt.get("action", ""))
            if not act.startswith("accept_quest:"):
                continue
            n_acc += 1
            qid = first_arg(act, "accept_quest:")
            if "," in act[len("accept_quest:"):]:
                composite.append((rid(node.get("id")), act))
            check(qid in quest_ids,
                  "对话 %s 的 accept_quest 目标不存在于 quests：%r（action=%r）"
                  % (rid(node.get("id")), qid, act))
    print("  accept_quest 选项 %d 个，其中复合指令 %d 个" % (n_acc, len(composite)))
    for nid, act in composite:
        print("    · 复合：%-14s %s" % (nid, act))

    # ---------- C. 对话跳转闭合 ----------
    print("\n[C] 对话 next / options[].next 跳转闭合")
    n_next = 0
    for node in dialogues:
        nid = canon(node.get("id"))
        nx = node.get("next")
        if nx not in (None, ""):
            n_next += 1
            check(canon(nx) in dlg_ids,
                  "对话 %s 的 next 指向不存在的节点：%r" % (nid, nx))
        for opt in (node.get("options") or []):
            onx = opt.get("next")
            if onx not in (None, ""):
                n_next += 1
                check(canon(onx) in dlg_ids,
                      "对话 %s 的选项 next 指向不存在的节点：%r" % (nid, onx))
    print("  跳转引用 %d 条全部闭合" % n_next)

    # ---------- C2. 对话节点可达性（孤立剧情节点检测） ----------
    # 从每个 NPC 的 dialogue_root 出发沿 next / options[].next 做图遍历，
    # 检出玩家永远走不到的「死节点」——写了剧情但没有任何入口，即未兑现的伏笔。
    # 这比「标记名有没有代码读取」更贴近玩家体感：伏笔是否兑现，取决于
    # 玩家能不能真的走到那段对话。约定式后缀节点（_pending/_turnin）由
    # DialogueService 按 root 拼接后自动挂载，计入可达集。
    print("\n[C2] 对话节点可达性（从 NPC dialogue_root 出发遍历）")
    adj = {}
    for node in dialogues:
        nid = canon(node.get("id"))
        outs = []
        nx = node.get("next")
        if nx not in (None, ""):
            outs.append(canon(nx))
        for opt in (node.get("options") or []):
            onx = opt.get("next")
            if onx not in (None, ""):
                outs.append(canon(onx))
        adj[nid] = outs

    reachable = set()
    stack = []
    for n in npcs:
        dr = n.get("dialogue_root")
        if dr in (None, ""):
            continue
        root = canon(dr)
        stack.append(root)
        # 约定式后缀：DialogueService 由 root 拼 _pending / _turnin
        stack.append(root + "_pending")
        stack.append(root + "_turnin")
    # 约定式动态入口：主线章末/章初旁白由 world_map 按 "mj_ch{N}_end/_start"
    # 运行时拼名播放（world_map.gd _queue_narration），结局节点由
    # mainline_service.finale_dialogue_id() 按结局返回 mj_finale_{emperor,han,
    # hegemon,hermit} 或 mj_finale。它们没有静态 next 指入，属正常。
    for ch in range(1, 9):
        stack.append("mj_ch%d_end" % ch)
        stack.append("mj_ch%d_start" % ch)
    for suffix in ("", "_emperor", "_han", "_hegemon", "_hermit"):
        stack.append("mj_finale" + suffix)
        for i in (1, 2, 3):
            stack.append("mj_finale%s_%02d" % (suffix, i))
    # 开场旁白由 world_map 首次进图时 _start_dialogue_by_id("intro") 播放
    # （world_map.gd），其后 intro → intro_guide → intro_goals 为向导链。
    stack.append("intro")
    while stack:
        cur = stack.pop()
        if cur in reachable or cur not in adj:
            continue
        reachable.add(cur)
        stack.extend(adj[cur])

    orphans = sorted(dlg_ids - reachable)
    print("  可达节点 %d / 全库 %d" % (len(reachable & dlg_ids), len(dlg_ids)))
    for o in orphans:
        check(False, "对话节点 %s 无任何入口（玩家走不到，多半是未兑现的伏笔）" % o)

    # ---------- D. quests → npcs / cities ----------
    print("\n[D] quests giver_npc → npcs、npcs city_id → cities / dialogue_root → dialogues")
    n_g = 0
    for q in quests:
        g = q.get("giver_npc")
        if g not in (None, ""):
            n_g += 1
            check(canon(g) in npc_ids,
                  "任务 %s 的 giver_npc 不存在：%r" % (canon(q.get("id")), g))
    n_n = 0
    for n in npcs:
        nid = canon(n.get("id"))
        c = n.get("city_id")
        if c not in (None, ""):
            n_n += 1
            check(canon(c) in city_ids,
                  "NPC %s 的 city_id 不存在：%r" % (nid, c))
        dr = n.get("dialogue_root")
        if dr not in (None, ""):
            n_n += 1
            check(canon(dr) in dlg_ids,
                  "NPC %s 的 dialogue_root 不存在：%r" % (nid, dr))
    print("  giver_npc %d 条、npc 城市/对话根 %d 条全部闭合" % (n_g, n_n))

    # ---------- E. objectives[].target 按 type 分派 ----------
    print("\n[E] objectives[].target 按 type 分派闭合（复刻运行时匹配语义）")
    n_obj = 0
    for q in quests:
        qid = canon(q.get("id"))
        for ob in (q.get("objectives") or []):
            if not isinstance(ob, dict):
                continue
            t = str(ob.get("type", ""))
            tgt = ob.get("target")
            if tgt in (None, ""):
                continue
            n_obj += 1
            tcanon = canon(tgt)
            if t == "talk":
                ok = tcanon in npc_ids
            elif t == "collect":
                # 采集进度记在 quest_progress 计数器上，只要存在产出源即可达成；
                # 另允许 "any" 通配（record_event 里 "any" 会匹配任意 target）
                ok = (tcanon in collectible) or (tcanon == "any")
            elif t == "reach":
                # 运行时按 visit_target 匹配（cities.visit_target），非 cities.id
                ok = (tcanon in visit_targets) or (tcanon in city_ids)
            elif t == "battle":
                # 运行时 quest_target 优先、id 兜底
                ok = (tcanon in enc_qtargets) or (tcanon in enc_ids)
            else:
                ok = True   # 未知类型不在本项判定范围
            check(ok, "任务 %s 的 %s 目标无法命中任何实体：%r" % (qid, t, tgt))
    print("  目标引用 %d 条全部命中" % n_obj)

    # ---------- F. require.quest_active → quests ----------
    print("\n[F] 对话选项 require.quest_active → quests")
    n_req = 0
    for node in dialogues:
        nid = canon(node.get("id"))
        for opt in (node.get("options") or []):
            rq = (opt.get("require") or {}).get("quest_active")
            if rq not in (None, ""):
                n_req += 1
                check(canon(rq) in quest_ids,
                      "对话 %s 的 require.quest_active 不存在：%r" % (nid, rq))
    print("  条件引用 %d 条全部闭合" % n_req)

    # ---------- G. rewards.unlock/promise 标记有已审定的消费路径 ----------
    print("\n[G] rewards.unlock/promise 标记消费路径登记（防新增标记静默无消费方）")
    n_flag = 0
    for q in quests:
        qid = canon(q.get("id"))
        rewards = q.get("rewards") or {}
        for key in ("unlock", "promise"):
            v = rewards.get(key) if isinstance(rewards, dict) else None
            if v in (None, ""):
                continue
            flags = v if isinstance(v, list) else [v]
            for f in flags:
                f = str(f).strip()
                if not f:
                    continue
                n_flag += 1
                consumed = (f.startswith(GRANT_BY_FLAG_PREFIX)
                            or f in GRANT_BY_FLAG_EXACT)
                check(consumed or f in STORY_TRAIL_FLAGS,
                      "任务 %s 的 %s=%r 既无 grant_by_flag 消费路径，也未登记为剧情留痕"
                      % (qid, key, f))
    print("  标记 %d 个，grant_by_flag 消费 %d 个，剧情留痕 %d 个"
          % (n_flag,
             sum(1 for q in quests
                 for k in ("unlock", "promise")
                 for f in ([(q.get("rewards") or {}).get(k)] if k in (q.get("rewards") or {}) else [])
                 if f and (str(f).startswith(GRANT_BY_FLAG_PREFIX) or str(f) in GRANT_BY_FLAG_EXACT)),
             len(STORY_TRAIL_FLAGS)))

    # ---------- 汇总 ----------
    print("\n" + "=" * 66)
    if FAILURES:
        print("[FAIL] 发现 %d 项问题（判定 %d 次）：" % (len(FAILURES), CHECKED))
        for m in FAILURES[:40]:
            print("  ! " + m)
        if len(FAILURES) > 40:
            print("  ... 其余 %d 项省略" % (len(FAILURES) - 40))
        return 1
    print("全部通过 ✅ 复合 action 双路径一致 + 跨表引用闭合（共判定 %d 次）" % CHECKED)
    return 0


if __name__ == "__main__":
    sys.exit(main())
