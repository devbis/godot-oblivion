extends RefCounted
## The body of a dead actor as a rag doll: a rigid capsule for the trunk, head, arms and legs, joined by cone-twist
## joints (hinges at the knees and elbows). The actor's skeleton is posed from these bodies every frame instead of
## from an animation, so the corpse falls limp, can be pushed, kicked and dragged, and piles up on stairs.

const ROOT_NAME := "ActorRagdoll"
## Movable bodies are on layer 16 (see physics_object_grabber.gd); a rag doll collides with the world and the player,
## not with its own limbs.
const BODY_LAYER := 16
const BODY_MASK := 3
const LIMB_FRICTION := 0.8
const LINEAR_DAMP := 0.3
const ANGULAR_DAMP := 6.0
## The skinned meshes stretch far from the actor's origin: their culling bounds grow by this much (game units).
const CULL_MARGIN := 400.0
const HEAD_LENGTH_M := 0.2
const MIN_CAPSULE_EXTRA_M := 0.02
const MAX_FLEX := 1.5
const MAX_LAUNCH_SPEED_MPS := 6.0
## A walker that passes through a limb moves it along: an acceleration (m/s^2) per m/s of walking speed.
const NUDGE_ACCELERATION_PER_MPS := 3.0
const NUDGE_MIN_SPEED_MPS := 0.3
const NUDGE_REACH_M := 2.5
## A rag doll is at rest below these speeds; the get-up clip then lines up with it.
const SETTLED_LINEAR_MPS := 0.25
const SETTLED_ANGULAR_RPS := 1.0
const ALIGN_MIN_FIT := 0.001
## Bones that line the get-up clip up with the bodies, with their weights.
const ALIGN_BONES := [
	["Bip01 Head", 3.0], ["Bip01 Spine1", 3.0], ["Bip01 L Thigh", 1.0], ["Bip01 R Thigh", 1.0],
	["Bip01 L UpperArm", 1.0], ["Bip01 R UpperArm", 1.0], ["Bip01 L Calf", 1.0], ["Bip01 R Calf", 1.0],
	["Bip01 L Forearm", 0.5], ["Bip01 R Forearm", 0.5],
]
const FLOOR_MASK := 2

## One rigid segment per entry: it runs from `bone` to `end` (empty: it carries on away from its parent), hangs on
## `parent` through a cone-twist joint at `bone`'s origin (or a hinge that bends towards `flex`: +1 the way the actor
## faces, -1 the way it does not). Masses add up to about 70 kg. The limits are narrow and the damping high: a corpse
## is stiff.
const SEGMENTS: Array[Dictionary] = [
	{"bone": "Bip01 Pelvis", "end": "Bip01 Spine1", "radius": 0.14, "mass": 14.0},
	{"bone": "Bip01 Spine1", "end": "Bip01 Neck", "radius": 0.17, "mass": 16.0, "parent": "Bip01 Pelvis", "swing": 0.30, "twist": 0.21},
	{"bone": "Bip01 Head", "end": "", "radius": 0.11, "mass": 5.0, "parent": "Bip01 Spine1", "swing": 0.48, "twist": 0.42},
	{"bone": "Bip01 L UpperArm", "end": "Bip01 L Forearm", "radius": 0.055, "mass": 2.5, "parent": "Bip01 Spine1", "swing": 0.90, "twist": 0.54},
	{"bone": "Bip01 L Forearm", "end": "Bip01 L Hand", "radius": 0.05, "mass": 1.5, "parent": "Bip01 L UpperArm", "flex": 1.0},
	{"bone": "Bip01 R UpperArm", "end": "Bip01 R Forearm", "radius": 0.055, "mass": 2.5, "parent": "Bip01 Spine1", "swing": 0.90, "twist": 0.54},
	{"bone": "Bip01 R Forearm", "end": "Bip01 R Hand", "radius": 0.05, "mass": 1.5, "parent": "Bip01 R UpperArm", "flex": 1.0},
	{"bone": "Bip01 L Thigh", "end": "Bip01 L Calf", "radius": 0.09, "mass": 8.0, "parent": "Bip01 Pelvis", "swing": 0.66, "twist": 0.21},
	{"bone": "Bip01 L Calf", "end": "Bip01 L Foot", "radius": 0.07, "mass": 4.0, "parent": "Bip01 L Thigh", "flex": -1.0},
	{"bone": "Bip01 R Thigh", "end": "Bip01 R Calf", "radius": 0.09, "mass": 8.0, "parent": "Bip01 Pelvis", "swing": 0.66, "twist": 0.21},
	{"bone": "Bip01 R Calf", "end": "Bip01 R Foot", "radius": 0.07, "mass": 4.0, "parent": "Bip01 R Thigh", "flex": -1.0},
]

