# -*- coding: utf-8 -*-
"""把三套程序化 BGM 烘焙成二进制音频资源（构建期执行，非运行时）。

用法：
    python tools/_bake_bgm.py                # 烘焙全部三条曲
    python tools/_bake_bgm.py --only 1       # 只烘焙战斗曲（0 大地图 / 1 战斗 / 2 城内）

为什么要烘焙而不是运行时合成：
    GDScript 预渲染单曲 136 万~235 万采样 × 四层织体，实测合成耗时超过 100 秒
    （见 docs/audio/bgm_direction.md 第 11 章），放在播放链路里会冻结主线程数分钟。
    烘焙把这笔计算挪到构建期，运行时只剩 load()。

产物仍然是零素材：全部由本项目代码生成，可一键重生成，同 seed 逐样本可复现。
"""
import argparse
import os
import subprocess
import tempfile
import sys
import time

sys.stdout.reconfigure(encoding='utf-8')

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GODOT = r'D:/Godot/Godot_v4.7.2-stable_win64_console.exe'
PROBE_SRC = '''extends SceneTree

func _init() -> void:
	var tid := 0
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--tid="):
			tid = int(a.substr(6))
		elif a.begins_with("--out="):
			out = a.substr(6)
	if out == "":
		print("BAKE_ERR missing --out")
		quit(1)
		return
	var t0 := Time.get_ticks_msec()
	var s := BgmComposer.build_track(tid)
	var t_synth := Time.get_ticks_msec() - t0
	var bytes := PackedByteArray()
	bytes.resize(s.size() * 2)
	for i in range(s.size()):
		var v := clampf(s[i], -1.0, 1.0)
		var iv := clampi(int(round(v * 32767.0)), -32768, 32767)
		var u := iv & 0xFFFF
		bytes[i * 2] = u & 0xFF
		bytes[i * 2 + 1] = (u >> 8) & 0xFF
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = 22050
	st.stereo = false
	st.loop_mode = AudioStreamWAV.LOOP_FORWARD
	st.loop_begin = 0
	st.loop_end = s.size()
	st.data = bytes
	var err := ResourceSaver.save(st, out)
	print("BAKE tid=%d n=%d synth_ms=%d total_ms=%d err=%d mib=%.2f out=%s"
		% [tid, s.size(), t_synth, Time.get_ticks_msec() - t0, err,
		float(bytes.size()) / 1048576.0, out])
	quit()
'''

OUT_DIR = 'res://assets/audio/bgm'

TRACKS = [
    (0, 'world_map', '大地图（D 宫 72BPM 106.67s）'),
    (1, 'battle', '战斗（E 商 124BPM 61.94s）'),
    (2, 'city', '城内（B 羽 76BPM 6/8 75.79s）'),
]


def _with_probe(argv_head, argv_tail):
    """把烘焙探针写到 tests/（临时）后执行，保证本脚本自包含、可重复运行。

    注意 Godot 的参数顺序：`--script <脚本> -- <用户参数>`，脚本路径必须紧跟 --script。
    """
    tests = os.path.join(ROOT, 'tests')
    os.makedirs(tests, exist_ok=True)
    fd, path = tempfile.mkstemp(suffix='.gd', dir=tests)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(PROBE_SRC)
    try:
        return subprocess.run(argv_head + ['res://tests/' + os.path.basename(path)] + argv_tail,
                              cwd=ROOT, capture_output=True, text=True,
                              encoding='utf-8', errors='replace')
    finally:
        for extra in (path, path + '.uid'):
            if os.path.exists(extra):
                os.remove(extra)


def bake(tid, name, desc):
    out = '%s/%s.res' % (OUT_DIR, name)
    print('[%d/%d] 烘焙 %s -> %s' % (tid + 1, len(TRACKS), desc, out), flush=True)
    t0 = time.time()
    p = _with_probe([GODOT, '--headless', '--path', ROOT, '--script'],
                    ['--', '--tid=%d' % tid, '--out=%s' % out])
    lines = [l for l in (p.stdout or '').splitlines() if l.startswith('BAKE')]
    for l in lines:
        print('    ' + l, flush=True)
    if not lines:
        tail = (p.stdout or '')[-1500:] + (p.stderr or '')[-1500:]
        print('    无 BAKE 输出，exit=%d' % p.returncode)
        print('    ' + tail.replace('\n', '\n    '))
        return False
    print('    耗时 %.1f s' % (time.time() - t0), flush=True)
    return 'err=0' in lines[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--only', type=int, default=None, help='只烘焙指定曲号 0/1/2')
    a = ap.parse_args()

    todo = [t for t in TRACKS if a.only is None or t[0] == a.only]
    if not todo:
        print('--only 必须是 0/1/2')
        return 1

    ok = 0
    for tid, name, desc in todo:
        if bake(tid, name, desc):
            ok += 1
    print('完成：成功 %d / 目标 %d' % (ok, len(todo)))
    if ok != len(todo):
        return 1
    print('下一步：把 7 条 BGM 路径从 .ogg 指向这些 .res，再跑 --import 与三件套。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
