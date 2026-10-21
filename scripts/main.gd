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
const ANIMATION_BLEND_DURATION := 0.18
const PLAYER_FACE_HEAD_MODEL := "Characters/Imperial/headhuman.nif"
const PLAYER_HEAD_CULL_MARGIN := 128.0
const PLAYER_HAIR_MODEL := "Characters/Imperial/male/hair01.nif"
const PLAYER_FACE_DETAIL_PARTS := [
	"Characters/Imperial/eyeLeftHuman.nif",
	"Characters/Imperial/eyeRightHuman.nif",
	"Characters/Imperial/mouthHuman.nif",
	"Characters/Imperial/teethUpperHuman.nif",
	"Characters/Imperial/teethLowerHuman.nif",
	"Characters/Imperial/tongueHuman.nif",
]
const PLAYER_STARTING_CLOTHING := ["LowerShirt05", "LowerPants05"]
const FACE_EXPRESSION_CYCLE := ["", "Happy", "Anger", "Surprise", "Sad", "Fear"]
const LINKED_DOOR_INTERACTION_DISTANCE := 2.5
const EXTERIOR_CELL_SIZE := 4096.0
const EXTERIOR_STREAM_RADIUS := 9
const EXTERIOR_STATIC_REFERENCE_RADIUS := 6
const EXTERIOR_TREE_REFERENCE_RADIUS := 9
const EXTERIOR_RELOAD_GRID_DISTANCE := 5
const EXTERIOR_REFERENCE_RENDER_DISTANCE := 220.0
const EXTERIOR_TREE_RENDER_DISTANCE := 380.0
const EXTERIOR_TREE_NEAR_DISTANCE := 42.0
const EXTERIOR_COLLISION_DISTANCE := 18.0
const EXTERIOR_TERRAIN_COLLISION_DISTANCE := 65.0
const EXTERIOR_BATCH_SIZE_METERS := EXTERIOR_CELL_SIZE * 0.01
const EXTERIOR_OBJECT_BATCH_SIZE_METERS := EXTERIOR_CELL_SIZE * 0.08
const EXTERIOR_CAMERA_FAR := 430.0
const EXTERIOR_SHADOW_DISTANCE := 28.0
const STARTUP_NEAR_REFERENCE_DISTANCE := 18.0
const STARTUP_NEAR_TERRAIN_DISTANCE := 86.0
const NPC_NEAR_LOAD_DISTANCE := 18.0
const NPC_VISIBLE_LOAD_DISTANCE := 72.0
const UNSUPPORTED_PARTICLE_MODEL_FILENAMES := [
	"fxdustcloudfaint01.nif",
	"fxdustcloud01.nif",
	"dustcloudhorizontal01.nif",
	"fxlightbeamdust01.nif",
]
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
@onready var inventory_panel: PanelContainer = $StatusLayer/InventoryPanel
@onready var key_light: DirectionalLight3D = $KeyLight
@onready var inventory_items_container: VBoxContainer = $StatusLayer/InventoryPanel/Margin/Contents/Scroll/Items
@onready var interaction_hint_label: Label = $StatusLayer/InteractionHint
@onready var face_profile_label: Label = $StatusLayer/FaceProfile
@onready var face_view_button: Button = $StatusLayer/FaceView
@onready var fly_mode_button: Button = $StatusLayer/FlyMode
@onready var player: CharacterBody3D = $Player
@onready var world_environment: WorldEnvironment = $WorldEnvironment

var data_reader: Object
var current_cell: Dictionary = {}
var cell_visual_root: Node3D
var _model_cache: Dictionary = {}
var _nif_metadata_cache: Dictionary = {}
var _collision_cache: Dictionary = {}
var _material_cache: Dictionary = {}
var _texture_cache: Dictionary = {}
var _cell_load_generation := 0
var _deferred_world_generation := 0
var _npc_stream_generation := 0
var _npc_stream_enabled := false
var _npc_stream_busy := false
var _npc_stream_scan_cooldown := 0.0
var _npc_loaded_reference_ids: Dictionary = {}
var _player_deferred_assets_ready := false
var _player_deferred_assets_loading := false
var _cell_material: StandardMaterial3D
var _interior_environment: Environment
var _exterior_environment: Environment
var _land_mesh_cache: Dictionary = {}
var _land_collision_cache: Dictionary = {}
var _tree_mesh_cache: Dictionary = {}
var _water_material: StandardMaterial3D
var _world_loading := true
var _interact_ready := true
var _player_skeleton: Skeleton3D
var _player_avatar: Node3D
var _player_face_meshes: Array[MeshInstance3D] = []
var _player_hair_meshes: Array[MeshInstance3D] = []
var _player_body_meshes_by_slot: Dictionary = {0x0004: [], 0x0008: []}
var _player_face_source_meshes: Array[ArrayMesh] = []
var _player_facegen_mesh_data: Array[Dictionary] = []
var _player_face_profiles: Array[Dictionary] = []
var _player_face_profile_ids: Dictionary = {}
var _player_face_profile_index := 0
var _player_face_state: Dictionary = {}
var _player_animations: Dictionary = {}
var _player_inventory: Dictionary = {}
var _player_equipment: Dictionary = {}
var _player_weapon_meshes: Array[MeshInstance3D] = []
var _player_weapon_form_id := 0
var _inventory_open := false
var _placed_items: Dictionary = {}
var _linked_door_candidates: Array[Dictionary] = []
var _pickup_toast_text := ""
var _pickup_toast_remaining := 0.0
var _facegen_cache: Dictionary = {}
var _facegen_texture_cache: Dictionary = {}
var _race_texture_path_cache: Dictionary = {}
var _facegen_expression_names: Array[String] = []
var _active_animation := ""
var _animation_time := 0.0
var _player_animation_from_pose: Array[Dictionary] = []
var _player_animation_blend_elapsed := ANIMATION_BLEND_DURATION
var _player_was_on_floor := true
var _npc_actors: Array[Dictionary] = []
var _npc_pending_roots: Array[Node3D] = []
var _player_start_position := Vector3.ZERO
var _fallback_support: StaticBody3D

func _ready() -> void:
	player.set_physics_process(false)
	face_view_button.disabled = true
	face_view_button.pressed.connect(_toggle_face_view)
	cell_visual_root = Node3D.new()
	cell_visual_root.name = "StreamedCell"
	add_child(cell_visual_root)
	_cell_material = StandardMaterial3D.new()
	_cell_material.albedo_color = Color(0.62, 0.58, 0.5)
	_cell_material.roughness = 0.9
	_cell_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_interior_environment = world_environment.environment
	_exterior_environment = _make_exterior_environment()
	status_label.text = "OpenOB data reader starting…"
	fly_mode_button.pressed.connect(_toggle_fly_mode)
	_load_game_data()

func _make_exterior_environment() -> Environment:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.12, 0.22, 0.38)
	sky_material.sky_horizon_color = Color(0.58, 0.69, 0.78)
	sky_material.ground_bottom_color = Color(0.17, 0.19, 0.16)
	sky_material.ground_horizon_color = Color(0.48, 0.52, 0.48)
	var sky := Sky.new()
	sky.sky_material = sky_material
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	# A modest neutral fill keeps asset meshes readable in cast shadow. Sky-only
	# ambient is too weak for Oblivion's dark, texture-heavy NIFs in Godot's
	# compatibility renderer, while the directional sun still defines shadows.
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.58, 0.64, 0.74)
	environment.ambient_light_energy = 0.4
	return environment

func _set_cell_environment(cell: Dictionary) -> void:
	var is_exterior := not bool(cell.get("interior", true))
	world_environment.environment = _exterior_environment if is_exterior else _interior_environment
	key_light.visible = is_exterior
	var camera := player.get_node_or_null("CameraPivot/Camera3D") as Camera3D
	if camera != null:
		camera.far = EXTERIOR_CAMERA_FAR if is_exterior else 4000.0

func _process(_delta: float) -> void:
	_pickup_toast_remaining = maxf(0.0, _pickup_toast_remaining - _delta)
	var nearby_item: Dictionary = {}
	var nearby_door: Dictionary = {}
	if not _world_loading:
		nearby_item = _nearest_placed_item()
		nearby_door = _nearest_linked_door()
		_update_interaction_hint(nearby_item, nearby_door)
	if Input.is_action_just_released("interact"):
		_interact_ready = true
	if not _world_loading and not _inventory_open and _interact_ready and Input.is_action_just_pressed("interact"):
		_interact_ready = false
		if nearby_item.is_empty():
			if not nearby_door.is_empty():
				await _transition_to_linked_cell(nearby_door)
		else:
			await _pick_up_placed_item(nearby_item)
			if not Input.is_action_pressed("interact"):
				_interact_ready = true
	if not _world_loading and not current_cell.is_empty() and not bool(current_cell.get("interior", true)):
		await _stream_exterior_if_needed()
	if _player_skeleton != null and not _world_loading:
		if not _inventory_open:
			_update_player_animation(_delta)
		_update_npc_actors(_delta)
		_update_npc_streaming()
		if not _player_face_state.is_empty():
			_update_face_blink(_player_face_state, _delta)
			_update_face_expression(_player_face_state, _delta)
		if player.face_preview_enabled:
			player.update_face_preview_anchor(_player_face_camera_anchor())

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
	elif event.keycode == KEY_I:
		_toggle_inventory()
	elif event.keycode == KEY_T:
		_toggle_face_view()
	elif event.keycode == KEY_Y:
		_toggle_fly_mode()

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

	var sewer_exit_spawn: Dictionary = {}
	if OS.get_cmdline_user_args().has("--start-at-sewer-exit"):
		sewer_exit_spawn = _sewer_exit_start_data()
		if sewer_exit_spawn.is_empty():
			status_label.text = "Could not find the Imperial Sewer exit. Start without --start-at-sewer-exit to begin in the prison."
			return
		current_cell = sewer_exit_spawn.get("cell", {})
	else:
		current_cell = data_reader.find_cell(START_CELL_ID)
		if current_cell.is_empty():
			status_label.text = "Loaded game data, but %s was not found." % START_CELL_ID
			return

	var summary: Dictionary = data_reader.get_summary()
	var start_label := "Imperial Prison" if sewer_exit_spawn.is_empty() else "Imperial Sewer exit"
	status_label.text = "%s index ready (%d references, %d cells, %d archives). Loading NIF meshes…" % [
		start_label,
		current_cell.references.size(), summary.cell_count, summary.archive_count
	]
	print("OpenOB indexed %s: %d references, %d cells, %d archives" % [
		start_label, current_cell.references.size(), summary.cell_count, summary.archive_count
	])
	if not sewer_exit_spawn.is_empty():
		_player_start_position = sewer_exit_spawn.get("position", Vector3.ZERO)
		player.global_position = _player_start_position
		var spawn_rotation: Vector3 = sewer_exit_spawn.get("rotation", Vector3.ZERO)
		player.set_spawn_yaw(spawn_rotation.y)
	if sewer_exit_spawn.is_empty():
		_place_player_at_start(current_cell)
	else:
		print("OpenOB started at the sewer exit: %s" % str(player.global_position))
	await _load_player_avatar()
	await _load_cell_geometry(
		current_cell, 0.0,
		STARTUP_NEAR_REFERENCE_DISTANCE if bool(current_cell.get("interior", true)) else STARTUP_NEAR_TERRAIN_DISTANCE,
		true
	)
	await _place_player_on_ground(_player_start_position)
	player.set_physics_process(true)
	_world_loading = false
	_npc_stream_enabled = false
	face_view_button.disabled = false
	player.capture_mouse()
	_start_deferred_cell_loading()
	_log_runtime_spawn_positions()

