extends CharacterBody3D
## Lightweight waypoint locomotion for placed Oblivion actors.
## Horizontal movement collides with streamed cell geometry; height stays at
## the ESM route plane because some original cells have incomplete floor data.

@export var walk_speed_mps := 1.3
@export var arrival_distance := 0.08
@export var waypoint_pause_seconds := 1.2

var waypoints: Array[Vector3] = []
var waypoint_speeds: Array[float] = []
var waypoint_index := 0
var loops_route := false
var is_walking := false
var _pause_remaining := 0.0

func configure_route(route: Array[Dictionary], should_loop: bool, initial_pause: float) -> void:
	waypoints.clear()
	waypoint_speeds.clear()
	for waypoint: Dictionary in route:
		waypoints.push_back(waypoint.get("position", global_position))
		waypoint_speeds.push_back(float(waypoint.get("speed_mps", walk_speed_mps)))
	loops_route = should_loop
	_pause_remaining = initial_pause
	waypoint_index = 0
	velocity = Vector3.ZERO
	is_walking = false
	set_physics_process(not waypoints.is_empty())

func _physics_process(delta: float) -> void:
	if waypoints.is_empty():
		is_walking = false
		return
	if _pause_remaining > 0.0:
		_pause_remaining = maxf(0.0, _pause_remaining - delta)
		velocity = Vector3.ZERO
		is_walking = false
		return
	if waypoint_index >= waypoints.size():
		velocity = Vector3.ZERO
		is_walking = false
		set_physics_process(false)
		return

	var offset := waypoints[waypoint_index] - global_position
	offset.y = 0.0
	if offset.length() <= arrival_distance:
		_advance_waypoint()
		return

	var direction := offset.normalized()
	rotation.y = lerp_angle(rotation.y, atan2(-direction.x, -direction.z), 1.0 - exp(-8.0 * delta))
	var speed := waypoint_speeds[waypoint_index] if waypoint_index < waypoint_speeds.size() else walk_speed_mps
	velocity = direction * speed
	var previous_position := global_position
	move_and_slide()
	is_walking = global_position.distance_squared_to(previous_position) > 0.0001

func _advance_waypoint() -> void:
	waypoint_index += 1
	if waypoint_index >= waypoints.size() and loops_route:
		waypoint_index = 0
	_pause_remaining = waypoint_pause_seconds
	velocity = Vector3.ZERO
	is_walking = false
