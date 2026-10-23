extends CharacterBody3D
## Third-person blockout controller. Values stay configurable until the
## original executable analysis and in-game comparison establish them.

@export var walk_speed_mps := 2.0
@export var run_speed_mps := 3.4
@export var jump_speed_mps := 4.7
@export var gravity_mps2 := 9.8
@export_range(0.0, 0.6, 0.01) var max_step_height_m := 0.40
@export_range(35.0, 75.0, 1.0) var max_walkable_slope_degrees := 55.0
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
@export var fly_speed_mps := 5.0
@export var fly_fast_speed_mps := 15.0
@export var chain_push_force_newtons := 20.0

@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D

var _camera_pitch := -0.28
var _camera_yaw := 0.0
var _target_camera_distance := 2.0
var _current_camera_distance := 2.0
var _camera_collision_shape: SphereShape3D
var _third_person := true
var _normal_camera_pivot_position := Vector3(0.0, 1.5, 0.0)
var _first_person_eye_anchor := Vector3(0.0, 1.5, 0.0)
var face_preview_enabled := false
var _saved_camera_pitch := -0.28
var _saved_camera_distance := 2.0
var _saved_camera_pivot_position := Vector3(0.0, 1.5, 0.0)
const FACE_PREVIEW_MIN_DISTANCE := 0.002
const CAMERA_COLLISION_MASK := 2
const CAMERA_COLLISION_MARGIN := 0.08
const CHAIN_COLLISION_LAYER := 16
var _capture_mouse_on_focus := false
var _stepper := CharacterStepper.new()
var is_flying := false
var _saved_collision_layer := 1
var _saved_collision_mask := 23
var _footstep_distance_m := 0.0

var is_first_person: bool:
	get:
		return not face_preview_enabled and not _third_person

func _ready() -> void:
	_normal_camera_pivot_position = camera_pivot.position
	_first_person_eye_anchor = _normal_camera_pivot_position
	_camera_yaw = rotation.y
	_target_camera_distance = camera_distance
	_current_camera_distance = camera_distance
	floor_snap_length = maxf(0.5, max_step_height_m + 0.1)
	floor_max_angle = deg_to_rad(max_walkable_slope_degrees)
	floor_constant_speed = true
	# Godot's default 15-degree wall threshold stops the body when it walks almost
	# straight into a wall. Zero lets it slide along the wall at any approach angle.
	wall_min_slide_angle = 0.0
	_camera_collision_shape = SphereShape3D.new()
	_camera_collision_shape.radius = camera_collision_radius
	camera.position = Vector3(camera_shoulder_offset, 0.0, _current_camera_distance)
	_apply_camera_orbit()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func set_spawn_yaw(yaw: float) -> void:
	_camera_yaw = wrapf(yaw, -PI, PI)
	rotation.y = _camera_yaw
	_apply_camera_orbit()

func set_first_person_eye_anchor(anchor: Vector3) -> void:
	_first_person_eye_anchor = anchor
	if is_first_person:
		camera_pivot.position = _first_person_eye_anchor
		camera.position = Vector3.ZERO

func capture_mouse() -> void:
	_capture_mouse_on_focus = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func release_mouse() -> void:
	_capture_mouse_on_focus = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func set_fly_mode(enabled: bool) -> void:
	if is_flying == enabled:
		return
	if enabled:
		_saved_collision_layer = collision_layer
		_saved_collision_mask = collision_mask
		collision_layer = 0
		collision_mask = 0
	else:
		collision_layer = _saved_collision_layer
		collision_mask = _saved_collision_mask
	velocity = Vector3.ZERO
	is_flying = enabled
	if not enabled:
		force_update_transform()

func toggle_face_preview(face_anchor: Vector3) -> bool:
	face_preview_enabled = not face_preview_enabled
	if face_preview_enabled:
		_saved_camera_pitch = _camera_pitch
		_saved_camera_distance = _target_camera_distance
		_saved_camera_pivot_position = camera_pivot.position
		camera.near = 0.001
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