## Turns the actor's body into a rag doll that keeps the actor's velocity. The walker (the player) passes through it: a
## limb is no step to climb and a corpse is too light to shove aside, so it would only hold the player up. Returns false
## when the skeleton lacks the bones.
static func start(actor: Dictionary, walker: PhysicsBody3D = null) -> bool:
	if actor.has("ragdoll"):
		return true
	var actor_root := actor.get("root") as Node3D
	var skeleton := actor.get("skeleton") as Skeleton3D
	if not is_instance_valid(actor_root) or not is_instance_valid(skeleton) or not actor_root.is_inside_tree():
		print("OpenOB ragdoll: %s has no actor in the tree" % str(actor.get("reference_name", "NPC")))
		return false
	if skeleton.find_bone(SEGMENTS[0].bone) < 0:
		print("OpenOB ragdoll: %s has no %s bone" % [str(actor.get("reference_name", "NPC")), SEGMENTS[0].bone])
		return false
	var rag_root := Node3D.new()
	rag_root.name = ROOT_NAME
	# Bodies live in world space; the root of the actor stays where the actor fell.
	rag_root.top_level = true
	actor_root.add_child(rag_root)
	rag_root.global_transform = Transform3D.IDENTITY
	var launch := Vector3.ZERO
	if actor_root is CharacterBody3D:
		launch = (actor_root as CharacterBody3D).velocity
	var hit_velocity: Variant = actor_root.get("_hit_velocity")
	if hit_velocity is Vector3:
		launch += hit_velocity
	# Only the shove carries over: the fall of a root that had no floor under it (a disabled actor) would shoot the body
	# through the floor.
	launch.y = 0.0
	launch = launch.limit_length(MAX_LAUNCH_SPEED_MPS)
	# A body posed from its saved ragdoll (a corpse placed dead) is already at rest: it does not move until disturbed.
	var settled := bool(actor.get("ragdoll_settled", false))
	if settled:
		launch = Vector3.ZERO
	# The root stays where the actor fell. Left to collide, it would be shoved aside by whoever walks into it and carry
	# the avatar along rigidly, apart from the bodies.
	var saved_layer := 0
	var saved_mask := 0
	if actor_root is CollisionObject3D:
		saved_layer = (actor_root as CollisionObject3D).collision_layer
		saved_mask = (actor_root as CollisionObject3D).collision_mask
		(actor_root as CollisionObject3D).collision_layer = 0
		(actor_root as CollisionObject3D).collision_mask = 0
	if actor_root is CharacterBody3D:
		(actor_root as CharacterBody3D).velocity = Vector3.ZERO
	actor_root.set_physics_process(false)
	actor_root.set("ragdoll_driven", true)
	var reference_id := int(actor.get("reference_id", 0))
	var to_world := skeleton.global_transform
	var bodies: Dictionary = {}
	var driven_bones: Array[Dictionary] = []
	for segment: Dictionary in SEGMENTS:
		var bone_index := skeleton.find_bone(str(segment.bone))
		if bone_index < 0:
			continue
		var parent_name := str(segment.get("parent", ""))
		if not parent_name.is_empty() and not bodies.has(parent_name):
			continue
		var bone_world := to_world * skeleton.get_bone_global_pose(bone_index)
		var origin := bone_world.origin
		var direction := _segment_direction(skeleton, to_world, segment, origin, bodies)
		var length := _segment_length(skeleton, to_world, segment, origin)
		var body := RigidBody3D.new()
		body.name = "Rag_" + str(segment.bone).replace(" ", "_")
		body.mass = float(segment.mass)
		body.collision_layer = BODY_LAYER
		body.collision_mask = BODY_MASK
		body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
		body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
		body.linear_damp = LINEAR_DAMP
		body.angular_damp = ANGULAR_DAMP
		var material := PhysicsMaterial.new()
		material.friction = LIMB_FRICTION
		body.physics_material_override = material
		body.set_meta("grab_enabled", true)
		body.set_meta("reference_id", reference_id)
		body.set_meta("resolve_spawn_penetration", false)
		var body_basis := bone_world.basis.orthonormalized()
		body.transform = Transform3D(body_basis, origin)
		var radius := float(segment.radius)
		var capsule := CapsuleShape3D.new()
		capsule.radius = radius
		capsule.height = maxf(length + radius * 2.0, radius * 2.0 + MIN_CAPSULE_EXTRA_M)
		var shape := CollisionShape3D.new()
		var local_direction := body_basis.inverse() * direction
		shape.transform = Transform3D(
			Basis(Quaternion(Vector3.UP, local_direction)), local_direction * length * 0.5
		)
		shape.shape = capsule
		body.add_child(shape)
		body.linear_velocity = launch
		# Thin limbs would tunnel through a floor at speed.
		body.continuous_cd = true
		if is_instance_valid(walker):
			walker.add_collision_exception_with(body)
		rag_root.add_child(body)
		if settled:
			body.sleeping = true
		bodies[str(segment.bone)] = {"body": body, "direction": direction}
		driven_bones.push_back({"index": bone_index, "body": body})
	for segment: Dictionary in SEGMENTS:
		var parent_name := str(segment.get("parent", ""))
		if not bodies.has(str(segment.bone)) or parent_name.is_empty():
			continue
		var body: RigidBody3D = (bodies[str(segment.bone)] as Dictionary).body
		var parent_entry: Dictionary = bodies[parent_name]
		var parent_body: RigidBody3D = parent_entry.body
		if segment.has("flex"):
			_add_hinge(rag_root, skeleton, segment, body, parent_body, parent_entry.direction)
		else:
			_add_cone_twist(rag_root, segment, body, parent_body, parent_entry.direction)
	# Parents first: a bone's pose is set relative to its parent's current one.
	driven_bones.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.index) < int(b.index))
	for node: Node in skeleton.get_parent().find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).extra_cull_margin = CULL_MARGIN
	print("OpenOB ragdoll: %s goes limp (%d bodies)" % [str(actor.get("reference_name", "NPC")), driven_bones.size()])
	var bodies_by_bone: Dictionary = {}
	for bone_name: Variant in bodies.keys():
		bodies_by_bone[bone_name] = (bodies[bone_name] as Dictionary).body
	actor["ragdoll"] = {
		"skeleton": skeleton, "bones": driven_bones, "root": rag_root, "applied": false, "bodies": bodies_by_bone,
		"root_layer": saved_layer, "root_mask": saved_mask,
	}
	return true

