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
const MAX_STEP_RATE := 3.2    ## 步频上限（步/秒）—— 防止高速时抖动成抽搐
const STOP_SPEED := 8.0       ## 低于此速度视为站定

## 【第六十六轮·步幅随身高】旧实现用**绝对像素**步幅（26~64px），对 425px 高的
## 大地图主角只合 0.06~0.15 身高 —— 每步迈不到膝盖，而步幅一旦偏小，
## 步频就被 MAX_STEP_RATE 顶到 3.2 步/秒，观感即「小碎步急抖」。
## 这正是用户反馈「人物行走方式特别不好」的根因。
## 真人步幅约为身高的 0.4~0.5 倍。改为**按身高比例**取步幅：
##   425px 主角 @250px/s → 步幅 166px → 1.5 步/秒；疾跑 400 → 179px → 2.2 步/秒。
## 各 attach 方只需报自己角色的世界身高，步幅与步频自动落在自然区间。
const STRIDE_MIN_RATIO := 0.26   ## 慢走时的步幅（× 身高）
const STRIDE_MAX_RATIO := 0.42   ## 疾跑时的步幅（× 身高）
## 角色世界身高（像素）。默认 120 与旧绝对步幅等效，未设置的调用方行为不变。
## 【注意】不设身高的小角色（如 56px 城内 NPC）步频仍会被 MAX_STEP_RATE 封顶，
## 小像素角色走"稍快的小步"是正常观感，无需强行拉成大步。
@export var body_height := 120.0
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

## 【去飘增强（第二十三轮）】单张正面立绘没有行走帧，光靠 bob+rotation 倾斜仍像
## 「贴图在飘」——真人走路 body 每步上下两次、且左右轻微晃（weave）。
## 这两个参数让立绘分支演出更"活"；几何小人用默认（bob_double=1、weave=0），
## 双腿相位维持 _phase 单一频率，不与 bob 双峰脱钩。
@export var bob_double := 1.0       ## bob 每步峰数倍率：1=单峰/步（几何），2=双峰/步（立绘更像真走）
@export var weave_amp := 0.0        ## 左右摆动（像素）：立绘分支给 2~4，让"往左/往右走"看得出来

## 【双腿 rig（2026-10-01）】给几何小人装两条会摆动的腿。
## 立绘是单张全身图（腿画在图里，程序动不了），只有几何角色才调用 add_legs。
@export var leg_len := 12.0         ## 单腿长度（髋到脚，像素）
@export var leg_swing_deg := 24.0   ## 腿前摆/后蹬的摆幅（度）
@export var leg_width := 3.0        ## 腿线宽
@export var leg_color := Color(0.16, 0.14, 0.12)  ## 腿色（默认深靴色）
## 【影子联动】抬脚时影子缩小变淡、落地恢复——单图立绘动不了腿，
## 靠影子的呼吸也能读出「落地感」。
@export var shadow_node: Node2D = null

