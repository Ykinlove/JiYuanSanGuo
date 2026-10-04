"""第七十二轮 · 云影缓存判据的反向验证

目的：证明 `_verify_cloud_cache.py` 的 15 项是**真锁**而非摆设。
手法：注入两个真缺陷 → 判据必须报红 → 还原源码。

两个注入分别打向判据的两组（这是本判据的设计前提）：
  I1 删掉缓存守卫 ⇒ 云照样在（A 组应仍绿），但每次进大地图重烘焙 229ms
     ⇒ 必须由 **B 组（性能/源码层）** 报红。
  I2 缓存返回 null ⇒ 云影彻底消失（玩家看到「云没了」= 功能回归）
     ⇒ 必须由 **A 组（正确性/无头真跑）** 报红。
若某注入报不出预期那一组，说明该组判据是摆设。
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
AMB = os.path.join(HERE, 'scripts', 'world', 'world_ambience.gd')
PROBE = os.path.join(HERE, '_verify_cloud_cache.py')

# 【锚点构造·血泪】不要用 '\tif...' 这种转义串手写 —— 极易多写一层
# 转义（本轮就因此 count=0排查了很久，且一度误判成「源文件被污染」）。
# 正解：**从源文件按行号取真实行**，锚点与被测方永远一致，
# 且天然规避手写缩进/转义错误。
_lines = open(AMB, 'r', encoding='utf-8').read().split('\n')
_i = next(i for i, ln in enumerate(_lines)
          if ln.strip() == 'if _cloud_tex_cache != null:')
A_CACHE = _lines[_i] + '\n' + _lines[_i + 1] + '\n'
print('anchor lines = %d/%d' % (_i + 1, _i + 2))
print('anchor repr  = %r' % A_CACHE)


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


orig = open(AMB, 'r', encoding='utf-8').read()
assert orig.count(A_CACHE) == 1, 'anchor not unique: %d' % orig.count(A_CACHE)

CASES = [
    ("I1 缓存守卫被删（每次进大地图都重烘焙 229ms）",
     A_CACHE, "",
     "B"),   # 预期由性能组报红
    ("I2 缓存返回 null（云影彻底消失 = 功能回归）",
     A_CACHE,
     _lines[_i] + '\n\t\treturn null\n',
     "A"),   # 预期由正确性组报红
]

bad = 0
for name, old, new, want_grp in CASES:
    open(AMB, 'w', encoding='utf-8', newline='').write(orig.replace(old, new))
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
        open(AMB, 'w', encoding='utf-8', newline='').write(orig)

back = open(AMB, 'r', encoding='utf-8').read()
print('restored ok =', back == orig)

rc, fails = probe()
print('baseline after restore: returncode=%d  FAIL=%d' % (rc, len(fails)))
if rc != 0:
    bad += 1

print()
print('REVERSE_RESULT =', 'PASS' if (bad == 0 and back == orig) else 'FAIL')
sys.exit(0 if (bad == 0 and back == orig) else 1)