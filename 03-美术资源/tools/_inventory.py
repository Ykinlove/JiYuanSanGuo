# -*- coding: utf-8 -*-
"""盘点美术资源缺口：列出每个 sprites 子目录已有的贴图，并对照数据表列出缺失项。"""
import json, os, sys
sys.stdout.reconfigure(encoding='utf-8')

ROOT = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国'
DEMO = os.path.join(ROOT, '04-Demo')
SPR = os.path.join(DEMO, 'assets', 'sprites')
DATA = os.path.join(DEMO, 'assets', 'data')

def pngs(d):
    p = os.path.join(SPR, d)
    if not os.path.isdir(p):
        return []
    return sorted([f[:-4] for f in os.listdir(p) if f.endswith('.png')])

print("=== sprites 各子目录已有贴图 ===")
for d in ['city_icons', 'units', 'npcs', 'city', 'map', 'terrain', 'encounters', 'player', 'ui', 'ui/icons']:
    print(f"  {d:12s} {pngs(d)}")

# 数据表对照
def load(name):
    d = json.load(open(os.path.join(DATA, name), encoding='utf-8'))
    return d

print("\n=== 缺口对照 ===")

# cities：所有城市 id（scene_*）
cities = load('cities.json')
city_ids = [str(c.get('id')) for c in cities if c.get('is_capital')]
print(f"  cities 都城(id)={city_ids}")
print(f"  cities 都城 已有 map/ 贴图: {[i for i in pngs('map')]}")
cap_missing = [i for i in city_ids if i not in pngs('map')]
print(f"  -> 都城缺 map/ 贴图: {cap_missing if cap_missing else '无（全部已有）'}")

# npcs.json
npcs = load('npcs.json')
npc_ids = [str(n.get('id')) for n in npcs]
print(f"  npcs.json id={npc_ids}")
npc_missing = [i for i in npc_ids if i not in pngs('npcs')]
print(f"  -> npcs 缺立绘: {npc_missing if npc_missing else '无'}")

# heroes6 中作为可招募武将的
recruit = load('recruit_pool.json')
pool = recruit.get('pool', [])
print(f"  招募池武将 hero_id={[p.get('hero_id') for p in pool]}")
print(f"  (招兵武将用 heroes6 数字 id, 见 heroes6.json role_id)")

# 兵种
units = load('units.json')
if isinstance(units, dict):
    units = list(units.values())
unit_ids = [str(u.get('id')) for u in units]
unit_missing = [i for i in unit_ids if i not in pngs('units')]
print(f"  units 兵种缺徽章: {unit_missing if unit_missing else '无'}")

# terrain.json 的 terrain 类型
terr = load('terrain.json')
if isinstance(terr, dict):
    terr = list(terr.values())
terr_types = []
def collect(o):
    if isinstance(o, dict):
        if 'terrain' in o:
            terr_types.append(str(o['terrain']))
        for v in o.values():
            collect(v)
    elif isinstance(o, list):
        for v in o:
            collect(v)
for t in terr:
    collect(t)
if 'base_terrain' in (terr[0] if terr else {}):
    terr_types.append(str(terr[0].get('base_terrain')))
t_set = sorted(set(terr_types))
t_missing = [i for i in t_set if i not in pngs('terrain')]
print(f"  terrain 地形类型={t_set} 缺贴图: {t_missing if t_missing else '无'}")

# encounters.json
enc = load('encounters.json')
e_ids = []
if isinstance(enc, dict):
    enc = list(enc.values())
for e in enc:
    if isinstance(e, dict) and 'id' in e:
        e_ids.append(str(e['id']))
    elif isinstance(e, dict):
        for k, v in e.items():
            if isinstance(v, dict) and 'id' in v:
                e_ids.append(str(v['id']))
e_ids = sorted(set(e_ids))
print(f"  encounters id={e_ids} 已有 encounters/ 贴图: {pngs('encounters')}")

print("\n=== 城内建筑 key（buildings 字段）===")
all_b = set()
for c in cities:
    b = c.get('buildings') or []
    if hasattr(b, 'keys'):
        all_b.update([k for k, v in b.items() if v])
    elif isinstance(b, list):
        all_b.update([str(x) for x in b])
print(f"  已出现建筑 key: {sorted(all_b)}")
print(f"  已有 city/ 贴图: {pngs('city')}")
b_missing = [k for k in all_b if k not in pngs('city')]
print(f"  -> 建筑缺贴图: {b_missing if b_missing else '无'}")
