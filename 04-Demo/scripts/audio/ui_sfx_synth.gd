extends RefCounted
class_name UiSfxSynth
## UI 音效合成器（四十一轮 2026-10-02，零外部素材）
##
## 【为什么单独成文件】
## assets/audio/sfx 下的 .ogg 全是 1~27 字节空桩（Godot 解不出），全部音效走运行时
## 合成；AudioManager 里那套合成基元已 700 行，UI 这一组音色（按钮/面板开合/铜钱）
## 有独立的时域设计（扫频带通、瞬态包络），再塞进去只会更难维护。故与 BgmSynth 同
## 范式独立成文件，由 AudioManager 的占位音分派调用。
##
## 【设计约束（UI 音的铁律）】
##   ① 短：按钮 ≤60ms，面板 ≤320ms，铜钱 ≤320ms —— UI 音是"确认手感"，不是音效表演。
##   ② 首尾必淡：任何非零起止都会在扬声器和低端耳机上爆 click（2ms 进 / 8ms 出）。
##   ③ 去直流：滤波后的残余 DC 会让耳机"噗"一声，编码前一律减均值。
##   ④ 不循环：loop_mode 保持默认禁用（短音循环=嗡鸣）。
##   ⑤ 确定性：固定种子，同一调用每次结果一致（便于探针断言与听感回归）。
##   ⑥ 峰值留余量：UI 音密集连点时叠加，单发归一到 0.38~0.52 而非 1.0。

const SR := 22050          ## 与 AudioManager.PLACEHOLDER_MIX_RATE 一致
const SEED := 20261002

## 目标峰值（UI 音留足叠加余量，见顶部约束⑥）
const PEAK_TAP := 0.44
const PEAK_PANEL_OPEN := 0.42
const PEAK_PANEL_CLOSE := 0.36
const PEAK_COINS := 0.50


# ---------- 对外：三条 UI 音色 ----------

## 按钮「嗒」：6ms 噪声瞬态（指甲/竹板触感）+ 木质共振双音（860/1720Hz），
## 55ms 收干净。比木鱼更短更干，连点不糊。
static func tap() -> PackedFloat32Array:
	var sr := float(SR)
	var n := int(sr * 0.055)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	for i in range(n):
		var t := float(i) / sr
		var transient := rng.randf_range(-1.0, 1.0) * exp(-t * 260.0) * 0.55
		var body := (sin(TAU * 860.0 * t) * 0.7 + sin(TAU * 1720.0 * t) * 0.25) * exp(-t * 78.0)
		out[i] = transient + body
	return _finish(out, PEAK_TAP)


## 面板展开：带通噪声中心频率 380→2400Hz 对数上扫（像卷轴抽开、绢帛摩擦），
## 300ms，尾段叠一记轻「嗒」表示"展开到位"。
static func panel_open() -> PackedFloat32Array:
	var sr := float(SR)
	var n := int(sr * 0.30)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var out := PackedFloat32Array()
	out.resize(n)
	# 状态变量滤波器（Chamberlin SVF）：系数逐采样更新即可扫频，比 RBJ 重算便宜
	var low := 0.0
	var band := 0.0
	var damp := 0.34          ## 1/Q：带通宽度
	for i in range(n):
		var t := float(i) / sr
		var k := float(i) / float(n - 1)
		var fc: float = 380.0 * pow(2400.0 / 380.0, k)
		var f := minf(2.0 * sin(PI * fc / sr), 1.9)   ## 稳定上限，防高 Q 自激
		var v := rng.randf_range(-1.0, 1.0)
		low += f * band
		var high: float = v - low - damp * band
		band += f * high
		# 包络：60ms 起振 → 缓降收尾（摩擦声由弱转强再消失）
		var env: float = minf(t / 0.06, 1.0) * exp(-maxf(0.0, t - 0.06) * 6.5)
		out[i] = band * env
	# 尾音：展开到位的轻「嗒」（0.22s 处，与主声叠不打架）
	_mix_at(out, 0.22, _tick(0.30))
	return _finish(out, PEAK_PANEL_OPEN)


