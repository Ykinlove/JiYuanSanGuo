extends Node2D
class_name PlayerController
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

const BOUNDS_MARGIN := 40.0
const PLAYER_TEX_DIR := "res://assets/sprites/player/"
## 贴图查找的候选扩展名。必须是「有类型」的数组，否则 for 循环变量是 Variant，
## 与 String 相加时无法用 := 推断类型（会报「Cannot infer the type of ... variable」）。
const TEX_EXT_CANDIDATES: Array[String] = [".png", ".webp", ".jpg"]

@export var map_size: Vector2 = Vector2(2400, 1400)
@export var sprite_frames := 4       ## 精灵表横向帧数
## 大地图需要缩小视野才能看清全貌；小地图保持 1:1
@export var camera_zoom_out := 0.62  ## 远景缩放（看全图）
@export var camera_zoom_in := 1.0    ## 近景缩放（走路时）
@export var auto_zoom := true        ## 是否启用自动缩放（按地图尺寸判断）
## 自由缩放范围（「最小~最大」）：下限自动按地图尺寸算，
## 保证缩到最小时整张地图刚好能装进屏幕；上限给到 2.4 倍看清细节。
const ZOOM_ABS_MAX := 2.4
const ZOOM_ABS_MIN := 0.05
## 滚轮/捏合每档的缩放倍率（乘法步进，视觉上均匀）
const ZOOM_STEP := 1.12
## 河流阻挡开关。城内场景是世界坐标独立的小地图，
## 全图河流（尺度 2 万级）会误挡城内行走，故城内必须关闭。
@export var river_blocking := true

var move_input := Vector2.ZERO       ## 原始输入（-1~1）
var velocity := Vector2.ZERO         ## 当前实际速度向量（像素/秒）
var facing := Vector2.DOWN           ## 平滑后的朝向单位向量
var is_moving := false
var is_running := false

var _bob_time := 0.0
var _anim: AnimatedSprite2D
var _facing_angle := PI * 0.5        ## 当前朝向角度（默认朝下）

@onready var _camera: Camera2D = $Camera2D
@onready var _visual: Node2D = $Visual


func _ready() -> void:
	_load_rivers()
	_apply_camera_limits()
	_try_use_sprite_sheet()


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


func _apply_camera_limits() -> void:
	if _camera == null:
		return
	_camera.limit_left = 0
	_camera.limit_top = 0
	_camera.limit_right = int(map_size.x)
	_camera.limit_bottom = int(map_size.y)
	if auto_zoom:
		# 默认近景跟随（从城内返回也保持近景）；自由缩放由滚轮/按钮驱动
		_camera.zoom = Vector2.ONE * clampf(camera_zoom_in, zoom_min(), zoom_max())


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


func _process(delta: float) -> void:
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

	# --- 应用位移（河流阻挡：不能渡河，除非走到渡口） ---
	var next := position + velocity * delta
	if _river_blocked(position, next):
		# 整体被河挡住 → 尝试单轴滑移（沿河岸走）
		var sx := position + Vector2(velocity.x * delta, 0.0)
		var sy := position + Vector2(0.0, velocity.y * delta)
		if not _river_blocked(position, sx):
			position = sx
		elif not _river_blocked(position, sy):
			position = sy
		else:
			velocity = Vector2.ZERO
			is_moving = false
	else:
		position = next
	_clamp_to_bounds()

	# --- 朝向平滑转向 ---
	if mag > 0.0:
		var want := raw.normalized().angle()
		_facing_angle = _lerp_angle_smooth(_facing_angle, want, TURN_TIME, delta)
		facing = Vector2.RIGHT.rotated(_facing_angle)
	elif _facing_angle != 0.0:
		facing = Vector2.RIGHT.rotated(_facing_angle)

	# --- 行走起伏 ---
	if is_moving:
		var ratio := clampf(velocity.length() / maxf(RUN_SPEED, 1.0), 0.0, 1.0)
		_bob_time += delta * lerpf(7.0, 14.0, ratio)
	else:
		# 停下时把起伏归零，避免停在半空中
		_bob_time = fposmod(_bob_time + delta * 6.0, TAU)
		if absf(sin(_bob_time)) < 0.06:
			_bob_time = 0.0

	_update_visual()


## 角度插值：沿最短路旋转，避免绕远
func _lerp_angle_smooth(from: float, to: float, turn_time: float, delta: float) -> float:
	var diff := wrapf(to - from, -PI, PI)
	var step := diff * clampf(delta / maxf(turn_time, 0.001), 0.0, 1.0)
	return from + step


