extends CanvasLayer
## Temporary touch layout for Android/iOS. Uses the existing Input Map actions
## so the controls can be replaced later without changing player gameplay code.

const LOOK_SENSITIVITY := 0.0034
const STICK_CENTER := Vector2(112.0, -128.0)
const STICK_RADIUS := 76.0

var player
var _surface: Control
var _stick_touch := -1
var _look_touch := -1
var _sprint_touch := -1
var _jump_touch := -1
var _interact_touch := -1
var _stick_vector := Vector2.ZERO


func _ready() -> void:
	layer = 20
	_surface = _TouchSurface.new()
	_surface.name = "TouchSurface"
	_surface.host = self
	_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_surface)


func bind(player_node) -> void:
	player = player_node


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_begin_touch(touch.index, touch.position)
		else:
			_end_touch(touch.index)
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index == _stick_touch:
			_update_stick(drag.position)
		elif drag.index == _look_touch and player != null:
			player.camera_yaw -= drag.relative.x * LOOK_SENSITIVITY
			player.camera_pitch = clampf(
				player.camera_pitch - drag.relative.y * LOOK_SENSITIVITY,
				-1.1, 0.6)


func _begin_touch(index: int, pos: Vector2) -> void:
	var size := get_viewport().get_visible_rect().size
	if _stick_touch == -1 and _inside_stick(pos, size):
		_stick_touch = index
		_update_stick(pos)
	elif _sprint_touch == -1 and _sprint_rect(size).has_point(pos):
		_sprint_touch = index
		Input.action_press("sprint")
		_surface.queue_redraw()
	elif _jump_touch == -1 and _jump_rect(size).has_point(pos):
		_jump_touch = index
		Input.action_press("jump")
		_surface.queue_redraw()
	elif _interact_touch == -1 and _interact_rect(size).has_point(pos):
		_interact_touch = index
		_surface.queue_redraw()
	elif _look_touch == -1 and pos.x > size.x * 0.42:
		_look_touch = index


func _end_touch(index: int) -> void:
	if index == _stick_touch:
		_stick_touch = -1
		_stick_vector = Vector2.ZERO
		_apply_stick()
	elif index == _look_touch:
		_look_touch = -1
	if index == _sprint_touch:
		_sprint_touch = -1
		Input.action_release("sprint")
	if index == _jump_touch:
		_jump_touch = -1
		Input.action_release("jump")
	if index == _interact_touch:
		_interact_touch = -1
		if player != null:
			player.call("_interact")
	_surface.queue_redraw()


func _inside_stick(pos: Vector2, size: Vector2) -> bool:
	var center := Vector2(STICK_CENTER.x, size.y + STICK_CENTER.y)
	return pos.distance_to(center) <= STICK_RADIUS * 1.45


func _update_stick(pos: Vector2) -> void:
	var size := get_viewport().get_visible_rect().size
	var center := Vector2(STICK_CENTER.x, size.y + STICK_CENTER.y)
	var offset := pos - center
	_stick_vector = offset.limit_length(STICK_RADIUS) / STICK_RADIUS
	if _stick_vector.length() < 0.12:
		_stick_vector = Vector2.ZERO
	_apply_stick()
	_surface.queue_redraw()


func _apply_stick() -> void:
	_set_axis("move_left", "move_right", _stick_vector.x)
	_set_axis("move_forward", "move_back", _stick_vector.y)


func _set_axis(negative_action: String, positive_action: String, value: float) -> void:
	if value < -0.05:
		Input.action_release(positive_action)
		Input.action_press(negative_action, -value)
	elif value > 0.05:
		Input.action_release(negative_action)
		Input.action_press(positive_action, value)
	else:
		Input.action_release(negative_action)
		Input.action_release(positive_action)


func _sprint_rect(size: Vector2) -> Rect2:
	return Rect2(size.x - 116.0, size.y - 258.0, 88.0, 64.0)


func _jump_rect(size: Vector2) -> Rect2:
	return Rect2(size.x - 212.0, size.y - 166.0, 84.0, 72.0)


func _interact_rect(size: Vector2) -> Rect2:
	return Rect2(size.x - 116.0, size.y - 166.0, 88.0, 72.0)


func _draw_controls(canvas: Control) -> void:
	var size := get_viewport().get_visible_rect().size
	var center := Vector2(STICK_CENTER.x, size.y + STICK_CENTER.y)
	canvas.draw_circle(center, STICK_RADIUS, Color(0.025, 0.035, 0.035, 0.24))
	canvas.draw_arc(center, STICK_RADIUS, 0.0, TAU, 48, Color(0.88, 0.82, 0.68, 0.48), 2.0)
	var knob := center + _stick_vector * STICK_RADIUS * 0.68
	canvas.draw_circle(knob, 31.0, Color(0.78, 0.70, 0.53, 0.48))
	canvas.draw_arc(knob, 31.0, 0.0, TAU, 32, Color(1.0, 0.94, 0.80, 0.72), 2.0)
	_draw_button(canvas, _sprint_rect(size), "RUN", _sprint_touch != -1)
	_draw_button(canvas, _jump_rect(size), "JUMP", _jump_touch != -1)
	_draw_button(canvas, _interact_rect(size), "USE", _interact_touch != -1)


func _draw_button(canvas: Control, rect: Rect2, label: String, active: bool) -> void:
	var fill := Color(0.72, 0.61, 0.40, 0.62) if active else Color(0.025, 0.035, 0.035, 0.42)
	canvas.draw_rect(rect, fill, true)
	canvas.draw_rect(rect, Color(0.92, 0.84, 0.68, 0.72), false, 2.0)
	var font := ThemeDB.fallback_font
	var font_size := 17
	var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	canvas.draw_string(font, rect.position + Vector2((rect.size.x - text_size.x) * 0.5,
		(rect.size.y + text_size.y * 0.65) * 0.5), label, HORIZONTAL_ALIGNMENT_LEFT, -1,
		font_size, Color(1.0, 0.96, 0.86))


class _TouchSurface extends Control:
	var host
	func _draw() -> void:
		if host != null:
			host._draw_controls(self)
