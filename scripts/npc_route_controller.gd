extends CharacterBody3D
## Lightweight waypoint locomotion for placed Oblivion actors.
## NPCs use generated floor geometry when it is available and retain the ESM
## route plane in cells where no walkable floor collider can be found.

const HIT_IMPULSE_CAP_MPS := 0.4
const HOP_RUN_SPEED_MPS := 3.4
const HOP_ARRIVAL_M := 0.6
const HOP_VOID_DEPTH_M := 3.0
const HOP_TIMEOUT_S := 5.0

@export var walk_speed_mps := 1.3
@export var gravity_mps2 := 9.8
@export var arrival_distance := 0.08
## Pause at each waypoint. The ESM does not give one, so the default is none.
@export var waypoint_pause_seconds := 0.0
@export var max_route_step_height_m := 0.40
@export var max_route_drop_m := 0.55
@export_range(35.0, 75.0, 1.0) var max_walkable_slope_degrees := 55.0

const YIELD_CLEARANCE_PAUSE_S := 0.45
const YIELD_RETRY_COOLDOWN_S := 0.8
const YIELD_BLOCKED_WAIT_S := 0.65
const YIELD_REQUEST_COOLDOWN_S := 1.0
const ROUTE_BLOCKED_REPORT_S := 0.8
const NPC_NAVIGATION_LAYERS := 3

## Emitted once when the route reaches its last waypoint and does not loop.
signal route_finished

var waypoints: Array[Vector3] = []
var waypoint_speeds: Array[float] = []
var waypoint_is_teleport: Array[bool] = []
var waypoint_teleport_destinations: Array[Vector3] = []
## A hop waypoint jumps down from a ledge to its destination (kept in waypoint_teleport_destinations).
var waypoint_is_hop: Array[bool] = []
var waypoint_index := 0
var final_arrival_distance := 0.08
var loops_route := false
var is_walking := false
var grounding_enabled := false
## PGRD points are the authored walk plane. Use them to support an actor across small collision gaps in imported cells.
var follow_authored_route_height := false
## Whether the walk checks the floor ahead for a drop. A route of several points comes from the navigation tiles, which
## already keep to walkable floor, so the check is only kept for a single straight target.
var check_floor_ahead := true
## A killed or disabled actor: its route is never run again and physics stays off.
var inactive := false
var dialogue_paused := false
var knocked_down := false
var _pause_remaining := 0.0
var _last_grounded_position := Vector3.ZERO
var _has_last_grounded_position := false
var _yield_path := PackedVector3Array()
var _yield_waypoint_index := 0
var _yield_cooldown_remaining := 0.0
var _route_blocked_elapsed := 0.0
var _route_blocked_reported := false
var _yield_request_cooldown_remaining := 0.0
var _stepper := CharacterStepper.new()
var _footstep_distance_m := 0.0
var _hit_velocity := Vector3.ZERO
var _hop_active := false
var _hop_to := Vector3.ZERO
var _hop_elapsed := 0.0
var _pending_route: Array = []

func _ready() -> void:
	floor_max_angle = deg_to_rad(max_walkable_slope_degrees)
	wall_min_slide_angle = 0.0

## Moves the actor without walking: the route it was following and the remembered ground belong to the old place, so
## both go, and the package route is planned again from here.
func teleport_to(destination: Vector3) -> void:
	_hop_active = false
	_pending_route.clear()
	global_position = destination
	velocity = Vector3.ZERO
	is_walking = false
	_yield_path.clear()
	_yield_waypoint_index = 0
	waypoints.clear()
	waypoint_speeds.clear()
	waypoint_is_teleport.clear()
	waypoint_teleport_destinations.clear()
	waypoint_is_hop.clear()
	waypoint_index = 0
	_route_blocked_elapsed = 0.0
	_route_blocked_reported = false
	_last_grounded_position = destination
	_has_last_grounded_position = grounding_enabled
	set_physics_process(not inactive and grounding_enabled)

