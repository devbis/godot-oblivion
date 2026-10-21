extends Node3D

const START_CELL_ID := "ImperialDungeon01"
const START_MARKER_EDITOR_ID := "CGPlayerStartMarker"
const START_MARKER_FORM_ID := 0x00032AB5
const DerivedResourceCache := preload("res://scripts/derived_resource_cache.gd")
const FaceGenData := preload("res://scripts/facegen_data.gd")
const NpcRouteController := preload("res://scripts/npc_route_controller.gd")
const PLAYER_SKELETON := "Characters/_male/skeleton.nif"
const PLAYER_IDLE_KF := "Characters/_male/idleanims/dynamicidle_facegen.kf"
const PLAYER_IDLE_SEQUENCE := "DynamicIdle_Facegen"
const PLAYER_DIRECTIONAL_KFS := {
	"Forward": ["Characters/_male/walkforward.kf", "Forward"],
	"Backward": ["Characters/_male/walkbackward.kf", "Backward"],
	"Left": ["Characters/_male/walkleft.kf", "Left"],
	"Right": ["Characters/_male/walkright.kf", "Right"],
	"FastForward": ["Characters/_male/walkfastforward.kf", "FastForward"],
	"FastBackward": ["Characters/_male/walkfastbackward.kf", "FastBackward"],
	"FastLeft": ["Characters/_male/walkfastleft.kf", "FastLeft"],
	"FastRight": ["Characters/_male/walkfastright.kf", "FastRight"],
}
const PLAYER_JUMP_KFS := {
	"JumpStart": ["Characters/_male/jumpstart.kf", "JumpStart"],
	"JumpLoop": ["Characters/_male/jumploop.kf", "JumpLoop"],
	"JumpLand": ["Characters/_male/jumpland.kf", "JumpLand"],
}
const PLAYER_FAST_FORWARD_KF := "Characters/_male/walkfastforward.kf"
const PLAYER_FACE_HEAD_MODEL := "Characters/Imperial/headhuman.nif"
const PLAYER_STARTING_CLOTHING := ["LowerShirt05", "LowerPants05"]
const FACE_EXPRESSION_CYCLE := ["", "Happy", "Anger", "Surprise", "Sad", "Fear"]
const PLAYER_AVATAR_PARTS := [
	"Characters/_male/upperbody.nif",
	"Characters/_male/lowerbody.nif",
	"Characters/_male/hand.nif",
	"Characters/_male/foot.nif",
	"Characters/Imperial/headhuman.nif",
	"Characters/Imperial/male/hair01.nif",
]
const FEMALE_AVATAR_PARTS := [
	"Characters/_male/femaleupperbody.nif",
	"Characters/_male/femalelowerbody.nif",
	"Characters/_male/femalehand.nif",
	"Characters/_male/femalefoot.nif",
	"Characters/Imperial/headhuman.nif",
	"Characters/Imperial/female/hair01.nif",
]
const TEXTURE_FALLBACKS := {
	"textures/characters/imperial/male/earmale.dds": "textures/characters/imperial/earshuman.dds",
	"textures/characters/imperial/female/ear.dds": "textures/characters/imperial/earshuman.dds",
	"textures/characters/hairf01.dds": "textures/characters/hair/short.dds",
	"textures/characters/hairbrownm01.dds": "textures/characters/hair/short.dds",
}

@export_range(0.001, 1.0, 0.001) var game_units_to_meters := 0.01

@onready var status_label: Label = $StatusLayer/StatusPanel/Margin/Status
@onready var inventory_label: Label = $StatusLayer/Inventory
@onready var interaction_hint_label: Label = $StatusLayer/InteractionHint
@onready var face_profile_label: Label = $StatusLayer/FaceProfile
@onready var player: CharacterBody3D = $Player

var data_reader: Object
var current_cell: Dictionary = {}
var cell_visual_root: Node3D
var _model_cache: Dictionary = {}
var _nif_metadata_cache: Dictionary = {}
var _collision_cache: Dictionary = {}
var _material_cache: Dictionary = {}
var _texture_cache: Dictionary = {}
var _transition_index := 0
var _cell_load_generation := 0
var _cell_material: StandardMaterial3D
var _world_loading := true
var _interact_ready := true
var _player_skeleton: Skeleton3D
var _player_avatar: Node3D
var _player_face_meshes: Array[MeshInstance3D] = []
var _player_face_source_meshes: Array[ArrayMesh] = []
var _player_face_profiles: Array[Dictionary] = []
var _player_face_profile_ids: Dictionary = {}
var _player_face_profile_index := 0
var _player_face_state: Dictionary = {}
var _player_animations: Dictionary = {}
var _player_inventory: Dictionary = {}
var _player_equipment: Dictionary = {}
var _player_weapon_meshes: Array[MeshInstance3D] = []
var _placed_items: Dictionary = {}
var _pickup_toast_text := ""
var _pickup_toast_remaining := 0.0
var _facegen_cache: Dictionary = {}
var _facegen_expression_names: Array[String] = []
var _active_animation := ""
var _animation_time := 0.0
var _player_was_on_floor := true
var _npc_actors: Array[Dictionary] = []
var _player_start_position := Vector3.ZERO
var _fallback_support: StaticBody3D

func _ready() -> void:
	player.set_physics_process(false)
	cell_visual_root = Node3D.new()
	cell_visual_root.name = "StreamedCell"
	add_child(cell_visual_root)
	_cell_material = StandardMaterial3D.new()
	_cell_material.albedo_color = Color(0.62, 0.58, 0.5)
	_cell_material.roughness = 0.9
	_cell_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	status_label.text = "OpenOB data reader starting…"
	_load_game_data()

func _process(_delta: float) -> void:
	_pickup_toast_remaining = maxf(0.0, _pickup_toast_remaining - _delta)
	var nearby_item: Dictionary = {}
	if not _world_loading:
		nearby_item = _nearest_placed_item()
		_update_interaction_hint(nearby_item)
	if Input.is_action_just_released("interact"):
		_interact_ready = true
	if not _world_loading and _interact_ready and Input.is_action_just_pressed("interact"):
		_interact_ready = false
		if nearby_item.is_empty():
			_transition_to_next_linked_cell()
		else:
			await _pick_up_placed_item(nearby_item)
			if not Input.is_action_pressed("interact"):
				_interact_ready = true
	if _player_skeleton != null and not _world_loading:
		_update_player_animation(_delta)
		_update_npc_actors(_delta)
		if not _player_face_state.is_empty():
			_update_face_blink(_player_face_state, _delta)
			_update_face_expression(_player_face_state, _delta)

func _input(event: InputEvent) -> void:
	if is_instance_valid(player):
		player.handle_camera_input(event)

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode == KEY_F:
		_cycle_nearest_npc_face_expression()
	elif event.keycode == KEY_C:
		_cycle_player_face_profile()
	elif event.keycode == KEY_G:
		_cycle_player_face_expression()

func _load_game_data() -> void:
	if not ClassDB.class_exists("OblivionData"):
		status_label.text = "Native reader is not built. Build native/ with the bundled godot-cpp and nifly sources."
		return

	var data_path := _game_data_path()
	if data_path.is_empty():
		status_label.text = "Set OBLIVION_DATA_DIR or pass --game-data <Oblivion Data directory>."
		return

	data_reader = ClassDB.instantiate("OblivionData")
	data_reader.open_game_async(data_path)
	status_label.text = "Reading Oblivion.esm and BSA indexes…"
	while data_reader.is_loading():
		await get_tree().process_frame
	if not data_reader.is_ready():
		status_label.text = "Data load failed: %s" % data_reader.get_error()
		return

	current_cell = data_reader.find_cell(START_CELL_ID)
	if current_cell.is_empty():
		status_label.text = "Loaded game data, but %s was not found." % START_CELL_ID
		return

	var summary: Dictionary = data_reader.get_summary()
	status_label.text = "Imperial Prison index ready (%d references, %d cells, %d archives). Loading NIF meshes…" % [
		current_cell.references.size(), summary.cell_count, summary.archive_count
	]
	print("OpenOB indexed %s: %d references, %d cells, %d archives" % [
		START_CELL_ID, current_cell.references.size(), summary.cell_count, summary.archive_count
	])
	await _load_cell_geometry(current_cell)
	_place_player_at_start(current_cell)
	await _place_player_on_ground(_player_start_position)
	await _load_player_avatar()
	await _load_cell_actors(current_cell)
	player.set_physics_process(true)
	_world_loading = false
	player.capture_mouse()
	await get_tree().create_timer(1.0).timeout
	_log_runtime_spawn_positions()

func _place_fallback_support(feet_position: Vector3) -> void:
	if not is_instance_valid(_fallback_support):
		_fallback_support = StaticBody3D.new()
		_fallback_support.name = "TemporaryStartCellSupport"
		_fallback_support.collision_layer = 2
		_fallback_support.collision_mask = 0
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(6.0, 0.2, 6.0)
		collision.shape = shape
		_fallback_support.add_child(collision)
		add_child(_fallback_support)
	_fallback_support.global_position = feet_position - Vector3.UP * 0.075
	player.global_position = feet_position
	player.velocity = Vector3.ZERO

func _place_player_on_ground(feet_position: Vector3) -> void:
	if is_instance_valid(_fallback_support):
		_fallback_support.queue_free()
		_fallback_support = null
		await get_tree().physics_frame
	player.global_position = feet_position
	player.velocity = Vector3.ZERO
	await get_tree().physics_frame
	var query := PhysicsRayQueryParameters3D.create(
		feet_position + Vector3.UP * 1.5,
		feet_position - Vector3.UP * 3.0,
		2,
		[player.get_rid()]
	)
	query.collide_with_areas = false
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	var hit_position: Vector3 = result.get("position", feet_position)
	var hit_normal: Vector3 = result.get("normal", Vector3.UP)
	if not result.is_empty() and hit_normal.dot(Vector3.UP) >= 0.55:
		player.global_position = Vector3(feet_position.x, hit_position.y + 0.02, feet_position.z)
		player.velocity = Vector3.ZERO
		_player_was_on_floor = true
		print("OpenOB grounded player at cell floor: marker_y=%.3f floor_y=%.3f offset=%.3fm" % [
			feet_position.y, hit_position.y, hit_position.y - feet_position.y
		])
		return
	_place_fallback_support(feet_position)
	_player_was_on_floor = true
	push_warning("No walkable cell floor was found below the player start; using temporary support at the start marker")

