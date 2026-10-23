extends Node
## Loads original Oblivion audio from the installed BSA archives and provides
## positional playback for locomotion, dialogue, equipment and world effects.

const FOOTSTEP_GROUPS := ["earth", "grass", "metal", "snow", "stone", "water", "wood"]
# Actual voice directories shipped in Oblivion's base voice archives. NPC race
# does not always match its voice type (for example, Valen Dreth uses High Elf).
const VOICE_GROUPS := ["argonian", "breton", "dark seducer", "dremora", "golden saint", "high elf", "imperial", "nord", "redguard", "sheogorath"]

@export_range(-24.0, 0.0, 0.5) var footstep_volume_db := -6.0
@export_range(-12.0, 6.0, 0.5) var voice_volume_db := 0.0
@export_range(-24.0, 0.0, 0.5) var effect_volume_db := -3.0

var _scene_root: Node
var _data_reader: Object
var _stream_cache: Dictionary = {}
var _reader_poll_remaining := 0.0
var _weapon_poll_remaining := 0.0
var _animation_poll_remaining := 0.0
var _weapon_state_initialized := false
var _last_weapon_form_id := 0
var _observed_animations: Dictionary = {}
var _npc_female_cache: Dictionary = {}
var _missing_voice_warnings: Dictionary = {}
var _last_world_loading := false
var _last_interaction_toast := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)


func _process(delta: float) -> void:
	var current_scene := get_tree().current_scene
	if current_scene != _scene_root:
		_scene_root = current_scene
		_data_reader = null
		_weapon_state_initialized = false
		_observed_animations.clear()
	_reader_poll_remaining -= delta
	if _reader_poll_remaining <= 0.0:
		_reader_poll_remaining = 0.25
		_resolve_data_reader()
	if not _reader_is_ready():
		return
	_weapon_poll_remaining -= delta
	if _weapon_poll_remaining <= 0.0:
		_weapon_poll_remaining = 0.12
		_watch_player_weapon()
	_animation_poll_remaining -= delta
	if _animation_poll_remaining <= 0.0:
		_animation_poll_remaining = 0.1
		_watch_combat_animations()
		_watch_world_feedback()


## Called by player and NPC locomotion controllers after each traveled step.
func play_footstep(actor: Node3D, running := false) -> void:
	if not is_instance_valid(actor) or not _reader_is_ready():
		return
	var group := _surface_group(actor)
	var variant := randi_range(1, 8)
	var asset_path := "sound\\fx\\fst\\%s\\fst_%s_%02d.wav" % [group, group, variant]
	var playback_volume := footstep_volume_db + (1.5 if running else 0.0)
	if not _play_asset_at(asset_path, actor.global_position + Vector3.UP * 0.08, null, playback_volume, 24.0, 1.6):
		var fallback := "sound\\fx\\fst\\stone\\fst_stone_%02d.wav" % variant
		_play_asset_at(fallback, actor.global_position + Vector3.UP * 0.08, null, playback_volume, 24.0, 1.6)


## Plays a combat effort sound. Animation transitions into attack/block/hit states
## are watched automatically; this method is also available to future combat code.
func play_combat_effort(actor: Node3D, female := false) -> void:
	if not is_instance_valid(actor) or not _reader_is_ready():
		return
	var sex := "female" if female else "male"
	var variant := randi_range(1, 4)
	var asset_path := "sound\\fx\\npc\\human\\gasp\\%s\\voc_gasp_%s_%02d.wav" % [sex, sex, variant]
	_play_asset_at(asset_path, actor.global_position + Vector3.UP * 1.1, actor, -2.0, 32.0, 2.0)