func _sewer_exit_start_data() -> Dictionary:
	var sewer_cell: Dictionary = data_reader.find_cell("ImperialSewers03")
	if sewer_cell.is_empty():
		return {}
	var exit_cell: Dictionary = data_reader.find_cell("ICPrisonSewerExit01")
	if exit_cell.is_empty() or bool(exit_cell.get("interior", true)):
		return {}
	for reference: Dictionary in sewer_cell.get("references", []):
		if str(reference.get("base_editor_id", "")).to_lower() != "cgsewerexitgate01":
			continue
		var destination_cell: Dictionary = data_reader.find_cell_by_id(int(reference.get("teleport_cell_id", 0)))
		if destination_cell.is_empty() or bool(destination_cell.get("interior", true)):
			continue
		if int(destination_cell.get("worldspace_form_id", 0)) != int(exit_cell.get("worldspace_form_id", 0)):
			continue
		var destination: PackedFloat32Array = reference.get("teleport_position", PackedFloat32Array())
		if destination.size() < 3:
			continue
		var grid_x := floori(destination[0] / EXTERIOR_CELL_SIZE)
		var grid_y := floori(destination[1] / EXTERIOR_CELL_SIZE)
		if grid_x != int(exit_cell.get("grid_x", -1)) or grid_y != int(exit_cell.get("grid_y", -1)):
			continue
		var exterior_cell: Dictionary = data_reader.find_exterior_region(
			grid_x,
			grid_y,
			int(exit_cell.get("worldspace_form_id", 0)),
			EXTERIOR_STREAM_RADIUS,
			EXTERIOR_STATIC_REFERENCE_RADIUS,
			EXTERIOR_TREE_REFERENCE_RADIUS
		)
		if exterior_cell.is_empty():
			continue
		var rotation: PackedFloat32Array = reference.get("teleport_rotation", PackedFloat32Array())
		var spawn_rotation := Vector3.ZERO
		if rotation.size() >= 3:
			spawn_rotation = _reference_rotation(rotation).get_euler()
		return {
			"cell": exterior_cell,
			"position": Vector3(destination[0], destination[2], -destination[1]) * game_units_to_meters,
			"rotation": spawn_rotation,
		}
	return {}

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
		print("OpenOB spawn check after physics: player=%s; NPCs will stream when nearby or in view" % str(player.global_position))
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

func _load_cell_geometry(
	cell: Dictionary,
	min_distance: float = 0.0,
	max_distance: float = INF,
	clear_existing: bool = true
) -> bool:
	_cell_load_generation += 1
	var generation := _cell_load_generation
	_set_cell_environment(cell)
	if clear_existing:
		_placed_items.clear()
		_linked_door_candidates.clear()
		if has_node("TestFloor/MeshInstance3D"):
			$TestFloor/MeshInstance3D.visible = true
			$TestFloor/CollisionShape3D.disabled = false
		for child in cell_visual_root.get_children():
			child.queue_free()
		await get_tree().process_frame

	var instance_count := 0
	var reference_count := 0
	var collision_count := 0
	var culled_reference_count := 0
	var skipped_gate_count := 0
	var tree_reference_count := 0
	var exterior_batches: Dictionary = {}
	var exterior_batch_materials: Dictionary = {}
	var exterior_tree_batches: Dictionary = {}
	var is_exterior := not bool(cell.get("interior", true))
	var terrain_cells: Array = cell.get("land_cells", [])
	if terrain_cells.is_empty() and cell.has("land"):
		terrain_cells.push_back(cell.get("land"))
	for land_value: Variant in terrain_cells:
		if generation != _cell_load_generation:
			return false
		var land: Dictionary = land_value
		var land_position := Vector3(
			(float(land.get("grid_x", 0)) + 0.5) * EXTERIOR_CELL_SIZE,
			0.0,
			-(float(land.get("grid_y", 0)) + 0.5) * EXTERIOR_CELL_SIZE
		) * game_units_to_meters
		var land_distance := land_position.distance_to(player.global_position)
		if (min_distance > 0.0 and land_distance <= min_distance) or land_distance > max_distance:
			continue
		var land_result: Dictionary = await _add_land_cell(land, generation)
		if bool(land_result.get("rendered", false)):
			instance_count += 1
		if bool(land_result.get("collider", false)):
			collision_count += 1
	if generation != _cell_load_generation:
		return false
	if clear_existing and _add_water_region(cell.get("water_cells", [])):
		instance_count += 1
	for reference: Dictionary in cell.references:
		if generation != _cell_load_generation:
			return false
		var reference_transform := _reference_transform(reference)
		var reference_distance := reference_transform.origin.distance_to(player.global_position)
		if (min_distance > 0.0 and reference_distance <= min_distance) or reference_distance > max_distance:
			continue
		if int(reference.get("teleport_cell_id", 0)) != 0:
			var door_id := int(reference.get("form_id", 0))
			var already_added := false
			for door_candidate: Dictionary in _linked_door_candidates:
				if int(door_candidate.get("reference_id", 0)) == door_id:
					already_added = true
					break
			if not already_added:
				_linked_door_candidates.push_back({
					"reference_id": door_id,
					"reference": reference,
					"position": reference_transform.origin,
				})
		if is_exterior and bool(reference.get("is_tree", false)):
			var tree_distance := reference_transform.origin.distance_to(player.global_position)
			if tree_distance > EXTERIOR_TREE_RENDER_DISTANCE:
				culled_reference_count += 1
				continue
			var tree_width := float(reference.get("tree_billboard_width", 0.0))
			var tree_height := float(reference.get("tree_billboard_height", 0.0))
			var tree_texture_path := str(reference.get("tree_billboard_texture_path", ""))
			if tree_width <= 0.0 or tree_height <= 0.0 or tree_texture_path.is_empty():
				continue
			var use_single_billboard := tree_distance > EXTERIOR_TREE_NEAR_DISTANCE
			var tree_mesh := _tree_billboard_mesh(tree_width, tree_height, use_single_billboard)
			var tree_texture := await _texture_for_path(tree_texture_path)
			if generation != _cell_load_generation:
				return false
			if tree_mesh == null or tree_texture == null:
				continue
			var tree_material := await _material_for_texture(
				tree_texture_path, false, true, 128, use_single_billboard
			)
			if generation != _cell_load_generation:
				return false
			var batch_x := floori(reference_transform.origin.x / EXTERIOR_OBJECT_BATCH_SIZE_METERS)
			var batch_z := floori(reference_transform.origin.z / EXTERIOR_OBJECT_BATCH_SIZE_METERS)
			var tree_key := "%s|%.1f|%.1f|%s|%d|%d|%d" % [
				tree_texture_path.to_lower(), tree_width, tree_height,
				"far" if use_single_billboard else "cross", batch_x, batch_z, 0
			]
			var tree_batch: Dictionary = exterior_tree_batches.get(tree_key, {})
			if tree_batch.is_empty():
				tree_batch = {
					"mesh": tree_mesh,
					"mesh_name": "TreeBillboard",
					"material": tree_material,
					"origin": Vector3(
						batch_x * EXTERIOR_OBJECT_BATCH_SIZE_METERS,
						0.0,
						batch_z * EXTERIOR_OBJECT_BATCH_SIZE_METERS
					),
					"transforms": [],
					"cast_shadow": false,
				}
				exterior_tree_batches[tree_key] = tree_batch
			var tree_transform := reference_transform
			tree_transform.origin -= tree_batch.origin
			tree_batch.transforms.push_back(tree_transform)
			tree_reference_count += 1
			continue
		var model_path := str(reference.get("model_path", ""))
		if model_path.is_empty() or not model_path.to_lower().ends_with(".nif"):
			continue
		if is_exterior and reference_transform.origin.distance_to(player.global_position) > EXTERIOR_REFERENCE_RENDER_DISTANCE:
			culled_reference_count += 1
			continue
		if _is_early_oblivion_gate(reference, model_path):
			skipped_gate_count += 1
			continue
		var base_form_id := int(reference.get("base_form_id", 0))
		var base_type := str(data_reader.find_record_type(base_form_id))
		var is_pickup_item := base_type in ["ARMO", "CLOT", "WEAP", "ALCH", "AMMO", "APPA", "BOOK", "INGR", "KEYM", "MISC", "SLGM", "SGST"]
		reference_count += 1
		var meshes: Array = await _meshes_for_model(model_path)
		if generation != _cell_load_generation:
			return false
		var should_collide := (
			not is_pickup_item
			and _should_collide_model(model_path)
			and (not is_exterior or reference_transform.origin.distance_to(player.global_position) <= EXTERIOR_COLLISION_DISTANCE)
		)
		if should_collide:
			_ensure_collision_shape(model_path)
		var item_mesh_instances: Array[MeshInstance3D] = []
		for mesh_index in range(meshes.size()):
			var mesh_entry: Dictionary = meshes[mesh_index]
			var model_key := model_path.to_lower().replace("\\", "/")
			var can_batch := (
				is_exterior
				and not is_pickup_item
				and not _is_debug_service_model(model_path)
				and not bool(mesh_entry.get("alpha_blend", false))
			)
			if can_batch:
				var material_key := "%s|%d" % [model_key, mesh_index]
				var batch_material := exterior_batch_materials.get(material_key) as Material
				if batch_material == null:
					batch_material = await _material_for_reference(
						model_path,
						str(mesh_entry.diffuse_texture_path),
						bool(mesh_entry.get("alpha_blend", false)),
						bool(mesh_entry.get("alpha_test", false)),
						int(mesh_entry.get("alpha_threshold", 128))
					)
					if generation != _cell_load_generation:
						return false
					exterior_batch_materials[material_key] = batch_material
				var batch_x := floori(reference_transform.origin.x / EXTERIOR_OBJECT_BATCH_SIZE_METERS)
				var batch_z := floori(reference_transform.origin.z / EXTERIOR_OBJECT_BATCH_SIZE_METERS)
				var batch_key := "%s|%d|%d" % [material_key, batch_x, batch_z]
				var batch: Dictionary = exterior_batches.get(batch_key, {})
				if batch.is_empty():
					batch = {
						"mesh": mesh_entry.mesh,
						"mesh_name": str(mesh_entry.get("mesh_name", "Mesh")),
						"material": batch_material,
						"origin": Vector3(
							batch_x * EXTERIOR_OBJECT_BATCH_SIZE_METERS,
							0.0,
							batch_z * EXTERIOR_OBJECT_BATCH_SIZE_METERS
						),
						"transforms": [],
						"cast_shadow": true,
					}
					exterior_batches[batch_key] = batch
				var relative_transform := reference_transform
				relative_transform.origin -= batch.origin
				batch.transforms.push_back(relative_transform)
			else:
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
				if generation != _cell_load_generation:
					return false
				instance.transform = reference_transform
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
				"position": reference_transform.origin,
				"mesh_instances": item_mesh_instances,
			}
		if should_collide:
			var model_key := model_path.to_lower().replace("\\", "/")
			var collision_shape := _collision_cache.get(model_key) as ConcavePolygonShape3D
			if collision_shape != null:
				var static_body := StaticBody3D.new()
				static_body.name = "GeneratedStaticMeshCollision"
				static_body.collision_layer = 2
				static_body.collision_mask = 0
				static_body.transform = reference_transform
				var collision_instance := CollisionShape3D.new()
				collision_instance.shape = collision_shape
				static_body.add_child(collision_instance)
				cell_visual_root.add_child(static_body)
				collision_count += 1
		if reference_count % 8 == 0:
			status_label.text = "Loading %s: %d placed NIF references, %d visible meshes…" % [
				cell.get("editor_id", "cell"), reference_count, instance_count
			]
			await get_tree().process_frame

	for batches: Dictionary in [exterior_batches, exterior_tree_batches]:
		for batch_key: String in batches:
			var batch: Dictionary = batches[batch_key]
			var transforms: Array = batch.transforms
			if transforms.is_empty():
				continue
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.mesh = batch.mesh
			multimesh.instance_count = transforms.size()
			for transform_index in range(transforms.size()):
				multimesh.set_instance_transform(transform_index, transforms[transform_index])
			multimesh.custom_aabb = AABB(
				Vector3(-20.0, -100.0, -20.0),
				Vector3(EXTERIOR_OBJECT_BATCH_SIZE_METERS + 40.0, 200.0, EXTERIOR_OBJECT_BATCH_SIZE_METERS + 40.0)
			)
			var batch_instance := MultiMeshInstance3D.new()
			batch_instance.name = "ExteriorBatch_" + str(batch.mesh_name).replace(":", "_")
			batch_instance.multimesh = multimesh
			batch_instance.material_override = batch.material
			batch_instance.position = batch.origin
			if not bool(batch.get("cast_shadow", true)) or batch.origin.distance_to(player.global_position) > EXTERIOR_SHADOW_DISTANCE:
				batch_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			cell_visual_root.add_child(batch_instance)
			instance_count += 1

	if generation != _cell_load_generation:
		return false
	if clear_existing and has_node("TestFloor/MeshInstance3D"):
		$TestFloor/MeshInstance3D.visible = collision_count == 0
		$TestFloor/CollisionShape3D.disabled = collision_count > 0
	var cell_label := str(cell.get("display_name", ""))
	if cell_label.is_empty():
		cell_label = "Cell %d,%d" % [int(cell.get("grid_x", 0)), int(cell.get("grid_y", 0))]
	status_label.text = "Cell: %s (%d references, %d meshes, %d generated colliders, %d tree billboards).\nWASD move · Shift run · Space jump · E pick up item / follow door\nMouse turns player · wheel/trackpad zoom · I inventory · V camera mode · C face profile · G player expression · F NPC expression · Esc release mouse\nOriginal textures, rig, and movement KF load from the game files; Havok collision and game scale remain unverified." % [
		cell_label, cell.references.size(), instance_count, collision_count, tree_reference_count
	]
	_update_interaction_hint({}, {})
	_refresh_inventory_hud()
	print("OpenOB displayed %s: %d NIF references, %d tree billboards, %d meshes, %d terrain tiles; culled %d distant references, skipped %d gates" % [
		cell_label, reference_count, tree_reference_count, instance_count, terrain_cells.size(), culled_reference_count, skipped_gate_count
	])
	print("OpenOB indexed %d nearby-pickup candidates in %s" % [_placed_items.size(), str(cell.get("editor_id", "cell"))])
	return true

