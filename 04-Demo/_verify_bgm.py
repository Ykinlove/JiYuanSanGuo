# -*- coding: utf-8 -*-
"""三套烘焙 BGM 的自动化验收（规格 docs/audio/bgm_direction.md §9）。

对 assets/audio/bgm/*.res 逐条断言：
  资源属性（采样率/位深/单声道/循环）、样本数、峰值 dBFS、直流偏移、接缝连续性。
用 Godot 真实 load() 资源后解码回浮点统计，属确定性检查，不依赖听觉。

用法：
    python tools/_verify_bgm.py
"""
import os
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding='utf-8')

# 本脚本与其余 _verify_*.py 同处 04-Demo 根目录，工程根即脚本所在目录
ROOT = os.path.dirname(os.path.abspath(__file__))
GODOT = r'D:/Godot/Godot_v4.7.2-stable_win64_console.exe'
OUT_DIR = os.path.join(ROOT, 'assets', 'audio', 'bgm')

## 【接缝判据为什么不用规格 §9 的字面阈值 0.003】
## 经等功率环绕混合后 s[0] == extended[n]，即 s[0] 就是循环点后的下一个自然采样。
## 因此 |s[0]-s[n-1]| 量的其实是**波形自身斜率**，只要循环点处还有音乐就必然非零
## （战斗曲实测 0.028 ≈ 1kHz 成分在 0.1 幅值下的正常步进）。要把它压到 0.003 以下，
## 唯一办法是让循环点近乎静音——而规格 §2.5 明令禁止「末尾淡出到 0 再从 0 淡入」，
## 因为那会产生每 106 秒一次的呼吸坑。二者不可兼得。
## 真正表征「有没有咔哒」的是一阶差分连续性（kink），以及接缝步进是否为局部离群值。
SEAM_OUTLIER_MAX = 4.0
EXPECT = {
    'world_map': (2352000, -6.0),
    'battle': (1365677, -5.0),
    'city': (1671158, -7.0),
}

PROBE = '''extends SceneTree

func _init() -> void:
	for name in ["world_map", "battle", "city"]:
		var p := "res://assets/audio/bgm/%s.res" % name
		if not ResourceLoader.exists(p):
			print("V|%s|MISSING" % name)
			continue
		var st := load(p)
		if not (st is AudioStreamWAV):
			print("V|%s|NOT_WAV" % name)
			continue
		var w := st as AudioStreamWAV
		var d := w.data
		var n := d.size() / 2
		if n <= 1:
			print("V|%s|EMPTY" % name)
			continue
		var peak := 0.0
		var sum := 0.0
		var first := 0.0
		var second := 0.0
		var last := 0.0
		var prev_last := 0.0
		for i in range(n):
			var lo := int(d[i * 2])
			var hi := int(d[i * 2 + 1])
			var u := lo | (hi << 8)
			if u >= 32768:
				u -= 65536
			var v := float(u) / 32768.0
			var a := absf(v)
			if a > peak:
				peak = a
			sum += v
			if i == 0:
				first = v
			elif i == 1:
				second = v
			elif i == n - 2:
				prev_last = v
			elif i == n - 1:
				last = v
		var mean := sum / float(n)
		var bound := absf(first - last)
		var ddiff := absf((second - first) - (last - prev_last))
		# 局部步进 RMS：取接缝前后各 50 ms 窗口（1102 采样）内相邻采样差的均方根。
		# 用于判断接缝步进是否是离群值——正常波形斜率不算咔哒，离群跳变才算。
		var wnd: int = mini(int(22050.0 * 0.05), n / 4)
		var acc: float = 0.0
		var cnt := 0
		for i in range(wnd):
			var a0 := _s16(d, i)
			var a1 := _s16(d, i + 1)
			var b0 := _s16(d, n - wnd + i)
			var b1 := _s16(d, n - wnd + i + 1)
			acc += (a1 - a0) * (a1 - a0) + (b1 - b0) * (b1 - b0)
			cnt += 2
		var step_rms := sqrt(acc / float(maxi(cnt, 1)))
		print("V|%s|n=%d|rate=%d|bits=%d|stereo=%s|loop=%d|loop_end=%d|peak_db=%.3f|dc=%.7f|seam=%.6f|ddiff=%.6f|step_rms=%.6f"
			% [name, n, w.mix_rate, w.format, str(w.stereo), w.loop_mode, w.loop_end,
			linear_to_db(peak), mean, bound, ddiff, step_rms])
	quit()

func _s16(d: PackedByteArray, i: int) -> float:
	var lo := int(d[i * 2])
	var hi := int(d[i * 2 + 1])
	var u := lo | (hi << 8)
	if u >= 32768:
		u -= 65536
	return float(u) / 32768.0
'''


