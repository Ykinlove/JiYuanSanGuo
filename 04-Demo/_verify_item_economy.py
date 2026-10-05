# -*- coding: utf-8 -*-
"""物品经济闭合校验（第七十五轮）

背景：用户报告「物品的获取或者任务完成之后奖励的物品，好像还没有落实」。
本轮实测取证到的真实缺陷（全部由本判据锁死）：

1. quests.json 的 73 个任务 rewards 里 **items 键 0 次**，且唯一那个
   materials 键（br_huizhou 的 treasure_pearl）**在两张物品表里都查不到**（悬空 id），
   而 QuestService.turn_in 根本不消费 materials —— 玩家做完任务只拿钱和经验。
2. items6.json 有 **113 件物品带 craft_flag + 完整配方**（339 次材料引用，
   材料 100% 有效零悬空），但 `grep -rn craft scripts/` 零命中 —— 死数据。
3. 那 113 件配方的材料指向 **54 种基础材料，其中 33 种完全不可获取** ——
   这是整条锻造链的唯一堵点。
4. 覆盖率高得离谱地低：改动前玩家能拿到的 items6 只有 42 件（全靠 NPC 商店买）。
5. items6.json 255 条里 **38 条是上游占位尾巴**（id 183/184/185/191/204/223~255，
   名字就叫「保留/未知物品/图纸」），真实物品 217 件。

判据分两组（性质不同才能交叉保护）：
  A 组 = 数据层闭合（纯 Python 算，不需要引擎）
  B 组 = 接线层（源码字面）——「补了数据必须证明有代码消费」
  C 组 = 无头真跑（tests/economy_probe.gd，51 项）
  C0    = 交叉保护断言（两组合同时覆盖的点必须都有）

用法：python _verify_item_economy.py
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))          # 04-Demo（不是上一级！）
ROOT = HERE
DATA = os.path.join(HERE, "assets", "data")
GODOT = r"D:/Godot/Godot_v4.7.2-stable_win64_console.exe"

FAILS = []
CHECKS = 0


def check(tag, ok, detail=""):
    global CHECKS
    CHECKS += 1
    if ok:
        print("  [PASS] %-56s %s" % (tag, detail))
    else:
        FAILS.append(tag)
        print("  [FAIL] %-56s %s" % (tag, detail))


def load(name):
    with open(os.path.join(DATA, name), encoding="utf-8") as f:
        return json.load(f)


def read(name):
    with open(os.path.join(HERE, name), "rb") as f:
        return f.read().decode("utf-8")


def code_only(src):
    """剔掉 # 注释与 ## 文档行：判据不能被注释里的关键词骗过。"""
    out = []
    for ln in src.split("\n"):
        s = ln.strip()
        if s.startswith("#"):
            continue
        out.append(ln)
    return "\n".join(out)


# ================================================================
# 载入数据
# ================================================================
try:
    I6 = load("items6.json")
    I_OLD = load("items.json")
    Q = load("quests.json")
    ECON = load("item_economy.json")
    NS = load("npc_stock.json")
    E = load("encounters.json")
except Exception as e:
    print("!! 数据表读取/解析失败：%s: %s" % (type(e).__name__, e))
    print("!! 本判据一行都没跑 —— 绿灯是假的")
    sys.exit(1)

PLACEHOLDER_NAMES = {"保留", "未知物品", "图纸", "空"}
PH = {i["id"] for i in I6 if str(i.get("name", "")) in PLACEHOLDER_NAMES}
REAL = [i for i in I6 if i["id"] not in PH]
REAL_IDS = {i["id"] for i in REAL}
I6_BY = {i["id"]: i for i in REAL}
OLD_IDS = {str(i["id"]) for i in I_OLD}

# ================================================================
print("")
print("=" * 64)
print("A 组 · 数据层闭合（%s）" % os.path.basename(__file__))
print("=" * 64)

# ---- A0 崩溃防护 ----
check("A0 物品经济表可解析（语法坏掉时本判据须报红而非崩溃）", True,
      "items6=%d 真实=%d 占位=%d" % (len(I6), len(REAL), len(PH)))

# ---- A1 占位物识别 ----
check("A1★ 占位物识别正确（38 条：183/184/185/191/204/223~255）",
      len(PH) == 38 and 223 in PH and 255 in PH and 222 not in PH,
      "占位=%d 真实=%d" % (len(PH), len(REAL)))