## 当前起伏值（像素，负 = 抬起）。宿主若自己管 transform，可读这一个值叠加。
var bob_offset := 0.0
## 【外部附加偏移】挥砍、被击退这类一次性位移写这里，由本组件统一叠加。
## 【为什么要有这个口子】本体 position 每帧都被本组件按"基准 + 起伏"重写，
## 外部若直接 tween 本体 position，下一帧就被起伏覆盖掉；
## 反过来若让外部接管，踏步又没了。所以用一条独立通道，两者相加互不干扰。
var extra_offset := Vector2.ZERO
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
var _leg_l: Line2D = null
var _leg_r: Line2D = null
var _leg_hip_y := 0.0
var _leg_spread := 6.0
var _leg_step_k := 0.0          ## 本帧移动淡入系数（腿摆幅随之收放）
var _shadow_base := Vector2.ONE
var _shadow_alpha := 1.0
var _shadow_ready := false


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
		# 【第六十六轮】步幅按身高比例取，不再是固定像素（见 STRIDE_MIN_RATIO 注释）
		var stride := lerpf(STRIDE_MIN_RATIO, STRIDE_MAX_RATIO, ratio) \
			* maxf(body_height, 24.0)
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
	# bob 频率按 bob_double 倍率：立绘分支=2 → 每步上下两次，更接近真行走
	var bob_phase := _phase * bob_double
	var bob := -absf(sin(bob_phase)) * bob_amp * lerpf(0.6, 1.25, ratio) * move_k
	var idle := sin(_idle_t) * idle_amp * (1.0 - move_k)
	bob_offset = bob + idle
	# 左右摆动（weave）：与 bob 同相位，立绘分支才有（几何分支默认 0）
	var weave := sin(bob_phase) * weave_amp * move_k

	_body.position = _base_pos + extra_offset + Vector2(weave, bob_offset)
	if drive_rotation:
		_body.rotation = _base_rot \
			+ deg_to_rad((sin(_phase) * lean_deg + _dir * dir_lean_deg) * move_k)
	if drive_scale:
		# 落地（phase=0）压扁、腾空（phase=π/2）拉长，与 bob 同相位
		var sq := squash * cos(_phase * 2.0) * move_k
		_body.scale = _base_scale * Vector2(1.0 + sq, 1.0 - sq)

	# --- 4. 双腿摆动 + 影子联动（与踏步相位同源，天然同步） ---
	_leg_step_k = move_k
	if _leg_l != null and _leg_r != null:
		_pose_leg(_leg_l, _phase, -_leg_spread)
		_pose_leg(_leg_r, _phase + PI, _leg_spread)
	if shadow_node != null and is_instance_valid(shadow_node):
		if not _shadow_ready:
			_shadow_base = shadow_node.scale
			_shadow_alpha = shadow_node.modulate.a
			_shadow_ready = true
		# 【第五十九轮·缺陷修复】抬脚量必须用**纯 bob 分量**，不能用合成后的
		# bob_offset。原式 -bob_offset / bob_amp 把站定仍生效的 idle 呼吸项
		# （idle = sin(_idle_t) * idle_amp * (1-move_k)）也算了进去：
		# 静止时 move_k=0 → bob 贡献 0，bob_offset 退化为纯 idle，
		# 于是完全站定时影子仍以 idle_amp/bob_amp 的比例周期性缩小变淡
		# （大地图 NPC bob_amp=9.8、idle_amp=0.8 →约 2% 的无意义呼吸抖动）。
		# bob 项本身已含 move_k 与 0.6~1.25 速度系数，直接用即为正确抬脚比例。
		# 另：站定不动时直接跳过写入，避免每帧无谓的属性通知。
		if move_k > 0.0:
			var lift_k := clampf(-bob / maxf(bob_amp, 0.01), 0.0, 1.0)
			shadow_node.scale = _shadow_base * (1.0 - 0.25 * lift_k)
			shadow_node.modulate.a = _shadow_alpha * (1.0 - 0.35 * lift_k)


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


## ---------- 双腿 rig ----------

## 给几何角色装两条会摆动的腿（画在身体之下）。
## parent 传「装着身体部件的容器」；hip_y 是髋关节在 parent 局部坐标的 y；
## spread 是左右腿的横向间距。必须在 add_child(parent) 之后调用。
## 【立绘角色不要调用】单图全身立绘的腿画在图里，再画两条会变成四条腿。
func add_legs(parent: Node2D, hip_y: float, spread: float = 6.0) -> void:
	if parent == null or not is_instance_valid(parent):
		return
	var legs := Node2D.new()
	legs.name = "Legs"
	parent.add_child(legs)
	parent.move_child(legs, 0)   # 画在身体之下，别盖住躯干
	_leg_hip_y = hip_y
	_leg_spread = spread
	_leg_l = _make_leg(-spread)
	_leg_r = _make_leg(spread)
	legs.add_child(_leg_l)
	legs.add_child(_leg_r)


func _make_leg(base_x: float) -> Line2D:
	var l := Line2D.new()
	l.name = "Leg"
	l.width = leg_width
	l.default_color = leg_color
	l.begin_cap_mode = Line2D.LINE_CAP_ROUND
	l.end_cap_mode = Line2D.LINE_CAP_ROUND
	var hip := Vector2(base_x, _leg_hip_y)
	l.points = PackedVector2Array([
		hip, hip + Vector2(0.0, leg_len * 0.5), hip + Vector2(0.0, leg_len)])
	return l


## 单腿姿态：s>0 前摆（抬脚+小腿回收），s<0 后蹬（伸直踏地）。
## 与踏步 bob 共用 _phase，迈步、起伏、影子天然同拍。
func _pose_leg(leg: Line2D, ph: float, base_x: float) -> void:
	var s := sin(ph)
	var k := _leg_step_k
	var sw := deg_to_rad(leg_swing_deg) * s * k
	var hip := Vector2(base_x, _leg_hip_y)
	var knee := hip + Vector2(sin(sw), cos(sw)) * leg_len * 0.5
	# 前摆抬脚：小腿回收（变短）+ 脚上提；后蹬时小腿全长着地
	var shin := leg_len * 0.5 * (1.0 - 0.22 * maxf(0.0, s) * k)
	var foot := knee + Vector2(sin(sw * 0.6), cos(sw * 0.6)) * shin
	foot.y -= maxf(0.0, s) * leg_len * 0.30 * k
	leg.points = PackedVector2Array([hip, knee, foot])
