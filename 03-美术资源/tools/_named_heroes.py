# -*- coding: utf-8 -*-
"""列出 heroes6 中所有「具名历史武将」（排除: 名为「无」/动物/职业兵种/主角占位）。"""
import json, os, sys
sys.stdout.reconfigure(encoding='utf-8')

ROOT = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国'
DEMO = os.path.join(ROOT, '04-Demo')
DATA = os.path.join(DEMO, 'assets', 'data')
SPR = os.path.join(DEMO, 'assets', 'sprites', 'npcs')

heroes = json.load(open(os.path.join(DATA, 'heroes6.json'), encoding='utf-8'))

# 职业/通用名黑名单（这些是功能 NPC / 职业，非具名武将；动物单独判断）
JOB_NAMES = {
    '伯乐','书商','军官','村长','商铺老板','铁匠','酒店老板','药店老板','旅馆老板',
    '驯马师','米店老板','治安官','首饰商','旅人','村民青年','村民老翁','村民女孩',
    '村民少妇','村民老妇','兄弟会首领','暗夜堂头目','罗马军官','山贼斧兵','黄巾军枪兵',
    '强盗刀兵','强盗弓兵','流寇刀盾兵','流寇弓箭手','乱军骑兵','乱军弩手','羌兵',
    '山贼刀兵','黄巾弓兵','护卫','亲兵','教头','掌柜','郎中','货郎','侠客','游侠',
}
ANIMALS = {'鹿','野猪','虎','熊','狼','豹','象','马','牛','羊','鸡'}

have = set(os.path.splitext(f)[0] for f in os.listdir(SPR) if f.endswith('.png'))

named = []
for h in heroes:
    name = str(h.get('name', ''))
    rid = str(h.get('id', ''))
    is_dummy = bool(h.get('is_dummy', False))
    if is_dummy:
        continue
    if not name or name == '无' or name in JOB_NAMES or name in ANIMALS:
        continue
    # 排除主角/占位
    if rid in ('1','2','3','4','5','6'):
        continue
    named.append(h)

print("具名武将（含职业词，需人工甄别）:", len(named))
print("其中已有立绘:", sum(1 for h in named if str(h.get('id')) in have), "张")
print("缺立绘:", len(named) - sum(1 for h in named if str(h.get('id')) in have), "张")
print("\n=== 全部具名武将 id/name ===\n")
for h in named:
    rid = str(h.get('id'))
    mark = 'HAVE' if rid in have else '    '
    print(f"  [{mark}] id={rid:<5} name={h.get('name','')}")
