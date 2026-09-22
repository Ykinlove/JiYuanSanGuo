extends Control
class_name VirtualJoystick
## 虚拟摇杆（VirtualJoystick）
## 手机触控用的虚拟摇杆。输出 -1~1 的二维向量。
## 用法：把本控件放到 UI 层，读取 output 属性或监听 changed 信号。

signal changed(value: Vector2)

@export var max_distance: float = 80.0   ## 摇杆头最大偏移半径
@export var dead_zone: float = 10.0      ## 死区（小于此值视为 0）
@export var fixed_position: bool = true  ## true=固定位置；false=跟随手指出现

var output: Vector2 = Vector2.ZERO

var _base_pos: Vector2
var _touch_index: int = -1
var _is_active := false
var _knob_offset: Vector2 = Vector2.ZERO

@onready var _base: Control = $Base
@onready var _knob: Control = $Base/Knob


func _ready() -> void:
	if fixed_position:
		_base_pos = _base.position + _base.size * 0.5


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_drag(event)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		# 桌面调试：鼠标模拟
		var touch := InputEventScreenTouch.new()
		touch.index = 0
		touch.position = event.position
		touch.pressed = event.pressed
		_handle_touch(touch)
	elif event is InputEventMouseMotion and _is_active:
		var drag := InputEventScreenDrag.new()
		drag.index = 0
		drag.position = event.position
		_handle_drag(drag)


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed and not _is_active:
		var center: Vector2
		if fixed_position:
			center = Vector2(_base.global_position) + _base.size * 0.5
			if event.position.distance_to(center) > max_distance * 1.6:
				return
		else:
			center = event.position
			_base.global_position = center - _base.size * 0.5
		_touch_index = event.index
		_is_active = true
		_base.visible = true
		_knob.visible = true
		_update_output(event.position, center)
	elif not event.pressed and event.index == _touch_index:
		_release()


func _handle_drag(event: InputEventScreenDrag) -> void:
	if not _is_active or event.index != _touch_index:
		return
	var center := Vector2(_base.global_position) + _base.size * 0.5
	_update_output(event.position, center)


func _update_output(pointer: Vector2, center: Vector2) -> void:
	var offset := pointer - center
	if offset.length() > max_distance:
		offset = offset.normalized() * max_distance
	_knob_offset = offset
	_knob.position = _base.size * 0.5 + offset - _knob.size * 0.5

	if offset.length() < dead_zone:
		output = Vector2.ZERO
	else:
		output = offset / max_distance
	changed.emit(output)


func _release() -> void:
	_is_active = false
	_touch_index = -1
	output = Vector2.ZERO
	_knob_offset = Vector2.ZERO
	if fixed_position:
		_knob.position = _base.size * 0.5 - _knob.size * 0.5
	changed.emit(output)


func is_pressed() -> bool:
	return _is_active
