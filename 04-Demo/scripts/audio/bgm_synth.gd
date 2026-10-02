class_name BgmSynth
extends RefCounted
## BGM 合成基元库（AUD-02 第 1 段：只做合成基元，不含作曲/循环编排逻辑）
##
## 供 audio_manager.gd 及后续作曲层调用的三个音色 + 四个工具函数，全部 static / 纯函数 /
## 由 seed 完全确定性驱动（同 seed 同参数 → 逐样本完全一致），便于离线渲染与回归比对。
##
## 【为什么单独成一个类】audio_manager.gd 已 ~700 行且混合 <合成/总线/UI/存档> 四类职责，
## 再加 BGM 合成会失控；本类只依赖 @GlobalScope + RandomNumberGenerator，可被 headless 探针直接调用。
##
## 【重要：本类输出的样点是浮点且允许瞬时超过 ±1.0】
## 所有热路径都不做硬削波（hard clip），因为峰值由多个音色叠加决定；最终 Peak 由
## normalize_with_headroom() 统一压到目标 dBFS。导出前必须走过该函数，否则 int16 编码会削顶。
##
## 【工程硬约束】Godot 4.7 / GDScript：
##   1. 强制 Tab 缩进；
##   2. 禁止 `var x := <含 Variant 的表达式>`，所有容器取值一律显式 float()/int() 包装；
##   3. 新增/改动带 class_name 的 .gd 后需跑 `godot --headless --path . --import` 刷全局类缓存。

## 占位音采样率，与 audio_manager.gd 的 PLACEHOLDER_MIX_RATE 保持一致
const MIX_RATE := 22050

## 抗混叠安全上限：分音频率 >= 该比例 × 采样率时直接丢弃（已含颤音引起的最大频偏高估余量）。
## 0.45 ⇒ 22050Hz 下 ≈ 9922Hz
const ALIAS_SAFE := 0.45

## 颤音深度上限（相对频偏 Δf/f）。超过此值的颤音 musically 会变成 siren
const VIB_REL_MAX := 0.012

## 32 位掩码（derive_seed 内部保证中间值恒为正数，规避 >> 符号位问题）
const _MASK32 := 0xFFFFFFFF
## FNV 乘法散列用的奇素数（< 2^31，保证与时淚 32 位值相乘不越 int64）
const _HASH_MUL := 1103515245


# ============================================================
# 1. 气声箫 / 笛
# ============================================================