## Plays a quest reply using the speaker's race and sex voice folder.
func play_dialogue(
	reader: Object,
	scene_root: Node,
	speaker_form_id: int,
	quest: String,
	topic: String,
	reply_form_id: int
) -> void:
	if reader == null or not is_instance_valid(reader) or not reader.has_method("read_asset"):
		return
	var npc: Dictionary = reader.call("find_npc_base", speaker_form_id)
	var race_form_id := int(npc.get("race_form_id", 0))
	var race_editor_id := str(reader.call("find_editor_id", race_form_id)).to_lower()
	var voice_group := _voice_group(race_editor_id)
	var sex := "f" if bool(npc.get("female", false)) else "m"
	var file_name := "%s_%s_%08x_1.mp3" % [quest.to_lower(), topic.to_lower(), reply_form_id]
	var groups_to_try: Array[String] = [voice_group]
	for group: String in VOICE_GROUPS:
		if group != voice_group:
			groups_to_try.push_back(group)
	var selected_stream: AudioStream
	var selected_group := ""
	for group: String in groups_to_try:
		var asset_path := "sound\\voice\\oblivion.esm\\%s\\%s\\%s" % [group, sex, file_name]
		selected_stream = _stream_for_asset(asset_path, reader)
		if selected_stream != null:
			selected_group = group
			break
	if selected_stream == null:
		if not _missing_voice_warnings.has(file_name):
			_missing_voice_warnings[file_name] = true
			push_warning("OpenOB audio: no voice asset found for %s/%s/%08x" % [quest, topic, reply_form_id])
		return
	if selected_group != voice_group:
		print("OpenOB audio: %s voice resolved in '%s' folder (race folder '%s' has no clip)" % [file_name, selected_group, voice_group])
	var speaker := _speaker_node(scene_root, speaker_form_id)
	var player_node := scene_root.get_node_or_null("Player") as Node3D if scene_root != null else null
	var position := speaker.global_position if is_instance_valid(speaker) else player_node.global_position if is_instance_valid(player_node) else Vector3.ZERO
	_play_stream(selected_stream, position + Vector3.UP * 1.2, speaker, voice_volume_db, 55.0, 3.0)


## Door SetOpenState uses original NIF animation data; this adds the matching
## positional open/close sound at the placed reference.
func play_door_state(reference: Dictionary, is_open: bool, world: Node3D) -> void:
	var descriptor := ("%s %s %s" % [
		str(reference.get("reference_name", "")),
		str(reference.get("base_editor_id", "")),
		str(reference.get("model_path", "")),
	]).to_lower()
	var reader_value: Variant = world.get("data_reader")
	if reader_value != null and reader_value.has_method("find_item_model_path"):
		var model_path := str(reader_value.call("find_item_model_path", int(reference.get("base_form_id", 0)), false))
		descriptor += " " + model_path.to_lower()
	var sound_family := "wooden"
	if descriptor.contains("gate"):
		sound_family = "gate"
	elif descriptor.contains("stone") or descriptor.contains("ruin") or descriptor.contains("sewer"):
		sound_family = "stone"
	elif descriptor.contains("metal") or descriptor.contains("iron") or descriptor.contains("prison"):
		sound_family = "metal"
	var suffix := "open" if is_open else "close"
	var asset_path := "sound\\fx\\doors\\drs_%s%s.wav" % [sound_family, suffix]
	if sound_family == "wooden":
		asset_path = "sound\\fx\\doors\\drs_wooden%s_01.wav" % suffix
	elif sound_family == "gate":
		asset_path = "sound\\fx\\doors\\drs_rustygate%s.wav" % suffix
	elif sound_family == "stone":
		asset_path = "sound\\fx\\doors\\drs_stone%s.wav" % suffix
	elif sound_family == "metal":
		asset_path = "sound\\fx\\doors\\drs_metal%s_01.wav" % suffix
	var position := _reference_position(reference, world)
	_play_asset_at(asset_path, position, null, effect_volume_db, 42.0, 2.0)


## General positional effect entry point for spells, impacts and other world events.
func play_effect(asset_path: String, position: Vector3, volume_db := -3.0, max_distance := 36.0) -> void:
	_play_asset_at(asset_path, position, null, volume_db, max_distance, 2.0)


func _resolve_data_reader() -> void:
	if not is_instance_valid(_scene_root):
		return
	var reader_value: Variant = _scene_root.get("data_reader")
	if reader_value != null and reader_value is Object and reader_value.has_method("is_ready"):
		_data_reader = reader_value


func _reader_is_ready() -> bool:
	if not is_instance_valid(_data_reader):
		return false
	return bool(_data_reader.call("is_ready"))


func _stream_for_asset(asset_path: String, reader_override: Object = null) -> AudioStream:
	if _stream_cache.has(asset_path):
		return _stream_cache[asset_path] as AudioStream
	var reader := reader_override if reader_override != null else _data_reader
	if reader == null or not is_instance_valid(reader) or not reader.has_method("read_asset"):
		return null
	var bytes: PackedByteArray = reader.call("read_asset", asset_path)
	var stream: AudioStream
	match asset_path.get_extension().to_lower():
		"wav":
			stream = AudioStreamWAV.load_from_buffer(bytes) if not bytes.is_empty() else null
		"mp3":
			if not bytes.is_empty():
				var mp3 := AudioStreamMP3.new()
				mp3.data = bytes
				stream = mp3
	_stream_cache[asset_path] = stream
	return stream


func _play_asset_at(
	asset_path: String,
	position: Vector3,
	host: Node3D,
	volume_db: float,
	max_distance: float,
	unit_size: float
) -> bool:
	var stream := _stream_for_asset(asset_path)
	if stream == null:
		return false
	_play_stream(stream, position, host, volume_db, max_distance, unit_size)
	return true