## True when every body has come to rest (or sleeps).
static func is_settled(rig: Dictionary) -> bool:
	for bone_value: Variant in rig.get("bones", []):
		var body := (bone_value as Dictionary).get("body") as RigidBody3D
		if is_instance_valid(body) and not body.sleeping \
				and (body.linear_velocity.length() > SETTLED_LINEAR_MPS or body.angular_velocity.length() > SETTLED_ANGULAR_RPS):
			return false
	return true

## True when the chest of the body faces up (it lies on its back). The way the chest faces is the way the actor faces in
## the rest pose, carried to the pose the chest has now.
static func is_face_up(rig: Dictionary) -> bool:
	var skeleton := rig.get("skeleton") as Skeleton3D
	var bodies: Dictionary = rig.get("bodies", {})
	var chest := bodies.get("Bip01 Spine1", bodies.get("Bip01 Pelvis")) as RigidBody3D
	if not is_instance_valid(skeleton) or not is_instance_valid(chest):
		return true
	var bone_index := skeleton.find_bone("Bip01 Spine1" if bodies.has("Bip01 Spine1") else "Bip01 Pelvis")
	var rest_basis := skeleton.get_bone_global_rest(bone_index).basis.orthonormalized()
	var front := chest.global_basis.orthonormalized() * (rest_basis.inverse() * _rest_forward(skeleton))
	return front.y >= 0.0

