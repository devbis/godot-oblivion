class_name QuestStageBridge
extends RefCounted
## Applies the actions a quest stage requests to the loaded cell. Targets outside
## the cell are reported and not applied; commands without an implementation are
## reported as well. Only the cell's references and their nodes are touched.

## Stats and flags set by stage scripts, keyed by reference name ("" for global).
var actor_state: Dictionary = {}
## Names of actors a script killed or disabled. They stay so for the session: the scene does not build them again when
## their cell is loaded again.
var dead_actors: Dictionary = {}
var disabled_actors: Dictionary = {}


## Reference ids of the removed actors; the name is not unique (guards share a base editor id).
var removed_reference_ids: Dictionary = {}


func is_actor_removed(reference_id: int) -> bool:
	return removed_reference_ids.has(reference_id)


## Forgets door and actor state of the previous cell. Doors are rebuilt closed when a cell loads, so their open marks go.
func reset_cell_state(world: Node) -> void:
	for meta_name: StringName in world.get_meta_list():
		if str(meta_name).begins_with("door_open_"):
			world.remove_meta(meta_name)


## `runs` is the array from OblivionData.run_quest_stage. `transform_of` maps a
## reference dictionary to its Godot transform in the loaded cell.
func apply(runs: Array, cell: Dictionary, world: Node3D, transform_of: Callable) -> PackedStringArray:
	var report := PackedStringArray()
	for run_value: Variant in runs:
		var run: Dictionary = run_value
		if not bool(run.get("conditions_hold", false)):
			continue
		report.push_back("entry" + (" (completes)" if bool(run.get("completes", false)) else ""))
		for error_text: String in run.get("parse_errors", PackedStringArray()):
			report.push_back("  parse error " + error_text)
		report.append_array(apply_actions(run.get("actions", []), cell, world, transform_of))
	return report


## Applies a list of actions, such as the ones a quest driver tick returns.
func apply_actions(actions: Array, cell: Dictionary, world: Node3D, transform_of: Callable) -> PackedStringArray:
	var report := PackedStringArray()
	var references := _references_by_name(cell)
	for action_value: Variant in actions:
		var action: Dictionary = action_value
		var command := str(action.get("command", "")).to_lower()
		if command in ["setstage", "startquest", "say", "sayto"]:
			# The quest world executes these commands and emits a `speech` action for Say/SayTo.
			# The scene consumes that speech action below; replaying the original command here is wrong.
			if command in ["setstage", "startquest"]:
				report.push_back("  %s handled by the quest world" % command)
			continue
		report.push_back("  " + _apply_action(action, references, world, transform_of))
	return report


func _apply_action(action: Dictionary, references: Dictionary, world: Node3D, transform_of: Callable) -> String:
	var command := str(action.get("command", "")).to_lower()
	var target := str(action.get("target", ""))
	var arguments: Array = action.get("arguments", [])
	var label := ("%s.%s" % [target, command]) if not target.is_empty() else command
	match command:
		"setav", "setfactionreaction", "setessential":
			_store(target, command, arguments)
			return "applied state: %s" % label
		"moveto":
			return _move_to(target, arguments, references, world, transform_of, label)
		"kill", "disable":
			return _deactivate(target, command, world, label)
		"setopenstate":
			return _set_open_state(target, arguments, references, world, label)
		"speech":
			# A resolved Say/SayTo reply, with the speaker's installed voice, face animation and subtitle.
			var line := str(arguments[0]) if not arguments.is_empty() else ""
			var who := str(arguments[1]) if arguments.size() > 1 else ""
			_play_dialogue_audio(action, arguments, who, world)
			return "says (%s): %s" % [who, line]
		"look":
			return _look_at(target, arguments, world, label)
		"pickidle":
			return _pick_idle(target, arguments, world)
		"evp":
			# The NPC re-evaluates its packages; the scene refreshes the routes after the result (see main.gd).
			return "re-evaluates packages: %s" % label
	return "not implemented: %s" % label


## PickIdle: the idle manager chose a clip for the actor (arguments: .kf path, IDLE editor id, form id, group flags).
## An empty path means nothing matched and the actor goes back to its default idle. The scene plays it.
func _pick_idle(target: String, arguments: Array, world: Node3D) -> String:
	if target.is_empty() or arguments.size() < 4:
		return "not applied: pickidle needs an actor"
	if not world.has_method("play_npc_idle"):
		return "not applied: %s.pickidle, the scene cannot play idles" % target
	var kf_path := str(arguments[0])
	var idle_id := str(arguments[1])
	var done := str(world.call("play_npc_idle", target, kf_path, idle_id, int(arguments[3])))
	return "picks idle: %s" % done