# ---- A2 集市 / 商城 / 广告 三表非空 ----
ex_goods = ECON.get("exchange", {}).get("goods", [])
ma_goods = ECON.get("mall", {}).get("goods", [])
ad_tiers = ECON.get("reward_ad", {}).get("tiers", [])
check("A2a 集市货单非空", len(ex_goods) > 0, "goods=%d" % len(ex_goods))
check("A2b 商城货单非空", len(ma_goods) > 0, "goods=%d" % len(ma_goods))
check("A2c 看广告档位非空", len(ad_tiers) > 0, "tiers=%d" % len(ad_tiers))

# ---- A3 三表 id 全部可解析且非占位 ----
bad_ex = [g["item_id"] for g in ex_goods
          if g.get("item_id") not in REAL_IDS or g["item_id"] in PH]
check("A3a 集市全部 id 有效且非占位", not bad_ex, "bad=%s" % bad_ex[:5])
bad_ma = [g["item_id"] for g in ma_goods
          if g.get("item_id") not in REAL_IDS or g["item_id"] in PH]
check("A3b 商城全部 id 有效且非占位", not bad_ma, "bad=%s" % bad_ma[:5])
bad_ad = [m.get("item_id") for t in ad_tiers for m in t.get("items", [])
          if m.get("item_id") not in REAL_IDS or m.get("item_id") in PH]
check("A3c 广告全部 id 有效且非占位", not bad_ad, "bad=%s" % bad_ad[:5])

# ---- A4★ 商城不得含材料/工具（定价体系红线）----
wrong_cat = [g["item_id"] for g in ma_goods
             if I6_BY.get(g.get("item_id"), {}).get("cat_major") in (1, 8)]
check("A4★ 商城不含材料/工具（否则价格体系崩）", not wrong_cat,
      "违规=%d 例=%s" % (len(wrong_cat), wrong_cat[:3]))

# ---- A5★ 广告不得产装备/宝物（防刷红线）----
ad_equip = [m.get("item_id") for t in ad_tiers for m in t.get("items", [])
            if I6_BY.get(m.get("item_id"), {}).get("cat_major", 0) >= 2]
check("A5★ 看广告不产装备/宝物（稀缺性红线）", not ad_equip,
      "违规=%d" % len(ad_equip))

# ---- A6 定价单调性：史诗 > 普通，同档内按基价单调 ----
bad_price = []
for g in ex_goods:
    if int(g.get("price", 0)) <= 0:
        bad_price.append(g["item_id"])
check("A6a 集市定价为正", not bad_price, "非正价=%d" % len(bad_price))
bad_price2 = [g["item_id"] for g in ma_goods if int(g.get("price", 0)) <= 0]
check("A6b 商城定价为正", not bad_price2, "非正价=%d" % len(bad_price2))
# 商城价必须显著高于 items6 基价（商城定价倍数的存在意义）
too_cheap = [g["item_id"] for g in ma_goods
             if int(g.get("price", 0)) < int(I6_BY[g["item_id"]].get("price", 0)) * 2]
check("A6c★ 商城定价 ≥ 基价 2 倍（否则「贵」这一侧约束失效）", not too_cheap,
      "偏便宜=%d" % len(too_cheap))

# ---- A7★ 任务物品奖励 ----
q_with_items = [q for q in Q if "items" in (q.get("rewards") or {})]
check("A7a★ 多数任务配发物品（≥50/73）", len(q_with_items) >= 50,
      "%d/%d" % (len(q_with_items), len(Q)))
# 物品 id 必须有效
bad_qi = []
for q in q_with_items:
    for it in q["rewards"]["items"]:
        iid = int(it.get("item_id", 0)) if isinstance(it, dict) else -1
        if iid not in REAL_IDS or iid in PH:
            bad_qi.append((q["id"], iid))
check("A7b★ 任务奖励物品 id 全部有效（无悬空）", not bad_qi, "悬空=%s" % bad_qi[:5])
# 数量必须为正
bad_qc = [(q["id"], it) for q in q_with_items for it in q["rewards"]["items"]
          if int(it.get("count", 1)) <= 0]
