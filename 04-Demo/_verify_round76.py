#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
第七十六轮校验：用户提 6 项优化（商城入口 / 黑屏载入 / 城池倾斜 / 城名偏离 /
大地图卡顿 / 战斗连续触发）的行为不变量。

背景
----
这 6 项里有 **5 项是"看起来改了、其实没改"或"改一处坏一处"的高危类型**，
本校验逐条钉死真正的不变量：

  A 商城入口
    A1 轮盘 ENTRIES 必须含 action="mall" 且 label="商城"（用户明确要这个入口名）。
    A2 world_map._on_wheel_selected 必须有 mall 分支（加了表项不接分支 =
       点一下只会掉进 `_:` 分支弹「待实装」）。
    A3 EconomyPanel 必须同时注册进 world_map 与 city_scene 的 `_ui_panels`
       —— 漏注册的后果是「面板开着但角色还在跑」，不崩不报错（MEMORY 铁律）。
    A4 摆行逻辑**只有一份**：city_scene 内不得再出现 `_build_market_exchange`
       / `_build_market_mall` / `_build_market_ad`（否则经济规则要改两处）。
    A5 EconomyPanel 不得自建 PanelContainer（必须走 UITheme.make_modal，
       否则成为全工程唯一样式不一致的面板）。

  B 城池倾斜
    B1★ 城池倾斜上限必须**小于**角色倾斜上限（用户反馈「城池都是倾斜的」）。
       两者同值时整图读起来是「歪的」——建筑对倾斜的敏感度远高于人。
    B2 倾斜必须**按节点角色分流**（_apply_slope_tilt 带 is_city 参数），
       绝不能让角色也降到 2.5°（那是矫枉过正：人要站得住）。

  C 城名位置
    C1★ 城名 Label 必须挂在 Art 内（挂 marker 上则不跟随抬升 → 「城名飘在城下面」，
       这正是用户说的「城名和城池不沾边」）。
    C2 城名纵向位置必须由**图标半高**算出，不得写死常数（旧值 y=65 落在
       384px 高图标内部，字压在城墙上）。

  D 场景切换耗时
    D1★ prewarm 必须在**渐黑之前**（写在渐黑之后 = 玩家看到的只剩纯黑屏干等）。
    D2 渐变时长必须显著短于旧值 0.3（这是纯等待，画面已全黑/全亮）。

  E 大地图每帧开销
    E1★ 高度场节流判据必须是**纯比较**（读坐标比坐标），
       且 NPC 缓存必须在 marker 缓存清空处同步失效。
    E2★ 裁剪闸门的快照必须在 `_rebuild_city_markers` 里失效 ——
       否则新区域屏外城池全部常亮（一次性把 110 个 768px 图标塞进渲染管线，
       正是该函数存在的目的所防的填充率爆炸）。
    E3 节流判据**不得**调用有副作用的「判脏」函数（MEMORY 血泪：
       `_static_geometry_dirty()` 被复用会静默架空整个脏标记优化）。

  F 战斗连续触发
    F1★ 撒点必须避让玩家位置（旧实现只避让城池与其它遭遇点，
       新点可能落在玩家脚下 → 站着不动也立刻再触发）。
    F2★ 战斗类触发时必须累加 `_def_resolved`（战斗走 battle_scene 结算，
       永不经过 `_note_resolved` → `RESOLVE_CAP_PER_DEF` 对 21 条 battle
       定义完全失效，可无限刷同一批怪）。
    F3★ 战斗落点必须推离触发点（`return_pos` 存的是"站在遭遇点上"的坐标，
       距离 0 < 触发半径 → 回来必然原地再触发）。
    F4 避让半径必须**大于**触发半径（否则推出去仍在圈内）。

外加：反向验证由 _verify_round76_reverse.py 承担（9 注入）。
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