func _add_land_cell(land: Dictionary, generation: int = -1) -> Dictionary:
	var heights: PackedFloat32Array = land.get("heights", PackedFloat32Array())
	if heights.size() != 33 * 33:
		return {}
	var grid_x := int(land.get("grid_x", 0))
	var grid_y := int(land.get("grid_y", 0))
	var position := Vector3(grid_x * EXTERIOR_CELL_SIZE, 0.0, -grid_y * EXTERIOR_CELL_SIZE) * game_units_to_meters
	var terrain_center := position + Vector3(EXTERIOR_BATCH_SIZE_METERS * 0.5, 0.0, -EXTERIOR_BATCH_SIZE_METERS * 0.5)
	var terrain_distance := terrain_center.distance_to(player.global_position)
	var detail_step := 1 if terrain_distance <= 110.0 else 2 if terrain_distance <= 220.0 else 4
	var mesh_key := "%d,%d,%d" % [grid_x, grid_y, detail_step]
	var cache_key := "%d,%d" % [grid_x, grid_y]
	var mesh := _land_mesh_cache.get(mesh_key) as ArrayMesh
	if mesh == null:
		mesh = _build_land_mesh(heights, detail_step)
		if mesh == null:
			return {}
		_land_mesh_cache[mesh_key] = mesh
	var instance := MeshInstance3D.new()
	instance.name = "Terrain_%d_%d" % [grid_x, grid_y]
	instance.mesh = mesh
	var texture_path := str(land.get("texture_path", ""))
	if texture_path.is_empty():
		texture_path = "textures/landscape/terrainhddirt01.dds"
	instance.material_override = await _material_for_texture(texture_path)
	if generation >= 0 and generation != _cell_load_generation:
		return {}
	instance.scale = Vector3.ONE * game_units_to_meters
	instance.position = position
	cell_visual_root.add_child(instance)

	var collision := _land_collision_cache.get(cache_key) as ConcavePolygonShape3D
	if terrain_center.distance_to(player.global_position) > EXTERIOR_TERRAIN_COLLISION_DISTANCE:
		return {"rendered": true, "collider": false}
	if collision == null:
		collision = _build_concave_shape(mesh.get_faces())
		if collision != null:
			_land_collision_cache[cache_key] = collision
	if collision != null:
		var body := StaticBody3D.new()
		body.name = "TerrainCollision_%d_%d" % [grid_x, grid_y]
		body.collision_layer = 2
		body.collision_mask = 0
		body.scale = Vector3.ONE * game_units_to_meters
		body.position = instance.position
		var collision_instance := CollisionShape3D.new()
		collision_instance.shape = collision
		body.add_child(collision_instance)
		cell_visual_root.add_child(body)
	return {"rendered": true, "collider": collision != null}

func _build_land_mesh(heights: PackedFloat32Array, step := 1) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for y in range(0, 32, step):
		for x in range(0, 32, step):
			var top_left := _land_vertex(x, y, heights)
			var top_right := _land_vertex(x + step, y, heights)
			var bottom_left := _land_vertex(x, y + step, heights)
			var bottom_right := _land_vertex(x + step, y + step, heights)
			var uv_top_left := Vector2(float(x) * 12.0 / 32.0, float(y) * 12.0 / 32.0)
			var uv_top_right := Vector2(float(x + step) * 12.0 / 32.0, float(y) * 12.0 / 32.0)
			var uv_bottom_left := Vector2(float(x) * 12.0 / 32.0, float(y + step) * 12.0 / 32.0)
			var uv_bottom_right := Vector2(float(x + step) * 12.0 / 32.0, float(y + step) * 12.0 / 32.0)
			surface.set_uv(uv_top_left)
			surface.add_vertex(top_left)
			surface.set_uv(uv_top_right)
			surface.add_vertex(top_right)
			surface.set_uv(uv_bottom_left)
			surface.add_vertex(bottom_left)
			surface.set_uv(uv_top_right)
			surface.add_vertex(top_right)
			surface.set_uv(uv_bottom_right)
			surface.add_vertex(bottom_right)
			surface.set_uv(uv_bottom_left)
			surface.add_vertex(bottom_left)
	surface.index()
	surface.generate_normals()
	return surface.commit() as ArrayMesh

func _land_vertex(x: int, y: int, heights: PackedFloat32Array) -> Vector3:
	return Vector3(float(x) * 128.0, heights[y * 33 + x], -float(y) * 128.0)

func _add_water_region(water_cells: Array) -> bool:
	if water_cells.is_empty():
		return false
	if _water_material == null:
		_water_material = StandardMaterial3D.new()
		_water_material.albedo_color = Color(0.08, 0.3, 0.43, 0.72)
		_water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_water_material.roughness = 0.24
		_water_material.metallic = 0.08
		_water_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var height_groups: Dictionary = {}
	for water_value: Variant in water_cells:
		var water: Dictionary = water_value
		var grid_x := int(water.get("grid_x", 0))
		var grid_y := int(water.get("grid_y", 0))
		var height_key := roundi(float(water.get("height", 0.0)) * 100.0)
		var group: Dictionary = height_groups.get(height_key, {
			"min_x": grid_x, "max_x": grid_x, "min_y": grid_y, "max_y": grid_y
		})
		group.min_x = mini(int(group.min_x), grid_x)
		group.max_x = maxi(int(group.max_x), grid_x)
		group.min_y = mini(int(group.min_y), grid_y)
		group.max_y = maxi(int(group.max_y), grid_y)
		height_groups[height_key] = group
	for height_key: int in height_groups:
		var group: Dictionary = height_groups[height_key]
		var min_x := int(group.min_x)
		var min_y := int(group.min_y)
		var width := int(group.max_x) - min_x + 1
		var depth := int(group.max_y) - min_y + 1
		var plane := PlaneMesh.new()
		plane.size = Vector2(width * EXTERIOR_CELL_SIZE, depth * EXTERIOR_CELL_SIZE)
		var instance := MeshInstance3D.new()
		instance.name = "WaterRegion_%d" % height_key
		instance.mesh = plane
		instance.material_override = _water_material
		instance.scale = Vector3.ONE * game_units_to_meters
		instance.position = Vector3(
			(min_x + float(width) * 0.5) * EXTERIOR_CELL_SIZE,
			float(height_key) / 100.0,
			-(min_y + float(depth) * 0.5) * EXTERIOR_CELL_SIZE
		) * game_units_to_meters
		cell_visual_root.add_child(instance)
	return true

func _tree_billboard_mesh(width: float, height: float, single_billboard: bool) -> ArrayMesh:
	var normalized_width := snappedf(width, 0.1)
	var normalized_height := snappedf(height, 0.1)
	var key := "%.1f,%.1f,%s" % [normalized_width, normalized_height, "single" if single_billboard else "cross"]
	if _tree_mesh_cache.has(key):
		return _tree_mesh_cache[key] as ArrayMesh
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_tree_billboard_quad(surface, Vector3(-normalized_width * 0.5, 0.0, 0.0), Vector3(normalized_width * 0.5, 0.0, 0.0), Vector3(-normalized_width * 0.5, normalized_height, 0.0), Vector3(normalized_width * 0.5, normalized_height, 0.0))
	if not single_billboard:
		_append_tree_billboard_quad(surface, Vector3(0.0, 0.0, -normalized_width * 0.5), Vector3(0.0, 0.0, normalized_width * 0.5), Vector3(0.0, normalized_height, -normalized_width * 0.5), Vector3(0.0, normalized_height, normalized_width * 0.5))
	surface.index()
	surface.generate_normals()
	var mesh := surface.commit() as ArrayMesh
	_tree_mesh_cache[key] = mesh
	return mesh

func _append_tree_billboard_quad(surface: SurfaceTool, bottom_left: Vector3, bottom_right: Vector3, top_left: Vector3, top_right: Vector3) -> void:
	surface.set_uv(Vector2(0.0, 1.0))
	surface.add_vertex(bottom_left)
	surface.set_uv(Vector2(1.0, 1.0))
	surface.add_vertex(bottom_right)
	surface.set_uv(Vector2(0.0, 0.0))
	surface.add_vertex(top_left)
	surface.set_uv(Vector2(1.0, 1.0))
	surface.add_vertex(bottom_right)
	surface.set_uv(Vector2(1.0, 0.0))
	surface.add_vertex(top_right)
	surface.set_uv(Vector2(0.0, 0.0))
	surface.add_vertex(top_left)

func _is_early_oblivion_gate(reference: Dictionary, model_path: String) -> bool:
	var identifiers := ("%s %s %s %s" % [
		str(reference.get("editor_id", "")),
		str(reference.get("base_editor_id", "")),
		str(reference.get("reference_name", "")),
		model_path,
	]).to_lower().replace("_", "").replace(" ", "")
	return (identifiers.contains("oblivion") and identifiers.contains("gate")) or identifiers.contains("obgate")