## 面板收起：反向扫频 2400→420Hz，240ms，尾段一记更轻的「嗒」（合拢落扣）。
static func panel_close() -> PackedFloat32Array:
	var sr := float(SR)
	var n := int(sr * 0.24)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var out := PackedFloat32Array()
	out.resize(n)
	var low := 0.0
	var band := 0.0
	var damp := 0.34
	for i in range(n):
		var t := float(i) / sr
		var k := float(i) / float(n - 1)
		var fc: float = 2400.0 * pow(420.0 / 2400.0, k)
		var f := minf(2.0 * sin(PI * fc / sr), 1.9)
		var v := rng.randf_range(-1.0, 1.0)
		low += f * band
		var high: float = v - low - damp * band
		band += f * high
		var env: float = minf(t / 0.03, 1.0) * exp(-maxf(0.0, t - 0.03) * 8.0)
		out[i] = band * env
	_mix_at(out, 0.17, _tick(0.22))
	return _finish(out, PEAK_PANEL_CLOSE)


## 铜钱：三枚随机音高的金属「叮」，非谐泛音簇（铜器不是整数倍频）+ 各枚失谐，
## 错开 55~115ms（钱袋里几枚钱相碰，不是一次齐响）。
static func coins() -> PackedFloat32Array:
	var sr := float(SR)
	var total := 0.34
	var out := PackedFloat32Array()
	out.resize(int(sr * total))
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	# [起始秒, 基频Hz, 失谐倍数]（失谐让三枚钱不像同一个音复制三次）
	var pings := [
		[0.00, 1980.0, 1.000],
		[0.058, 2420.0, 1.017],
		[0.115, 1760.0, 0.986],
	]
	for p in pings:
		var t0 := float(p[0])
		var f0 := float(p[1]) * float(p[2])
		var n := int(sr * 0.18)
		# 非谐比：铜锣/铜钱类体鸣乐器分音非整数倍，纯整数倍会像风琴
		var parts: Array = [1.0, 1.73, 2.41, 3.17]
		var amps: Array = [1.0, 0.55, 0.32, 0.18]
		for i in range(n):
			var t := float(i) / sr
			var dst := int((t0 + t) * sr)
			if dst >= out.size():
				break
			var env := exp(-t * 42.0)
			var v := 0.0
			for k in range(parts.size()):
				v += float(amps[k]) * sin(TAU * f0 * float(parts[k]) * t)
			# 起振瞬态：金属接触的"啪"（前 8ms）
			var click := rng.randf_range(-1.0, 1.0) * exp(-t * 400.0) * 0.35
			out[dst] += (v * 0.5 + click) * env
	return _finish(out, PEAK_COINS)


# ---------- 内部辅助 ----------

## 面板尾音用的木质轻「嗒」（比 tap() 更弱更闷，只做落点提示）
static func _tick(amp: float) -> PackedFloat32Array:
	var sr := float(SR)
	var n := int(sr * 0.05)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 7
	for i in range(n):
		var t := float(i) / sr
		var transient := rng.randf_range(-1.0, 1.0) * exp(-t * 300.0) * 0.45
		var body := sin(TAU * 720.0 * t) * exp(-t * 95.0)
		out[i] = (transient + body) * amp
	return out


## 把一段短音叠到主缓冲的指定秒位（越界自动截断，不报错）
static func _mix_at(dst: PackedFloat32Array, at_sec: float, src: PackedFloat32Array) -> void:
	var off := int(at_sec * float(SR))
	for i in range(src.size()):
		var j := off + i
		if j >= dst.size():
			break
		dst[j] += float(src[i])


## 收尾：首尾淡入淡出（防爆 click）→ 去直流 → 峰值归一
static func _finish(s: PackedFloat32Array, peak: float) -> PackedFloat32Array:
	var n := s.size()
	if n <= 0:
		return s
	var fade_in := maxi(1, int(float(SR) * 0.002))
	var fade_out := maxi(1, int(float(SR) * 0.008))
	var out := PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		var v := float(s[i])
		if i < fade_in:
			v *= float(i) / float(fade_in)
		var from_end := n - 1 - i
		if from_end < fade_out:
			v *= float(from_end) / float(fade_out)
		out[i] = v
	# 【顺序有讲究】必须先淡入淡出再减均值：先减后淡，两端的不对称衰减会把直流
	# 又带回来（实测 tap 的残余直流 1.3e-3，超出探针 1e-4 判据）。
	var sum := 0.0
	for v in out:
		sum += float(v)
	var mean := sum / float(n)
	for i in range(n):
		out[i] = float(out[i]) - mean
	var mx := 0.0001
	for v in out:
		mx = maxf(mx, absf(v))
	for i in range(n):
		out[i] = float(out[i]) / mx * peak
	return out


## 编码成 16bit 单声道非循环 WAV（与 AudioManager._encode_wav 同参数口径）
static func encode(samples: PackedFloat32Array) -> AudioStreamWAV:
	var n := samples.size()
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in range(n):
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = SR
	st.stereo = false
	st.data = data
	return st