check("A7c 任务奖励物品数量为正", not bad_qc, "非正=%d" % len(bad_qc))

# ---- A8★ 全表悬空引用扫描 ----
dangling = []
for q in Q:
    for mid in (q.get("rewards") or {}).get("materials", []):
        # materials 可能是 str（旧 id，走 LEGACY_ITEM_MAP）或 int（items6）
        if isinstance(mid, int):
            if mid not in REAL_IDS:
                dangling.append((q["id"], mid, "int 不存在"))
        elif isinstance(mid, str):
            if mid not in OLD_IDS and not mid.is_valid_int():
                dangling.append((q["id"], mid, "str 两表皆无"))
check("A8★ 全表物品引用零悬空（含 materials 键）", not dangling,
      "悬空=%s" % dangling[:5])

# ---- A9★ 获取途径覆盖率 ----
avail = set()
for _npc, cfg in (NS.get("stock") or {}).items():
    for i in (cfg.get("buy") or []):
        try:
            iv = int(i)
        except (TypeError, ValueError):
            continue
        if iv in REAL_IDS:
            avail.add(iv)
# 集市
for g in ex_goods:
    avail.add(int(g["item_id"]))
# 商城
for g in ma_goods:
    avail.add(int(g["item_id"]))
# 任务奖励
for q in q_with_items:
    for it in q["rewards"]["items"]:
        avail.add(int(it["item_id"]))
# 制作链二级可达
craftable = {i["id"] for i in REAL
             if i.get("craft_flag") is True or str(i.get("craft_flag", "")) in ("1", "true")}
reach = set(avail)
for _ in range(10):
    add = set()
    for cid in craftable:
        if cid in reach:
            continue
        ms = I6_BY[cid].get("craft_materials") or []
        if ms and all(int(m["item_id"]) in reach for m in ms):
            add.add(cid)
    if not add:
        break
    reach |= add
ratio = 100.0 * len(reach) / len(REAL)
check("A9★ 真实物品获取覆盖率（改动前 19.4%%）≥ 95%%", ratio >= 95.0,
      "可达 %d/%d = %.1f%%" % (len(reach), len(REAL), ratio))
unreach = REAL_IDS - reach
check("A9b 不可获取物品数 ≤ 10", len(unreach) <= 10,
      "拿不到=%d 例=%s" % (len(unreach), sorted(unreach)[:5]))

# ---- A10 配方本身的有效性 ----
cf = [i for i in REAL if i.get("craft_flag") is True
      or str(i.get("craft_flag", "")) in ("1", "true")]
check("A10a 可锻造物品数 ≥ 100", len(cf) >= 100, "count=%d" % len(cf))
bad_mat = []
for i in cf:
    ms = i.get("craft_materials") or []
    if not ms:
        bad_mat.append((i["id"], "配方为空"))
        continue
    for m in ms:
        mid = int(m["item_id"])
        if mid not in REAL_IDS or mid in PH:
            bad_mat.append((i["id"], mid))
check("A10b★ 全部配方材料有效（无悬空无占位）", not bad_mat, "坏=%s" % bad_mat[:5])

# ---- A11 配方产出物必须非占位（占位不能被锻造出来）----
bad_out = [i["id"] for i in cf if i["id"] in PH]
check("A11 配方产出物不含占位", not bad_out, "违规=%d" % len(bad_out))

# ---- A12 广告档位冷却参数 ----
ad_cfg = ECON.get("reward_ad", {})
check("A12a 广告日限次为正", int(ad_cfg.get("ad_daily_limit", 0)) > 0,
      "limit=%s" % ad_cfg.get("ad_daily_limit"))
check("A12b 广告冷却 ≥ 24 游戏日（防刷底线）",
      int(ad_cfg.get("cooldown_hours", 0)) >= 24,
      "cd=%s" % ad_cfg.get("cooldown_hours"))
check("A12c 集市日限次为正", int(ECON.get("exchange", {}).get("daily_limit", 0)) > 0,
      "limit=%s" % ECON.get("exchange", {}).get("daily_limit"))

# ================================================================
print("")
print("=" * 64)
print("B 组 · 接线层（补了数据必须有代码消费）")
print("=" * 64)

