extends Node2D
class_name PlayerController

signal bounds_blocked(dir: Vector2)   ## 撞到地图边界（dir = 越界方向，单位向量）
## 主角控制器（PlayerController）
## ------------------------------------------------------------------
## 职责：接收摇杆输入、平滑加减速、转向插值、行走动画、地图边界。
##
## 【手感设计】原实现是 `position += input * speed * delta` —— 输入一给就是满速，
## 一松手立刻停死，转向也是瞬间 90° 折角，走起来很"硬"。
## 现在改为：
##   1. **速度插值**：当前速度向目标速度逼近（加速快、减速稍慢），有起步与滑步感
##   2. **转向插值**：朝向用角度插值旋转，不会直角折弯
##   3. **缓动曲线**：起步用 ease-out，接近满速时自然收敛
##   4. **帧速联动**：走路动画速度跟着实际速度走，慢走→快跑过渡自然
##   5. **停步衰减**：松手后残留一点惯性再停，不是急刹
##
## 视觉策略：检测到 res://assets/sprites/player/walk.png 精灵表则用 AnimatedSprite2D，
##           否则回退程序化绘制。
## ------------------------------------------------------------------

const SPEED := 250.0              ## 常规行走速度（像素/秒）
const RUN_SPEED := 400.0          ## 疾跑速度
const RUN_THRESHOLD := 0.86       ## 摇杆推杆超过此比例视为疾跑

const ACCEL_TIME := 0.16          ## 从静止到满速的时间（秒）—— 起步手感
const DECEL_TIME := 0.22          ## 从满速到静止的时间（秒）—— 松手滑步
const TURN_TIME := 0.11           ## 转向 90° 所需时间（秒）—— 转向柔和度

const DEAD_ZONE := 0.10           ## 摇杆死区（与虚拟摇杆的 DeadZone 呼应）

const PLAYER_TEX_DIR := "res://assets/sprites/player/"
## 贴图查找的候选扩展名。必须是「有类型」的数组，否则 for 循环变量是 Variant，
## 与 String 相加时无法用 := 推断类型（会报「Cannot infer the type of ... variable」）。
const TEX_EXT_CANDIDATES: Array[String] = [".png", ".webp", ".jpg"]

@export var map_size: Vector2 = Vector2(2400, 1400)
@export var region_offset: Vector2 = Vector2.ZERO   ## 当前区域在世界坐标中的左上角偏移
## 可行走矩形集合（世界坐标）。由 world_map 按 RegionService.walkable_rects() 注入。
## 【为什么要它】map_size+region_offset 只是「所有古州 rect 的并集」，
## 并集会圈出不属于任何州的虚空角落，玩家走进去就像走出了地图。
## 留空则回退到旧的并集矩形逻辑（不会再有 Blocked 频谱回调以外的差异）。
var walk_rects: Array = []
## 【城内建筑阻挡】矩形数组（世界坐标）：玩家不能从建筑贴图上走过去。
## 站进矩形时按「最近边」推出（城市场景在生成建筑时填入地基矩形）。
var block_rects: Array = []
@export var sprite_frames := 4       ## 精灵表横向帧数
## 大地图需要缩小视野才能看清全貌；小地图保持 1:1
@export var camera_zoom_out := 0.62  ## 远景缩放（看全图）
@export var camera_zoom_in := 1.0    ## 近景缩放（走路时）
const ZOOM_SMOOTH := 0.18             ## 缩放缓动时长（秒）：set_zoom 用 tween 平滑过渡，避免切换档位时画面「啪」跳
@export var auto_zoom := true        ## 是否启用自动缩放（按地图尺寸判断）
## 自由缩放范围（「最小~最大」）：下限自动按地图尺寸算，
## 保证缩到最小时整张地图刚好能装进屏幕；上限给到 2.4 倍看清细节。
const ZOOM_ABS_MAX := 2.4
const ZOOM_ABS_MIN := 0.05
## 滚轮/捏合每档的缩放倍率（乘法步进，视觉上均匀）
const ZOOM_STEP := 1.12

