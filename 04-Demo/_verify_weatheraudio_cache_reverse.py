"""第七十三轮 · 雨声/风声缓存判据的反向验证

目的：证明 `_verify_weatheraudio_cache.py` 的 28 项是**真锁**而非摆设。
手法：注入真缺陷 → 判据必须报红 → 还原源码。

三个注入分别打向判据的三种性质（这是本判据的设计前提）：
  I1 删掉雨声缓存守卫 ⇒ 声音照样在（A 组除性能外仍绿），
     但每次进场景重合成 15.4 万采样 ⇒ 必须由 **B 组（性能/源码层）** 报红。
  I2 缓存返回 null ⇒ 雨声彻底消失（玩家听到「没声音了」= 功能回归）
     ⇒ 必须由 **A 组（正确性/无头真跑）** 报红。
  I3 把写死的 seed 换成 randomize() ⇒ 编译通过、合成成功、字节数不变、
     前两组判据**全部察觉不到**（它只是让每次内容不同）——
     只有 A5 的确定性自证能抓住。**这一条专治「看起来全绿其实已坏」。**
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FX = os.path.join(HERE, 'scripts', 'world', 'weather_fx.gd')
AMB = os.path.join(HERE, 'scripts', 'world', 'world_ambient_audio.gd')
PROBE = os.path.join(HERE, '_verify_weatheraudio_cache.py')


def lines_of(path):
    # 【锚点构造·血泪】不要用 '\tif...' 这种转义串手写—— 极易多写一层
    # 转义（云影那轮就因此 count=0 排查了很久，且一度误判成「源文件被污染」）。
    # 正解：**从源文件按行号取真实行**，锚点与被测方永远一致，
    # 且天然规避手写缩进/转义错误。
    return open(path, 'r', encoding='utf-8').read().split('\n')


def anchor(path, first_line_text, nlines=2):
    """取以 first_line_text（strip 后相等）开头的连续 nlines 行作锚点。"""
    ls = lines_of(path)
    i = next(k for k, ln in enumerate(ls) if ln.strip() == first_line_text)
    got = '\n'.join(ls[i:i + nlines]) + '\n'
    print('  anchor %-58s L%d/%d  %r'
          % (os.path.basename(path), i + 1, i + nlines, got))
    return got


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


print('=' * 68)
print('构造锚点（全部从源文件按行号取真实行）')
print('=' * 68)
A_RAIN = anchor(FX, 'if _rain_stream_cache != null:')
A_SEED = anchor(FX, 'rng.seed = 20261002', nlines=1)
print()

orig_fx = open(FX, 'r', encoding='utf-8').read()
orig_amb = open(AMB, 'r', encoding='utf-8').read()
assert orig_fx.count(A_RAIN) == 1, \
    'rain anchor not unique: %d' % orig_fx.count(A_RAIN)
assert orig_fx.count(A_SEED) == 1, \
    'seed anchor not unique: %d' % orig_fx.count(A_SEED)

# I3：把写死的 seed 换成 randomize()。
# 编译器不报错、合成照样成功、字节数/循环头全部不变 ⇒ 只有确定性自证能抓。
_NEW_SEED = '\trng.randomize()\n'

CASES = [
    ("I1 雨声缓存守卫被删（每次进场景重合成 15.4 万采样）",
     FX, A_RAIN, "", "B"),
    ("I2 雨声缓存返回 null（雨声消失 = 功能回归）",
     FX, A_RAIN, '\tif _rain_stream_cache != null:\n\t\treturn null\n', "A"),
    ("I3 写死的 seed 被换成 randomize()（前两组判据全绿，只有确定性自证能抓）",
     FX, A_SEED, _NEW_SEED, "A"),
]

bad = 0
for name, path, old, new, want_grp in CASES:
    src = orig_fx if path == FX else orig_amb
    open(path, 'w', encoding='utf-8', newline='').write(src.replace(old, new))
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
        open(path, 'w', encoding='utf-8', newline='').write(src)

back_fx = open(FX, 'r', encoding='utf-8').read()
back_amb = open(AMB, 'r', encoding='utf-8').read()
print()
print('restored fx  ok =', back_fx == orig_fx)
print('restored amb ok =', back_amb == orig_amb)

rc, fails = probe()
print('baseline after restore: returncode=%d  FAIL=%d' % (rc, len(fails)))
if rc != 0:
    bad += 1

print()
print('REVERSE_RESULT =', 'PASS'
      if (bad == 0 and back_fx == orig_fx and back_amb == orig_amb) else 'FAIL')
sys.exit(0 if (bad == 0 and back_fx == orig_fx and back_amb == orig_amb) else 1)