func configure_route(
	route: Array[Dictionary], should_loop: bool, initial_pause: float,
	final_arrival_distance_m: float = -1.0, use_authored_route_height: bool = false
) -> void:
	# A hop in the air finishes first; the new route starts where it lands.
	if _hop_active:
		_pending_route = [route, should_loop, initial_pause, final_arrival_distance_m, use_authored_route_height]
		return
	_yield_path.clear()
	_yield_waypoint_index = 0
	waypoints.clear()
	waypoint_speeds.clear()
	waypoint_is_teleport.clear()
	waypoint_teleport_destinations.clear()
	waypoint_is_hop.clear()
	for waypoint: Dictionary in route:
		waypoints.push_back(waypoint.get("position", global_position))
		waypoint_speeds.push_back(float(waypoint.get("speed_mps", walk_speed_mps)))
		var teleport_destination: Variant = waypoint.get("teleport_to")
		var hop_destination: Variant = waypoint.get("hop_to")
		var is_teleport := teleport_destination is Vector3
		var is_hop := hop_destination is Vector3
		waypoint_is_teleport.push_back(is_teleport)
		waypoint_is_hop.push_back(is_hop)
		waypoint_teleport_destinations.push_back(teleport_destination if is_teleport else (hop_destination if is_hop else Vector3.ZERO))
	loops_route = should_loop
	follow_authored_route_height = use_authored_route_height
	final_arrival_distance = maxf(arrival_distance, final_arrival_distance_m) if final_arrival_distance_m >= 0.0 else arrival_distance
	check_floor_ahead = waypoints.size() <= 1
	_pause_remaining = initial_pause
	waypoint_index = 0
	velocity = Vector3.ZERO
	is_walking = false
	_route_blocked_elapsed = 0.0
	_route_blocked_reported = false
	# A repath in mid-air must not take the airborne spot as the place to fall back to.
	if grounding_enabled and (is_on_floor() or not _has_last_grounded_position):
		_last_grounded_position = global_position
		_has_last_grounded_position = true
	set_physics_process(not inactive and (grounding_enabled or not waypoints.is_empty()))

## A routed actor can ask another actor to make room. The blocker keeps its package route and briefly
## follows a navmesh sidestep; its original waypoint route resumes once the yield path is complete.
func request_yield(
	away_direction: Vector3, approach_direction: Vector3, requester_position: Vector3, distance_m: float
) -> bool:
	if inactive or dialogue_paused or not _yield_path.is_empty() or _yield_cooldown_remaining > 0.0:
		return false
	var has_active_route := not waypoints.is_empty() and waypoint_index < waypoints.size()
	if has_active_route and _route_blocked_elapsed < YIELD_BLOCKED_WAIT_S and _pause_remaining <= 0.0:
		return false
	var away := away_direction
	away.y = 0.0
	var approach := approach_direction
	approach.y = 0.0
	var route_direction := _current_route_direction()
	var axes: Array[Vector3] = []
	if approach.length_squared() > 0.0001:
		axes.push_back(approach.normalized())
	if route_direction.length_squared() > 0.0001:
		var duplicate_axis := false
		for axis: Vector3 in axes:
			if absf(axis.dot(route_direction)) > 0.9:
				duplicate_axis = true
				break
		if not duplicate_axis:
			axes.push_back(route_direction)
	if axes.is_empty() and away.length_squared() > 0.0001:
		axes.push_back(away.normalized())
	if axes.is_empty():
		return false

	var directions: Array[Vector3] = []
	var requester_offset := requester_position - global_position
	requester_offset.y = 0.0
	for axis: Vector3 in axes:
		var side := Vector3(-axis.z, 0.0, axis.x)
		var side_dot := side.dot(requester_offset)
		var preferred_side: Vector3
		if absf(side_dot) > 0.05:
			preferred_side = -side if side_dot > 0.0 else side
		elif absf(side.dot(away)) > 0.15:
			preferred_side = side if side.dot(away) > 0.0 else -side
		else:
			preferred_side = side if get_instance_id() % 2 == 0 else -side
		_append_yield_direction(directions, preferred_side)
		_append_yield_direction(directions, -preferred_side)
		_append_yield_direction(directions, (preferred_side * 0.8 + axis * 0.6).normalized())
		_append_yield_direction(directions, (preferred_side * 0.8 - axis * 0.6).normalized())
		_append_yield_direction(directions, axis)
		_append_yield_direction(directions, -axis)
	if away.length_squared() > 0.0001:
		_append_yield_direction(directions, away.normalized())

	var navigation_map := get_world_3d().navigation_map
	for direction: Vector3 in directions:
		var path := _yield_path_for_direction(navigation_map, direction, distance_m)
		if path.is_empty():
			continue
		_yield_path = path
		break
	if _yield_path.is_empty():
		return false
	_yield_waypoint_index = 0
	_route_blocked_elapsed = 0.0
	_route_blocked_reported = false
	set_physics_process(true)
	print("OpenOB AI avoidance: %s yields from=%s to=%s" % [
		name, str(global_position), str(_yield_path[_yield_path.size() - 1])
	])
	return true

