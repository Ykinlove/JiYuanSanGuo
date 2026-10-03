extends ColorRect
class_name DepthFog
## 大地图纵深雾化 / 远景降饱和（纯演出，零新资源）——第 5 项第五层
##
## ## 要解决的「贴图感」
##   高度场（TerrainHeight）让角色按海拔浮起，解决了「谁浮得高」；
##   但**画面本身仍是平的**：站在高山与站在平原，屏幕上的颜色、清晰度、
##   空气感完全一样，于是大脑仍把整幅图读成一张贴图而不是一个有纵深的世界。
##   真实地形里，**海拔越高，空气越稀薄 → 远景越蓝、对比越低、饱和越低**，
##   这层「大气透视」（aerial perspective）正是人眼判断距离远近的主要线索。
##
## ## 为什么复用 DayNightTint 这一层，而不是新开一个全屏 ColorRect
##   弱 GPU 上每个全透明混合层约 10ms（DayNightTint 注释里已实测过占比）。
##   本层与昼夜染色、季节色偏、阴天压暗是**同一批「大气」语义**，
##   故直接接进 DayNightTint 的合成链，不新增任何全屏节点。
##
## ## 高度场口径必须与 TerrainHeight 同源
##   本层读的是 TerrainHeight.elevation_at()，即**角色实际站立的那套海拔**——
##   同一份噪声、同一份阶梯、同一份城池压平。所以「雾色」与「角色被抬多高」
##   永远自洽；若另写一套噪声，会出现「角色按平原站、雾却按高山压」的割裂。
##
## ## 分档强度（alpha 极小是刻意的）
##   雾是**气氛**，不是滤镜。峰值 alpha 仅 0.085，低地 0.03 —— 压得住纵深，
##   又不会让地名/血条/HUD 掉可读性。饱和度补偿同时反向微调，
##   避免降饱和后画面发灰发脏。

## 相机引用（world_map._ready 注入；缺省时按原点处理，不报错）
var camera: Camera2D = null

## 地形高度场引用（world_map 注入；缺省则本层不生效）
var terrain: Node = null

## 各海拔档的雾色与强度 [elev阈值, 雾色RGBA, 远景降饱和量]
## 阈值与 TerrainHeight.band_name 的分档边界保持一致
## （>0.80 peak / >0.62 hill / >0.40 plain / 其余 low），
## 免得出现「角色已按 hill 分档抬升、雾还停在 plain 档」的错位。
const FOG_BANDS := [
	[0.80, Color(0.62, 0.74, 0.92, 0.085), 0.26],   # peak：高处 → 冷蓝薄雾、明显降饱和
	[0.62, Color(0.70, 0.79, 0.94, 0.060), 0.17],   # hill：微蓝、轻度降饱和
	[0.40, Color(0.82, 0.86, 0.93, 0.038), 0.08],   # plain：几乎无雾
	[-1.0, Color(0.86, 0.87, 0.90, 0.030), 0.04],  # low（低洼）：偏暖灰薄雾
]

## 当前相机海拔（由 sample_fog 写入，供探针与调试读取）
var current_elev := 0.0

## 当前实际生效的雾色（含 alpha）。透明时本层不产生任何混合开销。
var current_fog := Color(0, 0, 0, 0)


func _init() -> void:
	# 【关键·为什么在 _init 而非 _ready 设】Godot 在 add_child 时会先用类默认属性
	# 初始化节点，_ready 里设的 visible 会被随后的入树流程覆盖回 true（实测：
	# 探针入树后 visible 仍为 true）。本层是纯计算对象，必须从构造起就不可见，
	# 否则就白占一个全屏混合层（弱 GPU 每层 ~10ms）。
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 采样只在昼夜层每帧取色时被调用一次，本层自身**不需要**每帧回调。
	process_mode = Node.PROCESS_MODE_DISABLED


func _ready() -> void:
	# 全屏锚点（父级非 Control，锚点相对视口）
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 再设一次：防 _init 的设置被入树流程覆盖（双重保险，成本为零）
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 按相机所在位置采样雾色与降饱和量。
##
## 【本层没有 _process】process_mode 设为 DISABLED —— 采样由 DayNightTint
## 每帧调 sample_fog() 时顺带完成，本层自己不需要任何每帧回调
## （多一个每帧回调在 110 城 + 数十 NPC 规模下是纯浪费）。
##
## 【为什么采样相机而不是玩家】雾是「观察者所处空气」的表现，
## 采样相机中心才能让整幅画面统一处在同一层大气里；采样玩家会在
## 玩家走到山脊时让半个屏幕的雾突变。
##
## terrain 缺失时返回全透明 —— 缺依赖不该产出视觉异常。
##
## 走 TerrainPainter.sample_height() 这个**现成公开出口**，而不是自己再拼一遍
## TerrainHeight.elevation_at()：前者内部已含城池掩码（elevation_at 的第 4 参），
## 后者拿不到（城市掩码 _city_mask 是 painter 私有）。若绕开 sample_height
## 自行调 elevation_at 且漏传掩码，雾会与角色高度场在城池周边不一致。
func sample_fog() -> Color:
	if terrain == null or not is_instance_valid(terrain):
		current_fog = Color(0, 0, 0, 0)
		return current_fog
	if not terrain.has_method("sample_height"):
		current_fog = Color(0, 0, 0, 0)
		return current_fog
	var focus := Vector2.ZERO
	if camera != null and is_instance_valid(camera):
		focus = camera.get_screen_center_position()
	var h = terrain.sample_height(focus.x, focus.y)
	current_elev = float(h.get("elev", 0.0))
	current_fog = fog_for_elevation(current_elev)
	return current_fog


## 给定海拔求雾色。这是**纯函数**——探针可直接复算校验，
## 不必真的跑一帧 scene（无头探针铁律：不碰 autoload 依赖的运行时路径）。
static func fog_for_elevation(elev: float) -> Color:
	for band in FOG_BANDS:
		if elev > float(band[0]):
			return band[1]
	return FOG_BANDS[FOG_BANDS.size() - 1][1]


## 给定海拔求远景降饱和量（0 = 不降，越大越灰）。同样是纯函数。
static func desat_for_elevation(elev: float) -> float:
	for band in FOG_BANDS:
		if elev > float(band[0]):
			return float(band[2])
	return float(FOG_BANDS[FOG_BANDS.size() - 1][2])
