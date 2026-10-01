# -*- coding: utf-8 -*-
""" china_geo_4096 烘焙 v3：AI 全景图 → 近景细节整图（浮雕 hillshade + 锐化链）

演进史：
  v1 lanczos 4x + 单次 USM
  v2 多尺度锐化（DETAIL + 细/粗 USM + 饱和/对比）
  v3 【2026-10-01 抗糊终极版】用户仍嫌糊 → 从 AI 图亮度场推导高度图，
     做西北光山体阴影（hillshade 浮雕）+ 坡度调制的地表肌理：
     山体真正"立起来"（受光面亮/背光面暗），平原保持干净——
     这是插值放大路线里最大的质感跳跃，全部离线烘焙、运行时零开销。

管线（源 1024 → 4096）：
  ① lanczos 放大
  ② 高度场 = 亮度高斯模糊（σ≈14，只留大山势）
  ③ 法线 → 西北 45° 光照 hillshade，强度 RELIEF，均值归一不整体偏亮/暗
  ④ 坡度调制肌理：细噪声 × smoothstep(坡度)，山地颗粒、平原洁净
  ⑤ 乘合 shade/肌理 → DETAIL + 细 USM(1.2/160) + 粗 USM(6/70)
  ⑥ 饱和 1.15 + 对比 1.06

用法（工程外一次性烘焙，产物落 04-Demo/assets/sprites/terrain/）：
    python _china_geo_4096_bake.py
"""
import os
import sys
import numpy as np
from PIL import Image, ImageEnhance, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
# 【v4】源图优先用 2048 原生高清拼接图（_china_geo_hd_stitch.py 产出，
# ImageGen 四象限 i2i 增强）——2x lanczos 即到 4096，真细节翻倍；
# 旧 1024 图仅作兜底。
SRC_HD = os.path.normpath(os.path.join(HERE, "..", "AI源图", "terrain", "china_geo_hd_2048.png"))
SRC = os.path.normpath(os.path.join(HERE, "..", "AI源图", "terrain", "china_geo_src.png"))
FALLBACK = os.path.normpath(os.path.join(HERE, "..", "..", "04-Demo", "assets", "sprites", "terrain", "china_geo.png"))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "04-Demo", "assets", "sprites", "terrain", "china_geo_4096.png"))

SIZE = 4096

# —— hillshade 浮雕参数（v4：源已是高清真实细节，浮雕只做轻量补强） ——
## 【条纹教训】绘画原图色彩分块 → 亮度场有「台阶」，梯度直接放大呈现等高线
## 状伪影。三招抑制：高度场大 σ 模糊洗平台阶 + 梯度场二次小 σ 平滑 + 低 RELIEF。
HEIGHT_SIGMA = 18.0    ## 高度场高斯σ（4096 尺度；大=只表现大山势，小=碎噪）
GRAD_SMOOTH = 3.0      ## 梯度场二次高斯平滑（抹平亮度台阶引起的梯度条纹）
RELIEF = 60.0          ## 浮雕强度（高度梯度放大系数）
LIGHT = np.array([-0.55, -0.55, 0.65])   ## 西北 45° 光（指向光源方向）
LIGHT = LIGHT / np.linalg.norm(LIGHT)
AMBIENT = 0.88         ## 环境光底（高环境+低漫射=柔和浮雕）
DIFFUSE = 0.28         ## 漫反射增益（shade = AMBIENT + DIFFUSE·max(n·l,0)，再归一）

# —— 坡度调制肌理 ——
NOISE_BLUR = 1.2       ## 肌理噪声轻微模糊（避免硬像素点）
TEX_STRENGTH = 0.06    ## 山地最大肌理幅度（乘性 ±）
SLOPE_LO, SLOPE_HI = 0.0004, 0.0022  ## 坡度→肌理权重 smoothstep 区间

# —— 锐化/色彩（v4 调轻：真细节在，重锐化会出白边光晕） ——
USM_FINE_RADIUS = 1.0
USM_FINE_PERCENT = 120
USM_COARSE_RADIUS = 5.0
USM_COARSE_PERCENT = 50
SATURATION = 1.15
CONTRAST = 1.06

# —— v5 HD 细节注入 ——
HD_HP_SIGMA = 12.0     ## 高频提取的高斯σ（越小=注入越细的纹理，越大=注入形体）
DETAIL_GAIN = 1.15      ## 细节注入增益


