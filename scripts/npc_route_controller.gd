extends CharacterBody3D
## Lightweight waypoint locomotion for placed Oblivion actors.
## NPCs use generated floor geometry when it is available and retain the ESM
## route plane in cells where no walkable floor collider can be found.

@export var walk_speed_mps := 1.3
@export var gravity_mps2 := 9.8
@export var arrival_distance := 0.08
## Pause at each waypoint. The ESM does not give one, so the default is none.
@export var waypoint_pause_seconds := 0.0
@export var max_route_step_height_m := 0.40
@export var max_route_drop_m := 0.55
@export_range(35.0, 75.0, 1.0) var max_walkable_slope_degrees := 55.0

## Emitted once when the route reaches its last waypoint and does not loop.
signal route_finished

var waypoints: Array[Vector3] = []
var waypoint_speeds: Array[float] = []
var waypoint_index := 0
var final_arrival_distance := 0.08
var loops_route := false
var is_walking := false
var grounding_enabled := false
## Whether the walk checks the floor ahead for a drop. A route of several points comes from the navigation tiles, which
## already keep to walkable floor, so the check is only kept for a single straight target.
var check_floor_ahead := true
## A killed or disabled actor: its route is never run again and physics stays off.
var inactive := false
var _pause_remaining := 0.0
var _last_grounded_position := Vector3.ZERO
var _has_last_grounded_position := false
var _yield_path := PackedVector3Array()
var _yield_waypoint_index := 0
var _stepper := CharacterStepper.new()

func _ready() -> void:
	floor_max_angle = deg_to_rad(max_walkable_slope_degrees)
	wall_min_slide_angle = 0.0

func configure_route(route: Array[Dictionary], should_loop: bool, initial_pause: float, final_arrival_distance_m: float = -1.0) -> void:
	_yield_path.clear()
	_yield_waypoint_index = 0
	waypoints.clear()
	waypoint_speeds.clear()
	for waypoint: Dictionary in route:
		waypoints.push_back(waypoint.get("position", global_position))
		waypoint_speeds.push_back(float(waypoint.get("speed_mps", walk_speed_mps)))
	loops_route = should_loop
	final_arrival_distance = maxf(arrival_distance, final_arrival_distance_m) if final_arrival_distance_m >= 0.0 else arrival_distance
	check_floor_ahead = waypoints.size() <= 1
	_pause_remaining = initial_pause
	waypoint_index = 0
	velocity = Vector3.ZERO
	is_walking = false
	if grounding_enabled:
		_last_grounded_position = global_position
		_has_last_grounded_position = true
	set_physics_process(not inactive and (grounding_enabled or not waypoints.is_empty()))

## A routed actor can ask a stationary NPC to clear a collision in a narrow passage.
## The yielding actor takes a short navmesh route away from the approaching actor.
func request_yield(away_direction: Vector3, distance_m: float) -> bool:
	if inactive:
		return false
	if not _yield_path.is_empty() or (not waypoints.is_empty() and waypoint_index < waypoints.size()):
		return false
	away_direction.y = 0.0
	if away_direction.length_squared() <= 0.0001:
		return false
	var target := global_position + away_direction.normalized() * distance_m
	var navigation_map := get_world_3d().navigation_map
	var target_on_mesh := NavigationServer3D.map_get_closest_point(navigation_map, target)
	if Vector2(target_on_mesh.x - target.x, target_on_mesh.z - target.z).length() > 0.35:
		return false
	var path := NavigationServer3D.map_get_path(navigation_map, global_position, target_on_mesh, true)
	if path.size() < 2:
		return false
	var path_end := path[path.size() - 1]
	if Vector2(path_end.x - target_on_mesh.x, path_end.z - target_on_mesh.z).length() > 0.35:
		return false
	if Vector2(path_end.x - global_position.x, path_end.z - global_position.z).length() < 0.25:
		return false
	_yield_path = path
	_yield_waypoint_index = 0
	set_physics_process(true)
	return true

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

func _physics_process(delta: float) -> void:
	if inactive:
		set_physics_process(false)
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
		else:
			var direction := offset.normalized()
			rotation.y = lerp_angle(rotation.y, atan2(-direction.x, -direction.z), 1.0 - exp(-8.0 * delta))
			desired_horizontal_velocity = direction * minf(walk_speed_mps, 0.8)
	elif not waypoints.is_empty() and waypoint_index < waypoints.size():
		var offset := waypoints[waypoint_index] - global_position
		offset.y = 0.0
		var waypoint_arrival_distance := arrival_distance
		if not loops_route and waypoint_index == waypoints.size() - 1:
			waypoint_arrival_distance = final_arrival_distance
		if offset.length() <= waypoint_arrival_distance:
			_advance_waypoint()
		else:
			var direction := offset.normalized()
			rotation.y = lerp_angle(rotation.y, atan2(-direction.x, -direction.z), 1.0 - exp(-8.0 * delta))
			var speed := waypoint_speeds[waypoint_index] if waypoint_index < waypoint_speeds.size() else walk_speed_mps
			desired_horizontal_velocity = direction * speed

	if grounding_enabled:
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
	velocity.x = desired_horizontal_velocity.x
	velocity.z = desired_horizontal_velocity.z
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
	is_walking = (
		desired_horizontal_velocity.length_squared() > 0.0001
		and Vector2(global_position.x - previous_position.x, global_position.z - previous_position.z).length_squared() > 0.0001
	)

func _request_blocking_npcs_to_yield(desired_horizontal_velocity: Vector3) -> void:
	if desired_horizontal_velocity.length_squared() <= 0.0001 or waypoints.is_empty() or waypoint_index >= waypoints.size():
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
		if bool(blocker.call("request_yield", away_direction, clearance)):
			print("OpenOB AI avoidance: %s asked %s to yield by %.2fm" % [name, blocker.name, clearance])
			return

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