## Ends the rag doll of a knocked-down actor so that it can get up with `animation` (the first frame of the get-up clip):
## the actor is turned and moved so that the clip's lying pose lies where the body lies, the skeleton keeps the pose of
## the bodies (the clip blends from it), and the actor walks again.
static func hand_back(actor: Dictionary, host: Object, animation: Dictionary) -> void:
	var rig: Dictionary = actor.get("ragdoll", {})
	var skeleton := rig.get("skeleton") as Skeleton3D
	var actor_root := actor.get("root") as Node3D
	var bodies: Dictionary = rig.get("bodies", {})
	var pelvis := bodies.get("Bip01 Pelvis") as RigidBody3D
	if is_instance_valid(skeleton) and is_instance_valid(actor_root) and is_instance_valid(pelvis) and not animation.is_empty():
		host.call("_apply_animation_pose", skeleton, animation, float(animation.get("start_time", 0.0)), false)
		var pelvis_index := skeleton.find_bone("Bip01 Pelvis")
		var clip_pelvis := skeleton.get_bone_global_pose(pelvis_index).origin
		var in_root := (actor_root.global_transform.affine_inverse() * skeleton.global_transform).basis
		# The yaw that lays the clip's pose over the bodies in the floor plane: the best fit of the main bones (the head
		# and trunk count most). The direction of the head alone is not enough, as a body that lies propped up or curled has
		# its head almost above the pelvis.
		var dot_sum := 0.0
		var cross_sum := 0.0
		for fit: Array in ALIGN_BONES:
			var fit_body := bodies.get(fit[0]) as RigidBody3D
			var fit_index := skeleton.find_bone(str(fit[0]))
			if not is_instance_valid(fit_body) or fit_index < 0:
				continue
			var clip_offset: Vector3 = in_root * (skeleton.get_bone_global_pose(fit_index).origin - clip_pelvis)
			var body_offset := fit_body.global_position - pelvis.global_position
			var weight := float(fit[1])
			dot_sum += weight * (clip_offset.x * body_offset.x + clip_offset.z * body_offset.z)
			cross_sum += weight * (clip_offset.x * body_offset.z - clip_offset.z * body_offset.x)
		if Vector2(dot_sum, cross_sum).length() > ALIGN_MIN_FIT:
			# Turning the actor by yaw turns floor-plane vectors by -yaw (see Basis(Vector3.UP, yaw)).
			var yaw := -atan2(cross_sum, dot_sum)
			actor_root.global_rotation = Vector3(0.0, yaw, 0.0)
			actor["animation_heading"] = yaw
		var clip_pelvis_world := skeleton.to_global(clip_pelvis)
		var shift := pelvis.global_position - clip_pelvis_world
		actor_root.global_position += Vector3(shift.x, 0.0, shift.z)
		var query := PhysicsRayQueryParameters3D.create(
			pelvis.global_position + Vector3.UP * 0.3, pelvis.global_position + Vector3.DOWN * 2.0, FLOOR_MASK
		)
		var hit := actor_root.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty():
			actor_root.global_position.y = (hit.position as Vector3).y
	# The skeleton shows the bodies again, now from the turned and moved actor.
	rig["applied"] = false
	update(rig)
	if is_instance_valid(actor_root):
		if actor_root is CollisionObject3D:
			(actor_root as CollisionObject3D).collision_layer = int(rig.get("root_layer", 0))
			(actor_root as CollisionObject3D).collision_mask = int(rig.get("root_mask", 0))
		if actor_root is CharacterBody3D:
			(actor_root as CharacterBody3D).velocity = Vector3.ZERO
		actor_root.set("ragdoll_driven", false)
		actor_root.set_physics_process(true)
	var rag_root := rig.get("root") as Node
	if is_instance_valid(rag_root):
		rag_root.queue_free()
	actor.erase("ragdoll")

## Puts each driven bone where its body is. A rag doll that lies still keeps the pose it has.
static func update(rig: Dictionary) -> void:
	var skeleton := rig.get("skeleton") as Skeleton3D
	if not is_instance_valid(skeleton):
		return
	# The skeleton rides on the actor, which a script may move: the pose is set again then, not only when a body moves.
	var skeleton_transform := skeleton.global_transform
	var moving: bool = not bool(rig.get("applied", false)) or skeleton_transform != rig.get("skeleton_transform")
	var bones: Array = rig.get("bones", [])
	if not moving:
		for bone_value: Variant in bones:
			var body := (bone_value as Dictionary).get("body") as RigidBody3D
			if is_instance_valid(body) and not body.sleeping:
				moving = true
				break
	if not moving:
		return
	rig["applied"] = true
	rig["skeleton_transform"] = skeleton_transform
	var to_skeleton := skeleton.global_transform.affine_inverse()
	for bone_value: Variant in bones:
		var bone: Dictionary = bone_value
		var body := bone.get("body") as RigidBody3D
		if not is_instance_valid(body):
			continue
		var pose := to_skeleton * body.global_transform
		# The skeleton carries the game-unit scale; the pose must not.
		pose.basis = pose.basis.orthonormalized()
		skeleton.set_bone_global_pose(int(bone.index), pose)