## 撞墙提示的节流秒数（避免贴边走时每帧刷提示）
const BLOCK_HINT_CD := 2.5
var _block_cd := 0.0

var move_input := Vector2.ZERO       ## 原始输入（-1~1）
var velocity := Vector2.ZERO         ## 当前实际速度向量（像素/秒）
var facing := Vector2.DOWN           ## 平滑后的朝向单位向量
var is_moving := false
var is_running := false

var _anim: AnimatedSprite2D
var _portrait_sprite: Sprite2D = null
var _facing_angle := PI * 0.5        ## 当前朝向角度（默认朝下）
## 【行走动画】立绘是单张图，光靠坐标平移就是"贴图在飘"。
## 起伏/摇摆/挤压统一交给 WalkAnim（按实际位移驱动），本类只留朝向与纵深。
var _walk: WalkAnim = null

@onready var _camera: Camera2D = $Camera2D
@onready var _visual: Node2D = $Visual


func _ready() -> void:
	# 初始缩放（近景跟随）只在这里设一次 —— _apply_camera_limits() 已改为纯纠偏，
	# 不再负责初始化，否则每次「缩放变化」都会把玩家的缩放覆盖回近景值。
	if _camera != null and auto_zoom:
		_camera.zoom = Vector2.ONE * clampf(camera_zoom_in, zoom_min(), zoom_max())
	_apply_camera_limits()
	_try_use_sprite_sheet()
	# 没有行走精灵表时，尝试使用静态立绘（单图正面插画）
	if _anim == null:
		_try_use_static_portrait()
	# 连立绘也没有 → 用程序化几何小人；它的 rotation/scale 由 _update_visual()
	# 负责（朝向 + 纵深），WalkAnim 只叠加踏步起伏，故关掉旋转与缩放接管。
	if _anim == null and _portrait_sprite == null:
		_walk = WalkAnim.attach(self, _visual)
		if _walk != null:
			_walk.drive_rotation = false
			_walk.drive_scale = false
			# 【双腿】几何小人装两条会摆动的腿（躯干底 y=18，脚至 y≈24）
			_walk.leg_len = 10.0
			_walk.leg_swing_deg = 24.0
			_walk.leg_color = Color(0.15, 0.25, 0.42)
			_walk.add_legs(_visual, 14.0, 7.0)


## 若存在行走精灵表，则用 AnimatedSprite2D 替换程序化视觉
func _try_use_sprite_sheet() -> void:
	var tex := _get_player_tex()
	if tex == null or _visual == null:
		return
	var fw := int(tex.get_width() / maxi(sprite_frames, 1))
	var fh := tex.get_height()

	var sf := SpriteFrames.new()
	var dirs := {
		"walk_down": 0, "walk_left": 1, "walk_right": 2, "walk_up": 3
	}
	for anim_name in dirs.keys():
		sf.add_animation(anim_name)
		sf.set_animation_speed(anim_name, 8.0)
		sf.set_animation_loop(anim_name, true)
		var row := int(dirs[anim_name])
		for i in range(sprite_frames):
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = Rect2(i * fw, row * fh, fw, fh)
			sf.add_frame(anim_name, at)

	_anim = AnimatedSprite2D.new()
	_anim.sprite_frames = sf
	_anim.position = Vector2(0, -fh * 0.5 + 20)
	_anim.play("walk_down")
	for child in _visual.get_children():
		child.visible = false
	_visual.add_child(_anim)


## 尝试加载主角行走精灵表
func _get_player_tex() -> Texture2D:
	for file_base in ["walk", "hero_walk", "player_walk"]:
		for ext in TEX_EXT_CANDIDATES:
			var path: String = PLAYER_TEX_DIR + file_base + ext
			if ResourceLoader.exists(path):
				var res := load(path)
				if res is Texture2D:
					return res
	return null


