extends ColorRect
class_name DayNightTint
## 大地图昼夜 / 时辰氛围层（纯演出，零新资源）
##
## 全屏 ColorRect，由 world_map 插到 $UI 最底层（index 0）：
## 只染地图世界（地形 / 城池 / 部队），不盖 HUD / 面板 / 摇杆。
##
## 颜色来源（两段叠加，按半透明层合成）：
##   ① 日内相位：WorldClock.day_fraction()（15 秒 = 1 游戏日）四段插值——
##      拂晓暖橙 → 清晨近透 → 正午全透 → 黄昏金橙 → 夜里凉蓝压暗；
##      相位随对话/切场景自动暂停（WorldClock 已有暂停逻辑），不会突跳。
##   ② 季节微调：按 GameState.month 给春青 / 秋金 / 冬霜蓝一层极淡的色偏。
##
## 【为什么用半透明染色而不是 modulate 整棵地图树】
##   modulate 会把城池名 / 血条等可读性一起拖下水，且要动 Terrain/CityMarkers
##   多处；一层 alpha 叠色等效「大气」，零侵入、可随时整体摘除。

## 时钟引用（world_map._ready 注入；缺省时按正午处理，不报错）
var clock: Node = null

## 【三十八轮】阴天染色因子（WorldWeather 每帧写入；晴/淡出时为全零色）。
## 复用本层合成链做阴天压暗，绝不另开全屏 ColorRect（填充率铁律）。
var weather_dim := Color(0, 0, 0, 0)

## 日内关键帧 [相位 0..1, 染色 RGBA]；首尾颜色相同保证循环无跳变。
## alpha 即染色强度：正午全透（0），夜里最强（0.20）——压暗但不黑屏。
const DAY_KEYS := [
	[0.00, Color(1.00, 0.70, 0.42, 0.10)],   # 拂晓：暖橙薄染
	[0.12, Color(1.00, 0.96, 0.88, 0.02)],   # 清晨：近透
	[0.45, Color(1.00, 1.00, 1.00, 0.00)],   # 白昼：全透
	[0.72, Color(1.00, 0.62, 0.28, 0.12)],   # 黄昏：金橙
	[0.88, Color(0.16, 0.22, 0.42, 0.20)],   # 入夜：凉蓝压暗
	[1.00, Color(1.00, 0.70, 0.42, 0.10)],   # 次日拂晓（与 0.00 衔接）
]


func _ready() -> void:
	# 全屏锚点（父级是 CanvasLayer 非 Control，锚点相对视口）+ 不吞任何点击
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	color = _blend(_blend(_day_color(_phase()), _season_color()), weather_dim)
	# 【三十四轮×5 性能】几乎全透时隐藏——全屏 ColorRect 即使 alpha≈0 也占
	# 一个混合层（弱 GPU 每层 ~10ms，实测占比显著），白天省掉这一层。
	visible = color.a >= 0.01


## 日内相位；时钟缺失 / 已释放时回落到正午（全透，无染色）
func _phase() -> float:
	if clock != null and is_instance_valid(clock):
		return float(clock.day_fraction())
	return 0.45


## 日内关键帧插值（KEYS 首尾衔接，天然环形）
func _day_color(f: float) -> Color:
	var keys: Array = DAY_KEYS
	for i in range(keys.size() - 1):
		var seg: Array = keys[i]
		var nxt: Array = keys[i + 1]
		var t0 := float(seg[0])
		var t1 := float(nxt[0])
		if f >= t0 and f <= t1:
			var c0: Color = seg[1]
			var c1: Color = nxt[1]
			var t := (f - t0) / maxf(0.0001, t1 - t0)
			return c0.lerp(c1, t)
	var first: Color = keys[0][1]
	return first


## 季节色偏（按月；极淡，只求氛围不抢可读性）
func _season_color() -> Color:
	var m := GameState.month
	if m >= 3 and m <= 5:
		return Color(0.40, 1.00, 0.60, 0.025)   # 春：微青
	elif m >= 6 and m <= 8:
		return Color(1.00, 1.00, 1.00, 0.0)     # 夏：不加偏
	elif m >= 9 and m <= 11:
		return Color(1.00, 0.80, 0.45, 0.03)    # 秋：微金
	return Color(0.55, 0.70, 1.00, 0.04)        # 冬：微霜蓝


## 两层半透明色的「over」合成（近似大气叠色）：
## 结果色 = mix(底色, 上色, 上色α)，结果α = 上色α + 底色α·(1−上色α)
func _blend(base: Color, over: Color) -> Color:
	var a := clampf(over.a + base.a * (1.0 - over.a), 0.0, 1.0)
	if a <= 0.0001:
		return Color(base.r, base.g, base.b, 0.0)
	var k := over.a / a
	return Color(
		lerpf(base.r, over.r, k),
		lerpf(base.g, over.g, k),
		lerpf(base.b, over.b, k),
		a)
