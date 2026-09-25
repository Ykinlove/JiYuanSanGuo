#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""【R3-11】小地图专用底图：china_geo 重采样 1024 → 2048。

背景：小地图「局部模式」控件约 300px 宽，只显示 ≈2900 世界宽 ≈ 采样 140 纹素，
2.1px/纹素明显糊（art-audit §2.4）。大地图远景用 1024 版无感，故只给小地图
单独出一份 2048 版，风格与 AI 写实全景图保持一致（用户拍板小地图底图统一
用 china_geo 系写实图，不做烘焙地形图替换）。

注：现图源为 1024²，本步属 LANCZOS 无损插值放大（不新增真实细节，仅消除
插值锯齿、把纹素密度翻倍）。若要真正增细节需重跑 AI 出图管线出 2048 原图。

用法：
    python _minimap_tex_upscale.py
输出：
    04-Demo/assets/sprites/terrain/china_geo_2048.png
"""
import os
import sys

from PIL import Image

# 脚本位于 03-美术资源/tools/ → 上两级是 03-美术资源 → 再进 04-Demo
DEMO = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "04-Demo")
SRC = os.path.join(DEMO, "assets/sprites/terrain/china_geo.png")
DST = os.path.join(DEMO, "assets/sprites/terrain/china_geo_2048.png")
TARGET = 2048


def main() -> int:
    if not os.path.exists(SRC):
        print("源图不存在：%s" % SRC)
        return 1
    im = Image.open(SRC)
    if im.width >= TARGET:
        print("源图已不低于 %d，无需重采样：%s（%s）" % (TARGET, DST, im.size))
        return 0
    out = im.resize((TARGET, TARGET), Image.LANCZOS)
    out.save(DST, "PNG", optimize=True)
    size_mb = os.path.getsize(DST) / 1024.0 / 1024.0
    print("已生成：%s（%s → 2048×2048，磁盘 %.1f MB）" % (DST, im.size, size_mb))
    print("提示：PNG 落盘后需跑 godot --headless --path %s --import 生成 .import" % DEMO)
    return 0


if __name__ == "__main__":
    sys.exit(main())
