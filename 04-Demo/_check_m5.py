# -*- coding: utf-8 -*-
"""
M5 城池经营模块校验脚本
覆盖：
  A. 场景节点引用一致性（脚本用 %Node 取节点，场景必须有 unique_name_in_owner 的对应节点）
  B. 数据表关键字段完整性（barracks / recruit_pool / shop_goods / drill）
  C. CityService 规则层方法存在性 + 返回值契约（{ok, msg}）
  D. GameState / EventBus 的 M5 新增成员
  E. 演练闭环链路（city_scene -> formation -> battle -> 回布阵）
  F. 交叉一致性：数据表引用的城市/兵种/武将/道具是否真实存在
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(ROOT, "assets", "data")
SCRIPTS = os.path.join(ROOT, "scripts")
SCENES = os.path.join(ROOT, "scenes")

errors = []
warns = []
checks = []


def ok(msg):
    checks.append(("OK", msg))


def fail(msg):
    errors.append(msg)


def warn(msg):
    warns.append(msg)


def read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def load(name):
    path = os.path.join(DATA, name)
    if not os.path.exists(path):
        fail("数据表缺失：%s" % name)
        return None
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception as e:
        fail("JSON 解析失败 %s：%s" % (name, e))
        return None


print("=" * 62)
print("M5 城池经营模块校验")
print("=" * 62)

# ---------------------------------------------------------------- A
print("\n[A] 场景节点引用一致性")
pairs = [
    ("scenes/city/city_scene.tscn", "scripts/city/city_scene.gd"),
    ("scenes/battle/formation_editor.tscn", "scripts/battle/formation_editor.gd"),
    ("scenes/battle/battle_scene.tscn", "scripts/battle/battle_scene.gd"),
]
for scene_rel, script_rel in pairs:
    spath = os.path.join(ROOT, scene_rel.replace("/", os.sep))
    gpath = os.path.join(ROOT, script_rel.replace("/", os.sep))
    if not os.path.exists(spath) or not os.path.exists(gpath):
        fail("文件不存在：%s 或 %s" % (scene_rel, script_rel))
        continue
    content = read(spath)
    script = read(gpath)
    # 场景中所有 unique_name_in_owner = true 的节点名
    unique_nodes = set()
    for b in content.split("[node "):
        m = re.match(r"name=\"([^\"]+)\"", b)
        if not m:
            continue
        if "unique_name_in_owner = true" in b:
            unique_nodes.add(m.group(1))
    # 脚本中 %Xxx 引用（排除 printf 占位符 %d/%s/%f 等）
    refs = set(re.findall(r"%([A-Za-z_][A-Za-z0-9_]*)", script))
    refs = {r for r in refs if not re.fullmatch(r"[dsfxXeEogc]|0?\d*[dsfxXeEogc]", r)}
    missing = sorted(r for r in refs if r not in unique_nodes)
    if missing:
        fail("%s 缺少节点（脚本 %s 中引用）：%s" % (
            os.path.basename(scene_rel), os.path.basename(script_rel), ", ".join(missing)))
    else:
        ok("%s 节点齐全（%d 个 unique 节点 / %d 处引用）" % (
            os.path.basename(scene_rel), len(unique_nodes), len(refs)))
    if unique_nodes:
        print("      %s -> %s" % (os.path.basename(scene_rel), ", ".join(sorted(unique_nodes))))

# ---------------------------------------------------------------- B
print("\n[B] 数据表字段完整性")

barracks = load("barracks.json")
if barracks:
    s = barracks.get("settings", {})
    need = ["recruit_per_batch", "max_recruit_per_day", "min_city_morale",
            "morale_cost_per_batch",
            "train_food_per_10", "train_exp_per_10", "veteran_threshold", "train_morale_gain"]
    miss = [k for k in need if k not in s]
    if miss:
        fail("barracks.json settings 缺字段：%s" % miss)
    else:
        ok("barracks.json settings 完整（%d 项）" % len(s))
    units = barracks.get("units", [])
    bad = [u for u in units if "unit_id" not in u or "gold_per_10" not in u]
    if bad:
        fail("barracks.json units 缺 unit_id/gold_per_10：%d 条" % len(bad))
    else:
        ok("barracks.json units %d 条，字段齐全" % len(units))

recruit = load("recruit_pool.json")
if recruit:
    s = recruit.get("settings", {})
    need = ["base_gold", "gold_per_difficulty", "recruit_gift_item", "max_party_size"]
    miss = [k for k in need if k not in s]
    if miss:
        fail("recruit_pool.json settings 缺字段：%s" % miss)
    else:
        ok("recruit_pool.json settings 完整")
    pool = recruit.get("pool", [])
    bad = [e for e in pool if "hero_id" not in e or "city_id" not in e or "difficulty" not in e]
    if bad:
        fail("recruit_pool.json pool 缺字段：%d 条" % len(bad))
    else:
        ok("recruit_pool.json pool %d 名武将" % len(pool))

shop = load("shop_goods.json")
if shop:
    s = shop.get("settings", {})
    if "sell_ratio" not in s or "material_price" not in s:
        fail("shop_goods.json settings 缺 sell_ratio / material_price")
    else:
        ok("shop_goods.json settings 完整（回收比 %.2f）" % float(s["sell_ratio"]))
    mg = shop.get("market_goods", [])
    sg = shop.get("smith_goods", [])
    if not mg:
        fail("shop_goods.json market_goods 为空")
    if not sg:
        fail("shop_goods.json smith_goods 为空")
    if mg and sg:
        ok("shop_goods.json 市集 %d 项 / 铁匠铺 %d 项" % (len(mg), len(sg)))

drill = load("drill.json")
if drill:
    s = drill.get("settings", {})
    if "default_drill_id" not in s:
        fail("drill.json settings 缺 default_drill_id")
    drills = drill.get("drills", [])
    if not drills:
        fail("drill.json drills 为空")
    else:
        bad = [d for d in drills if "id" not in d or "enemy_units" not in d]
        if bad:
            fail("drill.json 有 %d 条演练缺 id/enemy_units" % len(bad))
        else:
            ok("drill.json 演练 %d 套" % len(drills))
        dft = s.get("default_drill_id")
        if dft and not any(str(d.get("id")) == dft for d in drills):
            fail("drill.json default_drill_id=%s 在 drills 中不存在" % dft)

# ---------------------------------------------------------------- C
print("\n[C] CityService 规则层")
cs_path = os.path.join(SCRIPTS, "city", "city_service.gd")
if not os.path.exists(cs_path):
    fail("city_service.gd 不存在")
else:
    cs = read(cs_path)
    if "class_name CityService" not in cs:
        fail("city_service.gd 缺少 class_name CityService")
    methods = re.findall(r"^func ([a-z_][A-Za-z0-9_]*)", cs, re.M)
    need = [
        "buy_price", "sell_price",
        "can_recruit_unit", "recruit_cost", "remaining_quota", "recruit", "train",
        "morale_recruit_capacity", "effective_recruit_limit", "morale_cost_for_batch",
        "recruit_hero_terms", "can_recruit_hero", "recruit_hero", "give_gift", "assign_hero",
        "buy_resource", "sell_resource", "buy_item", "sell_item",
        "can_buy_smith", "buy_equipment",
        "relieve_city", "repair_city",
        "drill_as_encounter",
    ]
    miss = [m for m in need if m not in methods]
    if miss:
        fail("CityService 缺少方法：%s" % miss)
    else:
        ok("CityService 方法齐全（%d 个公共方法）" % len(methods))
    # 契约：操作类方法应返回 ok 字段
    if "_fail(" not in cs:
        warn("CityService 未见 _fail 辅助，返回值契约可能不统一")

# ---------------------------------------------------------------- D
print("\n[D] GameState / EventBus M5 成员")
gs_path = os.path.join(SCRIPTS, "autoload", "game_state.gd")
gs = read(gs_path)
gs_need = ["inventory", "equipment", "city_morale", "city_recruited_today",
           "city_defense_bonus", "drill_mode", "last_drill_result"]
miss = [k for k in gs_need if not re.search(r"^var\s+%s\b" % k, gs, re.M)]
if miss:
    fail("GameState 缺少字段：%s" % miss)
else:
    ok("GameState 字段齐全（%d 项）" % len(gs_need))
gs_m = ["add_item", "get_item_count", "has_item", "consume_item",
        "get_city_morale", "set_city_morale", "get_city_defense",
        "get_recruited_today", "add_recruited_today",
        "add_troop", "remove_troop", "assign_hero_to_troop",
        "has_hero", "recruit_hero", "add_fame", "add_infamy",
        "can_equip", "equip_item", "unequip_item"]
miss = [m for m in gs_m if not re.search(r"^func %s\b" % m, gs, re.M)]
if miss:
    fail("GameState 缺少方法：%s" % miss)
else:
    ok("GameState 方法齐全（%d 个）" % len(gs_m))
# 序列化同步
for field in ["inventory", "equipment", "city_morale", "city_recruited_today",
              "city_defense_bonus"]:
    if '"%s"' % field not in gs:
        fail("GameState 存档序列化未包含 %s" % field)
ok("GameState to_dict/from_dict 已同步 M5 字段")

eb = read(os.path.join(SCRIPTS, "autoload", "event_bus.gd"))
eb_need = ["party_changed", "inventory_changed", "item_bought", "item_sold",
           "troop_recruited", "city_morale_changed", "city_defense_changed",
           "drill_started", "drill_finished", "fame_changed", "infamy_changed",
           "equipment_changed"]
miss = [s for s in eb_need if not re.search(r"^signal\s+%s\b" % s, eb, re.M)]
if miss:
    fail("EventBus 缺少信号：%s" % miss)
else:
    ok("EventBus 信号齐全（%d 个）" % len(eb_need))

# ---------------------------------------------------------------- E
print("\n[E] 演练闭环链路")
city = read(os.path.join(SCRIPTS, "city", "city_scene.gd"))
fe = read(os.path.join(SCRIPTS, "battle", "formation_editor.gd"))
bs = read(os.path.join(SCRIPTS, "battle", "battle_scene.gd"))

chain = [
    (city, "drill_mode = true", "城池场景设置演练标记"),
    (city, "drill_as_encounter", "城池场景取演练敌方配置"),
    (city, 'push_scene("formation")', "城池场景跳转布阵界面"),
    (fe, "GameState.drill_mode", "布阵界面识别演练模式"),
    (fe, "试  演", "布阵界面按钮文案切换"),
    (bs, "GameState.drill_mode", "战场识别演练模式"),
    (bs, "_on_drill_finished", "战场演练专属结算"),
    (bs, "drill_finished", "战场广播演练结束信号"),
]
bad_chain = [(snippet, desc) for src, snippet, desc in chain if snippet not in src]
if bad_chain:
    fail("演练链路断裂：%s" % [d for _s, d in bad_chain])
else:
    ok("演练链路完整（城市场景 → 布阵 → 战场 → 回布阵）")

# 演练不得写存档
if "if GameState.drill_mode:" in fe and "SaveManager.auto_save()" in fe:
    # 确认 auto_save 在 drill_mode 分支之后（即演练时提前 return）
    idx = fe.find("if GameState.drill_mode:")
    idx2 = fe.find("if GameState.drill_mode:", idx + 1)
    seg = fe[idx2:idx2 + 400] if idx2 > 0 else fe[idx:idx + 400]
    if "return" in seg:
        ok("演练模式已跳过存档写入")
    else:
        fail("演练模式未跳过 SaveManager.auto_save()")

# 败北惩罚需在演练下被绕过
if "_apply_defeat_penalty" in bs and "if GameState.drill_mode:" in bs:
    ok("败北惩罚已加演练守卫")
else:
    fail("败北惩罚缺少演练守卫")

# ---------------------------------------------------------------- F
print("\n[F] 交叉一致性")
cities = load("cities.json") or []
city_ids = {str(c.get("id")) for c in cities}
units = load("units.json") or []
unit_ids = {str(u.get("id")) for u in units}
chars = load("characters.json") or []
char_ids = {str(c.get("id")) for c in chars}
items = load("items.json") or []
item_ids = {str(i.get("id")) for i in items}
items6 = load("items6.json") or []
item6_ids = {int(i.get("id")) for i in items6 if i.get("id") is not None}

if barracks:
    bad = [u.get("unit_id") for u in barracks.get("units", []) if str(u.get("unit_id")) not in unit_ids]
    if bad:
        fail("barracks.json 引用了不存在的兵种：%s" % bad)
    else:
        ok("barracks.json 兵种引用全部有效")

if recruit:
    badc = [e.get("city_id") for e in recruit.get("pool", []) if str(e.get("city_id")) not in city_ids]
    badh = [e.get("hero_id") for e in recruit.get("pool", []) if str(e.get("hero_id")) not in char_ids]
    if badc:
        fail("recruit_pool.json 引用了不存在的城池：%s" % badc)
    if badh:
        fail("recruit_pool.json 引用了不存在的武将：%s" % badh)
    if not badc and not badh:
        ok("recruit_pool.json 城池/武将引用全部有效")
    gift = recruit.get("settings", {}).get("recruit_gift_item", "")
    if gift and gift not in item_ids:
        fail("recruit_pool.json 赠礼道具不存在：%s" % gift)
    elif gift:
        ok("赠礼道具 %s 存在" % gift)

if shop:
    badi = []
    for g in shop.get("market_goods", []):
        if str(g.get("kind", "")) == "item" and str(g.get("item_id")) not in item_ids:
            badi.append(g.get("item_id"))
    bad6 = []
    for g in shop.get("smith_goods", []):
        raw = g.get("item_id")
        if raw is None:
            continue  # _section 分组行
        sid = str(raw)
        if sid.isdigit():
            if int(sid) not in item6_ids:
                bad6.append(sid)          # 数字 id 必须存在于 items6
        elif sid not in item_ids:
            badi.append(sid)              # 字符串 id 必须存在于 items.json
    if badi:
        fail("shop_goods.json 引用了不存在的道具：%s" % badi)
    if bad6:
        fail("shop_goods.json 引用了不存在的 items6 装备：%s" % bad6)
    if not badi and not bad6:
        ok("shop_goods.json 道具引用全部有效（items/items6 双源）")

if drill:
    badu = []
    for d in drill.get("drills", []):
        for u in d.get("enemy_units", []):
            if str(u.get("unit_id")) not in unit_ids:
                badu.append("%s -> %s" % (d.get("id"), u.get("unit_id")))
    if badu:
        fail("drill.json 引用了不存在的兵种：%s" % badu)
    else:
        ok("drill.json 兵种引用全部有效")

# ---------------------------------------------------------------- 汇总
print("\n" + "=" * 62)
for level, msg in checks:
    print("  [OK] %s" % msg)
if warns:
    for w in warns:
        print("  [WARN] %s" % w)
if errors:
    print("\n[FAIL] %d 项错误：" % len(errors))
    for e in errors:
        print("  - " + e)
    sys.exit(1)

print("\nM5 城池经营校验：%d 项检查全部通过，0 错误 ✅" % len(checks))
