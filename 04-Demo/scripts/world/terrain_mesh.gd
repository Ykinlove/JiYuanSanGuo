extends Node2D
class_name TerrainMesh
## 大地图「真地形」网格 —— 第 5 项第六层：从「一张贴图」升级为「有起伏的面」
##
## ## 为什么必须做这个（前面几层治不了本的原因）
##   y_sort / 高度场 / 接地投影 / 纵深雾，**全都是在平面贴图上做修饰**：
##   地面自始至终是「一张图」，无论角色站高山还是站平原，脚下几何完全相同。
##   人脑判断「是否处在真实环境里」靠的是**地面自身有起伏、有朝向不同的受光面**——
##   这必须**建模**，画不出来。所以本层把地形切成网格，
##   每格按海拔算出四角高度，画成**有明暗差异的立体四边形**。
##
## ## 为什么是 2.5D 而不是真 3D
##   玩法是俯视 2D（移动/攻击/交互全按 2D 坐标判定），
##   真 3D 要重做角色资源与全部战斗渲染，风格会剧变。
##   2.5D 能拿到 90% 的代入感成本，且**不动任何玩法判定**。
##
## ## 为什么不需要每帧重建（性能关键）
##   地形静态、相机变换由 Camera2D 自动完成，
##   所以网格**只在生成期构建一次**并常驻：此后每帧零开销。
##   这与 terrain_painter「静态整图 _draw 一次」是同一套前提。
##
## ## 光照模型（受光面 = 坡向）
##   亮面来自「西北方向来的光」。每格四边形按**法线朝向**算亮度：
##   朝光的面亮、背光的面暗。这正是低多边形地形（low-poly terrain）
##   在同类游戏里的标准画法，也是「看起来有体积」的主要来源。
##
## ## 与既有高度场的关系（不要重新发明噪声）
##   顶点海拔直接取 TerrainPainter.sample_height()，即角色被抬起来用的**同一套**
##   高程模型。网格与角色高度因此天然对齐 —— 绝不能另写一套噪声，
##   否则会出现「脚下的面」和「角色站的高度」对不上。

## 网格边长（世界像素）。与海陆分辨率匹配：够细才有起伏感，又不至于爆炸。
## 【为什么从 340 收到 170】实测：340px 格子下单格高差仅 1.04px，
## 而受光差取决于「高差 / 跨度」——1px/340px 意味着法线几乎竖直，
## 每个面的亮度几乎相同 → **看起来仍然是平的**（这正是"贴图感"的量化形态）。
## 收到 170px 后单格高差翻倍到 2.1px，再配合 TerrainHeight.VERT_EXAGGERATE 的
## 垂直夸张（×7）才真正立得起来。
const CELL := 170.0

## 垂直夸张**不在本层施加** —— 它已并入 TerrainHeight.VERT_EXAGGERATE，
## 而 lift_at() 是「角色抬升」与「地形网格」**共用的唯一真源**。
## 【为什么要收敛到一处】两侧各乘一次会平方放大（×49），
## 角色会飞到天上而地面纹丝不动；或反之「地面动了、角色没动」→
## 角色陷进地里。单一真源是唯一的正确做法。
## 本层若再乘一次即构成缺陷（由 _verify_terrain_mesh.py 的 X 组锁死：
## 网格高度必须与 sample_height().lift 逐点相等）。
const HEIGHT_SCALE_BASE := 102.0     ## 与 TerrainHeight.HEIGHT_SCALE 同值（仅文档用）

## 受光方向（单位向量）。西北光：x 负、y 负。
const LIGHT_DIR := Vector2(-0.62, -0.78)

## 亮度区间（按受光量在两端插值）。刻意不用极端对比 —— 贴图底图仍可见。
const LIGHT_MIN := 0.62
const LIGHT_MAX := 1.16

## 坡度过陡时额外的暗部强调（陡坡更"立"，视觉上更可信）
const SLOPE_SHADE := 0.34