## 气声箫（style="xiao"）或柔和笛（style="dizi_soft"）。
## 音色 = 4 次谐波正弦塔 + 带通滤波后的噪声构成的气声层；包络 = attack × release。
## release 按采样点索引收尾，保证 out[n-1] 精确趋 0 → 可安全混入环形缓冲。
## 【注意】'seed' 同时决定 r_v / β / air / attack / release 五个随机微参，故同一 (freq,style,seed)
## 永远得到同一段波形，不同音符务必换 note_index 派生 seed。
static func _synth_breath_flute(freq: float, dur: float, amp: float, style: String = "xiao", seed: int = 0) -> PackedFloat32Array:
	var sr := float(MIX_RATE)
	var n := int(sr * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	if n <= 1 or freq <= 0.0:
		return out

	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	var is_xiao := style == "xiao"
	# 谐波塔：箫偏纯净，笛的偶次更强并带极弱膜振
	var h2: float = 0.20
	var h3: float = 0.12
	var h4: float = 0.05
	if is_xiao:
		h2 = 0.14
		h3 = 0.07
		h4 = 0.03

	var air: float = rng.randf_range(0.18, 0.25) if is_xiao else rng.randf_range(0.10, 0.16)
	var atk_sec: float = rng.randf_range(0.080, 0.120) if is_xiao else rng.randf_range(0.025, 0.055)
	var rel_sec: float = rng.randf_range(0.100, 0.350)
	var rv: float = rng.randf_range(4.7, 5.3) if is_xiao else rng.randf_range(4.9, 5.6)
	var beta_rel: float = rng.randf_range(0.006, 0.012)

	# 气声层：白噪声 → 二阶带通(center ∈ [0.8f, 2.5f]) → 归一到单位 RMS。
	# 直接喂白噪声会刺耳；做 RMS 归一而不是峰值归一，是为了让高低音、不同 center 下的气声音量一致。
	var noise_raw := PackedFloat32Array()
	noise_raw.resize(n)
	for i in range(n):
		noise_raw[i] = rng.randf_range(-1.0, 1.0)
	var center := clampf(freq * rng.randf_range(0.8, 2.5), 40.0, sr * ALIAS_SAFE)
	var coeffs := _coeff_bandpass(center, 1.1, sr)
	var noise := _normalize_rms(_run_biquad(noise_raw, coeffs))

	var beta := _vib_beta(beta_rel, rv, freq)
	var n_atk := maxi(1, int(atk_sec * sr))
	var n_rel := maxi(1, int(rel_sec * sr))

	for i in range(n):
		var t := float(i) / sr
		var ph := TAU * freq * t + beta * sin(TAU * rv * t)
		var tone: float = 0.70 * sin(ph) + h2 * sin(2.0 * ph) + h3 * sin(3.0 * ph) + h4 * sin(4.0 * ph)
		if not is_xiao:
			# 笛膜：极弱的 28Hz 相位调制，只给一点点"沙"，幅度再大就退化成噪声了
			tone += 0.03 * sin(2.0 * ph + 0.35 * sin(TAU * 28.0 * t))
		var env := _env_attack(i, n_atk) * _env_release(i, n, n_rel)
		out[i] = amp * env * (tone + air * float(noise[i]))
	return out


# ============================================================
# 2. 拉弦持续音（二胡 / 胡琴质感的 pad）
# ============================================================

## 拉弦持续音。锯齿形谐波塔(1/k^1.25) + 弓噪声 + 颤音 + 揉弦(tremolo)，末端 tanh 软限幅。
## vibrato_depth 语义为【相对频偏 Δf/f】，内部换算成相位调制指数（见 _vib_beta）。
## 典型取值：世界/城内 attack=0.12~0.25, vibrato_rate=4.5~5.2, tremolo_depth=0.0；
##           战斗 attack=0.04~0.09, tremolo_rate=7.0~9.0, tremolo_depth=0.08~0.14。
static func _synth_bowed_sustain(freq: float, dur: float, amp: float, attack: float, vibrato_rate: float, vibrato_depth: float, tremolo_rate: float, tremolo_depth: float, seed: int = 0) -> PackedFloat32Array:
	var sr := float(MIX_RATE)
	var n := int(sr * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	if n <= 1 or freq <= 0.0:
		return out

	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	# 分音相位 θ_k：由 seed 确定性生成；正是这些固定相位差让每个音符有各自稳定的"弓压感"
	var phases := PackedFloat64Array()
	phases.resize(8)
	for k in range(8):
		phases[k] = rng.randf_range(0.0, TAU)

	# 抗混叠：本音(含颤音余量)的超 Nyquist 分音必须跳过，否则 aliasing 会折回成刺耳的非谐哔声
	var alias_max := sr * ALIAS_SAFE
	var fmax := freq * (1.0 + clampf(vibrato_depth, 0.0, VIB_REL_MAX))
	var k_max := mini(8, int(alias_max / maxf(fmax, 1.0)))

	# 弓噪声：LPF@1.8kHz 的稳态摩擦噪声，RMS 归一化到 1 后乘 0.05
	var noise_raw := PackedFloat32Array()
	noise_raw.resize(n)
	for i in range(n):
		noise_raw[i] = rng.randf_range(-1.0, 1.0)
	var lp := _coeff_lowpass(1800.0, 0.7071, sr)
	var bow := _normalize_rms(_run_biquad(noise_raw, lp))

	var beta := _vib_beta(vibrato_depth, vibrato_rate, freq)
	var rv := maxf(vibrato_rate, 0.001)
	var tau := maxf(attack, 1.0 / sr)
	var n_rel := maxi(1, int(sr * 0.12))   # 持续音统一 120ms release，够短不糊、够长不爆

	for i in range(n):
		var t := float(i) / sr
		var ph := TAU * freq * t + beta * sin(TAU * rv * t)
		var s: float = 0.0
		for k in range(1, k_max + 1):
			var fk := float(k)
			s += pow(fk, -1.25) * sin(fk * ph + float(phases[k - 1]))
		var trem := 1.0 + tremolo_depth * sin(TAU * tremolo_rate * t)
		var body := 0.82 * s + 0.05 * float(bow[i])
		var env := (1.0 - exp(-t / tau)) * _env_release(i, n, n_rel)
		out[i] = amp * env * trem * tanh(1.15 * body)
	return out


# ============================================================
# 3. 战号 / 唢呐式短音
# ============================================================

## 战号。起音从低 3.5% 指数滑入 + 6 次谐波方波化图腾("suona-like") + tanh 过驱。
## drive 越大谐波越密且越扁（1.4 温润 / 2.0 嘶吼），Y 除以 tanh(drive) 让不同 drive 的峰值保持一致。
static func _synth_war_horn(f0: float, dur: float, amp: float, drive: float = 1.7, seed: int = 0) -> PackedFloat32Array:
	var sr := float(MIX_RATE)
	var n := int(sr * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	if n <= 1 or f0 <= 0.0:
		return out

	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	var atk_sec: float = rng.randf_range(0.020, 0.035)
	var rel_sec: float = rng.randf_range(0.080, 0.140)
	var n_atk := maxi(1, int(atk_sec * sr))
	var n_rel := maxi(1, int(rel_sec * sr))

	# 静态的分音表 + 逐项抗混叠判定（高音'号'会自动退化成更暗的音色而不是发出哔叫）
	var harms: Array[float] = [1.0, 0.65, 0.42, 0.28, 0.18, 0.11]
	var alias_max := sr * ALIAS_SAFE
	var count := 0
	for k in range(harms.size()):
		if float(k + 1) * f0 < alias_max:
			count += 1
	if count <= 0:
		return out

	var gate := clampf(drive, 0.1, 6.0)
	var norm := 1.0 / maxf(tanh(gate), 1e-6)
	var sustain := 0.72
	var phase: float = 0.0

	for i in range(n):
		var t := float(i) / sr
		var ft := f0 * (1.0 - 0.035 * exp(-t / 0.055))
		phase += TAU * ft / sr          # 累加相位代替解析积分：drift 在 22kHz 下可忽略
		var h: float = 0.0
		for k in range(count):
			var fk := float(k + 1)
			h += float(harms[k]) * sin(fk * phase)
		var env: float = 1.0
		if t < atk_sec:
			env = 0.5 - 0.5 * cos(PI * t / atk_sec)
		else:
			env = sustain + (1.0 - sustain) * exp(-(t - atk_sec) / 0.090)
		env *= _env_release(i, n, n_rel)
		out[i] = amp * env * tanh(gate * h) * norm
	return out


# ============================================================
# 4. 环形缓冲混入
# ============================================================

## 把 src 按 gain 混入长度为环的 dst，索引用 (offset+i) % size 回卷。
## 【与现有 audio_manager._make_bgm_* 的关键差别】旧代码 `if dst < n` 会直接丢弃越过循环点的尾音，
## 导致每小节末尾一记延音被削断（听感"啪"一下）。此处保证尾音跨循环点无损回卷。
## 【为什么要 dst[j] += 生效】GDScript 里 Packed*Array 属引用语义传参，原地写下标会写回调用方。
## 【使用前提 / 交给作曲层的坑】src.size() 不应超过 dst.size()：超过时同一个槽位会被多圈叠加写入
## （环缓冲的数学正确行为，但听感上是音符自我重合）。第 2 段务必保证单音 dur < 循环长度。
static func mix_into_circular(dst: PackedFloat32Array, src: PackedFloat32Array, offset: int, gain: float) -> void:
	var n := dst.size()
	if n <= 0 or src.is_empty():
		return
	var m := src.size()
	var start := ((offset % n) + n) % n
	for i in range(m):
		var j := (start + i) % n
		dst[j] += float(src[i]) * gain


# ============================================================
# 5. 确定性 seed 派生
# ============================================================

## 由 (曲号, 段号, 乐句号, 声部号, 音符序号) 确定性派生合成 seed。
## FNV-1a 变体 + xorshift avalanche：相邻 note_index 的结果必然不同且无明显线性相关。
## 所有中间值都限制在 32 位正数域，规避 int64 溢出与算术右移符号位扩散。
static func derive_seed(track_id: int, section: int, phrase: int, voice: int, note_index: int) -> int:
	var h: int = 2166136261
	h = ((h ^ _fold32(track_id)) * 16777619) & _MASK32
	h = ((h ^ _fold32(section)) * 16777619) & _MASK32
	h = ((h ^ _fold32(phrase)) * 16777619) & _MASK32
	h = ((h ^ _fold32(voice)) * 16777619) & _MASK32
	h = ((h ^ _fold32(note_index)) * 16777619) & _MASK32
	h = (h ^ (h >> 13)) & _MASK32
	h = (h * _HASH_MUL) & _MASK32
	h = (h ^ (h >> 17)) & _MASK32
	h = (h * _HASH_MUL) & _MASK32
	h = (h ^ (h >> 15)) & _MASK32
	return h


# ============================================================
# 6. 全曲峰值归一化
# ============================================================

## 先扫全曲绝对峰值，再【统一】缩放到目标峰值 dBFS。
## 严禁逐段各自归一化（那会抹掉声部间的配器平衡、并让每个乐句听起来一样响）。
## 返回新数组，不修改入参。
static func normalize_with_headroom(samples: PackedFloat32Array, target_peak_db: float) -> PackedFloat32Array:
	var out := samples.duplicate()
	var peak: float = 0.0
	for i in range(out.size()):
		var v := absf(float(out[i]))
		if v > peak:
			peak = v
	if peak < 1e-9:
		return out
	var target := db_to_linear(target_peak_db)
	if target <= 0.0:
		return out
	var g := target / peak
	for i in range(out.size()):
		out[i] = float(out[i]) * g
	return out


# ============================================================
# 7. 等功率接缝（把文件末尾接上它自己的续写尾段）
# ============================================================

## 无缝循环接缝。extended = 渲染到 N + blend_samples 的加长版，head = extended 的前 N 个
## （N = extended.size() - blend_samples）。
##
## 语义不是"淡出到静音"，而是：某声部的尾音在 extended 里继续跑过了循环点，把这段续写 (extended[N..N+M))
## 以 cos/sin 等功率交叉淡化，盖回文件开头 —— 接缝处既有尾音续接、又不损失能量。
##
## 返回长度 N 的新数组，不修改入参。
static func apply_equal_power_wrap_blend(head: PackedFloat32Array, extended: PackedFloat32Array, blend_samples: int) -> PackedFloat32Array:
	var out := head.duplicate()
	var n := extended.size() - blend_samples
	if n <= 0:
		return out
	out.resize(n)
	if blend_samples <= 1:
		return out
	var m := mini(blend_samples, mini(n, head.size()))
	for j in range(m):
		var x := float(j) / float(blend_samples - 1)
		var fade_out_v := cos(PI * 0.5 * x)   # 续写尾段权重：j=0 处为 1
		var fade_in_v := sin(PI * 0.5 * x)    # 原开头权重：j=M-1 处为 1
		out[j] = float(extended[n + j]) * fade_out_v + float(head[j]) * fade_in_v
	return out


# ============================================================
# 内部：确定性散列 / 包络 / 滤波器 / 单位化
# ============================================================

## 把任意 int 折叠到 32 位正数域并做 avalanche（乘数 < 2^31 保证不越 int64）
static func _fold32(v: int) -> int:
	var x: int = v & _MASK32
	x = (x * _HASH_MUL) & _MASK32
	x = (x ^ (x >> 16)) & _MASK32
	x = (x * _HASH_MUL) & _MASK32
	x = (x ^ (x >> 14)) & _MASK32
	x = (x * _HASH_MUL) & _MASK32
	x = (x ^ (x >> 12)) & _MASK32
	return x


## 颤音相位调制指数。vibrato_depth 是【相对频偏 Δf/f】（不是 Hz！）
## Δf_max = β × r_v ⇒ β = (Δf/f) × f / r_v。对 clamp 到 VIB_REL_MAX 防止深颤变警笛。
static func _vib_beta(vib_rel_depth: float, vib_rate: float, freq: float) -> float:
	var d := clampf(vib_rel_depth, 0.0, VIB_REL_MAX)
	return d * freq / maxf(vib_rate, 0.001)


## raised-cosine 起音（i=0 时为 0，i>=n_atk 后为 1），比线性干净、比指数好预测
static func _env_attack(i: int, n_atk: int) -> float:
	if n_atk <= 0:
		return 1.0
	var x := float(mini(i, n_atk)) / float(n_atk)
	return 0.5 - 0.5 * cos(PI * x)


## 索引域 release：保证最后一个采样精确趋 0（时间域 release 会留下 ~1e-3 的尾巴，
## 在循环点表现为周期性"哒"声），乐器尾音必须能安全跨循环点。
static func _env_release(i: int, n: int, n_rel: int) -> float:
	if n_rel <= 0 or n <= 1:
		return 1.0
	var start := maxi(0, n - n_rel)
	if i <= start:
		return 1.0
	var span := n - 1 - start
	if span <= 0:
		return 0.0
	var x := float(i - start) / float(span)
	return 0.5 + 0.5 * cos(PI * x)


## RBJ 带通（恒 skirt gain，峰值增益 1）系数，返回 [b0,b1,b2,a1,a2]（已除以 a0）
static func _coeff_bandpass(center: float, q: float, sr: float) -> PackedFloat64Array:
	var w0 := TAU * center / sr
	var cs := cos(w0)
	var alpha := sin(w0) / (2.0 * maxf(q, 0.05))
	var a0 := 1.0 + alpha
	var c := PackedFloat64Array()
	c.resize(5)
	c[0] = alpha * q / a0
	c[1] = 0.0
	c[2] = -alpha * q / a0
	c[3] = -2.0 * cs / a0
	c[4] = (1.0 - alpha) / a0
	return c


## RBJ 低通（Q=0.707  Butterworth）系数，返回 [b0,b1,b2,a1,a2]（已除以 a0）
static func _coeff_lowpass(cutoff: float, q: float, sr: float) -> PackedFloat64Array:
	var w0 := TAU * cutoff / sr
	var cs := cos(w0)
	var alpha := sin(w0) / (2.0 * maxf(q, 0.05))
	var a0 := 1.0 + alpha
	var c := PackedFloat64Array()
	c.resize(5)
	c[0] = (1.0 - cs) * 0.5 / a0
	c[1] = (1.0 - cs) / a0
	c[2] = (1.0 - cs) * 0.5 / a0
	c[3] = -2.0 * cs / a0
	c[4] = (1.0 - alpha) / a0
	return c


## 二阶 IIR（直接 II 型转 I 型差分）单次前向滤波
static func _run_biquad(src: PackedFloat32Array, c: PackedFloat64Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(src.size())
	if src.is_empty():
		return out
	var b0 := float(c[0])
	var b1 := float(c[1])
	var b2 := float(c[2])
	var a1 := float(c[3])
	var a2 := float(c[4])
	var x1: float = 0.0
	var x2: float = 0.0
	var y1: float = 0.0
	var y2: float = 0.0
	for i in range(src.size()):
		var x0 := float(src[i])
		var y0: float = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
		x2 = x1
		x1 = x0
		y2 = y1
		y1 = y0
		out[i] = y0
	return out


## 归一化到单位 RMS 并对离群峰值加软膝（tanh knee，默认把波峰因数压到 ~2.0）。
## 【为什么用 RMS 而不是峰值】气声/弓噪的响度主要由 RMS 决定，按峰值归一会让不同中心频率下
## 音量漂移；且单样本高斯尖峰并无听感意义（会随滤波器 Q 值抖动）。
## 【为什么还要加软膝】带通后的白噪声波峰因数实测高达 ~3.8，直接按 spec 的 air 系数叠加会把
## 单音推到 1.42（远超满刻度）。压过峰因数后 RMS 基本不变、听感不变，但瞬时峰值收敛到 ~2σ，
## 成品音符 amp=1.0 时的实测峰值落在 1.1 附近，留出合理混音余量。
static func _normalize_rms(src: PackedFloat32Array, crest_cap: float = 2.0) -> PackedFloat32Array:
	var out := src.duplicate()
	if out.is_empty():
		return out
	var acc: float = 0.0
	for i in range(out.size()):
		var v := float(out[i])
		acc += v * v
	var rms := sqrt(acc / float(out.size()))
	if rms < 1e-9:
		return out
	var g := 1.0 / rms
	var cap := maxf(crest_cap, 0.25)
	for i in range(out.size()):
		var x := float(out[i]) * g
		out[i] = cap * tanh(x / cap)
	return out
