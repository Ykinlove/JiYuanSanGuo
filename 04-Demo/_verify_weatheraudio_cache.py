"""第七十三轮 · 雨声/风声缓存判据

为什么需要这个：`WeatherFx.make_rain_stream()` 与 `WorldAmbientAudio._make_wind()`
加了进程内缓存后，探针实测雨声 119.6ms→3μs、风声 116.2ms→2μs。
**这个降幅本身可疑** —— 可能是「真的省了重复合成」，也可能是
「缓存返回空值，雨声/风声彻底消失」而后者玩家听到的是「没声音了」，
属功能回归而非优化。

更隐蔽的一种失败：缓存若不满足确定性前提（函数里混进了无 seed 的
randf() 或全局 randi()），会把「每次内容不同」变成「永远同一个值」。
对循环音频来说这听起来还行，缺陷会被完全掩盖。**探针第④组
（清缓存重合成对拍）专治这一条** —— 前三组都发现不了。

所以判据必须同时锁（缺一不可）：
  A 组 无头真跑，验声音真的存在且字节/循环头正确
  A5确定性自证：清掉缓存重合成，字节必须与第一次逐位相同
  A6 三调用点同源：大地图包装层不得自己再合成一遍
  B 组 源码层：static 缓存 + 守卫位置 + 确定性前提（写死seed）
  B7 反向保护：鸟鸣/虫鸣**不得**被缓存（randomize 是防复读机的设计意图）
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FX = os.path.join(HERE, 'scripts', 'world', 'weather_fx.gd')
AMB = os.path.join(HERE, 'scripts', 'world', 'world_ambient_audio.gd')
WMAP = os.path.join(HERE, 'scripts', 'world', 'world_weather.gd')
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


def check(name, cond, detail=""):
    N[0] += 1
    tag = "PASS" if cond else "FAIL"
    if not cond:
        FAILS.append(name)
    print("  [%s] %s :: %s" % (tag, name, detail))


def main():
    print("=" * 68)
    print("第七十三轮 · 雨声/风声缓存判据（性能 + 正确性 + 确定性双向）")
    print("=" * 68)
    fx_src = read(FX)
    amb_src = read(AMB)
    fx_code = code_only(fx_src)
    amb_code = code_only(amb_src)

    # ---------------- A 组：无头真跑，验声音真的存在且有效
    res = os.path.join(HERE, "weatheraudio_probe_result.txt")
    if os.path.exists(res):
        os.remove(res)
    godot = r"D:\Godot\Godot_v4.7.2-stable_win64_console.exe"
    subprocess.run(
        [godot, "--headless", "--path", HERE, "--quit-after", "400",
         "res://tests/weatheraudio_probe.tscn"],
        cwd=HERE, capture_output=True, text=True,
        encoding="gbk", errors="replace", timeout=180)
    out = read(res) if os.path.exists(res) else ""
    lines = out.strip().split("\n") if out.strip() else []

    def val(key):
        for ln in lines:
            if ln.startswith(key + "="):
                return ln.split("=", 1)[1].strip()
        return None

    def num(key):
        return int(val(key) or -1)

    # A1 真跑必须出结果，否则后续全部读-1 变成假绿
    check("A1a 无头探针真跑成功（不是编译失败/未产出）",
          bool(lines) and len(lines) >= 27,
          "探针输出行数=%d（期望 27）" % len(lines))
    check("A1b 雨声字节数正确（=%d）" % num("rain_expect_bytes"),
          num("rain_bytes") == num("rain_expect_bytes")
          and num("rain_bytes") > 0,
          "实测 rain_bytes=%d expect=%d；为 0 = 雨声流是空的= 没声音"
          % (num("rain_bytes"), num("rain_expect_bytes")))
    check("A1c 风声字节数正确（=%d）" % num("wind_expect_bytes"),
          num("wind_bytes") == num("wind_expect_bytes")
          and num("wind_bytes") > 0,
          "实测 wind_bytes=%d expect=%d；为 0 = 风声流是空的 = 没声音"
          % (num("wind_bytes"), num("wind_expect_bytes")))

    # A2 循环头必须仍正确 —— 缓存最容易在这里写坏（loop_end 是采样数不是字节数）
    # 【LOOP_FORWARD == 1 实测】枚举真值由探针自证（rain_loop_forward 与
    # rain_loop_mode 同为 1），判据只比「两者相等 + loop_end 是字节数的一半」，
    # 不写死 1 —— 引擎换枚举值时这条会自动跟随，而写死就会假红。
    check("A2a 雨声循环头正确（LOOP_FORWARD + loop_end=采样数）",
          num("rain_loop_mode") == num("rain_loop_forward")
          and num("rain_loop_forward") > 0
          and num("rain_loop_end_ok") == 1,
          "实测 loop_mode=%d（LOOP_FORWARD=%d）loop_end=%d（须=字节数/2）"
          % (num("rain_loop_mode"), num("rain_loop_forward"),
             num("rain_loop_end")))
    check("A2b 风声循环头正确（LOOP_FORWARD）",
          num("wind_loop_mode") == num("wind_loop_forward"),
          "实测 wind loop_mode=%d期望 %d；不等 = 风会播一次就停"
          % (num("wind_loop_mode"), num("wind_loop_forward")))
    check("A2c 雨声采样率正确（22050）",
          num("rain_mix_rate_ok") == 1 and num("rain_mix_rate") == 22050,
          "实测 mix_rate=%d" % num("rain_mix_rate"))

    # A3 缓存真的被复用（同一实例，不是各自 new）
    check("A3a 雨声第二次调用命中缓存（同一实例）",
          val("rain_same_object") == "1" and val("rain_same_bytes") == "1",
          "same_object=%s same_bytes=%s；对象不同 = 预热白做、内存没省"
          % (val("rain_same_object"), val("rain_same_bytes")))
    check("A3b 风声第二次调用命中缓存（同一实例）",
          val("wind_same_object") == "1" and val("wind_same_bytes") == "1",
          "same_object=%s same_bytes=%s" % (val("wind_same_object"),
                                            val("wind_same_bytes")))

    # A4 性能确实生效（判warm 不是恒等于 0 的死值：冷启动须真的贵）
    check("A4a 雨声第二次显著更快（缓存生效）",
          num("rain_warm_us") * 10 < num("rain_cold_us")
          and num("rain_cold_us") > 1000,
          "冷 %dμs → 热 %dμs（提速 %sx）；冷启动须 >1000μs 否则本项是假绿"
          % (num("rain_cold_us"), num("rain_warm_us"), val("rain_speedup_x")))
    check("A4b 风声第二次显著更快（缓存生效）",
          num("wind_warm_us") * 10 < num("wind_cold_us")
          and num("wind_cold_us") > 1000,
          "冷 %dμs → 热 %dμs（提速 %sx）"
          % (num("wind_cold_us"), num("wind_warm_us"), val("wind_speedup_x")))

    # A5 确定性自证 —— 本组是本判据的核心，缺它前三组都可能被绕过
    check("A5a 雨声是确定性的（清缓存重合成字节不变）",
          val("rain_determinism") == "1",
          "determinism=%s；若为 0 说明合成里有非确定性来源，"
          "缓存会把「每次不同」固化成「永远同一个错值」" % val("rain_determinism"))
    check("A5b 风声是确定性的（清缓存重合成字节不变）",
          val("wind_determinism") == "1",
          "determinism=%s；同上" % val("wind_determinism"))

    # A6 大地图包装层必须同源（否则包装自己又合成一遍，白改）
    check("A6 大地图 WorldWeather 包装与 WeatherFx 同一实例",
          val("worldmap_is_weatherfx") == "1",
          "实测=%s；为 0 说明包装层绕过了缓存自己合成，"
          "大地图那79ms 一分没省" % val("worldmap_is_weatherfx"))

    # ---------------- B 组：源码层
    body_rain = func_body(fx_src, "make_rain_stream") or ""
    body_wind = func_body(amb_src, "_make_wind") or ""
    body_wrap = func_body(read(WMAP), "_make_rain") or ""
    check("B1 能取到两个合成函数体",
          len(body_rain) > 400 and len(body_wind) > 400,
          "雨声体长 %d / 风声体长 %d" % (len(body_rain), len(body_wind)))
    check("B2a 雨声有 static 缓存 + 守卫 + 早返回",
          re.search(r"static\s+var\s+_rain_stream_cache\s*:\s*AudioStreamWAV",
                    fx_src) is not None
          and re.search(r"if\s+_rain_stream_cache\s*!=\s*null\s*:\s*\n\s*return\s+_rain_stream_cache",
                        body_rain) is not None,
          "守卫缺失 = 每进一次场景重合成 15.4 万采样")
    check("B2b 雨声缓存写回赋给 static 变量后再 return",
          "_rain_stream_cache = _encode_wav(buf)" in body_rain
          and "return _rain_stream_cache" in body_rain,
          "必须先写回再return，否则守卫永不命中")
    check("B2c 风声有 static 缓存 + 守卫 + 早返回",
          re.search(r"static\s+var\s+_wind_cache\s*:\s*AudioStreamWAV",
                    amb_src) is not None
          and re.search(r"if\s+_wind_cache\s*!=\s*null\s*:\s*\n\s*return\s+_wind_cache",
                        body_wind) is not None
          and "_wind_cache = _encode_wav(buf, true)" in body_wind
          and "return _wind_cache" in body_wind,
          "同上，风声 13.2 万采样")
    # B3 缓存守卫必须早于第一个真正干活的语句（挪后就形同虚设）
    def _cache_read_before_work(body, guard, work_tokens):
        gi = body.find(guard)
        if gi < 0:
            return False
        works = [body.find(t) for t in work_tokens if body.find(t) >= 0]
        return (not works) or gi < min(works)
    check("B3a 雨声缓存守卫早于合成循环（挪后则形同虚设）",
          _cache_read_before_work(body_rain, "_rain_stream_cache != null",
                                  ["rng.seed", "for i in range(n)",
                                   "PackedFloat32Array"]),
          "与 A4 性能项同源判据：这里比位置，那里比时间")
    check("B3b 风声缓存守卫早于合成循环（挪后则形同虚设）",
          _cache_read_before_work(body_wind, "_wind_cache != null",
                                  ["rng.seed", "for i in range(n)",
                                   "PackedFloat32Array"]),
          "同上")
    # B4 确定性前提：seed 必须写死（这是缓存成立的前提，判据必须锁）
    check("B4a 雨声 rng.seed 仍写死 20261002（缓存的确定性前提）",
          "rng.seed = 20261002" in body_rain,
          "seed 被改成 randomize() 或删掉，缓存就成立在错误的假设上")
    check("B4b 风声 rng.seed 仍写死 20261001",
          "rng.seed = 20261001" in body_wind,
          "同上")
    # B5 合成参数未被改动（改了 = 音色变了，属功能变更不是优化）
    check("B5 雨声合成参数未被改动（seed/低通系数/时长/峰值）",
          "MIX_RATE" in body_rain and "RAIN_DUR" in body_rain
          and "lp_hi += 0.30" in body_rain and "lp_lo += 0.05" in body_rain
          and "/ peak * 0.42" in body_rain and "sr * 0.4" in body_rain,
          "低通系数/峰值/交叉淡化长度任一改动都会换掉音色")
    check("B6 风声合成参数未被改动（低通系数/包络/峰值）",
          "a := 0.045" in body_wind and "/ peak * 0.5" in body_wind
          and "sr * 0.35" in body_wind and "TAU * 3.0" in body_wind,
          "同上")
    check("B7 大地图包装层只是转发（不含自己的合成代码）",
          "WeatherFx.make_rain_stream()" in body_wrap
          and "rng" not in code_only(body_wrap)
          and "PackedFloat32Array" not in code_only(body_wrap),
          "包装层一旦自己合成，缓存就只对战斗/城内生效")
    # B8 反向保护：鸟鸣/虫鸣**不得**被缓存 ——
    #【为什么要单独锁这条】它们用 rng.randomize()，每次不同是**设计意图**
    #（源码注释原文：「随机音高/音量防复读机」）。若将来有人"顺手"也给它们
    # 加缓存，5~11 秒就会重复同一个音，玩家立刻听出循环感 —— 而这类缺陷
    # 编译期无感、探针也测不出（因为"合成成功"仍然是 true）。只能静态锁。
    body_bird = func_body(amb_src, "_synth_bird_song") or ""
    body_crick = func_body(amb_src, "_synth_cricket") or ""
    check("B8a 鸟鸣未被缓存（randomize 的防复读机意图必须保留）",
          "_wind_cache" not in body_bird and "_rain_stream_cache" not in body_bird
          and "rng.randomize()" in body_bird,
          "给randomize() 的合成加缓存 = 每 5~11s 重复同一个音")
    check("B8b 虫鸣未被缓存（同上）",
          "_wind_cache" not in body_crick and "_rain_stream_cache" not in body_crick
          and "rng.randomize()" in body_crick,
          "同上")
    check("B8c 两个静态缓存都只声明了一处（防重复声明/覆盖）",
          len(re.findall(r"static\s+var\s+_wind_cache\s*:", amb_src)) == 1
          and len(re.findall(r"static\s+var\s+_rain_stream_cache\s*:",
                             fx_src)) == 1,
          "重复声明 = 两个不同的存储，缓存命中率恒 0（等于没加）")

    # ---------------- C 组：交叉保护（防A/B 同源同时失效）
    # 「删掉缓存」不会让声音消失 ⇒ A 组里只有 A4 会红（性能），A1/A2/A5 仍绿；
    # 「让声音消失」不影响缓存是否存在 ⇒ B 组全绿。两组都必须在场才构成交叉保护。
    # 判据本身恒真无意义，真正保证有效性的是反向验证
    # （注入 I1 删缓存 ⇒须由 B 组报红；注入 I2 返回 null ⇒ 须由 A 组报红）。
    with open(os.path.abspath(__file__), "r", encoding="utf-8") as _f:
        _self = _f.read()
    # 【口径】只数行首缩进后紧跟的真实调用点 —— 注释行以 # 开头不会匹配。
    # 数错对象（数被测文件而非判据自身）会得到恒 0。数到注释里的字面量会假通过。
    _na = len([1 for ln in _self.split("\n") if re.match(r'\s{4}check\("A\d', ln)])
    _nb = len([1 for ln in _self.split("\n") if re.match(r'\s{4}check\("B\d', ln)])
    check("C0 A 组与 B 组都非空（两组判据都在场才能交叉保护）",
          _na > 0 and _nb > 0,
          "A 组 %d 项（正确性+确定性，无头真跑）/ B 组 %d 项（性能，源码层）；"
          "两组性质不同才能交叉保护" % (_na, _nb))

    print()
    print("  A 组 无头真跑：字节数/循环头/缓存复用/性能/确定性自证/三调用点同源")
    print("  B 组 源码层：static 缓存 + 守卫位置 + 确定性前提 + 参数不变")
    print("          + 反向保护（鸟鸣虫鸣禁止缓存）")
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
