class_name QuestStageBridge
extends RefCounted
## Applies the actions a quest stage requests to the loaded cell. Targets outside
## the cell are reported and not applied; commands without an implementation are
## reported as well. Only the cell's references and their nodes are touched.

## Stats and flags set by stage scripts, keyed by reference name ("" for global).
var actor_state: Dictionary = {}
var dead_actors: Dictionary = {}


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
		if command == "setstage" or command == "startquest":
			# Stage changes and quest starts are applied by the quest world itself; this line only records them.
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
		"speech":
			# A SayTo line: the topic's reply, printed as the subtitle would show it.
			return "says: %s" % (str(arguments[0]) if not arguments.is_empty() else "")
	return "not implemented: %s" % label


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
	if command == "kill":
		dead_actors[target] = true
	return "applied: %s" % label


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