## The walker (the player) passes through the bodies, but pushes the ones it passes through: a gentle shove along its
## walk, away from its axis, so a corpse stirs rather than blocks. Call it every physics frame.
static func nudge(rig: Dictionary, walker: CharacterBody3D, walker_radius: float, walker_height: float) -> void:
	var horizontal := Vector3(walker.velocity.x, 0.0, walker.velocity.z)
	var speed := horizontal.length()
	if speed < NUDGE_MIN_SPEED_MPS:
		return
	var bones: Array = rig.get("bones", [])
	if bones.is_empty():
		return
	var first := (bones[0] as Dictionary).get("body") as RigidBody3D
	if not is_instance_valid(first) or first.global_position.distance_to(walker.global_position) > NUDGE_REACH_M:
		return
	var feet := walker.global_position
	var axis_from := feet + Vector3.UP * walker_radius
	var axis_to := feet + Vector3.UP * maxf(walker_height - walker_radius, walker_radius)
	var walk_direction := horizontal / speed
	for bone_value: Variant in bones:
		var body := (bone_value as Dictionary).get("body") as RigidBody3D
		if not is_instance_valid(body) or body.get_child_count() == 0:
			continue
		var shape := body.get_child(0) as CollisionShape3D
		var capsule := shape.shape as CapsuleShape3D
		if capsule == null:
			continue
		var half := maxf(capsule.height * 0.5 - capsule.radius, 0.0)
		var limb_axis := body.global_basis * shape.transform.basis * Vector3.UP
		var limb_center := body.global_transform * shape.transform.origin
		var closest := Geometry3D.get_closest_points_between_segments(
			axis_from, axis_to, limb_center - limb_axis * half, limb_center + limb_axis * half
		)
		var offset: Vector3 = closest[1] - closest[0]
		offset.y = 0.0
		if offset.length() > walker_radius + capsule.radius:
			continue
		var away := offset.normalized() if offset.length() > 0.001 else walk_direction
		var direction := (walk_direction + away * 0.5).normalized()
		body.apply_force(direction * body.mass * NUDGE_ACCELERATION_PER_MPS * speed, closest[1] - body.global_position)

static func _segment_end_world(skeleton: Skeleton3D, to_world: Transform3D, segment: Dictionary) -> Variant:
	var end_index := skeleton.find_bone(str(segment.end)) if not str(segment.end).is_empty() else -1
	if end_index < 0:
		return null
	return (to_world * skeleton.get_bone_global_pose(end_index)).origin

static func _segment_direction(
	skeleton: Skeleton3D, to_world: Transform3D, segment: Dictionary, origin: Vector3, bodies: Dictionary
) -> Vector3:
	var end: Variant = _segment_end_world(skeleton, to_world, segment)
	if end is Vector3 and (end as Vector3).distance_to(origin) > 0.001:
		return ((end as Vector3) - origin).normalized()
	# No end bone (the head): carry on away from the parent.
	var parent_name := str(segment.get("parent", ""))
	if bodies.has(parent_name):
		var parent_body: RigidBody3D = (bodies[parent_name] as Dictionary).body
		var away := origin - parent_body.global_position
		if away.length() > 0.001:
			return away.normalized()
	return Vector3.UP

static func _segment_length(skeleton: Skeleton3D, to_world: Transform3D, segment: Dictionary, origin: Vector3) -> float:
	var end: Variant = _segment_end_world(skeleton, to_world, segment)
	if end is Vector3 and (end as Vector3).distance_to(origin) > 0.001:
		return (end as Vector3).distance_to(origin)
	return HEAD_LENGTH_M