func _stream_exterior_if_needed() -> void:
	var worldspace_form_id := int(current_cell.get("worldspace_form_id", 0))
	var cell_size_meters := EXTERIOR_CELL_SIZE * game_units_to_meters
	var grid_x := floori(player.global_position.x / cell_size_meters)
	var grid_y := floori(-player.global_position.z / cell_size_meters)
	var loaded_grid_x := int(current_cell.get("grid_x", 0))
	var loaded_grid_y := int(current_cell.get("grid_y", 0))
	if abs(grid_x - loaded_grid_x) < EXTERIOR_RELOAD_GRID_DISTANCE and abs(grid_y - loaded_grid_y) < EXTERIOR_RELOAD_GRID_DISTANCE:
		return
	var exterior_region: Dictionary = data_reader.find_exterior_region(
		grid_x, grid_y, worldspace_form_id, EXTERIOR_STREAM_RADIUS,
		EXTERIOR_STATIC_REFERENCE_RADIUS, EXTERIOR_TREE_REFERENCE_RADIUS
	)
	if exterior_region.is_empty():
		return
	_deferred_world_generation += 1
	_npc_stream_enabled = false
	_world_loading = true
	player.set_physics_process(false)
	_clear_cell_actors()
	current_cell = exterior_region
	await _load_cell_geometry(current_cell, 0.0, STARTUP_NEAR_TERRAIN_DISTANCE, true)
	await _place_player_on_ground(player.global_position)
	player.set_physics_process(true)
	_world_loading = false
	_start_deferred_cell_loading()