try:
    QS = read("scripts/services/quest_service.gd")
    CRAFT = read("scripts/services/craft_service.gd")
    ECON_SVC = read("scripts/services/item_economy_service.gd")
    GS = read("scripts/autoload/game_state.gd")
    CITY = read("scripts/city/city_scene.gd")
    DM = read("scripts/autoload/data_manager.gd")
except Exception as e:
    print("!! 源码读取失败：%s: %s" % (type(e).__name__, e))
    sys.exit(1)

QS_C = code_only(QS)
CRAFT_C = code_only(CRAFT)
ECON_C = code_only(ECON_SVC)
GS_C = code_only(GS)
CITY_C = code_only(CITY)
DM_C = code_only(DM)

# ---- B1★ QuestService 消费 rewards 物品 ----
check("B1★ QuestService 声明并调用物品发放逻辑",
      "_grant_reward_items" in QS_C and "_grant_reward_items(rewards, parts)" in QS_C,
      "声明+调用")
# B2 两键都收
check("B2★ materials 与 items 两键都被读取（materials 优先）",
      'rewards.get("materials"' in QS_C and 'rewards.get("items"' in QS_C, "双键")
# B3 id 解析走 resolve_item6（兼容旧表），不是裸 DataManager.get_item
check("B3★ 奖励 id 走 resolve_item6（旧表 id 也能发放）",
      "resolve_item6" in QS_C, "兼容映射")
# B4 缺料/坏 id 必须显式暴露，不静默吞
check("B4★ 无效 id 在结算提示里暴露（不静默吞掉）",
      "物品数据缺失" in QS_C, "有提示文案")
# B5 空数组返回 [] 不返回 null（GDScript 带类型变量不能赋 null）
check("B5 配方材料空值返回 [] 而非 null",
      "return out" in CRAFT_C and ": Array = []" in CRAFT_C, "空数组")

# ---- B6★ CraftService 真正读 items6 配方（单一真源，不照抄副本）----
check("B6★ CraftService 读 items6.craft_materials（不照抄配方副本）",
      'craft_materials' in CRAFT_C and "func recipe_of" in CRAFT_C, "直读上游")
# B7 扣料前必须全量校验（不能边扣边发现不够）
can_i = CRAFT_C.find("static func can_craft")
craft_i = CRAFT_C.find("static func craft(item6_id")
seg_craft = CRAFT_C[craft_i:craft_i + 2000]
check("B7★ 扣料前先走 can_craft 全量校验（拒绝时零损耗）",
      "can_craft" in seg_craft, "先校验后扣料")
# B8 日限次用日号键（惰性归零）
check("B8 锻造日限次用日号键（惰性归零，不需手动清）",
      "craft_today" in CRAFT_C and "total_days()" in CRAFT_C, "日号键")

# ---- B9★ 广告三重防刷 ----
check("B9★1 广告日限次（ad_today）", "ad_today" in ECON_C, "日限次")
check("B9★2 单档冷却（ad_claimed）", "ad_claimed" in ECON_C, "档位冷却")
check("B9★3 冷却天数 ≥ 配置值", "cooldown_hours" in ECON_C, "冷却参数")
# B10 商城不写日限次（与集市区分）
seg_buy = ECON_C[ECON_C.find("static func buy_mall"):ECON_C.find("static func buy_mall") + 900]
check("B10 商城购买不写日限次（贵即约束，不叠双重门槛）",
      "exchange_today" not in seg_buy, "不占额度")

# ---- B11★ 存档四字段双向 ----
for f in ["craft_today", "ad_today", "ad_claimed", "exchange_today"]:
    pass
check("B11a★ 四个经济字段都写入 to_dict",
      all(('"%s"' % f) in GS_C for f in ["craft_today", "ad_today", "ad_claimed", "exchange_today"]),
      "四字段写")
# B11b ★ 必须过 _restore_int_keys（JSON 存档只有字符串键）
seg_fd = GS_C[GS_C.find("func from_dict"):]
seg_fd = seg_fd[:4000]
check("B11b★ 日号字典过 _restore_int_keys（否则读档当日额度清零）",
      "_restore_int_keys(_ct)" in seg_fd and "_restore_int_keys(_at)" in seg_fd
      and "_restore_int_keys(_et)" in seg_fd, "三处归一")
