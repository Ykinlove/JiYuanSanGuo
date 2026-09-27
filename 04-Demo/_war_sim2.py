# -*- coding: utf-8 -*-
"""复算：加版图闸门前后对比（验证雪球消除 + 史实演化成立）。镜像 ai_service.gd 作战分支。"""
import json, io, random
from collections import Counter

cities = json.load(io.open('assets/data/cities.json', encoding='utf-8'))
terr = json.load(io.open('assets/data/faction_territory.json', encoding='utf-8'))
fac = json.load(io.open('assets/data/factions6.json', encoding='utf-8'))
fac = fac.get('factions', fac) if isinstance(fac, dict) else fac
fname = {int(f.get('id', 0)): f.get('name', '?') for f in fac}
INIT = {c['id']: c.get('faction_id') for c in cities}

AI = [3, 5, 6, 15, 16, 17, 18, 34]
MILITANCY = {3: 0.85, 5: 0.6, 6: 0.5, 15: 0.4, 16: 0.7, 17: 0.8, 18: 0.9, 34: 0.3}
SPHERE = {int(k): set(v['cities']) for k, v in terr.items() if k != '_comment'}


def clamp(v, a, b): return max(a, min(b, v))
def wp(fid): return clamp(0.5 + MILITANCY[fid] * 0.3, 0, 0.9)
def pk(a, b): return "%d|%d" % (min(a, b), max(a, b))


def run(use_sphere, years=20, seed=20260922):
    random.seed(seed)
    for c in cities:
        c['faction_id'] = INIT[c['id']]
    wars, declares = {}, 0

    def cnt(fid): return sum(1 for c in cities if int(c.get('faction_id', 0)) == fid)
    def enemies(fid):
        out = []
        for k in wars:
            x, y = k.split("|")
            if x == str(fid): out.append(int(y))
            elif y == str(fid): out.append(int(x))
        return out

    def capture_victims(att, victims):
        sph = SPHERE.get(att, set()) if use_sphere else set()
        best, bs = None, 999999
        for c in cities:
            if use_sphere and sph and c['id'] not in sph: continue
            fid = int(c.get('faction_id', 0))
            if fid == att: continue
            if fid != 0 and fid not in victims: continue
            sc = int(c.get('defense', 0)) * 2 + int(c.get('morale', 50))
            if sc < bs: bs, best = sc, c
        if best is None: return False
        best['faction_id'] = att
        return True

    def capture_in_sphere(att):
        if not use_sphere: return False
        sph = SPHERE.get(att, set())
        if not sph: return False
        best, bs = None, 999999
        for c in cities:
            if c['id'] not in sph: continue
            own = int(c.get('faction_id', 0))
            if own == att: continue
            # 争夺区：现属势力同样主张此城 → 跳过，留给宣战解决
            if own > 0 and c['id'] in SPHERE.get(own, set()): continue
            sc = int(c.get('defense', 0)) * 2 + int(c.get('morale', 50))
            if sc < bs: bs, best = sc, c
        if best is None: return False
        best['faction_id'] = att
        return True

    year, month = 184, 1
    for _ in range(years * 12):
        cur = (year - 1) * 12 + (month - 1)
        for fid in AI:
            en = enemies(fid)
            # 1) 版图内扩张（与战争状态解耦）
            if random.random() < wp(fid) * 0.5:
                capture_in_sphere(fid)
            # 2) 战争攻敌
            if en:
                if random.random() < wp(fid):
                    if not capture_victims(fid, en):
                        capture_in_sphere(fid)
                continue
            # 3) 宣战
            if random.random() < wp(fid) * 0.4:
                pool = [o for o in AI if o != fid and pk(fid, o) not in wars and cnt(o) > 0]
                if pool:
                    wars[pk(fid, random.choice(pool))] = cur
                    declares += 1
        for k in list(wars.keys()):
            x, y = k.split("|")
            if cur - wars[k] >= 1 and (cnt(int(x)) == 0 or cnt(int(y)) == 0):
                wars.pop(k)
        month += 1
        if month > 12: month, year = 1, year + 1
    dist = Counter(int(c.get('faction_id', 0)) for c in cities)
    return declares, len(wars), dist


for label, use in (("【改前】无版图闸门（随机互打）", False), ("【改后】版图闸门 + 版图内扩张", True)):
    d, w, dist = run(use)
    print("=" * 66)
    print(label)
    print("  20年宣战 %d 次 / 进行中战争 %d 对" % (d, w))
    print("  --- 8 个 AI 势力终局城数（括号为版图上限）---")
    for fid in sorted(AI, key=lambda f: -dist.get(f, 0)):
        cap = len(SPHERE.get(fid, set())) if use else '-'
        init = sum(1 for c in cities if INIT[c['id']] == fid)
        print("    %-4s %2d 城 (初始%2d, 版图上限%s)" % (fname.get(fid), dist.get(fid, 0), init, cap))
    top = max(dist.get(f, 0) for f in AI)
    print("  最大 AI 势力: %d/110 城 = %.0f%%" % (top, top / 110 * 100))
print("=" * 66)
