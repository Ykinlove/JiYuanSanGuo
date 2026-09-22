# -*- coding: utf-8 -*-
"""盘点 heroes6 数据规模、武将 id、以及已有哪些立绘，估算全量生成需求。"""
import json, os, sys
sys.stdout.reconfigure(encoding='utf-8')

ROOT = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国'
DEMO = os.path.join(ROOT, '04-Demo')
DATA = os.path.join(DEMO, 'assets', 'data')
SPR = os.path.join(DEMO, 'assets', 'sprites', 'npcs')

def load(name):
    return json.load(open(os.path.join(DATA, name), encoding='utf-8'))

heroes = load('heroes6.json')
print("heroes6 总条数:", len(heroes))
print("样例字段:", list(heroes[0].keys()) if isinstance(heroes, list) and heroes else "?")
# 打印前 5 条关键字段
for h in heroes[:5]:
    print("  ", json.dumps(h, ensure_ascii=False)[:300])

# 现有立绘（数字 id）
have = set(os.path.splitext(f)[0] for f in os.listdir(SPR) if f.endswith('.png'))
print("\n已有 npcs/ 立绘:", sorted(have))

# 按阵营/武将 id 统计（role_id 字段）
from collections import Counter
faction_counter = Counter()
print("\n=== 前 40 名武将（id 与阵营）===")
for h in heroes[:40]:
    rid = str(h.get('id', h.get('role_id', h.get('hero_id', ''))))
    fid = h.get('faction_id', h.get('faction', ''))
    fname = h.get('faction_name', h.get('faction', ''))
    print(f"  id={rid:<8} faction={fid:<4} {fname:<6} name={h.get('name','')}")