func _log_runtime_spawn_positions() -> void:
	if _player_skeleton != null:
		var foot_positions: Array[String] = []
		for bone_name in ["Bip01 L Foot", "Bip01 L Toe0", "Bip01 R Foot", "Bip01 R Toe0"]:
			var bone_index := _player_skeleton.find_bone(bone_name)
			if bone_index >= 0:
				var bone_position := _player_skeleton.global_transform * _player_skeleton.get_bone_global_pose(bone_index).origin
				foot_positions.push_back("%s=%.3f" % [bone_name, bone_position.y])
		print("OpenOB player floor alignment: root_y=%.3f feet=[%s] on_floor=%s" % [
			player.global_position.y,
			", ".join(foot_positions),
			str(player.is_on_floor()),
		])
	if _npc_actors.is_empty():
		print("OpenOB spawn check after physics: player=%s; no NPC actors" % str(player.global_position))
		return
	var first_actor: Dictionary = _npc_actors[0]
	var first_root := first_actor.get("root") as Node3D
	var nearest_actor := ""
	var nearest_distance := INF
	for actor: Dictionary in _npc_actors:
		var actor_root := actor.get("root") as Node3D
		if not is_instance_valid(actor_root):
			continue
		var distance := player.global_position.distance_to(actor_root.global_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_actor = str(actor.get("name", "NPC"))
	print("OpenOB spawn check after physics: player=%s; first NPC %s=%s; nearest NPC %s at %.2fm" % [
		str(player.global_position),
		str(first_actor.get("name", "NPC")),
		str(first_root.global_position if is_instance_valid(first_root) else Vector3.INF),
		nearest_actor,
		nearest_distance
	])

func _game_data_path() -> String:
	var environment_path := OS.get_environment("OBLIVION_DATA_DIR").strip_edges()
	if not environment_path.is_empty():
		return environment_path
	var args := OS.get_cmdline_user_args()
	for index in range(args.size() - 1):
		if args[index] == "--game-data":
			return args[index + 1]
	var config := ConfigFile.new()
	if config.load("user://openob.cfg") == OK:
		return str(config.get_value("game", "data_directory", ""))
	return ""

func _load_cell_geometry(cell: Dictionary) -> void:
	_cell_load_generation += 1
	var generation := _cell_load_generation
	_placed_items.clear()
	if has_node("TestFloor/MeshInstance3D"):
		$TestFloor/MeshInstance3D.visible = true
	for child in cell_visual_root.get_children():
		child.queue_free()
	await get_tree().process_frame

	var instance_count := 0
	var reference_count := 0
	var collision_count := 0
	for reference: Dictionary in cell.references:
		if generation != _cell_load_generation:
			return
		var model_path := str(reference.get("model_path", ""))
		if model_path.is_empty() or not model_path.to_lower().ends_with(".nif"):
			continue
		var base_form_id := int(reference.get("base_form_id", 0))
		var base_type := str(data_reader.find_record_type(base_form_id))
		var is_pickup_item := base_type in ["ARMO", "CLOT", "WEAP", "ALCH", "AMMO", "APPA", "BOOK", "INGR", "KEYM", "MISC", "SLGM", "SGST"]
		reference_count += 1
		var meshes: Array = await _meshes_for_model(model_path)
		var item_mesh_instances: Array[MeshInstance3D] = []
		for mesh_entry: Dictionary in meshes:
			var instance := MeshInstance3D.new()
			var mesh_name := str(mesh_entry.get("mesh_name", "Mesh"))
			instance.name = model_path.get_file().get_basename() + "_" + mesh_name.replace(":", "_")
			instance.mesh = mesh_entry.mesh
			instance.material_override = await _material_for_reference(
				model_path,
				str(mesh_entry.diffuse_texture_path),
				bool(mesh_entry.get("alpha_blend", false)),
				bool(mesh_entry.get("alpha_test", false)),
				int(mesh_entry.get("alpha_threshold", 128))
			)
			instance.transform = _reference_transform(reference)
			cell_visual_root.add_child(instance)
			if is_pickup_item:
				item_mesh_instances.push_back(instance)
			instance_count += 1
		if is_pickup_item and not item_mesh_instances.is_empty():
			var reference_id := int(reference.get("form_id", 0))
			_placed_items[reference_id] = {
				"reference_id": reference_id,
				"base_form_id": base_form_id,
				"record_type": base_type,
				"editor_id": str(data_reader.find_editor_id(base_form_id)),
				"position": _reference_transform(reference).origin,
				"mesh_instances": item_mesh_instances,
			}
		if not is_pickup_item and _should_collide_model(model_path):
			var model_key := model_path.to_lower().replace("\\", "/")
			var collision_shape := _collision_cache.get(model_key) as ConcavePolygonShape3D
			if collision_shape != null:
				var static_body := StaticBody3D.new()
				static_body.name = "GeneratedStaticMeshCollision"
				static_body.collision_layer = 2
				static_body.collision_mask = 0
				static_body.transform = _reference_transform(reference)
				var collision_instance := CollisionShape3D.new()
				collision_instance.shape = collision_shape
				static_body.add_child(collision_instance)
				cell_visual_root.add_child(static_body)
				collision_count += 1
		if reference_count % 8 == 0:
			status_label.text = "Loading %s: %d placed NIF references, %d visible meshes…" % [
				cell.get("editor_id", "cell"), reference_count, instance_count
			]

	if generation != _cell_load_generation:
		return
	if instance_count > 0 and has_node("TestFloor/MeshInstance3D"):
		$TestFloor/MeshInstance3D.visible = false
		$TestFloor/CollisionShape3D.disabled = collision_count > 0
	status_label.text = "Cell: %s — %s (%d references, %d meshes, %d generated colliders).\nWASD move · Shift run · Space jump · E pick up item / follow door\nMouse turns player · wheel zoom · V camera mode · C face profile · G player expression · F NPC expression · Esc release mouse\nOriginal textures, rig, and movement KF load from the game files; Havok collision and game scale remain unverified." % [
		cell.get("editor_id", "(unnamed)"), cell.get("display_name", ""), cell.references.size(), instance_count, collision_count
	]
	_update_interaction_hint({})
	_refresh_inventory_hud()
	print("OpenOB displayed %s: %d placed NIF references, %d meshes" % [
		cell.get("editor_id", "(unnamed)"), reference_count, instance_count
	])
	print("OpenOB indexed %d nearby-pickup candidates in %s" % [_placed_items.size(), str(cell.get("editor_id", "cell"))])

func _meshes_for_model(model_path: String) -> Array:
	var key := model_path.to_lower().replace("\\", "/")
	if _model_cache.has(key):
		return _model_cache[key]
	if data_reader == null or not data_reader.request_nif_meshes(model_path):
		return []
	while data_reader.is_asset_loading():
		await get_tree().process_frame
	var parse_error := str(data_reader.get_asset_error())
	if not parse_error.is_empty():
		push_warning("Could not parse NIF %s: %s" % [model_path, parse_error])
		_model_cache[key] = []
		return []

	var result: Dictionary = data_reader.take_nif_meshes()
	_nif_metadata_cache[key] = {
		"nodes": result.get("nodes", []),
		"animations": result.get("animations", []),
	}
	var source_bytes: PackedByteArray = result.get("source_bytes", PackedByteArray())
	var raw_meshes: Array = result.get("meshes", [])
	var godot_meshes: Array[Dictionary] = []
	var collision_faces := PackedVector3Array()
	for index in range(raw_meshes.size()):
		var mesh_data: Dictionary = raw_meshes[index]
		var builder := Callable(self, "_build_godot_mesh").bind(mesh_data)
		var resource := DerivedResourceCache.load_or_build(
			source_bytes, "nif-arraymesh-%d" % index, builder
		) as ArrayMesh
		if resource != null:
			godot_meshes.push_back({
				"mesh": resource,
				"mesh_name": str(mesh_data.get("name", "")),
				"diffuse_texture_path": str(mesh_data.get("diffuse_texture_path", "")),
				"alpha_blend": bool(mesh_data.get("alpha_blend", false)),
				"alpha_test": bool(mesh_data.get("alpha_test", false)),
				"alpha_threshold": int(mesh_data.get("alpha_threshold", 128)),
				"bone_names": mesh_data.get("bone_names", []),
			})
			var shape_name := str(mesh_data.get("name", "")).to_lower()
			if not shape_name.contains("sky") and not shape_name.contains("lightbeam") and not shape_name.contains("dust"):
				collision_faces.append_array(resource.get_faces())
	_collision_cache[key] = null
	if not collision_faces.is_empty():
		var collision_builder := Callable(self, "_build_concave_shape").bind(collision_faces)
		_collision_cache[key] = DerivedResourceCache.load_or_build(
			source_bytes, "nif-static-concave-shape", collision_builder
		) as ConcavePolygonShape3D
	_model_cache[key] = godot_meshes
	return godot_meshes

func _build_concave_shape(faces: PackedVector3Array) -> ConcavePolygonShape3D:
	if faces.size() < 3 or faces.size() % 3 != 0:
		return null
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	return shape

func _should_collide_model(model_path: String) -> bool:
	var normalized := model_path.to_lower().replace("\\", "/")
	return not normalized.contains("/fx/") and not normalized.contains("lightbeam") and not normalized.contains("dust") and not normalized.contains("trigzone") and not normalized.contains("/triggers/") and not normalized.contains("markerx")

func _material_for_reference(
	model_path: String,
	texture_path: String,
	alpha_blend := false,
	alpha_test := false,
	alpha_threshold := 128
) -> StandardMaterial3D:
	var material := await _material_for_texture(texture_path, alpha_blend, alpha_test, alpha_threshold)
	if not _is_debug_service_model(model_path):
		return material
	var translucent := material.duplicate() as StandardMaterial3D
	translucent.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var tint := translucent.albedo_color
	tint.a = 0.1
	translucent.albedo_color = tint
	translucent.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return translucent

func _is_debug_service_model(model_path: String) -> bool:
	var normalized := model_path.to_lower().replace("\\", "/")
	var filename := normalized.get_file()
	return filename in ["markerx.nif", "markerxheading.nif", "marker_north.nif"] or normalized.contains("trigzone") or normalized.contains("/triggers/")

func _load_player_avatar() -> void:
	if data_reader == null:
		return
	status_label.text += "\nLoading original Imperial character meshes…"
	var avatar := Node3D.new()
	avatar.name = "OriginalImperialAvatar"
	avatar.scale = Vector3.ONE * game_units_to_meters
	_player_avatar = avatar
	player.add_child(avatar)
	await _meshes_for_model(PLAYER_SKELETON)
	var skeleton_metadata: Dictionary = _nif_metadata_cache.get(PLAYER_SKELETON.to_lower(), {})
	_player_skeleton = _build_player_skeleton(skeleton_metadata.get("nodes", []))
	if _player_skeleton != null:
		avatar.add_child(_player_skeleton)
		_align_avatar_to_floor_origin(avatar, _player_skeleton)
	await _meshes_for_model(PLAYER_IDLE_KF)
	_player_animations["Idle"] = _animation_sequence(PLAYER_IDLE_KF, PLAYER_IDLE_SEQUENCE)
	for animation_name: String in PLAYER_DIRECTIONAL_KFS:
		var animation_info: Array = PLAYER_DIRECTIONAL_KFS[animation_name]
		var asset_path := str(animation_info[0])
		await _meshes_for_model(asset_path)
		_player_animations[animation_name] = _animation_sequence(asset_path, str(animation_info[1]))
	for animation_name: String in PLAYER_JUMP_KFS:
		var animation_info: Array = PLAYER_JUMP_KFS[animation_name]
		var asset_path := str(animation_info[0])
		await _meshes_for_model(asset_path)
		_player_animations[animation_name] = _animation_sequence(asset_path, str(animation_info[1]))
	var loaded_animation_names: Array[String] = []
	for animation_name_value: Variant in _player_animations.keys():
		var animation_name := str(animation_name_value)
		if _player_animations[animation_name].is_empty():
			push_warning("Original player KF sequence %s was not found" % animation_name)
		else:
			loaded_animation_names.push_back(animation_name)
	_initialize_player_face_profiles()
	var part_count := 0
	for model_path: String in PLAYER_AVATAR_PARTS:
		var meshes: Array = await _meshes_for_model(model_path)
		for mesh_entry: Dictionary in meshes:
			var instance := MeshInstance3D.new()
			var mesh_name := str(mesh_entry.get("mesh_name", "Mesh"))
			instance.name = model_path.get_file().get_basename() + "_" + mesh_name.replace(":", "_")
			var source_mesh := mesh_entry.mesh as ArrayMesh
			instance.mesh = source_mesh
			if model_path.to_lower() == PLAYER_FACE_HEAD_MODEL.to_lower():
				_player_face_meshes.push_back(instance)
				_player_face_source_meshes.push_back(source_mesh)
			instance.material_override = await _material_for_texture(str(mesh_entry.diffuse_texture_path))
			avatar.add_child(instance)
			var bone_names: Array = mesh_entry.get("bone_names", [])
			if _player_skeleton != null and not bone_names.is_empty():
				instance.skeleton = NodePath("../Skeleton3D")
				instance.skin = _skin_for_mesh(bone_names, _player_skeleton)
			part_count += 1
	_apply_player_face_profile()
	_player_face_state = {
		"name": "Player",
		"face_meshes": _player_face_meshes,
		"face_expression": "",
		"face_expression_weight": 0.0,
		"face_expression_previous": "",
		"face_expression_previous_weight": 0.0,
		"face_expression_transition": 0.25,
		"expression_cycle": _available_face_expression_cycle(_player_face_meshes),
		"blink_cooldown": randf_range(2.5, 5.5),
		"blink_remaining": 0.0,
	}
	_apply_face_expression(_player_face_state)
	_refresh_player_face_profile_hint()
	print("OpenOB player FaceGen expressions: %s" % str(_player_face_state.expression_cycle))
	var clothing_count := await _load_player_starting_clothing(avatar)
	if part_count > 0:
		var body_proxy := player.get_node_or_null("BodyProxy") as MeshInstance3D
		if body_proxy != null:
			body_proxy.visible = false
		status_label.text += "\nOriginal Imperial male rig loaded (%d body/head shapes, %d bones); idle, directional, fast, and jump KF playback active.\nLoaded %d base-game clothing pieces." % [
			part_count,
			_player_skeleton.get_bone_count() if _player_skeleton != null else 0,
			clothing_count,
		]
		print("OpenOB loaded original Imperial actor: %d body/head shapes, %d rig bones, %d base-game clothing pieces, idle=%s, KF sequences=%s" % [
			part_count,
			_player_skeleton.get_bone_count() if _player_skeleton != null else 0,
			clothing_count,
			str(not _player_animations.get("Idle", {}).is_empty()),
			", ".join(loaded_animation_names)
		])

func _initialize_player_face_profiles() -> void:
	_player_face_profiles.clear()
	_player_face_profile_ids.clear()
	_player_face_profile_index = 0
	var facegen_data := _ensure_facegen_data(PLAYER_FACE_HEAD_MODEL)
	if facegen_data.is_empty():
		face_profile_label.text = "C · Player face: unavailable"
		return
	var symmetric := PackedFloat32Array()
	symmetric.resize(facegen_data.egm.symmetric_modes.size())
	var asymmetric := PackedFloat32Array()
	asymmetric.resize(facegen_data.egm.asymmetric_modes.size())
	_player_face_profiles.push_back({
		"id": "default",
		"name": "Default",
		"face_symmetric": symmetric,
		"face_asymmetric": asymmetric,
	})
	_refresh_player_face_profile_hint()

func _register_player_face_profile(npc: Dictionary, head_model_path: String) -> void:
	if head_model_path.to_lower() != PLAYER_FACE_HEAD_MODEL.to_lower():
		return
	var profile_id := int(npc.get("form_id", 0))
	if profile_id == 0 or _player_face_profile_ids.has(profile_id):
		return
	var facegen_data := _ensure_facegen_data(head_model_path)
	if facegen_data.is_empty():
		return
	var symmetric: PackedFloat32Array = npc.get("face_symmetric", PackedFloat32Array())
	var asymmetric: PackedFloat32Array = npc.get("face_asymmetric", PackedFloat32Array())
	if symmetric.size() != facegen_data.egm.symmetric_modes.size() or asymmetric.size() != facegen_data.egm.asymmetric_modes.size():
		return
	var profile_name := str(npc.get("name", npc.get("editor_id", "NPC")))
	_player_face_profiles.push_back({
		"id": profile_id,
		"name": profile_name,
		"face_symmetric": symmetric,
		"face_asymmetric": asymmetric,
	})
	_player_face_profile_ids[profile_id] = true
	_refresh_player_face_profile_hint()

func _cycle_player_face_profile() -> void:
	if _world_loading or _player_face_profiles.size() < 2:
		return
	_player_face_profile_index = (_player_face_profile_index + 1) % _player_face_profiles.size()
	_apply_player_face_profile()
	_refresh_player_face_profile_hint()
	var profile: Dictionary = _player_face_profiles[_player_face_profile_index]
	print("OpenOB changed player face profile to %s" % str(profile.get("name", "Default")))

func _cycle_player_face_expression() -> void:
	if _world_loading or _player_face_state.is_empty():
		return
	var expression_cycle: Array = _player_face_state.get("expression_cycle", [""])
	if expression_cycle.size() < 2:
		return
	var current_index := expression_cycle.find(str(_player_face_state.get("face_expression", "")))
	var expression_index := (current_index + 1) % expression_cycle.size()
	var expression_name := str(expression_cycle[expression_index])
	_set_face_expression(_player_face_state, expression_name, 0.75)
	_refresh_player_face_profile_hint()
	print("OpenOB set player face expression to %s" % (expression_name if not expression_name.is_empty() else "neutral"))

func _apply_player_face_profile() -> void:
	if _player_face_profiles.is_empty() or _player_face_meshes.is_empty():
		return
	var profile: Dictionary = _player_face_profiles[_player_face_profile_index]
	var facegen_data := _ensure_facegen_data(PLAYER_FACE_HEAD_MODEL)
	if facegen_data.is_empty():
		return
	for index in range(mini(_player_face_meshes.size(), _player_face_source_meshes.size())):
		var instance := _player_face_meshes[index]
		if not is_instance_valid(instance):
			continue
		var morphed_mesh := FaceGenData.build_head_mesh(
			_player_face_source_meshes[index],
			profile.get("face_symmetric", PackedFloat32Array()),
			profile.get("face_asymmetric", PackedFloat32Array()),
			facegen_data.egm,
			facegen_data.tri
		)
		if morphed_mesh != null:
			instance.mesh = morphed_mesh

func _refresh_player_face_profile_hint() -> void:
	if _player_face_profiles.is_empty():
		return
	var profile: Dictionary = _player_face_profiles[_player_face_profile_index]
	var expression := str(_player_face_state.get("face_expression", "")) if not _player_face_state.is_empty() else ""
	face_profile_label.text = "C · Face: %s (%d/%d)\nG · Expression: %s" % [
		str(profile.get("name", "Default")),
		_player_face_profile_index + 1,
		_player_face_profiles.size(),
		expression if not expression.is_empty() else "Neutral",
	]

func _load_player_starting_clothing(avatar: Node3D) -> int:
	var loaded_count := 0
	for editor_id: String in PLAYER_STARTING_CLOTHING:
		var form_id := int(data_reader.find_form_id_by_editor_id(editor_id))
		if form_id == 0:
			push_warning("Player starting clothing record %s was not found" % editor_id)
			continue
		if await _equip_player_item(form_id):
			_add_inventory_item(form_id)
			loaded_count += 1
	print("OpenOB equipped player with %d base-game CLOT clothing meshes" % loaded_count)
	return loaded_count

func _equip_player_item(form_id: int) -> bool:
	if _player_avatar == null or _player_skeleton == null:
		return false
	var item_type := str(data_reader.find_record_type(form_id))
	var model_path := str(data_reader.find_item_model_path(form_id, false))
	if item_type not in ["ARMO", "CLOT", "WEAP"] or model_path.is_empty():
		return false
	var item_meshes: Array[MeshInstance3D]
	if item_type == "WEAP":
		item_meshes = await _add_actor_model(_player_avatar, _player_skeleton, model_path, "Bip01 R Hand")
		if item_meshes.is_empty():
			return false
		for previous_mesh in _player_weapon_meshes:
			if is_instance_valid(previous_mesh):
				previous_mesh.queue_free()
		_player_weapon_meshes = item_meshes
		return true
	var slots := int(data_reader.get_item_biped_slots(form_id))
	if slots == 0:
		return false
	item_meshes = await _add_actor_model(_player_avatar, _player_skeleton, model_path)
	if item_meshes.is_empty():
		return false
	var replaced_item_ids: Array[int] = []
	for equipped_id_value: Variant in _player_equipment.keys():
		var equipped_id := int(equipped_id_value)
		var equipped: Dictionary = _player_equipment[equipped_id]
		if (int(equipped.get("slots", 0)) & slots) == 0:
			continue
		for previous_mesh_value: Variant in equipped.get("meshes", []):
			var previous_mesh := previous_mesh_value as MeshInstance3D
			if is_instance_valid(previous_mesh):
				previous_mesh.queue_free()
		replaced_item_ids.push_back(equipped_id)
	for equipped_id in replaced_item_ids:
		_player_equipment.erase(equipped_id)
	_player_equipment[form_id] = {"slots": slots, "meshes": item_meshes}
	return true

func _nearest_placed_item() -> Dictionary:
	var nearest_item: Dictionary = {}
	var nearest_distance_squared := 1.8 * 1.8
	for item_value: Variant in _placed_items.values():
		var item: Dictionary = item_value
		var item_position: Vector3 = item.get("position", Vector3.ZERO)
		var distance_squared := player.global_position.distance_squared_to(item_position)
		if distance_squared < nearest_distance_squared:
			nearest_distance_squared = distance_squared
			nearest_item = item
	return nearest_item

func _pick_up_placed_item(item: Dictionary) -> void:
	var reference_id := int(item.get("reference_id", 0))
	_placed_items.erase(reference_id)
	for mesh_value: Variant in item.get("mesh_instances", []):
		var mesh_instance := mesh_value as MeshInstance3D
		if is_instance_valid(mesh_instance):
			mesh_instance.queue_free()
	var form_id := int(item.get("base_form_id", 0))
	var item_name := str(item.get("editor_id", "item"))
	_add_inventory_item(form_id)
	var item_type := str(item.get("record_type", ""))
	if item_type in ["ARMO", "CLOT", "WEAP"] and await _equip_player_item(form_id):
		print("OpenOB picked up and equipped %s" % item_name)
	else:
		print("OpenOB picked up %s into inventory" % item_name)
	_refresh_inventory_hud()
	_pickup_toast_text = "Picked up %s" % item_name
	_pickup_toast_remaining = 1.5

func _add_inventory_item(form_id: int, amount: int = 1) -> void:
	if form_id <= 0 or amount <= 0:
		return
	_player_inventory[form_id] = int(_player_inventory.get(form_id, 0)) + amount
	_refresh_inventory_hud()

func _refresh_inventory_hud() -> void:
	var item_count := 0
	for amount_value: Variant in _player_inventory.values():
		item_count += int(amount_value)
	inventory_label.text = "Inventory: %d items · %d types" % [item_count, _player_inventory.size()]

func _update_interaction_hint(nearby_item: Dictionary) -> void:
	if _world_loading:
		interaction_hint_label.visible = false
		return
	if _pickup_toast_remaining > 0.0:
		interaction_hint_label.text = _pickup_toast_text
	elif not nearby_item.is_empty():
		interaction_hint_label.text = "E · Pick up %s" % str(nearby_item.get("editor_id", "item"))
	else:
		interaction_hint_label.text = "E · Follow next linked door"
	interaction_hint_label.visible = true

func _load_cell_actors(cell: Dictionary) -> void:
	_clear_cell_actors()
	var actor_count := 0
	var routed_actor_count := 0
	for reference_value: Variant in cell.get("references", []):
		var reference: Dictionary = reference_value
		if str(reference.get("record_type", "")) != "ACHR":
			continue
		var npc: Dictionary = data_reader.find_npc_base(int(reference.get("base_form_id", 0)))
		if npc.is_empty():
			continue
		var actor_root := CharacterBody3D.new()
		actor_root.set_script(NpcRouteController)
		var actor_name := str(reference.get("reference_name", "")).strip_edges()
		if actor_name.is_empty():
			actor_name = str(npc.get("editor_id", "")).strip_edges()
		if actor_name.is_empty():
			actor_name = "NPC_%08X" % int(reference.get("form_id", 0))
		actor_root.name = actor_name
		actor_root.collision_layer = 4
		actor_root.collision_mask = 2
		actor_root.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
		actor_root.transform = _actor_reference_transform(reference)
		add_child(actor_root)
		var actor_collision := CollisionShape3D.new()
		actor_collision.name = "ApproximateActorCollision"
		var actor_capsule := CapsuleShape3D.new()
		actor_capsule.radius = 0.27
		actor_capsule.height = 1.8
		actor_collision.shape = actor_capsule
		actor_collision.position.y = 0.9
		actor_root.add_child(actor_collision)
		var avatar := Node3D.new()
		avatar.name = "OriginalActor"
		avatar.scale = Vector3.ONE * game_units_to_meters
		actor_root.add_child(avatar)
		var skeleton_metadata: Dictionary = _nif_metadata_cache.get(PLAYER_SKELETON.to_lower(), {})
		var skeleton := _build_player_skeleton(skeleton_metadata.get("nodes", []))
		if skeleton == null:
			actor_root.queue_free()
			continue
		avatar.add_child(skeleton)
		_align_avatar_to_floor_origin(avatar, skeleton)
		var is_female := bool(npc.get("female", false))
		var actor_parts: Array = (FEMALE_AVATAR_PARTS if is_female else PLAYER_AVATAR_PARTS).duplicate()
		actor_parts.pop_back()
		var head_model_path := _npc_head_model_path(npc)
		_register_player_face_profile(npc, head_model_path)
		actor_parts[actor_parts.size() - 1] = head_model_path
		var face_meshes: Array[MeshInstance3D] = []
		for model_path: String in actor_parts:
			if model_path.to_lower() == head_model_path.to_lower():
				var new_face_meshes: Array[MeshInstance3D] = await _add_actor_model(
					avatar, skeleton, model_path, "", PackedByteArray(), npc
				)
				face_meshes.append_array(new_face_meshes)
			else:
				await _add_actor_model(avatar, skeleton, model_path)
		var hair_form_id := int(npc.get("hair_form_id", 0))
		var hair_path := str(data_reader.find_item_model_path(hair_form_id, is_female)) if hair_form_id != 0 else ""
		if hair_path.is_empty():
			hair_path = "Characters/Imperial/female/hair01.nif" if is_female else "Characters/Imperial/male/hair01.nif"
		var hair_color: PackedByteArray = npc.get("hair_color", PackedByteArray())
		await _add_actor_model(avatar, skeleton, hair_path, "", hair_color)
		var weapon_attached := false
		var attached_item_names: Array[String] = []
		for item_form_id: int in _npc_equipment_ids(npc):
			var item_type := str(data_reader.find_record_type(item_form_id))
			if item_type != "ARMO" and item_type != "CLOT" and item_type != "WEAP":
				continue
			if item_type == "WEAP" and weapon_attached:
				continue
			var item_path := str(data_reader.find_item_model_path(item_form_id, is_female))
			if item_path.is_empty():
				continue
			var attach_bone := "Bip01 R Hand" if item_type == "WEAP" else ""
			await _add_actor_model(avatar, skeleton, item_path, attach_bone)
			attached_item_names.push_back(str(data_reader.find_editor_id(item_form_id)))
			if item_type == "WEAP":
				weapon_attached = true
		print("OpenOB attached equipment to %s: %s" % [actor_name, str(attached_item_names)])
		await _meshes_for_model(PLAYER_IDLE_KF)
		await _meshes_for_model(PLAYER_DIRECTIONAL_KFS["Forward"][0])
		await _meshes_for_model(PLAYER_FAST_FORWARD_KF)
		var animations := {
			"Idle": _animation_sequence(PLAYER_IDLE_KF, PLAYER_IDLE_SEQUENCE, skeleton),
			"Forward": _animation_sequence(PLAYER_DIRECTIONAL_KFS["Forward"][0], "Forward", skeleton),
			"FastForward": _animation_sequence(PLAYER_FAST_FORWARD_KF, "FastForward", skeleton),
		}
		var expression_cycle := _available_face_expression_cycle(face_meshes)
		var waypoints := _npc_waypoints(cell, actor_name, npc)
		if not waypoints.is_empty():
			routed_actor_count += 1
			var route_speeds: Array[String] = []
			for waypoint: Dictionary in waypoints:
				route_speeds.push_back("%.1f" % float(waypoint.get("speed_mps", 0.0)))
			print("OpenOB route for %s uses %d ESM marker targets at %s m/s" % [actor_name, waypoints.size(), str(route_speeds)])
		actor_root.call("configure_route", waypoints, actor_name == "ValenDrethRef", 1.2 if not waypoints.is_empty() else 0.0)
		var initial_expression := "Happy" if actor_name == "ValenDrethRef" else "Fear" if actor_name == "UrielSeptimRef" else ""
		if not expression_cycle.has(initial_expression):
			initial_expression = ""
		var actor_state := {
			"name": actor_name,
			"root": actor_root,
			"skeleton": skeleton,
			"face_meshes": face_meshes,
			"face_expression": initial_expression,
			"face_expression_weight": 0.7,
			"face_expression_previous": "",
			"face_expression_previous_weight": 0.0,
			"face_expression_transition": 0.0,
			"expression_cycle": expression_cycle,
			"blink_cooldown": randf_range(2.5, 5.5),
			"blink_remaining": 0.0,
			"animations": animations,
			"active_animation": "",
			"animation_time": 0.0,
		}
		_npc_actors.push_back(actor_state)
		_apply_face_expression(actor_state)
		actor_count += 1
	print("OpenOB assembled %d placed NPCs, %d with ESM marker routes, original idle/walk/fast-walk animations, and FaceGen head morphs" % [actor_count, routed_actor_count])
	if actor_count > 0:
		status_label.text += "\nLoaded %d placed NPCs with original rigs, outfit meshes, FaceGen head shapes, and walk/fast-walk animations. F cycles the nearest NPC's expression." % actor_count

func _clear_cell_actors() -> void:
	for actor: Dictionary in _npc_actors:
		var actor_root := actor.get("root") as Node3D
		if not is_instance_valid(actor_root):
			continue
		actor_root.set_physics_process(false)
		actor_root.set_process(false)
		actor_root.queue_free()
	_npc_actors.clear()

func _npc_head_model_path(npc: Dictionary) -> String:
	var race_form_id := int(npc.get("race_form_id", 0))
	var race_editor_id := str(data_reader.find_editor_id(race_form_id)).to_lower()
	match race_editor_id:
		"argonian":
			return "Characters/Argonian/headargonian.nif"
		"khajiit":
			return "Characters/Khajiit/headkhajiit.nif" if bool(npc.get("female", false)) else "Characters/Khajiit/male/headkhajiit.nif"
		"orc":
			return "Characters/Orc/headorc.nif"
		_:
			return "Characters/Imperial/headhuman.nif"

func _ensure_facegen_data(head_model_path: String) -> Dictionary:
	var cache_key := head_model_path.to_lower().replace("\\", "/")
	if _facegen_cache.has(cache_key):
		return _facegen_cache[cache_key]
	var asset_stem := head_model_path.replace("\\", "/").get_basename()
	var egm_bytes: PackedByteArray = data_reader.read_asset("Meshes/" + asset_stem + ".egm")
	var tri_bytes: PackedByteArray = data_reader.read_asset("Meshes/" + asset_stem + ".tri")
	if egm_bytes.is_empty() or tri_bytes.is_empty():
		push_warning("Could not read FaceGen data for %s: %s" % [head_model_path, data_reader.get_error()])
		_facegen_cache[cache_key] = {}
		return {}
	var egm := FaceGenData.decode_egm(egm_bytes)
	var tri := FaceGenData.decode_tri(tri_bytes)
	if egm.has("error") or tri.has("error"):
		push_warning("Could not decode FaceGen data for %s: EGM=%s TRI=%s" % [
			head_model_path, egm.get("error", "ok"), tri.get("error", "ok")
		])
		_facegen_cache[cache_key] = {}
		return {}
	if int(egm.vertex_count) != int(tri.total_vertex_count):
		push_warning("FaceGen EGM/TRI vertex counts do not agree for %s" % head_model_path)
		_facegen_cache[cache_key] = {}
		return {}
	for morph_value: Variant in tri.difference_morphs:
		var morph_name := str(morph_value.get("name", ""))
		if not _facegen_expression_names.has(morph_name):
			_facegen_expression_names.push_back(morph_name)
	for morph_value: Variant in tri.static_morphs:
		var morph_name := str(morph_value.get("name", ""))
		if not _facegen_expression_names.has(morph_name):
			_facegen_expression_names.push_back(morph_name)
	var decoded := {"egm": egm, "tri": tri}
	_facegen_cache[cache_key] = decoded
	print("OpenOB decoded FaceGen for %s: %d vertices, %d symmetric/%d asymmetric modes, %d expression and %d static morphs" % [
		head_model_path,
		egm.vertex_count,
		egm.symmetric_modes.size(),
		egm.asymmetric_modes.size(),
		tri.difference_morphs.size(),
		tri.static_morphs.size(),
	])
	return decoded

func _npc_equipment_ids(npc: Dictionary) -> Array[int]:
	var outfit_garments: Array[int] = []
	var outfit_weapons: Array[int] = []
	var inventory_armor: Array[int] = []
	var inventory_clothing: Array[int] = []
	var inventory_weapons: Array[int] = []
	var seen: Dictionary = {}
	var outfit_id := int(npc.get("default_outfit_form_id", 0))
	if outfit_id != 0:
		for item_value: Variant in data_reader.get_outfit_items(outfit_id):
			var item_id := int(item_value)
			if seen.has(item_id):
				continue
			seen[item_id] = true
			var item_type := str(data_reader.find_record_type(item_id))
			if item_type == "ARMO" or item_type == "CLOT":
				outfit_garments.push_back(item_id)
			elif item_type == "WEAP":
				outfit_weapons.push_back(item_id)
	for inventory_value: Variant in npc.get("inventory", []):
		var entry: Dictionary = inventory_value
		var item_id := int(entry.get("form_id", 0))
		if int(entry.get("count", 0)) <= 0 or seen.has(item_id):
			continue
		seen[item_id] = true
		var item_type := str(data_reader.find_record_type(item_id))
		match item_type:
			"ARMO": inventory_armor.push_back(item_id)
			"CLOT": inventory_clothing.push_back(item_id)
			"WEAP": inventory_weapons.push_back(item_id)

	# DOFT is the NPC's authored outfit. Only fall back to carried garments when
	# the base record has no outfit, as happens for the intro-cell actors.
	var garment_candidates := outfit_garments
	if garment_candidates.is_empty():
		garment_candidates.append_array(inventory_armor)
		garment_candidates.append_array(inventory_clothing)

	var item_ids: Array[int] = []
	var occupied_slots := 0
	for item_id: int in garment_candidates:
		var slots := int(data_reader.get_item_biped_slots(item_id))
		if slots == 0 or (slots & occupied_slots) != 0:
			continue
		item_ids.push_back(item_id)
		occupied_slots |= slots

	for item_id: int in outfit_weapons:
		item_ids.push_back(item_id)
	for item_id: int in inventory_weapons:
		item_ids.push_back(item_id)
	return item_ids

func _add_actor_model(
	avatar: Node3D,
	skeleton: Skeleton3D,
	model_path: String,
	attach_bone := "",
	tint: PackedByteArray = PackedByteArray(),
	npc_face_data: Dictionary = {}
) -> Array[MeshInstance3D]:
	var meshes: Array = await _meshes_for_model(model_path)
	var attachment: Node3D = avatar
	var added_instances: Array[MeshInstance3D] = []
	if not attach_bone.is_empty():
		var bone_attachment := BoneAttachment3D.new()
		bone_attachment.bone_name = attach_bone
		skeleton.add_child(bone_attachment)
		attachment = bone_attachment
	for mesh_entry: Dictionary in meshes:
		var instance := MeshInstance3D.new()
		var mesh_name := str(mesh_entry.get("mesh_name", "Mesh"))
		instance.name = model_path.get_file().get_basename() + "_" + mesh_name.replace(":", "_")
		var source_mesh := mesh_entry.mesh as ArrayMesh
		if not npc_face_data.is_empty():
			var facegen_data := _ensure_facegen_data(model_path)
			if not facegen_data.is_empty():
				var face_mesh := FaceGenData.build_head_mesh(
					source_mesh,
					npc_face_data.get("face_symmetric", PackedFloat32Array()),
					npc_face_data.get("face_asymmetric", PackedFloat32Array()),
					facegen_data.egm,
					facegen_data.tri
				)
				if face_mesh != null:
					source_mesh = face_mesh
				else:
					push_warning("Could not apply FaceGen data to %s" % str(npc_face_data.get("editor_id", model_path)))
		instance.mesh = source_mesh
		var material := await _material_for_texture(
			str(mesh_entry.diffuse_texture_path),
			bool(mesh_entry.get("alpha_blend", false)),
			bool(mesh_entry.get("alpha_test", false)),
			int(mesh_entry.get("alpha_threshold", 128))
		)
		if tint.size() >= 3:
			material = material.duplicate() as StandardMaterial3D
			material.albedo_color = Color8(tint[0], tint[1], tint[2], tint[3] if tint.size() > 3 and tint[3] > 0 else 255)
		instance.material_override = material
		attachment.add_child(instance)
		var bone_names: Array = mesh_entry.get("bone_names", [])
		if not bone_names.is_empty() and attach_bone.is_empty():
			instance.skeleton = NodePath("../Skeleton3D")
			instance.skin = _skin_for_mesh(bone_names, skeleton)
		added_instances.push_back(instance)
	return added_instances

func _actor_reference_transform(reference: Dictionary) -> Transform3D:
	var position: PackedFloat32Array = reference.get("position", PackedFloat32Array())
	var rotation: PackedFloat32Array = reference.get("rotation", PackedFloat32Array())
	if position.size() < 3 or rotation.size() < 3:
		return Transform3D.IDENTITY
	var source_to_godot := Basis(Vector3.RIGHT, Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0))
	var source_rotation := Basis.from_euler(Vector3(rotation[0], rotation[1], rotation[2]))
	var godot_rotation := (source_to_godot * source_rotation * source_to_godot.inverse()).orthonormalized()
	var godot_position := Vector3(position[0], position[2], -position[1]) * game_units_to_meters
	return Transform3D(godot_rotation, godot_position)

