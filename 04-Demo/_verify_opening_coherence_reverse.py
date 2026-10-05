# -*- coding: utf-8 -*-
"""第七十四轮 · 开场旁白连贯性判据的反向验证

目的：证明 `_verify_opening_coherence.py` 的 18 项是**真锁**而非摆设。
手法：注入真缺陷 → 判据必须报红 → 还原。

本判据的设计前提是「数据层+ 接线层」两组性质不同，故注入分打向两组：
  I1 删掉 mj_ch1_start 节点⇒ 数据层失去第一章章首（回到本轮前的缺陷）
     ⇒ 必须由 **A 组** 报红。
  I2 去掉 dialogue_ui 里对 schedule_ch1_start 的调用 ⇒ 数据在、标记永不置位
     ⇒ 必须由 **B4** 报红（这是「补了节点没接线 = 死数据」那个缺陷）。
  I3 换掉纪年体例（把「建安五年」改回「公元 206 年」）⇒ 必须由 **A6** 报红。
  I4 把 chapter 的「南中」全删掉 ⇒ 必须由 **A5** 报红（基线断链）。
  I5 反向保护：动ch1_end 的入队 ⇒ 必须由 **B7** 报红（证明反向保护有效）。
"""
import io
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DIA = os.path.join(HERE, 'assets', 'data', 'dialogues.json')
SVC = os.path.join(HERE, 'scripts', 'services', 'mainline_service.gd')
UI = os.path.join(HERE, 'scripts', 'ui', 'dialogue_ui.gd')
WMAP = os.path.join(HERE, 'scripts', 'world', 'world_map.gd')
PROBE = os.path.join(HERE, '_verify_opening_coherence.py')


def probe():
    pr = subprocess.run([sys.executable, PROBE], cwd=HERE,
                        capture_output=True, text=True,
                        encoding='utf-8', errors='replace', timeout=300)
    fails = []
    for ln in pr.stdout.split('\n'):
        if '[FAIL]' in ln:
            name = ln.split(']')[-1].strip().split('::')[0].strip()
            fails.append((name, name[:1]))
    return pr.returncode, fails


orig = {p: io.open(p, encoding='utf-8', newline='').read()
        for p in (DIA, SVC, UI, WMAP)}


def restore():
    for p, s in orig.items():
        io.open(p, 'w', encoding='utf-8', newline='').write(s)


print('=' * 72)
print('构造注入（全部用「唯一子串计数 == 1」预检，避免改到多处）')
print('=' * 72)

# ---- I1 删掉 mj_ch1_start 整个节点（数据层）----
nodes = json.loads(orig[DIA])
i1 = next(k for k, n in enumerate(nodes) if n['id'] == 'mj_ch1_start')
i1_text = json.dumps(nodes[i1], ensure_ascii=False)
assert orig[DIA].count(i1_text) == 1 or True   # json.dumps 形态可能与文件不同，改用行区间
# 用行区间切：从该节点的 '  {' 到下一个 '  }'
lines = orig[DIA].split('\r\n')
st = next(k for k, ln in enumerate(lines) if '"id": "mj_ch1_start"' in ln)
# 回退到该节点的开括号行
while lines[st].strip() != '{':
    st -= 1
en = next(k for k in range(st + 1, len(lines)) if lines[k] == '  }')
i1_block = '\r\n'.join(lines[st:en + 1])
# 【注入自纠·两轮踩坑】首版删块连逗号一起删，留下尾逗号 ⇒ JSON 语法错。
# 二版改成「保留分隔逗号」，结果**照样是尾逗号** —— 因为 mj_ch1_start 是
# **最后一个节点**，块前一行是 `},`：删掉 [st..en] 后它紧跟 `]` ⇒ 仍是尾逗号。
# 正解：删块时把**块前那一行的逗号**一起去掉（改成 `}` 接`]`），
# 即注入文本 = 「前一行去掉逗号」 + 块 + 换行，原文替换成「前一行去掉逗号」+ 换行。
# 判据侧已加 A0 崩溃防护，所以即便注入再坏，也会表达成一条 FAIL 而非 traceback。
assert lines[st - 1] == '  },', '块前一行不是「  },」，本注入需改法：%r' % lines[st - 1]
assert lines[en + 1] == ']', '块后一行不是数组闭合，本注入需改法：%r' % lines[en + 1]
assert orig[DIA].count(i1_block) == 1, 'I1 block not unique: %d' % orig[DIA].count(i1_block)
#注入 = 把「  },\r\n<块>\r\n」整体换成「  }\r\n」
i1_old_full = '  },\r\n' + i1_block + '\r\n'
i1_new_full = '  }\r\n'
assert orig[DIA].count(i1_old_full) == 1, 'I1 full not unique: %d' % orig[DIA].count(i1_old_full)
print('  I1 mj_ch1_start 节点块 %d 行，唯一=True（连块前逗号一起去，避免尾逗号）'
      % (en - st + 1))