func update_face_preview_anchor(face_anchor: Vector3) -> void:
	if face_preview_enabled:
		camera_pivot.position = face_anchor

func _process(delta: float) -> void:
	rotation.y = _camera_yaw
	_apply_camera_orbit()

func handle_camera_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_camera_yaw = wrapf(_camera_yaw - event.relative.x * mouse_sensitivity, -PI, PI)
		var pitch_min := camera_pitch_min_degrees
		var pitch_max := camera_pitch_max_degrees
		if face_preview_enabled:
			pitch_min = -20.0
			pitch_max = 20.0
		elif is_flying:
			pitch_min = -89.0
			pitch_max = 89.0
		_camera_pitch = clampf(
			_camera_pitch - event.relative.y * mouse_sensitivity,
			deg_to_rad(pitch_min),
			deg_to_rad(pitch_max)
		)
		_apply_camera_orbit()
		get_viewport().set_input_as_handled()
	elif event is InputEventPanGesture:
		if not is_zero_approx(event.delta.y):
			if face_preview_enabled:
				_set_camera_distance(_target_camera_distance * exp(event.delta.y * 0.14))
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
				_set_camera_distance(_target_camera_distance * 0.68)
			else:
				_set_camera_distance(_target_camera_distance - camera_zoom_speed * 0.25)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if face_preview_enabled:
				_set_camera_distance(_target_camera_distance / 0.68)
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
		if not face_preview_enabled:
			camera_pivot.position = _first_person_eye_anchor if is_first_person else _normal_camera_pivot_position
		camera_pivot.rotation = Vector3(_camera_pitch, PI if face_preview_enabled else 0.0, 0.0)
		if is_first_person:
			camera.position = Vector3.ZERO

func _set_camera_distance(distance: float) -> void:
	var min_distance := FACE_PREVIEW_MIN_DISTANCE if face_preview_enabled else camera_zoom_min
	_target_camera_distance = clampf(distance, min_distance, camera_zoom_max)
	_third_person = _target_camera_distance > camera_zoom_min + 0.05
	if is_inside_tree() and _camera_collision_shape != null and _target_camera_distance < _current_camera_distance:
		_update_camera_clearance(0.0)

func _physics_process(delta: float) -> void:
	if is_flying:
		var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		var vertical := (1.0 if Input.is_key_pressed(KEY_SPACE) else 0.0) - (1.0 if Input.is_key_pressed(KEY_CTRL) else 0.0)
		var view_yaw := _camera_yaw + (PI if face_preview_enabled else 0.0)
		var view_basis := Basis(Vector3.UP, view_yaw) * Basis(Vector3.RIGHT, _camera_pitch)
		var direction := view_basis * Vector3(input.x, 0.0, input.y) + Vector3.UP * vertical
		if direction.length_squared() > 1.0:
			direction = direction.normalized()
		var speed := fly_fast_speed_mps if Input.is_action_pressed("run") else fly_speed_mps
		velocity = direction * speed
		global_position += velocity * delta
		return

	_update_camera_clearance(delta)

	# While a step is in progress the capsule rolls over a tread's rounded nose,
	# where it is not on the floor yet. Gravity is held off so it can finish the step,
	# but a jump still starts from there.
	if Input.is_action_just_pressed("jump") and (is_on_floor() or _stepper.is_stepping()):
		_stepper.cancel()
		velocity.y = jump_speed_mps
	elif _stepper.is_stepping():
		velocity.y = 0.0
	elif not is_on_floor():
		velocity.y -= gravity_mps2 * delta

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

	var requested_velocity := velocity
	var horizontal_motion := Vector3(velocity.x, 0.0, velocity.z) * delta
	var previous_position := global_position
	if (
		(is_on_floor() or _stepper.is_stepping())
		and _stepper.try_step_up(self, horizontal_motion, max_step_height_m, floor_max_angle)
	):
		_update_footstep_audio(previous_position)
		return
	_stepper.tick()
	var was_on_floor := is_on_floor()
	move_and_slide()
	_push_contacted_chains(requested_velocity)
	if (was_on_floor or _stepper.is_stepping()) and not is_on_floor() and velocity.y <= 0.0:
		_stepper.try_step_down(self, max_step_height_m)
	_update_footstep_audio(previous_position)