func _current_route_direction() -> Vector3:
	if waypoints.is_empty() or waypoint_index >= waypoints.size():
		return Vector3.ZERO
	var direction := waypoints[waypoint_index] - global_position
	direction.y = 0.0
	if direction.length_squared() <= 0.0001 and waypoint_index + 1 < waypoints.size():
		direction = waypoints[waypoint_index + 1] - global_position
		direction.y = 0.0
	return direction.normalized() if direction.length_squared() > 0.0001 else Vector3.ZERO

func _append_yield_direction(directions: Array[Vector3], direction: Vector3) -> void:
	var flat_direction := direction
	flat_direction.y = 0.0
	if flat_direction.length_squared() <= 0.0001:
		return
	flat_direction = flat_direction.normalized()
	for existing: Vector3 in directions:
		if existing.dot(flat_direction) > 0.98:
			return
	directions.push_back(flat_direction)

func _yield_path_for_direction(navigation_map: RID, direction: Vector3, distance_m: float) -> PackedVector3Array:
	var target := global_position + direction * distance_m
	var target_on_mesh := NavigationServer3D.map_get_closest_point(navigation_map, target)
	if Vector2(target_on_mesh.x - target.x, target_on_mesh.z - target.z).length() > 0.35:
		return PackedVector3Array()
	var path := NavigationServer3D.map_get_path(
		navigation_map, global_position, target_on_mesh, true, NPC_NAVIGATION_LAYERS
	)
	if path.size() < 2:
		return PackedVector3Array()
	var path_end := path[path.size() - 1]
	if Vector2(path_end.x - target_on_mesh.x, path_end.z - target_on_mesh.z).length() > 0.35:
		return PackedVector3Array()
	var achieved_offset := path_end - global_position
	achieved_offset.y = 0.0
	if achieved_offset.length() < 0.25 or achieved_offset.normalized().dot(direction) < 0.25:
		return PackedVector3Array()
	return path

func get_collision_radius() -> float:
	for child: Node in get_children():
		var collision := child as CollisionShape3D
		if collision == null or collision.shape == null:
			continue
		if collision.shape is CapsuleShape3D:
			return (collision.shape as CapsuleShape3D).radius + collision.shape.margin
		if collision.shape is SphereShape3D:
			return (collision.shape as SphereShape3D).radius + collision.shape.margin
	return 0.18

func is_yielding() -> bool:
	return not _yield_path.is_empty() or _yield_cooldown_remaining > 0.0

func is_hop_waypoint(index: int) -> bool:
	return index >= 0 and index < waypoint_is_hop.size() and waypoint_is_hop[index]

func _begin_hop(destination: Vector3) -> void:
	_hop_active = true
	_hop_to = destination
	_hop_elapsed = 0.0

## The drop leg is walked with real physics (gravity, collision): the actor walks off the edge toward the landing and falls
## onto whatever is below. The guards of a normal route (floor ahead, fall limit, authored height) are off during it. It
## ends on the floor near the landing, or is put at the landing when the fall leaves the geometry or takes too long.
func _update_hop(delta: float) -> void:
	_hop_elapsed += delta
	var to_landing := Vector3(_hop_to.x - global_position.x, 0.0, _hop_to.z - global_position.z)
	var flat_distance := to_landing.length()
	var below_landing := global_position.y < _hop_to.y - HOP_VOID_DEPTH_M
	if (flat_distance <= HOP_ARRIVAL_M and is_on_floor()) or below_landing or _hop_elapsed > HOP_TIMEOUT_S:
		if below_landing or _hop_elapsed > HOP_TIMEOUT_S:
			global_position = _hop_to
		_end_hop()
		return
	var direction := to_landing / flat_distance if flat_distance > 0.05 else Vector3.ZERO
	if flat_distance > 0.05:
		_face_route_direction(direction, delta)
	velocity.x = direction.x * HOP_RUN_SPEED_MPS
	velocity.z = direction.z * HOP_RUN_SPEED_MPS
	velocity.y = 0.0 if is_on_floor() else velocity.y - gravity_mps2 * delta
	is_walking = true
	move_and_slide()