func _npc_waypoints(cell: Dictionary, actor_name: String, npc: Dictionary) -> Array[Dictionary]:
	var waypoints: Array[Dictionary] = []
	var route_markers: Array[String] = []
	match actor_name:
		"ValenDrethRef":
			route_markers = ["CGValenDrethTauntMarker", "CGValenDrethTauntMarker2"]
		"UrielSeptimRef":
			route_markers = ["CGMarkerAEmperor", "CGMarkerBEmperor", "CGMarkerCEmperor", "CGMarkerC1Emperor", "CGMarkerC2Emperor"]
		"BaurusRef":
			route_markers = ["CGMarkerABaurus", "CGMarker9Baurus", "CGMarkerCBaurus", "CGMarkerC2Baurus"]
		"GlenroyRef":
			route_markers = ["CGMarkerAGlenroy", "CGMarkerBGlenroy", "CGMarkerCGlenroy", "CGMarkerC2Glenroy"]
		"RenoteRef":
			route_markers = ["CGMarkerARenote", "CGMarkerBRenote", "CGMarkerB1Renote", "CGMarkerCRenote", "CGMarkerC2Renote"]
	if route_markers.is_empty():
		return waypoints
	var movement_flags_by_target: Dictionary = {}
	var package_ids: PackedInt64Array = npc.get("ai_package_form_ids", PackedInt64Array())
	for package_id: int in package_ids:
		var package: Dictionary = data_reader.get_ai_package_info(package_id)
		if package.is_empty() or int(package.get("location_type", -1)) != 0:
			continue
		var package_type := int(package.get("package_type", -1))
		if package_type != 1 and package_type != 6:
			continue
		var target_id := int(package.get("location_form_id", 0))
		if target_id != 0 and not movement_flags_by_target.has(target_id):
			movement_flags_by_target[target_id] = int(package.get("flags", 0))
	for marker_name: String in route_markers:
		for reference_value: Variant in cell.get("references", []):
			var reference: Dictionary = reference_value
			if str(reference.get("reference_name", "")) == marker_name:
				var target_id := int(reference.get("form_id", 0))
				var package_flags := int(movement_flags_by_target.get(target_id, 0))
				var target_speed := 3.4 if (package_flags & 0x00002000) != 0 else 1.3
				waypoints.push_back({
					"position": _reference_transform(reference).origin,
					"speed_mps": target_speed,
				})
				break
	return waypoints

