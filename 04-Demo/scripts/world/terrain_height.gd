extends RefCounted
class_name TerrainHeight
## 地形高度场（第六十八轮·第 5 项第三层）
## ------------------------------------------------------------------
## 【解决什么问题】用户原话：「让角色真正的行经走于每个地质上面，包括山啊、
## 土地什么的，而不是只在贴图上面走来走去」。
## 取证结论：大地图的 `terrain_painter.gd` **内部早已有一套完整高程模型**
## （西高东低三级阶梯 + 三层噪声 + 城池周边压平），但它只用来**给底图上色**，
## 颜色信息随 `_draw` 结束就丢了。于是：
##   · 角色无论走到西部高山还是东部平原，绘制高度**完全一致**；
##   · 走位与地形的纵深关系不存在 → 观感就是「在一张平铺贴图上滑动」。
##
## 【本模块做什么】把 `terrain_painter._make_geo_image_for_rect()` 里的
## 高程公式**原样抽成可查询的纯函数**，让角色/NPC/城池按高程抬升绘制高度。
## 高山上的角色比平原上的角色画得更高（y_sort 之上再叠高度），
## 于是「爬上坡」这件事在画面上真的成立。
##
## 【为什么不重写一套公式】这是本项目反复踩过的坑：
## 任何「上游改数值、下游留过期副本」的双实现，跑的就不是同一个东西。
## 因此这里的噪声种子/频率/阶梯系数**必须与 terrain_painter 完全一致**，
## 由 _verify_city_height_field.py 的锚定判据锁死；改动必须两边同改。
##
## 【与 y_sort 的分工】y_sort 决定「谁盖住谁」（同一平面上的前后关系），
## 高度场决定「谁浮得高」（离观察者更近）。两者相乘才有的纵深：
##   绘制 y = 逻辑 y - elevation * HEIGHT_SCALE
##   y_sort 仍按**逻辑 y** 排序（走位判断不该被高程影响）。
##
## 【性能】噪声采样是纯计算。角色每帧 1 次、NPC 每人每帧 1 次、
## 城池/遭遇物仅生成时 1 次 —— 全图千级采样完全可承受。
## 但**绝不可**在 `_draw` 里逐像素调本函数（那是百万级）。

## 高度偏移总量：最高山抬升多少世界像素。
## 【取值依据】世界高度 UITheme.WORLD_UNIT_HEIGHT = 120（角色身高）。
## 山地抬升取角色身高的 0.85 倍 —— 再高角色会飘出可视区显得不真实，
## 再低则看不出「爬坡」（实测 0.6 以下几乎看不出差别）。
const HEIGHT_SCALE := 102.0

## 【第六层新增】垂直夸张倍数。
##
## ## 为什么需要它
##   俯视 2D 的真实地形，严格按 1:1 画的话高差只有格跨度的 0.3% ——
##   数学上正确，视觉上**完全是平面**（这正是前五层治不了本的量化形态：
##   实测 CELL=340 时单格高差仅 1.04px，受光差≈0）。
##   低多边形地形（low-poly terrain）的标准做法就是放大垂直比例。
##
## ## 为什么必须与地形网格共用同一常量
##   角色抬升（本文件 lift_at）与地形网格面（terrain_mesh.gd）读的是**同一个**出口，
##   所以只要两侧都走 lift_at / sample_height().lift，就天然一致。
##   若网格层自己再乘一次 → 平方放大 → 角色飞上天而地面不动。
const VERT_EXAGGERATE := 7.0

## --- 与 terrain_painter._make_geo_image_for_rect() 完全一致的高程参数 ---
## 【血泪·必须同源】这些值一旦漂移，角色的高度就会与底图的山势对不上：
## 站在画出来是山的地方，角色却按平原高度绘制。故由源码锚定判据锁死。
const NOISE_ELEV_SEED := 2026
const NOISE_ELEV_FREQ := 1.0 / 3000.0
const NOISE_MID_SEED := 7788
const NOISE_MID_FREQ := 1.0 / 1100.0
const NOISE_HUMID_SEED := 5566
const NOISE_HUMID_FREQ := 1.0 / 2200.0
const ELEV_WEST_COEFF := 0.8      ## 西部隆起幅度：west_factor^2 * 该值
const ELEV_NOISE_MAIN := 0.4      ## 大尺度噪声权重
const ELEV_NOISE_MID := 0.18      ## 中尺度噪声权重
const ELEV_CITY_FLAT := 0.28      ## 城池周边压平后的目标海拔

