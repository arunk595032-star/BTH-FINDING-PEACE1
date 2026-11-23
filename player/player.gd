extends CharacterBody3D
## Third-person explorer.
##
## Camera-relative movement, sprint, jump, slope limiting, boundary clamping and
## a simple interaction probe.  The character model is generated in code (no
## third-party character asset is used).

const Config = preload("res://scripts/core/world_config.gd")
const Mats = preload("res://scripts/core/material_library.gd")

@export var walk_speed := 4.6
@export var run_speed := 9.0
@export var acceleration := 16.0
@export var jump_velocity := 5.6
@export var gravity := 22.0
@export var mouse_sensitivity := 0.0024

var camera_yaw := 0.0
var camera_pitch := -0.16
var is_sprinting := false
var current_focus := ""
var discovered: Array[String] = []
var distance_travelled := 0.0

var _pivot: Node3D
var _spring: SpringArm3D
var _camera: Camera3D
var _model: Node3D
var _leg_l: MeshInstance3D
var _leg_r: MeshInstance3D
var _arm_l: MeshInstance3D
var _arm_r: MeshInstance3D
var _stride := 0.0
var _last_pos := Vector3.ZERO
var _mouse_captured := true

var _landmarks := [
	{"name": "Thornbury well", "pos": Config.VILLAGE_CENTER + Vector2(-7.5, 6.0), "radius": 5.0},
	{"name": "Thornbury market", "pos": Config.VILLAGE_CENTER + Vector2(12.0, -3.0), "radius": 6.0},
	{"name": "Tarnwatch gate", "pos": Config.CASTLE_CENTER + Vector2(0, 46), "radius": 10.0},
	{"name": "Tarnwatch keep", "pos": Config.CASTLE_CENTER + Vector2(0, 10), "radius": 9.0},
	{"name": "Ashenfall altar", "pos": Config.RUINS_SITE, "radius": 8.0},
	{"name": "Watchtower ruins", "pos": Config.WATCHTOWER_SITE, "radius": 9.0},
	{"name": "Old camp", "pos": Config.CAMP_SITE, "radius": 8.0},
	{"name": "Cave mouth", "pos": Config.CAVE_SITE + Vector2(0, 5), "radius": 7.0},
	{"name": "Ashenfall falls", "pos": Config.WATERFALL_SITE + Vector2(10, 8), "radius": 14.0},
]


func _ready() -> void:
	collision_layer = 2
	collision_mask = 1
	floor_max_angle = deg_to_rad(52.0)
	floor_snap_length = 0.6
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.42
	capsule.height = 1.85
	var cs := CollisionShape3D.new()
	cs.shape = capsule
	cs.position = Vector3(0, 0.93, 0)
	add_child(cs)
	_build_camera()
	_build_model()
	_last_pos = global_position
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _build_camera() -> void:
	_pivot = Node3D.new()
	_pivot.name = "CameraPivot"
	_pivot.position = Vector3(0, 1.55, 0)
	add_child(_pivot)
	_spring = SpringArm3D.new()
	_spring.name = "SpringArm"
	_spring.spring_length = 5.2
	_spring.margin = 0.35
	_spring.collision_mask = 1
	_spring.position = Vector3(0, 0, 0)
	_pivot.add_child(_spring)
	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.fov = 72.0
	_camera.near = 0.08
	_camera.far = 2400.0
	_spring.add_child(_camera)


func _build_model() -> void:
	_model = Node3D.new()
	_model.name = "Traveller"
	add_child(_model)
	var cloth := Mats.plain(Color(0.24, 0.29, 0.22), 0.95)
	var cloth_dark := Mats.plain(Color(0.18, 0.21, 0.17), 0.95)
	var leather := Mats.plain(Color(0.26, 0.18, 0.12), 0.85)
	var skin := Mats.plain(Color(0.62, 0.47, 0.36), 0.8)

	var torso := CapsuleMesh.new()
	torso.radius = 0.27
	torso.height = 0.95
	_add_part("Torso", torso, Vector3(0, 1.15, 0), cloth, Vector3.ONE)
	var cloak := BoxMesh.new()
	cloak.size = Vector3(0.62, 0.85, 0.16)
	_add_part("Cloak", cloak, Vector3(0, 1.12, -0.18), cloth_dark, Vector3.ONE)
	var head := SphereMesh.new()
	head.radius = 0.155
	head.height = 0.33
	_add_part("Head", head, Vector3(0, 1.78, 0), skin, Vector3.ONE)
	var hood := CylinderMesh.new()
	hood.top_radius = 0.03
	hood.bottom_radius = 0.24
	hood.height = 0.34
	_add_part("Hood", hood, Vector3(0, 1.86, -0.02), cloth_dark, Vector3.ONE)
	var belt := BoxMesh.new()
	belt.size = Vector3(0.56, 0.1, 0.36)
	_add_part("Belt", belt, Vector3(0, 0.92, 0), leather, Vector3.ONE)

	var leg := BoxMesh.new()
	leg.size = Vector3(0.17, 0.78, 0.2)
	_leg_l = _add_part("LegL", leg, Vector3(-0.13, 0.4, 0), leather, Vector3.ONE)
	_leg_r = _add_part("LegR", leg, Vector3(0.13, 0.4, 0), leather, Vector3.ONE)
	var arm := BoxMesh.new()
	arm.size = Vector3(0.14, 0.62, 0.16)
	_arm_l = _add_part("ArmL", arm, Vector3(-0.34, 1.28, 0), cloth, Vector3.ONE)
	_arm_r = _add_part("ArmR", arm, Vector3(0.34, 1.28, 0), cloth, Vector3.ONE)