func _update_footstep_audio(previous_position: Vector3) -> void:
	if not (is_on_floor() or _stepper.is_stepping()):
		return
	var planar_distance := Vector2(global_position.x - previous_position.x, global_position.z - previous_position.z).length()
	if planar_distance <= 0.001:
		return
	_footstep_distance_m += planar_distance
	var running := Input.is_action_pressed("run")
	var stride_length := 0.62 if running else 0.86
	if _footstep_distance_m < stride_length:
		return
	_footstep_distance_m = fmod(_footstep_distance_m, stride_length)
	var audio_manager := get_tree().root.get_node_or_null("AudioManager")
	if audio_manager != null:
		audio_manager.call("play_footstep", self, running)

## True while a step is in progress, so the actor is still treated as grounded.
func is_stepping() -> bool:
	return _stepper.is_stepping()

func _push_contacted_chains(requested_velocity: Vector3) -> void:
	var horizontal_velocity := Vector3(requested_velocity.x, 0.0, requested_velocity.z)
	if horizontal_velocity.length_squared() < 0.01:
		return
	for collision_index in range(get_slide_collision_count()):
		var collision := get_slide_collision(collision_index)
		var chain := collision.get_collider() as RigidBody3D
		if chain == null or (chain.collision_layer & CHAIN_COLLISION_LAYER) == 0:
			continue
		var normal := collision.get_normal()
		var horizontal_normal := Vector3(normal.x, 0.0, normal.z)
		if horizontal_normal.length_squared() < 0.01:
			continue
		horizontal_normal = horizontal_normal.normalized()
		var push_speed := maxf(0.0, -horizontal_velocity.dot(horizontal_normal))
		if push_speed <= 0.05:
			continue
		var force := -horizontal_normal * chain_push_force_newtons * clampf(push_speed / run_speed_mps, 0.0, 1.0)
		var contact_offset := collision.get_position() - chain.global_position
		chain.apply_force(force, contact_offset)

func _update_camera_clearance(delta: float) -> void:
	if is_flying:
		_current_camera_distance = _target_camera_distance
		camera.position = Vector3(camera_shoulder_offset, 0.0, _current_camera_distance)
		return
	if is_first_person:
		_current_camera_distance = 0.0
		camera.position = Vector3.ZERO
		return
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _camera_collision_shape
	var camera_start := camera_pivot.global_position + camera_pivot.global_basis.x * camera_shoulder_offset
	query.transform = Transform3D(Basis.IDENTITY, camera_start)
	query.motion = camera_pivot.global_basis.z * _target_camera_distance
	query.collision_mask = CAMERA_COLLISION_MASK
	query.exclude = [get_rid()]
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.margin = 0.02

	var fractions := get_world_3d().direct_space_state.cast_motion(query)
	var min_distance := FACE_PREVIEW_MIN_DISTANCE if face_preview_enabled else camera_zoom_min
	var available_distance := _target_camera_distance
	if fractions.size() == 2 and fractions[0] < 1.0:
		available_distance *= fractions[0]
		available_distance = maxf(min_distance, available_distance - CAMERA_COLLISION_MARGIN)

	# Move inward before entering a wall; ease back out after the view is clear.
	if available_distance < _current_camera_distance:
		_current_camera_distance = available_distance
	else:
		_current_camera_distance = lerpf(
			_current_camera_distance,
			available_distance,
			1.0 - exp(-camera_smoothing * delta)
		)
	camera.position = Vector3(camera_shoulder_offset, 0.0, _current_camera_distance)
