class_name BgmComposer
extends RefCounted
## 三套程序化古风 BGM 作曲层（AUD-02 第 2 段）
##
## 依据 docs/audio/bgm_direction.md：
##   大地图 D 宫 72BPM 4/4  32 小节 → 2,352,000 samples（106.67 s）
##   战斗   E 商 124BPM 4/4 32 小节 → 1,365,677 samples（61.94 s）
##   城内   B 羽 76BPM 6/8  48 小节 → 1,671,158 samples（75.79 s）
##
## 每条曲都是 A → A' → B → A'' 四段，四层织体（低音/伴奏/主旋律/打击），
## 乐句按规格给的原形 + 变奏规则展开，跨循环尾音走环形叠加 + 等功率环绕混合，
## 最后统一归一化留出峰值余量。全部由 track_id + 段/句/声部/音符派生的 seed 驱动，逐样本可复现。
##
## 【本文件自带拨弦与打击基元的理由】BgmSynth 只交付了箫/拉弦/战号三个旋律音色，
## 伴奏与打击层仍缺；且 audio_manager 的 _synth_pluck 是 autoload 成员函数，
## 无法在 --script 模式的 headless 探针里调用（该模式不加载 autoload）。
## 因此本类自带纯 static 版本，保证验收探针可离线跑。
##
## 【工程硬约束】Godot 4.7 / GDScript：Tab 缩进；禁止 `var x := <含 Variant 的表达式>`。

const SR := 22050

## 三曲目标样本数（规格 §2.5 / §3.5 / §4.5）
const WORLD_N := 2352000
const BATTLE_N := 1365677
const CITY_N := 1671158

## 环绕混合的溢出尾段时长（秒）。规格要求 100~120 ms
const SPILL_SEC := 0.12

## 三曲成品目标峰值（dBFS），规格 §1.3
const WORLD_PEAK_DB := -6.0
const BATTLE_PEAK_DB := -5.0
const CITY_PEAK_DB := -7.0

## track_id：0 大地图 / 1 战斗 / 2 城内
const T_WORLD := 0
const T_BATTLE := 1
const T_CITY := 2


# ============================================================
# 对外入口
# ============================================================

## 构建指定曲并返回可直接喂 _encode_wav 的 Float32 样本（已归一化、已做无缝接缝）
static func build_track(track_id: int) -> PackedFloat32Array:
	match track_id:
		T_BATTLE:
			return _build_battle()
		T_CITY:
			return _build_city()
		_:
			return _build_world()


static func track_samples(track_id: int) -> int:
	match track_id:
		T_BATTLE:
			return BATTLE_N
		T_CITY:
			return CITY_N
		_:
			return WORLD_N


## 收尾：环形尾音已在写入时回卷，这里再把溢出尾段等功率盖回开头，最后统一归一化
static func _finish(buf: PackedFloat32Array, spill: int, target_peak_db: float) -> PackedFloat32Array:
	var wrapped := BgmSynth.apply_equal_power_wrap_blend(buf, buf, spill)
	# 必须先去直流再归一化：战号的 tanh 波形整形与打击瞬态都是单侧的，混音后残留
	# 1.5e-4 ~ 2.8e-4 的直流分量（规格 §9 要求 < 1e-4）。直流不产生听觉音高，但会
	# 白占 1 bit 动态、并在循环点表现为固定偏置，故在此统一扣除。
	_remove_dc(wrapped)
	return BgmSynth.normalize_with_headroom(wrapped, target_peak_db)


## 扣除整曲均值（直流分量）。就地修改，不返回新数组。
static func _remove_dc(s: PackedFloat32Array) -> void:
	var n := s.size()
	if n <= 0:
		return
	var sum: float = 0.0
	for i in range(n):
		sum += float(s[i])
	var mean: float = sum / float(n)
	for i in range(n):
		s[i] = float(s[i]) - mean


# ============================================================
# 拨弦（Karplus-Strong，分数延迟修正音准）
# ============================================================

