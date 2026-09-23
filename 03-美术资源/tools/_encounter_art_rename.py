# -*- coding: utf-8 -*-
"""P3-4 立绘归位：AI 生图工具并发调用时会忽略各自的 output_dir，
所有图都落进同一个目录。好在文件名里带了 prompt 的中文关键词，
据此把每张图归位到它的遭遇 id 目录下（并重命名为 <id>.png）。

匹配不到关键词的文件会明确报出来，绝不静默乱配。
"""
import glob
import os
import shutil

ROOT = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国\03-美术资源\AI源图\encounters\_raw'

# (文件名关键词, 遭遇 id) —— 关键词必须在该张图的文件名里唯一出现
KEYMAP = [
    ('山贼头目', 'enc_bandit'),
    ('黄巾军士兵', 'enc_yellow_turban'),
    ('黄巾军首领', 'enc_zhangjue_boss'),
    ('南蛮部落战士', 'enc_tribal_warrior'),
    ('猛虎', 'enc_beast'),
    ('行商车队', 'enc_merchant'),
    ('木质宝箱', 'enc_treasure'),
    ('草药丛', 'enc_herb'),
    ('裸露矿脉', 'enc_ore'),
    ('湖畔垂钓', 'enc_fishing'),
    ('流民一家', 'enc_refugees'),
    ('古井', 'enc_old_well'),
    ('山中隐士', 'enc_hermit'),
    ('倒地伤兵', 'enc_wounded_scout'),
    ('毒龙潭', 'enc_hidden_dragon_pool'),
    ('翡翠矿洞', 'enc_hidden_jade_mine'),
    ('祭坛图腾', 'enc_hidden_shaman_altar'),
    ('山间暗道', 'enc_hidden_prison_pass'),
]


def main():
    files = []
    for ext in ('*.png', '*.webp', '*.jpg', '*.jpeg'):
        files += glob.glob(os.path.join(ROOT, '**', ext), recursive=True)
    files = [f for f in files if not os.path.basename(f).startswith('.')]
    print('待归位：%d 张' % len(files))

    moved, missed = 0, []
    for f in files:
        name = os.path.basename(f)
        target_id = None
        for kw, enc_id in KEYMAP:
            if kw in name:
                target_id = enc_id
                break
        if target_id is None:
            missed.append(name)
            continue
        dst_dir = os.path.join(ROOT, target_id)
        os.makedirs(dst_dir, exist_ok=True)
        dst = os.path.join(dst_dir, target_id + '.png')
        if os.path.abspath(f) != os.path.abspath(dst):
            shutil.move(f, dst)
            moved += 1
        else:
            moved += 1

    print('已归位：%d 张' % moved)
    if missed:
        print('!! 未匹配到关键词（需人工处理）:')
        for m in missed:
            print('   -', m)
    else:
        print('无遗漏')


if __name__ == '__main__':
    main()
