# -*- coding: utf-8 -*-
"""按 190 群雄割据 历史占领重排 cities.json 的 faction_id（雪球修复）。
保留小势力对其专属城的既有归属；75 中立城按各方真实势力范围分配。
同时跑 20 年互伐镜像模拟，验证雪球是否消除。
"""
import json, random
from collections import Counter

random.seed(20260927)
HERE = 'assets/data'
cities_raw = json.load(open('%s/cities.json' % HERE, encoding='utf-8'))
# 兼容 dict 包裹 / 裸 list
if isinstance(cities_raw, dict):
    key = 'cities' if 'cities' in cities_raw else ('table' if 'table' in cities_raw else None)
    cities = cities_raw[key] if key else [cities_raw]
    wrapper = (cities_raw, key)
else:
    cities = cities_raw
    wrapper = None

fac = json.load(open('%s/factions6.json' % HERE, encoding='utf-8'))
if isinstance(fac, dict):
    fac = fac.get('factions', fac.get('table', [fac]))
fac_name = {int(f.get('id',0)): f.get('name','?') for f in fac}

# scene_id -> 历史归属 faction_id（190 群雄割据）
OVERRIDE = {
    # —— 既有归属微调 ——
    'scene_23': 16,   # 濮阳：190 属曹操兖州（原吕布，调正）
    # —— 75 中立城按历史势力范围分配 ——
    'scene_3': 26, 'scene_6': 17, 'scene_7': 26, 'scene_15': 24, 'scene_18': 3,
    'scene_19': 3, 'scene_21': 16, 'scene_29': 10, 'scene_30': 10, 'scene_31': 10,
    'scene_34': 16, 'scene_40': 34, 'scene_43': 10, 'scene_45': 25, 'scene_46': 25,
    'scene_51': 25, 'scene_52': 6, 'scene_53': 26, 'scene_54': 26, 'scene_55': 26,
    'scene_56': 7, 'scene_57': 7, 'scene_58': 26, 'scene_59': 16, 'scene_60': 7,
    'scene_61': 20, 'scene_62': 22, 'scene_63': 25, 'scene_64': 17, 'scene_65': 17,
    'scene_66': 13, 'scene_67': 24, 'scene_68': 18, 'scene_69': 17, 'scene_70': 17,
    'scene_71': 24, 'scene_72': 17, 'scene_73': 18, 'scene_74': 10, 'scene_75': 13,
    'scene_76': 34, 'scene_77': 26, 'scene_78': 34, 'scene_79': 24, 'scene_80': 24,
    'scene_81': 10, 'scene_82': 18, 'scene_83': 10, 'scene_84': 10, 'scene_85': 25,
    'scene_87': 25, 'scene_88': 24, 'scene_89': 16, 'scene_90': 25, 'scene_91': 13,
    'scene_92': 25, 'scene_93': 25, 'scene_94': 16, 'scene_95': 16, 'scene_96': 16,
    'scene_97': 10, 'scene_98': 25, 'scene_99': 10, 'scene_100': 10, 'scene_101': 10,
    'scene_102': 10, 'scene_103': 24, 'scene_104': 24, 'scene_105': 10,
    'scene_106': 6, 'scene_109': 26, 'scene_110': 26, 'scene_111': 6,
    # 交州远端（士燮，不在势力名册）留中立：scene_86 郁林 / scene_107 高凉 / scene_108 合蒲
}

before = Counter(int(c.get('faction_id',0)) for c in cities)
changed = 0        # faction_id 被重排的城数
fixed_fields = 0    # faction/faction_name 字段被纠正的城数（修复脏数据）

def _fac_fields(fid):
    """返回 (faction代码, faction_name) 标准写法：fid==0 为中立。"""
    if fid == 0:
        return 'neutral', '中立'
    return 'f%d' % fid, fac_name.get(fid, '')