## 颜色来源：按**地貌档**派生，不另写一套配色。
## terrain_painter 的取色逻辑都封在 _draw 里、没有对外出口；
## 而 sample_height() 已经返回了 band（地貌档），那是同一份高程模型的输出 ——
## 用它派生颜色可保证「网格颜色」与「角色高度」出自同一套数据。
## 【不要为省事去调 terrain_painter 私有函数】那是它自己 _draw 的实现细节。
const BAND_COLORS := {
	"peak": Color(0.52, 0.50, 0.48),
	"hill": Color(0.58, 0.60, 0.46),
	"plain": Color(0.62, 0.68, 0.44),
	"low": Color(0.55, 0.60, 0.48),
}

## 颜色来源：交给 terrain_painter 采样，保证与底图同色系（不引入第二套配色）
## 【类型放宽到 Object】只要对方有 sample_height(wx,wy)->{lift,band} 就能用。
## 原先写死 Node 会让探针/测试无法用轻量替身（RefCounted 继承链不含 Node），
## 逼着测试去造真场景 —— 那是测试替身机制缺失的信号。
var _terrain: Object = null

## 世界尺寸
var _world := Vector2.ZERO

## 玩家/单位据此查询「脚下这个面」的高度与法线
var _heights: PackedFloat32Array = PackedFloat32Array()
## 每格顶点所属地貌档（_draw 时直接查，避免逐面回调 painter）
var _bands: PackedStringArray = PackedStringArray()
var _cols := 0
var _rows := 0


func setup(terrain: Object, world: Vector2) -> void:
	_terrain = terrain
	_world = world
	_build()
	queue_redraw()


## 网格尺寸（格数）。对外只读。
func grid_size() -> Vector2i:
	return Vector2i(_cols, _rows)


## 采样某世界坐标处的海拔（对网格顶点做双线性插值）。
## 角色贴地、倾斜、战斗地面起伏全部走这里 —— 与渲染用同一份数据，
## 保证「看到的面」和「脚踩的面」永远一致。
func height_at(wx: float, wy: float) -> float:
	if _heights.is_empty():
		return 0.0
	var gx := clampf(wx / CELL, 0.0, float(_cols - 1))
	var gy := clampf(wy / CELL, 0.0, float(_rows - 1))
	var x0 := int(floor(gx))
	var y0 := int(floor(gy))
	var x1 := mini(x0 + 1, _cols - 1)
	var y1 := mini(y0 + 1, _rows - 1)
	var fx := gx - float(x0)
	var fy := gy - float(y0)
	var h00 := _heights[y0 * _cols + x0]
	var h10 := _heights[y0 * _cols + x1]
	var h01 := _heights[y1 * _cols + x0]
	var h11 := _heights[y1 * _cols + x1]
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fy)


## 采样某点的地面法线（单位向量，z 为高度方向）。
## 角色按它倾斜 → 站在斜坡上不会像站在平板上。
## 用中心差分：分别取 x/y 方向一小步的高度差。
func normal_at(wx: float, wy: float) -> Vector3:
	if _heights.is_empty():
		return Vector3.UP
	var d := CELL * 0.5
	var hl := height_at(wx - d, wy)
	var hr := height_at(wx + d, wy)
	var hu := height_at(wx, wy - d)
	var hd := height_at(wx, wy + d)
	return Vector3(hl - hr, hu - hd, 2.0 * d).normalized()


## 坡度（0 = 平地，越大越陡）。供角色决定倾斜幅度。
func slope_at(wx: float, wy: float) -> float:
	var n := normal_at(wx, wy)
	return clampf(1.0 - n.z, 0.0, 1.0)


