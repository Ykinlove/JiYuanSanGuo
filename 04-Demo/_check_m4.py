# -*- coding: utf-8 -*-
"""_check_m4.py — M4 专项一致性检查
检查 battle_scene.gd 引用的所有节点路径在 .tscn 中确实存在，
并核对 battle_unit / battle_director / combat.json 之间的字段名一致。
"""
import io
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))


def read(p):
    return io.open(os.path.join(HERE, p), encoding="utf-8").read()


errors = []
warns = []

# ---------- 1. battle_scene.gd 的 @onready 路径 vs .tscn 节点 ----------
print("=" * 66)
print("[1] battle_scene 节点路径一致性")
print("=" * 66)

gd = read("scripts/battle/battle_scene.gd")
tscn = read("scenes/battle/battle_scene.tscn")

def norm(path):
    """把 parent='.' 或 parent='' 的路径归一化为不带前导 ./"""
    p = path
    while p.startswith("./"):
        p = p[2:]
    return p


# 收集 tscn 中所有节点全路径
nodes = set()
root_name = ""
for m in re.finditer(r'\[node name="([^"]+)"(?:\s+type="([^"]+)")?(?:\s+parent="([^"]*)")?', tscn):
    name, _type, parent = m.group(1), m.group(2), m.group(3)
    if parent is None:
        if not root_name:
            root_name = name
        nodes.add(name)
    else:
        base = norm(parent)
        path = (base + "/" + name) if base else name
        nodes.add(path)
        nodes.add(name)   # 同时记录叶子名，便于 $Child 这种直接子节点引用

# 收集 gd 中的 $路径 引用
refs = re.findall(r'\$([A-Za-z0-9_/]+)', gd)
missing = []
for r in sorted(set(refs)):
    rn = norm(r)
    if rn in nodes:
        continue
    missing.append(r)

if missing:
    for r in missing:
        errors.append("battle_scene.gd 引用了不存在的节点: $%s" % r)
        print("  [FAIL] $%s 在场景中不存在" % r)
else:
    print("  [PASS] battle_scene.gd 全部 %d 个 $节点引用均存在（根节点 %s）" % (len(set(refs)), root_name))
print("  场景共 %d 个节点路径" % len(nodes))

# 检查脚本里 new 出来的节点是否声明了类型
print()

# ---------- 2. combat.json 字段 vs GDScript 读取的 key ----------
print("=" * 66)
print("[2] combat.json 字段 vs 脚本读取 key")
print("=" * 66)

cfg = json.loads(read("assets/data/combat.json"))
combat_keys = set(cfg.get("combat", {}).keys())

bu = read("scripts/battle/battle_unit.gd")
# 找出 _cfg.get("combat", {}).get("xxx") 形式
used_combat = set(re.findall(r'_cfg\.get\("combat",\s*\{\}\)\.get\("([a-z_]+)"', bu))
# 也找 cfg.get("xxx") 里已经拿到 combat 子字典的（calc_damage 里）
used_combat |= set(re.findall(r'var cfg:\s*Dictionary\s*=\s*attacker\._cfg\.get\("combat",\s*\{\}\)\s*\n(?:.*\n)*?\s*var \w+\s*:=\s*float\(cfg\.get\("([a-z_]+)"', bu))
for k in sorted(used_combat):
    if k in combat_keys:
        print("  [PASS] combat.%s 存在" % k)
    else:
        errors.append("battle_unit.gd 读取了 combat.json 中不存在的 key: combat.%s" % k)
        print("  [FAIL] combat.%s 不存在于 combat.json" % k)

# calc_damage 里的取值（cfg 已是 combat 子字典）
cd_fn = bu[bu.find("static func calc_damage"):]
cd_fn = cd_fn[:cd_fn.find("\n\n\n")]
# 从 "var cfg: Dictionary = attacker._cfg.get(...)" 之后开始匹配，
# 避免把 "_cfg.get(\"combat\")" 里的 combat 误当成 key
anchor = cd_fn.find("var cfg: Dictionary")
body = cd_fn[anchor:] if anchor >= 0 else cd_fn
used_cd = set(re.findall(r'(?<!_)\bcfg\.get\("([a-z_]+)"', body))
used_cd.discard("combat")
print("   —— calc_damage 读取：", ", ".join(sorted(used_cd)))
for k in sorted(used_cd):
    if k not in combat_keys:
        errors.append("calc_damage 读取了不存在的 key: %s" % k)
        print("  [FAIL] %s 不存在" % k)
    else:
        print("  [PASS] combat.%s 存在" % k)

# ---------- 3. combat.json 顶层结构 ----------
print()
print("=" * 66)
print("[3] combat.json 顶层结构")
print("=" * 66)
for k in ["combat", "counter_matrix", "ai", "category_default_speed"]:
    if k in cfg:
        print("  [PASS] 顶层 %s 存在" % k)
    else:
        errors.append("combat.json 缺少顶层字段 %s" % k)
        print("  [FAIL] 缺少顶层 %s" % k)