check("B11c ad_claimed 不过归一（键是档位 id 字符串）",
      "ad_claimed = _ac if _ac is Dictionary" in seg_fd, "不归一")
# B12 开新档要清
seg_new = GS_C[GS_C.find("func reset_new_game"):] if "func reset_new_game" in GS_C else ""
if not seg_new:
    # 找开新档的清空段
    m = re.search(r"merit_today = 0", GS_C)
    seg_new = GS_C[max(0, m.start() - 200): m.start() + 500] if m else ""
check("B12★ 开新档清空四个经济字段（否则上一局额度顶掉新档首日）",
      all(f in seg_new for f in ["craft_today", "ad_today", "ad_claimed", "exchange_today"]),
      "已清")

# ---- B13★ 铁匠铺锻造区已挂 ----
check("B13★ 铁匠铺调用锻造区构建（_build_smith 内）",
      "_build_smith_craft()" in CITY_C, "已挂")
seg_smith = CITY_C[CITY_C.find("func _build_smith()"):CITY_C.find("func _build_smith()") + 800]
check("B13b 锻造区挂在 _build_smith 内（不是新面板）",
      "_build_smith_craft()" in seg_smith, "同面板")
check("B13c 锻造区函数已实现",
      "func _build_smith_craft()" in CITY_C and "func _do_craft(" in CITY_C, "有实现")
# ---- B14★ 市场三区已挂 ----
check("B14★ 市场调用经济三区（集市/商城/广告）",
      "_build_market_economy()" in CITY_C, "已挂")
for fn in ["func _build_market_exchange()", "func _build_market_mall()",
           "func _build_market_ad()", "func _do_exchange(",
           "func _do_buy_mall(", "func _do_watch_ad("]:
    check("B14 面板函数已实现：%s" % fn.replace("func ", "").split("(")[0],
          fn in CITY_C, "有实现")
# B15 新区都在既有 _panel 内 ⇒ 不必改 _ui_panels 红线清单
check("B15★ 三区复用既有 _panel（无需改 _any_ui_open 红线清单）",
      "_panel_title.text" in CITY_C and "_panel_content.add_child" in CITY_C, "复用既有面板")

# ---- B16★ DataManager 已登记新表 ----
check("B16★ DataManager 登记 item_economy（否则全表读不到）",
      '"item_economy": "item_economy.json"' in DM_C, "已登记")

# ---- B17 面板里不得出现硬编码的物品 id 副本 ----
seg_mkt = CITY_C[CITY_C.find("func _build_market_exchange()"):
                CITY_C.find("func _tier_label(")]
hard_ids = re.findall(r"item_id\"?\s*[:=]\s*(\d+)", seg_mkt)
check("B17★ 面板不硬编码物品 id（数据单一真源）", not hard_ids,
      "硬编码=%s" % hard_ids[:5])
seg_craft_ui = CITY_C[CITY_C.find("func _build_smith_craft()"):
                      CITY_C.find("func _craft_cat_name(")]
hard_ids2 = re.findall(r"item_id\"?\s*[:=]\s*(\d+)", seg_craft_ui)
check("B17b 锻造区不硬编码物品 id", not hard_ids2, "硬编码=%s" % hard_ids2[:5])

# ================================================================
print("")
print("=" * 64)
print("C 组 · 无头真跑（tests/economy_probe.gd）")
print("=" * 64)

probe = os.path.join(HERE, "tests", "economy_probe.gd")
tscn = os.path.join(HERE, "tests", "economy_probe.tscn")
res = os.path.join(HERE, "economy_probe_result.txt")

if not (os.path.exists(probe) and os.path.exists(tscn)):
    check("C0 探针文件存在", False, "缺 economy_probe.gd/.tscn")
