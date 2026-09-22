extends Node2D
class_name PlayerController
## 主角控制器（PlayerController）
## 职责：接收摇杆输入、八方向移动、朝向切换、行走动画状态、碰撞边界。
## 视觉策略：检测到 res://assets/sprites/player/walk.png 精灵表则用 AnimatedSprite2D，
##           否则回退程序化绘制（胶囊 + 朝向指示）。

const SPEED := 260.0
const RUN_MULT := 1.6
const BOUNDS_MARGIN := 40.0
const PLAYER_TEX_DIR := "res://assets/sprites/player/"

@export var map_size: Vector2 = Vector2(2400, 1400)
@export var sprite_frames := 4       ## 精灵表横向帧数

var move_input := Vector2.ZERO       ## -1~1 输入向量
var facing := Vector2.DOWN           ## 当前朝向
var is_moving := false
var is_running := false

var _bob_time := 0.0
var _anim: AnimatedSprite2D

@onready var _camera: Camera2D = $Camera2D
@onready var _visual: Node2D = $Visual


func _ready() -> void:
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
	# 隐藏程序化节点（改由精灵表显示）
	for child in _visual.get_children():
		child.visible = false
	_visual.add_child(_anim)


## 尝试加载主角行走精灵表
func _get_player_tex() -> Texture2D:
	for name_candidate in ["walk", "hero_walk", "player_walk"]:
		for ext in [".png", ".webp"]:
			var path := PLAYER_TEX_DIR + name_candidate + ext
			if ResourceLoader.exists(path):
				var res := load(path)
				if res is Texture2D:
					return res
	return null


func _apply_camera_limits() -> void:
	if _camera:
		_camera.limit_left = 0
		_camera.limit_top = 0
		_camera.limit_right = int(map_size.x)
		_camera.limit_bottom = int(map_size.y)


func _process(delta: float) -> void:
	is_moving = move_input.length() > 0.08
	is_running = move_input.length() > 0.85

	if is_moving:
		facing = move_input.normalized()
		var speed := SPEED * (RUN_MULT if is_running else 1.0)
		position += move_input * speed * delta
		_bob_time += delta * (12.0 if is_running else 8.0)
	else:
		_bob_time = 0.0

	_clamp_to_bounds()
	_update_visual()


## 限制在地图边界内
func _clamp_to_bounds() -> void:
	position.x = clampf(position.x, BOUNDS_MARGIN, map_size.x - BOUNDS_MARGIN)
	position.y = clampf(position.y, BOUNDS_MARGIN, map_size.y - BOUNDS_MARGIN)


## 更新视觉（行走时上下轻微起伏 + 朝向指示）
func _update_visual() -> void:
	if _visual == null:
		return
	var bob := 0.0
	if is_moving:
		bob = sin(_bob_time) * (3.0 if is_running else 2.0)
	_visual.position.y = bob
	# 背对镜头时轻微缩小，增强纵深感
	_visual.scale = Vector2.ONE * (0.94 if facing.y < -0.5 else 1.0)

	# 有精灵表时切换行走动画与速度
	if _anim:
		_anim.speed_scale = 1.5 if is_running else 1.0
		if is_moving:
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
