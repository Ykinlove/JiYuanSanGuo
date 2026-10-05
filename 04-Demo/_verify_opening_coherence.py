# -*- coding: utf-8 -*-
"""第七十四轮 · 开场旁白连贯性判据

本轮修的是什么（都是实测取证后的真缺陷，不是主观口味）：
  A. **mj_ch1_start 此前根本不存在** —— 二~七章每章都有 _start 旁白并被
     on_quest_completed排期，唯独第一章没有。玩家从 intro（落脚南中）
     直接进第一章（打黄巾），中间缺「中平元年末·广宗战前」这一拍。
  B. **补了节点还不够** —— 数据侧有了节点，若没有代码排期它就是死数据，
     玩家永远看不到（与第十六轮删掉的 menghuo_quest 同类症状）。
     故判据必须锁「数据存在 + 有代码消费」两侧，缺一即HIT。
  C. **主角身份基线断链** —— intro 与 intro_goals 立了「南中 + 猎户」
     两条基线，但 ch2~ch7 原文再未提及， 主角的地理坐标在整条主线上消失。
  D. **纪年体例不统一** —— intro 用「中平元年」（史书纪年），
     ch2~ch6 原文用「公元 189 年」（现代纪年）。混排会让玩家觉得年份乱。

所以本判据分两组（性质不同才能交叉保护）：
  A 组数据层：节点存在、speaker 正确、章首成对、基线回扣、纪年统一
  B 组接线层：MainlineService 有排期/消费函数、dialogue_ui 调用排期、
    world_map 消费并入队 —— 判「位置」而非「存在性」
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
# 【铁律】_verify_*.py 一律放04-Demo 根目录，故 ROOT 就是 HERE。
# 写成 dirname(HERE) 会错位到仓库上一级 ⇒ FileNotFoundError。
ROOT = HERE
DIA = os.path.join(ROOT, 'assets', 'data', 'dialogues.json')
SVC = os.path.join(ROOT, 'scripts', 'services', 'mainline_service.gd')
UI = os.path.join(ROOT, 'scripts', 'ui', 'dialogue_ui.gd')
WMAP = os.path.join(ROOT, 'scripts', 'world', 'world_map.gd')

FAILS = []
N = [0]


def check(name, cond, detail=""):
    N[0] += 1
    tag = "PASS" if cond else "FAIL"
    if not cond:
        FAILS.append(name)
    print("  [%s] %s :: %s" % (tag, name, detail))


def read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def code_only(text):
    """剔除整行注释与行尾注释 —— 判据把注释当代码是本项目反复踩的坑。"""
    out = []
    for ln in text.split("\n"):
        s = ln.strip()
        if s.startswith("#"):
            continue
        out.append(ln.split("  #")[0] if "  #" in ln else ln)
    return "\n".join(out)


def main():
    print("=" * 72)
    print("第七十四轮 · 开场旁白连贯性判据（数据层 + 接线层双向）")
    print("=" * 72)
    # 【崩溃防护】数据文件语法坏掉时，本判据必须**报红**而不是抛异常。
    # 【为什么必须加】反向验证 I1 首跑时，我的注入删节点留下了尾逗号，
    # json.load直接抛 JSONDecodeError ⇒ 判据一行都没跑 ⇒ returncode=1
    # 但红项列表为空。**这比假绿更危险**：调用方（反向验证）只能看到
    # 「非零退出码」就以为「判据报红了」，实际是判据崩了。
    # ⇒ 判据必须把「数据读不出来」本身表达成一条 FAIL。
    try:
        nodes = json.load(open(DIA, encoding="utf-8"))
    except Exception as e:
        check("A0 剧本文件可解析（语法坏掉时本判据须报红而非崩溃）",
              False, "读取/解析失败：%s: %s" % (type(e).__name__, e))
        print()
        print("=" * 72)
        print("判定项：%d" % N[0])
        print("结果：FAIL（数据不可解析，后续判项未执行）")
        return 1
    check("A0 剧本文件可解析（语法坏掉时本判据须报红而非崩溃）",
          True, "节点数 = %d" % len(nodes))

    by = {n["id"]: n for n in nodes}
    ids = set(by)

    # ================= A 组：数据层
    # A1 第一章章首节点必须存在
    check("A1 第一章章首旁白 mj_ch1_start 存在",
          "mj_ch1_start" in ids,
          "缺失 = 玩家从 intro 直接跳到打黄巾，中间无铺垫")

    # A2 全部 7 章的 _start 都得存在（成对，不允许再有单侧）
    missing_start = ["mj_ch%d_start" % k for k in range(1, 8)
                     if "mj_ch%d_start" % k not in ids]
    missing_end = ["mj_ch%d_end" % k for k in range(1, 8)
                   if "mj_ch%d_end" % k not in ids]
    check("A2 七章的 _start / _end 全部成对存在",
          not missing_start and not missing_end,
          "缺 _start=%s 缺 _end=%s" % (missing_start or "无",
                                       missing_end or "无"))

    # A3 章首旁白的 speaker 必须是旁白
    bad_spk = [k for k in range(1, 8)
               if ("mj_ch%d_start" % k) in ids
               and by["mj_ch%d_start" % k].get("speaker") != "旁白"]
    check("A3 章首旁白 speaker 均为「旁白」",
          not bad_spk, "speaker 不对= %s" % (bad_spk or "无"))

    # A4 体量下限：章首旁白少于 5 行撑不起「铺垫」二字
    thin = ["mj_ch%d_start" % k for k in range(1, 8)
            if ("mj_ch%d_start" % k) in ids
            and len(by["mj_ch%d_start" % k].get("lines") or []) < 5]
    check("A4 章首旁白均 >= 5 行（撑得起铺垫）",
          not thin, "过薄= %s" % (thin or "无"))

    # A5 ★ 基线回扣：七章章首**每章**都要提到「南中」——
    # 这条锁的是「主角的地理坐标不能在主线上消失」
    #
    # 【判据自纠·两轮】① 首版阈值「允许 <=3 章不提」是拍脑袋定的，
    # 反向验证 I4 删掉一处后完全放过（实测本来就1 章不提，删一处变2 章，
    # 仍在阈值内）—— **留余量必然功效不足**。
    # ② 收紧到 <=2 后仍留 1 处余量，继续是功效不足。
    # 正解：**先把数据补齐到 7/7 全覆盖，再把阈值定为 0**。
    # 这样「删任意一处」都必然跨过阈值 —— 阈值由数据实测支撑，不是猜的。
    no_nanzhong = []
    for k in range(1, 8):
        nid = "mj_ch%d_start" % k
        if nid not in ids:
            continue
        txt = "".join(by[nid].get("lines") or [])
        if "南中" not in txt:
            no_nanzhong.append(nid)
    check("A5★ 七章章首每章都回扣「南中」（主角坐标不断链）",
          not no_nanzhong,
          "未提南中的章：%s（阈值 0；某一章不回扣，玩家就会觉得"
          "主角凭空出现在中原）" % (no_nanzhong or "无"))

    # A6 ★ 纪年体例统一：ch2~ch7 章首首句必须用史书纪年（中平X年/建安X年/初平X年）
    # 而不是「公元 189 年」这种现代纪年混排
    bad_year = []
    for k in range(2, 8):
        nid = "mj_ch%d_start" % k
        if nid not in ids:
            continue
        first = (by[nid].get("lines") or [""])[0]
        # 首句须含史书纪年词，且不得开篇就是「公元 N 年」
        has_classic = re.search(r"(中平|初平|建安|延康|黄初)[元一二三四五六七八九十]+年", first)
        starts_modern = re.match(r"^\s*公元\s*\d{3,4}\s*年", first)
        if not has_classic or starts_modern:
            bad_year.append("%s: %s" % (nid, first[:28]))
    check("A6★ 二~七章章首用史书纪年（与 intro 的「中平元年」同体例）",
          not bad_year,
          "不合体例：%s" % ("；".join(bad_year) if bad_year else "无"))

    # A7 intro 里不该出现现代游戏语（龙兴/这方天地等）
    intro_txt = code_only("".join(by["intro"].get("lines") or []))
    modern = ["龙兴", "这方天地", "关卡", "点击", "屏幕", "图标", "主线任务"]
    hit_m = [w for w in modern if w in intro_txt]
    check("A7 开场旁白无现代游戏语",
          not hit_m, "命中：%s" % (hit_m or "无"))

    # A8 开场旁白须保留第二人称「你」（玩家代入的锚点，不能改成第三人称）
    check("A8 开场旁白保留第二人称「你」（代入锚点）",
          "你" in "".join(by["intro"].get("lines") or []),
          "全文无「你」= 玩家被踢出叙事视角")

    # A9 开场旁白仍须有唯一的推进选项（不能把 intro 改成死胡同）
    opts = by["intro"].get("options") or []
    check("A9 开场旁白仍有唯一推进选项且指向 intro_guide",
          len(opts) == 1 and opts[0].get("next") == "intro_guide",
          "opts=%s" % json.dumps(opts, ensure_ascii=False))

    # ================= B 组：接线层
    svc = read(SVC)
    ui = read(UI)
    wmap = read(WMAP)
    svc_c, ui_c, wmap_c = code_only(svc), code_only(ui), code_only(wmap)

    # B1 ★ 排期函数必须存在，且以 static 形式（否则 dialogue_ui 调不到）
    # 【判据自纠·首跑误报】首版正则写成 `schedule_ch1_start\s*\(\s*void`，
    # 而 GDScript 实际签名是 `static func schedule_ch1_start() -> void:`
    # —— 函数名后有**空参数列表**，返回值写成 `-> void`。
    # 正解：`\(\s*\)\s*->\s*void`（空参 + 箭头 + void）。
    # 注意 B4（真正调用它的地方）当时是 PASS 的 —— 两项矛盾即可定位到判据自身。
    check("B1★ MainlineService 有 static schedule_ch1_start（排期入口）",
          re.search(r"static\s+func\s+schedule_ch1_start\s*\(\s*\)\s*->\s*void",
                    svc) is not None,
          "缺失 = 没有代码给 mj_ch1_start 排期 = 死数据")

    # B2消费函数同理
    check("B2★ MainlineService 有 static consume_ch1_start_pending（消费入口）",
          re.search(r"static\s+func\s+consume_ch1_start_pending\s*\(\s*\)", svc)
          is not None,
          "缺失 = 标记置了没人清，会反复重播")

    # B3 pending 标记常量必须存在，且与 flag_intro 排期用的是同一个
    check("B3 pending 标记常量 FLAG_CH1_START_PENDING 存在",
          'FLAG_CH1_START_PENDING := "mj_ch1_start_pending"' in svc,
          "常量名与排期/消费处不一致 = 标记对不上，条件永假")

    # B4 ★ dialogue_ui 必须真的调用排期函数 —— 只定义不调用 = 永远不排期
    check("B4★ dialogue_ui 在 flag_intro 分支调用 schedule_ch1_start",
          re.search(r'"flag_intro"[\s\S]{0,400}?MainlineService\.schedule_ch1_start\s*\(',
                    ui) is not None,
          "flag_intro 是开场收尾的 action，挂在这里才正确；"
          "不调用 = 标记永不置位 = mj_ch1_start 永不播")

    # B5 ★ world_map 必须消费并入队 —— 只消费不入队 = 标记被清掉但没人播
    has_consume = "consume_ch1_start_pending()" in wmap_c
    # 队列调用必须在 consume 之后的同一分支里（判位置而非存在性）
    m = re.search(r"consume_ch1_start_pending\(\)\s*:\s*\r?\n\s*_queue_narration\(\s*\"mj_ch1_start\"",
                  wmap_c)
    check("B5★ world_map 消费标记后立刻入队 mj_ch1_start（判位置）",
          has_consume and m is not None,
          "有consume 无入队 / 入队在别处 = 标记被清掉但旁白被丢弃")

    # B6 队列延迟参数：章首用 1.4s（与二~七章的 _start 同口径），不能是 0
    q = re.search(r"_queue_narration\(\s*\"mj_ch1_start\"\s*,\s*([0-9.]+)", wmap_c)
    check("B6 入队延迟与其它章首同口径（1.4s）",
          q is not None and abs(float(q.group(1)) - 1.4) < 1e-6,
          "实测 %s" % (q.group(1) if q else "未找到"))

    # B7 反向保护：第一章的 _end 消费分支不能被这次改动删掉
    check("B7 反向保护：第一章章末 mj_ch1_end 消费分支仍在",
          re.search(r"consume_ch1_end_pending\(\)\s*:\s*\r?\n\s*_queue_narration\(\s*\"mj_ch1_end\"",
                    wmap_c) is not None,
          "本次只应新增，不得动既有的 ch1_end 链路")

    # B8 反向保护：flag_intro 分支原有的 intro_seen 置位不能被删
    check("B8 反向保护：flag_intro 仍置 intro_seen（防重入）",
          re.search(r'"flag_intro"[\s\S]{0,400}?GameState\.intro_seen\s*=\s*true',
                    ui) is not None,
          "删掉会导致开场剧情反复重播")

    # B9 章首节点不可有 next 指向（它由 world_map 单独排期，
    # 若被 next 串进别的链会出现播放顺序不确定）
    linked = []
    for n in nodes:
        nx = n.get("next")
        if nx == "mj_ch1_start":
            linked.append(n["id"] + "(next)")
        for o in (n.get("options") or []):
            if o.get("next") == "mj_ch1_start":
                linked.append(n["id"] + "(opt)")
    check("B9 mj_ch1_start 不被任何 next 串入（只由 world_map 排期）",
          not linked, "被串入：%s" % (linked or "无"))

    print()
    print("  A 组 数据层：节点成对/ 基线回扣 / 纪年统一 / 开场无现代语 / 代入锚点")
    print("  B 组 接线层：排期→ 置位 → 消费 → 入队，判位置不判存在性")
    print("          + 反向保护（ch1_end 与 intro_seen 不得被本次改动破坏）")
    print()
    print("=" * 72)
    print("判定项：%d" % N[0])
    if FAILS:
        print("结果：FAIL（%d 项）" % len(FAILS))
        for f in FAILS:
            print("  [FAIL] %s" % f)
        return 1
    print("结果：PASS（0 FAIL）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