## 若存在主角静态立绘，则用 Sprite2D 替换程序化视觉
func _try_use_static_portrait() -> void:
	if _visual == null or GameState == null:
		return
	var pid := str(GameState.player_portrait).strip_edges()
	if pid.is_empty():
		return
	var path: String = PLAYER_TEX_DIR + pid + ".png"
	if not ResourceLoader.exists(path):
		return
	var tex := load(path)
	if not (tex is Texture2D):
		return

	_portrait_sprite = Sprite2D.new()
	_portrait_sprite.texture = tex
	_portrait_sprite.centered = true
	# 作为大地图 token 使用，按高度缩放到统一大小，保持正面朝向。
	# 【放大】原 64px 在大地图上显得过小（用户反馈「立绘过于小」），提到 120px 更醒目。
	var target_h := 120.0
	var s := target_h / maxf(tex.get_height(), 1.0)
	_portrait_sprite.scale = Vector2(s, s)
	_portrait_sprite.position = Vector2(0, -target_h * 0.5)
	for child in _visual.get_children():
		child.visible = false
	_visual.add_child(_portrait_sprite)
	# 【落地感】立绘是单图（画在图里的腿动不了），加脚下投影并接入
	# WalkAnim 影子联动：抬脚影子缩小变淡、落地恢复——单图也能读出"踏地"
	var shadow := Polygon2D.new()
	shadow.name = "Shadow"
	shadow.polygon = _ellipse_points(Vector2.ZERO, 15.0, 6.0, 14)
	shadow.color = Color(0, 0, 0, 0.25)
	shadow.position = Vector2(0, 4)
	add_child(shadow)
	move_child(shadow, 0)
	# 立绘是单图：靠 WalkAnim 演出踏步（起伏 + 左右摇摆 + 落地挤压），
	# 并轻微朝移动方向倾斜，让"往左走/往右走"看得出来。
	_walk = WalkAnim.attach(self, _portrait_sprite)
	if _walk != null:
		# 【去飘（第二十三轮）】与战斗主角同套：bob_double=2 双峰/步、weave 左右轻晃，
		# 让大地图上正面立绘也"踩着步子走"而不是贴地飘。
		_walk.bob_amp = 6.0
		_walk.bob_double = 2.0
		_walk.weave_amp = 3.0
		_walk.lean_deg = 6.0
		_walk.dir_lean_deg = 3.5
		_walk.squash = 0.05
		_walk.shadow_node = shadow