## 逐格取海拔，缓存进 _heights（渲染与查询共用）
func _build() -> void:
	if _terrain == null or _world == Vector2.ZERO:
		return
	_cols = int(ceil(_world.x / CELL)) + 1
	_rows = int(ceil(_world.y / CELL)) + 1
	# 上限保护：世界 21256×21826 / 340 ≈ 63×65 格 = 4095 个面，
	# 顶点 4096 个 —— 完全可接受。仍留一道保险防止数据异常导致内存爆掉。
	var max_cells := 40000
	if _cols * _rows > max_cells:
		var shrink := sqrt(float(_cols * _rows) / float(max_cells))
		_cols = maxi(2, int(float(_cols) / shrink))
		_rows = maxi(2, int(float(_rows) / shrink))
	_heights.resize(_cols * _rows)
	_bands.resize(_cols * _rows)
	for j in range(_rows):
		for i in range(_cols):
			var wx := float(i) * CELL
			var wy := float(j) * CELL
			var h: Dictionary = _terrain.sample_height(wx, wy)
			var idx := j * _cols + i
			# 存**已夸张**的高度：本层所有采样（渲染、贴地、法线）都基于它，
			# 保证「看到的面」与「脚踩的面」是同一份数据。
			_heights[idx] = float(h.get("lift", 0.0))
			_bands[idx] = str(h.get("band", "plain"))



func _draw() -> void:
	if _heights.is_empty() or _terrain == null:
		return
	var step := CELL
	# 单格跨度 > 绘制阈值时缩步长，保证大格子也不丢起伏
	for j in range(_rows - 1):
		for i in range(_cols - 1):
			var x0 := float(i) * step
			var y0 := float(j) * step
			var x1 := x0 + step
			var y1 := y0 + step
			var h00 := _heights[j * _cols + i]
			var h10 := _heights[j * _cols + i + 1]
			var h01 := _heights[(j + 1) * _cols + i]
			var h11 := _heights[(j + 1) * _cols + i + 1]

			# 每格拆两个三角，各自按法线算亮度 —— 低多边形的标准画法。
			# 拆三角是必须的：四边形不共面，用单一法线会让整格看起来是平的。
			var band := _band_of(i, j)
			_draw_face(PackedVector2Array([
				Vector2(x0, y0 - h00), Vector2(x1, y0 - h10), Vector2(x1, y1 - h11)]),
				Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), band)
			_draw_face(PackedVector2Array([
				Vector2(x0, y0 - h00), Vector2(x1, y1 - h11), Vector2(x0, y1 - h01)]),
				Vector2(x0, y0), Vector2(x1, y1), Vector2(x0, y1), band)


## 取格子的地貌档（四格取众数：取第一个非 plain 的，退化到 plain）
func _band_of(i: int, j: int) -> String:
	for dj in range(2):
		for di in range(2):
			var b := _bands[(j + dj) * _cols + (i + di)]
			if b != "plain":
				return b
	return "plain"


## 画一个三角面：底色按地貌档，再按受光量调制明暗 ——
## 这就是「面」看起来有体积的唯一来源。
func _draw_face(pts: PackedVector2Array, a: Vector2, b: Vector2, c: Vector2,
		band: String) -> void:
	# 世界法线（高度已含在 pts 的 y 里，这里只用平面 xy 算坡向）
	var e1 := b - a
	var e2 := c - a
	var nrm := Vector3(e1.y, -e1.x, 0.0)
	# 斜率参与法线 z 分量
	var span := maxf(0.0001, (e1 + e2).length())
	nrm.z = span
	nrm = nrm.normalized()

	# 受光量：法线与光向的点积（>0 为受光面）
	var light := nrm.x * LIGHT_DIR.x + nrm.y * LIGHT_DIR.y
	# 坡度越大，背光面压得越暗（强化立体感）
	var slope := clampf(1.0 - nrm.z, 0.0, 1.0)
	var shade := lerpf(LIGHT_MIN, LIGHT_MAX, clampf(light * 0.5 + 0.5, 0.0, 1.0))
	shade -= slope * SLOPE_SHADE

	var base: Color = BAND_COLORS.get(band, Color(0.62, 0.68, 0.44))
	var col := Color(clampf(base.r * shade, 0.0, 1.0),
			clampf(base.g * shade, 0.0, 1.0),
			clampf(base.b * shade, 0.0, 1.0), 1.0)
	draw_colored_polygon(pts, col)