func _play_stream(
	stream: AudioStream,
	position: Vector3,
	host: Node3D,
	volume_db: float,
	max_distance: float,
	unit_size: float
) -> void:
	var player := AudioStreamPlayer3D.new()
	player.name = "OriginalGameAudio"
	player.stream = stream
	player.volume_db = volume_db
	player.max_distance = max_distance
	player.unit_size = unit_size
	player.finished.connect(player.queue_free)
	if is_instance_valid(host) and host.is_inside_tree():
		host.add_child(player)
		player.position = Vector3.UP * maxf(0.08, position.y - host.global_position.y)
	else:
		var parent := get_tree().current_scene
		if parent == null:
			parent = self
		parent.add_child(player)
		player.global_position = position
	player.play()


func _surface_group(actor: Node3D) -> String:
	var group := "stone"
	if is_instance_valid(_scene_root):
		var cell_value: Variant = _scene_root.get("current_cell")
		if cell_value is Dictionary and not bool((cell_value as Dictionary).get("interior", true)):
			group = "earth"
	var query := PhysicsRayQueryParameters3D.create(
		actor.global_position + Vector3.UP * 0.24,
		actor.global_position - Vector3.UP * 0.12,
		2,
		[actor.get_rid()]
	)
	query.collide_with_areas = false
	var result := actor.get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty():
		return group
	var collider_value: Variant = result.get("collider")
	if not collider_value is Node:
		return group
	var collider := collider_value as Node
	if collider.has_meta("footstep_surface"):
		return _normalize_surface(str(collider.get_meta("footstep_surface")))
	var description := collider.name.to_lower()
	var reference_id := int(collider.get_meta("reference_id", 0))
	if reference_id != 0 and is_instance_valid(_scene_root):
		var cell: Variant = _scene_root.get("current_cell")
		if cell is Dictionary:
			for reference_value: Variant in (cell as Dictionary).get("references", []):
				var reference: Dictionary = reference_value
				if int(reference.get("form_id", 0)) == reference_id:
					description += " " + str(reference.get("base_editor_id", ""))
					description += " " + str(reference.get("model_path", ""))
					break
	return _surface_from_description(description, group)


func _surface_from_description(description: String, fallback: String) -> String:
	for group: String in ["snow", "water", "metal", "wood", "grass", "stone", "earth"]:
		if description.contains(group):
			return group
	if description.contains("dirt") or description.contains("soil"):
		return "earth"
	return fallback


func _normalize_surface(surface: String) -> String:
	var normalized := surface.to_lower()
	return normalized if FOOTSTEP_GROUPS.has(normalized) else "stone"


func _voice_group(race_editor_id: String) -> String:
	var compact := race_editor_id.replace(" ", "").replace("_", "")
	match compact:
		"altmer", "highelf": return "high elf"
		"dunmer", "darkelf": return "dark elf"
		"bosmer", "woodelf": return "wood elf"
		_: return race_editor_id if VOICE_GROUPS.has(race_editor_id) else "imperial"


func _speaker_node(scene_root: Node, speaker_form_id: int) -> Node3D:
	if scene_root == null:
		return null
	var actor_states: Variant = scene_root.get("_npc_actors")
	var player_node := scene_root.get_node_or_null("Player") as Node3D
	var selected: Node3D
	var selected_distance := INF
	if actor_states is Array:
		for actor_value: Variant in actor_states:
			var actor_state: Dictionary = actor_value
			if int(actor_state.get("base_form_id", 0)) != speaker_form_id:
				continue
			var actor := actor_state.get("root") as Node3D
			if not is_instance_valid(actor):
				continue
			var distance := actor.global_position.distance_squared_to(player_node.global_position) if is_instance_valid(player_node) else 0.0
			if distance < selected_distance:
				selected = actor
				selected_distance = distance
		return selected
	return null


func _reference_position(reference: Dictionary, world: Node3D) -> Vector3:
	var reference_id := int(reference.get("form_id", 0))
	var door_root := world.find_child("Door_%08X" % reference_id, true, false) as Node3D
	if is_instance_valid(door_root):
		return door_root.global_position
	for node: Node in world.find_children("*", "PhysicsBody3D", true, false):
		if int(node.get_meta("reference_id", 0)) == reference_id:
			return (node as Node3D).global_position
	return world.global_position