func _end_hop() -> void:
	_hop_active = false
	velocity = Vector3.ZERO
	if grounding_enabled:
		_last_grounded_position = global_position
		_has_last_grounded_position = true
	if is_hop_waypoint(waypoint_index):
		_advance_waypoint()
	if not _pending_route.is_empty():
		var pending := _pending_route.duplicate()
		_pending_route.clear()
		configure_route(pending[0], pending[1], pending[2], pending[3], pending[4])

func is_teleport_waypoint(index: int) -> bool:
	return index >= 0 and index < waypoint_is_teleport.size() and waypoint_is_teleport[index]

func set_dialogue_paused(paused: bool) -> void:
	dialogue_paused = paused
	if paused:
		velocity = Vector3.ZERO
		is_walking = false

func apply_hit_impulse(impulse: Vector3) -> void:
	_hit_velocity = (_hit_velocity + Vector3(impulse.x, 0.0, impulse.z)).limit_length(HIT_IMPULSE_CAP_MPS)
	_hit_velocity.y = 0.0

func set_knocked_down(value: bool) -> void:
	knocked_down = value
	if value:
		_yield_path.clear()
		waypoints.clear()
		waypoint_speeds.clear()
		waypoint_is_teleport.clear()
		waypoint_teleport_destinations.clear()
		waypoint_is_hop.clear()
		_hop_active = false
		_pending_route.clear()
		waypoint_index = 0
		velocity.x = 0.0
		velocity.z = 0.0
		is_walking = false
		set_physics_process(not inactive and grounding_enabled)

