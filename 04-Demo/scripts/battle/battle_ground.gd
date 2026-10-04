extends Node2D
class_name BattleGround
## 战斗场景「起伏地面」—— 让两军站在真实坡地上，交战时产生高低差
##
## ## 为什么必须做
##   此前战斗地面是**一条 ColorRect**（GroundLine，y=760~1080 的纯色块），
##   完全平面。两军无论怎么移动，单位底部都踩在同一条 y 上 ——
##   这就是「战场像一张桌布」的根源。玩家看到的是一张平贴图，不是一个空间。
##
## ## 为什么复用大地图 TerrainMesh 的思路而不是新造一套
##   同一套「网格 + 拆三角 + 受光明暗」的低多边形画法。
##   但**高程来源不同**：大地图用 TerrainHeight（世界地理），
##   战场是虚构的局部地形，故这里用**确定性噪声**（种子固定）生成，
##   **不依赖任何 autoload**（无头探针可直接实例化本类做校验）。
##
## ## 战斗逻辑不受影响（重要）
##   本类**只负责画**。单位的世界坐标（AI 推进 / 接战距离 / 包围判定）
##   全部仍走 battle_scene 原本的 2D 坐标。
##   落地与倾斜由 battle_scene 调 `ground_y_at()` / `tilt_at()` **叠加**到
##   视觉节点上，与大地图「只抬可视子节点、不动实体 position」是同一条铁律。
##
## ## 幅度为何受限
##   高差过大（>90px）会让「后排单位」看起来悬在半空，且遮罩判定（点选）
##   容易与实际画面错位。**±40px** 足以让两军站出高低，又不破坏可玩性。

## 网格边长（屏幕像素）。战场宽度有限，比大地图可以粗一些。
const CELL := 96.0

## 起伏高度（屏幕像素，正值向上）。刻意保守：够看出坡，不破坏判定。
##
## 【为什么是 56 而不是 40】边缘压平用 sin² 会连带压低中段起伏
## （实测 span 从 19.9 缩到 14.2，不够形成可感知高低差），
## 故在此补偿。探针 G3 锁「span ≥ 18px」，G4 锁「span ≤ RELIEF×2.2」，
## 两个阈值一起把幅度框在「看得见但不出戏」的区间。
const RELIEF := 56.0

## 受光方向（与大地图同源的西北光，保证两处观感统一）
const LIGHT_DIR := Vector2(-0.62, -0.78)
const LIGHT_MIN := 0.70
const LIGHT_MAX := 1.14

## 地形色带（由低到高）。冷绿 → 暖褐，像被踩过的战场。
const COL_LOW := Color(0.30, 0.33, 0.26)
const COL_MID := Color(0.36, 0.37, 0.27)
const COL_HIGH := Color(0.44, 0.40, 0.30)

## 战场地面所在的竖直区间（与场景里的 GroundLine 一致：760~1080）
var top_y := 760.0
var bottom_y := 1080.0

## 横向覆盖范围（视口宽，运行时由调用方设置）
var span_x := 1920.0

## 竖直方向的排数（地平线 + 4 排向后延伸的面 → 天然透视）
const ROWS := 5
## 取第几排作为「地平线」高度（单位站立的那一排）
const MID_ROW := 2

## 种子：固定 → 同一场战斗每次布局一致（可复现、可对照截图取证）
var seed_value := 20261004

var _cols := 0
var _heights: PackedFloat32Array = PackedFloat32Array()


func build(vp: Vector2) -> void:
	span_x = maxf(320.0, vp.x)
	top_y = 760.0
	bottom_y = maxf(top_y + 80.0, vp.y)
	_cols = int(ceil(span_x / CELL)) + 1
	_heights.resize(_cols * ROWS)
	var n1 := FastNoiseLite.new()
	n1.seed = seed_value
	n1.frequency = 0.0032
	n1.noise_type = FastNoiseLite.TYPE_SIMPLEX
	var n2 := FastNoiseLite.new()
	n2.seed = seed_value + 977
	n2.frequency = 0.0125
	n2.noise_type = FastNoiseLite.TYPE_SIMPLEX
	for j in range(ROWS):
		for i in range(_cols):
			# 归一化位置 t ∈ [0,1]，末端精确落在 1.0。
			# 【探针 G6 抓到的第二个问题】原先用 x = i*CELL 再算 x/span_x，
			# 但 _cols = ceil(span_x/CELL)+1 使最后一格的 i*CELL 只有 1920，
			# 归一化后落在 1.0 附近却**不是精确 1.0** → sin 压不到 0 → 末端仍起伏 2.69px。
			# 正解：直接用 i/(_cols-1)，保证首末严格为 0 / 1。
			var t := float(i) / float(maxi(1, _cols - 1))
			# 两组不同频率的噪声叠加：大尺度起伏（丘）+ 中尺度（起伏不平），
			# 频率错开避免出现规则波纹。
			var x := t * span_x
			# 边缘（远端）压平：战场两端要能站人，不能是一堵墙。
			# 【探针 G6 抓到的第一个问题】原先写 clampf(edge, 0.15, 1.0) ——
			# 那是**钳位**不是**归零**，两端仍有 15% 残余起伏，
			# 站在最边缘的单位会有一截悬空。正确做法是让 edge 真正趋近 0。
			# 用 sin 的平方：两端严格为 0，中部为 1，边缘过渡平滑不突兀。
			var edge := sin(PI * t)
			edge = edge * edge
			var raw := n1.get_noise_1d(x) * 0.68 + n2.get_noise_1d(x) * 0.32
			_heights[j * _cols + i] = raw * RELIEF * edge
	queue_redraw()