func _play_dialogue_audio(action: Dictionary, arguments: Array, speaker_editor_id: String, world: Node3D) -> void:
	if arguments.is_empty():
		return
	var line := str(arguments[0])
	var reader_value: Variant = world.get("data_reader")
	var speaker_form_id := 0
	if reader_value != null and reader_value.has_method("find_form_id_by_editor_id") and not speaker_editor_id.is_empty():
		speaker_form_id = int(reader_value.call("find_form_id_by_editor_id", speaker_editor_id))
	var audio_manager := world.get_tree().root.get_node_or_null("AudioManager")
	var duration := 0.0
	if audio_manager != null and reader_value != null and speaker_form_id > 0 and arguments.size() >= 4:
		duration = float(audio_manager.call(
			"play_dialogue",
			reader_value,
			world,
			speaker_form_id,
			str(arguments[3]),
			str(action.get("target", "")),
			int(arguments[2]),
			_dialogue_face_expression(int(arguments[4])) if arguments.size() > 4 else "",
			clampf(float(arguments[5]) / 100.0, 0.0, 1.0) if arguments.size() > 5 else 0.0,
			int(arguments[6]) if arguments.size() > 6 else 1
		))
	# Say and SayTo are scripted speech commands. They show the line but never open a dialogue session.
	var player_directed := arguments.size() < 8 or int(arguments[7]) != 0
	if player_directed and world.has_method("present_scripted_speech_line"):
		var speaker_reference := str(arguments[8]) if arguments.size() > 8 else ""
		world.call("present_scripted_speech_line", speaker_form_id, speaker_editor_id, line, duration, speaker_reference)


func _dialogue_face_expression(emotion_type: int) -> String:
	match emotion_type:
		1: return "Anger"
		3: return "Fear"
		4: return "Sad"
		5: return "Happy"
		6: return "Surprise"
		_: return ""


func _look_at(target: String, arguments: Array, world: Node3D, label: String) -> String:
	if target.is_empty() or arguments.is_empty():
		return "not applied: %s needs an actor and a look target" % label
	if not world.has_method("set_npc_look_target"):
		return "not applied: %s, the scene cannot direct actor gaze" % label
	var result := str(world.call("set_npc_look_target", target, str(arguments[0])))
	if result.is_empty():
		return "not applied: %s, actor or look target is not loaded" % label
	return "%s looks at %s" % [target, str(arguments[0])]


func _move_to(target: String, arguments: Array, references: Dictionary, world: Node3D, transform_of: Callable, label: String) -> String:
	if target.is_empty() or arguments.is_empty():
		return "not applied: %s needs a target and a destination" % label
	var destination := str(arguments[0])
	if not references.has(destination):
		return "not applied: %s, destination %s is not in this cell" % [label, destination]
	var actor := _actor_node(target, world)
	if actor == null:
		return "not applied: %s, %s is not in this cell" % [label, target]
	var destination_transform: Transform3D = transform_of.call(references[destination])
	actor.global_position = destination_transform.origin
	return "applied: %s to %s" % [label, destination]


func _deactivate(target: String, command: String, world: Node3D, label: String) -> String:
	if target.is_empty():
		return "not applied: %s needs a target" % label
	var actor := _actor_node(target, world)
	if actor == null:
		return "not applied: %s, %s is not in this cell" % [label, target]
	actor.visible = false
	if actor is CollisionObject3D:
		actor.collision_layer = 0
		actor.collision_mask = 0
	actor.set_physics_process(false)
	# A route controller keeps physics off when a later route is configured for it.
	if "inactive" in actor:
		actor.set("inactive", true)
	removed_reference_ids[int(actor.get_meta("reference_id", 0))] = true
	if command == "kill":
		dead_actors[target] = true
	else:
		disabled_actors[target] = true
	return "applied: %s" % label


## Opens the referenced door for NPC route traversal. This is also used by
## SetOpenState actions from the game's scripts.
func set_door_open_state(reference: Dictionary, is_open: bool, world: Node3D) -> String:
	var target := str(reference.get("reference_name", ""))
	if target.is_empty():
		target = "0x%08X" % int(reference.get("form_id", 0))
	return _apply_door_open_state(reference, is_open, world, "%s.setopenstate" % target)


