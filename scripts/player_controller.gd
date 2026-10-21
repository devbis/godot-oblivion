extends CharacterBody3D
## Third-person blockout controller. Values stay configurable until the
## original executable analysis and in-game comparison establish them.

@export var walk_speed_mps := 2.0
@export var run_speed_mps := 3.4
@export var jump_speed_mps := 4.7
@export var gravity_mps2 := 9.8
@export var mouse_sensitivity := 0.004
@export var camera_pitch_min_degrees := -60.0
@export var camera_pitch_max_degrees := 35.0
@export var camera_distance := 2.0
@export var camera_shoulder_offset := 0.0
@export var camera_zoom_min := 0.18
@export var camera_zoom_max := 5.0
@export var camera_zoom_speed := 2.0
@export var camera_smoothing := 14.0
@export var camera_collision_radius := 0.18

@onready var camera_pivot: Node3D = $CameraPivot
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D

var _camera_pitch := -0.28
var _camera_yaw := 0.0
var _target_camera_distance := 2.0
var _current_camera_distance := 2.0
var _camera_collision_shape: SphereShape3D
var _third_person := true
var face_preview_enabled := false
var _saved_camera_pitch := -0.28
var _saved_camera_distance := 2.0
var _saved_camera_pivot_position := Vector3(0.0, 1.5, 0.0)
const FACE_PREVIEW_MIN_DISTANCE := 0.005
var _capture_mouse_on_focus := false

func _ready() -> void:
	_camera_yaw = rotation.y
	_target_camera_distance = camera_distance
	_current_camera_distance = camera_distance
	spring_arm.collision_mask = 2
	spring_arm.margin = 0.08
	_camera_collision_shape = SphereShape3D.new()
	_camera_collision_shape.radius = camera_collision_radius
	spring_arm.shape = _camera_collision_shape
	spring_arm.spring_length = camera_distance
	camera.position.x = camera_shoulder_offset
	_apply_camera_orbit()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func set_spawn_yaw(yaw: float) -> void:
	_camera_yaw = wrapf(yaw, -PI, PI)
	rotation.y = _camera_yaw
	_apply_camera_orbit()

func capture_mouse() -> void:
	_capture_mouse_on_focus = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func release_mouse() -> void:
	_capture_mouse_on_focus = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func toggle_face_preview(face_anchor: Vector3) -> bool:
	face_preview_enabled = not face_preview_enabled
	if face_preview_enabled:
		_saved_camera_pitch = _camera_pitch
		_saved_camera_distance = _target_camera_distance
		_saved_camera_pivot_position = camera_pivot.position
		camera.near = 0.005
		_camera_pitch = 0.0
		camera_pivot.position = face_anchor
		_set_camera_distance(0.08)
	else:
		_camera_pitch = _saved_camera_pitch
		camera_pivot.position = _saved_camera_pivot_position
		camera.near = 0.05
		_set_camera_distance(_saved_camera_distance)
	_apply_camera_orbit()
	return face_preview_enabled

func _process(delta: float) -> void:
	rotation.y = _camera_yaw
	_apply_camera_orbit()

func handle_camera_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_camera_yaw = wrapf(_camera_yaw - event.relative.x * mouse_sensitivity, -PI, PI)
		_camera_pitch = clampf(
			_camera_pitch - event.relative.y * mouse_sensitivity,
			deg_to_rad(camera_pitch_min_degrees),
			deg_to_rad(camera_pitch_max_degrees)
		)
		_apply_camera_orbit()
		get_viewport().set_input_as_handled()
	elif event is InputEventPanGesture:
		if not is_zero_approx(event.delta.y):
			if face_preview_enabled:
				_set_camera_distance(_target_camera_distance * exp(event.delta.y * 0.08))
			else:
				_set_camera_distance(_target_camera_distance + event.delta.y * camera_zoom_speed * 0.04)
			get_viewport().set_input_as_handled()
	elif event is InputEventMagnifyGesture:
		if event.factor > 0.0 and not is_equal_approx(event.factor, 1.0):
			_set_camera_distance(_target_camera_distance / event.factor)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if face_preview_enabled:
				_set_camera_distance(_target_camera_distance * 0.8)
			else:
				_set_camera_distance(_target_camera_distance - camera_zoom_speed * 0.25)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if face_preview_enabled:
				_set_camera_distance(_target_camera_distance / 0.8)
			else:
				_set_camera_distance(_target_camera_distance + camera_zoom_speed * 0.25)
			get_viewport().set_input_as_handled()
		elif Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			capture_mouse()
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_V:
		_third_person = not _third_person
		_set_camera_distance(camera_distance if _third_person else camera_zoom_min)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		release_mouse()
		get_viewport().set_input_as_handled()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and _capture_mouse_on_focus:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _apply_camera_orbit() -> void:
	if is_instance_valid(camera_pivot):
		camera_pivot.rotation = Vector3(_camera_pitch, PI if face_preview_enabled else 0.0, 0.0)

func _set_camera_distance(distance: float) -> void:
	var min_distance := FACE_PREVIEW_MIN_DISTANCE if face_preview_enabled else camera_zoom_min
	_target_camera_distance = clampf(distance, min_distance, camera_zoom_max)
	_third_person = _target_camera_distance > camera_zoom_min + 0.05

func _physics_process(delta: float) -> void:
	_update_camera_clearance(delta)

	if not is_on_floor():
		velocity.y -= gravity_mps2 * delta
	elif Input.is_action_just_pressed("jump"):
		velocity.y = jump_speed_mps

	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var camera_basis := Basis(Vector3.UP, rotation.y)
	var direction := (camera_basis * Vector3(input.x, 0.0, input.y)).normalized()
	var speed := run_speed_mps if Input.is_action_pressed("run") else walk_speed_mps
	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed * 8.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, speed * 8.0 * delta)

	move_and_slide()

func _update_camera_clearance(delta: float) -> void:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _camera_collision_shape
	query.transform = Transform3D(Basis.IDENTITY, camera_pivot.global_position)
	query.motion = -camera_pivot.global_basis.z * _target_camera_distance
	query.collision_mask = spring_arm.collision_mask
	query.exclude = [get_rid()]
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.margin = 0.02

	var fractions := get_world_3d().direct_space_state.cast_motion(query)
	var min_distance := FACE_PREVIEW_MIN_DISTANCE if face_preview_enabled else camera_zoom_min
	var available_distance := _target_camera_distance
	if fractions.size() == 2 and fractions[0] < 1.0:
		available_distance *= fractions[0]
		available_distance = maxf(min_distance, available_distance - spring_arm.margin)

	# Move inward before entering a wall; ease back out after the view is clear.
	if available_distance < _current_camera_distance:
		_current_camera_distance = available_distance
	else:
		_current_camera_distance = lerpf(
			_current_camera_distance,
			available_distance,
			1.0 - exp(-camera_smoothing * delta)
		)
	spring_arm.spring_length = _current_camera_distance