func _meshes_for_model(model_path: String) -> Array:
	var key := model_path.to_lower().replace("\\", "/")
	if _model_cache.has(key):
		return _model_cache[key]
	# These original particle effect NIFs are not static meshes and the reader cannot decode them.
	if key.get_file() in UNSUPPORTED_PARTICLE_MODEL_FILENAMES:
		_model_cache[key] = []
		return []
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
	for index in range(raw_meshes.size()):
		var mesh_data: Dictionary = raw_meshes[index]
		var builder := Callable(self, "_build_godot_mesh").bind(mesh_data)
		var resource := DerivedResourceCache.load_or_build(
			source_bytes, "nif-arraymesh-normal-orientation-v2-%d" % index, builder
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
	_model_cache[key] = godot_meshes
	return godot_meshes

func _ensure_collision_shape(model_path: String) -> void:
	var key := model_path.to_lower().replace("\\", "/")
	if _collision_cache.has(key):
		return
	var collision_faces := PackedVector3Array()
	for mesh_entry: Dictionary in _model_cache.get(key, []):
		var shape_name := str(mesh_entry.get("mesh_name", "")).to_lower()
		if shape_name.contains("sky") or shape_name.contains("lightbeam") or shape_name.contains("dust"):
			continue
		var mesh := mesh_entry.get("mesh") as ArrayMesh
		if mesh != null:
			collision_faces.append_array(mesh.get_faces())
	_collision_cache[key] = _build_concave_shape(collision_faces)

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
	_player_hair_meshes.clear()
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
	var loaded_animation_names: Array[String] = []
	for animation_name_value: Variant in _player_animations.keys():
		var animation_name := str(animation_name_value)
		if _player_animations[animation_name].is_empty():
			push_warning("Original player KF sequence %s was not found" % animation_name)
		else:
			loaded_animation_names.push_back(animation_name)
	_initialize_player_face_profiles()
	var part_count := 0
	var player_model_paths: Array[String] = []
	for model_path_value: Variant in PLAYER_AVATAR_PARTS:
		player_model_paths.push_back(str(model_path_value))
	for model_path: String in player_model_paths:
		var meshes: Array = await _meshes_for_model(model_path)
		var part_mesh_count := 0
		var is_face_model := model_path == PLAYER_FACE_HEAD_MODEL or PLAYER_FACE_DETAIL_PARTS.has(model_path)
		var is_player_hair := model_path.to_lower() == PLAYER_HAIR_MODEL.to_lower()
		var facegen_data: Dictionary = _ensure_facegen_data(model_path) if is_face_model else {}
		var attachment: Node3D = avatar
		if (PLAYER_FACE_DETAIL_PARTS.has(model_path) or is_player_hair) and _player_skeleton != null:
			var head_attachment := BoneAttachment3D.new()
			head_attachment.name = model_path.get_file().get_basename() + "Attachment"
			head_attachment.bone_name = "Bip01 Head"
			_player_skeleton.add_child(head_attachment)
			attachment = head_attachment
			if PLAYER_FACE_DETAIL_PARTS.has(model_path):
				var face_detail_to_head := Node3D.new()
				face_detail_to_head.name = "FaceDetailToHeadSpace"
				face_detail_to_head.transform = _player_face_detail_to_head_transform(model_path)
				head_attachment.add_child(face_detail_to_head)
				attachment = face_detail_to_head
			elif is_player_hair:
				var head_bone_index := _player_skeleton.find_bone("Bip01 Head")
				if head_bone_index >= 0:
					var hair_model_to_head := Node3D.new()
					hair_model_to_head.name = "HairModelToHeadSpace"
					hair_model_to_head.transform = _player_skeleton.get_bone_global_rest(head_bone_index).affine_inverse()
					head_attachment.add_child(hair_model_to_head)
					attachment = hair_model_to_head
		for mesh_entry: Dictionary in meshes:
			var instance := MeshInstance3D.new()
			var mesh_name := str(mesh_entry.get("mesh_name", "Mesh"))
			instance.name = model_path.get_file().get_basename() + "_" + mesh_name.replace(":", "_")
			var source_mesh := mesh_entry.mesh as ArrayMesh
			instance.mesh = source_mesh
			if is_face_model:
				_player_face_meshes.push_back(instance)
				_player_face_source_meshes.push_back(source_mesh)
				_player_facegen_mesh_data.push_back(facegen_data)
			if is_player_hair:
				_player_hair_meshes.push_back(instance)
			if model_path.to_lower() == PLAYER_AVATAR_PARTS[0].to_lower():
				_player_body_meshes_by_slot[0x0004].push_back(instance)
			elif model_path.to_lower() == PLAYER_AVATAR_PARTS[1].to_lower():
				_player_body_meshes_by_slot[0x0008].push_back(instance)
			instance.material_override = await _material_for_texture(
				str(mesh_entry.diffuse_texture_path),
				bool(mesh_entry.get("alpha_blend", false)),
				bool(mesh_entry.get("alpha_test", false)),
				int(mesh_entry.get("alpha_threshold", 128))
			)
			if model_path.to_lower() == PLAYER_FACE_HEAD_MODEL.to_lower():
				# Skinning moves the head around its rig rest pose. A generous local
				# bound prevents the renderer from dropping it during close, low-angle
				# face inspection, when only a small part of the head bounds is on screen.
				instance.custom_aabb = source_mesh.get_aabb().grow(PLAYER_HEAD_CULL_MARGIN)
			attachment.add_child(instance)
			var bone_names: Array = mesh_entry.get("bone_names", [])
			if _player_skeleton != null and not bone_names.is_empty():
				instance.skeleton = NodePath("../Skeleton3D")
				instance.skin = _skin_for_mesh(bone_names, _player_skeleton)
			part_count += 1
			part_mesh_count += 1
		print("OpenOB player model %s: %d mesh(es)" % [model_path, part_mesh_count])
		if part_mesh_count == 0 and (is_face_model or model_path == PLAYER_AVATAR_PARTS.back()):
			push_warning("Player appearance part did not load: %s" % model_path)
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
	_active_animation = ""
	_player_was_on_floor = true
	if part_count > 0:
		var body_proxy := player.get_node_or_null("BodyProxy") as MeshInstance3D
		if body_proxy != null:
			body_proxy.visible = false
		status_label.text += "\nOriginal Imperial male rig loaded (%d body/head shapes, %d bones); idle KF ready, other movement animations loading in background.\nLoaded %d base-game clothing pieces." % [
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

func _load_player_face_detail_part(model_path: String) -> void:
	var meshes: Array = await _meshes_for_model(model_path)
	var facegen_data := _ensure_facegen_data(model_path)
	var head_attachment := BoneAttachment3D.new()
	head_attachment.name = model_path.get_file().get_basename() + "Attachment"
	head_attachment.bone_name = "Bip01 Head"
	var attachment: Node3D = _player_avatar
	if _player_skeleton != null:
		_player_skeleton.add_child(head_attachment)
		var face_detail_to_head := Node3D.new()
		face_detail_to_head.name = "FaceDetailToHeadSpace"
		face_detail_to_head.transform = _player_face_detail_to_head_transform(model_path)
		head_attachment.add_child(face_detail_to_head)
		attachment = face_detail_to_head
	for mesh_entry: Dictionary in meshes:
		var instance := MeshInstance3D.new()
		var mesh_name := str(mesh_entry.get("mesh_name", "Mesh"))
		instance.name = model_path.get_file().get_basename() + "_" + mesh_name.replace(":", "_")
		var source_mesh := mesh_entry.mesh as ArrayMesh
		instance.mesh = source_mesh
		_player_face_meshes.push_back(instance)
		_player_face_source_meshes.push_back(source_mesh)
		_player_facegen_mesh_data.push_back(facegen_data)
		instance.material_override = await _material_for_texture(
			str(mesh_entry.diffuse_texture_path),
			bool(mesh_entry.get("alpha_blend", false)),
			bool(mesh_entry.get("alpha_test", false)),
			int(mesh_entry.get("alpha_threshold", 128))
		)
		attachment.add_child(instance)
		var bone_names: Array = mesh_entry.get("bone_names", [])
		if _player_skeleton != null and not bone_names.is_empty():
			instance.skeleton = NodePath("../Skeleton3D")
			instance.skin = _skin_for_mesh(bone_names, _player_skeleton)

func _load_deferred_player_assets() -> void:
	if _player_avatar == null or _player_skeleton == null:
		return
	for model_path_value: Variant in PLAYER_FACE_DETAIL_PARTS:
		await _load_player_face_detail_part(str(model_path_value))
	_player_face_state["expression_cycle"] = _available_face_expression_cycle(_player_face_meshes)
	_apply_face_expression(_player_face_state)
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
	print("OpenOB loaded deferred player face parts and %d original movement animations" % _player_animations.size())

func _start_deferred_cell_loading() -> void:
	_deferred_world_generation += 1
	_npc_stream_enabled = false
	_load_deferred_cell_assets(_deferred_world_generation, current_cell)

func _load_deferred_cell_assets(generation: int, cell: Dictionary) -> void:
	while _player_deferred_assets_loading:
		await get_tree().process_frame
		if generation != _deferred_world_generation:
			return
	if not _player_deferred_assets_ready:
		_player_deferred_assets_loading = true
		await _load_deferred_player_assets()
		_player_deferred_assets_loading = false
		_player_deferred_assets_ready = true
	if generation != _deferred_world_generation:
		return
	var is_exterior := not bool(cell.get("interior", true))
	var near_distance := STARTUP_NEAR_REFERENCE_DISTANCE if not is_exterior else STARTUP_NEAR_TERRAIN_DISTANCE
	var far_distance := INF if not is_exterior else EXTERIOR_CAMERA_FAR
	status_label.text = "Loading the rest of %s while you can explore…" % str(cell.get("display_name", cell.get("editor_id", "cell")))
	var geometry_complete: bool = await _load_cell_geometry(cell, near_distance, far_distance, false)
	if not geometry_complete or generation != _deferred_world_generation:
		return
	_npc_stream_enabled = true
	print("OpenOB nearby world pass complete; NPC streaming enabled for %s" % str(cell.get("editor_id", "cell")))

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
	var normalized_head_path := head_model_path.to_lower().replace("\\", "/")
	if normalized_head_path != PLAYER_FACE_HEAD_MODEL.to_lower():
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
	var applied_part_count := 0
	var applied_eye_count := 0
	# Eye NIFs have their own EGM/TRI vertex bases; rebuild each face part with
	# the selected NPC coefficients instead of reusing the head's generated mesh.
	for index in range(mini(_player_face_meshes.size(), _player_face_source_meshes.size())):
		var instance := _player_face_meshes[index]
		if not is_instance_valid(instance):
			continue
		var facegen_data: Dictionary = _player_facegen_mesh_data[index]
		if facegen_data.is_empty():
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
			if instance.name.to_lower().begins_with("headhuman_"):
				# Reapply after replacing the mesh so the skinned head keeps its
				# pose-safe bounds with every selected FaceGen profile.
				instance.custom_aabb = _player_face_source_meshes[index].get_aabb().grow(PLAYER_HEAD_CULL_MARGIN)
			applied_part_count += 1
			if instance.name.to_lower().contains("eye"):
				applied_eye_count += 1
		else:
			push_warning("Could not apply face profile %s to %s" % [str(profile.get("name", "?")), instance.name])
	print("OpenOB applied face profile %s to %d face parts, including %d eye meshes" % [
		str(profile.get("name", "?")), applied_part_count, applied_eye_count
	])
	if not _player_face_state.is_empty():
		_apply_face_expression(_player_face_state)
		var expression_name := str(_player_face_state.get("face_expression", ""))
		if not expression_name.is_empty():
			_set_actor_face_shape(
				_player_face_state,
				expression_name,
				float(_player_face_state.get("face_expression_weight", 0.0))
			)

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
		_player_weapon_form_id = form_id
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
	_refresh_player_hair_visibility()
	_refresh_player_body_visibility()
	return true

func _refresh_player_body_visibility() -> void:
	var covered_slots := 0
	for equipment_value: Variant in _player_equipment.values():
		var equipment: Dictionary = equipment_value
		covered_slots |= int(equipment.get("slots", 0))
	for slot_value: Variant in _player_body_meshes_by_slot.keys():
		var slot := int(slot_value)
		for body_mesh_value: Variant in _player_body_meshes_by_slot[slot]:
			var body_mesh := body_mesh_value as MeshInstance3D
			if is_instance_valid(body_mesh):
				body_mesh.visible = (covered_slots & slot) == 0

func _refresh_player_hair_visibility() -> void:
	var headwear_equipped := false
	for equipment_value: Variant in _player_equipment.values():
		var equipment: Dictionary = equipment_value
		if (int(equipment.get("slots", 0)) & 0x0003) != 0:
			headwear_equipped = true
			break
	for hair_mesh: MeshInstance3D in _player_hair_meshes:
		if is_instance_valid(hair_mesh):
			hair_mesh.visible = not headwear_equipped

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

func _nearest_linked_door() -> Dictionary:
	var nearest_door: Dictionary = {}
	var nearest_distance_squared := LINKED_DOOR_INTERACTION_DISTANCE * LINKED_DOOR_INTERACTION_DISTANCE
	var player_position := player.global_position
	for candidate: Dictionary in _linked_door_candidates:
		var reference: Dictionary = candidate.reference
		var door_position: Vector3 = candidate.position
		var horizontal_offset := Vector2(
			player_position.x - door_position.x,
			player_position.z - door_position.z
		)
		var distance_squared := horizontal_offset.length_squared()
		if distance_squared < nearest_distance_squared:
			nearest_distance_squared = distance_squared
			nearest_door = reference
	return nearest_door

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
	var inventory_form_ids: Array[int] = []
	for child in inventory_items_container.get_children():
		child.queue_free()
	for amount_value: Variant in _player_inventory.values():
		item_count += int(amount_value)
	for form_id_value: Variant in _player_inventory.keys():
		inventory_form_ids.push_back(int(form_id_value))
	inventory_form_ids.sort()
	for form_id: int in inventory_form_ids:
		var item_name := str(data_reader.find_editor_id(form_id)) if data_reader != null else ""
		if item_name.is_empty():
			item_name = "Item %08X" % form_id
		var item_type := str(data_reader.find_record_type(form_id)) if data_reader != null else ""
		var equipped := _player_equipment.has(form_id) or _player_weapon_form_id == form_id
		var equipped_label := " · equipped" if equipped else ""
		var item_button := Button.new()
		item_button.text = "%s  %s ×%d%s" % [item_type, item_name, int(_player_inventory[form_id]), equipped_label]
		item_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		item_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item_button.disabled = item_type not in ["ARMO", "CLOT", "WEAP"]
		if not item_button.disabled:
			item_button.pressed.connect(_equip_inventory_item.bind(form_id))
		inventory_items_container.add_child(item_button)
	if inventory_form_ids.is_empty():
		var empty_label := Label.new()
		empty_label.text = "Empty"
		inventory_items_container.add_child(empty_label)
	inventory_label.text = "Inventory: %d items · %d types" % [item_count, _player_inventory.size()]

func _equip_inventory_item(form_id: int) -> void:
	if _world_loading or not _inventory_open:
		return
	if await _equip_player_item(form_id):
		_refresh_inventory_hud()

func _toggle_inventory() -> void:
	if _world_loading:
		return
	_inventory_open = not _inventory_open
	inventory_panel.visible = _inventory_open
	player.set_physics_process(not _inventory_open)
	if _inventory_open:
		player.release_mouse()
	else:
		player.capture_mouse()

func _toggle_face_view() -> void:
	if _world_loading or _inventory_open:
		return
	var enabled := bool(player.toggle_face_preview(_player_face_camera_anchor()))
	face_view_button.text = "T · Behind player" if enabled else "T · Face view"

func _toggle_fly_mode() -> void:
	if _world_loading or _inventory_open:
		return
	var enable_fly_mode: bool = not player.is_flying
	if not enable_fly_mode:
		var resume_physics := player.is_physics_processing()
		player.set_physics_process(false)
		_ensure_nearby_terrain_collisions()
		await get_tree().physics_frame
		player.set_fly_mode(false)
		_snap_player_to_nearby_floor()
		player.set_physics_process(resume_physics)
	else:
		player.set_fly_mode(true)
	fly_mode_button.text = "Y · Fly: On" if player.is_flying else "Y · Fly: Off"

func _ensure_nearby_terrain_collisions() -> void:
	if current_cell.is_empty() or bool(current_cell.get("interior", true)):
		return
	var cell_size_meters := EXTERIOR_CELL_SIZE * game_units_to_meters
	var player_grid_x := floori(player.global_position.x / cell_size_meters)
	var player_grid_y := floori(-player.global_position.z / cell_size_meters)
	var terrain_cells: Array = current_cell.get("land_cells", [])
	if terrain_cells.is_empty() and current_cell.has("land"):
		terrain_cells.push_back(current_cell.get("land"))
	for land_value: Variant in terrain_cells:
		var land: Dictionary = land_value
		var grid_x := int(land.get("grid_x", 0))
		var grid_y := int(land.get("grid_y", 0))
		if abs(grid_x - player_grid_x) > 1 or abs(grid_y - player_grid_y) > 1:
			continue
		var body_name := "TerrainCollision_%d_%d" % [grid_x, grid_y]
		if cell_visual_root.has_node(NodePath(body_name)):
			continue
		var heights: PackedFloat32Array = land.get("heights", PackedFloat32Array())
		if heights.size() != 33 * 33:
			continue
		var cache_key := "%d,%d" % [grid_x, grid_y]
		var collision := _land_collision_cache.get(cache_key) as ConcavePolygonShape3D
		if collision == null:
			var terrain_mesh := _build_land_mesh(heights, 1)
			if terrain_mesh == null:
				continue
			collision = _build_concave_shape(terrain_mesh.get_faces())
			if collision == null:
				continue
			_land_collision_cache[cache_key] = collision
		var body := StaticBody3D.new()
		body.name = body_name
		body.collision_layer = 2
		body.collision_mask = 0
		body.scale = Vector3.ONE * game_units_to_meters
		body.position = Vector3(grid_x * EXTERIOR_CELL_SIZE, 0.0, -grid_y * EXTERIOR_CELL_SIZE) * game_units_to_meters
		var collision_instance := CollisionShape3D.new()
		collision_instance.shape = collision
		body.add_child(collision_instance)
		cell_visual_root.add_child(body)

func _snap_player_to_nearby_floor() -> void:
	var query := PhysicsRayQueryParameters3D.create(
		player.global_position + Vector3.UP * 1.2,
		player.global_position - Vector3.UP * 2.5,
		2,
		[player.get_rid()]
	)
	query.collide_with_areas = false
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty() or Vector3(result.get("normal", Vector3.UP)).dot(Vector3.UP) < 0.55:
		return
	var floor_position: Vector3 = result.get("position", player.global_position)
	if absf(floor_position.y - player.global_position.y) > 2.0:
		return
	player.global_position.y = floor_position.y + 0.02
	player.velocity = Vector3.ZERO
	player.force_update_transform()

func _player_face_camera_anchor() -> Vector3:
	if _player_skeleton == null:
		return Vector3(0.0, 1.5, 0.0)
	var head_bone_index := _player_skeleton.find_bone("Bip01 Head")
	if head_bone_index < 0:
		return Vector3(0.0, 1.5, 0.0)
	var head_pose := _player_skeleton.get_bone_global_pose(head_bone_index)
	var model_to_head := _player_head_model_to_head_transform()
	var face_target_in_skeleton := head_pose * (model_to_head * Vector3(0.0, 4.0, -9.5))
	return player.to_local(_player_skeleton.to_global(face_target_in_skeleton))


func _player_face_detail_to_head_transform(model_path: String) -> Transform3D:
	var normalized_path := model_path.to_lower()
	if normalized_path.ends_with("eyeleftHuman.nif".to_lower()) or normalized_path.ends_with("eyerightHuman.nif".to_lower()):
		return _player_head_model_to_head_transform()
	return Transform3D.IDENTITY

func _player_head_model_to_head_transform() -> Transform3D:
	if _player_skeleton == null:
		return Transform3D.IDENTITY
	var head_bone_index := _player_skeleton.find_bone("Bip01 Head")
	if head_bone_index < 0:
		return Transform3D.IDENTITY
	# Eye NIF vertices are offsets from the head bone origin in the model's
	# unrotated frame. Cancel only the rest rotation; removing the translation
	# would move the eyes down by the height of the head.
	var head_basis := _player_skeleton.get_bone_global_rest(head_bone_index).basis
	return Transform3D(head_basis.inverse(), Vector3.ZERO)

func _update_interaction_hint(nearby_item: Dictionary, nearby_door: Dictionary) -> void:
	if _world_loading:
		interaction_hint_label.visible = false
		return
	if _pickup_toast_remaining > 0.0:
		interaction_hint_label.text = _pickup_toast_text
	elif not nearby_item.is_empty():
		interaction_hint_label.text = "E · Pick up %s" % str(nearby_item.get("editor_id", "item"))
	elif not nearby_door.is_empty():
		interaction_hint_label.text = "E · Enter linked door"
	else:
		interaction_hint_label.visible = false
		return
	interaction_hint_label.visible = true

func _load_cell_actors(cell: Dictionary, target_reference_id: int = -1, clear_existing: bool = true) -> void:
	if clear_existing:
		_clear_cell_actors()
	var stream_generation := _npc_stream_generation
	var actor_count := 0
	var routed_actor_count := 0
	var grounded_actor_count := 0
	for reference_value: Variant in cell.get("references", []):
		var reference: Dictionary = reference_value
		if str(reference.get("record_type", "")) != "ACHR":
			continue
		var reference_id := int(reference.get("form_id", 0))
		if target_reference_id >= 0 and reference_id != target_reference_id:
			continue
		if _npc_loaded_reference_ids.has(reference_id):
			continue
		if target_reference_id >= 0:
			_npc_loaded_reference_ids[reference_id] = true
		if not bool(cell.get("interior", true)):
			if _is_early_oblivion_gate(reference, str(reference.get("model_path", ""))):
				continue
			if _actor_reference_transform(reference).origin.distance_to(player.global_position) > EXTERIOR_REFERENCE_RENDER_DISTANCE:
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
		_npc_pending_roots.push_back(actor_root)
		var actor_collision := CollisionShape3D.new()
		actor_collision.name = "ApproximateActorCollision"
		var actor_capsule := CapsuleShape3D.new()
		actor_capsule.radius = 0.27
		actor_capsule.height = 1.8
		actor_collision.shape = actor_capsule
		actor_collision.position.y = 0.9
		actor_root.add_child(actor_collision)
		if _place_actor_on_generated_floor(actor_root):
			grounded_actor_count += 1
		var avatar := Node3D.new()
		avatar.name = "OriginalActor"
		avatar.scale = Vector3.ONE * game_units_to_meters
		actor_root.add_child(avatar)
		var skeleton_metadata: Dictionary = _nif_metadata_cache.get(PLAYER_SKELETON.to_lower(), {})
		var skeleton := _build_player_skeleton(skeleton_metadata.get("nodes", []))
		if skeleton == null:
			_discard_pending_npc(actor_root)
			continue
		avatar.add_child(skeleton)
		_align_avatar_to_floor_origin(avatar, skeleton)
		var is_female := bool(npc.get("female", false))
		var race_editor_id := str(data_reader.find_editor_id(int(npc.get("race_form_id", 0)))).to_lower()
		var race_texture_key := _npc_race_texture_key(race_editor_id)
		var eye_texture_path := _npc_eye_texture_path(npc, race_editor_id)
		var head_model_path := _npc_head_model_path(npc)
		var head_part := _npc_head_part_entry(npc)
		var equipment_ids := _npc_equipment_ids(npc)
		var covered_body_slots := 0
		var covered_head_slots := 0
		for equipment_form_id: int in equipment_ids:
			var equipment_type := str(data_reader.find_record_type(equipment_form_id))
			if equipment_type in ["ARMO", "CLOT"]:
				var equipment_slots := int(data_reader.get_item_biped_slots(equipment_form_id))
				covered_body_slots |= equipment_slots
				covered_head_slots |= equipment_slots & 0x0003
		_register_player_face_profile(npc, head_model_path)
		var face_meshes: Array[MeshInstance3D] = []
		for body_part: Dictionary in _npc_body_part_entries(npc, is_female):
			if (int(body_part.get("biped_slot", 0)) & covered_body_slots) != 0:
				continue
			await _add_actor_model(
				avatar,
				skeleton,
				str(body_part.get("model_path", "")),
				"",
				PackedByteArray(),
				{},
				false,
				race_texture_key,
				"",
				str(body_part.get("texture_path", ""))
			)
			if stream_generation != _npc_stream_generation:
				_discard_pending_npc(actor_root)
				return
		var head_meshes: Array[MeshInstance3D] = await _add_actor_model(
			avatar,
			skeleton,
			head_model_path,
			"",
			PackedByteArray(),
			npc,
			false,
			race_texture_key,
			"",
			str(head_part.get("texture_path", ""))
		)
		if stream_generation != _npc_stream_generation:
			_discard_pending_npc(actor_root)
			return
		face_meshes.append_array(head_meshes)
		for detail_part: Dictionary in _npc_face_detail_entries(npc):
			var detail_path := str(detail_part.get("model_path", ""))
			var is_eye_model := int(detail_part.get("index", -1)) >= 7 or detail_path.to_lower().contains("eye")
			var is_ear_model := int(detail_part.get("index", -1)) == 1 or int(detail_part.get("index", -1)) == 2 or detail_path.to_lower().contains("ear")
			var uses_head_bone_rotation := _face_detail_uses_head_bone_rotation(
				int(detail_part.get("index", -1)), detail_path
			)
			var detail_face_data: Dictionary = {} if is_ear_model else npc
			var detail_meshes: Array[MeshInstance3D] = await _add_actor_model(
				avatar,
				skeleton,
				detail_path,
				"Bip01 Head",
				PackedByteArray(),
				detail_face_data,
				false,
				race_texture_key,
				eye_texture_path if is_eye_model else "",
				str(detail_part.get("texture_path", "")),
				not uses_head_bone_rotation
			)
			face_meshes.append_array(detail_meshes)
			if stream_generation != _npc_stream_generation:
				_discard_pending_npc(actor_root)
				return
		if covered_head_slots == 0:
			var hair_form_id := int(npc.get("hair_form_id", 0))
			var hair_path := str(data_reader.find_item_model_path(hair_form_id, is_female)) if hair_form_id != 0 else ""
			if hair_path.is_empty():
				hair_path = "Characters/Imperial/female/hair01.nif" if is_female else "Characters/Imperial/male/hair01.nif"
			var hair_color: PackedByteArray = npc.get("hair_color", PackedByteArray())
			var hair_is_model_space := hair_path.to_lower().replace("\\", "/").contains("/imperial/")
			await _add_actor_model(
				avatar, skeleton, hair_path, "Bip01 Head", hair_color, {}, hair_is_model_space,
				"", "", "", not hair_is_model_space
			)
			if stream_generation != _npc_stream_generation:
				_discard_pending_npc(actor_root)
				return
		var weapon_attached := false
		var attached_item_names: Array[String] = []
		for item_form_id: int in equipment_ids:
			var item_type := str(data_reader.find_record_type(item_form_id))
			if item_type != "ARMO" and item_type != "CLOT" and item_type != "WEAP":
				continue
			if item_type == "WEAP" and weapon_attached:
				continue
			var item_path := str(data_reader.find_item_model_path(item_form_id, is_female))
			if item_path.is_empty():
				continue
			var attach_bone := ""
			var adjust_bone_orientation := false
			var model_space_bone_attachment := false
			if item_type == "WEAP":
				attach_bone = "Bip01 R Hand"
			else:
				var item_slots := int(data_reader.get_item_biped_slots(item_form_id))
				if (item_slots & 0x2000) != 0:
					attach_bone = "Bip01 L Hand"
					adjust_bone_orientation = true
				elif (item_slots & 0x0003) != 0:
					attach_bone = "Bip01 Head"
					adjust_bone_orientation = true
					model_space_bone_attachment = await _uses_model_space_head_attachment(item_path)
			await _add_actor_model(
				avatar, skeleton, item_path, attach_bone, PackedByteArray(), {}, model_space_bone_attachment,
				race_texture_key, "", "", adjust_bone_orientation
			)
			if stream_generation != _npc_stream_generation:
				_discard_pending_npc(actor_root)
				return
			attached_item_names.push_back(str(data_reader.find_editor_id(item_form_id)))
			if item_type == "WEAP":
				weapon_attached = true
		print("OpenOB attached equipment to %s: %s" % [actor_name, str(attached_item_names)])
		await _meshes_for_model(PLAYER_IDLE_KF)
		await _meshes_for_model(PLAYER_DIRECTIONAL_KFS["Forward"][0])
		await _meshes_for_model(PLAYER_FAST_FORWARD_KF)
		if stream_generation != _npc_stream_generation:
			_discard_pending_npc(actor_root)
			return
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
			"animation_from_pose": [],
			"animation_blend_elapsed": ANIMATION_BLEND_DURATION,
		}
		_npc_actors.push_back(actor_state)
		_npc_pending_roots.erase(actor_root)
		_npc_loaded_reference_ids[reference_id] = true
		_apply_face_expression(actor_state)
		actor_count += 1
	print("OpenOB assembled %d placed NPCs (%d grounded), %d with ESM marker routes, original idle/walk/fast-walk animations, and FaceGen head morphs" % [actor_count, grounded_actor_count, routed_actor_count])
	if actor_count > 0:
		status_label.text += "\nLoaded %d placed NPCs with original rigs, outfit meshes, FaceGen head shapes, and walk/fast-walk animations. F cycles the nearest NPC's expression." % actor_count
		await get_tree().process_frame

func _update_npc_streaming() -> void:
	if not _npc_stream_enabled or _npc_stream_busy or _world_loading or data_reader == null:
		return
	_npc_stream_scan_cooldown = maxf(0.0, _npc_stream_scan_cooldown - get_process_delta_time())
	if _npc_stream_scan_cooldown > 0.0:
		return
	_npc_stream_scan_cooldown = 0.25
	var camera := player.get_node_or_null("CameraPivot/Camera3D") as Camera3D
	var is_exterior := not bool(current_cell.get("interior", true))
	var visible_distance := 110.0 if is_exterior else NPC_VISIBLE_LOAD_DISTANCE
	var selected_reference_id := -1
	var selected_priority := INF
	for reference_value: Variant in current_cell.get("references", []):
		var reference: Dictionary = reference_value
		if str(reference.get("record_type", "")) != "ACHR":
			continue
		var reference_id := int(reference.get("form_id", 0))
		if _npc_loaded_reference_ids.has(reference_id):
			continue
		if is_exterior and _is_early_oblivion_gate(reference, str(reference.get("model_path", ""))):
			continue
		var position := _actor_reference_transform(reference).origin
		var distance_to_player := position.distance_to(player.global_position)
		var is_near := distance_to_player <= NPC_NEAR_LOAD_DISTANCE
		var is_visible := (
			camera != null
			and distance_to_player <= visible_distance
			and camera.is_position_in_frustum(position)
		)
		if not is_near and not is_visible:
			continue
		var priority := distance_to_player + (0.0 if is_near else 1000.0)
		if priority < selected_priority:
			selected_priority = priority
			selected_reference_id = reference_id
	if selected_reference_id < 0:
		return
	_npc_stream_busy = true
	_load_next_streamed_npc.call_deferred(current_cell, selected_reference_id, _npc_stream_generation)

func _load_next_streamed_npc(cell: Dictionary, reference_id: int, stream_generation: int) -> void:
	if stream_generation != _npc_stream_generation:
		return
	await _load_cell_actors(cell, reference_id, false)
	if stream_generation == _npc_stream_generation:
		_npc_stream_busy = false

func _clear_cell_actors() -> void:
	_npc_stream_generation += 1
	_npc_stream_busy = false
	_npc_loaded_reference_ids.clear()
	for actor_root: Node3D in _npc_pending_roots:
		if not is_instance_valid(actor_root):
			continue
		actor_root.set_physics_process(false)
		actor_root.set_process(false)
		actor_root.queue_free()
	_npc_pending_roots.clear()
	for actor: Dictionary in _npc_actors:
		var actor_root := actor.get("root") as Node3D
		if not is_instance_valid(actor_root):
			continue
		actor_root.set_physics_process(false)
		actor_root.set_process(false)
		actor_root.queue_free()
	_npc_actors.clear()

func _discard_pending_npc(actor_root: Node3D) -> void:
	_npc_pending_roots.erase(actor_root)
	if not is_instance_valid(actor_root):
		return
	actor_root.set_physics_process(false)
	actor_root.set_process(false)
	actor_root.queue_free()

func _npc_head_model_path(npc: Dictionary) -> String:
	var race_head_parts: Array = npc.get("race_head_parts", [])
	if not race_head_parts.is_empty():
		var head_entry: Dictionary = race_head_parts[0]
		var race_head_path := str(head_entry.get("model_path", ""))
		if not race_head_path.is_empty():
			return race_head_path
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

func _npc_head_part_entry(npc: Dictionary) -> Dictionary:
	var race_head_parts: Array = npc.get("race_head_parts", [])
	if race_head_parts.is_empty():
		return {"model_path": _npc_head_model_path(npc), "texture_path": ""}
	return race_head_parts[0]

func _npc_body_part_entries(npc: Dictionary, is_female: bool) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var race_body_parts: Array = npc.get("race_body_parts", [])
	var fallback_parts: Array = FEMALE_AVATAR_PARTS if is_female else PLAYER_AVATAR_PARTS
	var body_slots := [0x0004, 0x0008, 0x0010, 0x0020]
	for index in range(mini(4, fallback_parts.size())):
		var race_part: Dictionary = race_body_parts[index] if index < race_body_parts.size() else {}
		var model_path := str(race_part.get("model_path", ""))
		if model_path.is_empty():
			model_path = str(fallback_parts[index])
		entries.push_back({
			"model_path": model_path,
			"texture_path": str(race_part.get("texture_path", "")),
			"biped_slot": body_slots[index],
		})
	if race_body_parts.size() > 4:
		var tail_part: Dictionary = race_body_parts[4]
		var tail_model_path := str(tail_part.get("model_path", ""))
		if not tail_model_path.is_empty():
			entries.push_back({
				"model_path": tail_model_path,
				"texture_path": str(tail_part.get("texture_path", "")),
				"biped_slot": 0x8000,
			})
	return entries

func _npc_face_detail_entries(npc: Dictionary) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var race_head_parts: Array = npc.get("race_head_parts", [])
	if race_head_parts.size() >= 9:
		var ear_index := 2 if bool(npc.get("female", false)) else 1
		var ear_part: Dictionary = race_head_parts[ear_index]
		if str(ear_part.get("model_path", "")).is_empty():
			ear_index = 1 if ear_index == 2 else 2
		for part_index in [ear_index, 3, 4, 5, 6, 7, 8]:
			var part: Dictionary = race_head_parts[part_index]
			var model_path := str(part.get("model_path", ""))
			if model_path.is_empty():
				continue
			entries.push_back({
				"index": part_index,
				"model_path": model_path,
				"texture_path": str(part.get("texture_path", "")),
			})
		if not entries.is_empty():
			return entries
	for fallback_path: String in _npc_face_detail_paths(str(data_reader.find_editor_id(int(npc.get("race_form_id", 0)))).to_lower()):
		entries.push_back({"index": -1, "model_path": fallback_path, "texture_path": ""})
	return entries

func _face_detail_uses_head_bone_rotation(part_index: int, model_path: String) -> bool:
	# Mouth, teeth, and tongue assets are authored in the head bone's local axes.
	# Eyes, ears, and other rigid face parts use character axes and need the bind
	# rotation cancelled when attached to the animated head bone.
	if part_index >= 0:
		return part_index in [3, 4, 5, 6]
	var lower_path := model_path.to_lower()
	return lower_path.contains("mouth") or lower_path.contains("teeth") or lower_path.contains("tongue")

func _npc_race_texture_key(race_editor_id: String) -> String:
	if race_editor_id in ["argonian", "darkelf", "khajiit", "orc", "redguard"]:
		return race_editor_id
	return "imperial"

func _npc_eye_texture_path(npc: Dictionary, race_editor_id: String) -> String:
	var eye_name := str(data_reader.find_editor_id(int(npc.get("eye_form_id", 0)))).to_lower()
	match eye_name:
		"eyedefault", "":
			match race_editor_id:
				"argonian": eye_name = "eyeargonian"
				"khajiit": eye_name = "eyekhajiit"
				"darkelf": eye_name = "eyedarkelf"
				"orc": eye_name = "eyeorc"
				_: eye_name = "eyebrown"
	return "Textures/Characters/Eyes/%s.dds" % eye_name

func _npc_face_detail_paths(race_editor_id: String) -> Array[String]:
	var paths: Array[String] = []
	match race_editor_id:
		"argonian":
			paths.append_array([
				"Characters/Argonian/eyeLeftArgonian.nif",
				"Characters/Argonian/eyeRightArgonian.nif",
				"Characters/Argonian/mouthArgonian.nif",
				"Characters/Argonian/teethUpperArgonian.nif",
				"Characters/Argonian/teethLowerArgonian.nif",
				"Characters/Argonian/tongueArgonian.nif",
			])
		"khajiit":
			paths.append_array([
				"Characters/Khajiit/earsKhajiit.nif",
				"Characters/Imperial/eyeLeftHuman.nif",
				"Characters/Imperial/eyeRightHuman.nif",
				"Characters/Khajiit/khajiitMouth.nif",
				"Characters/Khajiit/khajiitTeethUpper.nif",
				"Characters/Khajiit/khajiitTeethLower.nif",
				"Characters/Khajiit/khajiitTongue.nif",
			])
		"orc":
			paths.append_array([
				"Characters/Orc/earsOrc.nif",
				"Characters/Imperial/eyeLeftHuman.nif",
				"Characters/Imperial/eyeRightHuman.nif",
				"Characters/Orc/orcMouth.nif",
				"Characters/Orc/orcTeethUpper.nif",
				"Characters/Orc/orcTeethLower.nif",
				"Characters/Orc/orcTongue.nif",
			])
		"darkelf":
			paths.append_array([
				"Characters/DarkElf/earsDarkElf.nif",
				"Characters/Imperial/eyeLeftHuman.nif",
				"Characters/Imperial/eyeRightHuman.nif",
				"Characters/Imperial/mouthHuman.nif",
				"Characters/Imperial/teethUpperHuman.nif",
				"Characters/Imperial/teethLowerHuman.nif",
				"Characters/Imperial/tongueHuman.nif",
			])
		_:
			paths.append_array(PLAYER_FACE_DETAIL_PARTS)
	return paths

func _npc_race_texture_path(texture_path: String, race_texture_key: String) -> String:
	var normalized_path := texture_path.to_lower().replace("\\", "/")
	const IMPERIAL_TEXTURE_ROOT := "textures/characters/imperial/"
	if race_texture_key == "imperial" or not normalized_path.begins_with(IMPERIAL_TEXTURE_ROOT):
		return texture_path
	var relative_path := normalized_path.substr(IMPERIAL_TEXTURE_ROOT.length())
	var candidate := "textures/characters/%s/%s" % [race_texture_key, relative_path]
	if relative_path.begins_with("headhuman"):
		var race_head_name := ""
		match race_texture_key:
			"darkelf": race_head_name = "headdarkelf"
			"khajiit": race_head_name = "headkhajiit"
			"orc": race_head_name = "headorc"
			"argonian": race_head_name = "headargonian"
		if race_head_name.is_empty():
			return texture_path
		candidate = "textures/characters/%s/%s%s" % [
			race_texture_key,
			race_head_name,
			relative_path.substr("headhuman".length()),
		]
	if _race_texture_path_cache.has(candidate):
		return candidate if bool(_race_texture_path_cache[candidate]) else texture_path
	var texture_bytes: PackedByteArray = data_reader.read_asset(candidate)
	var found := not texture_bytes.is_empty()
	_race_texture_path_cache[candidate] = found
	return candidate if found else texture_path

func _ensure_facegen_data(head_model_path: String) -> Dictionary:
	var cache_key := head_model_path.to_lower().replace("\\", "/")
	if _facegen_cache.has(cache_key):
		return _facegen_cache[cache_key]
	var asset_stem := head_model_path.replace("\\", "/").get_basename()
	var egm_bytes: PackedByteArray = data_reader.read_asset("Meshes/" + asset_stem + ".egm")
	var tri_bytes: PackedByteArray = data_reader.read_asset("Meshes/" + asset_stem + ".tri")
	var egt_bytes: PackedByteArray = data_reader.read_asset("Meshes/" + asset_stem + ".egt")
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
	var decoded := {"egm": egm, "tri": tri, "egt_bytes": egt_bytes}
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

func _uses_model_space_head_attachment(model_path: String) -> bool:
	var normalized_path := model_path.to_lower().replace("\\", "/")
	await _meshes_for_model(model_path)
	var metadata: Dictionary = _nif_metadata_cache.get(normalized_path, {})
	for node_value: Variant in metadata.get("nodes", []):
		var node: Dictionary = node_value
		if str(node.get("name", "")) == "Bip01 Head":
			# Some headgear NIFs keep their vertices at full character height;
			# local headgear is centered near the origin instead.
			return absf(float((node.get("translation", Vector3.ZERO) as Vector3).y)) > 50.0
	return false

func _add_actor_model(
	avatar: Node3D,
	skeleton: Skeleton3D,
	model_path: String,
	attach_bone := "",
	tint: PackedByteArray = PackedByteArray(),
	npc_face_data: Dictionary = {},
	model_space_bone_attachment := false,
	race_texture_key := "",
	eye_texture_path := "",
	texture_override := "",
	remove_bone_rest_rotation := false
) -> Array[MeshInstance3D]:
	var meshes: Array = await _meshes_for_model(model_path)
	var attachment: Node3D = avatar
	var added_instances: Array[MeshInstance3D] = []
	var actor_head_model_path := _npc_head_model_path(npc_face_data) if not npc_face_data.is_empty() else ""
	var is_actor_head := not actor_head_model_path.is_empty() and model_path.to_lower() == actor_head_model_path.to_lower()
	if not attach_bone.is_empty():
		var bone_attachment := BoneAttachment3D.new()
		bone_attachment.bone_name = attach_bone
		skeleton.add_child(bone_attachment)
		attachment = bone_attachment
		if model_space_bone_attachment:
			var bone_index := skeleton.find_bone(attach_bone)
			if bone_index >= 0:
				var model_to_bone := Node3D.new()
				model_to_bone.name = "ModelToBoneSpace"
				model_to_bone.transform = skeleton.get_bone_global_rest(bone_index).affine_inverse()
				bone_attachment.add_child(model_to_bone)
				attachment = model_to_bone
		elif remove_bone_rest_rotation:
			var bone_index := skeleton.find_bone(attach_bone)
			if bone_index >= 0:
				var align_to_bone := Node3D.new()
				align_to_bone.name = "AlignModelToBoneAxes"
				align_to_bone.transform = Transform3D(
					skeleton.get_bone_global_rest(bone_index).basis.inverse(), Vector3.ZERO
				)
				bone_attachment.add_child(align_to_bone)
				attachment = align_to_bone
	for mesh_entry: Dictionary in meshes:
		var instance := MeshInstance3D.new()
		var mesh_name := str(mesh_entry.get("mesh_name", "Mesh"))
		instance.name = model_path.get_file().get_basename() + "_" + mesh_name.replace(":", "_")
		var source_mesh := mesh_entry.mesh as ArrayMesh
		var facegen_data: Dictionary = {}
		if not npc_face_data.is_empty():
			facegen_data = _ensure_facegen_data(model_path)
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
		var texture_path := str(mesh_entry.diffuse_texture_path)
		if not texture_override.is_empty():
			texture_path = _normalize_texture_asset_path(texture_override)
		elif not race_texture_key.is_empty():
			texture_path = _npc_race_texture_path(texture_path, race_texture_key)
		if not eye_texture_path.is_empty() and model_path.to_lower().contains("eye"):
			texture_path = eye_texture_path
		var material := await _material_for_texture(
			texture_path,
			bool(mesh_entry.get("alpha_blend", false)),
			bool(mesh_entry.get("alpha_test", false)),
			int(mesh_entry.get("alpha_threshold", 128))
		)
		if is_actor_head and not facegen_data.get("egt_bytes", PackedByteArray()).is_empty():
			material = _facegen_texture_material(
				material,
				texture_path,
				facegen_data.egt_bytes,
				npc_face_data.get("face_texture_coefficients", PackedFloat32Array())
			)
		if tint.size() >= 3:
			material = material.duplicate() as StandardMaterial3D
			material.albedo_color = Color8(tint[0], tint[1], tint[2], tint[3] if tint.size() > 3 and tint[3] > 0 else 255)
		instance.material_override = material
		if is_actor_head:
			instance.custom_aabb = source_mesh.get_aabb().grow(PLAYER_HEAD_CULL_MARGIN)
		attachment.add_child(instance)
		var bone_names: Array = mesh_entry.get("bone_names", [])
		if not bone_names.is_empty() and attach_bone.is_empty():
			instance.skeleton = NodePath("../Skeleton3D")
			instance.skin = _skin_for_mesh(bone_names, skeleton)
		added_instances.push_back(instance)
	return added_instances

func _facegen_texture_material(
	base_material: StandardMaterial3D,
	texture_path: String,
	egt_bytes: PackedByteArray,
	coefficients: PackedFloat32Array
) -> StandardMaterial3D:
	if base_material == null or base_material.albedo_texture == null or coefficients.is_empty():
		return base_material
	var cache_key := texture_path.to_lower().replace("\\", "/") + ":" + str(coefficients)
	var face_texture: Texture2D
	if _facegen_texture_cache.has(cache_key):
		face_texture = _facegen_texture_cache[cache_key] as Texture2D
	else:
		var image := base_material.albedo_texture.get_image()
		if image == null:
			return base_material
		image = image.duplicate()
		if image.is_compressed():
			if image.decompress() != OK:
				push_warning("Could not decompress base face texture %s" % texture_path)
				return base_material
		image.convert(Image.FORMAT_RGBA8)
		image.clear_mipmaps()
		var source_bytes := image.get_data()
		var morphed_bytes: PackedByteArray = data_reader.apply_facegen_texture_data(
			source_bytes,
			image.get_width(),
			image.get_height(),
			egt_bytes,
			coefficients
		)
		if morphed_bytes.size() != source_bytes.size():
			push_warning("Could not apply FaceGen texture coefficients to %s" % texture_path)
			return base_material
		var morphed_image := Image.create_from_data(
			image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8, morphed_bytes
		)
		morphed_image.generate_mipmaps()
		face_texture = ImageTexture.create_from_image(morphed_image)
		_facegen_texture_cache[cache_key] = face_texture
	var material := base_material.duplicate() as StandardMaterial3D
	material.albedo_texture = face_texture
	return material

func _normalize_texture_asset_path(texture_path: String) -> String:
	var normalized := texture_path.strip_edges().replace("\\", "/")
	if normalized.to_lower().begins_with("characters/"):
		return "Textures/" + normalized
	return normalized

func _actor_reference_transform(reference: Dictionary) -> Transform3D:
	var position: PackedFloat32Array = reference.get("position", PackedFloat32Array())
	var rotation: PackedFloat32Array = reference.get("rotation", PackedFloat32Array())
	if position.size() < 3 or rotation.size() < 3:
		return Transform3D.IDENTITY
	var godot_rotation := _reference_rotation(rotation)
	var godot_position := Vector3(position[0], position[2], -position[1]) * game_units_to_meters
	return Transform3D(godot_rotation, godot_position)

func _place_actor_on_generated_floor(actor_root: CharacterBody3D) -> bool:
	var start_position := actor_root.global_position
	var query := PhysicsRayQueryParameters3D.create(
		start_position + Vector3.UP * 2.1,
		start_position - Vector3.UP * 3.0,
		2,
		[actor_root.get_rid(), player.get_rid()]
	)
	query.collide_with_areas = false
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	if result.is_empty() or Vector3(result.get("normal", Vector3.UP)).dot(Vector3.UP) < 0.55:
		return false
	var floor_position: Vector3 = result.get("position", start_position)
	actor_root.global_position = Vector3(start_position.x, floor_position.y + 0.02, start_position.z)
	actor_root.motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	actor_root.floor_snap_length = 0.35
	actor_root.set("grounding_enabled", true)
	return true

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
			actor["animation_from_pose"] = _capture_skeleton_pose(skeleton)
			actor["animation_blend_elapsed"] = 0.0
			actor["active_animation"] = requested_animation
			actor["animation_time"] = float(animation.get("start_time", 0.0))
		actor["animation_time"] = float(actor.get("animation_time", 0.0)) + delta
		var blend_elapsed := minf(
			float(actor.get("animation_blend_elapsed", ANIMATION_BLEND_DURATION)) + delta,
			ANIMATION_BLEND_DURATION
		)
		actor["animation_blend_elapsed"] = blend_elapsed
		var blend_weight := blend_elapsed / ANIMATION_BLEND_DURATION
		var pose_from: Array[Dictionary] = []
		var pose_from_value: Variant = actor.get("animation_from_pose", [])
		if pose_from_value is Array:
			for pose_value: Variant in pose_from_value:
				if pose_value is Dictionary:
					pose_from.push_back(pose_value)
		_apply_animation_pose(skeleton, animation, float(actor["animation_time"]), true, pose_from, blend_weight)
		if blend_weight >= 1.0:
			actor["animation_from_pose"] = []

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
	_player_animation_blend_elapsed = minf(
		_player_animation_blend_elapsed + delta,
		ANIMATION_BLEND_DURATION
	)
	var start_time := float(animation.get("start_time", 0.0))
	var stop_time := float(animation.get("stop_time", start_time))
	var duration := stop_time - start_time
	if duration <= 0.0:
		return
	var blend_weight := _player_animation_blend_elapsed / ANIMATION_BLEND_DURATION
	_apply_animation_pose(
		_player_skeleton,
		animation,
		_animation_time,
		_active_animation not in ["JumpStart", "JumpLand"],
		_player_animation_from_pose,
		blend_weight
	)
	if blend_weight >= 1.0:
		_player_animation_from_pose.clear()

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
	if _player_skeleton != null:
		_player_animation_from_pose = _capture_skeleton_pose(_player_skeleton)
		_player_animation_blend_elapsed = 0.0
	_active_animation = animation_name
	_animation_time = float(animation.get("start_time", 0.0))

func _capture_skeleton_pose(skeleton: Skeleton3D) -> Array[Dictionary]:
	var pose: Array[Dictionary] = []
	pose.resize(skeleton.get_bone_count())
	for bone_index in range(skeleton.get_bone_count()):
		pose[bone_index] = {
			"position": skeleton.get_bone_pose_position(bone_index),
			"rotation": skeleton.get_bone_pose_rotation(bone_index),
			"scale": skeleton.get_bone_pose_scale(bone_index),
		}
	return pose

func _apply_animation_pose(
	skeleton: Skeleton3D,
	animation: Dictionary,
	time: float,
	looping: bool = true,
	pose_from: Array[Dictionary] = [],
	blend_weight := 1.0
) -> void:
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
	if pose_from.size() != skeleton.get_bone_count() or blend_weight >= 1.0:
		return
	var weight := clampf(blend_weight, 0.0, 1.0)
	for bone_index in range(skeleton.get_bone_count()):
		var source_pose: Dictionary = pose_from[bone_index]
		skeleton.set_bone_pose_position(
			bone_index,
			Vector3(source_pose.position).lerp(skeleton.get_bone_pose_position(bone_index), weight)
		)
		skeleton.set_bone_pose_rotation(
			bone_index,
			Quaternion(source_pose.rotation).slerp(skeleton.get_bone_pose_rotation(bone_index), weight)
		)
		skeleton.set_bone_pose_scale(
			bone_index,
			Vector3(source_pose.scale).lerp(skeleton.get_bone_pose_scale(bone_index), weight)
		)

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
	alpha_threshold := 128,
	billboard := false
) -> StandardMaterial3D:
	var normalized_path := texture_path.strip_edges().replace("\\", "/")
	if normalized_path.is_empty():
		return _cell_material
	var alpha_mode := "blend" if alpha_blend else "scissor" if alpha_test else "opaque"
	var key := "%s|%s|%d|%s" % [normalized_path.to_lower(), alpha_mode, alpha_threshold, "billboard" if billboard else "fixed"]
	if _material_cache.has(key):
		return _material_cache[key]

	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.roughness = 0.9
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y if billboard else BaseMaterial3D.BILLBOARD_DISABLED
	material.billboard_keep_scale = billboard
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
	# The converted Oblivion model normals shade opposite the intended sun side in
	# Godot. Flip shading normals only; triangle winding still drives geometry and shadows.
	for normal_index in range(normals.size()):
		normals[normal_index] = -normals[normal_index]

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
		var generated_mesh := surface.commit() as ArrayMesh
		var generated_arrays := generated_mesh.surface_get_arrays(0)
		var generated_normals: PackedVector3Array = generated_arrays[Mesh.ARRAY_NORMAL]
		for normal_index in range(generated_normals.size()):
			generated_normals[normal_index] = -generated_normals[normal_index]
		generated_arrays[Mesh.ARRAY_NORMAL] = generated_normals
		var flipped_mesh := ArrayMesh.new()
		flipped_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, generated_arrays)
		return flipped_mesh

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
	var godot_rotation := _reference_rotation(rotation)
	var godot_position := Vector3(position[0], position[2], -position[1]) * game_units_to_meters
	return Transform3D(godot_rotation.scaled(Vector3.ONE * game_units_to_meters), godot_position)

