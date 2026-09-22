extends Node2D
class_name CityNpc
## 城内游荡 NPC（CityNpc）
## 职责：在城内以家为圆心、固定半径内随机走动（走一走 → 停一停 → 换方向）。
## 纯表现层：不含任何数值/规则逻辑，对话与交易由 city_scene 的交互按钮触发。

@export var home_pos: Vector2 = Vector2.ZERO   ## 巢点：游荡范围的圆心
@export var wander_radius: float = 220.0       ## 游荡半径（固定范围）
@export var move_speed: float = 55.0           ## 行走速度（慢悠悠）

var _target := Vector2.ZERO
var _wait := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	home_pos = position
	_target = position
	_wait = _rng.randf_range(0.5, 2.5)


func _process(delta: float) -> void:
	if _wait > 0.0:
		_wait -= delta
		return
	var to_target := _target - position
	if to_target.length() < 6.0:
		# 到达：停一会儿，再选下一个目标点（不出固定范围）
		_wait = _rng.randf_range(1.2, 3.6)
		_pick_target()
		return
	position += to_target.normalized() * move_speed * delta


func _pick_target() -> void:
	var ang := _rng.randf_range(0.0, TAU)
	var dist := _rng.randf_range(40.0, wander_radius)
	_target = home_pos + Vector2(cos(ang), sin(ang)) * dist
