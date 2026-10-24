class_name CharacterStepper
extends RefCounted
## Step-up and step-down for CharacterBody3D actors. The player and placed NPCs
## share this, so both climb and descend stairs the same way.

const GRACE_FRAMES := 15

## Frames left in an active step. While it runs, the actor counts as grounded
## and gravity is held, so a capsule can roll over a tread's rounded nose.
var grace_frames := 0

func is_stepping() -> bool:
	return grace_frames > 0

## Call on frames that did not step, so an unfinished grace period runs out.
func tick() -> void:
	grace_frames = maxi(0, grace_frames - 1)

## Ends the grace period at once, e.g. when the actor jumps off a step.
func cancel() -> void:
	grace_frames = 0

func try_step_up(body: CharacterBody3D, horizontal_motion: Vector3, max_step_height: float, max_walkable_angle: float) -> bool:
	if horizontal_motion.length_squared() <= 0.0001:
		return false
	var margin := body.safe_margin
	var original_transform := body.global_transform
	var obstruction := KinematicCollision3D.new()
	if not body.test_move(original_transform, horizontal_motion, obstruction, margin):
		return false
	if obstruction.get_collider() is CharacterBody3D or obstruction.get_collider() is RigidBody3D:
		return false
	# A walkable first contact is normal ground, except mid-climb: when the capsule
	# sits on a tread's nose apex the contact reads as floor, yet the step must go on.
	if grace_frames == 0 and obstruction.get_normal().dot(Vector3.UP) >= cos(max_walkable_angle):
		return false
	# OpenMW ignores obstacles whose contact point is higher than the actor's
	# configured step. The CharacterBody origin is at the feet, so this is the
	# contact height relative to global_position.y.
	if obstruction.get_position().y - body.global_position.y > max_step_height + margin:
		return false

	# Find the clearance available above the actor. The step itself starts at the
	# obstacle's contact height; using all available headroom can push the actor
	# into a doorway lintel even when the sill is low enough to step over.
	var step_height := maxf(
		margin * 2.0,
		obstruction.get_position().y - body.global_position.y + margin
	)
	if step_height > max_step_height + margin:
		return false
	var upward_motion := Vector3.UP * max_step_height
	var ceiling := KinematicCollision3D.new()
	var max_clearance := max_step_height
	if body.test_move(original_transform, upward_motion, ceiling, margin):
		max_clearance = maxf(0.0, ceiling.get_travel().y - margin)
		if max_clearance < step_height:
			return false
	if step_height <= margin * 2.0:
		return false

	var horizontal_distance := horizontal_motion.length()
	var horizontal_direction := horizontal_motion / horizontal_distance
	var raised_transform := Transform3D.IDENTITY
	var horizontal_progress := Vector3.ZERO
	var found_clearance := false
	var candidate_height := step_height
	while candidate_height <= max_clearance + margin:
		raised_transform = original_transform.translated(Vector3.UP * candidate_height)
		var across_collision := KinematicCollision3D.new()
		if not body.test_move(raised_transform, horizontal_motion, across_collision, margin):
			horizontal_progress = horizontal_motion
			found_clearance = true
			break
		var available_distance := clampf(across_collision.get_travel().dot(horizontal_direction), 0.0, horizontal_distance)
		if available_distance > margin * 2.0:
			horizontal_progress = horizontal_direction * maxf(0.0, available_distance - margin)
			found_clearance = true
			break
		candidate_height += maxf(margin * 2.0, 0.01)
	if not found_clearance:
		return false

	var across_transform := raised_transform.translated(horizontal_progress)
	var downward_distance := candidate_height + body.floor_snap_length + horizontal_progress.length()
	var downward_motion := Vector3.DOWN * downward_distance
	# The downward trace may catch a tread's nose before its flat top, and a
	# capsule's rounded base makes that contact steep. The rise is judged by the
	# contact height instead, so the next frames can roll onto the flat tread.
	var landing := KinematicCollision3D.new()
	if not body.test_move(across_transform, downward_motion, landing, margin):
		return false
	if landing.get_collider() is CharacterBody3D or landing.get_collider() is RigidBody3D:
		return false
	if not _is_step_contact(landing.get_position(), landing.get_normal(), original_transform.origin, max_step_height, margin):
		return false

	body.global_transform = across_transform
	var actual_landing := body.move_and_collide(downward_motion, false, margin, true)
	if (
		actual_landing == null
		or actual_landing.get_collider() is CharacterBody3D
		or actual_landing.get_collider() is RigidBody3D
		or not _is_step_contact(actual_landing.get_position(), actual_landing.get_normal(), original_transform.origin, max_step_height, margin)
	):
		body.global_transform = original_transform
		return false

	# Refresh the body's floor state without advancing it again.
	var horizontal_velocity := Vector3(body.velocity.x, 0.0, body.velocity.z)
	body.velocity = Vector3.ZERO
	body.move_and_slide()
	body.velocity.x = horizontal_velocity.x
	body.velocity.z = horizontal_velocity.z
	grace_frames = GRACE_FRAMES
	return true

## Walking off a tread leaves the capsule on a steep rim for a few frames, so
## floor snapping misses the lower tread. A contact within one step below the
## feet is taken as the next tread, and the same grace period carries the descent.
func try_step_down(body: CharacterBody3D, max_step_height: float) -> void:
	var min_floor_dot := cos(body.floor_max_angle)
	var drop := KinematicCollision3D.new()
	var found := body.test_move(body.global_transform, Vector3.DOWN * (max_step_height + body.safe_margin), drop, body.safe_margin)
	if (
		not found
		or drop.get_collider() is CharacterBody3D
		or drop.get_collider() is RigidBody3D
		or drop.get_normal().dot(Vector3.UP) < min_floor_dot
	):
		# Nothing within one step below: a real drop, so gravity takes over.
		grace_frames = 0
		return
	body.move_and_collide(Vector3.DOWN * drop.get_travel().length(), false, body.safe_margin, true)
	body.velocity.y = 0.0
	grace_frames = GRACE_FRAMES

func _is_step_contact(contact_position: Vector3, contact_normal: Vector3, feet_position: Vector3, max_step_height: float, margin: float) -> bool:
	if contact_normal.dot(Vector3.UP) <= 0.0:
		return false
	return contact_position.y - feet_position.y <= max_step_height + margin