func set_npc_expression(actor_name: String, expression_name: String, weight := 1.0) -> void:
	for actor: Dictionary in _npc_actors:
		if str(actor.get("name", "")) != actor_name:
			continue
		var expression_cycle: Array = actor.get("expression_cycle", [""])
		if not expression_cycle.has(expression_name):
			push_warning("NPC %s has no FaceGen expression morph named %s" % [actor_name, expression_name])
			return
		_set_face_expression(actor, expression_name, weight)
		return

func _set_face_expression(actor: Dictionary, expression_name: String, weight: float) -> void:
	actor["face_expression_previous"] = str(actor.get("face_expression", ""))
	actor["face_expression_previous_weight"] = float(actor.get("face_expression_weight", 0.0))
	actor["face_expression"] = expression_name
	actor["face_expression_weight"] = clampf(weight, 0.0, 1.0)
	actor["face_expression_transition"] = 0.0
	_apply_face_expression(actor)

func _cycle_nearest_npc_face_expression() -> void:
	if _world_loading:
		return
	var nearest_actor: Dictionary = {}
	var nearest_distance_squared := INF
	for actor: Dictionary in _npc_actors:
		var actor_root := actor.get("root") as Node3D
		if not is_instance_valid(actor_root):
			continue
		var distance_squared := player.global_position.distance_squared_to(actor_root.global_position)
		if distance_squared < nearest_distance_squared:
			nearest_distance_squared = distance_squared
			nearest_actor = actor
	if nearest_actor.is_empty():
		return
	var actor_name := str(nearest_actor.get("name", ""))
	var expression_cycle: Array = nearest_actor.get("expression_cycle", [""])
	if expression_cycle.size() < 2:
		return
	var current_index := expression_cycle.find(str(nearest_actor.get("face_expression", "")))
	var expression_index := (current_index + 1) % expression_cycle.size()
	var expression_name := str(expression_cycle[expression_index])
	set_npc_expression(actor_name, expression_name, 0.75)
	print("OpenOB set %s face expression to %s" % [actor_name, expression_name if not expression_name.is_empty() else "neutral"])