func _add_part(part_name: String, mesh: Mesh, pos: Vector3, mat: Material,
		scale_v: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = part_name
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.scale = scale_v
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_model.add_child(mi)
	return mi


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		camera_yaw -= event.relative.x * mouse_sensitivity
		camera_pitch = clampf(camera_pitch - event.relative.y * mouse_sensitivity, -1.1, 0.6)
	elif event.is_action_pressed("ui_cancel"):
		_mouse_captured = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		_mouse_captured = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("interact"):
		_interact()


func _physics_process(delta: float) -> void:
	var input_vec := Vector2.ZERO
	if Input.is_action_pressed("move_forward"):
		input_vec.y -= 1.0
	if Input.is_action_pressed("move_back"):
		input_vec.y += 1.0
	if Input.is_action_pressed("move_left"):
		input_vec.x -= 1.0
	if Input.is_action_pressed("move_right"):
		input_vec.x += 1.0
	if input_vec.length() > 1.0:
		input_vec = input_vec.normalized()

	is_sprinting = Input.is_action_pressed("sprint") and input_vec.length() > 0.1
	var target_speed := run_speed if is_sprinting else walk_speed
	var dir := Vector3(input_vec.x, 0.0, input_vec.y)
	dir = dir.rotated(Vector3.UP, camera_yaw)

	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var target := dir * target_speed
	horizontal = horizontal.lerp(target, clampf(acceleration * delta, 0.0, 1.0))
	velocity.x = horizontal.x
	velocity.z = horizontal.z

	if is_on_floor():
		if Input.is_action_just_pressed("jump"):
			velocity.y = jump_velocity
	else:
		velocity.y -= gravity * delta
		if velocity.y < -60.0:
			velocity.y = -60.0

	# Steep slopes: slide back down instead of walking up cliffs.
	if is_on_floor():
		var normal := get_floor_normal()
		var slope := 1.0 - normal.y
		if slope > 0.55:
			velocity += normal * 6.0 * delta * 60.0

	move_and_slide()

	# Keep the player inside the authored world.
	var limit := Config.WORLD_HALF - 26.0
	if absf(global_position.x) > limit or absf(global_position.z) > limit:
		global_position.x = clampf(global_position.x, -limit, limit)
		global_position.z = clampf(global_position.z, -limit, limit)

	_update_model(delta, horizontal.length())
	_update_camera(delta)
	_update_focus()

	var moved := global_position.distance_to(_last_pos)
	if moved < 3.0:
		distance_travelled += moved
	_last_pos = global_position


func _update_camera(delta: float) -> void:
	_pivot.rotation.y = lerp_angle(_pivot.rotation.y, camera_yaw, clampf(delta * 14.0, 0.0, 1.0))
	_pivot.rotation.x = lerp_angle(_pivot.rotation.x, camera_pitch, clampf(delta * 14.0, 0.0, 1.0))
	var speed := Vector3(velocity.x, 0, velocity.z).length()
	var target_fov := 72.0 + (8.0 if speed > 6.0 else 0.0)
	_camera.fov = lerpf(_camera.fov, target_fov, clampf(delta * 3.0, 0.0, 1.0))


func _update_model(delta: float, speed: float) -> void:
	if speed > 0.15:
		var desired_yaw := atan2(velocity.x, velocity.z)
		_model.rotation.y = lerp_angle(_model.rotation.y, desired_yaw, clampf(delta * 9.0, 0.0, 1.0))
	_stride += delta * (2.4 + speed * 0.55)
	var swing := sin(_stride * 2.2) * clampf(speed / run_speed, 0.0, 1.0) * 0.7
	if _leg_l:
		_leg_l.rotation.x = swing
		_leg_r.rotation.x = -swing
	if _arm_l:
		_arm_l.rotation.x = -swing * 0.6
		_arm_r.rotation.x = swing * 0.6
	var bob := absf(sin(_stride * 2.2)) * 0.035 * clampf(speed / 3.0, 0.0, 1.0)
	if _model:
		_model.position.y = bob


func _update_focus() -> void:
	current_focus = ""
	var p := Vector2(global_position.x, global_position.z)
	var best := 1e9
	for lm in _landmarks:
		var d: float = p.distance_to(lm["pos"])
		if d < float(lm["radius"]) and d < best:
			best = d
			current_focus = lm["name"]


func _interact() -> void:
	if current_focus == "":
		return
	if not discovered.has(current_focus):
		discovered.append(current_focus)


func camera_bearing() -> float:
	return fposmod(-rad_to_deg(camera_yaw), 360.0)


func camera_node() -> Camera3D:
	return _camera