func _watch_player_weapon() -> void:
	if not is_instance_valid(_scene_root):
		return
	var current_form_id := int(_scene_root.get("_player_weapon_form_id"))
	if not _weapon_state_initialized:
		_last_weapon_form_id = current_form_id
		_weapon_state_initialized = true
		return
	if current_form_id == _last_weapon_form_id:
		return
	if _last_weapon_form_id != 0:
		_play_weapon_equip_sound(_last_weapon_form_id, false)
	if current_form_id != 0:
		_play_weapon_equip_sound(current_form_id, true)
	_last_weapon_form_id = current_form_id


func _play_weapon_equip_sound(form_id: int, equipping: bool) -> void:
	if not _reader_is_ready():
		return
	var descriptor := str(_data_reader.call("find_editor_id", form_id)).to_lower()
	descriptor += " " + str(_data_reader.call("find_item_model_path", form_id, false)).to_lower()
	var weapon_kind := "blade"
	if descriptor.contains("bow"):
		weapon_kind = "bow"
	elif descriptor.contains("staff"):
		weapon_kind = "staff"
	elif descriptor.contains("blunt") or descriptor.contains("mace") or descriptor.contains("hammer") or descriptor.contains("axe"):
		weapon_kind = "blunt"
	var direction := "up" if equipping else "down"
	var asset_path := "sound\\fx\\itm\\itm_weapon%s_%s.wav" % [weapon_kind, direction]
	var player_node := _scene_root.get_node_or_null("Player") as Node3D
	if is_instance_valid(player_node):
		_play_asset_at(asset_path, player_node.global_position + Vector3.UP, player_node, effect_volume_db, 28.0, 2.0)


func _watch_combat_animations() -> void:
	if not is_instance_valid(_scene_root):
		return
	var player_node := _scene_root.get_node_or_null("Player") as Node3D
	var player_animation := str(_scene_root.get("_active_animation"))
	var player_time := float(_scene_root.get("_animation_time"))
	_watch_animation("player", player_animation, player_time, player_node, false)
	var actor_states: Variant = _scene_root.get("_npc_actors")
	if not actor_states is Array:
		return
	for actor_value: Variant in actor_states:
		var actor_state: Dictionary = actor_value
		var actor := actor_state.get("root") as Node3D
		if not is_instance_valid(actor):
			continue
		var actor_id := str(actor_state.get("reference_id", actor.get_instance_id()))
		var animation := str(actor_state.get("active_animation", ""))
		var animation_time := float(actor_state.get("animation_time", 0.0))
		var base_form_id := int(actor_state.get("base_form_id", 0))
		_watch_animation("npc_" + actor_id, animation, animation_time, actor, _npc_is_female(base_form_id))


func _watch_world_feedback() -> void:
	if not is_instance_valid(_scene_root):
		return
	var world_loading := bool(_scene_root.get("_world_loading"))
	if world_loading and not _last_world_loading:
		var target_value: Variant = _scene_root.get("_aimed_target")
		if target_value is Dictionary:
			var target: Dictionary = target_value
			if str(target.get("kind", "")) == "door" and bool(target.get("linked", false)):
				var reference: Dictionary = target.get("reference", {})
				play_door_state(reference, true, _scene_root as Node3D)
	_last_world_loading = world_loading
	var toast := str(_scene_root.get("_interaction_toast_text"))
	if toast == "Locked" and _last_interaction_toast != "Locked":
		var player_node := _scene_root.get_node_or_null("Player") as Node3D
		if is_instance_valid(player_node):
			var position := player_node.global_position
			var target_value: Variant = _scene_root.get("_aimed_target")
			if target_value is Dictionary:
				var target: Dictionary = target_value
				if str(target.get("kind", "")) == "door":
					position = _reference_position(target.get("reference", {}), _scene_root as Node3D)
			play_effect("sound\\fx\\doors\\drs_locked.wav", position, effect_volume_db, 28.0)
	_last_interaction_toast = toast


func _npc_is_female(base_form_id: int) -> bool:
	if _npc_female_cache.has(base_form_id):
		return bool(_npc_female_cache[base_form_id])
	var npc: Dictionary = _data_reader.call("find_npc_base", base_form_id)
	var female := bool(npc.get("female", false))
	_npc_female_cache[base_form_id] = female
	return female


func _watch_animation(key: String, animation: String, animation_time: float, actor: Node3D, female: bool) -> void:
	var previous: Dictionary = _observed_animations.get(key, {})
	var started := animation != str(previous.get("name", "")) or animation_time + 0.02 < float(previous.get("time", 0.0))
	_observed_animations[key] = {"name": animation, "time": animation_time}
	if not started or not _is_combat_effort_animation(animation):
		return
	play_combat_effort(actor, female)


func _is_combat_effort_animation(animation: String) -> bool:
	var normalized := animation.to_lower()
	for word: String in ["attack", "block", "hit", "stagger", "combat"]:
		if normalized.contains(word):
			return true
	return false