func _available_face_expression_cycle(face_meshes: Array) -> Array[String]:
	var expression_cycle: Array[String] = [""]
	for expression_value: Variant in FACE_EXPRESSION_CYCLE:
		var expression_name := str(expression_value)
		if expression_name.is_empty():
			continue
		for instance_value: Variant in face_meshes:
			var instance := instance_value as MeshInstance3D
			if is_instance_valid(instance) and instance.mesh != null and _blend_shape_index(instance.mesh, StringName(expression_name)) >= 0:
				expression_cycle.push_back(expression_name)
				break
	return expression_cycle

func _apply_face_expression(actor: Dictionary) -> void:
	for instance_value: Variant in actor.get("face_meshes", []):
		var instance := instance_value as MeshInstance3D
		if not is_instance_valid(instance) or instance.mesh == null:
			continue
		for shape_name in _facegen_expression_names:
			var shape_index := _blend_shape_index(instance.mesh, StringName(shape_name))
			if shape_index >= 0:
				instance.set_blend_shape_value(shape_index, 0.0)
	var previous_name := str(actor.get("face_expression_previous", ""))
	if not previous_name.is_empty():
		_set_actor_face_shape(actor, previous_name, float(actor.get("face_expression_previous_weight", 0.0)))

func _update_face_expression(actor: Dictionary, delta: float) -> void:
	var transition_duration := 0.25
	var transition := minf(float(actor.get("face_expression_transition", 0.0)) + delta, transition_duration)
	actor["face_expression_transition"] = transition
	var linear_weight := clampf(transition / transition_duration, 0.0, 1.0)
	var blend_weight := linear_weight * linear_weight * (3.0 - 2.0 * linear_weight)
	var previous_name := str(actor.get("face_expression_previous", ""))
	var expression_name := str(actor.get("face_expression", ""))
	var previous_weight := float(actor.get("face_expression_previous_weight", 0.0)) * (1.0 - blend_weight)
	var target_weight := float(actor.get("face_expression_weight", 0.0)) * blend_weight
	if not previous_name.is_empty():
		_set_actor_face_shape(actor, previous_name, previous_weight)
	if not expression_name.is_empty():
		_set_actor_face_shape(actor, expression_name, target_weight + (previous_weight if previous_name == expression_name else 0.0))