# ------------------------------------------------------------------
# 河流阻挡：河流不可通行，只能从渡口（fords）过河
# ------------------------------------------------------------------

const FORD_RADIUS := 170.0        ## 渡口判定半径（世界像素）
## 每条河：段列表 [[a: Vector2, b: Vector2], ...] + 渡口点列表
var _river_segments: Array = []   # Array of Dictionary {a, b}
var _river_fords: Array[Vector2] = []


func _load_rivers() -> void:
	_river_segments.clear()
	_river_fords.clear()
	for r in DataManager.get_table("terrain"):
		if str(r.get("id", "")) != "china":
			continue
		for river in r.get("rivers", []):
			var pts: Array = river.get("points", [])
			for i in range(1, pts.size()):
				_river_segments.append({
					"a": Vector2(float(pts[i - 1][0]), float(pts[i - 1][1])),
					"b": Vector2(float(pts[i][0]), float(pts[i][1])),
				})
			for f in river.get("fords", []):
				_river_fords.append(Vector2(float(f[0]), float(f[1])))
		break


## from→to 是否被河挡住（近似：视作河宽的一半缓冲，用线段距离）
func _river_blocked(from: Vector2, to: Vector2) -> bool:
	if not river_blocking or _river_segments.is_empty():
		return false
	# 起点或终点在渡口附近 → 允许通过
	if _near_ford(from) or _near_ford(to):
		return false
	for seg in _river_segments:
		if _segments_intersect(from, to, seg["a"], seg["b"]):
			return true
	return false


func _near_ford(p: Vector2) -> bool:
	for f in _river_fords:
		if p.distance_squared_to(f) <= FORD_RADIUS * FORD_RADIUS:
			return true
	return false


## 线段相交判定（跨立实验）
func _segments_intersect(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> bool:
	var d1 := _cross(p3, p4, p1)
	var d2 := _cross(p3, p4, p2)
	var d3 := _cross(p1, p2, p3)
	var d4 := _cross(p1, p2, p4)
	if ((d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0)) \
			and ((d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0)):
		return true
	return false


func _cross(a: Vector2, b: Vector2, p: Vector2) -> float:
	return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)


## 限制在地图边界内（撞边时把对应方向的速度清掉，避免"贴边抽搐"）
func _clamp_to_bounds() -> void:
	if position.x <= BOUNDS_MARGIN:
		position.x = BOUNDS_MARGIN
		velocity.x = maxf(velocity.x, 0.0)
	elif position.x >= map_size.x - BOUNDS_MARGIN:
		position.x = map_size.x - BOUNDS_MARGIN
		velocity.x = minf(velocity.x, 0.0)

	if position.y <= BOUNDS_MARGIN:
		position.y = BOUNDS_MARGIN
		velocity.y = maxf(velocity.y, 0.0)
	elif position.y >= map_size.y - BOUNDS_MARGIN:
		position.y = map_size.y - BOUNDS_MARGIN
		velocity.y = minf(velocity.y, 0.0)


## 更新视觉（行走起伏 + 朝向 + 动画速度联动）
func _update_visual() -> void:
	if _visual == null:
		return

	var bob := 0.0
	if is_moving:
		var ratio := clampf(velocity.length() / maxf(RUN_SPEED, 1.0), 0.0, 1.0)
		bob = absf(sin(_bob_time)) * lerpf(1.8, 3.4, ratio)
	_visual.position.y = -bob                 # 起伏向上，像踏步

	# 背对镜头略微缩小，增强纵深感；侧面略扁
	var sy := 0.94 if facing.y < -0.5 else 1.0
	_visual.scale = Vector2.ONE * sy

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


## 缩放下限：让整张地图刚好装进屏幕（16:9 视口按较紧的一边算）
func zoom_min() -> float:
	var vp := Vector2(1920, 1080)
	if is_inside_tree():
		vp = get_viewport_rect().size
	if vp.x <= 1.0 or vp.y <= 1.0:
		vp = Vector2(1920, 1080)
	var fit := minf(vp.x / maxf(map_size.x, 1.0), vp.y / maxf(map_size.y, 1.0))
	return clampf(fit, ZOOM_ABS_MIN, ZOOM_ABS_MAX)


## 缩放上限：固定 2.4，但不得低于下限（极小的地图仍能自洽）
func zoom_max() -> float:
	return clampf(ZOOM_ABS_MAX, zoom_min(), ZOOM_ABS_MAX)


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
	tw.tween_property(_camera, "zoom", Vector2.ONE * target, 0.18)


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
	elif cur < mid:
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