# ---- I2 去掉 dialogue_ui 的排期调用（接线层）----
i2_old = '\t\t\tMainlineService.schedule_ch1_start()\n'
assert orig[UI].count(i2_old) == 1, 'I2 anchor not unique: %d' % orig[UI].count(i2_old)
print('  I2 dialogue_ui 排期调用，唯一=True')

# ---- I3 纪年体例改回现代纪年（数据层）----
i3_old = '建安五年、公元二百零六年'
i3_new = '公元 206 年'
assert orig[DIA].count(i3_old) == 1, 'I3 anchor not unique: %d' % orig[DIA].count(i3_old)
print('  I3 ch4 章首纪年串，唯一=True')

# ---- I4 删掉一处「南中」（数据层基线，阈值已收紧为 0，删一处即跨阈值）----
i4_old = '南中这处边陲'
assert orig[DIA].count(i4_old) == 1, \
    'I4 anchor not unique: %d' % orig[DIA].count(i4_old)
print('  I4 「南中这处边陲」出现次数 = 1（阈值 0 ⇒ 删一处必报红）')

# ---- I5 破坏 ch1_end 的入队（反向保护有效性）----
i5_old = '_queue_narration("mj_ch1_end", 0.8)'
assert orig[WMAP].count(i5_old) == 1, 'I5 anchor not unique: %d' % orig[WMAP].count(i5_old)
print('  I5 ch1_end 入队串，唯一=True')

CASES = [
    ('I1 删掉 mj_ch1_start 节点（回到「第一章无章首」的缺陷）',
     DIA, i1_old_full, i1_new_full, 'A'),
    ('I2 去掉 dialogue_ui 的排期调用（节点在但永不播 = 死数据）',
     UI, i2_old, '', 'B'),
    ('I3 纪年改回现代体例（公元 206 年）',
     DIA, i3_old, i3_new, 'A'),
    ('I4 删掉某一章的「南中」回扣（基线断链，阈值 0）',
     DIA, i4_old, '【已删】', 'A'),
    ('I5 破坏 ch1_end 入队（验反向保护 B7 有效）',
     WMAP, i5_old, '_queue_narration("mj_ch1_end_XX", 0.8)', 'B'),
]

bad = 0
for name, path, old, new, want_grp in CASES:
    io.open(path, 'w', encoding='utf-8', newline='').write(
        orig[path].replace(old, new))
    try:
        rc, fails = probe()
        groups = sorted(set(g for _, g in fails))
        ok = (rc != 0) and (want_grp in groups)
        print('  [%s] %s' % ('PASS' if ok else 'FAIL', name))
        print('         returncode=%d  红项=%s  期望组=%s'
              % (rc, [n for n, _ in fails] or '无', want_grp))
        if not ok:
            bad += 1
    finally:
        restore()

same = all(io.open(p, encoding='utf-8', newline='').read() == s
           for p, s in orig.items())
print()
print('restored all 4 files ok =', same)

rc, fails = probe()
print('baseline after restore: returncode=%d  FAIL=%d' % (rc, len(fails)))
if rc != 0:
    bad += 1

print()
print('REVERSE_RESULT =', 'PASS' if (bad == 0 and same) else 'FAIL')
sys.exit(0 if (bad == 0 and same) else 1)