func _blend_shape_index(mesh: Mesh, shape_name: StringName) -> int:
	for shape_index in range(mesh.get_blend_shape_count()):
		if mesh.get_blend_shape_name(shape_index) == shape_name:
			return shape_index
	return -1

func _set_actor_face_shape(actor: Dictionary, shape_name: String, weight: float) -> void:
	for instance_value: Variant in actor.get("face_meshes", []):
		var instance := instance_value as MeshInstance3D
		if not is_instance_valid(instance) or instance.mesh == null:
			continue
		var shape_index := _blend_shape_index(instance.mesh, StringName(shape_name))
		if shape_index >= 0:
			instance.set_blend_shape_value(shape_index, weight)

func _update_face_blink(actor: Dictionary, delta: float) -> void:
	var remaining := maxf(0.0, float(actor.get("blink_remaining", 0.0)) - delta)
	var cooldown := float(actor.get("blink_cooldown", 3.0)) - delta
	if cooldown <= 0.0 and remaining <= 0.0:
		remaining = 0.18
		cooldown = randf_range(2.5, 5.5)
	actor["blink_remaining"] = remaining
	actor["blink_cooldown"] = cooldown
	var blink_weight := 0.0
	if remaining > 0.0:
		blink_weight = sin((1.0 - remaining / 0.18) * PI)
	_set_actor_face_shape(actor, "BlinkLeft", blink_weight)
	_set_actor_face_shape(actor, "BlinkRight", blink_weight)

func _update_npc_actors(delta: float) -> void:
	for actor: Dictionary in _npc_actors:
		var actor_root := actor.get("root") as Node3D
		var skeleton := actor.get("skeleton") as Skeleton3D
		if not is_instance_valid(actor_root) or not is_instance_valid(skeleton):
			continue
		_update_face_blink(actor, delta)
		_update_face_expression(actor, delta)
		var walking := bool(actor_root.get("is_walking"))
		var horizontal_speed := Vector2(actor_root.velocity.x, actor_root.velocity.z).length()
		var requested_animation := "Idle"
		if walking:
			requested_animation = "FastForward" if horizontal_speed > 2.2 else "Forward"
		var animations: Dictionary = actor.get("animations", {})
		var animation: Dictionary = animations.get(requested_animation, {})
		if animation.is_empty() and requested_animation == "FastForward":
			requested_animation = "Forward"
			animation = animations.get(requested_animation, {})
		if animation.is_empty():
			continue
		if requested_animation != str(actor.get("active_animation", "")):
			actor["active_animation"] = requested_animation
			actor["animation_time"] = float(animation.get("start_time", 0.0))
		actor["animation_time"] = float(actor.get("animation_time", 0.0)) + delta
		_apply_animation_pose(skeleton, animation, float(actor["animation_time"]))

func _build_player_skeleton(node_data: Array) -> Skeleton3D:
	if node_data.is_empty():
		push_warning("Original male skeleton.nif did not provide node data")
		return null
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton3D"
	var pending: Array = node_data.duplicate()
	var bone_indices: Dictionary = {}
	while not pending.is_empty():
		var added_this_pass := false
		for node_value: Variant in pending.duplicate():
			var node: Dictionary = node_value
			var bone_name := str(node.get("name", ""))
			var parent_name := str(node.get("parent_name", ""))
			if bone_name.is_empty() or (not parent_name.is_empty() and not bone_indices.has(parent_name)):
				continue
			var bone_index := skeleton.add_bone(bone_name)
			if bone_index < 0:
				push_warning("Could not add original skeleton bone %s" % bone_name)
				pending.erase(node_value)
				continue
			if not parent_name.is_empty():
				skeleton.set_bone_parent(bone_index, int(bone_indices[parent_name]))
			skeleton.set_bone_rest(bone_index, _godot_node_rest(node))
			bone_indices[bone_name] = bone_index
			pending.erase(node_value)
			added_this_pass = true
		if not added_this_pass:
			push_warning("Could not resolve %d original skeleton node parents" % pending.size())
			break
	skeleton.reset_bone_poses()
	return skeleton