for c in cities:
    # 真实匹配键是字符串 id（如 'scene_2'）；scene_id 是整数 2，不可直接比对
    sid = c.get('id')
    if not isinstance(sid, str):
        sid = 'scene_%s' % c.get('scene_id', '')
    target = OVERRIDE.get(sid, None)
    if target is not None:
        fid = target
        if int(c.get('faction_id',0)) != fid:
            c['faction_id'] = fid
            changed += 1
        # 命中：无论如何同步 faction/faction_name 字段（避免写入中文名脏数据）
        wf, wn = _fac_fields(fid)
        if c.get('faction') != wf or c.get('faction_name') != wn:
            c['faction'] = wf
            c['faction_name'] = wn
            fixed_fields += 1
    else:
        # 未命中：按当前 faction_id 规范化字段（幂等修复）
        fid = int(c.get('faction_id',0))
        wf, wn = _fac_fields(fid)
        if c.get('faction') != wf or c.get('faction_name') != wn:
            c['faction'] = wf
            c['faction_name'] = wn
            fixed_fields += 1

after = Counter(int(c.get('faction_id',0)) for c in cities)

# 写回
if wrapper:
    wrapper[0][wrapper[1]] = cities
    out = wrapper[0]
else:
    out = cities
json.dump(out, open('%s/cities.json' % HERE, 'w', encoding='utf-8'),
          ensure_ascii=False, indent=2)

print('=== 重排结果 ===')
print('faction_id 重排城数:', changed)
print('faction/faction_name 字段纠正城数:', fixed_fields)
print('中立城 前/后:', before.get(0,0), '->', after.get(0,0))
print('\n归属分布（faction_id: 城数）:')
for fid in sorted(after):
    nm = fac_name.get(fid, '中立' if fid==0 else '?')
    print('  %-3d %-8s %d' % (fid, nm, after[fid]))

# ================= 互伐镜像模拟（验证雪球） =================
AI_FACTIONS = [3,5,6,15,16,17,18,34]
MILITANCY = {3:0.85,5:0.6,6:0.5,15:0.4,16:0.7,17:0.8,18:0.9,34:0.3}
faction_wars = {}
def clamp(v,a,b): return max(a,min(b,v))
def wp(fid): return clamp(0.5+MILITANCY[fid]*0.3,0,0.9)
def fcc(fid): return sum(1 for c in cities if int(c.get('faction_id',0))==fid)
def pk(a,b): return '%d|%d'%(min(a,b),max(a,b))
def iswar(a,b): return bool(faction_wars.get(pk(a,b),False))
def enemies(fid):
    out=[]
    for k in faction_wars:
        x,y=k.split('|')
        if x==str(fid): out.append(int(y))
        elif y==str(fid): out.append(int(x))
    return out
def declare(a,b,cur):
    k=pk(a,b)
    if k in faction_wars: return False
    faction_wars[k]=cur; return True
def peace(a,b): faction_wars.pop(pk(a,b),None)
def capture(atk,vics):
    best=None; bs=999999
    for c in cities:
        fid=int(c.get('faction_id',0))
        if fid==atk: continue
        if fid!=0 and fid not in vics: continue
        sc=int(c.get('defense',0))*2+int(c.get('morale',50))
        if sc<bs: bs=sc; best=c
    if best is None: return False
    best['faction_id']=atk; return True
def maybe_decl(atk):
    pool=[o for o in AI_FACTIONS if o!=atk and not iswar(atk,o) and fcc(o)>0]
    if not pool: return
    declare(atk, random.choice(pool), cur)
def war_step(atk):
    en=enemies(atk)
    if en:
        if random.random()<wp(atk):
            if not capture(atk,en): capture(atk,[0])
        return
    if random.random()<wp(atk)*0.4: maybe_decl(atk)
def auto_resolve(cur):
    for k in list(faction_wars.keys()):
        x,y=k.split('|'); st=faction_wars[k]
        if cur-st>=1 and (fcc(int(x))==0 or fcc(int(y))==0): peace(int(x),int(y))

year,month=190,1
declares=0
for _ in range(240):
    cur=(year-1)*12+(month-1)
    for fid in AI_FACTIONS:
        b=len(faction_wars); war_step(fid); declares+=len(faction_wars)-b
    auto_resolve(cur); month+=1
    if month>12: month=1; year+=1
final=Counter(int(c.get('faction_id',0)) for c in cities)
print('\n=== 20 年互伐模拟（190 起点）===')
print('累计宣战:', declares, '| 进行中战争:', len(faction_wars))
print('最终 AI 势力城数:')
for fid in AI_FACTIONS:
    print('  fid=%-3d %-8s 城数=%d' % (fid, fac_name.get(fid,'?'), final.get(fid,0)))
print('最大单一势力城数:', max(final.values()), '/ 总城', len(cities))