def smoothstep(lo, hi, x):
    t = np.clip((x - lo) / max(hi - lo, 1e-9), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def main() -> None:
    # 【v5】色彩基调恒用原版 china_geo.png（用户认可色调，构图对齐城池）；
    # HD 拼接图只作高频细节源（其 i2i 色彩会漂移，不能当基调）。
    src = FALLBACK
    if not os.path.exists(src):
        print("[FAIL] 找不到源图：", src)
        sys.exit(1)
    im = Image.open(src).convert("RGB")
    print("[INFO] 源图：", src, im.size)

    # ① 放大（色彩基调图）
    im = im.resize((SIZE, SIZE), Image.LANCZOS)

    # ①.5 【v6 频段交换】v5 的「原图+HD高频」是双重曝光（HD 亮结构把亮度推爆
    # → 灰白）。正确姿势：低频（色彩/形体）取原图，高频（细节）取 HD——
    #   final = blur(原图, σ) + (HD − blur(HD, σ))
    # 两图构图同源，同 σ 交换无缝；原图色调（用户已认可）完整保留。
    hd_path = SRC_HD
    if os.path.exists(hd_path) and DETAIL_GAIN > 0.001:
        hd = Image.open(hd_path).convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
        base_blur = im.filter(ImageFilter.GaussianBlur(HD_HP_SIGMA))
        hd_blur = hd.filter(ImageFilter.GaussianBlur(HD_HP_SIGMA))
        low = np.asarray(base_blur).astype(np.float32)
        hp = (np.asarray(hd).astype(np.float32)
              - np.asarray(hd_blur).astype(np.float32)) * DETAIL_GAIN
        arr0 = low + hp
        im = Image.fromarray((np.clip(arr0, 0, 255) + 0.5).astype(np.uint8))
        print("[INFO] 已做频段交换（低频=原图 高频=HD，σ=%.0f 增益 %.2f）"
              % (HD_HP_SIGMA, DETAIL_GAIN))

    # ② 高度场：亮度 → 大尺度高斯模糊（去掉碎细节只留山势）
    lum = im.convert("L").filter(ImageFilter.GaussianBlur(HEIGHT_SIGMA))
    h = np.asarray(lum).astype(np.float32) / 255.0

    # ③ 法线 → hillshade（梯度场二次平滑，抹平亮度台阶条纹）
    gy, gx = np.gradient(h)
    def _blur(a):
        rng = max(float(np.ptp(a)), 1e-9)
        return np.asarray(Image.fromarray(
            ((a - a.min()) / rng * 255).astype(np.uint8)
        ).filter(ImageFilter.GaussianBlur(GRAD_SMOOTH))).astype(np.float32) / 255.0 * rng + float(a.min())
    gx = _blur(gx)
    gy = _blur(gy)
    nx, ny, nz = -gx * RELIEF, -gy * RELIEF, np.ones_like(h)
    norm = np.sqrt(nx * nx + ny * ny + nz * nz)
    ndotl = np.clip((nx * LIGHT[0] + ny * LIGHT[1] + nz * LIGHT[2]) / norm, 0.0, 1.0)
    shade = AMBIENT + DIFFUSE * ndotl
    shade /= max(shade.mean(), 1e-6)          # 均值归一：不整体偏亮/偏暗
    shade = np.clip(shade, 0.55, 1.5)

    # ④ 坡度调制肌理（山地颗粒、平原洁净）
    slope = np.sqrt(gx * gx + gy * gy)
    tex_w = TEX_STRENGTH * smoothstep(SLOPE_LO, SLOPE_HI, slope)
    noise = np.asarray(Image.effect_noise((SIZE, SIZE), 48)
                       .filter(ImageFilter.GaussianBlur(NOISE_BLUR))
                       ).astype(np.float32) / 255.0 - 0.5
    mod = 1.0 + noise * tex_w * 2.0

    # ⑤ 合成 + 锐化链
    arr = np.asarray(im).astype(np.float32) / 255.0
    arr *= shade[..., None]
    arr *= mod[..., None]
    out = Image.fromarray((np.clip(arr, 0, 1) * 255.0 + 0.5).astype(np.uint8))
    out = out.filter(ImageFilter.DETAIL)
    out = out.filter(ImageFilter.UnsharpMask(
        radius=USM_FINE_RADIUS, percent=USM_FINE_PERCENT, threshold=1))
    out = out.filter(ImageFilter.UnsharpMask(
        radius=USM_COARSE_RADIUS, percent=USM_COARSE_PERCENT, threshold=2))

    # ⑥ 色彩
    out = ImageEnhance.Color(out).enhance(SATURATION)
    out = ImageEnhance.Contrast(out).enhance(CONTRAST)
    out.save(OUT, optimize=True)
    print("[OK] 已烘焙：", OUT, "（%d×%d，%.1f MB）"
          % (SIZE, SIZE, os.path.getsize(OUT) / 1048576.0))


if __name__ == "__main__":
    main()