WM = os.path.join(HERE, "scripts", "world", "world_map.gd")
EM = os.path.join(HERE, "scripts", "world", "encounter_manager.gd")
CM = os.path.join(HERE, "scripts", "world", "city_marker_art.gd")
SR = os.path.join(HERE, "scripts", "autoload", "scene_router.gd")
MW = os.path.join(HERE, "scripts", "ui", "main_menu_wheel.gd")
EP = os.path.join(HERE, "scripts", "ui", "economy_panel.gd")
CITY = os.path.join(HERE, "scripts", "city", "city_scene.gd")

FAILS: list[str] = []
CHECKS = 0


def check(cond: bool, msg: str) -> None:
    global CHECKS
    CHECKS += 1
    if not cond:
        FAILS.append(msg)


def read(path: str) -> str:
    with open(path, "rb") as f:
        return f.read().decode("utf-8")


def strip_comments(src: str) -> str:
    """剥掉整行与行尾注释，避免校验命中解释性注释造成假阳性。

    【本轮特别重要】本轮新增的代码里解释性注释极多（说明根因与取值依据），
    若不剥离，A/B/C/D/E/F 里的字面量判据会大量命中注释 → 判据形同虚设。
    """
    out = []
    for line in src.split("\n"):
        s = line.lstrip()
        if s.startswith("#"):
            out.append("")
            continue
        i = line.find("#")
        out.append(line[:i] if i >= 0 else line)
    return "\n".join(out)


def func_body(src, name):
    """提取函数体（血泪六次踩坑的最终形态，勿简化）。

    1) 只按 {}/} 配对 → 遇 `var x: Dictionary = {}` 立刻归零 → 体被截断
    2) 跳过字符串会被引号搞乱状态
    3) 正则只写 ^func → 匹配不到 static func
    4)【本轮新踩】签名**跨行**时（`() -> void:` 换行才结束），
       旧写法 `src.index("\\n", m.end()-1)` 会把**续行**当成函数体第一行，
       于是体被截成签名残片（本轮 `_apply_slope_tilt` 提取到 33 字符，
       判据据此报出两个根本不存在的缺陷）。
       正解：先做**括号配平**扫过整个签名（含跨行的参数与返回类型），
       配平点之后的第一个换行才是函数体起点。
    故：正则定位 → 括号配平扫签名 → 缩进定界取体。
    """
    m = re.search(r"^(?:static\s+)?func\s+" + re.escape(name) + r"\s*\(",
                  src, re.M)
    if not m:
        return None
    # 从左括号起做配平，跳过字符串字面量（否则 "(" 出现在串里会配平错位）
    i = src.index("(", m.end() - 1)
    depth = 0
    j = i
    n = len(src)
    while j < n:
        ch = src[j]
        if ch == '"':
            j += 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == "\\" else 1
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                break
        j += 1
    # 配平点之后：吃掉返回类型（`-> void:`）直到行尾，才是真正的体起点
    nl = src.find("\n", j)
    if nl < 0:
        return None
    rest = src[nl + 1:]
    lines = rest.split("\n")
    body = []
    base = None
    for ln in lines:
        if ln.strip() == "":
            body.append(ln)
            continue
        ind = len(ln) - len(ln.lstrip("\t"))
        if base is None:
            base = ind
        if ind < base:
            break
        body.append(ln)
    return "\n".join(body)


def const_val(src: str, name: str):
    """取 `const NAME := 3.14` 的数值。取不到返回 None（而不是 0 ——
    0 是合法值，用它当"没取到"会掩盖真实缺陷）。"""
    m = re.search(r"^const\s+" + re.escape(name) + r"\s*:?=\s*([0-9.eE+-]+)",
                  src, re.M)
    return float(m.group(1)) if m else None


