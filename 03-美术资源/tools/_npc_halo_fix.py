# -*- coding: utf-8 -*-
"""R3-01：NPC 立绘白雾批量净化（erode + despill）。

背景：npcs 全批 ~749 张为白底图抠图产物，半透明边缘像素 RGB 仍携带白色（spill），
在墨底 #171B26 的对话/详情面板上呈灰白毛边（美术审计实测 white_halo 800~2100 px/张）。

处理（对成品透明底 PNG 直接净化，无需回溯白底原图，git 跟踪可随时还原）：
  1) alpha 通道 3×3 最小值滤波（erode 1px）——收缩裁掉白边源；
  2) despill：全部像素 RGB 乘 (1 - (1-a)/255*0.6)——白色残留按透明度比例回拉；
     连续公式，a=255 时因子恰为 1.0，全不透明像素不受影响，无需阈值分支；
  3) 原地覆盖 04-Demo/assets/sprites/npcs/*.png。

指标 white_halo = 0<a<250 且 min(r,g,b)>=220 的像素数（修复前后自动对比）。
用法：
  python _npc_halo_fix.py sample    # 抽样试跑，只打印前后指标
  python _npc_halo_fix.py run       # 全量批处理并覆盖
"""
import glob
import os
import random
import sys

from PIL import Image, ImageChops, ImageFilter

SRC = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国\04-Demo\assets\sprites\npcs'


def white_halo_count(img: Image.Image) -> int:
    """统计白雾像素数：半透明且 RGB 全通道偏白。"""
    rgba = img.convert('RGBA')
    a = rgba.getchannel('A')
    # 半透明掩码：0 < a < 250 → 二值图 255/0
    semi = a.point(lambda v: 255 if 0 < v < 250 else 0)
    r, g, b = rgba.split()[:3]
    # 三通道各取「≥220 才亮」的掩码后取最小值 = 全通道皆白的掩码
    masks = [ch.point(lambda v: 255 if v >= 220 else 0) for ch in (r, g, b)]
    whiteish = masks[0]
    for m in masks[1:]:
        whiteish = ImageChops.darker(whiteish, m)
    halo = ImageChops.multiply(semi, whiteish)
    return sum(1 for v in halo.getdata() if v)


def fix(img: Image.Image) -> Image.Image:
    """erode 1px + despill，返回新 RGBA 图。"""
    rgba = img.convert('RGBA')
    a = rgba.getchannel('A').filter(ImageFilter.MinFilter(3))
    r, g, b = rgba.split()[:3]
    # 因子表：factor(a) = 1 - (1 - a/255)*0.6 = 0.4 + 0.6*a/255
    # new_ch = ch*0.4 + ch*(a*0.6)/255，用 ImageChops.multiply/add 实现（全 C 速度）
    a06 = a.point(lambda v: int(v * 0.6))
    out_channels = []
    for ch in (r, g, b):
        t1 = ch.point(lambda v: int(v * 0.4))
        t2 = ImageChops.multiply(ch, a06)
        out_channels.append(ImageChops.add(t1, t2))
    out = Image.merge('RGBA', (*out_channels, a))
    return out


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else 'sample'
    files = sorted(glob.glob(os.path.join(SRC, '*.png')))
    if not files:
        print('未找到待处理 PNG：', SRC)
        sys.exit(1)
    print('共 %d 张待处理' % len(files))

    if mode == 'sample':
        named = [f for f in files if os.path.basename(f) in
                 ('300.png', 'protagonist.png', 'npc_elder.png', 'npc_meng_huo.png')]
        rng = random.Random(20260925)
        sample = named + rng.sample(files, max(0, 8 - len(named)))
        sample = list(dict.fromkeys(sample))[:8]
        for f in sample:
            img = Image.open(f)
            before = white_halo_count(img)
            after = white_halo_count(fix(img))
            print('%-28s halo %5d -> %5d' % (os.path.basename(f), before, after))
        return

    if mode == 'run':
        total_before = total_after = 0
        for i, f in enumerate(files, 1):
            img = Image.open(f)
            before = white_halo_count(img)
            out = fix(img)
            after = white_halo_count(out)
            total_before += before
            total_after += after
            out.save(f, optimize=True)
            if i % 100 == 0:
                print('  进度 %d/%d' % (i, len(files)))
        print('全量完成：white_halo 总计 %d -> %d（%d 张）'
              % (total_before, total_after, len(files)))
        return

    print('未知模式：%r（可用 sample / run）' % mode)
    sys.exit(1)


if __name__ == '__main__':
    main()
