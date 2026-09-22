# -*- coding: utf-8 -*-
import json, sys
sys.stdout.reconfigure(encoding='utf-8')
p = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国\04-Demo\assets\data\dialogues.json'
d = json.load(open(p, encoding='utf-8'))
print('TYPE', type(d).__name__, 'LEN', len(d))
samples = d[:3] if isinstance(d, list) else []
for s_ in samples:
    print('---', json.dumps(s_, ensure_ascii=False)[:600])