func _align_avatar_to_floor_origin(avatar: Node3D, skeleton: Skeleton3D) -> void:
	var root_bone := skeleton.find_bone("Bip01")
	if root_bone < 0:
		return
	# Character meshes use the model origin at the soles, while Bip01 is above them.
	var rig_root_height := skeleton.get_bone_global_rest(root_bone).origin.y * game_units_to_meters
	avatar.position.y -= rig_root_height
	if skeleton == _player_skeleton:
		print("OpenOB aligned avatar mesh origin to rig root: root_height=%.3fm" % rig_root_height)

func _godot_node_rest(node: Dictionary) -> Transform3D:
	var rows: PackedFloat32Array = node.get("rotation_rows", PackedFloat32Array())
	var source_rotation := Basis.IDENTITY
	if rows.size() == 9:
		source_rotation = Basis(
			Vector3(rows[0], rows[3], rows[6]),
			Vector3(rows[1], rows[4], rows[7]),
			Vector3(rows[2], rows[5], rows[8])
		)
	var source_to_godot := Basis(Vector3.RIGHT, Vector3(0.0, 0.0, -1.0), Vector3.UP)
	var godot_basis := source_to_godot * source_rotation * source_to_godot.inverse()
	godot_basis = godot_basis.scaled(Vector3.ONE * float(node.get("scale", 1.0)))
	return Transform3D(godot_basis, node.get("translation", Vector3.ZERO))

func _skin_for_mesh(bone_names: Array, skeleton: Skeleton3D) -> Skin:
	var skin := Skin.new()
	for bone_name_value: Variant in bone_names:
		var bone_name := str(bone_name_value)
		var bone_index := skeleton.find_bone(bone_name)
		var inverse_bind := Transform3D.IDENTITY
		if bone_index >= 0:
			inverse_bind = skeleton.get_bone_global_rest(bone_index).affine_inverse()
		else:
			push_warning("Mesh refers to missing original rig bone %s" % bone_name)
		skin.add_named_bind(bone_name, inverse_bind)
	return skin

func _animation_sequence(asset_path: String, sequence_name: String, target_skeleton: Skeleton3D = null) -> Dictionary:
	var key := asset_path.to_lower().replace("\\", "/")
	var metadata: Dictionary = _nif_metadata_cache.get(key, {})
	var pose_skeleton := target_skeleton if target_skeleton != null else _player_skeleton
	for animation_value: Variant in metadata.get("animations", []):
		var animation: Dictionary = animation_value
		if str(animation.get("name", "")) != sequence_name:
			continue
		var tracks: Array = []
		for track_value: Variant in animation.get("tracks", []):
			var track: Dictionary = track_value.duplicate()
			track["bone_index"] = pose_skeleton.find_bone(str(track.get("node_name", ""))) if pose_skeleton != null else -1
			if int(track.bone_index) >= 0:
				tracks.push_back(track)
		animation["tracks"] = tracks
		return animation
	return {}

func _update_player_animation(delta: float) -> void:
	if _player_skeleton == null:
		return
	var horizontal_speed := Vector2(player.velocity.x, player.velocity.z).length()
	var is_on_floor_now := player.is_on_floor()
	if _player_was_on_floor and not is_on_floor_now and player.velocity.y > 0.1:
		_set_player_animation("JumpStart" if not _player_animations.get("JumpStart", {}).is_empty() else "JumpLoop")
	elif not _player_was_on_floor and is_on_floor_now:
		_set_player_animation("JumpLand" if not _player_animations.get("JumpLand", {}).is_empty() else _player_locomotion_animation(horizontal_speed))
	elif not is_on_floor_now:
		if _active_animation == "JumpStart":
			var jump_start: Dictionary = _player_animations.get("JumpStart", {})
			if _animation_time >= float(jump_start.get("stop_time", 0.0)):
				_set_player_animation("JumpLoop")
		elif _active_animation != "JumpLoop":
			_set_player_animation("JumpLoop")
	elif _active_animation == "JumpLand":
		var jump_land: Dictionary = _player_animations.get("JumpLand", {})
		if _animation_time >= float(jump_land.get("stop_time", 0.0)):
			_set_player_animation(_player_locomotion_animation(horizontal_speed))
	else:
		_set_player_animation(_player_locomotion_animation(horizontal_speed))
	_player_was_on_floor = is_on_floor_now
	var animation: Dictionary = _player_animations.get(_active_animation, {})
	if animation.is_empty():
		return
	_animation_time += delta
	var start_time := float(animation.get("start_time", 0.0))
	var stop_time := float(animation.get("stop_time", start_time))
	var duration := stop_time - start_time
	if duration <= 0.0:
		return
	_apply_animation_pose(_player_skeleton, animation, _animation_time, _active_animation not in ["JumpStart", "JumpLand"])

func _player_locomotion_animation(horizontal_speed: float) -> String:
	if horizontal_speed <= 0.08:
		return "Idle"
	var local_velocity := Basis(Vector3.UP, player.rotation.y).inverse() * Vector3(player.velocity.x, 0.0, player.velocity.z)
	var is_fast := Input.is_action_pressed("run")
	var direction_name := "Forward"
	if absf(local_velocity.x) > absf(local_velocity.z):
		direction_name = "Left" if local_velocity.x < 0.0 else "Right"
	else:
		direction_name = "Backward" if local_velocity.z > 0.0 else "Forward"
	return ("Fast" + direction_name) if is_fast else direction_name

func _set_player_animation(animation_name: String) -> void:
	var animation: Dictionary = _player_animations.get(animation_name, {})
	if animation.is_empty() or animation_name == _active_animation:
		return
	_active_animation = animation_name
	_animation_time = float(animation.get("start_time", 0.0))

func _apply_animation_pose(skeleton: Skeleton3D, animation: Dictionary, time: float, looping: bool = true) -> void:
	var start_time := float(animation.get("start_time", 0.0))
	var stop_time := float(animation.get("stop_time", start_time))
	var duration := stop_time - start_time
	if duration <= 0.0:
		return
	var sample_time := start_time + fposmod(time - start_time, duration) if looping else clampf(time, start_time, stop_time)
	skeleton.reset_bone_poses()
	for track_value: Variant in animation.get("tracks", []):
		var track: Dictionary = track_value
		var bone_index := int(track.get("bone_index", -1))
		if bone_index < 0:
			continue
		var bone_name := str(track.get("node_name", ""))
		var translations: PackedFloat32Array = track.get("translations", PackedFloat32Array())
		if translations.size() >= 4 and bone_name != "Bip01":
			skeleton.set_bone_pose_position(bone_index, _sample_vector_keys(translations, 4, sample_time))
		var rotations: PackedFloat32Array = track.get("rotations", PackedFloat32Array())
		if rotations.size() >= 5:
			skeleton.set_bone_pose_rotation(bone_index, _sample_quaternion_keys(rotations, sample_time))
		var scales: PackedFloat32Array = track.get("scales", PackedFloat32Array())
		if scales.size() >= 2:
			var scale_value := _sample_scalar_keys(scales, sample_time)
			skeleton.set_bone_pose_scale(bone_index, Vector3.ONE * scale_value)

func _sample_vector_keys(keys: PackedFloat32Array, stride: int, time: float) -> Vector3:
	var key_count := keys.size() / stride
	if key_count <= 1:
		return Vector3(keys[1], keys[2], keys[3])
	for key_index in range(key_count - 1):
		var left := key_index * stride
		var right := (key_index + 1) * stride
		if time <= keys[right]:
			var span := keys[right] - keys[left]
			var weight := 0.0 if span <= 0.0 else clampf((time - keys[left]) / span, 0.0, 1.0)
			return Vector3(keys[left + 1], keys[left + 2], keys[left + 3]).lerp(
				Vector3(keys[right + 1], keys[right + 2], keys[right + 3]), weight
			)
	var last := (key_count - 1) * stride
	return Vector3(keys[last + 1], keys[last + 2], keys[last + 3])

func _sample_quaternion_keys(keys: PackedFloat32Array, time: float) -> Quaternion:
	var key_count := keys.size() / 5
	if key_count <= 1:
		return Quaternion(keys[1], keys[2], keys[3], keys[4]).normalized()
	for key_index in range(key_count - 1):
		var left := key_index * 5
		var right := (key_index + 1) * 5
		if time <= keys[right]:
			var span := keys[right] - keys[left]
			var weight := 0.0 if span <= 0.0 else clampf((time - keys[left]) / span, 0.0, 1.0)
			var first := Quaternion(keys[left + 1], keys[left + 2], keys[left + 3], keys[left + 4]).normalized()
			var second := Quaternion(keys[right + 1], keys[right + 2], keys[right + 3], keys[right + 4]).normalized()
			return first.slerp(second, weight).normalized()
	var last := (key_count - 1) * 5
	return Quaternion(keys[last + 1], keys[last + 2], keys[last + 3], keys[last + 4]).normalized()

func _sample_scalar_keys(keys: PackedFloat32Array, time: float) -> float:
	var key_count := keys.size() / 2
	if key_count <= 1:
		return keys[1]
	for key_index in range(key_count - 1):
		var left := key_index * 2
		var right := (key_index + 1) * 2
		if time <= keys[right]:
			var span := keys[right] - keys[left]
			var weight := 0.0 if span <= 0.0 else clampf((time - keys[left]) / span, 0.0, 1.0)
			return lerpf(keys[left + 1], keys[right + 1], weight)
	var last := (key_count - 1) * 2
	return keys[last + 1]

func _material_for_texture(
	texture_path: String,
	alpha_blend := false,
	alpha_test := false,
	alpha_threshold := 128
) -> StandardMaterial3D:
	var normalized_path := texture_path.strip_edges().replace("\\", "/")
	if normalized_path.is_empty():
		return _cell_material
	var alpha_mode := "blend" if alpha_blend else "scissor" if alpha_test else "opaque"
	var key := "%s|%s|%d" % [normalized_path.to_lower(), alpha_mode, alpha_threshold]
	if _material_cache.has(key):
		return _material_cache[key]

	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.roughness = 0.9
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if alpha_blend:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	elif alpha_test:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		material.alpha_scissor_threshold = float(alpha_threshold) / 255.0
	var texture := await _texture_for_path(normalized_path)
	if texture != null:
		material.albedo_texture = texture
	else:
		material.albedo_color = Color(0.62, 0.58, 0.5)
	_material_cache[key] = material
	return material