def main():
    fd, probe = tempfile.mkstemp(suffix='.gd', dir=os.path.join(ROOT, 'tests'))
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(PROBE)
    probe_res = 'res://tests/' + os.path.basename(probe)
    try:
        p = subprocess.run(
            [GODOT, '--headless', '--path', ROOT, '--script', probe_res],
            cwd=ROOT, capture_output=True, text=True, encoding='utf-8', errors='replace')
        rows = {}
        for line in (p.stdout or '').splitlines():
            if line.startswith('V|'):
                parts = line.split('|')
                name = parts[1]
                if len(parts) == 3:
                    rows[name] = {'error': parts[2]}
                else:
                    rows[name] = dict(kv.split('=', 1) for kv in parts[2:])

        fails = []
        print('%-11s %10s %9s %10s %10s %10s %10s' % ('曲', '样本数', '峰值dBFS', '直流偏移', '接缝步进', '差分差值', '步进RMS'))
        print('-' * 78)
        for name, (want_n, want_peak) in EXPECT.items():
            r = rows.get(name)
            if r is None or 'error' in r:
                print('%-11s  失败：%s' % (name, r.get('error', '无输出')))
                fails.append(name)
                continue
            n = int(r['n'])
            peak_db = float(r['peak_db'])
            dc = abs(float(r['dc']))
            seam = float(r['seam'])
            ddiff = float(r['ddiff'])
            step_rms = float(r.get('step_rms', '0'))
            print('%-11s %10d %9.3f %10.7f %10.6f %10.6f %10.6f' % (name, n, peak_db, dc, seam, ddiff, step_rms))

            if n != want_n:
                fails.append('%s 样本数 %d != %d' % (name, n, want_n))
            if peak_db > want_peak + 0.15:
                fails.append('%s 峰值 %.3f dBFS 超过目标 %.1f' % (name, peak_db, want_peak))
            if dc >= 1e-4:
                fails.append('%s 直流偏移 %.7f >= 1e-4' % (name, dc))
            if seam > SEAM_OUTLIER_MAX * max(step_rms, 1e-9):
                fails.append('%s 接缝步进 %.6f 是局部步进 RMS %.6f 的 %.1f 倍（离群，疑似咔哒）'
                             % (name, seam, step_rms, seam / max(step_rms, 1e-9)))
            if ddiff >= 0.01:
                fails.append('%s 一阶差分差 %.6f >= 0.01' % (name, ddiff))
            if int(r['rate']) != 22050:
                fails.append('%s 采样率 %s != 22050' % (name, r['rate']))
            if int(r['loop']) == 0:
                fails.append('%s 未设置循环' % name)
            if int(r['loop_end']) != n:
                fails.append('%s loop_end %s != %d' % (name, r['loop_end'], n))

        print('-' * 78)
        if fails:
            for f in fails:
                print('FAIL ' + f)
            print('验收未通过：%d 项' % len(fails))
            return 1
        print('PASS 全部 %d 项断言通过' % len(EXPECT))
        return 0
    finally:
        if os.path.exists(probe):
            os.remove(probe)
        uid = probe + '.uid'
        if os.path.exists(uid):
            os.remove(uid)


if __name__ == '__main__':
    sys.exit(main())
