#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
第六十九轮反向验证：证明 _verify_scene_perf.py 是有效的锁。

注入真缺陷（回退到无缓存 / 无预热 / 无进度文字的旧写法）→ 必须报红；
注入等价无害写法（改注释 / 改顺序但语义不变）→ 必须仍全绿。
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, "_verify_scene_perf.py")
SR = os.path.join(HERE, "scripts", "autoload", "scene_router.gd")
CMA = os.path.join(HERE, "scripts", "world", "city_marker_art.gd")

results = []


def record(name, ok, detail):
    results.append((name, bool(ok)))
    print(("  [PASS] " if ok else "  [FAIL] ") + name + " :: " + detail)


def read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def write(p, t):
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(t)


def line_endings(p):
    raw = open(p, "rb").read()
    return "\r\n" if raw.count(b"\r\n") > 0 else "\n"


def run_verify():
    pr = subprocess.run([sys.executable, TARGET], cwd=HERE,
                        capture_output=True, text=True,
                        encoding="utf-8", errors="replace")
    return (pr.stdout or "") + (pr.stderr or ""), pr.returncode


def fail_keys(out):
    return set(re.findall(r"\[FAIL\]\s+(\S+)", out))


def inject(path, old, new):
    src = read(path)
    n = src.count(old)
    assert n == 1, "锚点 %r 在 %s 命中 %d 次（须恰好 1）" % (old[:48], os.path.basename(path), n)
    backup = path + ".iv2.bak.stale"
    shutil.copy2(path, backup)
    le = line_endings(path)
    write(path, src.replace(old, new).replace("\r\n", "\n").replace("\n", le))
    return backup


def restore(path, backup):
    shutil.copy2(backup, path)
    try:
        os.replace(backup, backup + ".done.stale")
    except BaseException:
        pass