## 某屏幕 x 处的地面起伏量（**向上为正**，调用方用 y - h 换算）。
## 与大地图 TerrainMesh.height_at 同一约定 —— 都是「往上抬多少」。
func relief_at(sx: float) -> float:
	if _heights.is_empty() or _cols <= 0:
		return 0.0
	# 【必须与 build 同口径】build 用归一化 t = i/(_cols-1)，
	# 这里若再用 sx/CELL 就会与生成时的横坐标错开半格，两端插值也会拉回非零值。
	var t := clampf(sx / span_x, 0.0, 1.0)
	var gx := t * float(_cols - 1)
	var x0 := int(floor(gx))
	var x1 := mini(x0 + 1, _cols - 1)
	var fx := gx - float(x0)
	var mid := MID_ROW * _cols
	return lerpf(_heights[mid + x0], _heights[mid + x1], fx)


## 地平线在某 x 处的屏幕 y（已含起伏）。单位应站在这条线上。
func ground_y_at(sx: float) -> float:
	return top_y + (bottom_y - top_y) * 0.42 - relief_at(sx)


## 某点的地面倾角（弧度，0 = 平）。单位按它倾斜以贴合斜面。
func tilt_at(sx: float) -> float:
	var d := CELL * 0.5
	var slope := (relief_at(sx + d) - relief_at(sx - d)) / (2.0 * d)
	# 限幅：战场起伏本就是收敛设计，倾斜只取真实坡度的一部分
	var ang := atan(slope) * 0.45
	return clampf(ang, deg_to_rad(-12.0), deg_to_rad(12.0))


func _draw() -> void:
	if _heights.is_empty():
		return
	# 从地平线往下画 4 排渐暗的面 → 天然形成「地面向后延伸」的透视。
	# 这是最省力也最像样的地面画法：不需要真的 3D 投影。
	for j in range(ROWS - 1):
		var y0 := top_y + (bottom_y - top_y) * (0.42 + 0.145 * float(j))
		var y1 := top_y + (bottom_y - top_y) * (0.42 + 0.145 * float(j + 1))
		for i in range(_cols - 1):
			# 与 build / relief_at 同口径：横坐标按归一化 t 插值出实际屏幕 x。
			var x0 := float(i) / float(maxi(1, _cols - 1)) * span_x
			var x1 := float(i + 1) / float(maxi(1, _cols - 1)) * span_x
			var h0 := _heights[j * _cols + i]
			var h1 := _heights[j * _cols + i + 1]
			var h2 := _heights[(j + 1) * _cols + i + 1]
			var h3 := _heights[(j + 1) * _cols + i]
			# 越靠下（越近）越暗，形成纵深
			var depth := 1.0 - 0.16 * float(j)
			_draw_face(PackedVector2Array([
				Vector2(x0, y0 - h0), Vector2(x1, y0 - h1),
				Vector2(x1, y1 - h2), Vector2(x0, y1 - h3)]),
				Vector2(x0, y0), Vector2(x1, y0), depth,
				(h0 + h1 + h2 + h3) * 0.25)


## 画一个梯形面：按左右高差算受光（左侧高则受光在上坡侧），
## 并按平均海拔在色带里取底色。
func _draw_face(pts: PackedVector2Array, a: Vector2, b: Vector2,
		depth: float, avg_h: float) -> void:
	var dh := b.y - a.y
	var slope := clampf(dh / CELL, -1.0, 1.0)
	# 受光：坡面朝光则亮。x 分量取 0，只按左右高差给一点横向明暗，
	# 真正的大层次由 depth 提供。
	var light := -slope * LIGHT_DIR.x
	var shade := lerpf(LIGHT_MIN, LIGHT_MAX, clampf(light * 0.5 + 0.5, 0.0, 1.0))
	var t := clampf((avg_h / RELIEF) * 0.5 + 0.5, 0.0, 1.0)
	var base := COL_LOW.lerp(COL_MID, minf(t * 2.0, 1.0))
	if t > 0.5:
		base = COL_MID.lerp(COL_HIGH, (t - 0.5) * 2.0)
	var col := Color(clampf(base.r * shade * depth, 0.0, 1.0),
			clampf(base.g * shade * depth, 0.0, 1.0),
			clampf(base.b * shade * depth, 0.0, 1.0), 1.0)
	draw_colored_polygon(pts, col)