# 克制矩阵自检
units = {u["id"] for u in json.loads(read("assets/data/units.json"))}
matrix = cfg.get("counter_matrix", {})
idx = 0
matrix_errors = []
for uid, rows in matrix.items():
    if uid.startswith("_"):
        continue
    idx += 1
    if uid not in units:
        matrix_errors.append("counter_matrix 有未知兵种 %s" % uid)
    for r in rows:
        tgt = r.get("unit_id", "")
        if tgt.startswith("_"):
            continue
        if tgt not in units:
            matrix_errors.append("counter_matrix[%s] 指向未知兵种 %s" % (uid, tgt))
if matrix_errors:
    errors.extend(matrix_errors)
    print("  [FAIL] 克制矩阵有问题：%s" % "; ".join(matrix_errors))
else:
    print("  [PASS] 克制矩阵覆盖 %d 个兵种，引用目标全部有效" % idx)
covered = {u for u in matrix if not u.startswith("_")}
print("  兵种表共 %d 个兵种，矩阵覆盖 %d 个（未覆盖：%s）" % (
    len(units), idx, ",".join(sorted(units - covered)) or "无"))

# ---------- 4. director 调用的 unit 方法是否存在 ----------
print()
print("=" * 66)
print("[4] BattleDirector 调用的 BattleUnit 方法")
print("=" * 66)
bd = read("scripts/battle/battle_director.gd")
# 只匹配明确的 BattleUnit 变量名，排除数组/字典调用（units. / _enemies. / rows. 等）
unit_vars = ["u", "unit", "found", "weakest", "nearest", "best", "front"]
calls = set()
for v in unit_vars:
    calls |= set(re.findall(r'\b' + v + r'\.([a-z_]+)\(', bd))
calls |= set(re.findall(r'\btargets\[i\]\.([a-z_]+)\(', bd))
# 排除已知的容器方法
CONTAINER = {"is_empty", "size", "append", "clear", "has", "get", "keys", "duplicate", "sort_custom"}
calls -= CONTAINER
# Godot Object/Node/Node2D 内建方法：BattleUnit 继承链必然可用，无需在脚本源码中 func 声明
# （静态正则按源码声明判定会误报，这里从待检集合剔除，避免假阴性）
GODOT_BUILTIN = {
    "get_instance_id", "free", "queue_free", "get_parent", "get_node", "find_child",
    "add_child", "remove_child", "get_child", "get_children", "get_groups",
    "is_in_group", "add_to_group", "connect", "disconnect", "emit_signal",
    "has_method", "has_signal", "call", "call_deferred", "set", "get",
    "set_deferred", "get_class", "get_script", "is_queued_for_deletion",
    "notification", "add_user_signal",
}
calls -= GODOT_BUILTIN
declared = set(re.findall(r'^func ([a-z_]+)\(', bu, re.M))
for c in sorted(calls):
    if c in declared:
        print("  [PASS] BattleUnit.%s() 已定义" % c)
    else:
        errors.append("BattleDirector 调用了未定义的方法 BattleUnit.%s()" % c)
        print("  [FAIL] BattleUnit.%s() 未定义" % c)

# 属性访问
props = set(re.findall(r'\bu\.(count_max|attack_mult|defense_mult|counter_table|hold_position|charge_timer|unit_id|unit_name|category|troop_index|is_ally|range_px|morale|formation_slot|state|target|position)\b', bd))
decl_props = set(re.findall(r'^var ([a-z_]+)\s*[:=]', bu, re.M))
for p in sorted(props):
    if p in decl_props or p == "position":
        pass
    else:
        errors.append("BattleDirector 访问了未定义属性 BattleUnit.%s" % p)
        print("  [FAIL] BattleUnit.%s 未定义" % p)
print("  [PASS] 属性访问检查完成（%d 项）" % len(props))

# ---------- 5. 场景中 unit 层节点名 ----------
print()
print("=" * 66)
print("[5] 战场分层节点")
print("=" * 66)
for n in ["AllyUnits", "EnemyUnits", "Player", "UI"]:
    if n in nodes:
        print("  [PASS] %s 存在" % n)
    else:
        errors.append("battle_scene.tscn 缺少节点 %s" % n)
        print("  [FAIL] %s 缺失" % n)

# tscn 里 UI 下的新节点
for n in ["UI/SituationLabel", "UI/LogLabel"]:
    if n in nodes:
        print("  [PASS] %s 存在" % n)
    else:
        errors.append("battle_scene.tscn 缺少 M4 新增节点 %s" % n)
        print("  [FAIL] %s 缺失（M4 新增）" % n)

# 脚本里 new 出来的 UI 节点应可被解析
print()
print("=" * 66)
print("[6] battle_scene.gd 动态创建的视觉节点")
print("=" * 66)
for cls in ["Polygon2D", "Line2D", "Label", "ColorRect", "ProgressBar"]:
    if cls in gd:
        print("  [PASS] 使用了 %s" % cls)

# ---------- 汇总 ----------
print()
print("=" * 66)
if errors:
    print("发现 %d 个问题：" % len(errors))
    for e in errors:
        print("  - " + e)
else:
    print("M4 专项检查全部通过 ✅")
print("=" * 66)