func _physics_process(delta: float) -> void:
	_yield_cooldown_remaining = maxf(0.0, _yield_cooldown_remaining - delta)
	_yield_request_cooldown_remaining = maxf(0.0, _yield_request_cooldown_remaining - delta)
	if inactive:
		set_physics_process(false)
		return
	if dialogue_paused:
		velocity = Vector3.ZERO
		is_walking = false
		return
	if _hop_active and not knocked_down:
		_update_hop(delta)
		return
	if knocked_down:
		velocity.x = move_toward(velocity.x + _hit_velocity.x, 0.0, 9.0 * delta)
		velocity.z = move_toward(velocity.z + _hit_velocity.z, 0.0, 9.0 * delta)
		_hit_velocity = _hit_velocity.move_toward(Vector3.ZERO, 12.0 * delta)
		if grounding_enabled:
			velocity.y = 0.0 if is_on_floor() or _stepper.is_stepping() else velocity.y - gravity_mps2 * delta
		else:
			velocity.y = 0.0
		_stepper.tick()
		move_and_slide()
		is_walking = false
		return
	var desired_horizontal_velocity := Vector3.ZERO
	if _pause_remaining > 0.0:
		_pause_remaining = maxf(0.0, _pause_remaining - delta)
	elif not _yield_path.is_empty() and _yield_waypoint_index < _yield_path.size():
		var offset := _yield_path[_yield_waypoint_index] - global_position
		offset.y = 0.0
		if offset.length() <= arrival_distance:
			_yield_waypoint_index += 1
			if _yield_waypoint_index >= _yield_path.size():
				_yield_path.clear()
				_yield_waypoint_index = 0
				_rejoin_route_after_yield()
				_yield_cooldown_remaining = YIELD_RETRY_COOLDOWN_S
				_pause_remaining = maxf(_pause_remaining, YIELD_CLEARANCE_PAUSE_S)
		else:
			var direction := offset.normalized()
			_face_route_direction(direction, delta)
			desired_horizontal_velocity = direction * minf(walk_speed_mps, 0.8)
	elif not waypoints.is_empty() and waypoint_index < waypoints.size():
		var offset := waypoints[waypoint_index] - global_position
		offset.y = 0.0
		var waypoint_arrival_distance := arrival_distance
		if not loops_route and waypoint_index == waypoints.size() - 1:
			waypoint_arrival_distance = final_arrival_distance
		if offset.length() <= waypoint_arrival_distance:
			if is_hop_waypoint(waypoint_index):
				_begin_hop(waypoint_teleport_destinations[waypoint_index])
				return
			if is_teleport_waypoint(waypoint_index):
				global_position = waypoint_teleport_destinations[waypoint_index]
				velocity = Vector3.ZERO
				if grounding_enabled:
					_last_grounded_position = global_position
					_has_last_grounded_position = true
			_advance_waypoint()
		else:
			var direction := offset.normalized()
			_face_route_direction(direction, delta)
			var speed := waypoint_speeds[waypoint_index] if waypoint_index < waypoint_speeds.size() else walk_speed_mps
			desired_horizontal_velocity = direction * speed

	if grounding_enabled:
		var follows_route_plane := follow_authored_route_height \
			and not waypoints.is_empty() and waypoint_index < waypoints.size()
		if follows_route_plane:
			# Oblivion's pathgrid records the intended floor height. A few imported cells have gaps between
			# static collision meshes; gravity alone drops an actor off that authored route before the next floor.
			var route_height_error := waypoints[waypoint_index].y - global_position.y
			velocity.y = clampf(route_height_error * 4.0, -1.2, 1.2)
		else:
			velocity.y = 0.0 if (is_on_floor() or _stepper.is_stepping()) else velocity.y - gravity_mps2 * delta
		if (
			desired_horizontal_velocity.length_squared() > 0.0001
			and is_on_floor()
			and check_floor_ahead
			and not _has_walkable_floor_ahead(desired_horizontal_velocity, delta)
		):
			desired_horizontal_velocity = Vector3.ZERO
	else:
		velocity.y = 0.0
	velocity.x = desired_horizontal_velocity.x + _hit_velocity.x
	velocity.z = desired_horizontal_velocity.z + _hit_velocity.z
	_hit_velocity = _hit_velocity.move_toward(Vector3.ZERO, 12.0 * delta)
	var previous_position := global_position
	var horizontal_motion := Vector3(velocity.x, 0.0, velocity.z) * delta
	var stepped := (
		grounding_enabled
		and (is_on_floor() or _stepper.is_stepping())
		and _stepper.try_step_up(self, horizontal_motion, max_route_step_height_m, deg_to_rad(max_walkable_slope_degrees))
	)
	if not stepped:
		_stepper.tick()
		var was_on_floor := is_on_floor()
		move_and_slide()
		_request_blocking_npcs_to_yield(desired_horizontal_velocity)
		if grounding_enabled and (was_on_floor or _stepper.is_stepping()) and not is_on_floor() and velocity.y <= 0.0:
			_stepper.try_step_down(self, max_route_step_height_m)
	if grounding_enabled:
		# A step in progress is grounded too; otherwise a long descent would look like a fall.
		if is_on_floor() or _stepper.is_stepping():
			_last_grounded_position = global_position
			_has_last_grounded_position = true
		elif _has_last_grounded_position and global_position.y < _last_grounded_position.y - max_route_drop_m:
			global_position = _last_grounded_position
			velocity = Vector3.ZERO
			_pause_remaining = maxf(_pause_remaining, waypoint_pause_seconds)
	var horizontal_displacement := global_position - previous_position
	horizontal_displacement.y = 0.0
	if not _yield_path.is_empty():
		_route_blocked_elapsed = 0.0
	elif desired_horizontal_velocity.length_squared() > 0.0001:
		var expected_progress := desired_horizontal_velocity.length() * delta
		var actual_progress := horizontal_displacement.dot(desired_horizontal_velocity.normalized())
		if actual_progress < expected_progress * 0.35:
			_route_blocked_elapsed += delta
			if _route_blocked_elapsed >= ROUTE_BLOCKED_REPORT_S and not _route_blocked_reported:
				var target := waypoints[waypoint_index] if waypoint_index < waypoints.size() else global_position
				print("OpenOB AI route blocked: %s at=%s waypoint=%d/%d target=%s" % [
					name, str(global_position), waypoint_index, waypoints.size(), str(target)
				])
				_route_blocked_reported = true
		else:
			_route_blocked_elapsed = 0.0
			_route_blocked_reported = false
	else:
		_route_blocked_elapsed = 0.0
		_route_blocked_reported = false
	is_walking = (
		desired_horizontal_velocity.length_squared() > 0.0001 and horizontal_displacement.length_squared() > 0.0001
	)
	if is_walking:
		_footstep_distance_m += Vector2(global_position.x - previous_position.x, global_position.z - previous_position.z).length()
		if _footstep_distance_m >= 0.78:
			_footstep_distance_m = fmod(_footstep_distance_m, 0.78)
			var audio_manager := get_tree().root.get_node_or_null("AudioManager")
			if audio_manager != null:
				audio_manager.call("play_footstep", self, desired_horizontal_velocity.length() > 1.8)
	if not grounding_enabled and waypoints.is_empty() and _yield_path.is_empty() \
			and _yield_cooldown_remaining <= 0.0:
		set_physics_process(false)