func _set_open_state(target: String, arguments: Array, references: Dictionary, world: Node3D, label: String) -> String:
	if target.is_empty() or arguments.is_empty():
		return "not applied: %s needs a target and a state" % label
	var reference: Dictionary = references.get(target, {})
	if reference.is_empty():
		return "not applied: %s, %s is not in this cell" % [label, target]
	return _apply_door_open_state(reference, int(arguments[0]) != 0, world, label)


func _apply_door_open_state(reference: Dictionary, is_open: bool, world: Node3D, label: String) -> String:
	var reference_id := int(reference.get("form_id", 0))
	var state_key := "door_open_%08x" % reference_id
	if world.has_meta(state_key) and bool(world.get_meta(state_key)) == is_open:
		return "applied: %s (%s)" % [label, "open" if is_open else "closed"]
	var animation_player := _door_animation_player(reference_id, world)
	var sequence_name := _door_animation_name(animation_player, "Open" if is_open else "Close")
	var body_count := _door_body_count(reference_id, world)
	if animation_player != null and not sequence_name.is_empty():
		world.set_meta(state_key, is_open)
		animation_player.animation_finished.connect(
			_finish_door_animation.bind(reference_id, is_open, world), CONNECT_ONE_SHOT
		)
		animation_player.play(sequence_name)
		_play_door_audio(reference, is_open, world)
		return "applied: %s (%s, NIF %s animation)" % [label, "open" if is_open else "closed", sequence_name]
	if body_count == 0:
		return "not applied: %s has no door collision or original NIF animation in this cell" % label
	world.set_meta(state_key, is_open)
	_set_door_collision(reference_id, is_open, world)
	_play_door_audio(reference, is_open, world)
	return "applied: %s (%s)" % [label, "open" if is_open else "closed"]


func _play_door_audio(reference: Dictionary, is_open: bool, world: Node3D) -> void:
	var audio_manager := world.get_tree().root.get_node_or_null("AudioManager")
	if audio_manager != null:
		audio_manager.call("play_door_state", reference, is_open, world)


func _door_animation_player(reference_id: int, world: Node3D) -> AnimationPlayer:
	for node: Node in world.find_children("*", "AnimationPlayer", true, false):
		var animation_player := node as AnimationPlayer
		if animation_player != null and int(animation_player.get_meta("reference_id", 0)) == reference_id:
			return animation_player
	return null


func _door_animation_name(animation_player: AnimationPlayer, requested_name: String) -> String:
	if animation_player == null:
		return ""
	for animation_name: StringName in animation_player.get_animation_list():
		if str(animation_name).to_lower() == requested_name.to_lower():
			return str(animation_name)
	return ""


func _door_body_count(reference_id: int, world: Node3D) -> int:
	var count := 0
	for node: Node in world.find_children("*", "PhysicsBody3D", true, false):
		if int(node.get_meta("reference_id", 0)) == reference_id:
			count += 1
	return count


func _finish_door_animation(_animation_name: StringName, reference_id: int, is_open: bool, world: Node3D) -> void:
	if not is_instance_valid(world):
		return
	var state_key := "door_open_%08x" % reference_id
	if not world.has_meta(state_key) or bool(world.get_meta(state_key)) != is_open:
		return
	_set_door_collision(reference_id, is_open, world)


func _set_door_collision(reference_id: int, is_open: bool, world: Node3D) -> void:
	for node: Node in world.find_children("*", "PhysicsBody3D", true, false):
		var body := node as PhysicsBody3D
		if body == null or int(body.get_meta("reference_id", 0)) != reference_id:
			continue
		if is_open:
			if not body.has_meta("closed_layer"):
				body.set_meta("closed_layer", body.collision_layer)
				body.set_meta("closed_mask", body.collision_mask)
			body.collision_layer = 0
			body.collision_mask = 0
		elif body.has_meta("closed_layer"):
			body.collision_layer = int(body.get_meta("closed_layer"))
			body.collision_mask = int(body.get_meta("closed_mask"))


func _store(target: String, command: String, arguments: Array) -> void:
	var entry: Dictionary = actor_state.get(target, {})
	var values: Array = []
	for argument: Variant in arguments:
		values.push_back(argument)
	entry[command] = values
	actor_state[target] = entry


func _actor_node(name: String, world: Node3D) -> Node3D:
	var node := world.get_node_or_null(NodePath(name))
	return node as Node3D


func _references_by_name(cell: Dictionary) -> Dictionary:
	var result := {}
	for reference_value: Variant in cell.get("references", []):
		var reference: Dictionary = reference_value
		var name := str(reference.get("reference_name", ""))
		if not name.is_empty() and not result.has(name):
			result[name] = reference
	return result