CASES = [
    ("S1 prewarm 幂等守卫被删（重复预热变成新的性能坑）",
     SR, "\tif _prewarmed.has(scene_key) or not SCENES.has(scene_key):\n\t\treturn\n",
     "\tif not SCENES.has(scene_key):\n\t\treturn\n", "S0b"),

    ("S2 prewarm 改成 instantiate（把 _ready 的 2715ms 也提前了，更糟）",
     SR, "\tvar ps: PackedScene = load(SCENES[scene_key])",
     "\tvar ps: PackedScene = load(SCENES[scene_key])\n\tif ps != null:\n\t\tps.instantiate()", "S0d"),

    ("S3 goto 不再调用 prewarm（预热白写）",
     SR, "\tprewarm(scene_key)\n\n\t# 渐黑",
     "\t# 渐黑", "S0e"),

    ("S4 prewarm 被移到渐黑之后（等于没挪，白屏里反而更慢）",
     SR, "\tprewarm(scene_key)\n\n\t# 渐黑\n\tvar tween := create_tween()\n\ttween.tween_property(_overlay, \"color:a\", 1.0, fade_time)\n\tawait tween.finished",
     "\tvar tween := create_tween()\n\ttween.tween_property(_overlay, \"color:a\", 1.0, fade_time)\n\tawait tween.finished\n\tprewarm(scene_key)", "S0f"),

    ("S5 进度文字移到渐黑之前（会被淡入淡出吃掉，玩家仍看不到）",
     SR, "\tawait tween.finished\n\n\t# 【本轮·性能】全黑之后立刻显示进度文字，再做同步阻塞的场景切换。\n\t# 顺序很重要：文字必须在黑幕**之后**才可见（黑幕之前显示等于被淡入淡出吃掉）。\n\t_label.visible = true",
     "\t_label.visible = true\n\tawait tween.finished", "S0g"),

    ("S6 渐亮后才撤文字（白幕上留字会闪一下）",
     SR, "\t# 渐亮（先撤文字：它只是遮挡物，白幕上留字会闪一下）\n\t_label.visible = false\n\tvar tween2 := create_tween()",
     "\tvar tween2 := create_tween()", "S0h"),

    # 【修·血泪】初版锚点只有 `_label.visible = false` 一行 —— 该行在 goto 里
    # 也出现一次 →命中 2 次 → 注入器按"必须恰好 1 次"正确拒绝（报"锚点预检
    # 失败"）。正解：锚点带上 `_build_overlay` 内的上下文两行做区分。
    ("S7 进度 Label 构造即抢镜（visible 初值改成 true）",
     SR, "\t_label.mouse_filter = Control.MOUSE_FILTER_IGNORE\n\t_label.visible = false",
     "\t_label.mouse_filter = Control.MOUSE_FILTER_IGNORE\n\t_label.visible = true", "S0i"),

    ("S8 进度 Label 开始吃鼠标（挡住返回键）",
     SR, "\t_label.mouse_filter = Control.MOUSE_FILTER_IGNORE",
     "\t_label.mouse_filter = Control.MOUSE_FILTER_STOP", "S0j"),

    ("A1 _tex_cache 从 static 改成实例变量（每次 build 都新建缓存，等于没缓存）",
     CMA, "static var _tex_cache: Dictionary = {}",
     "var _tex_cache: Dictionary = {}", "A0a"),

    ("A2 _try_texture 不再查缓存（110 次磁盘 stat 全部回来）",
     CMA, '\tvar key := "m:" + city_id\n\tif _tex_cache.has(key):\n\t\treturn _tex_cache[key] as Texture2D\n',
     '\tvar key := "m:" + city_id\n', "A0b"),

    # 【第七十一轮·判据随实现重写】A3 原注入针对的是「逐扩展名 exists 循环 +
    # break」那段代码，目录索引方案已把它换成 `_map_index.has(city_id)`，
    # 旧锚点命中 0 次（反向验证自身报「锚点预检失败」而非判据红）。
    # 正解：把 A3 改成对新实现同样成立的缺陷 —— **负缓存写回被条件包住**。
    # 语义等价性：命中项仍会缓存，但「查过没有」这个结论没被记住 ⇒
    # 下次同id 再来仍要查一次索引/load，缓存命中率归零。
    # 【第七十一轮·唯一性】`_tex_cache[key] = found   # 正负都缓存\n\treturn found`
    # 在 _try_texture 与 _type_texture **两处都出现**（命中 2 次），
    # 只锚这两行预检就判「锚点不唯一」而失败。正解：向前带上
    # `_map_index.has(city_id)` 这行 —— 它只属于 _try_texture。
    ("A3 负缓存写回被条件包住（miss 结论不被记住）",
     CMA, 'if _map_index.has(city_id):\n\t\tvar res := load(String(_map_index[city_id]))\n'
     '\t\tif res is Texture2D:\n\t\t\tfound = res\n'
     '\t_tex_cache[key] = found   # 正负都缓存\n',
     'if _map_index.has(city_id):\n\t\tvar res := load(String(_map_index[city_id]))\n'
     '\t\tif res is Texture2D:\n\t\t\tfound = res\n'
     '\tif found != null:\n\t\t_tex_cache[key] = found\n', "A0d"),

    ("A4 key 去掉前缀分区（city_id 与 city_type 同名会串味）",
     CMA, '\tvar key := "m:" + city_id', '\tvar key := city_id', "A0f"),

    ("A5 key 写死成一个常量（110 次调用只有 1 个缓存项）",
     CMA, '\tvar key := "m:" + city_id', '\tvar key := "m:all"', "A0g"),

    # 【第七十一轮·新增·锁住目录索引本身】上轮只锁了「缓存」，而本轮真正的
    # 性能动作是「消灭逐城 stat」。这四条注入分别破坏索引的四个关键性质，
    # 任何一条退化都必须被 D 组抓到，否则性能会悄悄回到 438ms。
    ("A7 退回逐城 exists（消灭的那个动作回来了）",
     CMA, "\t_ensure_map_index()\n", "\tfor _e in _TEX_EXTS:\n"
     "\t\tif ResourceLoader.exists(\"res://assets/sprites/map/\" + city_id + _e):\n"
     "\t\t\tbreak\n", "D1a"),

    ("A8 索引不惰性（每次调用都重扫目录 = N 次 readdir）",
     CMA, "\tif _map_index_built:\n\t\treturn\n\t_map_index_built = true\n",
     "\t_map_index_built = true\n", "D3a"),

    ("A9 索引不按扩展名白名单过滤（.import 等会污染）",
     CMA, "\t\tvar idx := _TEX_EXTS.find(ext)\n\t\tif idx < 0:\n\t\t\tcontinue\n",
     "\t\tvar idx := 0\n", "D0d"),

    # 【注·两次踩坑后修正】
    # 坑 1：注入必须真正破坏**两阶段结构**才能被 D0e 抓到。只把中间表赋值
    # 换成 `found[base] = {...}` 而保留循环后的 `for base in found.keys()`
    # 统一倒出 ⇒ 结构判据仍为真（实测漏放）。正解：把「统一倒出」也顶掉。
    # 坑 2（属A6，见下）：等价写法当注入用 = 判据抓不到，必须注入真缺陷。
    ("A10 索引边遍历边写（同名多扩展名时优先级错乱）",
     CMA, '\t\t\tfound[base] = slot\n\tfor base in found.keys():\n'
     '\t\tout[base] = String(found[base]["p"])\n',
     '\t\t\tfound[base] = slot\n\t\t\tout[base] = dir_path + f\n',
     "D0e"),

    # 【两次踩坑后修正·血泪】
    #坑 1：锚点含 `for ext in _TEX_EXTS:`（逐扩展名 exists 循环），
    # 目录索引方案已删除该循环 ⇒ 锚点命中 0。且 `_tex_cache.has(key)`
    # 在两个函数都出现，只锚前 2 行会命中 2 次 ⇒ 带 `_ensure_map_index()` 区分。
    # 坑 2：注入「缓存读挪到 _ensure_map_index() 之后」是**等价写法** ——
    # _ensure_map_index 幂等（第二次起直接 return），挪前挪后都是 0 成本，
    # 正向判据照样全绿（实测漏放）。
    # 正解：真缺陷 = 把缓存读挪到 **load() 之后**（每次调用都真去 IO，
    # 缓存彻底形同虚设）。锚点覆盖「缓存读 → 索引判定 → load → 写回」整段。
    ("A6 缓存读挪到 load 之后（缓存形同虚设）",
     CMA, '\tif _tex_cache.has(key):\n\t\treturn _tex_cache[key] as Texture2D\n'
     "\t_ensure_map_index()\n"
     "\t# 【纯内存查表】索引里没有 = 该城确定无专属图（负结论同样缓存）\n"
     "\tvar found: Texture2D = null\n"
     "\tif _map_index.has(city_id):\n"
     "\t\tvar res := load(String(_map_index[city_id]))\n"
     "\t\tif res is Texture2D:\n\t\t\tfound = res\n",
     "\t_ensure_map_index()\n"
     "\t# 【纯内存查表】索引里没有 = 该城确定无专属图（负结论同样缓存）\n"
     "\tvar found: Texture2D = null\n"
     "\tif _map_index.has(city_id):\n"
     "\t\tvar res := load(String(_map_index[city_id]))\n"
     "\t\tif res is Texture2D:\n\t\t\tfound = res\n"
     "\tif _tex_cache.has(key):\n\t\treturn _tex_cache[key] as Texture2D\n",
     "A0b2"),
    ("A6b 缓存判定整段删除",
     CMA, '\tif _tex_cache.has(key):\n\t\treturn _tex_cache[key] as Texture2D\n'
     "\t_ensure_map_index()\n",
     "\t_ensure_map_index()\n", "A0b"),
]