## 噪声实例缓存：FastNoiseLite 构造有开销，而采样是每帧多次。
## 【为什么可静态缓存】FastNoiseLite 构造后只读不写，采样是纯函数，
## 多个调用方共享同一实例不改变结果（故不影响可复现性）。
static var _n_elev: FastNoiseLite = null
static var _n_mid: FastNoiseLite = null
static var _n_humid: FastNoiseLite = null


static func _noise(which: String) -> FastNoiseLite:
	match which:
		"elev":
			if _n_elev == null:
				_n_elev = FastNoiseLite.new()
				_n_elev.seed = NOISE_ELEV_SEED
				_n_elev.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
				_n_elev.frequency = NOISE_ELEV_FREQ
			return _n_elev
		"mid":
			if _n_mid == null:
				_n_mid = FastNoiseLite.new()
				_n_mid.seed = NOISE_MID_SEED
				_n_mid.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
				_n_mid.frequency = NOISE_MID_FREQ
			return _n_mid
		_:
			if _n_humid == null:
				_n_humid = FastNoiseLite.new()
				_n_humid.seed = NOISE_HUMID_SEED
				_n_humid.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
				_n_humid.frequency = NOISE_HUMID_FREQ
			return _n_humid


## 无城池压平的基础海拔（0~1）。
## 【与绘制同源】公式逐项对齐 terrain_painter 的高程段，勿单方面"优化"。
static func base_elevation(wx: float, wy: float, world: Vector2) -> float:
	var nx := wx / maxf(world.x, 1.0)
	var west_factor := 1.0 - nx
	var elev: float = west_factor * west_factor * ELEV_WEST_COEFF
	elev += _noise("elev").get_noise_2d(wx, wy) * ELEV_NOISE_MAIN
	elev += _noise("mid").get_noise_2d(wx, wy) * ELEV_NOISE_MID
	return clampf(elev, 0.0, 1.0)


## 完整海拔：基础海拔 + 城池周边压平（city_mask 0~1，0=不受影响）。
## @param city_mask 城池影响值，来自 TerrainPainter 的蒙版采样（0~1）
static func elevation_at(wx: float, wy: float, world: Vector2,
		city_mask: float = 0.0) -> float:
	var elev := base_elevation(wx, wy, world)
	if city_mask > 0.0:
		elev = lerpf(elev, ELEV_CITY_FLAT, city_mask * 0.85)
	return clampf(elev, 0.0, 1.0)


## 该世界坐标处的绘制抬升量（世界像素，向**上**为正）。
## 【为什么反向】绘制 y 越小越靠上/越靠里，故绘制时用 `y - lift`。
static func lift_at(wx: float, wy: float, world: Vector2,
		city_mask: float = 0.0) -> float:
	return elevation_at(wx, wy, world, city_mask) * HEIGHT_SCALE * VERT_EXAGGERATE


## 直接给出「角色视觉节点应设置的 y 偏移」。
## 【为什么要这一个入口】调用方各有各的坐标系（世界玩家用 position，
## NPC 用节点 position），但语义一律是「向上抬」，故统一在此换算符号，
## 避免每个调用方各写一次减号 —— 符号写反会让人物沉进地里，
## 而这**编译期与运行期都不报错**，只能靠像素/截图取证发现。
##
## 【血泪·基准 y 只能在首次记录】早先版本这里写的是
## `node.set_meta("ground_y", node.position.y)` —— **每次调用都把当前 y
## 重新写成基准**，而当前 y 已经是抬升过的值，于是抬升逐次累加：
## 探针 H7 实测连调 10 次位移达 -450.234px（单次只该 -45.023），
## 走 100 步就会飞出天际 —— 而**第一帧看起来完全正常**。
## 正解：基准只在**首次**记录，之后一律沿用。
## （由 tests/terrain_height_probe.gd 的 H7 锁死：连调 10 次位移须等于单次）
static func apply_to(node: Node2D, wx: float, wy: float, world: Vector2,
		city_mask: float = 0.0) -> void:
	if node == null:
		return
	if not node.has_meta("base_y"):
		node.set_meta("base_y", node.position.y)
	node.position.y = float(node.get_meta("base_y")) - lift_at(wx, wy, world, city_mask)


## 诊断用：某个海拔对应什么地形（供探针与调试断言，不参与渲染）。
## 【判据设计】返回**离散档位名**而非浮点，便于探针做等值断言，
## 也便于把"角色站在山顶 vs 站在河谷"写成可读的判定。
static func band_name(elev: float) -> String:
	if elev > 0.80:
		return "peak"
	if elev > 0.62:
		return "hill"
	if elev > 0.40:
		return "plain"
	return "low"