## 【为什么必须分数延迟】audio_manager 的 _synth_pluck 用 `period = int(sr/freq)` 整数延迟，
## 在 22050 Hz 下量化误差显著：440Hz 偏 4 音分可接受，但 2093Hz 会偏近 90 音分（近乎半个音）。
## 这里对延迟线做线性插值读取，把音准误差压到 1 音分以内，拨弦才敢承担伴奏层的密集音型。
static func pluck(freq: float, dur: float, amp: float, seed: int) -> PackedFloat32Array:
	var sr := float(SR)
	var n := int(sr * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	if n <= 1 or freq <= 0.0:
		return out

	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	var d := sr / freq
	var base := int(floor(d))
	var L := maxi(2, base)
	# floor() 属 @GlobalScope 返回 Variant，不能直接 :=（工程铁律）
	var frac: float = d - float(base)

	var line := PackedFloat32Array()
	line.resize(L)
	for i in range(L):
		line[i] = rng.randf_range(-1.0, 1.0)

	# 每 0.35 s 衰减到 ~37%，比原版的 0.14 s 慢，拨弦余韵更长、更像古琴
	var decay := exp(-2.9 / sr)
	var level: float = 1.0
	var idx := 0
	for i in range(n):
		var cur := float(line[idx])
		var nxt := float(line[(idx + 1) % L])
		# 依赖 frac 的运算同样要显式标注，否则链式推断失败
		var filtered: float = (cur * (1.0 - frac) + nxt * frac) * 0.9965
		out[i] = filtered * level
		line[idx] = filtered
		idx = (idx + 1) % L
		level *= decay
	# 末端 15 ms 强制收尾，保证可安全跨循环点
	var n_rel := mini(n, int(sr * 0.015))
	if n_rel > 1:
		for j in range(n_rel):
			var i := n - n_rel + j
			var x := float(j) / float(n_rel - 1)
			out[i] *= 0.5 + 0.5 * cos(PI * x)
	for i in range(n):
		out[i] *= amp
	return out


# ============================================================
# 打击基元
# ============================================================

## 战鼓：低频正弦下滑 + 噪声瞬态。**必须有 2 ms attack**——
## 规格 §3.5 明确：首拍鼓若从非零瞬态起，即使首样本为 0，首段斜率仍会产生 click。
static func perc_drum(f0: float, dur: float, amp: float, seed: int) -> PackedFloat32Array:
	var sr := float(SR)
	var n := int(sr * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	if n <= 1:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var n_atk := maxi(1, int(sr * 0.002))
	var phase: float = 0.0
	var noise_hp: float = 0.0
	var prev_x: float = 0.0
	for i in range(n):
		var t := float(i) / sr
		var ft := f0 * (1.0 + 0.9 * exp(-t / 0.03))
		phase += TAU * ft / sr
		var body := sin(phase) * exp(-t / (dur * 0.35))
		var x := rng.randf_range(-1.0, 1.0)
		# 一阶高通做噪声瞬态，去掉直流与低频浑浊
		noise_hp = 0.85 * (noise_hp + x - prev_x)
		prev_x = x
		var click := noise_hp * exp(-t / 0.008) * 0.35
		var env: float = 1.0
		if i < n_atk:
			env = 0.5 - 0.5 * cos(PI * float(i) / float(n_atk))
		out[i] = amp * env * (body + click)
	var n_rel := mini(n, int(sr * 0.02))
	for j in range(n_rel):
		var i := n - n_rel + j
		var x := float(j) / float(n_rel - 1)
		out[i] *= 0.5 + 0.5 * cos(PI * x)
	return out


## 低锣：非谐分音簇 + 噪声击点，只作段落标点
static func perc_gong(dur: float, amp: float, seed: int) -> PackedFloat32Array:
	var sr := float(SR)
	var n := int(sr * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	if n <= 1:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var ratios := PackedFloat32Array([1.0, 1.73, 2.41, 3.16, 4.27])
	var decays := PackedFloat32Array([2.6, 3.4, 4.2, 5.5, 7.0])
	var f0: float = rng.randf_range(78.0, 96.0)
	var cnt := ratios.size()
	for i in range(n):
		var t := float(i) / sr
		var v: float = 0.0
		for k in range(cnt):
			var f := f0 * float(ratios[k])
			if f >= sr * 0.45:
				continue
			v += sin(TAU * f * t + float(k)) * exp(-t * float(decays[k]))
		v += rng.randf_range(-1.0, 1.0) * exp(-t * 60.0) * 0.25
		out[i] = amp * v * 0.30
	var n_rel := mini(n, int(sr * 0.03))
	for j in range(n_rel):
		var i := n - n_rel + j
		var x := float(j) / float(n_rel - 1)
		out[i] *= 0.5 + 0.5 * cos(PI * x)
	return out


## 木鱼/梆子：短促木质点击，城内专用
static func perc_woodfish(freq: float, dur: float, amp: float, seed: int) -> PackedFloat32Array:
	var sr := float(SR)
	var n := int(sr * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	if n <= 1:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var n_atk := maxi(1, int(sr * 0.001))
	for i in range(n):
		var t := float(i) / sr
		var v := sin(TAU * freq * t) * exp(-t / 0.022)
		v += sin(TAU * freq * 2.71 * t) * exp(-t / 0.012) * 0.4
		v += rng.randf_range(-1.0, 1.0) * exp(-t / 0.004) * 0.5
		var env: float = 1.0
		if i < n_atk:
			env = 0.5 - 0.5 * cos(PI * float(i) / float(n_atk))
		out[i] = amp * env * v * 0.5
	return out


## 磬：两个非谐分音（1.0 / 2.76），城内段落标点
static func perc_chime(freq: float, dur: float, amp: float, seed: int) -> PackedFloat32Array:
	var sr := float(SR)
	var n := int(sr * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	if n <= 1:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var n_atk := maxi(1, int(sr * 0.002))
	for i in range(n):
		var t := float(i) / sr
		var v: float = 0.0
		v += sin(TAU * freq * t) * exp(-t * 3.2)
		if freq * 2.76 < sr * 0.45:
			v += sin(TAU * freq * 2.76 * t) * exp(-t * 5.0) * 0.38
		v += rng.randf_range(-1.0, 1.0) * exp(-t * 80.0) * 0.10
		var env: float = 1.0
		if i < n_atk:
			env = 0.5 - 0.5 * cos(PI * float(i) / float(n_atk))
		out[i] = amp * env * v * 0.45
	return out


# ============================================================
# 通用：把一批 [freq, start_sec, dur_sec, amp] 事件混入环形缓冲
# ============================================================

static func _mix_events(buf: PackedFloat32Array, events: Array, voice: int, kind: int, seed: int) -> void:
	var sr := float(SR)
	for e in events:
		var freq: float = float(e[0])
		var start: float = float(e[1])
		var dur: float = float(e[2])
		var amp: float = float(e[3])
		if freq <= 0.0:
			continue
		var s: int = BgmSynth.derive_seed(0, kind, voice, int(start * 100.0), int(freq))
		var w: PackedFloat32Array
		match kind:
			0:
				w = pluck(freq, dur, amp, s)
			1:
				w = BgmSynth._synth_breath_flute(freq, dur, amp, "xiao", s)
			2:
				w = BgmSynth._synth_breath_flute(freq, dur, amp, "dizi_soft", s)
			3:
				w = BgmSynth._synth_war_horn(freq, dur, amp, 1.7, s)
			_:
				w = pluck(freq, dur, amp, s)
		BgmSynth.mix_into_circular(buf, w, int(start * sr), 1.0)


static func _mix_perc(buf: PackedFloat32Array, events: Array, voice: int, kind: int) -> void:
	var sr := float(SR)
	for e in events:
		var freq: float = float(e[0])
		var start: float = float(e[1])
		var dur: float = float(e[2])
		var amp: float = float(e[3])
		var s: int = BgmSynth.derive_seed(0, 90 + kind, voice, int(start * 100.0), int(freq * 10.0))
		var w: PackedFloat32Array
		match kind:
			0:
				w = perc_drum(freq, dur, amp, s)
			1:
				w = perc_gong(dur, amp, s)
			2:
				w = perc_woodfish(freq, dur, amp, s)
			_:
				w = perc_chime(freq, dur, amp, s)
		BgmSynth.mix_into_circular(buf, w, int(start * sr), 1.0)


# ============================================================
# 曲 1：大地图（D 宫，72 BPM，4/4，32 小节）
# ============================================================

## 乐句原形（单位：拍）。每条 2 小节 = 8 拍。freq=0 表示休止占位（由调用方跳过）
const _W1 := [[587.33, 0.0, 1.0], [659.25, 1.0, 1.0], [739.99, 2.0, 1.0], [880.00, 3.0, 1.0],
		[987.77, 4.0, 2.0], [880.00, 6.0, 1.0], [739.99, 7.0, 1.0]]
const _W2 := [[587.33, 0.0, 2.0], [440.00, 2.0, 1.0], [587.33, 3.0, 1.0], [659.25, 4.0, 1.0],
		[739.99, 5.0, 1.0], [659.25, 6.0, 1.0], [587.33, 7.0, 1.0]]
const _W3 := [[739.99, 0.0, 1.0], [880.00, 1.0, 1.0], [987.77, 2.0, 2.0], [880.00, 4.0, 1.0],
		[739.99, 5.0, 1.0], [659.25, 6.0, 1.0], [440.00, 7.0, 1.0]]
const _W4 := [[987.77, 0.0, 1.0], [880.00, 1.0, 1.0], [739.99, 2.0, 1.0], [659.25, 3.0, 1.0],
		[587.33, 4.0, 3.0]]


static func _build_world() -> PackedFloat32Array:
	var sr := float(SR)
	var n := WORLD_N
	var spill := int(sr * SPILL_SEC)
	var buf := PackedFloat32Array()
	buf.resize(n + spill)

	var beat := 60.0 / 72.0          # 0.8333 s
	var bar := beat * 4.0
	var sec_beat := bar * 2.0        # 一个乐句 2 小节

	# ---- 低音层：每 2 小节换一次气的持续低弦，根音在 D2/A2/D3 间走 ----
	var roots := PackedFloat32Array([73.42, 73.42, 110.00, 73.42, 146.83, 110.00, 73.42, 110.00])
	var seg := bar * 2.0
	for i in range(16):
		var f := float(roots[i % roots.size()])
		var seed: int = BgmSynth.derive_seed(T_WORLD, i / 4, i, 0, int(f * 10.0))
		var w := BgmSynth._synth_bowed_sustain(f, seg + 0.35, 0.22, 0.20, 5.0, 0.004, 0.0, 0.0, seed)
		BgmSynth.mix_into_circular(buf, w, int(float(i) * seg * sr), 1.0)

	# ---- 主旋律层：四段，每段 4 个乐句 ----
	var phrases := [_W1, _W2, _W1, _W4,          # A
			_W1, _W2, _W1, _W4,                  # A'（伴奏加密）
			_W3, _W2, _W3, _W4,                  # B
			_W1, _W2, _W1, _W4]                  # A''
	for pi in range(phrases.size()):
		var section: int = pi / 4
		var base_t := float(pi) * sec_beat
		var melody: Array = []
		var ph: Array = phrases[pi]
		for k in range(ph.size()):
			var e: Array = ph[k]
			var freq: float = float(e[0])
			var start_b: float = float(e[1])
			var dur_b: float = float(e[2])
			# 变奏：A'' 只保留结构音（第 1/3/5/7 个）
			if section == 3 and k % 2 == 1:
				continue
			# B 段第 2 句走 W2 的逆行轮廓
			var freq2 := freq
			if section == 2 and pi % 4 == 1:
				var idx := ph.size() - 1 - k
				freq2 = float(ph[idx][0])
			# A' 段把 W2 的低音 A4 抬到 A5
			if section == 1 and freq < 500.0:
				freq2 = 880.00
			melody.append([freq2, base_t + start_b * beat, dur_b * beat * 1.6, 0.20])
		_mix_events(buf, melody, pi, 1, 0)

	# ---- 伴奏层：空五度与五声分解，弱拍回声 ----
	var accomp: Array = []
	var acc_scale := PackedFloat32Array([146.83, 220.00, 293.66, 329.63, 369.99, 440.00, 493.88])
	var rng := RandomNumberGenerator.new()
	rng.seed = BgmSynth.derive_seed(T_WORLD, 7, 0, 0, 1)
	var t_acc := 0.0
	var acc_i := 0
	while t_acc < float(n) / sr - 0.2:
		var section: int = int(t_acc / (sec_beat * 4.0))
		var density := 1.0 + float(section) * 0.25     # A' 之后每小节从 2 音增到 3 音
		var per_bar := 2.0 if section == 0 else minf(2.0 + density - 1.0, 3.0)
		for b in range(int(per_bar)):
			var f: float = float(acc_scale[rng.randi() % acc_scale.size()])
			var off := (float(b) + rng.randf_range(0.35, 0.75)) * beat * 2.0
			accomp.append([f, t_acc + off, 1.4, 0.13])
			acc_i += 1
		t_acc += bar

	_mix_events(buf, accomp, 1, 0, 0)

	# ---- 打击层：低鼓每 2 小节 1~2 记，锣只标 B 段入口与回归 ----
	var perc: Array = []
	for b in range(16):
		var sec: int = b / 4
		var t0 := float(b) * bar * 2.0
		if sec == 0:
			if b % 2 == 0:
				perc.append([92.0, t0, 0.55, 0.16])
		elif sec == 1:
			perc.append([92.0, t0, 0.55, 0.20])
			perc.append([78.0, t0 + beat * 2.0, 0.45, 0.12])
		elif sec == 2:
			perc.append([92.0, t0, 0.60, 0.26])
			perc.append([78.0, t0 + beat * 2.0, 0.45, 0.16])
		else:
			if b < 14:
				perc.append([92.0, t0, 0.50, 0.14])
	_mix_perc(buf, perc, 0, 0)
	# 锣：B 段入口与 A'' 回归各一记
	_mix_perc(buf, [[0.0, sec_beat * 8.0, 1.6, 0.30], [0.0, sec_beat * 12.0, 1.8, 0.26]], 1, 1)

	return _finish(buf, spill, WORLD_PEAK_DB)


# ============================================================
# 曲 2：战斗（E 商，124 BPM，4/4，32 小节）
# ============================================================

## 乐句以八分音符为一格，每条 2 小节 = 16 格
const _T1 := [[329.63, 0], [329.63, 1], [440.00, 2], [493.88, 3], [329.63, 4], [369.99, 5],
		[440.00, 6], [369.99, 7], [329.63, 8], [329.63, 9], [293.66, 10], [246.94, 11],
		[329.63, 12], [369.99, 13], [329.63, 14]]
const _T2 := [[246.94, 0], [329.63, 1], [369.99, 2], [440.00, 3], [493.88, 4], [440.00, 5],
		[369.99, 6], [329.63, 7], [293.66, 8], [329.63, 9], [246.94, 10], [293.66, 11],
		[329.63, 12], [329.63, 14]]
const _T3 := [[329.63, 0], [493.88, 1], [440.00, 2], [369.99, 3], [329.63, 4], [369.99, 5],
		[440.00, 6], [493.88, 7], [587.33, 8], [493.88, 9], [440.00, 10], [369.99, 11],
		[329.63, 12], [293.66, 13], [246.94, 14], [329.63, 15]]
const _T4 := [[293.66, 0], [329.63, 1], [369.99, 2], [329.63, 3], [246.94, 4], [293.66, 5],
		[329.63, 6], [369.99, 7], [440.00, 8], [369.99, 9], [329.63, 10], [293.66, 11],
		[246.94, 12], [329.63, 14]]


static func _build_battle() -> PackedFloat32Array:
	var sr := float(SR)
	var n := BATTLE_N
	var spill := int(sr * SPILL_SEC)
	var buf := PackedFloat32Array()
	buf.resize(n + spill)

	var beat := 60.0 / 124.0
	var eighth := beat * 0.5
	var bar := beat * 4.0
	var sec_beat := bar * 2.0

	# ---- 低音层：2 小节换根音，B 段开 8 Hz 轻颤 ----
	var roots := PackedFloat32Array([82.41, 82.41, 123.47, 82.41, 164.81, 123.47, 82.41, 164.81])
	for i in range(16):
		var sec: int = i / 4
		var f := float(roots[i % roots.size()])
		var trem_d: float = 0.10 if sec == 2 else 0.0
		var trem_r: float = 8.0 if sec == 2 else 0.0
		var atk: float = 0.05 if sec >= 2 else 0.08
		var seed: int = BgmSynth.derive_seed(T_BATTLE, sec, i, 0, int(f * 10.0))
		var w := BgmSynth._synth_bowed_sustain(f, sec_beat + 0.25, 0.26, atk, 5.0, 0.005, trem_r, trem_d, seed)
		BgmSynth.mix_into_circular(buf, w, int(float(i) * sec_beat * sr), 1.0)

	# ---- 伴奏层：八分 ostinato，每 2 小节删 2~5 格 ----
	var phrases := [_T1, _T2, _T1, _T4, _T1, _T2, _T1, _T4, _T3, _T2, _T3, _T4, _T1, _T2, _T1, _T4]
	var rng := RandomNumberGenerator.new()
	rng.seed = BgmSynth.derive_seed(T_BATTLE, 3, 0, 0, 2)
	for pi in range(phrases.size()):
		var sec: int = pi / 4
		var base_t := float(pi) * sec_beat
		var ph: Array = phrases[pi]
		var skip := 2 if sec == 3 else 3
		var arr: Array = []
		for k in range(ph.size()):
			arr.append(k)
		arr.shuffle()
		var drop := {}
		for d in range(mini(skip, arr.size())):
			drop[arr[d]] = true
		var accomp: Array = []
		for k in range(ph.size()):
			if drop.has(k):
				continue
			var e: Array = ph[k]
			accomp.append([float(e[0]), base_t + float(e[1]) * eighth, 0.55, 0.17])
		_mix_events(buf, accomp, pi, 0, 0)

	# ---- 主旋律层：战号只抽每句第 1/5/9/13 格附近的 A4/B4/D5 锚点并延长 ----
	for pi in range(phrases.size()):
		var sec: int = pi / 4
		if sec == 0 and pi % 4 < 2:
			continue                       # A 段前两句号角不进入（规格：第 7~8 小节才回答）
		var base_t := float(pi) * sec_beat
		var ph: Array = phrases[pi]
		var horn: Array = []
		for k in range(ph.size()):
			var slot: int = int(ph[k][1])
			if slot != 0 and slot != 4 and slot != 8 and slot != 12:
				continue
			var f := float(ph[k][0])
			if f < 380.0:
				f = 440.00                 # E4/F#4 只作引子，核心锚点抬到 A4 以上
			if f > 600.0:
				f = 587.33
			horn.append([f, base_t + float(slot) * eighth, 0.85, 0.20])
		_mix_events(buf, horn, pi, 3, 0)

	# ---- 打击层：三种鼓模板轮换，B 段才允许八分滚奏 ----
	var perc: Array = []
	for b in range(16):
		var sec: int = b / 4
		var t0 := float(b) * sec_beat
		var which: int = (b / 2) % 3
		if sec <= 1:
			if which == 0:
				perc.append([82.0, t0, 0.30, 0.30])
				perc.append([70.0, t0 + beat * 2.0, 0.26, 0.18])
			elif which == 1:
				perc.append([82.0, t0, 0.30, 0.30])
				perc.append([70.0, t0 + beat * 3.5, 0.24, 0.16])
			else:
				perc.append([82.0, t0, 0.30, 0.30])
				perc.append([70.0, t0 + beat * 2.0, 0.24, 0.15])
				perc.append([70.0, t0 + beat * 2.5, 0.22, 0.13])
		elif sec == 2:
			for s in range(8):
				var a := 0.32 if s % 2 == 0 else 0.18
				perc.append([82.0, t0 + float(s) * beat * 0.5, 0.22, a])
		else:
			perc.append([82.0, t0, 0.30, 0.26])
			if b < 14:
				perc.append([70.0, t0 + beat * 2.0, 0.24, 0.14])
	_mix_perc(buf, perc, 2, 0)
	# 低锣：B 段入口一记
	_mix_perc(buf, [[0.0, sec_beat * 8.0, 1.2, 0.34]], 3, 1)

	return _finish(buf, spill, BATTLE_PEAK_DB)


# ============================================================
# 曲 3：城内（B 羽，76 BPM，6/8，48 小节）
# ============================================================

## 6/8：以附点四分为一拍，每小节 2 拍 = 6 个八分。乐句 2 小节 = 12 个八分格
const _C1 := [[246.94, 0, 3], [293.66, 3, 1], [329.63, 4, 1], [369.99, 5, 1],
		[329.63, 6, 3], [293.66, 9, 3]]
const _C2 := [[369.99, 0, 3], [440.00, 3, 1], [369.99, 4, 1], [329.63, 5, 1],
		[293.66, 6, 3], [246.94, 9, 3]]
const _C3 := [[293.66, 0, 1], [329.63, 1, 1], [369.99, 2, 1], [440.00, 3, 3],
		[369.99, 6, 1], [329.63, 7, 1], [293.66, 8, 1], [246.94, 9, 3]]
const _C4 := [[329.63, 0, 3], [293.66, 3, 1], [246.94, 4, 1], [293.66, 5, 1],
		[369.99, 6, 3], [246.94, 9, 3]]


static func _build_city() -> PackedFloat32Array:
	var sr := float(SR)
	var n := CITY_N
	var spill := int(sr * SPILL_SEC)
	var buf := PackedFloat32Array()
	buf.resize(n + spill)

	var beat := 60.0 / 76.0            # 附点四分
	var eighth := beat / 3.0
	var bar := beat * 2.0
	var sec_beat := bar * 2.0          # 一个乐句 2 小节

	# ---- 低音层：每 4 小节换一次，极轻 ----
	var roots := PackedFloat32Array([123.47, 185.00, 123.47, 185.00])
	for i in range(12):
		var f := float(roots[i % roots.size()])
		var seed: int = BgmSynth.derive_seed(T_CITY, i / 6, i, 0, int(f * 10.0))
		var w := BgmSynth._synth_bowed_sustain(f, bar * 4.0 + 0.3, 0.14, 0.22, 4.8, 0.003, 0.0, 0.0, seed)
		BgmSynth.mix_into_circular(buf, w, int(float(i) * bar * 4.0 * sr), 1.0)

	# ---- 主旋律层：6/8 短句，长音多于短音 ----
	var phrases := [_C1, _C2, _C1, _C3, _C2, _C4,          # A
			_C1, _C2, _C3, _C1, _C2, _C4,                  # A'
			_C3, _C2, _C3, _C3, _C2, _C4,                  # B
			_C1, _C2, _C4, _C2, _C1, _C4]                  # A''
	var rng := RandomNumberGenerator.new()
	rng.seed = BgmSynth.derive_seed(T_CITY, 5, 0, 0, 3)
	for pi in range(phrases.size()):
		var sec: int = pi / 6
		var base_t := float(pi) * sec_beat
		var ph: Array = phrases[pi]
		var melody: Array = []
		for k in range(ph.size()):
			var e: Array = ph[k]
			var freq: float = float(e[0])
			var slot: int = int(e[1])
			var dur_e: int = int(e[2])
			# A'' 删去 25%~40% 起音
			if sec == 3 and rng.randf() < 0.35:
				continue
			# B 段第二次出现 C3 时把 A4 改为 F#4
			if sec == 2 and freq > 420.0 and pi >= 15:
				freq = 369.99
			# 每 6 小节仅一次高音 A4
			if freq > 420.0 and (pi % 3) != 1:
				freq = 369.99
			melody.append([freq, base_t + float(slot) * eighth, float(dur_e) * eighth * 1.25, 0.16])
		_mix_events(buf, melody, pi, 2, 0)

	# ---- 伴奏层：6/8 中在「1、4」或「1、5」起音的软拨 ----
	var accomp: Array = []
	var acc_scale := PackedFloat32Array([246.94, 293.66, 369.99, 440.00])
	var t_acc := 0.0
	while t_acc < float(n) / sr - 0.3:
		var sec: int = int(t_acc / (sec_beat * 6.0))
		var f: float = float(acc_scale[rng.randi() % acc_scale.size()])
		accomp.append([f, t_acc, 1.2, 0.11])
		var off := 3.0 if rng.randf() < 0.5 else 4.0
		if sec != 3 or rng.randf() > 0.4:
			accomp.append([float(acc_scale[rng.randi() % acc_scale.size()]), t_acc + off * eighth, 1.0, 0.09])
		t_acc += bar
	_mix_events(buf, accomp, 4, 0, 0)

	# ---- 打击层：木鱼每 2~4 小节一次，磬每 12 小节最多一次 ----
	var perc: Array = []
	for b in range(48):
		if b % 3 == 0 and b < 44:
			perc.append([920.0, float(b) * bar, 0.09, 0.10])
	_mix_perc(buf, perc, 5, 2)
	_mix_perc(buf, [[587.33, sec_beat * 6.0 * 4.0, 1.4, 0.14]], 6, 3)

	return _finish(buf, spill, CITY_PEAK_DB)
