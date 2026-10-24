extends RefCounted
## Mouse-driven Havok-style object handling. The object stays in the physics solver and is pulled toward a point in front
## of the active camera with a damped spring, so it can collide with the player and the world while held.

const GRAB_COLLISION_MASK := 2 | 4 | 16

var player: CharacterBody3D
var world_host: Node3D
var max_reach_from_player_m := 4.5
var min_hold_distance_m := 0.55
var max_hold_distance_m := 5.0
var hold_spring_frequency := 4.0
var hold_damping_ratio := 1.25
var max_hold_acceleration_mps2 := 30.0
var held_angular_damp := 6.0
var drop_velocity_factor := 0.15
var throw_reference_mass_kg := 1.0
var throw_reference_speed_mps := 6.5
var min_throw_speed_mps := 2.5
var max_throw_speed_mps := 10.0
var carried_player_velocity_factor := 0.35

var _held_body: RigidBody3D
var _camera_center_offset := Vector3.ZERO
var _hold_distance := 0.0
var _saved_angular_damp := 0.0
var _saved_angular_damp_mode := RigidBody3D.DAMP_MODE_COMBINE
var _has_saved_angular_damp := false

func configure(player_body: CharacterBody3D, host: Node3D) -> void:
	player = player_body
	world_host = host

func handle_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if mouse_button.button_index == MOUSE_BUTTON_LEFT:
			if mouse_button.pressed:
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and _begin_grab():
					world_host.get_viewport().set_input_as_handled()
					return true
			elif is_holding_object():
				_release_grab(false)
				world_host.get_viewport().set_input_as_handled()
				return true
		elif mouse_button.button_index == MOUSE_BUTTON_RIGHT and mouse_button.pressed and is_holding_object():
			_release_grab(true)
			world_host.get_viewport().set_input_as_handled()
			return true
		elif is_holding_object() and mouse_button.pressed:
			if mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP:
				_hold_distance = maxf(min_hold_distance_m, _hold_distance - 0.25)
				world_host.get_viewport().set_input_as_handled()
				return true
			elif mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_hold_distance = minf(max_hold_distance_m, _hold_distance + 0.25)
				world_host.get_viewport().set_input_as_handled()
				return true
	elif event.is_action_pressed("ui_cancel") and is_holding_object():
		_release_grab(false)
	return false

func physics_update(_delta: float) -> void:
	if not is_holding_object():
		return
	if not is_instance_valid(player) or not is_instance_valid(_held_body) or _held_body.freeze:
		_release_grab(false)
		return
	var camera := _active_camera()
	if camera == null:
		_release_grab(false)
		return
	var camera_basis := camera.global_basis.orthonormalized()
	var target_position: Vector3 = (
		camera.global_position
		- camera_basis.z * _hold_distance
		+ camera_basis * _camera_center_offset
	)
	target_position = _clamp_target_to_world(target_position)
	var natural_frequency: float = hold_spring_frequency * TAU
	var acceleration: Vector3 = (target_position - _held_body.global_position) * natural_frequency * natural_frequency
	acceleration -= _held_body.linear_velocity * (2.0 * hold_damping_ratio * natural_frequency)
	if acceleration.length() > max_hold_acceleration_mps2:
		acceleration = acceleration.normalized() * max_hold_acceleration_mps2
	# Pull through the center of mass to avoid adding torque from an off-center click.
	_held_body.apply_central_force(acceleration * _held_body.mass)

func _clamp_target_to_world(target_position: Vector3) -> Vector3:
	var motion := target_position - _held_body.global_position
	var motion_length := motion.length()
	if motion_length < 0.001:
		return target_position
	var space_state := world_host.get_world_3d().direct_space_state
	var safe_fraction := 1.0
	var excluded_rids: Array[RID] = [_held_body.get_rid(), player.get_rid()]
	for child: Node in _held_body.get_children():
		var collision := child as CollisionShape3D
		if collision == null or collision.disabled or collision.shape == null:
			continue
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = collision.shape
		query.transform = collision.global_transform
		query.motion = motion
		query.collision_mask = 2
		query.exclude = excluded_rids
		query.collide_with_areas = false
		query.collide_with_bodies = true
		var fractions := space_state.cast_motion(query)
		if fractions.size() == 2:
			safe_fraction = minf(safe_fraction, fractions[0])
	if safe_fraction >= 1.0:
		return target_position
	var contact_margin_fraction := minf(safe_fraction, 0.01 / motion_length)
	return _held_body.global_position + motion * maxf(0.0, safe_fraction - contact_margin_fraction)

func is_holding_object() -> bool:
	return is_instance_valid(_held_body)

func release_without_throw() -> void:
	_release_grab(false)

func release_reference(reference_id: int) -> void:
	if is_holding_object() and int(_held_body.get_meta("reference_id", -1)) == reference_id:
		_release_grab(false)

func _begin_grab() -> bool:
	if not is_instance_valid(player) or not is_instance_valid(world_host):
		return false
	if is_holding_object():
		_release_grab(false)
	var camera := _active_camera()
	if camera == null:
		return false
	var screen_center := world_host.get_viewport().get_visible_rect().get_center()
	var ray_origin := camera.project_ray_origin(screen_center)
	var ray_direction := camera.project_ray_normal(screen_center)
	var query := PhysicsRayQueryParameters3D.create(
		ray_origin,
		ray_origin + ray_direction * (max_reach_from_player_m + camera.global_position.distance_to(player.global_position)),
		GRAB_COLLISION_MASK,
		[player.get_rid()]
	)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := world_host.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	var body := hit.get("collider") as RigidBody3D
	if body == null or body.mass <= 0.0 or body.freeze or not bool(body.get_meta("grab_enabled", false)):
		return false
	var hit_position: Vector3 = hit.get("position", ray_origin)
	if hit_position.distance_to(player.global_position + Vector3.UP * 0.9) > max_reach_from_player_m:
		return false
	_held_body = body
	_held_body.sleeping = false
	_camera_center_offset = camera.global_basis.orthonormalized().inverse() * (body.global_position - hit_position)
	_hold_distance = clampf(ray_origin.distance_to(hit_position), min_hold_distance_m, max_hold_distance_m)
	_saved_angular_damp = body.angular_damp
	_saved_angular_damp_mode = body.angular_damp_mode
	_has_saved_angular_damp = true
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp = held_angular_damp
	return true

func _release_grab(throw_object: bool) -> void:
	if not is_instance_valid(_held_body):
		_held_body = null
		return
	var body := _held_body
	_held_body = null
	if _has_saved_angular_damp:
		body.angular_damp_mode = _saved_angular_damp_mode
		body.angular_damp = _saved_angular_damp
		_has_saved_angular_damp = false
	if throw_object and is_instance_valid(player):
		body.sleeping = false
		var camera := _active_camera()
		if camera != null:
			var throw_speed := clampf(
				throw_reference_speed_mps * sqrt(throw_reference_mass_kg / maxf(body.mass, 0.05)),
				min_throw_speed_mps,
				max_throw_speed_mps
			)
			var throw_velocity := -camera.global_basis.z * throw_speed
			var player_velocity := Vector3(player.velocity.x, 0.0, player.velocity.z)
			body.apply_central_impulse((throw_velocity + player_velocity * carried_player_velocity_factor) * body.mass)
	else:
		body.linear_velocity *= drop_velocity_factor

func _active_camera() -> Camera3D:
	if not is_instance_valid(player):
		return null
	var camera := player.get_node_or_null("CameraPivot/Camera3D") as Camera3D
	return camera if camera != null and camera.current else null