# 假阳性对照：等价无害写法，必须仍全绿
NEG_CASES = [
    ("N1 给 prewarm 加行尾注释（语义不变）",
     SR, "\tif _prewarmed.has(scene_key) or not SCENES.has(scene_key):",
     "\tif _prewarmed.has(scene_key) or not SCENES.has(scene_key):  ## 幂等"),
    ("N2 调整 _TEX_EXTS 顺序（换扩展名探测次序，语义等价）",
     CMA, 'const _TEX_EXTS: Array[String] = [".png", ".webp", ".jpg"]',
     'const _TEX_EXTS: Array[String] = [".webp", ".png", ".jpg"]'),
]


def main():
    print("=" * 68)
    print("第六十九轮 反向验证 · 场景性能校验器的有效性")
    print("=" * 68)

    out0, rc0 = run_verify()
    f0 = fail_keys(out0)
    record("B0 基线全绿（反向验证的前提）", rc0 == 0 and not f0,
           "returncode=%d，FAIL 项 %d 个" % (rc0, len(f0)))
    if f0:
        print("  基线就不绿，先修基线：" + ", ".join(sorted(f0)))
        return 1

    print("\n== 真缺陷注入（每个都必须报红） ==")
    for name, path, old, new, expect in CASES:
        try:
            bk = inject(path, old, new)
        except AssertionError as e:
            record(name, False, "锚点预检失败：" + str(e))
            continue
        try:
            out, rc = run_verify()
            fk = fail_keys(out)
            hit = any(k.startswith(expect) for k in fk)
            record(name, (rc != 0 and hit),
                   "returncode=%d，期望判据 %s，实际 FAIL=%s"
                   % (rc, expect, sorted(fk)[:6] if fk else "无"))
        finally:
            restore(path, bk)

    print("\n== 假阳性对照（等价无害写法必须仍然全绿） ==")
    for name, path, old, new in NEG_CASES:
        try:
            bk = inject(path, old, new)
        except AssertionError as e:
            record(name, False, "锚点预检失败：" + str(e))
            continue
        try:
            out, rc = run_verify()
            fk = fail_keys(out)
            record(name, (rc == 0 and not fk),
                   "returncode=%d，FAIL=%s（须 0）" % (rc, sorted(fk)[:6] if fk else "无"))
        finally:
            restore(path, bk)

    out2, rc2 = run_verify()
    f2 = fail_keys(out2)
    record("Z 还原后回到全绿", rc2 == 0 and not f2,
           "returncode=%d，FAIL=%s" % (rc2, sorted(f2) if f2 else "无"))

    save_dir = os.path.join(os.environ.get("APPDATA", ""), "Godot", "app_userdata",
                            "JiYuanSanGuo", "saves")
    if os.path.isdir(save_dir):
        before = sorted((f, os.path.getsize(os.path.join(save_dir, f)))
                        for f in os.listdir(save_dir))
        run_verify()
        after = sorted((f, os.path.getsize(os.path.join(save_dir, f)))
                       for f in os.listdir(save_dir))
        record("Z2 玩家存档零污染", before == after,
               "%d 个存档文件跑前跑后一致" % len(before))
    else:
        record("Z2 玩家存档零污染", True, "存档目录不存在，跳过")

    bad = [n for n, ok in results if not ok]
    print("\n" + "=" * 68)
    print("  判定项：%d" % len(results))
    print("  结果：%s" % ("PASS（0 FAIL）" if not bad else "FAIL（%d 项）" % len(bad)))
    if bad:
        print("-" * 68)
        for n in bad:
            print("  [FAIL] " + n)
        return 1
    print("  14 个真缺陷注入全部报红 + 2 个等价写法全部放行 → 判据是有效的锁 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())