def main() -> int:
    for p in (WM, EM, CM, SR, MW, EP, CITY):
        if not os.path.exists(p):
            print("[FATAL] 缺文件：%s" % p)
            return 2
    wm = strip_comments(read(WM))
    em = strip_comments(read(EM))
    cm = strip_comments(read(CM))
    sr = strip_comments(read(SR))
    mw = strip_comments(read(MW))
    ep = strip_comments(read(EP))
    city = strip_comments(read(CITY))

    # ---------------- A 商城入口 ----------------
    entries = re.search(r"const\s+ENTRIES\s*:=\s*\[(.*?)\n\]", mw, re.S)
    check(entries is not None, "A0 轮盘 ENTRIES 表解析失败（结构变了？）")
    if entries:
        blk = entries.group(1)
        check('"action": "mall"' in blk or '"action":"mall"' in blk,
              "A1★ 轮盘缺 action=mall 入口（用户明确要入口名「商城」）")
        mm = re.search(r'"action"\s*:\s*"mall".*?"label"\s*:\s*"([^"]*)"', blk)
        check(mm is not None and mm.group(1) == "商城",
              "A1★ 商城入口名不是「商城」，实为 %r"
              % (mm.group(1) if mm else None))
        check(mm is not None and '"glyph"' in blk.split('"mall"')[1][:120],
              "A1b 商城入口缺 glyph（缺图时无回退字形）")

    wheel_sel = func_body(wm, "_on_wheel_selected")
    check(wheel_sel is not None, "A2 _on_wheel_selected 提取失败")
    if wheel_sel:
        check('"mall"' in wheel_sel,
              "A2★ 轮盘无 mall 分派（加了表项不接分支 = 点一下弹「待实装」）")
        check("_economy" in wheel_sel.split('"mall"')[-1][:200],
              "A2b mall 分支未打开 _economy")

    check("EconomyPanel" in wm, "A3 world_map 未引用 EconomyPanel")
    check("EconomyPanel" in city, "A3b city_scene 未引用 EconomyPanel")
    wm_panels = func_body(wm, "_ready")
    check(wm_panels is not None and "_economy" in wm_panels.split("_ui_panels")[1][:400]
          if wm_panels and "_ui_panels" in wm_panels else False,
          "A3★ world_map 的 _ui_panels 未登记 _economy"
          "（漏登记 = 面板开着但角色还在跑，不崩不报错）")
    city_panels = func_body(city, "_ready")
    check(city_panels is not None and "_economy" in city_panels.split("_ui_panels")[1][:400]
          if city_panels and "_ui_panels" in city_panels else False,
          "A3c★ city_scene 的 _ui_panels 未登记 _economy")

    for dead in ("_build_market_exchange", "_build_market_mall",
                 "_build_market_ad"):
        check(dead not in city,
              "A4★ city_scene 仍留 %s —— 摆行逻辑出现第二份真源" % dead)
    check("_do_exchange" not in city and "_do_buy_mall" not in city,
          "A4b city_scene 仍留交易回调（规则一改要改两处）")
    check("_open_economy" in city, "A4c 城内市场面板无「打开商城」入口")

    check("make_modal" in ep,
          "A5★ EconomyPanel 未走 UITheme.make_modal（样式不一致的面板）")
    check("PanelContainer.new()" not in ep,
          "A5b EconomyPanel 自建 PanelContainer，绕过了统一卡片样式")
    check("ItemEconomyService" in ep, "A6 EconomyPanel 未读服务层（等于自带真源）")
    check("item_economy.json" not in ep,
          "A6b EconomyPanel 直读 json 绕过服务层（两份定价真源）")
    check("TOUCH_H" in ep or "UITheme.button" in ep,
          "A7 EconomyPanel 按钮未走 UITheme 工厂（触控高度可能不足 84）")
    # 【判据修正·血泪】A7b 首版写成"全文件不得出现 custom_minimum_size"，
    # 结果命中 _add_hint 里 **Label** 的那一句 —— 控件类型不同，语义完全不同：
    # Label 撑高是为了自动换行不断字，Button 覆写高度才是第五十三轮那种回退
    # （按钮被压回 74px，手指点不准）。判据必须只盯 Button。
    _add_row_body = func_body(ep, "_add_row") or ""
    check("custom_minimum_size" not in _add_row_body,
          "A7b EconomyPanel 的 _add_row 在 UITheme.button 之后覆写了 "
          "custom_minimum_size（第五十三轮同款回退：按钮高度被压回 74）")
    check(re.search(r"UITheme\.button\(", _add_row_body) is not None,
          "A7c _add_row 未走 UITheme.button 工厂")

    # ---------------- B 城池倾斜 ----------------
    city_tilt = const_val(cm, "CITY_MAX_TILT_DEG")
    role_tilt = const_val(wm, "MAX_TILT_DEG")
    check(city_tilt is not None, "B0 读不到 CITY_MAX_TILT_DEG")
    check(role_tilt is not None, "B0b 读不到 MAX_TILT_DEG")
    if city_tilt is not None and role_tilt is not None:
        check(city_tilt < role_tilt,
              "B1★ 城池倾斜未小于角色倾斜（城 %.1f° / 角色 %.1f°）"
              "—— 建筑对倾斜的敏感度远高于人，同值时整图读起来是「歪的」"
              % (city_tilt, role_tilt))
        check(city_tilt <= 4.0,
              "B1b★ 城池倾斜仍偏大（%.1f° > 4°），用户反馈「城池都是倾斜的」未解决"
              % city_tilt)
        check(role_tilt >= 10.0,
              "B2★ 角色倾斜被一并降到 %.1f° —— 矫枉过正，人物会站不住" % role_tilt)

    tilt_fn = func_body(wm, "_apply_slope_tilt")
    check(tilt_fn is not None, "B2b _apply_slope_tilt 提取失败")
    if tilt_fn:
        check("is_city" in tilt_fn,
              "B2c★ 倾斜未按节点角色分流（无法只降城、不降人）")
        # 【判据修正】不能用 `"MAX_TILT_DEG" in tilt_fn` 判"引用了角色上限"：
        # `CityMarkerArt.CITY_MAX_TILT_DEG` 里也含 `MAX_TILT_DEG` 子串，
        # 两种写法都命中同一条件 → 判据恒真、形同虚设。
        # 必须用**词边界**：只认独立的裸标识符 MAX_TILT_DEG。
        check(re.search(r"(?<![A-Za-z0-9_])MAX_TILT_DEG(?![A-Za-z0-9_])",
                        tilt_fn) is not None,
              "B2d 倾斜函数未引用角色上限 MAX_TILT_DEG（分流未真正生效）")
        check("CITY_MAX_TILT_DEG" in tilt_fn,
              "B2d-b 倾斜函数未引用城池上限 CITY_MAX_TILT_DEG")

    apply_h = func_body(wm, "_apply_height")
    check(apply_h is not None and "_is_city_node" in apply_h,
          "B2e★ _apply_height 未按节点角色分流（城池恒走角色上限）")
    check("_is_city_node" in wm, "B2f 缺 _is_city_node 判定函数")

    tilt_fn2 = func_body(em, "apply_tilt")
    if tilt_fn2:
        check("CITY_MAX_TILT_DEG" in tilt_fn2,
              "B3 CityMarkerArt.apply_tilt 未用城专用上限")

    # ---- 死代码：_apply_city_tilt 必须遍历真源缓存 ----
    ac = func_body(wm, "_apply_city_tilt")
    check(ac is not None, "B4 _apply_city_tilt 提取失败")
    if ac:
        check("_marker_cache" in ac,
              "B4★ _apply_city_tilt 仍在遍历 _city_markers —— "
              "第六十八轮起该容器已空，本函数是死代码（零次迭代且不报错）")
        check("_city_markers" not in ac,
              "B4b _apply_city_tilt 仍引用 _city_markers（空容器）")

    # ---------------- C 城名位置 ----------------
    cm_fn = func_body(wm, "_create_marker")
    check(cm_fn is not None, "C0 _create_marker 提取失败")
    if cm_fn:
        # 【判据两次修正·血泪】
        # ① 按 `label.add_child` 切段取末段：代码写的是 `art_host.add_child(label)`
        #    字面不匹配；而**注释里**恰好有 `marker.add_child(label)`（说明旧实现），
        #    切分点落在注释上 → 判出一个根本不存在的缺陷。
        #    故必须用正则锚定代码，且依赖 strip_comments 已剥注释。
        # ② 改用 findall[-1] 后仍报错：真实代码里**确实**有 `marker.add_child(label)`，
        #    但它在 `else:` 降级分支里（无 Art 的旧调用方）——那是**有意的正确设计**，
        #    不是缺陷。教训：判据必须判「**主路径**走哪条」，而不是「出现过哪条」。
        #    这里的"主路径" = `if art_host != null:` 那一支。
        _adds = re.findall(r"(\w+)\.add_child\(\s*label\s*\)", cm_fn)
        main_path = re.search(
            r"if\s+art_host\s*!=\s*null\s*:(.*?)\n\s*else\s*:", cm_fn, re.S)
        check(main_path is not None,
              "C1★ 城名挂载无「有 Art 走 Art / 无 Art 降级」的两分支结构"
              "（判据无法确认主路径）")
        if main_path is not None:
            check(re.search(r"art_host\.add_child\(\s*label\s*\)",
                            main_path.group(1)) is not None,
                  "C1★ 主路径未把城名挂进 Art —— 挂 marker 则不跟随抬升，"
                  "即用户说的「城名和城池不沾边、偏离太远」")
            check(re.search(r"marker\.add_child\(\s*label\s*\)",
                            main_path.group(1)) is None,
                  "C1b★ 主路径仍把城名挂 marker（Art 存在却不跟随）")
        check("art_host" in cm_fn and "marker.add_child(label)" in cm_fn,
              "C1c 降级分支缺失（旧调用方会拿不到城名）")
        check("CityMarkerArt.icon_half_height" in cm_fn,
              "C2★ 城名纵向位置未由图标半高算出（写死常数会随素材/缩放档位错位）")
        check(not re.search(r"label\.position\s*=\s*Vector2\(\s*-?\d+\s*,\s*65\s*\)",
                            cm_fn),
              "C2b★ 城名仍写死 y=65（旧值落在 384px 高图标内部，字压在城墙上）")
        check("CITY_NAME_GAP" in cm_fn, "C2c 城名间距未走常量（换素材时要改两处）")
    check("func icon_half_height" in cm,
          "C3 CityMarkerArt 缺 icon_half_height 出口")

    # ---------------- D 场景切换耗时 ----------------
    goto = func_body(sr, "goto")
    check(goto is not None, "D0 goto 提取失败")
    if goto:
        # 【判据两次补强·由反向验证 I6 逼出来】
        # 首版只判「prewarm 存在」+「prewarm 在渐黑之前」，
        # 注入把 prewarm **挪到渐黑之后**仍报绿 —— 因为判据取的是
        # `find` 的**首次**出现位置；注入后函数里仍有一个 prewarm 在渐黑前
        # （那就是被移到渐黑后的那一个的残留），位置比较失去意义。
        # 正解：判**唯一一次** prewarm 调用的位置，且要求它出现在
        # 渐黑语句**之前**且两者之间**没有 await** ——
        # 有 await 就意味着已经进入黑屏等待。
        pre_positions = [m.start() for m in
                         re.finditer(r"^\s*prewarm\(scene_key\)\s*$", goto, re.M)]
        check(len(pre_positions) == 1,
              "D1★ goto 内 prewarm 调用应恰好一次，实为 %d 次"
              "（多处预热或零处预热都是接线问题）" % len(pre_positions))
        fade = goto.find('tween_property(_overlay, "color:a", 1.0')
        check(fade >= 0, "D1b 渐黑语句消失（结构变了？）")
        if pre_positions and fade >= 0:
            p0 = pre_positions[0]
            check(p0 < fade,
                  "D1c★ prewarm 写在渐黑之后 —— 预热收益归零，"
                  "玩家看到的只剩纯黑屏干等一整轮 load")
            between = goto[p0:fade]
            check("await" not in between,
                  "D1d★ prewarm 与渐黑之间存在 await —— 说明已经进入黑屏等待，"
                  "预热再快玩家也只看到黑屏（这正是原实现的病根）")
    fade_t = const_val(sr, "FADE_TIME")
    check(fade_t is not None, "D2 读不到 FADE_TIME")
    if fade_t is not None:
        check(fade_t <= 0.2,
              "D2★ 渐变仍为 %.2fs —— 这是纯等待（画面已全黑/全亮），"
              "用户反馈「黑屏等待太长」未解决" % fade_t)
    check("prewarm_battle_chain" in sr, "D3 缺对战链路预热（切 4 次场景各付一次首载）")
    check("prewarm_battle_chain" in wm,
          "D3b world_map 未触发链路预热（函数存在但没人调 = 死代码）")
    check("goto(scene_key, 0.3" not in sr and "goto(scene_key, 0.3," not in sr,
          "D3c goto_fresh 仍硬写 0.3（旧值未被常量统一）")

    # ---------------- E 每帧开销 ----------------
    uhf = func_body(wm, "_update_height_field")
    check(uhf is not None, "E0 _update_height_field 提取失败")
    if uhf:
        check("_player_last_pos" in uhf,
              "E1★ 玩家高度/坡度未按坐标节流（站桩时每帧白算 "
              "FastNoiseLite 采样 + 4 次法线差分）")
        npc_seg = uhf.split("get_npc_nodes")
        if len(npc_seg) >= 2:
            npc = npc_seg[-1]
            check("_npc_height_pos" in npc,
                  "E1b★ NPC 高度未按坐标节流（NPC 是静态实体，"
                  "每帧重算与坐标无关 ⇒ 纯浪费）")
        check("GroundShadow.follow" in uhf,
              "E1c 影子跟随被节流掉了（影子必须每帧跟，它是接地的唯一证据）")
    check("_npc_height_pos" in wm and "_npc_height_done" in wm,
          "E1d 缺 NPC 高度缓存字段")

    cull = func_body(wm, "_cull_offscreen")
    check(cull is not None, "E2 _cull_offscreen 提取失败")
    if cull:
        check("_cull_last_center" in cull and "_cull_last_zoom" in cull,
              "E2★ 裁剪无「视野未变则跳过」闸门（玩家站定时每帧 110 次"
              "has_point 判定结果完全相同）")
        gate = cull.split("return")
        check(len(gate) >= 2 and "for nd in _marker_cache" in cull,
              "E2b 闸门存在但遍历段丢失（提前 return 写错位置）")
    check("_cull_last_zoom = -1.0" in wm,
          "E2c★ 裁剪闸门快照无失效点（切区后屏外城池全部常亮 → "
          "一次性把 110 个 768px 图标塞进渲染管线）")
    rebuild = func_body(wm, "_rebuild_city_markers")
    check(rebuild is not None and "_cull_last_zoom = -1.0" in rebuild,
          "E2d★ _rebuild_city_markers 未失效裁剪快照"
          "（新 marker 默认 visible=true，闸门会跳过整段裁剪）")

    # 节流判据不得调用有副作用的「判脏」函数（MEMORY 血泪）
    for bad, where in (("_static_geometry_dirty", "world_map"),
                       ("_static_geometry_dirty", "economy_panel")):
        check(bad not in (wm if where == "world_map" else ep),
              "E3★ %s 里出现了有副作用的判脏函数 %s"
              "（复用它会静默架空整个节流优化）" % (where, bad))

    # ---------------- F 战斗连续触发 ----------------
    spawn_all = func_body(em, "_spawn_all")
    check(spawn_all is not None, "F0 _spawn_all 提取失败")
    if spawn_all:
        # 【判据补强·由反向验证 I7 逼出来】首版只判「出现 SPAWN_PLAYER_GAP」，
        # 注入把条件改成 `if false and ...` 后**仍报绿** —— 常量还在，
        # 只是永远不成立。存在性 ≠ 语义（MEMORY 判据六禁之一）。
        # 正解：抽出避让那一条 if 的**完整条件文本**，逐项断言它真的
        # 包含「距离比较」且**没有被短路成恒假**。
        m = re.search(
            r"if\s+([^\n]*?_player[^\n]*?)\\\s*\n\s*([^\n]*?):\s*\n\s*continue",
            spawn_all)
        cond = (m.group(1) + " " + m.group(2)) if m else ""
        check(m is not None,
              "F1★ 撒点缺「与玩家距离过近则 continue」的判定"
              "（新点可能落在脚下 → 站着不动也立刻再触发，"
              "这是「战斗接连触发」第一来源）")
        if m:
            check("false" not in cond.lower(),
                  "F1b★ 玩家避让条件被短路成恒假（注入向）：%r" % cond.strip())
            check("distance_to(_player.position)" in cond.replace(" ", ""),
                  "F1c★ 玩家避让条件缺距离比较：%r" % cond.strip())
            check("SPAWN_PLAYER_GAP" in cond,
                  "F1d★ 玩家避让未用 SPAWN_PLAYER_GAP（阈值散落在别处 = "
                  "换半径要改多处）：%r" % cond.strip())
            check("is_instance_valid(_player)" in cond,
                  "F1e 玩家避让未做实例有效性守卫")
    gap = const_val(em, "SPAWN_PLAYER_GAP")
    radius = const_val(em, "INTERACT_RADIUS")
    check(gap is not None, "F4 读不到 SPAWN_PLAYER_GAP")
    if gap is not None and radius is not None:
        check(gap > radius,
              "F4★ 撒点避让半径 %.0f 未大于触发半径 %.0f"
              "（落在圈内等于没避）" % (gap, radius))
        check(gap >= radius * 2.0,
              "F4b 避让半径 %.0f 偏小（应 ≥ 触发半径两倍 %.0f，"
              "否则新点糊在玩家脚下）" % (gap, radius * 2.0))

    trig = func_body(em, "_trigger")
    check(trig is not None, "F2 _trigger 提取失败")
    if trig:
        battle_seg = trig.split('"battle"')
        check("_def_resolved" in trig,
              "F2★ 战斗类触发不累加 _def_resolved —— 战斗走 battle_scene 结算、"
              "永不经过 _note_resolved，RESOLVE_CAP_PER_DEF 对 21 条 battle "
              "定义完全失效（可无限刷同一批怪）")
        check("_triggered_ids[enc_id] = true" in trig,
              "F2b 战斗类丢失防重复标记（本场防抖）")

    trig_cb = func_body(wm, "_on_encounter_triggered")
    check(trig_cb is not None, "F3 _on_encounter_triggered 提取失败")
    if trig_cb:
        check("_encounter_world_pos" in trig_cb,
              "F3★ 战斗落点未推离触发点（return_pos 存的是"
              "「站在遭遇点上」的坐标，距离 0 < 触发半径 → 回来必然原地再战）")
        check("_encounter_world_pos" in wm and "BATTLE_RETURN_OFFSET" in wm,
              "F3b 缺落点推离的实现（常量或反查函数缺失）")
        check(re.search(r"return_pos\s*=\s*_player\.position", trig_cb) is None,
              "F3c★ 落点仍直接存玩家坐标（战斗触发点本身）")
    off = const_val(wm, "BATTLE_RETURN_OFFSET")
    if off is not None and radius is not None:
        check(off > radius,
              "F4c★ 战后落点偏移 %.0f 未大于触发半径 %.0f（推出去仍在圈内）"
              % (off, radius))
    check("func node_position" in em,
          "F5 EncounterManager 缺 node_position（大地图若自己遍历就是第二份真源）")

    # ---------------- 汇总 ----------------
    print("=" * 62)
    print("第七十六轮校验：商城入口 / 载入 / 城池 / 卡顿 / 战斗触发")
    print("=" * 62)
    print("检查项：%d" % CHECKS)
    if FAILS:
        print("失败 %d 项：" % len(FAILS))
        for m in FAILS:
            print("  [FAIL] %s" % m)
        return 1
    print("[OK] 全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
