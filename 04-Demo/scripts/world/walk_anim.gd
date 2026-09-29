extends Node
class_name WalkAnim
## 程序化行走动画（WalkAnim）
## ------------------------------------------------------------------
## 【为什么需要它】本作角色形象是 AI 立绘（单张正面插画），没有行走帧动画。
## 直接让贴图跟着坐标平移，观感就是「一张图在屏幕上飘」——不真实。
## 这里用四个程序化动作把「走路」演出来，零美术成本、不增加任何资源：
##   ① 踏步起伏 bob    —— 每迈一步上下弹一次
##   ② 左右摇摆 lean   —— 每步左右交替倾斜（步伐感的主要来源）
##   ③ 落地挤压 squash —— 落地压扁、腾空拉长（弹性与"重量感"的关键）
##   ④ 静止呼吸 idle   —— 站定时极轻微起伏，避免"死图"
##
## 【驱动方式】读宿主节点（角色根节点）的**实际位移**推进相位，而不是读输入：
## 玩家（摇杆）与 NPC（自主游荡）因此共用同一套代码，不必各写一遍；
## 相位按「走了多少像素 ÷ 步幅」推进 → 慢走慢摆、快跑快摆，自动匹配。
##
## 用法：
##   WalkAnim.attach(角色节点, 人物本体节点)
##   本体可以是 Sprite2D，也可以是装着几何体的 Node2D。
##   脚下投影 / 名字标签**不要**放进本体，否则会跟着一起晃（看着像整块在抖）。
##
## 【步频封顶】步幅随速度增长，但步频不超过 MAX_STEP_RATE 步/秒：
## 否则主角疾跑（400px/s）会抖成"抽搐"，而 NPC 慢走仍是悠悠的两步一秒。
## ------------------------------------------------------------------

const REF_SPEED := 300.0      ## 参考速度：速度比例的归一化基准（像素/秒）
const STRIDE_MIN := 26.0      ## 最慢时的步幅（像素/步）
const STRIDE_MAX := 64.0      ## 最快时的步幅
const MAX_STEP_RATE := 3.2    ## 步频上限（步/秒）—— 防止高速时抖动成抽搐
const STOP_SPEED := 8.0       ## 低于此速度视为站定
## 单帧位移超过这个值视为「传送/切场景」而非走路，不推进相位
const TELEPORT_DIST := 400.0

@export var bob_amp := 3.2          ## 踏步起伏（像素，按速度在 0.6~1.25 倍间缩放）
@export var lean_deg := 4.5         ## 左右摇摆（度）
@export var dir_lean_deg := 3.0     ## 朝向左/右的整体倾斜（度）—— 正面立绘的方向感
@export var squash := 0.04          ## 落地压扁 / 腾空拉长的比例
@export var idle_amp := 0.8         ## 静止呼吸起伏（像素）
@export var idle_period := 2.6      ## 静止呼吸周期（秒）
@export var drive_rotation := true  ## 是否接管本体 rotation（几何小人已自转朝向时关）
@export var drive_scale := true     ## 是否接管本体 scale（宿主另有缩放逻辑时关）

## 当前起伏值（像素，负 = 抬起）。宿主若自己管 transform，可读这一个值叠加。
var bob_offset := 0.0
## 平滑后的移动速度（像素/秒），供宿主判断"在不在走"
var move_speed := 0.0

var _host: Node2D = null
var _body: Node2D = null
var _prev := Vector2.ZERO
var _has_prev := false
var _phase := 0.0
var _speed := 0.0
var _idle_t := 0.0
var _base_pos := Vector2.ZERO
var _base_rot := 0.0
var _base_scale := Vector2.ONE
var _base_ready := false
var _dir := 0.0        ## 最近的水平移动方向（-1~1，平滑值）


## 把动画挂到 host 上、驱动 body。返回的实例可直接调参（如改 bob_amp）。
## 【注意】必须在 body 的 position / scale 定好之后再 attach ——
## 本组件以"首次运行时的 transform"为基准，之后每帧在基准上叠加。
static func attach(host: Node2D, body: Node2D) -> WalkAnim:
	if host == null or body == null:
		return null
	var wa := WalkAnim.new()
	wa.name = "WalkAnim"
	wa._host = host
	wa._body = body
	host.add_child(wa)
	return wa


func _process(delta: float) -> void:
	if _host == null or _body == null or not is_instance_valid(_body):
		return
	_bootstrap_base()

	# --- 1. 读宿主的真实位移（玩家摇杆 / NPC 自主游荡，同一套） ---
	var hp := _host.global_position
	var dist := 0.0
	if _has_prev:
		dist = hp.distance_to(_prev)
		if dist > 0.02 and dist < TELEPORT_DIST:
			_dir = lerpf(_dir, clampf((hp.x - _prev.x) / dist, -1.0, 1.0),
				clampf(delta * 8.0, 0.0, 1.0))
	_prev = hp
	_has_prev = true
	_speed = lerpf(_speed, dist / maxf(delta, 0.0001), clampf(delta * 12.0, 0.0, 1.0))
	move_speed = _speed

	# --- 2. 相位推进：走多远迈一步，步频封顶 ---
	var ratio := clampf(_speed / REF_SPEED, 0.0, 1.0)
	if _speed > STOP_SPEED:
		var stride := lerpf(STRIDE_MIN, STRIDE_MAX, ratio)
		stride = maxf(stride, _speed / MAX_STEP_RATE)
		_phase = fposmod(_phase + (dist / stride) * PI, TAU)
	else:
		# 站定：把相位平滑收回到最近的落脚点（此时 bob 与 lean 都恰为 0）
		var rest := roundf(_phase / PI) * PI
		_phase = lerpf(_phase, rest, clampf(delta * 8.0, 0.0, 1.0))
		_dir = lerpf(_dir, 0.0, clampf(delta * 6.0, 0.0, 1.0))

	# --- 3. 合成四个动作 ---
	# move_k：起步/收步的淡入淡出，避免"一动就满幅抖"
	var move_k := clampf((_speed - STOP_SPEED) / 60.0, 0.0, 1.0)
	_idle_t = fposmod(_idle_t + delta * TAU / maxf(idle_period, 0.1), TAU)
	var bob := -absf(sin(_phase)) * bob_amp * lerpf(0.6, 1.25, ratio) * move_k
	var idle := sin(_idle_t) * idle_amp * (1.0 - move_k)
	bob_offset = bob + idle

	_body.position = _base_pos + Vector2(0.0, bob_offset)
	if drive_rotation:
		_body.rotation = _base_rot \
			+ deg_to_rad((sin(_phase) * lean_deg + _dir * dir_lean_deg) * move_k)
	if drive_scale:
		# 落地（phase=0）压扁、腾空（phase=π/2）拉长，与 bob 同相位
		var sq := squash * cos(_phase * 2.0) * move_k
		_body.scale = _base_scale * Vector2(1.0 + sq, 1.0 - sq)


## 记录基准 transform（首帧快照）。
## 必须留基准：立绘本体自带缩放（NPC 立绘统一缩到 56px 高），
## 直接写 scale=(1,1) 会把角色放大十几倍。
func _bootstrap_base() -> void:
	if _base_ready:
		return
	_base_pos = _body.position
	_base_rot = _body.rotation
	_base_scale = _body.scale
	_base_ready = true
