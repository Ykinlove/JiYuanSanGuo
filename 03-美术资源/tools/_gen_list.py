# -*- coding: utf-8 -*-
"""生成武将在立绘缺失清单，并自动产出 ImageGen 提示词。
用于「全量武将立绘」批次。输出成 JSON 供按 id 出图后处理。
"""
import json, os, sys
sys.stdout.reconfigure(encoding='utf-8')

ROOT = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国'
DEMO = os.path.join(ROOT, '04-Demo')
DATA = os.path.join(DEMO, 'assets', 'data')
SPR = os.path.join(DEMO, 'assets', 'sprites', 'npcs')

sys.path.insert(0, os.path.join(ROOT, '03-美术资源', 'tools'))
from _portrait_gen import SKIP  # noqa: E402

heroes = json.load(open(os.path.join(DATA, 'heroes6.json'), encoding='utf-8'))
have = set(os.path.splitext(f)[0] for f in os.listdir(SPR) if f.endswith('.png'))

# 由四维推断气质标签（force=武力 智力intel 魅力charm 统帅strong）
def vibe(f):
    s, fo, i, c = (f.get('strong',50), f.get('force',50), f.get('intel',50), f.get('charm',50))
    t = []
    if fo >= 85: t.append('威猛悍将')
    elif fo >= 70: t.append('武艺高强')
    if i >= 85: t.append('智谋军师')
    elif i >= 70: t.append('足智多谋')
    if c >= 85: t.append('儒雅英杰')
    elif c >= 70: t.append('气度不凡')
    if s >= 85: t.append('统帅风范')
    if not t: t.append('普通武将')
    return '，'.join(t[:2])

def weapon_hint(h):
    # 由 life_skills 或 troop_type 暗示武器
    ls = h.get('life_skills') or {}
    if ls.get('枪术') and ls['枪术'] >= 3000: return '手持长枪'
    if ls.get('剑术') and ls['剑术'] >= 3000: return '腰佩长剑'
    if ls.get('射术') and ls['射术'] >= 3000: return '背后长弓'
    if ls.get('骑术') and ls['骑术'] >= 4000: return '身侧骏马'
    return ''

def prompt_for(h):
    g = '女性' if str(h.get('gender','1')) == '2' else '男性'
    v = vibe(h)
    w = weapon_hint(h)
    wpart = (('%s，' % w) if w else '')
    if g == '女性':
        head = '凤钗发髻'
        robe = '明艳织锦汉式女将装束'
    else:
        head = '束发武冠'
        robe = '深色铁甲锦袍汉式武将服饰'
    return ('游戏角色立绘素材，中国古代三国时代%s武将，二次元国风2D手绘全身像，明快色调，怀旧感，不华丽厚重。'
            '正面平视，居中构图，全身站立，脚底对齐画面底边。气质%s的形象，%s头戴%s，身着%s，腰间束带。表情坚定自信。'
            '干净纯白背景，无阴影，无地面，无环境元素，画面中绝对不出现任何文字。线条清晰，色彩平涂带轻描边。'
            % (g, v, wpart, head, robe))

out = []
for h in heroes:
    name = str(h.get('name',''))
    rid = str(h.get('id',''))
    if not name or name in SKIP:
        continue
    if rid in ('1','2','3','4','5','6'):
        continue
    if rid in have:
        continue
    gender = '女' if str(h.get('gender','1')) == '2' else '男'  # 1=男 2=女
    faction = str(h.get('faction_id',''))
    out.append({'id': rid, 'name': name, 'gender': gender, 'faction_id': faction,
                'prompt': prompt_for(h)})

# 按 id 排序
out.sort(key=lambda x: int(x['id']))
print("待生成武将立绘:", len(out))
print("男性:", sum(1 for x in out if x['gender']!='女'), " 女性:", sum(1 for x in out if x['gender']=='女'))

# 存清单 + 提示词
with open(os.path.join(ROOT,'03-美术资源','tools','_gen_list.json'),'w',encoding='utf-8') as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
with open(os.path.join(ROOT,'03-美术资源','tools','_gen_prompts.json'),'w',encoding='utf-8') as f:
    json.dump({x['id']: x['prompt'] for x in out}, f, ensure_ascii=False, indent=2)
print("清单已存: _gen_list.json / _gen_prompts.json")

# 打印前 5 个便于参考
for x in out[:5]:
    print("  ", x['id'], x['name'], x['gender'])
print("提示词示例(468):", out and next((p['prompt'] for p in out if p['id']=='468'), ''))