func _request_blocking_npcs_to_yield(desired_horizontal_velocity: Vector3) -> void:
	if _yield_request_cooldown_remaining > 0.0 or desired_horizontal_velocity.length_squared() <= 0.0001 \
			or waypoints.is_empty() or waypoint_index >= waypoints.size():
		return
	for collision_index in range(get_slide_collision_count()):
		var collision := get_slide_collision(collision_index)
		var blocker := collision.get_collider() as Node3D
		if blocker == null or blocker == self or not blocker.has_method("request_yield"):
			continue
		var away_direction := -collision.get_normal()
		away_direction.y = 0.0
		if away_direction.length_squared() <= 0.0001:
			away_direction = blocker.global_position - global_position
			away_direction.y = 0.0
		if away_direction.length_squared() <= 0.0001:
			continue
		var blocker_radius := float(blocker.call("get_collision_radius")) if blocker.has_method("get_collision_radius") else get_collision_radius()
		var clearance := get_collision_radius() + blocker_radius + 0.2
		if bool(blocker.call("request_yield", away_direction, desired_horizontal_velocity, global_position, clearance)):
			_yield_request_cooldown_remaining = YIELD_REQUEST_COOLDOWN_S
			print("OpenOB AI avoidance: %s asked %s to yield by %.2fm" % [name, blocker.name, clearance])
			return

func _rejoin_route_after_yield() -> void:
	if waypoints.is_empty() or waypoint_index >= waypoints.size():
		return
	var position := global_position
	var nearest_index := waypoint_index
	var nearest_distance := INF
	for index in range(waypoint_index, waypoints.size()):
		var waypoint: Vector3 = waypoints[index]
		var distance := position.distance_squared_to(waypoint)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_index = index
	waypoint_index = nearest_index

func _face_route_direction(movement_direction: Vector3, delta: float) -> void:
	var desired_yaw := atan2(-movement_direction.x, -movement_direction.z)
	rotation.y = lerp_angle(rotation.y, desired_yaw, 1.0 - exp(-8.0 * delta))

func _has_walkable_floor_ahead(horizontal_velocity: Vector3, delta: float) -> bool:
	var probe_position := global_position + Vector3(horizontal_velocity.x, 0.0, horizontal_velocity.z) * delta
	var query := PhysicsRayQueryParameters3D.create(
		probe_position + Vector3.UP * (max_route_step_height_m + 0.1),
		probe_position - Vector3.UP * (max_route_drop_m + 0.1),
		2,
		[get_rid()]
	)
	query.collide_with_areas = false
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return false
	var floor_position: Vector3 = result.get("position", probe_position)
	var floor_normal: Vector3 = result.get("normal", Vector3.UP)
	var floor_delta := floor_position.y - global_position.y
	return (
		floor_delta <= max_route_step_height_m
		and floor_delta >= -max_route_drop_m
		and floor_normal.dot(Vector3.UP) >= cos(deg_to_rad(max_walkable_slope_degrees))
	)

func _advance_waypoint() -> void:
	waypoint_index += 1
	if waypoint_index >= waypoints.size() and loops_route:
		waypoint_index = 0
	elif waypoint_index >= waypoints.size():
		route_finished.emit()
	_pause_remaining = waypoint_pause_seconds
	velocity.x = 0.0
	velocity.z = 0.0
	is_walking = false
