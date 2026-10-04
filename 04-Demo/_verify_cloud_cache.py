"""第七十二轮 · 云影缓存判据

为什么需要这个：`_bake_cloud_texture()` 加了进程内缓存后，插桩显示
`pl:ambience` 从 228.9ms 降到 0.2ms。**这个降幅本身可疑** ——
可能是「真的省了重复烘焙」，也可能是「纹理提前 return 空值，云影彻底消失」
而后者玩家看到的是「云没了」，属功能回归而非优化。

所以判据必须同时锁三件事（缺一不可）：
  A1 真跑一次_try_boot，确认**云 sprite 真的存在**且texture 非空
  A2 云纹理尺寸 = CLOUD_TEXTURE_SIZE（不是被换成 1×1 之类的占位）
  A3 alpha 通道确有内容（云块分布成立，不是全 0 全 255 的纯色）
  B组 源码层：缓存守卫 + set_data 路径 + RGB 仍为白（视觉等价）
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
AMB = os.path.join(HERE, 'scripts', 'world', 'world_ambience.gd')
sys.path.insert(0, HERE)
from _gs_func import func_body  # noqa: E402  （真源：只有 func_body 在此）


def read(p):
    # 文本模式：CRLF 自动转 \n（反向验证器同样视角，锚点口径一致）
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def code_only(text):
    out = []
    for ln in text.split("\n"):
        s = ln.strip()
        if s.startswith("#"):
            continue
        out.append(ln.split("  #")[0] if "  #" in ln else ln)
    return "\n".join(out)

FAILS = []
N = [0]
# 分组登记：用于 C0 断言「A/B 两组都在场」
A_KEYS = []
B_KEYS = []


def check(name, cond, detail=""):
    N[0] += 1
    tag = "PASS" if cond else "FAIL"
    if not cond:
        FAILS.append(name)
    print("  [%s] %s :: %s" % (tag, name, detail))


def main():
    print("=" * 68)
    print("第七十二轮 · 云影缓存判据（性能 + 正确性双向）")
    print("=" * 68)
    src = read(AMB)
    code = code_only(src)

    # ---------------- A 组：无头真跑，验云影真的存在且有效
    probe = os.path.join(HERE, "tests", "cloud_probe.gd")
    tscn = os.path.join(HERE, "tests", "cloud_probe.tscn")
    res = os.path.join(HERE, "cloud_probe_result.txt")
    if os.path.exists(res):
        os.remove(res)
    godot = r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe"
    pr = subprocess.run(
        [godot, "--headless", "--path", HERE, "--quit-after", "400",
         "res://tests/cloud_probe.tscn"],
        cwd=HERE, capture_output=True, text=True,
        encoding="gbk", errors="replace", timeout=180)
    out = ""
    if os.path.exists(res):
        out = read(res)
    lines = out.strip().split("\n") if out.strip() else []

    def val(key):
        for ln in lines:
            if ln.startswith(key + "="):
                return ln.split("=", 1)[1].strip()
        return None

    sprites = int(val("cloud_sprite_count") or -1)
    # 【判据自纠·首跑误报】首版这里写的是 `cloud_tex_width`，而探针输出的键是
    # `tex_width` ⇒ val() 恒返回 None ⇒ 尺寸恒读成 -1 ⇒ 恒假。
    # 正解：键名必须与探针**逐字一致**（判据与被测方各写各的键 = 永远对不上）。
    tex_w = int(val("tex_width") or -1)
    tex_h = int(val("tex_height") or -1)
    alpha_lo = int(val("alpha_min") or -1)
    alpha_hi = int(val("alpha_max") or -1)
    alpha_mid = int(val("alpha_mid") or -1)

    #A1 真跑必须出结果，且云 sprite 数量 == CLOUD_BLOBS
    check("A1a 无头探针真跑成功（不是编译失败/未产出）",
          bool(lines) and val("DONE") == "1",
          "探针输出行数=%d，DONE=%s" % (len(lines), val("DONE")))
    check("A1b 云 sprite 真实存在且数量为 3",
          sprites == 3,
          "实测 cloud_sprite_count=%d（期望 3 = CLOUD_BLOBS）；"
          "为 0 说明云影消失= 功能回归" % sprites)
    check("A1c 云纹理尺寸正确（不是占位小图）",
          tex_w == 512 and tex_h == 512,
          "实测 %dx%d（期望 512x512 = CLOUD_TEXTURE_SIZE）" % (tex_w, tex_h))

    # A3 alpha 通道必须有梯度：全 0 = 云没了；全 255 = 变成纯色方块
    check("A2a alpha 有真实梯度（云块分布成立）",
          alpha_lo == 0 and 0 < alpha_hi <= 255,
          "alpha min=%d max=%d（须min=0 谷底全透 且 max>0 有云块）"
          % (alpha_lo, alpha_hi))
    check("A2b alpha 中间态存在（不是二值硬边）",
          0 < alpha_mid < 255,
          "alpha_mid=%d（须 0<mid<255，否则云是硬边色块不是柔和云影）"
          % alpha_mid)
    # 缓存必须真的被复用：第二次取到的是同一对象
    check("A2c 第二次调用命中缓存（同一实例）",
          val("cached_same") == "1",
          "cached_same=%s（1 = 第二次拿到的就是缓存那张图）" % val("cached_same"))

    # 【第七十二轮·判据补强】反向验证实测发现：I2（缓存返回 null）只让
    # A2c/B2 报红，**没有任何一项判据回答「玩家还能不能看到云」**——
    # 因为纹理层非空 ≠ 云 sprite 上挂着纹理。真跑 _build_clouds 数一遍，
    # 才是玩家眼睛看到的东西。
    built = int(val("built_sprite_count") or -1)
    with_tex = int(val("sprite_with_texture") or -1)
    check("A2d 云 sprite 真建出来了（玩家眼里有云）",
          built == 3,
          "实测 built_sprite_count=%d（期望 3）；为 0 = 云影整体消失" % built)
    check("A2e 每只云 sprite 都挂着有效纹理（不是空 sprite）",
          built > 0 and with_tex == built,
          "实测 %d/%d 只挂了纹理；不等说明有云 sprite 是空的（=白搭）"
          % (with_tex, built))

    # ---------------- B 组：源码层
    body = func_body(src, "_bake_cloud_texture") or ""
    check("B1 能取到 _bake_cloud_texture 函数体",
          bool(body) and len(body) > 200, "体长 %d" % len(body))
    check("B2 有缓存守卫（static var + null 判断 + 早返回）",
          re.search(r"static\s+var\s+_cloud_tex_cache\s*:\s*ImageTexture", src) is not None
          and "_cloud_tex_cache != null" in body
          and re.search(r"if\s+_cloud_tex_cache\s*!=\s*null\s*:\s*\n\s*return\s+_cloud_tex_cache",
                        body) is not None,
          "守卫缺失 = 每次进大地图都重烘焙 229ms")
    check("B2b 缓存写回发生在函数末尾且赋给 static 变量",
          "_cloud_tex_cache = ImageTexture.create_from_image(img)" in body
          and "return _cloud_tex_cache" in body,
          "必须先写回 static 再 return，否则守卫永不命中")
    #B3 关键：不得用 set_pixel 逐像素（大头就是它）
    # 【判据自纠·首跑误报】首版判 `"set_pixel" not in body` 实测 FAIL，
    # 但 grep 显示 set_pixel 只出现在**文档行与注释**里，代码中已无
    # ⇒ 判据把注释当代码了。正解：只看 code_only 剔除注释后的代码。
    body_code = code_only(body)
    check("B3 不再用 Image.set_pixel 逐像素写（26 万次调用是大头）",
          "set_pixel" not in body_code,
          "只看剔除注释后的代码；set_pixel 出现在注释里正常（那是在解释为什么不用它）")
    check("B4 走 PackedByteArray + create_from_data 批量路径",
          "PackedByteArray" in body
          and "Image.create_from_data" in body,
          "批量填充 + 一次 set_data")
    # B5 视觉等价性：RGB 必须仍填白（云的暗色来自 modulate 乘算）
    check("B5 纹理 RGB 仍填 255（与原式 Color(1,1,1,a) 逐位等价）",
          re.search(r"buf\[o\]\s*=\s*255\s*\n\s*buf\[o \+ 1\]\s*=\s*255", body) is not None,
          "云的暗色来自 sp.modulate 乘算，RGB 填白才不会改变可见效果")
    # B6 alpha 换算口径与原 set_pixel 一致：a * 255
    check("B6 alpha 字节换算与原式一致（int(a*255)）",
          re.search(r"buf\[o \+ 3\]\s*=\s*int\(a\s*\*\s*255", body) is not None,
          "Image.set_pixel 内部也是 a*255 量化，换算口径变了就是视觉变更")
    check("B7 环面参数化与噪声参数未被改动（图案不变）",
          "20261001" in body and "fractal_octaves = 3" in body
          and "(1.6 + 0.55 * cos(v)) * cos(u) * 200.0" in body,
          "seed / octaves / 环面公式任一改动都会换掉云图案")

    # ---------------- C 组：假阳性对照
    # ---------------- C 组：交叉性质（防止 A/B 两组同源失效）
    # 「删掉缓存」不会让云消失 ⇒ A 组全绿；「让云消失」不影响缓存存在 ⇒ B 组全绿。
    # 故两组必须真的判不同性质，且都必须在场。判据本身恒真无意义，
    # 真正保证有效性的是反向验证（注入 I1/I2 分别让两组报红）。
    # 【判据自纠·首跑恒真】首版判 `len(A_KEYS) > 0 and len(B_KEYS) > 0`，
    # 而 A_KEYS/B_KEYS 从未被填充 ⇒ **恒为假**（恒真死值铁律）。
    # 正解：直接数本文件里check("A / check("B 的调用点数。
    # 【为什么这样判】删缓存不影响云存在 ⇒ A 组仍绿；让云消失不影响缓存
    # ⇒ B 组仍绿。两组都在场才构成交叉保护（有效性另由反向验证 I1/I2 证）。
    # 【判据自纠·二次误报】首版数错了对象 —— `src` 是**被测文件**
    #（world_ambience.gd），里面当然没有 check("A ⇒ 恒为 0。
    # 正解：数判据自身（`__file__`）里的调用点。
    with open(os.path.abspath(__file__), "r", encoding="utf-8") as _f:
        _self = _f.read()
    # 【判据自纠·三次误报】前两版分别数错了对象（数被测文件）与口径
    # （注释里的 `check("A` 字面量会被自己数进去 ⇒ 恒 ≥2 假通过）。
    # 正解：只数**行首缩进后紧跟的真实调用**（注释行以 # 开头，不会匹配）。
    _na = len([1 for ln in _self.split("\n")
               if re.match(r'\s{4}check\("A\d', ln)])
    _nb = len([1 for ln in _self.split("\n")
               if re.match(r'\s{4}check\("B\d', ln)])
    check("C0 A 组与 B 组都非空（两组判据都在场才能交叉保护）",
          _na > 0 and _nb > 0,
          "A 组 %d 项（正确性，无头真跑）/ B 组 %d 项（性能，源码层）；"
          "两组性质不同才能交叉保护" % (_na, _nb))

    print()
    print("  A 组 无头真跑：云 sprite 数/纹理尺寸/alpha 梯度/缓存复用")
    print("  B 组 源码层：static 缓存 + set_data 批量 + RGB 等价 + 图案不变")
    print()
    print("=" * 68)
    print("判定项：%d" % N[0])
    if FAILS:
        print("结果：FAIL（%d 项）" % len(FAILS))
        for f in FAILS:
            print("  [FAIL] %s" % f)
        return 1
    print("结果：PASS（0 FAIL）")
    return 0


if __name__ == "__main__":
    sys.exit(main())