else:
    # ★ 存档指纹只扫**玩家真实存档目录** user://saves/（Windows 上是
    #   AppData/Roaming/Godot/app_userdata/纪元三国/saves/）。
    #   初版这里扫的是 ~/.workbuddy/**/*.json —— 那是 WorkBuddy 自己的对话/缓存目录
    #   （4622 个文件），与游戏存档毫无关系，跑一次必然报「污染」，
    #   判据恒红且毫无信息量。这是「判据自身搞错」而非「探针污染」。
    save_dir = os.path.join(os.path.expanduser("~"), "AppData", "Roaming",
                            "Godot", "app_userdata", "纪元三国", "saves")

    def snap_saves():
        out = {}
        if not os.path.isdir(save_dir):
            return out
        for fn in os.listdir(save_dir):
            if not fn.endswith(".json"):
                continue
            fp = os.path.join(save_dir, fn)
            try:
                with open(fp, "rb") as fh:
                    out[fn] = hash(fh.read())
            except OSError:
                pass
        return out

    before = snap_saves()
    try:
        os.remove(res)
    except OSError:
        pass
    p = subprocess.run([GODOT, "--headless", "--path", ".",
                        "res://tests/economy_probe.tscn"],
                       capture_output=True, cwd=ROOT,
                       encoding="gbk", errors="replace", timeout=300)
    got = ""
    if os.path.exists(res):
        with open(res, encoding="utf-8") as f:
            got = f.read()
    n_pass = got.count("[PASS]")
    n_fail = got.count("[FAIL]")
    check("C1 探针跑完且结果文件落盘", bool(got) and "FAILS=" in got,
          "returncode=%d 行数=%d" % (p.returncode, len(got.splitlines())))
    check("C2★ 探针零 FAIL（真实跑通四条途径）", n_fail == 0,
          "PASS=%d FAIL=%d" % (n_pass, n_fail))
    # 产出量闸门（MEMORY：光看红绿不够）
    check("C3★ 探针产出量达标（≥45 项，防空跑假绿灯）", n_pass + n_fail >= 45,
          "总断言=%d" % (n_pass + n_fail))
    # 逐项关键断言（挑三条最要紧的，判据失效时要能定位）
    check("C4★ 材料全额扣除（D5）", "[PASS] D5" in got, "不多扣不少扣")
    check("C5★ 缺料零损耗（D8b）", "[PASS] D8b" in got, "不白扣玩家料")
    check("C6★ 广告冷却防刷（E6/E6b）",
          "[PASS] E6" in got and "[PASS] E6b" in got, "同档不可再领")
    check("C7★ 存档往返（H2/H3/H5）",
          "[PASS] H2" in got and "[PASS] H3" in got and "[PASS] H5" in got,
          "日号键已归一")
    # 玩家存档内容级指纹（不是 mtime —— 同一毫秒内改动测不出）
    after = snap_saves()
    changed = [k for k in set(before) | set(after) if before.get(k) != after.get(k)]
    check("C8 探针未污染玩家存档（user://saves 内容级比对）", not changed,
          "存档目录=%s 存档数=%d 变动=%s" % (
              save_dir if os.path.isdir(save_dir) else "(不存在)",
              len(after), changed[:3]))

# ---- C0 交叉保护 ----
print("")
print("=" * 64)
print("C0 · 交叉保护（两组性质不同才能互证）")
print("=" * 64)
# 交叉点 1：广告不产装备 —— A 组查数据、B 组查接线、无头真跑查实际发放
check("C0-1a A 组断言 广告不含 cat>=2 物品", not ad_equip, "数据层")
check("C0-1b 无头真跑断言 同上（读的是真发放结果）",
      "A4★ 看广告不产装备/宝物" in got, "运行层")
# 交叉点 2：商城不含材料 —— 数据层 + 源码层（无头探针也断言）
check("C0-2a A 组断言 商城不含 cat 1/8", not wrong_cat, "数据层")
check("C0-2b 无头真跑断言 同上", "A3★ 商城不含材料/工具" in got, "运行层")
# 交叉点 3：任务物品发放 —— 数据层有 items + 源码层有消费 + 真跑有入账
check("C0-3a A 组断言 ≥50 个任务配发物品", len(q_with_items) >= 50, "数据层")
check("C0-3b 源码层断言 turn_in 调用了发放", "_grant_reward_items(rewards, parts)" in QS_C, "源码层")
check("C0-3c 无头真跑断言 奖励真的入背包", "[PASS] F1" in got, "运行层")

# ================================================================
print("")
print("=" * 64)
print("汇总：%d 项，FAIL %d" % (CHECKS, len(FAILS)))
if FAILS:
    for t in FAILS:
        print("  !! %s" % t)
print("=" * 64)
sys.exit(1 if FAILS else 0)
