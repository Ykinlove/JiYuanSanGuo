# -*- coding: utf-8 -*-
"""向 dialogues.json 追加开场剧情(NEW)/新手引导对话。一次性脚本。"""
import json, sys
sys.stdout.reconfigure(encoding='utf-8')
P = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国\04-Demo\assets\data\dialogues.json'
d = json.load(open(P, encoding='utf-8'))
assert isinstance(d, list)

def upsert(entry):
    for i, x in enumerate(d):
        if x.get('id') == entry.get('id'):
            d[i] = entry
            print('覆盖:', entry['id'])
            return
    d.append(entry)
    print('新增:', entry['id'])

# 开场剧情：184年黄巾乱世，无名侠士初至南中
upsert({
    "id": "intro",
    "speaker": "旁白",
    "lines": [
        "汉末，灵帝昏聩，宦官弄权。中平元年，张角起事，黄巾乱起，天下大乱。",
        "你本是一个无名侠士，中原混战不休，便一路南行，来到了偏远的南中之地。",
        "南中，山高林密、瘴气弥漫，却也是一片可以让人安身立命的乱世净土。",
        "北望是建宁城（南蛮王的都城），东去有泸水渡口，往西是永昌，往南则是云南。",
        "从今天起，你将是这片土地上的一员。先四处走走，学学如何在这乱世中立足。",
    ],
    "options": [
        {"text": "（听老人讲讲此处规矩）", "next": "intro_guide"},
        {"text": "（直接开始闯荡）", "action": "gain_gold:500,gain_food:500,gain_fame:5,flag_intro", "next": ""},
    ],
})

# 新手引导：城邑与移动
upsert({
    "id": "intro_guide",
    "speaker": "旁白",
    "lines": [
        "左手边的摇杆可以移动人物，四处看看山野与村落。",
        "左上角的小地图，能帮你认清方位；右上的缩放按钮，可拉近拉远视野。",
        "遇到城邑，走进去就能见识南中的市井——商人、铁匠、还有招兵的衙门。",
        "见到游荡的商人【点其交谈】可交易补给；碰到山贼也可以一战，或绕开。",
        "好，我把它留给你了。带上这些盘缠，出去闯荡吧！",
    ],
    "options": [
        {"text": "（收下盘缠，出发！）", "action": "gain_gold:500,gain_food:500,gain_fame:5,flag_intro", "next": ""},
    ],
})

json.dump(d, open(P, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('写入完成，总条数', len(d))