## 椭圆顶点（主角脚下投影用）
func _ellipse_points(center: Vector2, rx: float, ry: float, n: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(n):
		var t := float(i) / float(n) * TAU
		pts.append(center + Vector2(cos(t) * rx, sin(t) * ry))
	return pts


func _apply_camera_limits() -> void:
	if _camera == null:
		return
	# 【注意】相机 limit 由 world_map._apply_region_camera 基于「当前区域矩形」
	# 动态计算，这里不再设置 limit，避免用全图 map_size 覆盖区域限制导致
	# 「地图显示不全 / 相机乱跑」。本函数只负责缩放 clamp。
	if auto_zoom:
		# 【修复】旧代码在这里无条件把 zoom 写成近景固定值，而本函数由 _process
		# 在「检测到缩放变化」时调用 —— 滚轮/捏合/缩放按钮刚改完 zoom，下一帧就被
		# 覆盖回 1.0，缩放功能形同虚设。这里只在越界时纠正，不覆盖玩家的选择。
		var z := clampf(_camera.zoom.x, zoom_min(), zoom_max())
		if absf(z - _camera.zoom.x) > 0.0001:
			_camera.zoom = Vector2.ONE * z


## ---------------------------------------------------------------
## 自由缩放输入：鼠标滚轮 / 触摸板上下滚动 / 双指捏合
## 只处理缩放，不消费其他事件（移动仍走摇杆与键盘）。
## ---------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if _camera == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_by_steps(1)
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_by_steps(-1)
			get_viewport().set_input_as_handled()
	elif event is InputEventMagnifyGesture:
		# 触摸板捏合（桌面）：
		var mg := event as InputEventMagnifyGesture
		var target := _camera.zoom.x * mg.factor
		_camera.zoom = Vector2.ONE * clampf(target, zoom_min(), zoom_max())
		get_viewport().set_input_as_handled()
	elif event is InputEventPanGesture:
		# 触摸板双指上下滑 = 缩放
		var pg := event as InputEventPanGesture
		if absf(pg.delta.y) > 0.0001:
			zoom_by_steps(-1 if pg.delta.y > 0.0 else 1)
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch or event is InputEventScreenDrag:
		_handle_pinch(event)


## 双指捏合缩放（安卓真机/触屏）：记录前两指距离，按比例缩放
var _touch_points: Dictionary = {}

func _handle_pinch(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_touch_points[t.index] = t.position
		else:
			_touch_points.erase(t.index)
		return
	var d := event as InputEventScreenDrag
	if d.index in _touch_points:
		_touch_points[d.index] = d.position
	if _touch_points.size() != 2:
		# 【R1-15】手势结束/切换单指时清残留：旧 dist 留到下次捏合首帧会算出跳变系数
		_pinch_last = 0.0
		return
	var ks := _touch_points.keys()
	var a: Vector2 = _touch_points[ks[0]]
	var b: Vector2 = _touch_points[ks[1]]
	var dist := a.distance_to(b)
	if _pinch_last > 1.0 and dist > 1.0:
		var f := dist / _pinch_last
		# 只保留明显变化，过滤手指抖动
		if absf(f - 1.0) > 0.01:
			_camera.zoom = Vector2.ONE * clampf(_camera.zoom.x * f, zoom_min(), zoom_max())
			get_viewport().set_input_as_handled()
	_pinch_last = dist

var _pinch_last := 0.0


var _last_zoom_x := -1.0   ## 上一帧的缩放值，用于检测缩放变化

func _process(delta: float) -> void:
	_block_cd = maxf(0.0, _block_cd - delta)
	# 仅在缩放变化时刷新相机边界（避免每帧 int() 转换开销）
	var cur_zoom := _camera.zoom.x if _camera != null else -1.0
	if absf(cur_zoom - _last_zoom_x) > 0.0001:
		_apply_camera_limits()
		_last_zoom_x = cur_zoom

	var raw := move_input
	var mag := raw.length()

	# --- 死区处理：轻微推杆不生效，避免手指抖动导致角色乱走 ---
	if mag < DEAD_ZONE:
		raw = Vector2.ZERO
		mag = 0.0

	is_running = mag > RUN_THRESHOLD

	# --- 目标速度 ---
	var target := Vector2.ZERO
	if mag > 0.0:
		# 把推杆量映射为速度（非线性：轻推=慢走，推满=快跑，中间过渡自然）
		var speed := lerpf(SPEED * 0.45, RUN_SPEED if is_running else SPEED,
			clampf(mag, 0.0, 1.0))
		target = raw.normalized() * speed

	# --- 速度插值：加速用短时间，减速用稍长时间（滑步感） ---
	var accel := (SPEED * RUN_THRESHOLD) / maxf(ACCEL_TIME, 0.001)
	if target == Vector2.ZERO:
		accel = SPEED / maxf(DECEL_TIME, 0.001)
	elif target.length() < velocity.length():
		# 目标速度低于当前（例如从疾跑松到行走）→ 用减速速率，避免突然顿住
		accel = SPEED / maxf(DECEL_TIME, 0.001)
	velocity = velocity.move_toward(target, accel * delta)

	is_moving = velocity.length() > 12.0

	# --- 应用位移（河流无阻挡：玩家可自由穿过河流，任何位置都能过河） ---
	position += velocity * delta
	_clamp_to_bounds()
	_clamp_out_of_blocks()

	# --- 朝向平滑转向 ---
	if mag > 0.0:
		var want := raw.normalized().angle()
		_facing_angle = _lerp_angle_smooth(_facing_angle, want, TURN_TIME, delta)
		facing = Vector2.RIGHT.rotated(_facing_angle)
	elif _facing_angle != 0.0:
		facing = Vector2.RIGHT.rotated(_facing_angle)

	_update_visual()


## 角度插值：沿最短路旋转，避免绕远
func _lerp_angle_smooth(from: float, to: float, turn_time: float, delta: float) -> float:
	var diff := wrapf(to - from, -PI, PI)
	var step := diff * clampf(delta / maxf(turn_time, 0.001), 0.0, 1.0)
	return from + step


# ------------------------------------------------------------------
# 河流不参与阻挡：玩家可自由通过（河流仅在地图上作视觉呈现）
# ------------------------------------------------------------------


## 限制在区域边界内。
## 【硬限制】优先按「古州矩形集合」限制（walk_rects），避免玩家走进多州并集的
## 虚空角落；集合为空时才回退到旧的并集矩形。
## 【反馈】真撞墙时发 bounds_blocked(dir)，由 world_map 提示"前方无路"，
## 否则玩家推着摇杆撞墙却毫无反馈，第一反应是"游戏卡死了"。
func _clamp_to_bounds() -> void:
	var hit := Vector2.ZERO
	if not walk_rects.is_empty():
		hit = _clamp_to_walk_rects()
	else:
		var min_x := region_offset.x
		var max_x := region_offset.x + map_size.x
		var min_y := region_offset.y
		var max_y := region_offset.y + map_size.y
		if position.x <= min_x:
			position.x = min_x
			velocity.x = maxf(velocity.x, 0.0)
			hit.x = -1.0
		elif position.x >= max_x:
			position.x = max_x
			velocity.x = minf(velocity.x, 0.0)
			hit.x = 1.0
		if position.y <= min_y:
			position.y = min_y
			velocity.y = maxf(velocity.y, 0.0)
			hit.y = -1.0
		elif position.y >= max_y:
			position.y = max_y
			velocity.y = minf(velocity.y, 0.0)
			hit.y = 1.0
	_report_blocked(hit)


## 【建筑阻挡】站进阻挡矩形时按「到四边最近」推出。
## 用于城内建筑（官府/酒馆等）：主角不能从贴图上直接走过去。
func _clamp_out_of_blocks() -> void:
	for r_node in block_rects:
		var r: Rect2 = r_node
		if not r.has_point(position):
			continue
		var dl := position.x - r.position.x
		var dr := r.end.x - position.x
		var dt := position.y - r.position.y
		var db := r.end.y - position.y
		var m := minf(minf(dl, dr), minf(dt, db))
		if m == dl:
			position.x = r.position.x
		elif m == dr:
			position.x = r.end.x
		elif m == dt:
			position.y = r.position.y
		else:
			position.y = r.end.y


## 按古州矩形集合钳制：落到所有矩形之外时，拉回最近的那个矩形的边缘。
## 返回越界方向（用于撞墙提示），未越界则 Vector2.ZERO。
func _clamp_to_walk_rects() -> Vector2:
	for r_node in walk_rects:
		if (r_node as Rect2).has_point(position):
			return Vector2.ZERO
	var fixed := position
	var best_d := INF
	for r_node in walk_rects:
		var r := r_node as Rect2
		var c := Vector2(
			clampf(position.x, r.position.x, r.end.x),
			clampf(position.y, r.position.y, r.end.y))
		var d := c.distance_squared_to(position)
		if d < best_d:
			best_d = d
			fixed = c
	var out_dir := (position - fixed)
	if out_dir.length_squared() < 1.0:
		return Vector2.ZERO
	out_dir = out_dir.normalized()
	# 清掉朝外的速度分量，避免贴边持续"推墙"导致抖动
	if absf(out_dir.x) > 0.2:
		velocity.x = 0.0
	if absf(out_dir.y) > 0.2:
		velocity.y = 0.0
	position = fixed
	return out_dir


## 撞墙反馈上报（带节流，避免贴边每帧刷屏）
func _report_blocked(hit: Vector2) -> void:
	if hit == Vector2.ZERO or _block_cd > 0.0:
		return
	# 只有玩家确实朝这个方向推着走才算"撞墙"，
	# 否则只是沿着边界平行移动也会不停弹提示。
	if move_input.length() <= DEAD_ZONE:
		return
	if move_input.normalized().dot(hit.normalized()) <= 0.2:
		return
	_block_cd = BLOCK_HINT_CD
	bounds_blocked.emit(hit)


## 把位置夹回当前区域的可行走范围内（读档 / 出城 / 战斗归来时用）。
## 旧存档可能记录的是另一区域的坐标，不夹一次会直接生成在地图外。
func sync_into_region() -> void:
	if walk_rects.is_empty():
		position = Vector2(
			clampf(position.x, region_offset.x, region_offset.x + map_size.x),
			clampf(position.y, region_offset.y, region_offset.y + map_size.y))
	else:
		var fixed := position
		var best_d := INF
		for r_node in walk_rects:
			var r := r_node as Rect2
			var c := Vector2(
				clampf(position.x, r.position.x, r.end.x),
				clampf(position.y, r.position.y, r.end.y))
			var d := c.distance_squared_to(position)
			if d < best_d:
				best_d = d
				fixed = c
		position = fixed
	velocity = Vector2.ZERO


## 更新视觉（行走起伏 + 朝向 + 动画速度联动）
func _update_visual() -> void:
	if _visual == null:
		return

	# 【踏步起伏已移交 WalkAnim】旧实现在这里把 _visual.position.y 写成 -bob，
	# 幅度只有 1.8~3.4px，立绘看着仍是"贴图在飘"。现在由 WalkAnim 按实际位移
	# 演出完整的踏步（起伏 + 摇摆 + 挤压），本函数只保留朝向与纵深。

	if _portrait_sprite != null:
		# 静态立绘（正面插画）保持直立、等比例，不做方向旋转或压扁
		_visual.rotation = 0.0
		_visual.scale = Vector2.ONE
	elif _anim == null:
		# 背对镜头略微缩小，增强纵深感；侧面略扁
		var sy := 0.94 if facing.y < -0.5 else 1.0
		_visual.scale = Vector2.ONE * sy

		# 【主角朝向】将视觉旋转到面朝移动方向（_facing_angle 从 +x 轴起算，
		# 角色默认朝上(-y)，故减去 PI/2 使头部指向 facing 方向）。
		# 无精灵表时，程序化角色的头部三角会随朝向转动，玩家能看清往哪走。
		_visual.rotation = _facing_angle - PI * 0.5
	else:
		_visual.scale = Vector2.ONE
		_visual.rotation = 0.0

	# 有精灵表时切换行走动画，速度跟着实际速度走
	if _anim:
		if is_moving:
			var ratio := clampf(velocity.length() / maxf(RUN_SPEED, 1.0), 0.0, 1.0)
			_anim.speed_scale = lerpf(0.85, 1.7, ratio)
			_anim.play(_anim_for_facing())
		else:
			_anim.stop()
			_anim.frame = 0


## 依据朝向选动画名
func _anim_for_facing() -> String:
	if absf(facing.x) > absf(facing.y):
		return "walk_right" if facing.x > 0 else "walk_left"
	return "walk_down" if facing.y > 0 else "walk_up"


## 由外部（世界地图）设置移动输入
func set_move_input(v: Vector2) -> void:
	move_input = v


## 缩放下限：保证地图比屏幕稍大（留 5% 余量），相机有活动空间跟随玩家。
## 【修复】原 maxf 让地图刚好铺满屏幕，相机被锁死在中心，玩家走到地图
## 边缘时相机无法跟随 → 看起来像被空气墙挡住。留 5% 余量后相机可小幅移动，
## 即使边缘有极少量露白也远好过角色被卡死。
func zoom_min() -> float:
	var vp := Vector2(1920, 1080)
	if is_inside_tree():
		vp = get_viewport_rect().size
	if vp.x <= 1.0 or vp.y <= 1.0:
		vp = Vector2(1920, 1080)
	var fit := maxf(vp.x / maxf(map_size.x, 1.0), vp.y / maxf(map_size.y, 1.0))
	return clampf(fit * 1.05, ZOOM_ABS_MIN, ZOOM_ABS_MAX)


## 缩放上限：固定 1.6（不能无限放大），且不得低于下限
func zoom_max() -> float:
	return clampf(ZOOM_ABS_MAX * 0.67, zoom_min(), ZOOM_ABS_MAX)


## 当前缩放所处位置：0=最小，1=最大（供 UI 显示进度）
func zoom_ratio() -> float:
	var lo := zoom_min()
	var hi := zoom_max()
	if hi - lo < 0.0001:
		return 1.0
	var z := 1.0
	if _camera != null:
		z = _camera.zoom.x
	return clampf((z - lo) / (hi - lo), 0.0, 1.0)


## 设置缩放到「绝对倍率」，自动夹进 [min, max]，0.18s 平滑过渡
func set_zoom(z: float) -> void:
	if _camera == null:
		return
	var target := clampf(z, zoom_min(), zoom_max())
	var tw := create_tween()
	tw.tween_property(_camera, "zoom", Vector2.ONE * target, ZOOM_SMOOTH)


## 按「档」步进缩放（delta>0 放大，<0 缩小）。滚轮 / 按钮都走这条。
func zoom_by_steps(steps: int) -> void:
	if steps == 0 or _camera == null:
		return
	set_zoom(_camera.zoom.x * pow(ZOOM_STEP, float(steps)))


## 缩放到最小（看全图）
func zoom_to_min() -> void:
	set_zoom(zoom_min())


## 缩放到最大（看清细节）
func zoom_to_max() -> void:
	set_zoom(zoom_max())


## 循环档位：最小 → 居中 → 最大 → 最小……（给「缩放」按钮用，单键走遍全范围）
func zoom_cycle() -> void:
	if _camera == null:
		return
	var lo := zoom_min()
	var hi := zoom_max()
	var mid := (lo + hi) * 0.5
	var cur := _camera.zoom.x
	# 用相对容差判断落在哪一档，避免浮点相等判断失效
	var tol := (hi - lo) * 0.08
	if absf(cur - lo) <= tol:
		set_zoom(mid)
	elif absf(cur - hi) <= tol:
		set_zoom(lo)
	elif cur <= mid:
		# 【修复】旧代码用严格小于，停在中间档时 cur 恰好等于 mid，会落进 else
		# 回到最小档，最大档永远点不到（按钮只在 全图 ↔ 中间 两档来回跳）。
		set_zoom(hi)
	else:
		set_zoom(lo)


## 切换视野远近（供「缩放」按钮调用）——保留旧接口，内部走循环档位
func toggle_zoom() -> void:
	zoom_cycle()


## 是否处于最远景（供按钮显示文字）
func is_zoomed_out() -> bool:
	if _camera == null:
		return false
	var tol := (zoom_max() - zoom_min()) * 0.08
	return absf(_camera.zoom.x - zoom_min()) <= tol


## 立即停止（切场景/进对话时用，避免残留惯性把人推出画面）
func halt() -> void:
	move_input = Vector2.ZERO
	velocity = Vector2.ZERO
	is_moving = false
	is_running = false