func _texture_for_path(texture_path: String) -> Texture2D:
	var key := texture_path.to_lower()
	if _texture_cache.has(key):
		return _texture_cache[key]
	if data_reader == null:
		return null

	var source_bytes: PackedByteArray = data_reader.read_asset(texture_path)
	if source_bytes.is_empty():
		var fallback_path := str(TEXTURE_FALLBACKS.get(key, ""))
		if not fallback_path.is_empty():
			source_bytes = data_reader.read_asset(fallback_path)
	if source_bytes.is_empty():
		push_warning("Could not read texture %s" % texture_path)
		_texture_cache[key] = null
		return null
	var kind := "oblivion-texture-%s" % texture_path.get_extension().to_lower()
	var builder := Callable(self, "_build_godot_texture").bind(source_bytes, texture_path)
	var resource := DerivedResourceCache.load_or_build(source_bytes, kind, builder) as Texture2D
	_texture_cache[key] = resource
	return resource

func _build_godot_texture(source_bytes: PackedByteArray, texture_path: String) -> Texture2D:
	var image := Image.new()
	if texture_path.get_extension().to_lower() == "dds":
		image = _decode_dds_image(source_bytes)
		if image == null:
			push_warning("Could not decode DDS texture %s" % texture_path)
			return null
		return ImageTexture.create_from_image(image)

	var load_error: Error
	match texture_path.get_extension().to_lower():
		"tga":
			load_error = image.load_tga_from_buffer(source_bytes)
		"png":
			load_error = image.load_png_from_buffer(source_bytes)
		"jpg", "jpeg":
			load_error = image.load_jpg_from_buffer(source_bytes)
		_:
			push_warning("Unsupported texture format: %s" % texture_path)
			return null
	if texture_path.get_extension().to_lower() == "dds" and (load_error != OK or image.is_empty()):
		# Some shipped Oblivion DDS files omit the final 8-byte 1x1 DXT block.
		# Pad only decoder input; cache identity still uses the unmodified asset.
		var padded_bytes := source_bytes.duplicate()
		padded_bytes.append_array(PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0]))
		var padded_image := Image.new()
		load_error = padded_image.load_dds_from_buffer(padded_bytes)
		if load_error == OK and not padded_image.is_empty():
			image = padded_image
	if load_error != OK or image.is_empty():
		push_warning("Could not decode texture %s (%s)" % [texture_path, error_string(load_error)])
		return null
	return ImageTexture.create_from_image(image)

func _decode_dds_image(source_bytes: PackedByteArray) -> Image:
	if source_bytes.size() < 128 or source_bytes.decode_u32(0) != 0x20534444:
		return null
	# Godot 4.7 rejects DDS files with partial mip chains. Oblivion commonly
	# stores fewer levels than the DDS header's full-chain flag implies. Load the
	# original top-level compressed image, then rebuild its mip chain in Godot.
	var decoder_bytes := source_bytes.duplicate()
	var dds_flags := decoder_bytes.decode_u32(8)
	if (dds_flags & 0x20000) != 0:
		decoder_bytes.encode_u32(8, dds_flags & ~0x20000)
		decoder_bytes.encode_u32(28, 1)
	var image := Image.new()
	var load_error := image.load_dds_from_buffer(decoder_bytes)
	if load_error != OK or image.is_empty():
		return null
	if image.is_compressed():
		load_error = image.decompress()
		if load_error != OK:
			return null
	if image.get_mipmap_count() == 0:
		load_error = image.generate_mipmaps()
		if load_error != OK:
			return null
	return image

func _build_godot_mesh(mesh_data: Dictionary) -> ArrayMesh:
	var vertices: PackedVector3Array = mesh_data.get("vertices", PackedVector3Array())
	var normals: PackedVector3Array = mesh_data.get("normals", PackedVector3Array())
	var uvs: PackedVector2Array = mesh_data.get("uvs", PackedVector2Array())
	var indices: PackedInt32Array = mesh_data.get("indices", PackedInt32Array())
	var bones: PackedInt32Array = mesh_data.get("bone_indices", PackedInt32Array())
	var weights: PackedFloat32Array = mesh_data.get("bone_weights", PackedFloat32Array())
	if vertices.is_empty() or indices.is_empty():
		return null

	if normals.size() != vertices.size():
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		for index in indices:
			if uvs.size() == vertices.size():
				surface.set_uv(uvs[index])
			if bones.size() == vertices.size() * 4 and weights.size() == vertices.size() * 4:
				var vertex_bones := PackedInt32Array()
				var vertex_weights := PackedFloat32Array()
				for influence in range(4):
					vertex_bones.push_back(bones[index * 4 + influence])
					vertex_weights.push_back(weights[index * 4 + influence])
				surface.set_bones(vertex_bones)
				surface.set_weights(vertex_weights)
			surface.add_vertex(vertices[index])
		surface.generate_normals()
		return surface.commit()

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	if uvs.size() == vertices.size():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	if bones.size() == vertices.size() * 4 and weights.size() == vertices.size() * 4:
		arrays[Mesh.ARRAY_BONES] = bones
		arrays[Mesh.ARRAY_WEIGHTS] = weights
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func _reference_transform(reference: Dictionary) -> Transform3D:
	var position: PackedFloat32Array = reference.get("position", PackedFloat32Array())
	var rotation: PackedFloat32Array = reference.get("rotation", PackedFloat32Array())
	if position.size() < 3 or rotation.size() < 3:
		return Transform3D.IDENTITY
	var source_to_godot := Basis(Vector3.RIGHT, Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0))
	var source_rotation := Basis.from_euler(Vector3(rotation[0], rotation[1], rotation[2]))
	var godot_rotation := source_to_godot * source_rotation * source_to_godot.inverse()
	var godot_position := Vector3(position[0], position[2], -position[1]) * game_units_to_meters
	return Transform3D(godot_rotation.scaled(Vector3.ONE * game_units_to_meters), godot_position)

func _place_player_at_start(cell: Dictionary) -> bool:
	if _place_player_at_start_marker(cell):
		return true
	push_warning("Player start marker %s was not found; using the first placed NPC as a fallback" % START_MARKER_EDITOR_ID)
	for reference: Dictionary in cell.get("references", []):
		if str(reference.get("record_type", "")) != "ACHR":
			continue
		var npc: Dictionary = data_reader.find_npc_base(int(reference.get("base_form_id", 0)))
		if npc.is_empty():
			continue
		var npc_transform := _reference_transform(reference)
		_player_start_position = npc_transform.origin
		player.global_position = _player_start_position
		player.global_rotation = npc_transform.basis.orthonormalized().get_euler()
		if player.has_method("set_spawn_yaw"):
			player.set_spawn_yaw(player.global_rotation.y)
		print("OpenOB placed player at fallback NPC %s (0x%08X): %s" % [
			str(reference.get("reference_name", npc.get("editor_id", "NPC"))),
			int(reference.get("form_id", 0)),
			str(player.global_position),
		])
		return true
	push_warning("No player start marker or valid NPC fallback was found; player remains at the origin")
	return false

func _place_player_at_start_marker(cell: Dictionary) -> bool:
	var selected_marker: Dictionary = {}
	for reference: Dictionary in cell.get("references", []):
		if int(reference.get("form_id", 0)) == START_MARKER_FORM_ID:
			selected_marker = reference
			break
		if selected_marker.is_empty() and str(reference.get("reference_name", "")) == START_MARKER_EDITOR_ID:
			selected_marker = reference
	if not selected_marker.is_empty():
		var marker_transform := _reference_transform(selected_marker)
		_player_start_position = marker_transform.origin
		player.global_position = _player_start_position
		player.global_rotation = marker_transform.basis.orthonormalized().get_euler()
		if player.has_method("set_spawn_yaw"):
			player.set_spawn_yaw(player.global_rotation.y)
		print("OpenOB placed player at start marker %s (0x%08X): %s" % [
			START_MARKER_EDITOR_ID, int(selected_marker.get("form_id", 0)), str(player.global_position)
		])
		return true
	return false

func _transition_to_next_linked_cell() -> void:
	if _world_loading or data_reader == null or current_cell.is_empty():
		return
	_world_loading = true
	var linked_refs: Array = []
	var same_cell_refs: Array = []
	var current_id := int(current_cell.get("form_id", 0))
	for reference: Dictionary in current_cell.references:
		var target_id := int(reference.get("teleport_cell_id", 0))
		if target_id == 0:
			continue
		if target_id == current_id:
			same_cell_refs.push_back(reference)
		else:
			linked_refs.push_back(reference)
	if linked_refs.is_empty():
		linked_refs = same_cell_refs
	if linked_refs.is_empty():
		_world_loading = false
		return
	_transition_index %= linked_refs.size()
	var reference: Dictionary = linked_refs[_transition_index]
	_transition_index += 1
	var target_id := int(reference.teleport_cell_id)
	var target: Dictionary = data_reader.find_cell_by_id(target_id)
	if target.is_empty():
		status_label.text = "Linked door target 0x%08X is not indexed." % target_id
		_world_loading = false
		return
	player.set_physics_process(false)
	_clear_cell_actors()
	current_cell = target
	_transition_index = 0
	await _load_cell_geometry(current_cell)
	var destination: PackedFloat32Array = reference.get("teleport_position", PackedFloat32Array())
	var destination_position := player.global_position
	if destination.size() >= 3:
		destination_position = Vector3(destination[0], destination[2], -destination[1]) * game_units_to_meters
	await _place_player_on_ground(destination_position)
	var destination_rotation: PackedFloat32Array = reference.get("teleport_rotation", PackedFloat32Array())
	if destination_rotation.size() >= 3:
		var source_to_godot := Basis(Vector3.RIGHT, Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0))
		var source_rotation := Basis.from_euler(Vector3(destination_rotation[0], destination_rotation[1], destination_rotation[2]))
		var godot_rotation := (source_to_godot * source_rotation * source_to_godot.inverse()).orthonormalized()
		player.set_spawn_yaw(godot_rotation.get_euler().y)
	await _load_cell_actors(current_cell)
	player.set_physics_process(true)
	_world_loading = false
