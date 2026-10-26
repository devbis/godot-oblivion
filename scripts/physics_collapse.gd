extends RefCounted
## A scripted collapse: a NIF with Havok bodies and an animation sequence, such as the wall by the prison gate whose
## bricks slide apart when the guards push it. The bodies hold still (frozen, a solid wall) until a script plays the
## sequence on the reference (PlayGroup). From that moment the bodies are dynamic, and while the sequence runs each one
## moves sideways as its keys say, so the bricks are spread apart while gravity and the solver bring them down.

const AnimationSampling := preload("res://scripts/animation_sampling.gd")

## reference_id -> {bodies: node name -> RigidBody3D, sequences: Array, basis: Basis, position: Vector3, state: String,
## sequence: Dictionary, time: float}. State is "held", "playing" or "done".
var _rigs: Dictionary = {}

## `bodies` are the frozen rigid bodies by the name of their NIF node; `reference_transform` carries the game-unit scale.
func register(reference_id: int, bodies: Dictionary, sequences: Array, reference_transform: Transform3D) -> void:
	_rigs[reference_id] = {
		"bodies": bodies, "sequences": sequences, "basis": reference_transform.basis,
		"position": reference_transform.origin, "state": "held", "sequence": {}, "time": 0.0,
	}

func has_reference(reference_id: int) -> bool:
	return _rigs.has(reference_id)

## Starts the sequence called `group_name` on the reference. Returns its name, or "" when there is nothing to play.
func play(reference_id: int, group_name: String, host: Node) -> String:
	var rig: Dictionary = _rigs.get(reference_id, {})
	if rig.is_empty() or str(rig.state) != "held":
		return ""
	var sequence: Dictionary = {}
	for sequence_value: Variant in rig.sequences:
		if str((sequence_value as Dictionary).get("name", "")).to_lower() == group_name.to_lower():
			sequence = sequence_value
			break
	if sequence.is_empty():
		return ""
	rig["state"] = "playing"
	rig["sequence"] = sequence
	rig["time"] = float(sequence.get("start_time", 0.0))
	for body_value: Variant in (rig.bodies as Dictionary).values():
		var body := body_value as RigidBody3D
		if is_instance_valid(body):
			body.freeze = false
			body.sleeping = false
	for key_value: Variant in sequence.get("text_keys", []):
		_play_text_key(key_value as Dictionary, rig, host)
	return str(sequence.get("name", ""))

func physics_update(delta: float) -> void:
	for reference_id: Variant in _rigs.keys():
		var rig: Dictionary = _rigs[reference_id]
		if str(rig.state) != "playing":
			continue
		var sequence: Dictionary = rig.sequence
		var stop_time := float(sequence.get("stop_time", 0.0))
		var from_time := float(rig.time)
		var to_time := minf(from_time + delta, stop_time)
		if to_time > from_time:
			_drive_bodies(rig, sequence, from_time, to_time)
		rig["time"] = to_time
		if to_time >= stop_time:
			rig["state"] = "done"

## Sets the velocity the keys give each body between two times: the sideways motion is the animation's, the fall is
## the solver's.
func _drive_bodies(rig: Dictionary, sequence: Dictionary, from_time: float, to_time: float) -> void:
	var bodies: Dictionary = rig.bodies
	var basis: Basis = rig.basis
	for track_value: Variant in sequence.get("tracks", []):
		var track: Dictionary = track_value
		var body := bodies.get(str(track.get("node_name", ""))) as RigidBody3D
		var translations: PackedFloat32Array = track.get("translations", PackedFloat32Array())
		if not is_instance_valid(body) or translations.size() < 8:
			continue
		var step := AnimationSampling.vector(translations, 4, to_time) - AnimationSampling.vector(translations, 4, from_time)
		var velocity: Vector3 = basis * (step / (to_time - from_time))
		var keyed_height := not is_zero_approx(step.y)
		body.linear_velocity = Vector3(velocity.x, velocity.y if keyed_height else body.linear_velocity.y, velocity.z)

func _play_text_key(key: Dictionary, rig: Dictionary, host: Node) -> void:
	var text := str(key.get("name", ""))
	if not text.to_lower().begins_with("sound:"):
		return
	var sound_name := text.substr(6).strip_edges()
	# The ambient sounds of the master are "AMB<Name>", filed as fx\ambient\amb_<name>.wav.
	if not sound_name.to_upper().begins_with("AMB"):
		return
	var audio_manager := host.get_tree().root.get_node_or_null("AudioManager")
	if audio_manager != null:
		audio_manager.call(
			"play_effect", "sound\\fx\\ambient\\amb_%s.wav" % sound_name.substr(3).to_lower(), rig.position, 0.0, 60.0
		)
