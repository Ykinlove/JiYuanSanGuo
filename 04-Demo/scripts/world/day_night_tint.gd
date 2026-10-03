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
##   ② 季节微调：按 GameState.get_season()（单一来源）给春青 / 秋金 / 冬霜蓝一层极淡的色偏；
##      与 TerrainPainter 季节氛围罩同走 get_season，全游戏只有一套季节定义（四十三轮一致性修复）。
##
## 【为什么用半透明染色而不是 modulate 整棵地图树】
##   modulate 会把城池名 / 血条等可读性一起拖下水，且要动 Terrain/CityMarkers
##   多处；一层 alpha 叠色等效「大气」，零侵入、可随时整体摘除。

## 时钟引用（world_map._ready 注入；缺省时按正午处理，不报错）
var clock: Node = null

## 【三十八轮】阴天染色因子（WorldWeather 每帧写入；晴/淡出时为全零色）。
## 复用本层合成链做阴天压暗，绝不另开全屏 ColorRect（填充率铁律）。
var weather_dim := Color(0, 0, 0, 0)

## 【第 5 项第五层】纵深雾化提供者（world_map._ready 注入）。
## 缺省为 null 时本层不产出雾色，行为与本轮之前完全一致。
var fog: Node = null

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
	color = _blend(_blend(_blend(_day_color(_phase()), _season_color()),
			weather_dim), _fog_color())
	# 【三十四轮×5 性能】几乎全透时隐藏——全屏 ColorRect 即使 alpha≈0 也占
	# 一个混合层（弱 GPU 每层 ~10ms，实测占比显著），白天省掉这一层。
	visible = color.a >= 0.01


## 【第 5 项第五层】纵深雾化。按相机所处海拔档给一层极淡的大气色。
##
## ## 为什么雾要接在这一层而不是新开一个 ColorRect
##   雾属于「大气」，与昼夜染色 / 季节色偏 / 阴天压暗同属一层大气语义。
##   弱 GPU 上每个全屏混合层约 10ms（见上方 visible 注释的实测），
##   新开一层等于给每帧加一份固定开销，而合成结果与串进本链**完全等价**。
##
## ## 为什么雾本体不自绘
##   DepthFog 是个纯计算对象：它只回答「当前海拔该用哪层雾」，
##   真正的全屏染色由本层完成。它默认 visible=false，
##   因此**不占任何混合层**（见 DepthFog._ready 的注释）。
func _fog_color() -> Color:
	if fog == null or not is_instance_valid(fog):
		return Color(0, 0, 0, 0)
	return fog.sample_fog()


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


## 季节色偏（按 GameState.get_season() 单一来源；极淡，只求氛围不抢可读性）。
## 【四十三轮·一致性修复】旧实现按 month 3-5/6-8/9-11 自定季节区间，与
## GameState.get_season()（1-3春/4-6夏/7-9秋/10-12冬）在 1/2/12 月冲突——
## 一月二月地形归春（嫩绿）大气却归冬（霜蓝），视觉打架。现统一走 get_season()，
## 与 TerrainPainter 季节氛围罩同源，全游戏只有一套季节定义。
func _season_color() -> Color:
	var s := GameState.get_season()
	if s == GameState.SEASON_SPRING:
		return Color(0.40, 1.00, 0.60, 0.025)   # 春：微青
	elif s == GameState.SEASON_SUMMER:
		return Color(1.00, 1.00, 1.00, 0.0)     # 夏：不加偏
	elif s == GameState.SEASON_AUTUMN:
		return Color(1.00, 0.80, 0.45, 0.03)    # 秋：微金
	elif s == GameState.SEASON_WINTER:
		return Color(0.55, 0.70, 1.00, 0.04)    # 冬：微霜蓝
	return Color(0.55, 0.70, 1.00, 0.04)        # 兜底（理论不可达，四季已穷尽）


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