static func _add_cone_twist(
	rag_root: Node3D, segment: Dictionary, body: RigidBody3D, parent_body: RigidBody3D, parent_direction: Vector3
) -> void:
	var twist_axis := parent_direction
	var reference := Vector3.RIGHT if absf(twist_axis.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var y_axis := (reference - twist_axis * reference.dot(twist_axis)).normalized()
	var z_axis := twist_axis.cross(y_axis).normalized()
	# Godot's ConeTwistJoint3D uses its local X axis for twist.
	var joint := ConeTwistJoint3D.new()
	joint.name = "RagJoint_" + str(segment.bone).replace(" ", "_")
	joint.node_a = NodePath("../" + parent_body.name)
	joint.node_b = NodePath("../" + body.name)
	joint.exclude_nodes_from_collision = true
	joint.set_param(ConeTwistJoint3D.PARAM_SWING_SPAN, float(segment.swing))
	joint.set_param(ConeTwistJoint3D.PARAM_TWIST_SPAN, float(segment.twist))
	joint.transform = Transform3D(Basis(twist_axis, y_axis, z_axis), body.global_position)
	rag_root.add_child(joint)

## A knee or an elbow: it bends one way only, from straight to MAX_FLEX. The axis comes from the rest pose, where the
## actor stands upright and faces forward, carried to the pose the bones have now.
static func _add_hinge(
	rag_root: Node3D, skeleton: Skeleton3D, segment: Dictionary, body: RigidBody3D, parent_body: RigidBody3D,
	parent_direction: Vector3
) -> void:
	var bone_index := skeleton.find_bone(str(segment.bone))
	var rest := skeleton.get_bone_global_rest(bone_index)
	var rest_basis := rest.basis.orthonormalized()
	var forward_rest := _rest_forward(skeleton)
	var end_index := skeleton.find_bone(str(segment.end))
	var segment_rest := Vector3.DOWN
	if end_index >= 0:
		segment_rest = (skeleton.get_bone_global_rest(end_index).origin - rest.origin).normalized()
	var axis_rest := segment_rest.cross(forward_rest)
	if axis_rest.length() < 0.001:
		axis_rest = Vector3.RIGHT
	axis_rest = axis_rest.normalized()
	# Turning by a positive angle about the axis must carry the segment towards the bending side.
	if axis_rest.cross(segment_rest).dot(forward_rest * float(segment.flex)) < 0.0:
		axis_rest = -axis_rest
	var current_basis := body.global_basis.orthonormalized()
	var axis := (current_basis * (rest_basis.inverse() * axis_rest)).normalized()
	var reference := Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	reference = (reference - axis * reference.dot(axis)).normalized()
	# The hinge angle is zero in the pose at hand: allow as much as is left of the bend from there.
	var current_bend := parent_direction.angle_to(_body_direction(body))
	var joint := HingeJoint3D.new()
	joint.name = "RagJoint_" + str(segment.bone).replace(" ", "_")
	joint.node_a = NodePath("../" + parent_body.name)
	joint.node_b = NodePath("../" + body.name)
	joint.exclude_nodes_from_collision = true
	joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
	joint.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, -current_bend)
	joint.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, maxf(MAX_FLEX - current_bend, 0.1))
	# Godot's HingeJoint3D turns about its local Z axis.
	joint.transform = Transform3D(Basis(reference, axis.cross(reference), axis), body.global_position)
	rag_root.add_child(joint)

## The way a body's capsule points in the world.
static func _body_direction(body: RigidBody3D) -> Vector3:
	var shape := body.get_child(0) as CollisionShape3D
	return (body.global_basis * shape.transform.basis * Vector3.UP).normalized()

## The way the actor faces in the rest pose, in skeleton space: from the foot to the toes.
static func _rest_forward(skeleton: Skeleton3D) -> Vector3:
	var foot_index := skeleton.find_bone("Bip01 L Foot")
	var toe_index := skeleton.find_bone("Bip01 L Toe0")
	if foot_index >= 0 and toe_index >= 0:
		var toe_offset := skeleton.get_bone_global_rest(toe_index).origin - skeleton.get_bone_global_rest(foot_index).origin
		toe_offset.y = 0.0
		if toe_offset.length() > 0.001:
			return toe_offset.normalized()
	return Vector3(0.0, 0.0, -1.0)