func _reference_rotation(rotation: PackedFloat32Array) -> Basis:
	if rotation.size() < 3:
		return Basis.IDENTITY
	var source_to_godot := Basis(Vector3.RIGHT, Vector3(0.0, 0.0, -1.0), Vector3.UP)
	# TES4 reference angles use Z-Y-X composition around negative source axes.
	var source_rotation := (
		Basis(Vector3(0.0, 0.0, -1.0), rotation[2])
		* Basis(Vector3(0.0, -1.0, 0.0), rotation[1])
		* Basis(Vector3(-1.0, 0.0, 0.0), rotation[0])
	)
	return (source_to_godot * source_rotation * source_to_godot.inverse()).orthonormalized()

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

func _transition_to_linked_cell(reference: Dictionary) -> void:
	if _world_loading or data_reader == null or current_cell.is_empty():
		return
	_world_loading = true
	var target_id := int(reference.get("teleport_cell_id", 0))
	if target_id == 0:
		_world_loading = false
		return
	var target: Dictionary = data_reader.find_cell_by_id(target_id)
	if target.is_empty():
		status_label.text = "Linked door target 0x%08X is not indexed." % target_id
		_world_loading = false
		return
	var destination: PackedFloat32Array = reference.get("teleport_position", PackedFloat32Array())
	if not bool(target.get("interior", true)):
		if destination.size() < 2:
			status_label.text = "Exterior door is missing its destination coordinates."
			_world_loading = false
			return
		var grid_x := floori(destination[0] / EXTERIOR_CELL_SIZE)
		var grid_y := floori(destination[1] / EXTERIOR_CELL_SIZE)
		var exterior_region: Dictionary = data_reader.find_exterior_region(
			grid_x,
			grid_y,
			int(target.get("worldspace_form_id", 0)),
			EXTERIOR_STREAM_RADIUS,
			EXTERIOR_STATIC_REFERENCE_RADIUS,
			EXTERIOR_TREE_REFERENCE_RADIUS
		)
		if exterior_region.is_empty():
			status_label.text = "Exterior cell %d,%d was not found." % [grid_x, grid_y]
			_world_loading = false
			return
		target = exterior_region
	var destination_position := player.global_position
	if destination.size() >= 3:
		destination_position = Vector3(destination[0], destination[2], -destination[1]) * game_units_to_meters
	_deferred_world_generation += 1
	_npc_stream_enabled = false
	player.set_physics_process(false)
	_clear_cell_actors()
	player.global_position = destination_position
	current_cell = target
	await _load_cell_geometry(
		current_cell, 0.0,
		STARTUP_NEAR_REFERENCE_DISTANCE if bool(current_cell.get("interior", true)) else STARTUP_NEAR_TERRAIN_DISTANCE,
		true
	)
	await _place_player_on_ground(destination_position)
	var destination_rotation: PackedFloat32Array = reference.get("teleport_rotation", PackedFloat32Array())
	if destination_rotation.size() >= 3:
		var godot_rotation := _reference_rotation(destination_rotation)
		player.set_spawn_yaw(godot_rotation.get_euler().y)
	player.set_physics_process(true)
	_world_loading = false
	_start_deferred_cell_loading()
