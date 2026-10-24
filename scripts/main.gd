extends Node3D

const START_CELL_ID := "ImperialDungeon01"
const START_MARKER_EDITOR_ID := "CGPlayerStartMarker"
const START_MARKER_FORM_ID := 0x00032AB5
const PLAYER_REFERENCE_FORM_ID := 0x00000014
const AI_PACKAGE_TYPE_AMBUSH := 9
const AI_PACKAGE_TYPE_FOLLOW := 1
const AI_PACKAGE_TYPE_USE_ITEM_AT := 8
const AI_PACKAGE_TARGET_REFERENCE := 0
const AI_USE_ITEM_ACTIVATION_RADIUS_GAME_UNITS := 150.0
const AI_PACKAGE_FLAG_ALWAYS_RUN := 0x2000
const DIALOGUE_REPLY_FLAG_GOODBYE := 0x01
const DerivedResourceCache := preload("res://scripts/derived_resource_cache.gd")
const ActorFactory := preload("res://scripts/actor_factory.gd")
const SceneQuestDirector := preload("res://scripts/scene_quest_director.gd")
const NifAssetLibrary := preload("res://scripts/nif_asset_library.gd")
const FaceGenData := preload("res://scripts/facegen_data.gd")
const NpcRouteController := preload("res://scripts/npc_route_controller.gd")
const PlayerActorValues := preload("res://scripts/player_actor_values.gd")
const PLAYER_DYNAMIC_GAME_SETTINGS := [
	"fFatigueReturnBase", "fFatigueReturnMult", "fFatigueRunBase", "fFatigueRunMult",
	"fFatigueJumpBase", "fFatigueJumpMult", "fMagickaReturnBase", "fMagickaReturnMult",
	"fMagicCostScale", "fMagicDurMagBaseCostMult", "fMagicAreaBaseCostMult",
	"fMagicRangeTargetCostMult", "fMagicCasterSkillCostBase", "fMagicCasterSkillCostMult",
]
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
## Unarmed sneak clips, played while the player holds the crouch key. The sequence names match the walk clips.
const PLAYER_SNEAK_KFS := {
	"SneakIdle": ["Characters/_male/sneakidle.kf", "Idle"],
	"SneakForward": ["Characters/_male/sneakforward.kf", "Forward"],
	"SneakBackward": ["Characters/_male/sneakbackward.kf", "Backward"],
	"SneakLeft": ["Characters/_male/sneakleft.kf", "Left"],
	"SneakRight": ["Characters/_male/sneakright.kf", "Right"],
}
const PLAYER_JUMP_KFS := {
	"JumpStart": ["Characters/_male/jumpstart.kf", "JumpStart"],
	"JumpLoop": ["Characters/_male/jumploop.kf", "JumpLoop"],
	"JumpLand": ["Characters/_male/jumpland.kf", "JumpLand"],
}
const PLAYER_FAST_FORWARD_KF := "Characters/_male/walkfastforward.kf"
const ANIMATION_BLEND_DURATION := 0.18
## A gesture eases in over its first moments and eases back out into the stance, instead of snapping at the default blend.
const GESTURE_BLEND_IN_S := 0.3
const GESTURE_BLEND_OUT_S := 0.8
## Original idle and gesture clips (pointing, saluting, praying and so on), enumerated from the game archives at runtime.
const PLAYER_GESTURE_PREFIX := "meshes/characters/_male/idleanims"
const GESTURE_KEY := "Gesture"
## Key of the clip an NPC plays for the idle manager's PickIdle (see play_npc_idle), next to its Idle and Forward clips.
const NPC_IDLE_KEY := "ScriptIdle"
const GESTURE_MOVE_ACTIONS := ["move_forward", "move_back", "move_left", "move_right"]
const InteractionTargeting := preload("res://scripts/interaction_targeting.gd")
const PhysicsObjectGrabber := preload("res://scripts/physics_object_grabber.gd")
const PLAYER_FACE_HEAD_MODEL := "Characters/Imperial/headhuman.nif"
const PLAYER_HEAD_CULL_MARGIN := ActorFactory.PLAYER_HEAD_CULL_MARGIN
const PLAYER_HAIR_MODEL := "Characters/Imperial/male/hair01.nif"
const PLAYER_FACE_DETAIL_PARTS := ActorFactory.PLAYER_FACE_DETAIL_PARTS
const FACE_EXPRESSION_CYCLE := ["", "Happy", "Anger", "Surprise", "Sad", "Fear"]
const PICKUP_TARGET_COLLISION_LAYER := 8
const FIRST_PERSON_HIDDEN_EQUIPMENT_SLOTS := 0x002F
const EXTERIOR_CELL_SIZE := 4096.0
const EXTERIOR_STREAM_RADIUS := 9
const EXTERIOR_STATIC_REFERENCE_RADIUS := 6
const EXTERIOR_TREE_REFERENCE_RADIUS := 9
const EXTERIOR_RELOAD_GRID_DISTANCE := 5
const EXTERIOR_REFERENCE_RENDER_DISTANCE := 220.0
const EXTERIOR_TREE_RENDER_DISTANCE := 380.0
const EXTERIOR_TREE_NEAR_DISTANCE := 42.0
const EXTERIOR_COLLISION_DISTANCE := 65.0
const EXTERIOR_COLLISION_UNLOAD_DISTANCE := 84.0
const EXTERIOR_TERRAIN_COLLISION_DISTANCE := 65.0
const EXTERIOR_TERRAIN_COLLISION_UNLOAD_DISTANCE := 84.0
const EXTERIOR_BATCH_SIZE_METERS := EXTERIOR_CELL_SIZE * 0.01
const EXTERIOR_OBJECT_BATCH_SIZE_METERS := EXTERIOR_CELL_SIZE * 0.08
const EXTERIOR_CAMERA_FAR := 430.0
const EXTERIOR_SHADOW_DISTANCE := 28.0
const STARTUP_NEAR_REFERENCE_DISTANCE := 18.0
const STARTUP_NEAR_TERRAIN_DISTANCE := 86.0
const NPC_NEAR_LOAD_DISTANCE := 18.0
const NPC_VISIBLE_LOAD_DISTANCE := 72.0
const PLAYER_AVATAR_PARTS := ActorFactory.PLAYER_AVATAR_PARTS
const FEMALE_AVATAR_PARTS := ActorFactory.FEMALE_AVATAR_PARTS

@export_range(0.001, 1.0, 0.001) var game_units_to_meters := 0.01

@onready var status_label: Label = $StatusLayer/StatusPanel/Margin/Status
@onready var inventory_label: Label = $StatusLayer/Inventory
@onready var inventory_panel: PanelContainer = $StatusLayer/InventoryPanel
@onready var key_light: DirectionalLight3D = $KeyLight
@onready var inventory_items_container: VBoxContainer = $StatusLayer/InventoryPanel/Margin/Contents/Scroll/Items
@onready var interaction_hint_label: Label = $StatusLayer/InteractionHint
@onready var hud: Control = $StatusLayer/HUD
@onready var face_profile_label: Label = $StatusLayer/FaceProfile
@onready var face_view_button: Button = $StatusLayer/FaceView
@onready var fly_mode_button: Button = $StatusLayer/FlyMode
@onready var player: CharacterBody3D = $Player
@onready var world_environment: WorldEnvironment = $WorldEnvironment

var data_reader: Object
var assets := NifAssetLibrary.new(self)
var actors := ActorFactory.new(assets)
var director := SceneQuestDirector.new(self)
var current_cell: Dictionary = {}
var quest_bridge := QuestStageBridge.new()
## The quests of the game running together (OblivionQuestWorld), or null before the first quest starts.
var quest_world: Object = null
## The quest whose packages drive the NPCs' routes: the first one started.
var route_quest_editor_id := ""
## Functions the quests asked for that nothing answers, reported once each.
var _reported_unanswered: Dictionary = {}
## Action lines of the quest bridge already reported, so a command asked on every tick is printed once.
var _reported_bridge_lines: Dictionary = {}
var cell_visual_root: Node3D
var _cell_load_generation := 0
var _deferred_world_generation := 0
var _npc_stream_generation := 0
var _npc_stream_enabled := false
var _npc_stream_busy := false
var _npc_stream_scan_cooldown := 0.0
var _npc_loaded_reference_ids: Dictionary = {}
var _exterior_collision_bodies: Dictionary = {}
var _exterior_collision_attempted_ids: Dictionary = {}
var _exterior_collision_stream_enabled := false
var _exterior_collision_stream_busy := false
var _exterior_collision_busy_generation := -1
var _exterior_collision_scan_cooldown := 0.0
var _exterior_terrain_collision_bodies: Dictionary = {}
var _exterior_terrain_collision_attempted_ids: Dictionary = {}
var _exterior_terrain_collision_stream_enabled := false
var _exterior_terrain_collision_scan_cooldown := 0.0
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
var _player_eye_meshes: Array[MeshInstance3D] = []
var _player_hair_meshes: Array[MeshInstance3D] = []
var _player_first_person_hidden_meshes: Array[MeshInstance3D] = []
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
var _player_base_record: Dictionary = {}
var _player_spell_form_ids: Array[int] = []
var _player_selected_spell_form_id := 0
var _player_actor_values := PlayerActorValues.new()
var _player_actor_values_ready := false
var _player_game_settings: Dictionary = {}
var _inventory_open := false
var _placed_items: Dictionary = {}
var _aimed_target: Dictionary = InteractionTargeting.empty_snapshot()
var targeting := InteractionTargeting.new()
var physics_grabber := PhysicsObjectGrabber.new()
var _container_reference_cache: Dictionary = {}
var _interaction_toast_text := ""
var _interaction_toast_remaining := 0.0
var _dialogue_active := false
var _dialogue_paused_actor: Node3D
var _pending_dialogue_actions: Array[Dictionary] = []
var _pending_dialogue_route_finished_actor_ids: Array[int] = []
var _dialogue_pending_route_refresh := false
var _scripted_subtitle_generation := 0
var _suppress_scripted_dialogue_presentation := false
var _dialogue_actor: Dictionary = {}
var _dialogue_camera: Camera3D
var _dialogue_previous_camera: Camera3D
var _dialogue_previous_mouse_mode := Input.MOUSE_MODE_VISIBLE
var _dialogue_previous_controls_suspended := false
var _dialogue_exit_transition := false
var _dialogue_exit_elapsed := 0.0
var _dialogue_return_transform := Transform3D.IDENTITY
var _dialogue_return_fov := 72.0
var _dialogue_layer: CanvasLayer
var _dialogue_panel: PanelContainer
var _dialogue_speaker_label: Label
var _dialogue_subtitle_label: Label
var _dialogue_topics: VBoxContainer
var _dialogue_goodbye_button: Button
var _scripted_dialogue_layer: CanvasLayer
var _scripted_dialogue_panel: PanelContainer
var _scripted_dialogue_speaker_label: Label
var _scripted_dialogue_subtitle_label: Label
var _dialogue_speaker_form_id := 0
var _dialogue_listener_form_id := 0
var _dialogue_listener_race := ""
var _dialogue_listener_female := false
var _dialogue_line_generation := 0
var _player_first_person_mode := false
var _active_animation := ""
var _gesture_clips: Array[Dictionary] = []
var _gesture_index := -1
var _gesture_active := false
var _gesture_request_id := 0
var _gesture_panel: PanelContainer
var _gesture_list: VBoxContainer
var _animation_time := 0.0
var _player_animation_from_pose: Array[Dictionary] = []
var _player_animation_blend_elapsed := ANIMATION_BLEND_DURATION
var _player_blend_duration := ANIMATION_BLEND_DURATION
var _player_was_on_floor := true
var _npc_actors: Array[Dictionary] = []
## Idles the idle manager chose for NPCs that are not in the scene yet, by lowercase reference name; played when they load.
var _pending_idles: Dictionary = {}
var _npc_pending_roots: Array[Node3D] = []
var _player_start_position := Vector3.ZERO
var _fallback_support: StaticBody3D

func _ready() -> void:
	_setup_targeting()
	_setup_dialogue_presentation()
	physics_grabber.configure(player, self)
	player.gameplay_frame.connect(_on_player_gameplay_frame)
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
	assets.cell_material = _cell_material
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
	_interaction_toast_remaining = maxf(0.0, _interaction_toast_remaining - _delta)
	if _dialogue_active:
		_update_dialogue_camera(_delta)
	elif _dialogue_exit_transition:
		_update_dialogue_camera_exit(_delta)
	if (_world_loading or _inventory_open or player.face_preview_enabled) and physics_grabber.is_holding_object():
		physics_grabber.release_without_throw()
	_update_hud()
	if Input.is_action_just_released("interact"):
		_interact_ready = true
	if (
		not _world_loading
		and not _inventory_open
		and not _dialogue_active
		and not _dialogue_exit_transition
		and not player.face_preview_enabled
		and _interact_ready
		and Input.is_action_just_pressed("interact")
	):
		_interact_ready = false
		# Re-validate at the moment of the press: act on what is under the reticle now.
		await _activate_target(targeting.acquire())
		if not Input.is_action_pressed("interact"):
			_interact_ready = true
	if not _world_loading and not current_cell.is_empty() and not bool(current_cell.get("interior", true)):
		await _stream_exterior_if_needed()
	if _player_skeleton != null and not _world_loading:
		if _gesture_panel_open() and (_world_loading or _inventory_open or player.face_preview_enabled):
			_toggle_gesture_panel()
		if not _inventory_open:
			_update_player_animation(_delta)
		player.set_first_person_eye_anchor(_player_first_person_camera_anchor())
		if _player_first_person_mode != player.is_first_person:
			_player_first_person_mode = player.is_first_person
			_refresh_player_first_person_visibility()
		_update_npc_actors(_delta)
		_update_exterior_collision_streaming()
		_update_exterior_terrain_collision_streaming()
		_update_npc_streaming()
		if not _player_face_state.is_empty():
			_update_face_blink(_player_face_state, _delta)
			_update_face_expression(_player_face_state, _delta)
		if player.face_preview_enabled:
			player.update_face_preview_anchor(_player_face_camera_anchor())

## Camera input runs after the interface had its turn: a click on the inventory or on the Face and Fly buttons is theirs,
## and only an event no control took (a click on the world, the mouse motion that looks around) reaches the camera.
func _unhandled_input(event: InputEvent) -> void:
	if _dialogue_exit_transition:
		return
	if _dialogue_active:
		if event is InputEventKey and event.pressed and not event.echo \
				and (event.keycode == KEY_ESCAPE or event.keycode == KEY_SPACE):
			_end_dialogue()
			get_viewport().set_input_as_handled()
		return
	if is_instance_valid(player):
		var grabber_handled_input := false
		if not _world_loading and not _inventory_open and not player.face_preview_enabled:
			grabber_handled_input = physics_grabber.handle_input(event)
		else:
			physics_grabber.release_without_throw()
		if not grabber_handled_input:
			player.handle_camera_input(event)
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode == KEY_F9:
		var report := start_quest("CharacterGen")
		for line: String in report:
			print("OpenOB quest: " + line)
	elif event.keycode == KEY_F:
		_cycle_nearest_npc_face_expression()
	elif event.keycode == KEY_N:
		_cycle_player_face_profile()
	elif event.keycode == KEY_G:
		_cycle_player_face_expression()
	elif event.keycode == KEY_I:
		if _gesture_panel_open():
			_toggle_gesture_panel()
		_toggle_inventory()
	elif event.keycode == KEY_Q:
		_cycle_player_spell()
	elif event.keycode == KEY_C:
		_cast_selected_spell()
	elif event.keycode == KEY_M:
		_toggle_gesture_panel()
	elif event.keycode == KEY_COMMA:
		_step_gesture(-1)
	elif event.keycode == KEY_PERIOD:
		_step_gesture(1)
	elif event.keycode == KEY_U:
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
	assets.data_reader = data_reader
	actors.data_reader = data_reader
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
	_initialize_player_game_state()
	await hud.load_assets(assets)

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

func _initialize_player_game_state() -> void:
	var player_form_id := int(data_reader.find_form_id_by_editor_id("Player"))
	if player_form_id <= 0:
		push_warning("The installed game data has no Player base record; player vitals and starting equipment are unavailable")
		return
	_player_base_record = data_reader.find_npc_base(player_form_id)
	if _player_base_record.is_empty():
		push_warning("Could not read actor values and inventory from the installed game's Player base record")
		return
	_player_actor_values_ready = _player_actor_values.initialize_from_base(_player_base_record)
	_player_game_settings.clear()
	for setting_name: String in PLAYER_DYNAMIC_GAME_SETTINGS:
		_player_game_settings[setting_name] = data_reader.get_float_game_setting(setting_name, 0.0)
	_player_actor_values.configure_game_settings(_player_game_settings)
	if not _player_actor_values_ready:
		push_warning("The Player base record has no usable health, magicka, and fatigue values; HUD vitals will be hidden")
	for spell_value: Variant in _player_base_record.get("spell_form_ids", PackedInt64Array()):
		var spell_form_id := int(spell_value)
		if spell_form_id > 0 and str(data_reader.find_record_type(spell_form_id)) == "SPEL":
			if not _player_spell_form_ids.has(spell_form_id):
				_player_spell_form_ids.push_back(spell_form_id)
	if not _player_spell_form_ids.is_empty():
		# The base record's first SPLO is the data-defined initial selection; Q and the inventory select other known spells.
		_player_selected_spell_form_id = _player_spell_form_ids[0]
	_refresh_inventory_hud()
	print("OpenOB player record %s: actor_values=%s known_spells=%d starting_items=%d" % [
		str(_player_base_record.get("name", "Player")),
		str(_player_actor_values.snapshot()),
		_player_spell_form_ids.size(),
		_player_base_record.get("inventory", []).size(),
	])

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

func _physics_process(delta: float) -> void:
	physics_grabber.physics_update(delta)
	if not _world_loading and not _inventory_open and not _dialogue_active and not _dialogue_exit_transition and not player.face_preview_enabled:
		_aimed_target = targeting.acquire()
	else:
		_aimed_target = InteractionTargeting.empty_snapshot()
	if quest_world == null:
		return
	# A dialogue is a script pause as well as a camera mode. Let the selected reply finish and the camera return before
	# GameMode, trigger zones, package completion, or route refreshes can advance the quest.
	if _dialogue_active or _dialogue_exit_transition:
		return
	_sync_player_actor_values_to_quest_world()
	var result: Dictionary = quest_world.tick(
		delta, Callable(self, "_quest_distance"), Callable(self, "_quest_world_command")
	)
	for line: String in _apply_driver_result(result):
		print("OpenOB quest: " + line)
	if _needs_route_refresh(result):
		_refresh_npc_routes()
	_try_npc_initiated_dialogues()
	_fire_trigger_zones()
	_player_route_timer -= delta
	if _player_route_timer <= 0.0:
		_player_route_timer = 0.5
		_update_dynamic_target_routes()
	_open_doors_on_npc_routes()

## Trigger zones of the cell: a reference whose base has an object script with an OnTrigger block. The zone's OnTrigger
## runs each time the player enters its box, until the script disables the zone.
var _trigger_zones: Array[Dictionary] = []
var _cell_setup_done := false

func _find_trigger_zones(generation: int) -> void:
	var zones: Array[Dictionary] = []
	for reference_value: Variant in current_cell.get("references", []):
		var reference: Dictionary = reference_value
		var script_form_id := int(reference.get("script_form_id", 0))
		if script_form_id == 0:
			continue
		var box := AABB()
		var has_box := false
		for mesh_entry: Dictionary in await assets.meshes_for_model(str(reference.get("model_path", ""))):
			var mesh := mesh_entry.get("mesh") as Mesh
			if mesh == null:
				continue
			box = mesh.get_aabb() if not has_box else box.merge(mesh.get_aabb())
			has_box = true
		if not has_box:
			continue
		var world_box := _reference_transform(reference) * box
		zones.push_back({"script_form_id": script_form_id, "box": world_box, "inside": false, "disabled": false})
		print("OpenOB scripted trigger %08X: box %s" % [script_form_id, str(world_box)])
	if generation == _npc_stream_generation:
		_trigger_zones = zones

## Travel and follow packages can cross a closed doorway in the nav mesh. When
## an upcoming route segment crosses a door and the actor is close to it, open
## that actual DOOR reference before the actor reaches its collision body.
const DOOR_APPROACH_MARGIN_M := 0.5
## How far a speaking or gazing NPC turns its head toward its target, from the pose its animation gives.
const NPC_HEAD_LOOK_MAX_ANGLE := deg_to_rad(48.0)

func _open_doors_on_npc_routes() -> void:
	for actor: Dictionary in _npc_actors:
		var package: Dictionary = actor.get("package", {})
		if package.is_empty():
			continue
		var root := actor.get("root") as Node3D
		if not is_instance_valid(root) or bool(root.get("inactive")):
			continue
		var route_value: Variant = root.get("waypoints")
		if not route_value is Array:
			continue
		var route_points: Array = route_value
		var waypoint_index := int(root.get("waypoint_index"))
		if waypoint_index < 0 or waypoint_index >= route_points.size():
			continue
		var route_start := root.global_position
		var actor_radius := _actor_collision_radius(root)
		for door: Dictionary in director.door_references:
			var reference: Dictionary = door.get("reference", {})
			if quest_bridge.is_door_locked(reference, self):
				continue
			var state_key := "door_open_%08x" % int(reference.get("form_id", 0))
			if has_meta(state_key) and bool(get_meta(state_key)):
				continue
			var box: AABB = door.get("box", AABB())
			var activation_bounds := box.grow(actor_radius)
			var route_crosses_door := false
			for route_index in range(waypoint_index, route_points.size()):
				var segment_start: Vector3 = route_start if route_index == waypoint_index else route_points[route_index - 1]
				var segment_end: Vector3 = route_points[route_index]
				if activation_bounds.intersects_segment(segment_start, segment_end) != null:
					route_crosses_door = true
					break
			if not route_crosses_door:
				continue
			var closest_door_point := Vector3(
				clampf(route_start.x, box.position.x, box.end.x),
				clampf(route_start.y, box.position.y, box.end.y),
				clampf(route_start.z, box.position.z, box.end.z)
			)
			var distance_to_door := Vector2(route_start.x - closest_door_point.x, route_start.z - closest_door_point.z).length()
			if distance_to_door > actor_radius + DOOR_APPROACH_MARGIN_M:
				continue
			var report := quest_bridge.set_door_open_state(reference, true, self)
			if report.begins_with("applied:"):
				print("OpenOB door: " + report)
			else:
				# The route is checked every physics frame: warn once per door, not sixty times a second.
				var warned_key := "door_warned_%08x" % int(reference.get("form_id", 0))
				if not has_meta(warned_key):
					set_meta(warned_key, true)
					push_warning("OpenOB AI door: " + report)

func _actor_collision_radius(actor: Node3D) -> float:
	for child: Node in actor.get_children():
		var collision := child as CollisionShape3D
		if collision == null or collision.shape == null:
			continue
		var shape_margin := collision.shape.margin
		if collision.shape is CapsuleShape3D:
			return (collision.shape as CapsuleShape3D).radius + shape_margin
		if collision.shape is CylinderShape3D:
			return (collision.shape as CylinderShape3D).radius + shape_margin
		if collision.shape is SphereShape3D:
			return (collision.shape as SphereShape3D).radius + shape_margin
		if collision.shape is BoxShape3D:
			var box_shape := collision.shape as BoxShape3D
			return maxf(box_shape.size.x, box_shape.size.z) * 0.5 + shape_margin
	return 0.0

## Follow packages have a moving target, not a terminal destination. Hold at the authored distance and resume
## tracking when the leader moves; completing the route must not fire OnPackageDone or freeze the follower.
func _hold_dynamic_follow_route(actor: Dictionary, root: Node3D, target_form_id: int, arrival_distance: float) -> void:
	var active_route: Array = root.get("waypoints") if root.get("waypoints") is Array else []
	if not active_route.is_empty():
		var stopped_route: Array[Dictionary] = []
		root.call("configure_route", stopped_route, false, 0.0, arrival_distance)
	actor.erase("route_target")
	if int(actor.get("follow_hold_target_form_id", 0)) != target_form_id:
		print("OpenOB AI follow: %s holds %s within %.2fm and keeps tracking" % [
			str(actor.get("reference_name", actor.get("name", "NPC"))),
			_package_location_label(target_form_id),
			arrival_distance,
		])
	actor["follow_hold_target_form_id"] = target_form_id

## Length in seconds of a spoken reply, from its voice file. The voice folder is the speaker's voice type, which is not read
## yet, so each race and sex folder is tried; a reply's form ID names one file. Null when no folder has it, so the quest
## estimates the length from the text.
const VOICE_FOLDERS := ["argonian", "breton", "dark seducer", "dremora", "golden saint", "high elf", "imperial", "nord", "redguard", "sheogorath"]
var _speech_length_cache: Dictionary = {}

func _speech_seconds(_speaker: int, quest: String, topic: String, reply: int, line_number: int, _text: String) -> Variant:
	var file_name := "%s_%s_%08x_%d.mp3" % [quest.to_lower(), topic.to_lower(), reply, maxi(1, line_number)]
	if _speech_length_cache.has(file_name):
		return _speech_length_cache[file_name]
	var length: Variant = null
	for folder: String in VOICE_FOLDERS:
		for sex: String in ["m", "f"]:
			var bytes: PackedByteArray = data_reader.read_asset("sound\\voice\\oblivion.esm\\%s\\%s\\%s" % [folder, sex, file_name])
			if bytes.is_empty():
				continue
			var stream := AudioStreamMP3.new()
			stream.data = bytes
			length = stream.get_length()
			break
		if length != null:
			break
	_speech_length_cache[file_name] = length
	return length

var _player_route_timer := 0.0

## Player-targeted packages and Follow packages track their live target as it moves.
func _update_dynamic_target_routes() -> void:
	for actor: Dictionary in _npc_actors:
		var package: Dictionary = actor.get("package", {})
		var destination_form_id := _package_destination_form_id(package)
		var follows_player := destination_form_id == PLAYER_REFERENCE_FORM_ID
		var follows_actor := _is_dynamic_follow_package(package)
		var uses_target := int(package.get("package_type", -1)) == AI_PACKAGE_TYPE_USE_ITEM_AT
		if (not follows_player and not follows_actor and not uses_target) or bool(actor.get("package_done", false)):
			continue
		var root := actor.get("root") as Node3D
		if not is_instance_valid(root) or bool(root.get("inactive")):
			continue
		if root.has_method("is_yielding") and bool(root.call("is_yielding")):
			continue
		var destination_value: Variant = _package_destination_position(package)
		if destination_value == null:
			continue
		var destination: Vector3 = destination_value
		var arrival_distance := _package_destination_arrival_distance(package, root)
		if uses_target:
			arrival_distance = float(actor.get("package_arrival_distance", arrival_distance))
		var destination_distance := Vector2(root.global_position.x - destination.x, root.global_position.z - destination.z).length()
		if uses_target and not bool(actor.get("package_target_activated", false)) \
				and destination_distance <= AI_USE_ITEM_ACTIVATION_RADIUS_GAME_UNITS * game_units_to_meters:
			actor["package_target_activated"] = true
			_activate_ai_package_target(actor, package)
			# Activating the target may advance the quest and replace this package synchronously.
			if str((actor.get("package", {}) as Dictionary).get("editor_id", "")) != str(package.get("editor_id", "")):
				continue
		if destination_distance <= arrival_distance:
			var active_route: Array = root.get("waypoints") if root.get("waypoints") is Array else []
			if follows_actor:
				_hold_dynamic_follow_route(actor, root, destination_form_id, arrival_distance)
				continue
			if not active_route.is_empty():
				var stopped_route: Array[Dictionary] = []
				root.call("configure_route", stopped_route, false, 0.0, arrival_distance)
			# A moving target can enter its authored radius between waypoints. Use Item At packages can also reach their
			# location without the route controller emitting its final waypoint signal after collision resolution.
			_on_actor_route_finished(int(actor.get("reference_id", 0)))
			continue
		if uses_target:
			continue
		var target: Vector3 = actor.get("route_target", Vector3.INF)
		var active_route: Array = root.get("waypoints") if root.get("waypoints") is Array else []
		var route_index := int(root.get("waypoint_index"))
		var route_is_active := route_index >= 0 and route_index < active_route.size()
		if target.distance_to(destination) <= 1.0 and route_is_active:
			continue
		actor.erase("follow_hold_target_form_id")
		actor["route_target"] = destination
		var waypoints: Array[Dictionary] = []
		var route_path := director.navigation_path(
			root.global_position, destination, _actor_collision_radius(root), true
		)
		var route_uses_pathgrid := bool(director.get("last_navigation_path_uses_pathgrid"))
		var flags := int(package.get("flags", 0))
		var speed := 3.4 if (flags & AI_PACKAGE_FLAG_ALWAYS_RUN) != 0 else 1.3
		for point: Vector3 in route_path:
			waypoints.push_back({"position": point, "speed_mps": speed})
		root.call("configure_route", waypoints, false, 0.0, arrival_distance, route_uses_pathgrid)
		print("OpenOB AI route update: %s from=%s destination=%s at=%s authored_height=%s path=%s" % [
			str(actor.get("reference_name", actor.get("name", "NPC"))),
			str(root.global_position),
			_package_location_label(destination_form_id),
			str(destination),
			str(route_uses_pathgrid),
			str(route_path),
		])

## Runs the OnTrigger of each trigger zone the player has just entered, until the zone is disabled.
func _fire_trigger_zones() -> void:
	if quest_world == null:
		return
	for zone: Dictionary in _trigger_zones:
		if bool(zone.get("disabled", false)):
			continue
		var inside := (zone.get("box") as AABB).has_point(player.global_position)
		var was_inside := bool(zone.get("inside", false))
		zone["inside"] = inside
		if not inside or was_inside:
			continue
		_sync_player_actor_values_to_quest_world()
		var result: Dictionary = quest_world.run_object_event(int(zone.get("script_form_id", 0)), "onTrigger", "player", Callable(self, "_quest_distance"))
		for line: String in _apply_driver_result(result):
			print("OpenOB trigger: " + line)
		for action: Dictionary in result.get("actions", []):
			if str(action.get("command", "")).to_lower() == "disable":
				zone["disabled"] = true
		if _needs_route_refresh(result):
			_refresh_npc_routes()

## Starts a quest at a stage (default 0) in the quest world, which is created on the first start.
## The world then ticks every physics frame, and every started quest runs its GameMode.
func start_quest(quest_editor_id: String, stage: int = 0) -> PackedStringArray:
	if data_reader == null or not data_reader.is_ready():
		return PackedStringArray(["game data is not ready"])
	var executable_path := _game_executable_path()
	if not FileAccess.file_exists(executable_path):
		return PackedStringArray(["Oblivion.exe not found at %s (set OBLIVION_EXE)" % executable_path])
	var cache_dir := DerivedResourceCache.cache_dir()
	if quest_world == null:
		quest_world = data_reader.create_quest_world(executable_path, cache_dir)
		if quest_world == null:
			return PackedStringArray(["quest world not created (command table of %s)" % executable_path])
		quest_world.set_speech_length(Callable(self, "_speech_seconds"))
		# Dialogue conditions read the currently loaded Player base record until character creation supplies live identity.
		var player_race_form_id := int(_player_base_record.get("race_form_id", 0))
		var player_race_editor_id := str(data_reader.find_editor_id(player_race_form_id)) if player_race_form_id > 0 else ""
		quest_world.set_listener(player_race_editor_id, bool(_player_base_record.get("female", false)))
		_sync_player_actor_values_to_quest_world()
		for actor: Dictionary in _npc_actors:
			_register_quest_actor(actor)
	_register_cell_npc_references(current_cell)
	if quest_world.get_stage(quest_editor_id) < 0:
		return PackedStringArray(["quest %s has no script" % quest_editor_id])
	if route_quest_editor_id.is_empty():
		route_quest_editor_id = quest_editor_id
	_sync_player_actor_values_to_quest_world()
	var report := _apply_driver_result(quest_world.start(quest_editor_id, stage, Callable(self, "_quest_distance")))
	_refresh_npc_routes()
	return report


func _register_quest_actor(actor: Dictionary) -> void:
	if quest_world == null:
		return
	var reference_name := str(actor.get("reference_name", ""))
	var base_form_id := int(actor.get("base_form_id", 0))
	quest_world.set_reference_base(reference_name, base_form_id)
	if not quest_world.add_actor(base_form_id, reference_name):
		push_warning("OpenOB quest: no GameMode script for actor %s" % reference_name)
	# A MoveTo issued before this actor was streamed in applies now.
	var pending_move: Variant = quest_bridge.take_pending_move(int(actor.get("reference_id", 0)))
	var actor_root := actor.get("root") as Node3D
	if pending_move != null and is_instance_valid(actor_root):
		if actor_root.has_method("teleport_to"):
			actor_root.call("teleport_to", pending_move)
		else:
			actor_root.global_position = pending_move
	# An idle picked before this actor was streamed in plays now.
	var pending: Dictionary = _pending_idles.get(reference_name.to_lower(), {})
	if not pending.is_empty():
		_pending_idles.erase(reference_name.to_lower())
		_start_npc_idle(actor, str(pending.path), str(pending.idle_id))


func _register_cell_npc_references(cell: Dictionary) -> void:
	if quest_world == null or data_reader == null:
		return
	for reference_value: Variant in cell.get("references", []):
		var reference: Dictionary = reference_value
		if str(reference.get("record_type", "")) != "ACHR":
			continue
		var reference_name := str(reference.get("reference_name", "")).strip_edges()
		var base_form_id := int(reference.get("base_form_id", 0))
		if reference_name.is_empty() or str(data_reader.find_record_type(base_form_id)) != "NPC_":
			continue
		quest_world.set_reference_base(reference_name, base_form_id)

## Keeps GetAV/GetBaseAV in loaded quest scripts tied to the same current/base values drawn on the HUD.
func _sync_player_actor_values_to_quest_world() -> void:
	if quest_world == null or not _player_actor_values_ready:
		return
	quest_world.set_player_actor_values(_player_actor_values.snapshot())

## Names the speaker of each spoken line (its base form is the second argument) before the bridge prints it.
func _name_speakers(result: Dictionary) -> void:
	for action: Dictionary in result.get("actions", []):
		var arguments: Array = action.get("arguments", [])
		if str(action.get("command", "")).to_lower() == "speech" and arguments.size() > 1:
			arguments[1] = str(data_reader.find_editor_id(int(arguments[1])))

## True when a result asked the NPCs to re-evaluate their packages (evp). As in the game, a stage change alone does not
## re-evaluate them: the data asks for it with evp, so a package that is still the first to hold keeps its route.
func _needs_route_refresh(result: Dictionary) -> bool:
	for action: Dictionary in result.get("actions", []):
		if str(action.get("command", "")).to_lower() == "evp":
			return true
	return false

func _apply_driver_result(result: Dictionary) -> PackedStringArray:
	_name_speakers(result)
	var report := PackedStringArray()
	for change: String in result.get("stage_changes", PackedStringArray()):
		report.push_back("stage %s" % change)
	for error_text: String in result.get("parse_errors", PackedStringArray()):
		report.push_back("parse error " + error_text)
	# Quest actions produced during dialogue are held until the response and camera exit are both complete. This prevents
	# stage results from speaking, turning, opening doors, or changing packages over the active dialogue.
	var actions_to_apply: Array[Dictionary] = []
	for action_value: Variant in result.get("actions", []):
		var action: Dictionary = action_value
		if _dialogue_active or _dialogue_exit_transition:
			_pending_dialogue_actions.push_back(action.duplicate(true))
			var command := str(action.get("command", "")).to_lower()
			var arguments: Array = action.get("arguments", [])
			if command == "look" and not arguments.is_empty():
				report.push_back("defers scripted look: %s will look at %s after the dialogue camera returns" % [str(action.get("target", "NPC")), str(arguments[0])])
			elif command == "speech":
				var speaker := str(arguments[1]) if arguments.size() > 1 else str(action.get("target", "NPC"))
				report.push_back("defers scripted speech from %s until the dialogue camera returns" % speaker)
			continue
		actions_to_apply.push_back(action)
	# State and unsupported-command reports are summarized once. Speech is an event, so repeated identical dialogue lines
	# remain visible each time the script says them.
	for line: String in quest_bridge.apply_actions(actions_to_apply, current_cell, self, Callable(self, "_reference_transform")):
		if line.strip_edges().begins_with("says (") or line.strip_edges().begins_with("picks idle"):
			report.push_back(line)
		elif not _reported_bridge_lines.has(line):
			_reported_bridge_lines[line] = true
			report.push_back(line)
	# A distance to a reference outside the loaded cell is far away by design (see _quest_distance), so it is not
	# reported. Other functions the scene cannot answer come back on every tick; report each one only the first time.
	for name: String in result.get("unanswered", PackedStringArray()):
		if name != "getdistance" and not _reported_unanswered.has(name):
			_reported_unanswered[name] = true
			report.push_back("unanswered (first time): " + name)
	return report

## Distance in game units between two named references of the loaded cell (or the player).
## Returns null when a name is not in the scene, so the driver treats the condition as unanswered.
func _quest_distance(from: String, to: String) -> Variant:
	var from_position = _quest_position(from)
	var to_position = _quest_position(to)
	if from_position == null or to_position == null:
		return null
	return (from_position as Vector3).distance_to(to_position as Vector3) / game_units_to_meters

## Answers world-state queries made by GameMode scripts during a tick.
func _quest_world_command(command: String, target: String, _arguments: Array) -> Variant:
	if command.to_lower() != "getopenstate":
		return null
	var wanted_name := target.strip_edges().to_lower()
	for reference_value: Variant in current_cell.get("references", []):
		var reference: Dictionary = reference_value
		if str(reference.get("reference_name", "")).to_lower() != wanted_name:
			continue
		return quest_bridge.get_door_open_state(reference, self)
	return null


func door_lock_level(reference: Dictionary) -> int:
	return quest_bridge.door_lock_level(reference, self)

## Origins of the loaded cell's references by name and by form id, built once per cell: a quest asks for a distance on
## every physics tick, and scanning every reference each time is wasteful.
var _reference_index_cell: Dictionary = {}
var _reference_index: Dictionary = {}

func _reference_origin_index() -> Dictionary:
	if is_same(_reference_index_cell, current_cell) and not _reference_index.is_empty():
		return _reference_index
	var by_name: Dictionary = {}
	var by_id: Dictionary = {}
	for reference_value: Variant in current_cell.get("references", []):
		var reference: Dictionary = reference_value
		var origin := _reference_origin(reference)
		var reference_name := str(reference.get("reference_name", ""))
		if not reference_name.is_empty() and not by_name.has(reference_name):
			by_name[reference_name] = origin
		by_id[int(reference.get("form_id", 0))] = origin
	_reference_index = {"by_name": by_name, "by_id": by_id}
	_reference_index_cell = current_cell
	return _reference_index

func _quest_position(name: String) -> Variant:
	if name.to_lower() == "player":
		return player.global_position
	var node := get_node_or_null(NodePath(name)) as Node3D
	if node != null:
		return node.global_position
	var origins: Dictionary = _reference_origin_index().get("by_name", {})
	return origins.get(name)

## Gives every placed NPC the route of the package it starts at the quest's current stage.
func _refresh_npc_routes() -> void:
	if _dialogue_active or _dialogue_exit_transition:
		_dialogue_pending_route_refresh = true
		return
	for actor: Dictionary in _npc_actors:
		_refresh_actor_route(actor)

func _refresh_actor_route(actor: Dictionary) -> void:
	var root: Node = actor.get("root")
	if not is_instance_valid(root) or bool(root.get("inactive")):
		return
	var package: Dictionary = {}
	var npc_id := str(actor.get("npc_editor_id", ""))
	if quest_world != null and not route_quest_editor_id.is_empty() and not npc_id.is_empty():
		package = quest_world.select_package(route_quest_editor_id, npc_id)
	# The same package keeps its route: starting it again would finish at once and run its OnPackageDone again.
	var previous: Dictionary = actor.get("package", {})
	if not package.is_empty() and str(package.get("editor_id", "")) == str(previous.get("editor_id", "")):
		var current_route: Array = root.get("waypoints") if root.get("waypoints") is Array else []
		var current_index := int(root.get("waypoint_index"))
		var remaining_path: Array[Vector3] = []
		for index in range(current_index, current_route.size()):
			remaining_path.push_back(current_route[index])
		print("OpenOB AI route: %s keeps package=%s from=%s destination=%s remaining_path=%s" % [
			str(actor.get("reference_name", actor.get("name", "NPC"))),
			str(package.get("editor_id", "")),
			str((root as Node3D).global_position),
			_package_location_label(_package_destination_form_id(package)),
			str(remaining_path),
		])
		return
	# A new package starts a new activation: its OnPackageDone may run once when its route ends.
	if str(package.get("editor_id", "")) != str(previous.get("editor_id", "")):
		actor["package_done"] = false
		actor["package_target_activated"] = false
		actor.erase("package_arrival_distance")
		actor.erase("follow_hold_target_form_id")
	if int(package.get("form_id", 0)) != int(previous.get("form_id", 0)):
		actor.erase("npc_greet_attempted_package_id")
		actor.erase("npc_greet_last_attempt_msec")
		actor.erase("npc_greet_debug_package_id")
		actor.erase("npc_greet_range_package_id")
		actor.erase("npc_greet_range_bucket")
		actor.erase("npc_greet_unavailable_package_id")
		actor.erase("npc_greet_bad_distance_package_id")
	actor["package"] = package
	if quest_world != null:
		quest_world.set_actor_package(str(actor.get("reference_name", "")), int(package.get("form_id", 0)))
	var waypoints: Array[Dictionary] = []
	var route_path := PackedVector3Array()
	var route_uses_pathgrid := false
	var final_arrival_distance := 0.08
	# Packages without a PLDT location can still name a PTDT target reference to approach.
	var destination_form_id := _package_destination_form_id(package)
	if not package.is_empty() and destination_form_id != 0:
		var position = _package_destination_position(package)
		if position == null:
			print("OpenOB package %s for %s: target %s is not available in this cell" % [
				str(package.get("editor_id", "")), str(actor.get("name", "")), _package_location_label(destination_form_id)
			])
		else:
			final_arrival_distance = _package_destination_arrival_distance(package, root as Node3D)
			var destination: Vector3 = position
			if destination_form_id == PLAYER_REFERENCE_FORM_ID or _is_dynamic_follow_package(package):
				actor["route_target"] = destination
			else:
				actor.erase("route_target")
			var flags := int(package.get("flags", 0))
			var speed := 3.4 if (flags & AI_PACKAGE_FLAG_ALWAYS_RUN) != 0 else 1.3
			route_path = director.navigation_path(
				(root as Node3D).global_position, destination, _actor_collision_radius(root as Node3D), true
			)
			route_uses_pathgrid = bool(director.get("last_navigation_path_uses_pathgrid"))
			if int(package.get("package_type", -1)) == AI_PACKAGE_TYPE_USE_ITEM_AT and not route_path.is_empty():
				var path_endpoint: Vector3 = route_path[route_path.size() - 1]
				var navmesh_snap_distance := Vector2(path_endpoint.x - destination.x, path_endpoint.z - destination.z).length()
				# The navmesh can project a scripted marker to the nearest walkable edge. Include that projection
				# in the package arrival range, bounded by the actor's collision radius.
				final_arrival_distance += minf(navmesh_snap_distance, _actor_collision_radius(root as Node3D))
			actor["package_arrival_distance"] = final_arrival_distance
			for point: Vector3 in route_path:
				waypoints.push_back({"position": point, "speed_mps": speed})
	# A route that starts ends a whole-body idle: the actor walks. An upper-body idle (pointing, arms crossed) plays on over the walk.
	if not waypoints.is_empty() and bool(actor.get("idle_active", false)) and not bool(actor.get("idle_upper_body", false)):
		_end_npc_idle(actor)
	root.call("configure_route", waypoints, false, 0.0, final_arrival_distance, route_uses_pathgrid)
	print("OpenOB AI route: %s package=%s destination=%s at=%s from=%s authored_height=%s path=%s" % [
		str(actor.get("reference_name", actor.get("name", "NPC"))),
		str(package.get("editor_id", "<none>")),
		_package_location_label(destination_form_id),
		str(_package_destination_position(package)),
		str((root as Node3D).global_position),
		str(route_uses_pathgrid),
		str(route_path),
	])
	if not root.has_meta("route_finished_connected"):
		root.set_meta("route_finished_connected", true)
		root.route_finished.connect(_on_actor_route_finished.bind(int(actor.get("reference_id", 0))))

## The NPC reached its package destination: perform any target activation, then run OnPackageDone.
func _on_actor_route_finished(actor_reference_id: int) -> void:
	if _dialogue_active or _dialogue_exit_transition:
		if not _pending_dialogue_route_finished_actor_ids.has(actor_reference_id):
			_pending_dialogue_route_finished_actor_ids.push_back(actor_reference_id)
		return
	for actor: Dictionary in _npc_actors:
		if int(actor.get("reference_id", 0)) != actor_reference_id or quest_world == null or route_quest_editor_id.is_empty():
			continue
		var package: Dictionary = actor.get("package", {})
		if package.is_empty() or bool(actor.get("package_done", false)):
			return
		var root := actor.get("root") as Node3D
		if not is_instance_valid(root):
			return
		var destination_form_id := _package_destination_form_id(package)
		var location = _package_destination_position(package)
		if location != null:
			var destination: Vector3 = location
			var horizontal_distance := Vector2(root.global_position.x - destination.x, root.global_position.z - destination.z).length()
			var actor_arrival_distance := float(root.get("arrival_distance")) if root.get("arrival_distance") != null else 0.08
			var arrival_radius := float(actor.get(
				"package_arrival_distance", _package_destination_arrival_distance(package, root)
			))
			if horizontal_distance > arrival_radius:
				# A partial NavigationServer path is not package completion. Replan from the
				# actor's current position, and leave OnPackageDone for actual arrival.
				var retry_path := director.navigation_path(
					root.global_position, destination, _actor_collision_radius(root), true
				)
				var retry_uses_pathgrid := bool(director.get("last_navigation_path_uses_pathgrid"))
				if not retry_path.is_empty():
					var retry_end: Vector3 = retry_path[retry_path.size() - 1]
					var retry_distance := Vector2(root.global_position.x - retry_end.x, root.global_position.z - retry_end.z).length()
					if retry_distance > actor_arrival_distance:
						var flags := int(package.get("flags", 0))
						var speed := 3.4 if (flags & AI_PACKAGE_FLAG_ALWAYS_RUN) != 0 else 1.3
						var waypoints: Array[Dictionary] = []
						if int(package.get("package_type", -1)) == AI_PACKAGE_TYPE_USE_ITEM_AT:
							var endpoint: Vector3 = retry_path[retry_path.size() - 1]
							var snap_distance := Vector2(endpoint.x - destination.x, endpoint.z - destination.z).length()
							arrival_radius = _package_destination_arrival_distance(package, root) \
								+ minf(snap_distance, _actor_collision_radius(root))
							actor["package_arrival_distance"] = arrival_radius
						for point: Vector3 in retry_path:
							waypoints.push_back({"position": point, "speed_mps": speed})
						root.call("configure_route", waypoints, false, 0.0, arrival_radius, retry_uses_pathgrid)
					else:
						push_warning("OpenOB package %s for %s stopped %.2fm from its destination; no reachable route remains" % [
							str(package.get("editor_id", "")), str(actor.get("name", "")), horizontal_distance
						])
				return
		if _is_dynamic_follow_package(package):
			_hold_dynamic_follow_route(
				actor, root, destination_form_id, _package_destination_arrival_distance(package, root)
			)
			return
		actor["package_done"] = true
		print("OpenOB AI route complete: %s package=%s destination=%s" % [
			str(actor.get("reference_name", actor.get("name", "NPC"))),
			str(package.get("editor_id", "")),
			_package_location_label(destination_form_id),
		])
		if int(package.get("package_type", -1)) == AI_PACKAGE_TYPE_USE_ITEM_AT \
				and not bool(actor.get("package_target_activated", false)):
			actor["package_target_activated"] = true
			_activate_ai_package_target(actor, package)
		_sync_player_actor_values_to_quest_world()
		var result: Dictionary = quest_world.run_actor_event(route_quest_editor_id, str(actor.get("npc_editor_id", "")), "OnPackageDone", str(package.get("editor_id", "")), Callable(self, "_quest_distance"))
		for line: String in _apply_driver_result(result):
			print("OpenOB quest: " + line)
		if _needs_route_refresh(result):
			_refresh_npc_routes()
		return


## Use Item At packages first route the actor to their authored location, then activate their target reference.
func _activate_ai_package_target(actor: Dictionary, package: Dictionary) -> void:
	var target_form_id := int(package.get("target_form_id", 0))
	var target_reference := _placed_reference_by_form_id(target_form_id)
	if target_reference.is_empty():
		push_warning("OpenOB AI package %s for %s reached its location, but target %s is not in this cell" % [
			str(package.get("editor_id", "")), str(actor.get("reference_name", "NPC")), _package_location_label(target_form_id)
		])
		return
	var script_form_id := int(target_reference.get("script_form_id", 0))
	if script_form_id <= 0:
		push_warning("OpenOB AI package %s for %s reached target %s, but it has no object script" % [
			str(package.get("editor_id", "")), str(actor.get("reference_name", "NPC")), _package_location_label(target_form_id)
		])
		return
	var target_name := str(target_reference.get("reference_name", "")).strip_edges()
	if target_name.is_empty():
		target_name = "0x%08X" % target_form_id
	var actor_name := str(actor.get("reference_name", actor.get("name", "")))
	var actor_root := actor.get("root") as Node3D
	var location_value: Variant = _package_destination_position(package)
	var location_distance := 0.0
	if is_instance_valid(actor_root) and location_value is Vector3:
		var location: Vector3 = location_value
		location_distance = Vector2(actor_root.global_position.x - location.x, actor_root.global_position.z - location.z).length()
	print("OpenOB AI use item: %s activates %s at %.2fm (range %.2fm) via package=%s" % [
		actor_name,
		target_name,
		location_distance,
		AI_USE_ITEM_ACTIVATION_RADIUS_GAME_UNITS * game_units_to_meters,
		str(package.get("editor_id", "")),
	])
	var result: Dictionary = quest_world.run_object_event(
		script_form_id, "OnActivate", "", Callable(self, "_quest_distance"), target_name, actor_name
	)
	for line: String in _apply_driver_result(result):
		print("OpenOB use item: " + line)
	if _needs_route_refresh(result):
		_refresh_npc_routes()


func _placed_reference_by_form_id(form_id: int) -> Dictionary:
	for reference_value: Variant in current_cell.get("references", []):
		var reference: Dictionary = reference_value
		if int(reference.get("form_id", 0)) == form_id:
			return reference
	return {}


## An active Ambush package aimed at the player starts the eligible NPC greeting at its authored target distance.
## Scripted Say/SayTo actions only speak and direct the speaker's gaze; they do not open the dialogue session.
func _try_npc_initiated_dialogues() -> void:
	if _world_loading or _inventory_open or _dialogue_active or _dialogue_exit_transition \
			or player.face_preview_enabled or quest_world == null:
		return
	for actor: Dictionary in _npc_actors:
		var package: Dictionary = actor.get("package", {})
		if package.is_empty() or int(package.get("package_type", -1)) != AI_PACKAGE_TYPE_AMBUSH:
			continue
		var package_id := int(package.get("form_id", 0))
		if package_id <= 0 \
				or int(package.get("target_type", -1)) != AI_PACKAGE_TARGET_REFERENCE \
				or int(package.get("target_form_id", 0)) != PLAYER_REFERENCE_FORM_ID:
			continue
		if int(actor.get("npc_greet_attempted_package_id", 0)) == package_id:
			continue
		var actor_root := actor.get("root") as Node3D
		if not is_instance_valid(actor_root) or not actor_root.visible or bool(actor_root.get("inactive")):
			continue
		var target_distance := int(package.get("target_distance", 0))
		if target_distance <= 0:
			target_distance = int(package.get("radius", 0))
		var distance_game_units := Vector2(
			actor_root.global_position.x - player.global_position.x,
			actor_root.global_position.z - player.global_position.z
		).length() / game_units_to_meters
		if int(actor.get("npc_greet_debug_package_id", 0)) != package_id:
			actor["npc_greet_debug_package_id"] = package_id
			print("OpenOB dialogue: force-greet package %s target_type=%d target=0x%08X distance=%.1f target_distance=%d location_radius=%d" % [
				str(package.get("editor_id", "Ambush")),
				int(package.get("target_type", -1)),
				int(package.get("target_form_id", 0)),
				distance_game_units,
				target_distance,
				int(package.get("radius", 0)),
			])
		if target_distance <= 0:
			if int(actor.get("npc_greet_bad_distance_package_id", 0)) != package_id:
				actor["npc_greet_bad_distance_package_id"] = package_id
				push_warning("OpenOB dialogue: %s has a player-targeted Ambush package without a usable target distance" % str(actor.get("reference_name", "NPC")))
			continue
		if distance_game_units > float(target_distance):
			var distance_bucket := int(floor(distance_game_units / 50.0))
			if int(actor.get("npc_greet_range_package_id", 0)) != package_id \
					or int(actor.get("npc_greet_range_bucket", -1)) != distance_bucket:
				actor["npc_greet_range_package_id"] = package_id
				actor["npc_greet_range_bucket"] = distance_bucket
				print("OpenOB dialogue: %s waits for force-greet range at %.1f/%d units" % [
					str(actor.get("reference_name", "NPC")), distance_game_units, target_distance
				])
			continue
		var now_msec := Time.get_ticks_msec()
		if now_msec - int(actor.get("npc_greet_last_attempt_msec", 0)) < 750:
			continue
		actor["npc_greet_last_attempt_msec"] = now_msec
		if _begin_dialogue(actor, false):
			actor["npc_greet_attempted_package_id"] = package_id
			print("OpenOB dialogue: %s force-greets the player via %s at %.1f/%d units" % [
				str(actor.get("reference_name", actor.get("name", "NPC"))),
				str(package.get("editor_id", "Ambush")), distance_game_units, target_distance
			])
			return
		if int(actor.get("npc_greet_unavailable_package_id", 0)) != package_id:
			actor["npc_greet_unavailable_package_id"] = package_id
			print("OpenOB dialogue: %s is in force-greet range, but no Greeting response is eligible yet; retrying" % str(actor.get("reference_name", "NPC")))

## Position of a placed reference of the loaded cell, by form ID, or null when the cell does not have it.
func _location_position(form_id: int) -> Variant:
	if form_id == 0:
		return null
	# Form 0x14 is the player's reference: a package near the player walks to the player.
	if form_id == 0x14:
		return player.global_position
	var origins: Dictionary = _reference_origin_index().get("by_id", {})
	return origins.get(form_id)

func _package_location_label(form_id: int) -> String:
	if form_id == 0:
		return "none"
	if form_id == 0x14:
		return "Player"
	var editor_id := str(data_reader.find_editor_id(form_id)) if data_reader != null else ""
	return "%s (0x%08X)" % [editor_id, form_id] if not editor_id.is_empty() else "0x%08X" % form_id

func _package_arrival_radius(package: Dictionary, root: Node3D) -> float:
	var actor_arrival_distance := float(root.get("arrival_distance")) if root.get("arrival_distance") != null else 0.08
	var package_radius := float(package.get("radius", 0)) * game_units_to_meters
	return package_radius + _actor_collision_radius(root) + actor_arrival_distance


func _package_destination_form_id(package: Dictionary) -> int:
	var location_form_id := int(package.get("location_form_id", 0))
	if location_form_id != 0:
		return location_form_id
	if int(package.get("target_type", -1)) == AI_PACKAGE_TARGET_REFERENCE:
		return int(package.get("target_form_id", 0))
	return 0


func _is_dynamic_follow_package(package: Dictionary) -> bool:
	return int(package.get("package_type", -1)) == AI_PACKAGE_TYPE_FOLLOW \
		and int(package.get("location_form_id", 0)) == 0 \
		and int(package.get("target_type", -1)) == AI_PACKAGE_TARGET_REFERENCE


func _npc_reference_position(reference_form_id: int) -> Variant:
	for actor: Dictionary in _npc_actors:
		if int(actor.get("reference_id", 0)) != reference_form_id:
			continue
		var root := actor.get("root") as Node3D
		if is_instance_valid(root):
			return root.global_position
	return null


func _package_destination_position(package: Dictionary) -> Variant:
	var destination_form_id := _package_destination_form_id(package)
	if destination_form_id == PLAYER_REFERENCE_FORM_ID:
		return player.global_position
	if _is_dynamic_follow_package(package):
		return _npc_reference_position(destination_form_id)
	return _location_position(destination_form_id)


func _package_destination_arrival_distance(package: Dictionary, root: Node3D) -> float:
	if int(package.get("location_form_id", 0)) != 0:
		return _package_arrival_radius(package, root)
	var target_distance := int(package.get("target_distance", 0))
	if target_distance > 0:
		var actor_arrival_distance := float(root.get("arrival_distance")) if root.get("arrival_distance") != null else 0.08
		return maxf(actor_arrival_distance, float(target_distance) * game_units_to_meters)
	return _package_arrival_radius(package, root)

## Runs one stage of a quest against the loaded cell and returns the report lines.
## The executable comes from OBLIVION_EXE, or from the usual install layout next to Data.
func run_quest_stage(quest_editor_id: String, stage: int) -> PackedStringArray:
	if data_reader == null or not data_reader.is_ready():
		return PackedStringArray(["game data is not ready"])
	var executable_path := _game_executable_path()
	if not FileAccess.file_exists(executable_path):
		return PackedStringArray(["Oblivion.exe not found at %s (set OBLIVION_EXE)" % executable_path])
	var cache_dir := DerivedResourceCache.cache_dir()
	var result: Dictionary = data_reader.run_quest_stage(quest_editor_id, stage, executable_path, cache_dir)
	var error := str(result.get("error", ""))
	if not error.is_empty():
		return PackedStringArray(["stage %s of %s not run: %s" % [stage, quest_editor_id, error]])
	var report := quest_bridge.apply(result.get("runs", []), current_cell, self, Callable(self, "_reference_transform"))
	for line: String in report:
		print("OpenOB stage %s/%d: %s" % [quest_editor_id, stage, line])
	return report

func _game_executable_path() -> String:
	var environment_path := OS.get_environment("OBLIVION_EXE").strip_edges()
	if not environment_path.is_empty():
		return environment_path
	# The data directory is <install>/game_info/data/Data; the executable sits next to it in <install>/game_info/data.
	return _game_data_path().get_base_dir().path_join("Oblivion.exe")

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
		physics_grabber.release_without_throw()
		_exterior_collision_stream_enabled = false
		_exterior_collision_stream_busy = false
		_exterior_collision_busy_generation = -1
		_exterior_collision_scan_cooldown = 0.0
		_exterior_collision_bodies.clear()
		_exterior_collision_attempted_ids.clear()
		_exterior_terrain_collision_stream_enabled = false
		_exterior_terrain_collision_scan_cooldown = 0.0
		_exterior_terrain_collision_bodies.clear()
		_exterior_terrain_collision_attempted_ids.clear()
		_placed_items.clear()
		_container_reference_cache.clear()
		director.clear_door_references()
		# Doors are rebuilt closed, so the open marks of the previous cell go.
		quest_bridge.reset_cell_state(self)
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
	var pending_dynamic_bodies: Array[RigidBody3D] = []
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
			var tree_texture := await assets.texture_for_path(tree_texture_path)
			if generation != _cell_load_generation:
				return false
			if tree_mesh == null or tree_texture == null:
				continue
			var tree_material := await assets.material_for_texture(
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
		var is_door := base_type == "DOOR"
		var is_pickup_item := base_type in ["ARMO", "CLOT", "WEAP", "ALCH", "AMMO", "APPA", "BOOK", "INGR", "KEYM", "MISC", "SLGM", "SGST"]
		# An item the player took stays gone when its cell is loaded again.
		if is_pickup_item and _picked_up_reference_ids.has(int(reference.get("form_id", 0))):
			continue
		reference_count += 1
		var meshes: Array = await assets.meshes_for_model(model_path)
		if generation != _cell_load_generation:
			return false
		if is_door:
			director.register_door_reference(reference, meshes, _reference_transform(reference))
		var nif_key := model_path.to_lower().replace("\\", "/")
		var physics_metadata: Dictionary = assets.nif_metadata_cache.get(nif_key, {})
		var animation_sequences: Array = physics_metadata.get("animations", [])
		var has_nif_animations := not animation_sequences.is_empty()
		var animate_reference := is_door or has_nif_animations
		if _supports_imported_nif_physics(physics_metadata, meshes):
			var physics_result: Dictionary = await _instantiate_imported_nif_physics(
				int(reference.get("form_id", 0)), reference_transform, model_path, meshes, physics_metadata
			)
			if generation != _cell_load_generation:
				return false
			if not physics_result.is_empty():
				if is_pickup_item:
					_register_imported_physics_pickup(reference, base_form_id, base_type, reference_transform, physics_result)
			for body_value: Variant in physics_result.get("dynamic_bodies", []):
				var dynamic_body := body_value as RigidBody3D
				if is_instance_valid(dynamic_body):
					pending_dynamic_bodies.push_back(dynamic_body)
			if not physics_result.is_empty():
				instance_count += int(physics_result.get("mesh_count", 0))
				collision_count += int(physics_result.get("body_count", 0))
				if reference_count % 8 == 0:
					await get_tree().process_frame
				continue
		var should_collide := (
			not is_pickup_item
			and _should_collide_model(model_path)
			and (not is_exterior or reference_transform.origin.distance_to(player.global_position) <= EXTERIOR_COLLISION_DISTANCE)
		)
		if should_collide:
			_exterior_collision_attempted_ids[int(reference.get("form_id", 0))] = true
			assets.ensure_collision_shape(model_path)
		var animated_reference_root: Node3D = null
		var animated_node_hosts: Dictionary = {}
		if animate_reference:
			animated_reference_root = Node3D.new()
			animated_reference_root.name = "AnimatedReference_%08X" % int(reference.get("form_id", 0))
			animated_reference_root.set_meta("reference_id", int(reference.get("form_id", 0)))
			animated_reference_root.transform = reference_transform
			cell_visual_root.add_child(animated_reference_root)
		var item_mesh_instances: Array[MeshInstance3D] = []
		for mesh_index in range(meshes.size()):
			var mesh_entry: Dictionary = meshes[mesh_index]
			if bool(mesh_entry.get("editor_marker", false)):
				continue
			var model_key := model_path.to_lower().replace("\\", "/")
			var can_batch := (
				is_exterior
				and not is_pickup_item
				and not animate_reference
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
				instance.set_meta("reference_id", int(reference.get("form_id", 0)))
				instance.set_meta("source_mesh_name", mesh_name)
				instance.set_meta("model_path", model_path)
				instance.material_override = await _material_for_reference(
					model_path,
					str(mesh_entry.diffuse_texture_path),
					bool(mesh_entry.get("alpha_blend", false)),
					bool(mesh_entry.get("alpha_test", false)),
					int(mesh_entry.get("alpha_threshold", 128))
				)
				if generation != _cell_load_generation:
					return false
				if animate_reference:
					var parent_node_name := str(mesh_entry.get("parent_node_name", ""))
					var node_host := animated_node_hosts.get(parent_node_name) as Node3D
					if node_host == null:
						if should_collide:
							var animated_body := AnimatableBody3D.new()
							animated_body.collision_layer = 2
							animated_body.collision_mask = 0
							animated_body.sync_to_physics = true
							animated_body.set_meta("reference_id", int(reference.get("form_id", 0)))
							node_host = animated_body
						else:
							node_host = Node3D.new()
						node_host.name = "NifNode_%d" % animated_node_hosts.size()
						node_host.set_meta("nif_node_name", parent_node_name)
						node_host.set_meta("reference_id", int(reference.get("form_id", 0)))
						animated_reference_root.add_child(node_host)
						animated_node_hosts[parent_node_name] = node_host
					instance.transform = Transform3D.IDENTITY
					node_host.add_child(instance)
				else:
					instance.transform = reference_transform
					cell_visual_root.add_child(instance)
				if is_pickup_item:
					item_mesh_instances.push_back(instance)
				instance_count += 1
		if animated_reference_root != null and not animated_node_hosts.is_empty():
			_install_nif_animations(animated_reference_root, physics_metadata, animated_node_hosts)
		var animated_collision_count := 0
		if should_collide and animate_reference and not animated_node_hosts.is_empty():
			animated_collision_count = _add_animated_reference_colliders(
				animated_node_hosts, meshes
			)
		if is_pickup_item and not item_mesh_instances.is_empty():
			var reference_id := int(reference.get("form_id", 0))
			var item_display_name := str(reference.get("reference_name", "")).strip_edges()
			if item_display_name.is_empty():
				item_display_name = str(data_reader.find_editor_id(base_form_id)).strip_edges()
			if item_display_name.is_empty():
				item_display_name = "Item"
			var target_area := _create_pickup_target_area(reference_id, reference_transform, meshes)
			_placed_items[reference_id] = {
				"reference_id": reference_id,
				"base_form_id": base_form_id,
				"record_type": base_type,
				"editor_id": str(data_reader.find_editor_id(base_form_id)),
				"display_name": item_display_name,
				"position": reference_transform.origin,
				"mesh_instances": item_mesh_instances,
				"target_area": target_area,
			}
		if should_collide:
			if animated_collision_count > 0:
				collision_count += animated_collision_count
			elif _add_reference_collider(int(reference.get("form_id", 0)), reference_transform, model_path, is_exterior):
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
	_trim_static_collision_for_animated_openings()
	if not pending_dynamic_bodies.is_empty():
		# Let this cell's static and terrain colliders enter the physics space before dynamic props wake up.
		await get_tree().physics_frame
		if generation != _cell_load_generation:
			return false
		for dynamic_body: RigidBody3D in pending_dynamic_bodies:
			if not is_instance_valid(dynamic_body):
				continue
			if bool(dynamic_body.get_meta("resolve_spawn_penetration", false)):
				_resolve_initial_dynamic_body_penetration(dynamic_body)
			dynamic_body.freeze = false
	if clear_existing and has_node("TestFloor/MeshInstance3D"):
		$TestFloor/MeshInstance3D.visible = collision_count == 0
		$TestFloor/CollisionShape3D.disabled = collision_count > 0
	var cell_label := str(cell.get("display_name", ""))
	if cell_label.is_empty():
		cell_label = "Cell %d,%d" % [int(cell.get("grid_x", 0)), int(cell.get("grid_y", 0))]
	status_label.text = "Cell: %s · %d refs · %d meshes · %d colliders\nWASD move · Shift run · E jump · Ctrl crouch · mouse look/zoom\nQ cycle spell · C cast self spell · I inventory · Hold Mouse1 to grab · release to drop · Mouse2 throw · wheel adjusts distance · Space interact · Esc unlock" % [
		cell_label, cell.references.size(), instance_count, collision_count
	]

	_aimed_target = InteractionTargeting.empty_snapshot()
	_update_hud()
	_refresh_inventory_hud()
	print("OpenOB displayed %s: %d NIF references, %d tree billboards, %d meshes, %d generated colliders, %d terrain tiles; culled %d distant references, skipped %d gates" % [
		cell_label, reference_count, tree_reference_count, instance_count, collision_count, terrain_cells.size(), culled_reference_count, skipped_gate_count
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
	instance.material_override = await assets.material_for_texture(texture_path)
	if generation >= 0 and generation != _cell_load_generation:
		return {}
	instance.scale = Vector3.ONE * game_units_to_meters
	instance.position = position
	cell_visual_root.add_child(instance)

	if _terrain_cell_edge_distance(grid_x, grid_y, player.global_position) > EXTERIOR_TERRAIN_COLLISION_DISTANCE:
		return {"rendered": true, "collider": false}
	return {"rendered": true, "collider": _add_terrain_cell_collider(land)}

func _terrain_cell_edge_distance(grid_x: int, grid_y: int, world_position: Vector3) -> float:
	var cell_size_meters := EXTERIOR_CELL_SIZE * game_units_to_meters
	var min_x := float(grid_x) * cell_size_meters
	var max_x := min_x + cell_size_meters
	var min_z := -float(grid_y + 1) * cell_size_meters
	var max_z := -float(grid_y) * cell_size_meters
	var nearest_x := clampf(world_position.x, min_x, max_x)
	var nearest_z := clampf(world_position.z, min_z, max_z)
	return Vector2(nearest_x - world_position.x, nearest_z - world_position.z).length()

func _add_terrain_cell_collider(land: Dictionary) -> bool:
	var grid_x := int(land.get("grid_x", 0))
	var grid_y := int(land.get("grid_y", 0))
	var cache_key := "%d,%d" % [grid_x, grid_y]
	var existing_entry: Dictionary = _exterior_terrain_collision_bodies.get(cache_key, {})
	var existing_body := existing_entry.get("body") as StaticBody3D
	if is_instance_valid(existing_body):
		return true
	if _exterior_terrain_collision_attempted_ids.has(cache_key):
		return false
	_exterior_terrain_collision_attempted_ids[cache_key] = true
	var heights: PackedFloat32Array = land.get("heights", PackedFloat32Array())
	if heights.size() != 33 * 33:
		return false
	var collision := _land_collision_cache.get(cache_key) as ConcavePolygonShape3D
	if collision == null:
		var mesh_key := "%d,%d,1" % [grid_x, grid_y]
		var terrain_mesh := _land_mesh_cache.get(mesh_key) as ArrayMesh
		if terrain_mesh == null:
			terrain_mesh = _build_land_mesh(heights, 1)
			if terrain_mesh != null:
				_land_mesh_cache[mesh_key] = terrain_mesh
		if terrain_mesh != null:
			collision = NifAssetLibrary.build_concave_shape(terrain_mesh.get_faces())
			if collision != null:
				_land_collision_cache[cache_key] = collision
	if collision == null:
		return false
	var body := StaticBody3D.new()
	body.name = "TerrainCollision_%d_%d" % [grid_x, grid_y]
	body.collision_layer = 2
	body.collision_mask = 0
	body.scale = Vector3.ONE * game_units_to_meters
	body.position = Vector3(grid_x * EXTERIOR_CELL_SIZE, 0.0, -grid_y * EXTERIOR_CELL_SIZE) * game_units_to_meters
	var collision_instance := CollisionShape3D.new()
	collision_instance.shape = collision
	body.add_child(collision_instance)
	cell_visual_root.add_child(body)
	_exterior_terrain_collision_bodies[cache_key] = {"body": body, "land": land}
	return true

func _update_exterior_terrain_collision_streaming() -> void:
	if not _exterior_terrain_collision_stream_enabled or _world_loading or data_reader == null:
		return
	_exterior_terrain_collision_scan_cooldown = maxf(
		0.0, _exterior_terrain_collision_scan_cooldown - get_process_delta_time()
	)
	if _exterior_terrain_collision_scan_cooldown > 0.0:
		return
	_exterior_terrain_collision_scan_cooldown = 0.35
	for cache_key_value: Variant in _exterior_terrain_collision_bodies.keys():
		var cache_key := str(cache_key_value)
		var entry: Dictionary = _exterior_terrain_collision_bodies.get(cache_key, {})
		var body := entry.get("body") as StaticBody3D
		if not is_instance_valid(body):
			_exterior_terrain_collision_bodies.erase(cache_key)
			_exterior_terrain_collision_attempted_ids.erase(cache_key)
			continue
		var land: Dictionary = entry.get("land", {})
		var grid_x := int(land.get("grid_x", 0))
		var grid_y := int(land.get("grid_y", 0))
		if _terrain_cell_edge_distance(grid_x, grid_y, player.global_position) <= EXTERIOR_TERRAIN_COLLISION_UNLOAD_DISTANCE:
			continue
		body.queue_free()
		_exterior_terrain_collision_bodies.erase(cache_key)
		_exterior_terrain_collision_attempted_ids.erase(cache_key)
	var terrain_cells: Array = current_cell.get("land_cells", [])
	if terrain_cells.is_empty() and current_cell.has("land"):
		terrain_cells.push_back(current_cell.get("land"))
	for land_value: Variant in terrain_cells:
		var land: Dictionary = land_value
		var grid_x := int(land.get("grid_x", 0))
		var grid_y := int(land.get("grid_y", 0))
		if _terrain_cell_edge_distance(grid_x, grid_y, player.global_position) > EXTERIOR_TERRAIN_COLLISION_DISTANCE:
			continue
		_add_terrain_cell_collider(land)

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

var _exterior_stream_empty_grid := Vector2i(1 << 30, 1 << 30)

func _stream_exterior_if_needed() -> void:
	var worldspace_form_id := int(current_cell.get("worldspace_form_id", 0))
	var cell_size_meters := EXTERIOR_CELL_SIZE * game_units_to_meters
	var grid_x := floori(player.global_position.x / cell_size_meters)
	var grid_y := floori(-player.global_position.z / cell_size_meters)
	var loaded_grid_x := int(current_cell.get("grid_x", 0))
	var loaded_grid_y := int(current_cell.get("grid_y", 0))
	if abs(grid_x - loaded_grid_x) < EXTERIOR_RELOAD_GRID_DISTANCE and abs(grid_y - loaded_grid_y) < EXTERIOR_RELOAD_GRID_DISTANCE:
		return
	# A grid square with no region is asked about once, not on every frame.
	if _exterior_stream_empty_grid == Vector2i(grid_x, grid_y):
		return
	var exterior_region: Dictionary = data_reader.find_exterior_region(
		grid_x, grid_y, worldspace_form_id, EXTERIOR_STREAM_RADIUS,
		EXTERIOR_STATIC_REFERENCE_RADIUS, EXTERIOR_TREE_REFERENCE_RADIUS
	)
	if exterior_region.is_empty():
		_exterior_stream_empty_grid = Vector2i(grid_x, grid_y)
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

func _supports_imported_nif_physics(metadata: Dictionary, meshes: Array) -> bool:
	var bodies: Array = metadata.get("physics_bodies", [])
	var constraints: Array = metadata.get("physics_constraints", [])
	var source_bytes: PackedByteArray = metadata.get("source_bytes", PackedByteArray())
	if bodies.is_empty() or source_bytes.is_empty():
		return false
	var meshes_by_node: Dictionary = {}
	for mesh_value: Variant in meshes:
		var mesh: Dictionary = mesh_value
		var node_name := str(mesh.get("parent_node_name", ""))
		if not node_name.is_empty():
			meshes_by_node[node_name] = true
	var body_names: Dictionary = {}
	var has_dynamic_body := false
	for body_value: Variant in bodies:
		var body: Dictionary = body_value
		var node_name := str(body.get("node_name", ""))
		var shape: Dictionary = body.get("shape", {})
		if node_name.is_empty() or not meshes_by_node.has(node_name) or body_names.has(node_name):
			return false
		if str(shape.get("type", "")) not in ["capsule", "convex_vertices", "sphere"]:
			return false
		if float(body.get("mass", 0.0)) > 0.0:
			has_dynamic_body = true
		body_names[node_name] = true
	if not has_dynamic_body:
		return false
	for constraint_value: Variant in constraints:
		var constraint: Dictionary = constraint_value
		if str(constraint.get("type", "")) != "ragdoll":
			return false
		if not body_names.has(str(constraint.get("body_a_node_name", ""))):
			return false
		if not body_names.has(str(constraint.get("body_b_node_name", ""))):
			return false
	return true

func _register_imported_physics_pickup(
	reference: Dictionary,
	base_form_id: int,
	base_type: String,
	reference_transform: Transform3D,
	physics_result: Dictionary
) -> void:
	var reference_id := int(reference.get("form_id", 0))
	var item_display_name := str(reference.get("reference_name", "")).strip_edges()
	var editor_id := str(data_reader.find_editor_id(base_form_id))
	if item_display_name.is_empty():
		item_display_name = editor_id
	if item_display_name.is_empty():
		item_display_name = "Item"
	_placed_items[reference_id] = {
		"reference_id": reference_id,
		"base_form_id": base_form_id,
		"record_type": base_type,
		"editor_id": editor_id,
		"display_name": item_display_name,
		"position": reference_transform.origin,
		"mesh_instances": physics_result.get("mesh_instances", []),
		"physics_root": physics_result.get("physics_root"),
		"target_area": null,
	}

func _create_imported_havok_shapes(shape_data: Dictionary) -> Array[CollisionShape3D]:
	var collisions: Array[CollisionShape3D] = []
	var shape_type := str(shape_data.get("type", ""))
	if shape_type == "capsule":
		var point_a: Vector3 = shape_data.get("point1", Vector3.ZERO) * game_units_to_meters
		var point_b: Vector3 = shape_data.get("point2", Vector3.ZERO) * game_units_to_meters
		var radius := maxf(float(shape_data.get("radius1", 0.0)), float(shape_data.get("radius2", 0.0))) * game_units_to_meters
		var segment := point_b - point_a
		radius = maxf(radius, 0.002)
		# Approximate the NIF capsule with overlapping spheres. This preserves
		# its end-to-end dimensions while avoiding unstable tiny Jolt capsules.
		var sphere_count := clampi(ceili(segment.length() / (radius * 1.75)) + 1, 2, 24)
		for sphere_index in range(sphere_count):
			var collision := CollisionShape3D.new()
			var sphere := SphereShape3D.new()
			sphere.radius = radius
			sphere.margin = minf(0.001, radius * 0.1)
			collision.shape = sphere
			collision.position = point_a.lerp(point_b, float(sphere_index) / float(sphere_count - 1))
			collisions.push_back(collision)
		return collisions
	elif shape_type == "convex_vertices":
		var source_points: PackedVector3Array = shape_data.get("vertices", PackedVector3Array())
		var points := PackedVector3Array()
		points.resize(source_points.size())
		for index in range(source_points.size()):
			points[index] = source_points[index] * game_units_to_meters
		var convex := ConvexPolygonShape3D.new()
		convex.set_points(points)
		convex.margin = 0.001
		var collision := CollisionShape3D.new()
		collision.shape = convex
		collisions.push_back(collision)
	elif shape_type == "sphere":
		var sphere := SphereShape3D.new()
		sphere.radius = float(shape_data.get("radius1", 0.0)) * game_units_to_meters
		sphere.margin = minf(0.001, sphere.radius * 0.1)
		var collision := CollisionShape3D.new()
		collision.shape = sphere
		collisions.push_back(collision)
	return collisions

func _resolve_initial_dynamic_body_penetration(body: RigidBody3D) -> void:
	var space_state := get_world_3d().direct_space_state
	var excluded_rids: Array[RID] = [body.get_rid(), player.get_rid()]
	var reference_id := int(body.get_meta("reference_id", 0))
	for sibling: Node in body.get_parent().get_children():
		var sibling_body := sibling as PhysicsBody3D
		if sibling_body != null and int(sibling_body.get_meta("reference_id", 0)) == reference_id:
			excluded_rids.push_back(sibling_body.get_rid())
	var required_lift := 0.0
	for child: Node in body.get_children():
		var collision := child as CollisionShape3D
		if collision == null or collision.disabled or collision.shape == null:
			continue
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = collision.shape
		query.transform = collision.global_transform
		query.collision_mask = 2
		query.exclude = excluded_rids
		query.collide_with_areas = false
		query.collide_with_bodies = true
		if space_state.intersect_shape(query, 1).is_empty():
			continue
		query.transform.origin += Vector3.UP * 1.5
		query.motion = Vector3.DOWN * 1.5
		var fractions := space_state.cast_motion(query)
		if fractions.size() == 2 and fractions[0] < 1.0:
			required_lift = maxf(required_lift, 1.5 * (1.0 - fractions[0]) + 0.01)
	if required_lift > 0.0:
		body.global_position += Vector3.UP * required_lift
		body.force_update_transform()

func _instantiate_imported_nif_physics(
	reference_id: int,
	reference_transform: Transform3D,
	model_path: String,
	meshes: Array,
	metadata: Dictionary
) -> Dictionary:
	var bodies: Array = metadata.get("physics_bodies", [])
	var constraints: Array = metadata.get("physics_constraints", [])
	var body_nodes: Dictionary = {}
	var dynamic_bodies: Array[RigidBody3D] = []
	var physics_root := Node3D.new()
	physics_root.name = "ImportedHavokPhysics"
	physics_root.set_meta("reference_id", reference_id)
	cell_visual_root.add_child(physics_root)
	var body_count := 0
	var dynamic_count := 0
	var articulated := not constraints.is_empty()
	for body_value: Variant in bodies:
		var body_data: Dictionary = body_value
		var node_name := str(body_data.get("node_name", ""))
		var mass := float(body_data.get("mass", 0.0))
		var physics_body: PhysicsBody3D
		if mass > 0.0:
			var rigid_body := RigidBody3D.new()
			rigid_body.name = "HavokBody_" + node_name
			# Build every body and constraint before the links enter the solver.
			rigid_body.freeze = true
			rigid_body.mass = mass
			rigid_body.gravity_scale = float(body_data.get("gravity_factor", 1.0))
			rigid_body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
			rigid_body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
			rigid_body.linear_damp = float(body_data.get("linear_damping", 0.0))
			rigid_body.angular_damp = float(body_data.get("angular_damping", 0.0))
			# Layer 16 marks movable bodies for grabbing. Standalone props collide
			# with one another; articulated chains retain their tuned world/player mask.
			rigid_body.collision_layer = 16
			rigid_body.collision_mask = 3 if articulated else 19
			var physics_material := PhysicsMaterial.new()
			physics_material.friction = float(body_data.get("friction", 0.3))
			physics_material.bounce = float(body_data.get("restitution", 0.0))
			rigid_body.physics_material_override = physics_material
			physics_body = rigid_body
			rigid_body.set_meta("grab_enabled", true)
			rigid_body.set_meta("resolve_spawn_penetration", constraints.is_empty())
			dynamic_bodies.push_back(rigid_body)
			dynamic_count += 1
		else:
			var static_body := StaticBody3D.new()
			static_body.name = "HavokAnchor_" + node_name
			static_body.collision_layer = 2
			static_body.collision_mask = 0
			physics_body = static_body
		physics_body.set_meta("reference_id", reference_id)
		var node_transform := ActorFactory.godot_node_rest({
			"translation": body_data.get("node_global_translation", Vector3.ZERO),
			"rotation_rows": body_data.get("node_global_rotation_rows", PackedFloat32Array()),
			"scale": float(body_data.get("node_global_scale", 1.0)),
		})
		var body_basis := (
			reference_transform.basis.orthonormalized() * node_transform.basis.orthonormalized()
		).orthonormalized()
		var body_origin := reference_transform.origin + reference_transform.basis * node_transform.origin
		physics_body.transform = Transform3D(body_basis, body_origin)
		var collision_instances := _create_imported_havok_shapes(body_data.get("shape", {}))
		if collision_instances.is_empty():
			physics_root.queue_free()
			return {}
		for collision_instance: CollisionShape3D in collision_instances:
			physics_body.add_child(collision_instance)
		body_nodes[node_name] = {"node": physics_body, "data": body_data}
		body_count += 1

	var mesh_count := 0
	var visual_mesh_instances: Array[MeshInstance3D] = []
	for mesh_index in range(meshes.size()):
		var mesh_entry: Dictionary = meshes[mesh_index]
		if bool(mesh_entry.get("editor_marker", false)):
			continue
		var node_name := str(mesh_entry.get("parent_node_name", ""))
		if not body_nodes.has(node_name):
			var static_mesh := MeshInstance3D.new()
			static_mesh.name = model_path.get_file().get_basename() + "_" + str(mesh_entry.get("mesh_name", "Mesh")).replace(":", "_")
			static_mesh.mesh = mesh_entry.get("mesh") as ArrayMesh
			static_mesh.set_meta("reference_id", reference_id)
			static_mesh.set_meta("source_mesh_name", str(mesh_entry.get("mesh_name", "")))
			static_mesh.set_meta("model_path", model_path)
			static_mesh.material_override = await _material_for_reference(
				model_path,
				str(mesh_entry.get("diffuse_texture_path", "")),
				bool(mesh_entry.get("alpha_blend", false)),
				bool(mesh_entry.get("alpha_test", false)),
				int(mesh_entry.get("alpha_threshold", 128))
			)
			static_mesh.transform = reference_transform
			physics_root.add_child(static_mesh)
			visual_mesh_instances.push_back(static_mesh)
			mesh_count += 1
			continue
		var physical_mesh := assets.physics_mesh_for_entry(model_path, mesh_index, mesh_entry)
		if physical_mesh == null:
			physics_root.queue_free()
			return {}
		var body_entry: Dictionary = body_nodes[node_name]
		var physics_body := body_entry.get("node") as PhysicsBody3D
		var visual := MeshInstance3D.new()
		visual.name = model_path.get_file().get_basename() + "_" + str(mesh_entry.get("mesh_name", "Mesh")).replace(":", "_")
		visual.mesh = physical_mesh
		visual.set_meta("reference_id", reference_id)
		visual.set_meta("source_mesh_name", str(mesh_entry.get("mesh_name", "")))
		visual.set_meta("model_path", model_path)
		visual.scale = Vector3.ONE * game_units_to_meters
		visual.material_override = await _material_for_reference(
			model_path,
			str(mesh_entry.get("diffuse_texture_path", "")),
			bool(mesh_entry.get("alpha_blend", false)),
			bool(mesh_entry.get("alpha_test", false)),
			int(mesh_entry.get("alpha_threshold", 128))
		)
		physics_body.add_child(visual)
		visual_mesh_instances.push_back(visual)
		mesh_count += 1

	# Register complete bodies with Jolt only after their colliders and visuals
	# are assembled, then create joints before allowing the solver to step.
	for body_entry: Dictionary in body_nodes.values():
		physics_root.add_child(body_entry.get("node") as PhysicsBody3D)

	var largest_initial_anchor_error := 0.0
	for constraint_value: Variant in constraints:
		var constraint: Dictionary = constraint_value
		var body_a_entry: Dictionary = body_nodes[str(constraint.get("body_a_node_name", ""))]
		var body_b_entry: Dictionary = body_nodes[str(constraint.get("body_b_node_name", ""))]
		var body_a := body_a_entry.get("node") as PhysicsBody3D
		var body_b := body_b_entry.get("node") as PhysicsBody3D
		var pivot_a: Vector3 = constraint.get("pivot_a", Vector3.ZERO) * game_units_to_meters
		var pivot_b: Vector3 = constraint.get("pivot_b", Vector3.ZERO) * game_units_to_meters
		var world_anchor_a := body_a.global_transform * pivot_a
		var world_anchor_b := body_b.global_transform * pivot_b
		largest_initial_anchor_error = maxf(largest_initial_anchor_error, world_anchor_a.distance_to(world_anchor_b))
		var twist_axis: Vector3 = constraint.get("twist_axis_a", Vector3.ZERO)
		twist_axis = body_a.global_basis * twist_axis
		if twist_axis.length_squared() < 0.000001:
			twist_axis = Vector3.UP
		else:
			twist_axis = twist_axis.normalized()
		var plane_axis: Vector3 = constraint.get("plane_axis_a", Vector3.ZERO)
		plane_axis = body_a.global_basis * plane_axis
		plane_axis -= twist_axis * plane_axis.dot(twist_axis)
		if plane_axis.length_squared() < 0.000001:
			var fallback_axis := Vector3.RIGHT if absf(twist_axis.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
			plane_axis = fallback_axis - twist_axis * fallback_axis.dot(twist_axis)
		plane_axis = plane_axis.normalized()
		# Godot's ConeTwistJoint3D uses its local X axis for twist.
		var x_axis := twist_axis
		var y_axis := plane_axis
		var z_axis := x_axis.cross(y_axis).normalized()
		var joint := ConeTwistJoint3D.new()
		joint.name = "OriginalRagdollJoint_%s" % str(constraint.get("body_a_node_name", "Link"))
		joint.node_a = NodePath("../" + body_a.name)
		joint.node_b = NodePath("../" + body_b.name)
		joint.exclude_nodes_from_collision = true
		joint.set_param(ConeTwistJoint3D.PARAM_SWING_SPAN, float(constraint.get("cone_max_angle", 0.785398)))
		joint.set_param(ConeTwistJoint3D.PARAM_TWIST_SPAN, maxf(
			absf(float(constraint.get("twist_min_angle", 0.0))),
			absf(float(constraint.get("twist_max_angle", 0.0)))
		))
		joint.transform = Transform3D(Basis(x_axis, y_axis, z_axis), (world_anchor_a + world_anchor_b) * 0.5)
		physics_root.add_child(joint)

	print("OpenOB imported original Havok NIF physics: %s (%d bodies, %d dynamic, %d ragdoll joints; largest initial anchor mismatch %.4fm)" % [
		model_path.get_file(), body_count, dynamic_count, constraints.size(), largest_initial_anchor_error
	])
	return {
		"body_count": body_count,
		"mesh_count": mesh_count,
		"physics_root": physics_root,
		"mesh_instances": visual_mesh_instances,
		"dynamic_bodies": dynamic_bodies,
	}

func _add_reference_collider(reference_id: int, reference_transform: Transform3D, model_path: String, track_exterior: bool) -> bool:
	var model_key := model_path.to_lower().replace("\\", "/")
	var collision_shape := assets.collision_shape_for_model(model_key)
	if collision_shape == null:
		return false
	var static_body := StaticBody3D.new()
	static_body.name = "GeneratedStaticMeshCollision"
	static_body.set_meta("reference_id", reference_id)
	static_body.set_meta("model_path", model_path)
	static_body.collision_layer = 2
	static_body.collision_mask = 0
	static_body.transform = reference_transform
	if collision_shape != null:
		var collision_instance := CollisionShape3D.new()
		collision_instance.shape = collision_shape
		static_body.add_child(collision_instance)
	cell_visual_root.add_child(static_body)
	if track_exterior:
		_exterior_collision_bodies[reference_id] = static_body
	return true

func _add_animated_reference_colliders(node_hosts: Dictionary, meshes: Array) -> int:
	# NIF mesh vertices are in model-root space; using the same animated node host as the visual
	# makes each collision part follow the authored sequence instead of leaving a closed-pose blocker.
	var faces_by_node: Dictionary = {}
	for mesh_value: Variant in meshes:
		var mesh_entry: Dictionary = mesh_value
		if bool(mesh_entry.get("editor_marker", false)):
			continue
		var node_name := str(mesh_entry.get("parent_node_name", ""))
		if not node_hosts.has(node_name):
			continue
		var mesh := mesh_entry.get("mesh") as Mesh
		if mesh == null:
			continue
		var mesh_faces := mesh.get_faces()
		if mesh_faces.size() < 3:
			continue
		var combined_faces: PackedVector3Array = faces_by_node.get(node_name, PackedVector3Array())
		combined_faces.append_array(mesh_faces)
		faces_by_node[node_name] = combined_faces

	var body_count := 0
	for node_name_value: Variant in faces_by_node:
		var node_name := str(node_name_value)
		var body := node_hosts.get(node_name) as AnimatableBody3D
		if body == null:
			continue
		var faces: PackedVector3Array = faces_by_node[node_name]
		var collision_shape := NifAssetLibrary.build_concave_shape(faces)
		if collision_shape == null:
			continue
		var collision_instance := CollisionShape3D.new()
		collision_instance.name = "AnimatedNifCollision"
		collision_instance.shape = collision_shape
		body.add_child(collision_instance)
		body_count += 1
	return body_count


## The cell kit can contain static render-mesh triangles behind a separately animated wall or door. The original
## walkable opening is defined by that animated NIF, so remove only the overlapping part of generated static collision.
func _trim_static_collision_for_animated_openings() -> void:
	var opening_boxes: Array[AABB] = []
	for player_node: Node in cell_visual_root.find_children("*", "AnimationPlayer", true, false):
		var animation_player := player_node as AnimationPlayer
		if animation_player == null:
			continue
		var opening_geometry := _animated_opening_collision_bounds(animation_player)
		var opening_box: AABB = opening_geometry.get("opening", AABB())
		if opening_box.size.length_squared() <= 0.0001:
			continue
		var clearance := Vector3(0.08, 0.05, 0.08)
		# Trim the wall panel's closed footprint, not its entire swing path. The panel thickness axis is the shallow
		# horizontal dimension; extending only that axis clears backing collision without erasing the adjoining wall.
		if opening_box.size.x > 0.0 and opening_box.size.z > 0.0:
			if opening_box.size.x <= opening_box.size.z:
				clearance.x = maxf(clearance.x, opening_box.size.x * 0.75)
			else:
				clearance.z = maxf(clearance.z, opening_box.size.z * 0.75)
		opening_box.position -= clearance
		opening_box.size += clearance * 2.0
		opening_boxes.push_back(opening_box)
	if opening_boxes.is_empty():
		return

	var affected_body_count := 0
	var removed_triangle_count := 0
	for body_node: Node in cell_visual_root.find_children("*", "StaticBody3D", true, false):
		var body := body_node as StaticBody3D
		# Imported Havok shapes already describe the authored solid geometry. Only trim our render-mesh fallback.
		if body == null or not body.has_meta("model_path"):
			continue
		for child: Node in body.get_children():
			var collision := child as CollisionShape3D
			if collision == null or not (collision.shape is ConcavePolygonShape3D):
				continue
			var original_faces: PackedVector3Array = (collision.shape as ConcavePolygonShape3D).get_faces()
			if original_faces.is_empty():
				continue
			var local_to_world := body.global_transform * collision.transform
			var world_to_local := local_to_world.affine_inverse()
			var remaining_faces := PackedVector3Array()
			var removed_for_body := 0
			for face_index in range(0, original_faces.size(), 3):
				var triangle := PackedVector3Array([
					local_to_world * original_faces[face_index],
					local_to_world * original_faces[face_index + 1],
					local_to_world * original_faces[face_index + 2],
				])
				var triangle_normal := (triangle[1] - triangle[0]).cross(triangle[2] - triangle[0]).normalized()
				# Preserve floor and ceiling triangles inside the aperture. Cutting the panel's swept AABB through
				# every face also removed the floor under the doorway, so actors fell while crossing it.
				if absf(triangle_normal.y) >= 0.7:
					remaining_faces.append_array(PackedVector3Array([
						original_faces[face_index], original_faces[face_index + 1], original_faces[face_index + 2]
					]))
					continue
				var fragments: Array[PackedVector3Array] = [triangle]
				for opening_box: AABB in opening_boxes:
					var next_fragments: Array[PackedVector3Array] = []
					for fragment: PackedVector3Array in fragments:
						var fragment_bounds := _polygon_bounds(fragment)
						if not fragment_bounds.intersects(opening_box):
							next_fragments.push_back(fragment)
							continue
						next_fragments.append_array(_subtract_aabb_from_polygon(fragment, opening_box))
					fragments = next_fragments
					if fragments.is_empty():
						break
				if fragments.size() == 1 and fragments[0].size() == 3 \
						and fragments[0][0].is_equal_approx(triangle[0]) \
						and fragments[0][1].is_equal_approx(triangle[1]) \
						and fragments[0][2].is_equal_approx(triangle[2]):
					remaining_faces.append_array(PackedVector3Array([
						original_faces[face_index], original_faces[face_index + 1], original_faces[face_index + 2]
					]))
					continue
				removed_for_body += 1
				for fragment: PackedVector3Array in fragments:
					if fragment.size() < 3:
						continue
					var local_origin := world_to_local * fragment[0]
					for vertex_index in range(1, fragment.size() - 1):
						remaining_faces.push_back(local_origin)
						remaining_faces.push_back(world_to_local * fragment[vertex_index])
						remaining_faces.push_back(world_to_local * fragment[vertex_index + 1])
			if removed_for_body == 0:
				continue
			var trimmed_shape := ConcavePolygonShape3D.new()
			trimmed_shape.backface_collision = true
			trimmed_shape.set_faces(remaining_faces)
			collision.shape = trimmed_shape
			affected_body_count += 1
			removed_triangle_count += removed_for_body
	if affected_body_count > 0:
		print("OpenOB navigation: trimmed %d static collision meshes around animated openings (%d triangles crossed openings)" % [
			affected_body_count, removed_triangle_count
		])


func _animated_opening_collision_bounds(animation_player: AnimationPlayer) -> Dictionary:
	var animation: Animation = null
	for requested_name in ["Open", "Forward"]:
		var sequence_name := quest_bridge._reference_animation_name(animation_player, requested_name)
		if not sequence_name.is_empty():
			animation = animation_player.get_animation(sequence_name)
			break
	if animation == null:
		return {}
	var animated_root := animation_player.get_parent() as Node3D
	if animated_root == null:
		return {}
	var closed_bounds := AABB()
	var has_closed_bounds := false
	var panel_bounds := AABB()
	var has_panel_bounds := false
	var has_collision_motion := false
	for body_node: Node in animated_root.find_children("*", "AnimatableBody3D", true, false):
		var body := body_node as AnimatableBody3D
		if body == null:
			continue
		var body_transforms: Array[Transform3D] = []
		var body_has_motion := false
		var first_transform: Variant = null
		for track_index in range(animation.get_track_count()):
			if animation.track_get_type(track_index) != Animation.TYPE_VALUE:
				continue
			var track_path: NodePath = animation.track_get_path(track_index)
			if track_path.get_name_count() == 0 or str(track_path.get_name(0)) != body.name:
				continue
			var key_count := animation.track_get_key_count(track_index)
			for key_index in range(key_count):
				var value: Variant = animation.track_get_key_value(track_index, key_index)
				if not value is Transform3D:
					continue
				var node_transform: Transform3D = value
				if first_transform != null and _nif_collision_transform_moves(first_transform, node_transform):
					body_has_motion = true
				if first_transform == null:
					first_transform = node_transform
				body_transforms.push_back(node_transform)
		if not body_has_motion:
			continue
		has_collision_motion = true
		for shape_node: Node in body.get_children():
			var collision := shape_node as CollisionShape3D
			if collision == null or not (collision.shape is ConcavePolygonShape3D):
				continue
			var faces: PackedVector3Array = (collision.shape as ConcavePolygonShape3D).get_faces()
			var closed_transform := animated_root.global_transform * body_transforms[0] * collision.transform
			var body_panel_bounds := AABB()
			var has_body_panel_bounds := false
			var vertical_surface_area := 0.0
			var horizontal_surface_area := 0.0
			for face_index in range(0, faces.size(), 3):
				var a := closed_transform * faces[face_index]
				var b := closed_transform * faces[face_index + 1]
				var c := closed_transform * faces[face_index + 2]
				for point: Vector3 in [a, b, c]:
					if not has_closed_bounds:
						closed_bounds = AABB(point, Vector3.ZERO)
						has_closed_bounds = true
					else:
						closed_bounds = closed_bounds.expand(point)
				var cross_product := (b - a).cross(c - a)
				var surface_area := cross_product.length()
				if surface_area <= 0.000001:
					continue
				var normal_y := absf(cross_product.normalized().y)
				if normal_y < 0.7:
					vertical_surface_area += surface_area
					for point: Vector3 in [a, b, c]:
						if not has_body_panel_bounds:
							body_panel_bounds = AABB(point, Vector3.ZERO)
							has_body_panel_bounds = true
						else:
							body_panel_bounds = body_panel_bounds.expand(point)
				else:
					horizontal_surface_area += surface_area
			if has_body_panel_bounds and vertical_surface_area > horizontal_surface_area * 1.2:
				for point: Vector3 in [body_panel_bounds.position, body_panel_bounds.end]:
					if not has_panel_bounds:
						panel_bounds = AABB(point, Vector3.ZERO)
						has_panel_bounds = true
					else:
						panel_bounds = panel_bounds.expand(point)
	if not has_collision_motion or not has_closed_bounds:
		return {}
	return {"opening": panel_bounds if has_panel_bounds else closed_bounds, "closed": closed_bounds}


func _nif_collision_transform_moves(first: Transform3D, next: Transform3D) -> bool:
	return (
		first.origin.distance_to(next.origin) > 0.05
		or first.basis.x.distance_to(next.basis.x) > 0.001
		or first.basis.y.distance_to(next.basis.y) > 0.001
		or first.basis.z.distance_to(next.basis.z) > 0.001
	)


func _polygon_bounds(polygon: PackedVector3Array) -> AABB:
	if polygon.is_empty():
		return AABB()
	var bounds := AABB(polygon[0], Vector3.ZERO)
	for point_index in range(1, polygon.size()):
		bounds = bounds.expand(polygon[point_index])
	return bounds


func _subtract_aabb_from_polygon(polygon: PackedVector3Array, box: AABB) -> Array[PackedVector3Array]:
	var pending: Array[PackedVector3Array] = [polygon]
	var outside_pieces: Array[PackedVector3Array] = []
	for axis in range(3):
		for plane_spec: Array in [[box.position[axis], true], [box.end[axis], false]]:
			var next_pending: Array[PackedVector3Array] = []
			for fragment: PackedVector3Array in pending:
				var split := _split_polygon_by_axis_plane(
					fragment, axis, float(plane_spec[0]), bool(plane_spec[1])
				)
				var outside: PackedVector3Array = split.get("outside", PackedVector3Array())
				var inside: PackedVector3Array = split.get("inside", PackedVector3Array())
				if outside.size() >= 3:
					outside_pieces.push_back(outside)
				if inside.size() >= 3:
					next_pending.push_back(inside)
			pending = next_pending
			if pending.is_empty():
				break
		if pending.is_empty():
			break
	return outside_pieces


func _split_polygon_by_axis_plane(
	polygon: PackedVector3Array, axis: int, plane: float, keep_greater: bool
) -> Dictionary:
	var inside := PackedVector3Array()
	var outside := PackedVector3Array()
	if polygon.size() < 3:
		return {"inside": inside, "outside": outside}
	var previous := polygon[polygon.size() - 1]
	var previous_inside := previous[axis] >= plane if keep_greater else previous[axis] <= plane
	for current: Vector3 in polygon:
		var current_inside := current[axis] >= plane if keep_greater else current[axis] <= plane
		if current_inside != previous_inside:
			var denominator := current[axis] - previous[axis]
			if absf(denominator) > 0.000001:
				var intersection := previous.lerp(current, (plane - previous[axis]) / denominator)
				_append_polygon_point(inside, intersection)
				_append_polygon_point(outside, intersection)
		if current_inside:
			_append_polygon_point(inside, current)
		else:
			_append_polygon_point(outside, current)
		previous = current
		previous_inside = current_inside
	_remove_duplicate_polygon_end(inside)
	_remove_duplicate_polygon_end(outside)
	return {"inside": inside, "outside": outside}


func _append_polygon_point(polygon: PackedVector3Array, point: Vector3) -> void:
	if polygon.is_empty() or polygon[polygon.size() - 1].distance_squared_to(point) > 0.00000001:
		polygon.push_back(point)


func _remove_duplicate_polygon_end(polygon: PackedVector3Array) -> void:
	if polygon.size() > 1 and polygon[0].distance_squared_to(polygon[polygon.size() - 1]) <= 0.00000001:
		polygon.remove_at(polygon.size() - 1)

func _create_pickup_target_area(reference_id: int, reference_transform: Transform3D, meshes: Array) -> Area3D:
	var model_bounds := AABB()
	var has_bounds := false
	for mesh_entry_value: Variant in meshes:
		var mesh_entry: Dictionary = mesh_entry_value
		if bool(mesh_entry.get("editor_marker", false)):
			continue
		var mesh := mesh_entry.get("mesh") as Mesh
		if mesh == null:
			continue
		var mesh_bounds := mesh.get_aabb()
		model_bounds = mesh_bounds if not has_bounds else model_bounds.merge(mesh_bounds)
		has_bounds = true
	if not has_bounds:
		return null
	model_bounds = model_bounds.grow(2.5)
	var area := Area3D.new()
	area.name = "PickupTarget_%08X" % reference_id
	area.collision_layer = PICKUP_TARGET_COLLISION_LAYER
	area.collision_mask = 0
	area.transform = reference_transform
	area.set_meta("reference_id", reference_id)
	area.set_meta("target_kind", "item")
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(
		maxf(model_bounds.size.x, 5.0),
		maxf(model_bounds.size.y, 5.0),
		maxf(model_bounds.size.z, 5.0)
	)
	collision.shape = shape
	collision.position = model_bounds.get_center()
	area.add_child(collision)
	cell_visual_root.add_child(area)
	return area

func _should_collide_model(model_path: String) -> bool:
	var normalized := model_path.to_lower().replace("\\", "/")
	return not normalized.contains("/fx/") and not normalized.contains("lightbeam") and not normalized.contains("dust") and not normalized.contains("trigzone") and not normalized.contains("/triggers/") and not normalized.contains("markerx")

func _update_exterior_collision_streaming() -> void:
	if (
		not _exterior_collision_stream_enabled
		or _exterior_collision_stream_busy
		or _npc_stream_busy
		or _world_loading
		or data_reader == null
	):
		return
	_exterior_collision_scan_cooldown = maxf(0.0, _exterior_collision_scan_cooldown - get_process_delta_time())
	if _exterior_collision_scan_cooldown > 0.0:
		return
	_exterior_collision_scan_cooldown = 0.5
	for reference_id_value: Variant in _exterior_collision_bodies.keys():
		var reference_id := int(reference_id_value)
		var static_body := _exterior_collision_bodies.get(reference_id) as StaticBody3D
		if not is_instance_valid(static_body):
			_exterior_collision_bodies.erase(reference_id)
			_exterior_collision_attempted_ids.erase(reference_id)
			continue
		if static_body.global_position.distance_to(player.global_position) <= EXTERIOR_COLLISION_UNLOAD_DISTANCE:
			continue
		static_body.queue_free()
		_exterior_collision_bodies.erase(reference_id)
		_exterior_collision_attempted_ids.erase(reference_id)

	var selected_reference: Dictionary = {}
	var selected_distance := EXTERIOR_COLLISION_DISTANCE
	for reference_value: Variant in current_cell.get("references", []):
		var reference: Dictionary = reference_value
		var reference_id := int(reference.get("form_id", 0))
		if _exterior_collision_attempted_ids.has(reference_id):
			continue
		var distance_to_player := _reference_origin(reference).distance_to(player.global_position)
		if distance_to_player > selected_distance:
			continue
		if bool(reference.get("is_tree", false)):
			continue
		var model_path := str(reference.get("model_path", ""))
		if model_path.is_empty() or not model_path.to_lower().ends_with(".nif") or not _should_collide_model(model_path):
			continue
		if _is_early_oblivion_gate(reference, model_path):
			continue
		var base_type := str(data_reader.find_record_type(int(reference.get("base_form_id", 0))))
		if base_type in ["ARMO", "CLOT", "WEAP", "ALCH", "AMMO", "APPA", "BOOK", "INGR", "KEYM", "MISC", "SLGM", "SGST"]:
			continue
		selected_distance = distance_to_player
		selected_reference = reference
	if selected_reference.is_empty():
		return
	var selected_id := int(selected_reference.get("form_id", 0))
	_exterior_collision_attempted_ids[selected_id] = true
	_exterior_collision_stream_busy = true
	_exterior_collision_busy_generation = _cell_load_generation
	_load_exterior_reference_collider.call_deferred(selected_reference, _cell_load_generation)

func _load_exterior_reference_collider(reference: Dictionary, generation: int) -> void:
	var reference_id := int(reference.get("form_id", 0))
	var reference_transform := _reference_transform(reference)
	var model_path := str(reference.get("model_path", ""))
	var model_key := model_path.to_lower().replace("\\", "/")
	if not assets.model_cache.has(model_key):
		await assets.meshes_for_model(model_path)
	if generation != _cell_load_generation or not _exterior_collision_stream_enabled:
		if generation == _cell_load_generation:
			_exterior_collision_attempted_ids.erase(reference_id)
		if _exterior_collision_busy_generation == generation:
			_exterior_collision_stream_busy = false
			_exterior_collision_busy_generation = -1
		return
	if reference_transform.origin.distance_to(player.global_position) <= EXTERIOR_COLLISION_UNLOAD_DISTANCE:
		_add_reference_collider(reference_id, reference_transform, model_path, true)
	else:
		# The player left before the model finished loading: no collider was made, so the reference may be tried again
		# when the player is back in range.
		_exterior_collision_attempted_ids.erase(reference_id)
	if _exterior_collision_busy_generation == generation:
		_exterior_collision_stream_busy = false
		_exterior_collision_busy_generation = -1

func _material_for_reference(
	model_path: String,
	texture_path: String,
	alpha_blend := false,
	alpha_test := false,
	alpha_threshold := 128
) -> StandardMaterial3D:
	var material := await assets.material_for_texture(texture_path, alpha_blend, alpha_test, alpha_threshold)
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
	_player_eye_meshes.clear()
	_player_first_person_hidden_meshes.clear()
	status_label.text = "Loading player appearance…"
	var avatar := Node3D.new()
	avatar.name = "OriginalImperialAvatar"
	avatar.scale = Vector3.ONE * game_units_to_meters
	_player_avatar = avatar
	player.add_child(avatar)
	await assets.meshes_for_model(PLAYER_SKELETON)
	var skeleton_metadata: Dictionary = assets.nif_metadata_cache.get(PLAYER_SKELETON.to_lower(), {})
	_player_skeleton = ActorFactory.build_skeleton(skeleton_metadata.get("nodes", []))
	if _player_skeleton != null:
		avatar.add_child(_player_skeleton)
		_align_avatar_to_floor_origin(avatar, _player_skeleton)
	await assets.meshes_for_model(PLAYER_IDLE_KF)
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
		var meshes: Array = await assets.meshes_for_model(model_path)
		var part_mesh_count := 0
		var is_face_model := model_path == PLAYER_FACE_HEAD_MODEL or PLAYER_FACE_DETAIL_PARTS.has(model_path)
		var is_player_hair := model_path.to_lower() == PLAYER_HAIR_MODEL.to_lower()
		var facegen_data: Dictionary = actors.ensure_facegen_data(model_path) if is_face_model else {}
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
			if bool(mesh_entry.get("editor_marker", false)):
				continue
			var instance := MeshInstance3D.new()
			var mesh_name := str(mesh_entry.get("mesh_name", "Mesh"))
			instance.name = model_path.get_file().get_basename() + "_" + mesh_name.replace(":", "_")
			var source_mesh := mesh_entry.mesh as ArrayMesh
			instance.mesh = source_mesh
			if is_face_model:
				_player_face_meshes.push_back(instance)
				_player_face_source_meshes.push_back(source_mesh)
				_player_facegen_mesh_data.push_back(facegen_data)
			var normalized_model_path := model_path.to_lower()
			var normalized_mesh_name := mesh_name.to_lower()
			if normalized_model_path.ends_with("eyelefthuman.nif") or normalized_model_path.ends_with("eyerighthuman.nif"):
				_player_eye_meshes.push_back(instance)
			var hide_in_first_person := (
				normalized_model_path == PLAYER_FACE_HEAD_MODEL.to_lower()
				or PLAYER_FACE_DETAIL_PARTS.has(model_path)
				or normalized_model_path == PLAYER_HAIR_MODEL.to_lower()
				or normalized_model_path == PLAYER_AVATAR_PARTS[1].to_lower()
				or normalized_model_path == PLAYER_AVATAR_PARTS[3].to_lower()
				or (normalized_model_path == PLAYER_AVATAR_PARTS[0].to_lower() and normalized_mesh_name == "upperbody")
			)
			if hide_in_first_person:
				_player_first_person_hidden_meshes.push_back(instance)
			if is_player_hair:
				_player_hair_meshes.push_back(instance)
			if model_path.to_lower() == PLAYER_AVATAR_PARTS[0].to_lower():
				_player_body_meshes_by_slot[0x0004].push_back(instance)
			elif model_path.to_lower() == PLAYER_AVATAR_PARTS[1].to_lower():
				_player_body_meshes_by_slot[0x0008].push_back(instance)
			instance.material_override = await assets.material_for_texture(
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
				instance.skin = ActorFactory.skin_for_mesh(bone_names, _player_skeleton)
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
		"face_talk_weight": 0.0,
		"dialogue_face_active": false,
		"dialogue_face_previous": "",
		"dialogue_face_previous_weight": 0.0,
		"expression_cycle": _available_face_expression_cycle(_player_face_meshes),
		"blink_cooldown": randf_range(2.5, 5.5),
		"blink_remaining": 0.0,
	}
	_apply_face_expression(_player_face_state)
	_refresh_player_face_profile_hint()
	print("OpenOB player FaceGen expressions: %s" % str(_player_face_state.expression_cycle))
	var starting_gear_count := await _load_player_starting_gear()
	_active_animation = ""
	_player_was_on_floor = true
	if part_count > 0:
		var body_proxy := player.get_node_or_null("BodyProxy") as MeshInstance3D
		if body_proxy != null:
			body_proxy.visible = false
		print("OpenOB loaded original Imperial actor: %d body/head shapes, %d rig bones, %d Player-record gear pieces, idle=%s, KF sequences=%s" % [
			part_count,
			_player_skeleton.get_bone_count() if _player_skeleton != null else 0,
			starting_gear_count,
			str(not _player_animations.get("Idle", {}).is_empty()),
			", ".join(loaded_animation_names)
		])

func _load_player_face_detail_part(model_path: String) -> void:
	var meshes: Array = await assets.meshes_for_model(model_path)
	var facegen_data := actors.ensure_facegen_data(model_path)
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
		if bool(mesh_entry.get("editor_marker", false)):
			continue
		var instance := MeshInstance3D.new()
		var mesh_name := str(mesh_entry.get("mesh_name", "Mesh"))
		instance.name = model_path.get_file().get_basename() + "_" + mesh_name.replace(":", "_")
		var source_mesh := mesh_entry.mesh as ArrayMesh
		instance.mesh = source_mesh
		instance.visible = not player.is_first_person
		_player_first_person_hidden_meshes.push_back(instance)
		if model_path.to_lower().ends_with("eyelefthuman.nif") or model_path.to_lower().ends_with("eyerighthuman.nif"):
			_player_eye_meshes.push_back(instance)
		_player_face_meshes.push_back(instance)
		_player_face_source_meshes.push_back(source_mesh)
		_player_facegen_mesh_data.push_back(facegen_data)
		instance.material_override = await assets.material_for_texture(
			str(mesh_entry.diffuse_texture_path),
			bool(mesh_entry.get("alpha_blend", false)),
			bool(mesh_entry.get("alpha_test", false)),
			int(mesh_entry.get("alpha_threshold", 128))
		)
		attachment.add_child(instance)
		var bone_names: Array = mesh_entry.get("bone_names", [])
		if _player_skeleton != null and not bone_names.is_empty():
			instance.skeleton = NodePath("../Skeleton3D")
			instance.skin = ActorFactory.skin_for_mesh(bone_names, _player_skeleton)

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
		await assets.meshes_for_model(asset_path)
		_player_animations[animation_name] = _animation_sequence(asset_path, str(animation_info[1]))
	for animation_name: String in PLAYER_SNEAK_KFS:
		var animation_info: Array = PLAYER_SNEAK_KFS[animation_name]
		var asset_path := str(animation_info[0])
		await assets.meshes_for_model(asset_path)
		_player_animations[animation_name] = _animation_sequence(asset_path, str(animation_info[1]))
	for animation_name: String in PLAYER_JUMP_KFS:
		var animation_info: Array = PLAYER_JUMP_KFS[animation_name]
		var asset_path := str(animation_info[0])
		await assets.meshes_for_model(asset_path)
		_player_animations[animation_name] = _animation_sequence(asset_path, str(animation_info[1]))
	print("OpenOB loaded deferred player face parts and %d original movement animations" % _player_animations.size())

func _start_deferred_cell_loading() -> void:
	_deferred_world_generation += 1
	_npc_stream_enabled = false
	_exterior_collision_stream_enabled = false
	_exterior_terrain_collision_stream_enabled = false
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
	status_label.text = "Loading nearby %s…" % str(cell.get("display_name", cell.get("editor_id", "cell")))
	var geometry_complete: bool = await _load_cell_geometry(cell, near_distance, far_distance, false)
	if not geometry_complete or generation != _deferred_world_generation:
		return
	_exterior_collision_stream_enabled = is_exterior
	_exterior_terrain_collision_stream_enabled = is_exterior
	_npc_stream_enabled = true
	print("OpenOB nearby world pass complete; exterior object, terrain collision, and NPC streaming enabled for %s" % str(cell.get("editor_id", "cell")))

func _initialize_player_face_profiles() -> void:
	_player_face_profiles.clear()
	_player_face_profile_ids.clear()
	_player_face_profile_index = 0
	var facegen_data := actors.ensure_facegen_data(PLAYER_FACE_HEAD_MODEL)
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
	var facegen_data := actors.ensure_facegen_data(head_model_path)
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
		var morphed_mesh := actors.build_facegen_mesh(
			_player_face_source_meshes[index],
			profile.get("face_symmetric", PackedFloat32Array()),
			profile.get("face_asymmetric", PackedFloat32Array()),
			facegen_data
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

func _load_player_starting_gear() -> int:
	var equipped_count := 0
	for item_value: Variant in _player_base_record.get("inventory", []):
		var item: Dictionary = item_value
		var form_id := int(item.get("form_id", 0))
		var count := maxi(int(item.get("count", 0)), 1)
		if form_id <= 0:
			continue
		_add_inventory_item(form_id, count)
		var item_type := str(data_reader.find_record_type(form_id))
		if item_type in ["ARMO", "CLOT"] and await _equip_player_item(form_id):
			equipped_count += 1
	print("OpenOB loaded %d equipped armor/clothing pieces and %d base inventory forms from the Player record" % [
		equipped_count, _player_base_record.get("inventory", []).size()
	])
	_refresh_inventory_hud()
	return equipped_count

func _equip_player_item(form_id: int) -> bool:
	if _player_avatar == null or _player_skeleton == null:
		return false
	var item_type := str(data_reader.find_record_type(form_id))
	var model_path := str(data_reader.find_item_model_path(form_id, false))
	if item_type not in ["ARMO", "CLOT", "WEAP"] or model_path.is_empty():
		return false
	var item_meshes: Array[MeshInstance3D]
	if item_type == "WEAP":
		item_meshes = await actors.add_actor_model(_player_avatar, _player_skeleton, model_path, "Bip01 R Hand")
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
	item_meshes = await actors.add_actor_model(_player_avatar, _player_skeleton, model_path)
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
	var first_person: bool = player.is_first_person
	var covered_slots := 0
	for equipment_value: Variant in _player_equipment.values():
		var equipment: Dictionary = equipment_value
		covered_slots |= int(equipment.get("slots", 0))
	for slot_value: Variant in _player_body_meshes_by_slot.keys():
		var slot := int(slot_value)
		for body_mesh_value: Variant in _player_body_meshes_by_slot[slot]:
			var body_mesh := body_mesh_value as MeshInstance3D
			if is_instance_valid(body_mesh):
				body_mesh.visible = (covered_slots & slot) == 0 and not (first_person and _player_first_person_hidden_meshes.has(body_mesh))
	for equipment_value: Variant in _player_equipment.values():
		var equipment: Dictionary = equipment_value
		var hide_equipment: bool = first_person and (int(equipment.get("slots", 0)) & FIRST_PERSON_HIDDEN_EQUIPMENT_SLOTS) != 0
		for mesh_value: Variant in equipment.get("meshes", []):
			var equipment_mesh := mesh_value as MeshInstance3D
			if is_instance_valid(equipment_mesh):
				equipment_mesh.visible = not hide_equipment

func _refresh_player_first_person_visibility() -> void:
	var first_person: bool = player.is_first_person
	for mesh: MeshInstance3D in _player_first_person_hidden_meshes:
		if is_instance_valid(mesh):
			mesh.visible = not first_person
	_refresh_player_body_visibility()
	_refresh_player_hair_visibility()

func _refresh_player_hair_visibility() -> void:
	var headwear_equipped := false
	for equipment_value: Variant in _player_equipment.values():
		var equipment: Dictionary = equipment_value
		if (int(equipment.get("slots", 0)) & 0x0003) != 0:
			headwear_equipped = true
			break
	for hair_mesh: MeshInstance3D in _player_hair_meshes:
		if is_instance_valid(hair_mesh):
			hair_mesh.visible = not headwear_equipped and not player.is_first_person

## Wires the targeting service to the scene's lookups; called once the nodes exist.
func _setup_targeting() -> void:
	targeting.player = player
	targeting.world_host = self
	targeting.item_lookup = func(reference_id: int) -> Dictionary: return _placed_items.get(reference_id, {})
	targeting.door_lookup = _door_reference_by_id
	targeting.container_lookup = _container_reference_by_id
	targeting.actor_lookup = func(collider: Node) -> Dictionary:
		for actor: Dictionary in _npc_actors:
			if actor.get("root") == collider:
				return actor
		return {}

func _container_reference_by_id(reference_id: int) -> Dictionary:
	if _container_reference_cache.has(reference_id):
		return _container_reference_cache[reference_id]
	var result := {}
	for reference_value: Variant in current_cell.get("references", []):
		var reference: Dictionary = reference_value
		if int(reference.get("form_id", 0)) != reference_id:
			continue
		var base_form_id := int(reference.get("base_form_id", 0))
		if str(data_reader.find_record_type(base_form_id)) == "CONT":
			var name := str(data_reader.find_editor_id(base_form_id)).strip_edges()
			result = {"reference": reference, "display_name": name if not name.is_empty() else "Container"}
		break
	_container_reference_cache[reference_id] = result
	return result

func _door_reference_by_id(reference_id: int) -> Dictionary:
	if director.door_reference_lookup_cache.has(reference_id):
		return director.door_reference_lookup_cache[reference_id]
	for door: Dictionary in director.door_references:
		var reference: Dictionary = door.get("reference", {})
		if int(reference.get("form_id", 0)) == reference_id:
			director.door_reference_lookup_cache[reference_id] = door
			return door
	for reference_value: Variant in current_cell.get("references", []):
		var reference: Dictionary = reference_value
		if int(reference.get("form_id", 0)) != reference_id:
			continue
		if str(data_reader.find_record_type(int(reference.get("base_form_id", 0)))) == "DOOR":
			var door := {"reference": reference}
			director.door_reference_lookup_cache[reference_id] = door
			return door
	director.door_reference_lookup_cache[reference_id] = {}
	return {}

func _setup_dialogue_presentation() -> void:
	_dialogue_camera = Camera3D.new()
	_dialogue_camera.name = "DialogueCamera"
	_dialogue_camera.current = false
	_dialogue_camera.fov = 42.0
	_dialogue_camera.near = 0.04
	add_child(_dialogue_camera)

	_dialogue_layer = CanvasLayer.new()
	_dialogue_layer.name = "DialogueLayer"
	_dialogue_layer.layer = 8
	_dialogue_layer.visible = false
	add_child(_dialogue_layer)
	_dialogue_panel = PanelContainer.new()
	_dialogue_panel.name = "DialoguePanel"
	_dialogue_panel.anchor_left = 0.025
	_dialogue_panel.anchor_top = 0.53
	_dialogue_panel.anchor_right = 0.38
	_dialogue_panel.anchor_bottom = 0.97
	_dialogue_panel.offset_left = 0.0
	_dialogue_panel.offset_top = 0.0
	_dialogue_panel.offset_right = 0.0
	_dialogue_panel.offset_bottom = 0.0
	_dialogue_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_dialogue_layer.add_child(_dialogue_panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 10)
	_dialogue_panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 7)
	margin.add_child(content)
	_dialogue_speaker_label = Label.new()
	_dialogue_speaker_label.add_theme_font_size_override("font_size", 21)
	content.add_child(_dialogue_speaker_label)
	_dialogue_subtitle_label = Label.new()
	_dialogue_subtitle_label.custom_minimum_size = Vector2(0.0, 64.0)
	_dialogue_subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialogue_subtitle_label.add_theme_font_size_override("font_size", 17)
	content.add_child(_dialogue_subtitle_label)
	var separator := HSeparator.new()
	content.add_child(separator)
	var topic_scroll := ScrollContainer.new()
	topic_scroll.custom_minimum_size = Vector2(0.0, 156.0)
	topic_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(topic_scroll)
	_dialogue_topics = VBoxContainer.new()
	_dialogue_topics.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	topic_scroll.add_child(_dialogue_topics)
	_dialogue_goodbye_button = Button.new()
	_dialogue_goodbye_button.text = "Goodbye  ·  Esc"
	_dialogue_goodbye_button.pressed.connect(_end_dialogue)
	content.add_child(_dialogue_goodbye_button)

	_scripted_dialogue_layer = CanvasLayer.new()
	_scripted_dialogue_layer.name = "ScriptedDialogueLayer"
	_scripted_dialogue_layer.layer = 8
	_scripted_dialogue_layer.visible = false
	add_child(_scripted_dialogue_layer)
	_scripted_dialogue_panel = PanelContainer.new()
	_scripted_dialogue_panel.anchor_left = 0.18
	_scripted_dialogue_panel.anchor_top = 0.77
	_scripted_dialogue_panel.anchor_right = 0.82
	_scripted_dialogue_panel.anchor_bottom = 0.96
	_scripted_dialogue_panel.offset_left = 0.0
	_scripted_dialogue_panel.offset_top = 0.0
	_scripted_dialogue_panel.offset_right = 0.0
	_scripted_dialogue_panel.offset_bottom = 0.0
	_scripted_dialogue_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scripted_dialogue_layer.add_child(_scripted_dialogue_panel)
	var scripted_margin := MarginContainer.new()
	scripted_margin.add_theme_constant_override("margin_left", 18)
	scripted_margin.add_theme_constant_override("margin_top", 8)
	scripted_margin.add_theme_constant_override("margin_right", 18)
	scripted_margin.add_theme_constant_override("margin_bottom", 8)
	_scripted_dialogue_panel.add_child(scripted_margin)
	var scripted_content := VBoxContainer.new()
	scripted_content.add_theme_constant_override("separation", 3)
	scripted_margin.add_child(scripted_content)
	_scripted_dialogue_speaker_label = Label.new()
	_scripted_dialogue_speaker_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_scripted_dialogue_speaker_label.add_theme_font_size_override("font_size", 17)
	_scripted_dialogue_speaker_label.add_theme_color_override("font_color", Color(1.0, 0.91, 0.69))
	_scripted_dialogue_speaker_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_scripted_dialogue_speaker_label.add_theme_constant_override("outline_size", 4)
	scripted_content.add_child(_scripted_dialogue_speaker_label)
	_scripted_dialogue_subtitle_label = Label.new()
	_scripted_dialogue_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_scripted_dialogue_subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_scripted_dialogue_subtitle_label.add_theme_font_size_override("font_size", 19)
	_scripted_dialogue_subtitle_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.9))
	_scripted_dialogue_subtitle_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_scripted_dialogue_subtitle_label.add_theme_constant_override("outline_size", 4)
	scripted_content.add_child(_scripted_dialogue_subtitle_label)


func _dialogue_player_identity() -> Dictionary:
	var player_form_id := int(_player_base_record.get("form_id", 0))
	if player_form_id <= 0 and data_reader != null:
		player_form_id = int(data_reader.find_form_id_by_editor_id("Player"))
	var race_form_id := int(_player_base_record.get("race_form_id", 0))
	var race_editor_id := str(data_reader.find_editor_id(race_form_id)) if data_reader != null and race_form_id > 0 else ""
	return {
		"base_form_id": player_form_id,
		"race_editor_id": race_editor_id,
		"female": bool(_player_base_record.get("female", false)),
	}


func _begin_dialogue(actor: Dictionary, show_failure_toast: bool = true) -> bool:
	if _dialogue_active or actor.is_empty() or quest_world == null:
		if show_failure_toast:
			_show_interaction_toast("Dialogue system is not ready")
		return false
	if _dialogue_exit_transition:
		_finish_dialogue_camera_exit()
	var actor_root := actor.get("root") as Node3D
	if not is_instance_valid(actor_root):
		return false
	var identity := _dialogue_player_identity()
	_dialogue_speaker_form_id = int(actor.get("base_form_id", 0))
	_dialogue_listener_form_id = int(identity.get("base_form_id", 0))
	_dialogue_listener_race = str(identity.get("race_editor_id", ""))
	_dialogue_listener_female = bool(identity.get("female", false))
	if _dialogue_speaker_form_id <= 0 or _dialogue_listener_form_id <= 0:
		if show_failure_toast:
			_show_interaction_toast("Dialogue actor data is unavailable")
		return false
	_dialogue_actor = actor
	_sync_player_actor_values_to_quest_world()
	quest_world.set_listener(_dialogue_listener_race, _dialogue_listener_female)
	var greeting: Dictionary = quest_world.begin_dialogue(
		_dialogue_speaker_form_id,
		_dialogue_listener_form_id,
		_dialogue_listener_race,
		_dialogue_listener_female,
		Callable(self, "_quest_distance")
	)
	if not bool(greeting.get("success", false)):
		_dialogue_actor = {}
		if show_failure_toast:
			_show_interaction_toast("They have nothing to say")
		return false
	var dialogue_actor_root := actor.get("root") as Node3D
	if is_instance_valid(dialogue_actor_root) and dialogue_actor_root.has_method("set_dialogue_paused"):
		dialogue_actor_root.call("set_dialogue_paused", true)
	_dialogue_paused_actor = dialogue_actor_root
	set_npc_look_target(str(actor.get("reference_name", "")), "player")
	_suppress_scripted_dialogue_presentation = true
	var greeting_report := _apply_driver_result(greeting)
	_suppress_scripted_dialogue_presentation = false
	for line: String in greeting_report:
		print("OpenOB dialogue: " + line)
	if _needs_route_refresh(greeting):
		_refresh_npc_routes()

	_clear_scripted_speech_subtitle()
	_dialogue_previous_camera = get_viewport().get_camera_3d()
	_dialogue_previous_mouse_mode = Input.mouse_mode
	_dialogue_previous_controls_suspended = player.controls_suspended
	if is_instance_valid(_dialogue_previous_camera):
		_dialogue_camera.global_transform = _dialogue_previous_camera.global_transform
		_dialogue_camera.fov = _dialogue_previous_camera.fov
	else:
		_dialogue_camera.global_position = player.global_position + Vector3.UP * 1.5
	_dialogue_active = true
	player.set_controls_suspended(true)
	_dialogue_camera.make_current()
	_dialogue_layer.visible = true
	_dialogue_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_dialogue_speaker_label.text = str(actor.get("display_name", actor.get("name", "NPC")))
	_present_dialogue_response(greeting)
	_refresh_dialogue_topics(greeting)
	_dialogue_goodbye_button.grab_focus()
	return true


## Scripted Say/SayTo lines show subtitles without opening an interactive dialogue session.
func present_scripted_speech_line(
	speaker_form_id: int, speaker_editor_id: String, line: String, voice_duration: float,
	speaker_reference: String = ""
) -> void:
	if _suppress_scripted_dialogue_presentation or _dialogue_active or line.strip_edges().is_empty():
		return
	if not speaker_reference.is_empty():
		set_npc_look_target(speaker_reference, "player")
	_scripted_subtitle_generation += 1
	var subtitle_generation := _scripted_subtitle_generation
	var speaker_name := speaker_editor_id
	if data_reader != null and speaker_form_id > 0:
		var npc: Dictionary = data_reader.find_npc_base(speaker_form_id)
		speaker_name = str(npc.get("name", speaker_editor_id))
	_scripted_dialogue_speaker_label.text = speaker_name
	_scripted_dialogue_subtitle_label.text = line.strip_edges()
	_scripted_dialogue_layer.visible = true
	var text_duration := maxf(1.2, float(line.length()) / 14.0)
	var hold_duration := maxf(voice_duration, text_duration) + 0.15
	_finish_scripted_subtitle_after(subtitle_generation, hold_duration)


func _finish_scripted_subtitle_after(generation: int, duration: float) -> void:
	await get_tree().create_timer(duration).timeout
	if generation != _scripted_subtitle_generation:
		return
	if is_instance_valid(_scripted_dialogue_layer):
		_scripted_dialogue_layer.visible = false


func _clear_scripted_speech_subtitle() -> void:
	_scripted_subtitle_generation += 1
	if is_instance_valid(_scripted_dialogue_layer):
		_scripted_dialogue_layer.visible = false


func _refresh_dialogue_topics(response: Dictionary = {}) -> void:
	if not _dialogue_active or quest_world == null:
		return
	for child: Node in _dialogue_topics.get_children():
		_dialogue_topics.remove_child(child)
		child.queue_free()
	var dialogue_choices: Array = response.get("dialogue_choices", [])
	var reply_ends_dialogue := (int(response.get("reply_flags", 0)) & DIALOGUE_REPLY_FLAG_GOODBYE) != 0
	if reply_ends_dialogue and dialogue_choices.is_empty():
		# A Goodbye response ends the session after its voice lines; do not leave stale topics selectable meanwhile.
		return
	var topic_values: Array = dialogue_choices
	if topic_values.is_empty():
		topic_values = quest_world.available_dialog_topics(
			_dialogue_speaker_form_id,
			_dialogue_listener_form_id,
			_dialogue_listener_race,
			_dialogue_listener_female
		)
	if topic_values.is_empty():
		var empty_label := Label.new()
		empty_label.text = "No available topics"
		_dialogue_topics.add_child(empty_label)
		return
	for topic_value: Variant in topic_values:
		var topic: Dictionary = topic_value
		var topic_id := int(topic.get("form_id", 0))
		var topic_button := Button.new()
		topic_button.text = str(topic.get("name", topic.get("editor_id", "Topic")))
		topic_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		topic_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		topic_button.pressed.connect(_select_dialogue_topic.bind(topic_id))
		_dialogue_topics.add_child(topic_button)


func _select_dialogue_topic(topic_form_id: int) -> void:
	if not _dialogue_active or quest_world == null:
		return
	var response: Dictionary = quest_world.select_dialog_topic(
		topic_form_id,
		_dialogue_speaker_form_id,
		_dialogue_listener_form_id,
		_dialogue_listener_race,
		_dialogue_listener_female,
		Callable(self, "_quest_distance")
	)
	if not bool(response.get("success", false)):
		_dialogue_subtitle_label.text = "That topic is no longer available."
		_refresh_dialogue_topics()
		return
	for line: String in _apply_driver_result(response):
		print("OpenOB dialogue: " + line)
	if _needs_route_refresh(response):
		_refresh_npc_routes()
	_present_dialogue_response(response)
	_refresh_dialogue_topics(response)


func _present_dialogue_response(response: Dictionary) -> void:
	_dialogue_line_generation += 1
	_play_dialogue_response_lines(response, _dialogue_line_generation)


func _play_dialogue_response_lines(response: Dictionary, generation: int) -> void:
	var lines: Array = response.get("response_lines", [])
	if lines.is_empty():
		lines = [{
			"text": str(response.get("text", response.get("topic_name", ""))),
			"line_number": int(response.get("line_number", 1)),
			"emotion_type": int(response.get("emotion_type", 0)),
			"emotion_value": int(response.get("emotion_value", 0)),
		}]
	var audio_manager := get_tree().root.get_node_or_null("AudioManager")
	for line_value: Variant in lines:
		if not _dialogue_active or generation != _dialogue_line_generation:
			return
		var line: Dictionary = line_value
		var text := str(line.get("text", "")).strip_edges()
		_dialogue_subtitle_label.text = text
		var duration := 0.0
		if audio_manager != null and audio_manager.has_method("play_dialogue"):
			duration = float(audio_manager.call(
				"play_dialogue",
				data_reader,
				self,
				int(response.get("speaker_base", _dialogue_speaker_form_id)),
				str(response.get("quest_editor_id", "")),
				str(response.get("topic_editor_id", "")),
				int(response.get("reply_form_id", 0)),
				quest_bridge._dialogue_face_expression(int(line.get("emotion_type", 0))),
				clampf(float(line.get("emotion_value", 0)) / 100.0, 0.0, 1.0),
				int(line.get("line_number", 1))
			))
		var minimum_duration := maxf(1.2, float(text.length()) / 14.0)
		if duration > 0.0 and audio_manager != null and audio_manager.has_method("is_dialogue_playing"):
			var elapsed := 0.0
			var reference_id := int(_dialogue_actor.get("reference_id", 0))
			while elapsed < duration and _dialogue_active and generation == _dialogue_line_generation \
					and bool(audio_manager.call("is_dialogue_playing", reference_id)):
				await get_tree().process_frame
				elapsed += get_process_delta_time()
		else:
			await get_tree().create_timer(minimum_duration).timeout
	var dialogue_choices: Array = response.get("dialogue_choices", [])
	if _dialogue_active and generation == _dialogue_line_generation \
			and (int(response.get("reply_flags", 0)) & DIALOGUE_REPLY_FLAG_GOODBYE) != 0 \
			and dialogue_choices.is_empty():
		_end_dialogue()


func _dialogue_head_position(actor: Dictionary) -> Vector3:
	var actor_root := actor.get("root") as Node3D
	var skeleton := actor.get("skeleton") as Skeleton3D
	if is_instance_valid(skeleton):
		var head_index := skeleton.find_bone("Bip01 Head")
		if head_index >= 0:
			return skeleton.to_global(skeleton.get_bone_global_pose(head_index).origin)
	if is_instance_valid(actor_root):
		return actor_root.global_position + Vector3.UP * 1.52
	return player.global_position + Vector3.UP * 1.5


## The horizontal direction the actor's face will point while it talks, so the dialogue camera goes there once and stays.
## The head turns toward the player during dialogue (see _update_npc_head_look), so reading the current pose would send the
## camera one way and then drag it to the other as that turn blends in. Instead the head's own pose, before the gaze
## is applied, is turned toward the player by the same limited angle the gaze uses. The body's facing is the fallback.
func _dialogue_face_forward(actor: Dictionary, actor_root: Node3D) -> Vector3:
	var body_forward := -actor_root.global_basis.z
	body_forward.y = 0.0
	if body_forward.length_squared() < 0.001:
		body_forward = player.global_position - actor_root.global_position
		body_forward.y = 0.0
	body_forward = body_forward.normalized() if body_forward.length_squared() > 0.001 else Vector3.FORWARD
	var skeleton := actor.get("skeleton") as Skeleton3D
	if not is_instance_valid(skeleton):
		return body_forward
	var head_index := skeleton.find_bone("Bip01 Head")
	if head_index < 0:
		return body_forward
	var base_rotation := skeleton.get_bone_pose_rotation(head_index)
	if bool(actor.get("look_pose_applied", false)) and int(actor.get("look_bone_index", -1)) == head_index:
		base_rotation = actor.get("look_base_pose_rotation", base_rotation)
	var head_forward := head_forward_vector(skeleton, body_forward, base_rotation)
	if head_forward.length_squared() < 0.001:
		return body_forward
	var gaze_target := actor.get("look_target") as Node3D
	if not is_instance_valid(gaze_target):
		gaze_target = player
	var to_target := _look_target_world_position(gaze_target) - _dialogue_head_position(actor)
	if to_target.length_squared() > 0.0001:
		head_forward = turn_toward_limited(head_forward.normalized(), to_target.normalized(), NPC_HEAD_LOOK_MAX_ANGLE)
	head_forward.y = 0.0
	if head_forward.length_squared() < 0.04:
		return body_forward
	return head_forward.normalized()


## `forward` turned toward `target` by at most `max_angle` radians.
static func turn_toward_limited(forward: Vector3, target: Vector3, max_angle: float) -> Vector3:
	var delta := Quaternion(forward, target)
	var angle := delta.get_angle()
	if angle > max_angle:
		delta = Quaternion.IDENTITY.slerp(delta, max_angle / angle)
	return delta * forward


## The direction "Bip01 Head" points in world space with its local pose rotation set to `pose_rotation`, given the direction the
## body faces at rest (zero when the skeleton has no head). Bone axes differ between rigs, so the forward axis is
## whatever points along the body's facing in the rest pose.
static func head_forward_vector(skeleton: Skeleton3D, body_forward: Vector3, pose_rotation: Quaternion) -> Vector3:
	if not is_instance_valid(skeleton):
		return Vector3.ZERO
	var head_index := skeleton.find_bone("Bip01 Head")
	if head_index < 0:
		return Vector3.ZERO
	var skeleton_basis := skeleton.global_transform.basis
	var rest_head_basis := skeleton_basis * skeleton.get_bone_global_rest(head_index).basis
	var forward_in_bone := rest_head_basis.orthonormalized().inverse() * body_forward
	var parent_index := skeleton.get_bone_parent(head_index)
	var parent_basis := skeleton_basis
	if parent_index >= 0:
		parent_basis = skeleton_basis * skeleton.get_bone_global_pose(parent_index).basis
	# Godot keeps a bone's pose as its local rotation (reset_bone_poses copies the rest into it).
	var head_basis := parent_basis * Basis(pose_rotation)
	return head_basis.orthonormalized() * forward_in_bone


func _update_dialogue_camera(delta: float) -> void:
	if not _dialogue_active or not is_instance_valid(_dialogue_camera):
		return
	var actor_root := _dialogue_actor.get("root") as Node3D
	if not is_instance_valid(actor_root) or bool(actor_root.get("inactive")):
		_end_dialogue()
		return
	var head_position := _dialogue_head_position(_dialogue_actor)
	var face_forward := _dialogue_face_forward(_dialogue_actor, actor_root)
	var camera_position := head_position + face_forward * 0.82 + Vector3.UP * 0.04
	var ray_start := head_position + face_forward * 0.06
	var query := PhysicsRayQueryParameters3D.create(ray_start, camera_position, 2 | 4, [player.get_rid(), actor_root.get_rid()])
	query.collide_with_areas = false
	var obstruction := get_world_3d().direct_space_state.intersect_ray(query)
	if not obstruction.is_empty():
		camera_position = Vector3(obstruction.get("position", camera_position)) + Vector3(obstruction.get("normal", Vector3.UP)) * 0.05
	var look_target := head_position + Vector3.UP * 0.035
	var direction := look_target - camera_position
	if direction.length_squared() < 0.001:
		return
	var target_basis := Basis.looking_at(direction.normalized(), Vector3.UP)
	var blend := 1.0 - exp(-5.5 * delta)
	var current_transform := _dialogue_camera.global_transform
	var current_rotation := current_transform.basis.get_rotation_quaternion()
	var target_rotation := target_basis.get_rotation_quaternion()
	_dialogue_camera.global_transform = Transform3D(
		Basis(current_rotation.slerp(target_rotation, blend)),
		current_transform.origin.lerp(camera_position, blend)
	)
	_dialogue_camera.fov = lerpf(_dialogue_camera.fov, 42.0, blend)


func _update_dialogue_camera_exit(delta: float) -> void:
	if not is_instance_valid(_dialogue_camera):
		_finish_dialogue_camera_exit()
		return
	_dialogue_exit_elapsed += delta
	var blend := 1.0 - exp(-8.0 * delta)
	var current_transform := _dialogue_camera.global_transform
	var target_rotation := _dialogue_return_transform.basis.get_rotation_quaternion()
	var current_rotation := current_transform.basis.get_rotation_quaternion()
	_dialogue_camera.global_transform = Transform3D(
		Basis(current_rotation.slerp(target_rotation, blend)),
		current_transform.origin.lerp(_dialogue_return_transform.origin, blend)
	)
	_dialogue_camera.fov = lerpf(_dialogue_camera.fov, _dialogue_return_fov, blend)
	if _dialogue_exit_elapsed >= 0.35:
		_finish_dialogue_camera_exit()


func _finish_dialogue_camera_exit() -> void:
	_dialogue_exit_transition = false
	if is_instance_valid(_dialogue_camera):
		_dialogue_camera.current = false
	if is_instance_valid(_dialogue_previous_camera):
		_dialogue_previous_camera.make_current()
	else:
		var player_camera := player.get_node_or_null("CameraPivot/Camera3D") as Camera3D
		if is_instance_valid(player_camera):
			player_camera.make_current()
	player.set_controls_suspended(_dialogue_previous_controls_suspended)
	Input.mouse_mode = _dialogue_previous_mouse_mode
	_dialogue_previous_camera = null
	if not _pending_dialogue_actions.is_empty():
		var pending_actions := _pending_dialogue_actions.duplicate(true)
		_pending_dialogue_actions.clear()
		for line: String in quest_bridge.apply_actions(pending_actions, current_cell, self, Callable(self, "_reference_transform")):
			print("OpenOB quest: " + line)
	var completed_actor_ids := _pending_dialogue_route_finished_actor_ids.duplicate()
	_pending_dialogue_route_finished_actor_ids.clear()
	for actor_reference_id: int in completed_actor_ids:
		_on_actor_route_finished(actor_reference_id)
	if _dialogue_pending_route_refresh:
		_dialogue_pending_route_refresh = false
		_refresh_npc_routes()
	if is_instance_valid(_dialogue_paused_actor) and _dialogue_paused_actor.has_method("set_dialogue_paused"):
		_dialogue_paused_actor.call("set_dialogue_paused", false)
	_dialogue_paused_actor = null


func _end_dialogue(immediate: bool = false) -> void:
	if not _dialogue_active:
		if immediate and _dialogue_exit_transition:
			_finish_dialogue_camera_exit()
		return
	_dialogue_active = false
	_dialogue_line_generation += 1
	var audio_manager := get_tree().root.get_node_or_null("AudioManager")
	var reference_id := int(_dialogue_actor.get("reference_id", 0))
	if audio_manager != null and audio_manager.has_method("stop_dialogue") and reference_id > 0:
		audio_manager.call("stop_dialogue", reference_id)
	if is_instance_valid(_dialogue_previous_camera):
		_dialogue_return_transform = _dialogue_previous_camera.global_transform
		_dialogue_return_fov = _dialogue_previous_camera.fov
	else:
		var player_camera := player.get_node_or_null("CameraPivot/Camera3D") as Camera3D
		if is_instance_valid(player_camera):
			_dialogue_previous_camera = player_camera
			_dialogue_return_transform = player_camera.global_transform
			_dialogue_return_fov = player_camera.fov
	if is_instance_valid(_dialogue_layer):
		_dialogue_layer.visible = false
	_dialogue_actor = {}
	_dialogue_exit_elapsed = 0.0
	_dialogue_exit_transition = true
	if immediate:
		_finish_dialogue_camera_exit()


func _update_hud() -> void:
	var visible_hud: bool = not _world_loading and not _inventory_open and not _dialogue_active \
		and not _dialogue_exit_transition and not player.face_preview_enabled
	var vital_snapshot: Dictionary = _player_actor_values.snapshot() if _player_actor_values_ready else {}
	hud.set_snapshot(_aimed_target, vital_snapshot, _player_loadout_snapshot(), _player_compass_heading_degrees(), visible_hud)
	if not visible_hud:
		interaction_hint_label.visible = false
	else:
		interaction_hint_label.text = _interaction_toast_text
		interaction_hint_label.visible = _interaction_toast_remaining > 0.0

func _player_loadout_snapshot() -> Dictionary:
	var weapon_name := "Unarmed"
	var weapon_icon_path := ""
	if _player_weapon_form_id > 0:
		weapon_name = _record_display_name(_player_weapon_form_id)
		if weapon_name.is_empty():
			weapon_name = "Weapon"
		weapon_icon_path = str(data_reader.find_record_icon_path(_player_weapon_form_id))
	var spell_name := "No spell selected"
	var spell_icon_path := ""
	if _player_selected_spell_form_id > 0:
		spell_name = _record_display_name(_player_selected_spell_form_id)
		if spell_name.is_empty():
			spell_name = "Spell"
		spell_icon_path = str(data_reader.find_record_icon_path(_player_selected_spell_form_id))
	return {
		"weapon_form_id": _player_weapon_form_id,
		"weapon_name": weapon_name,
		"weapon_icon_path": weapon_icon_path,
		"spell_form_id": _player_selected_spell_form_id,
		"spell_name": spell_name,
		"spell_icon_path": spell_icon_path,
	}

func _player_compass_heading_degrees() -> float:
	var forward := -player.global_basis.z
	return fposmod(rad_to_deg(atan2(forward.x, -forward.z)), 360.0)

## Executes the action of one target snapshot; the HUD displays the same snapshot.
func _activate_target(target: Dictionary) -> void:
	match str(target.get("action", "none")):
		"take":
			if str(target.get("kind", "")) == "item":
				var item: Dictionary = _placed_items.get(int(target.get("reference_id", 0)), {})
				if not item.is_empty():
					await _pick_up_placed_item(item)
		"enter":
			await _transition_to_linked_cell(target.get("reference", {}))
		"locked":
			_show_interaction_toast("Locked")
		"talk":
			_begin_dialogue(target.get("actor", {}))
		"open":
			var door_reference: Dictionary = target.get("reference", {})
			var state_key := "door_open_%08x" % int(target.get("reference_id", 0))
			var is_open := has_meta(state_key) and bool(get_meta(state_key))
			var report := quest_bridge.set_door_open_state(door_reference, not is_open, self)
			if not report.begins_with("applied:"):
				_show_interaction_toast("Cannot open %s" % str(target.get("display_name", "door")))

func _show_interaction_toast(message: String) -> void:
	_interaction_toast_text = message
	_interaction_toast_remaining = 1.5

var _picked_up_reference_ids: Dictionary = {}

func _pick_up_placed_item(item: Dictionary) -> void:
	var reference_id := int(item.get("reference_id", 0))
	physics_grabber.release_reference(reference_id)
	_picked_up_reference_ids[reference_id] = true
	_placed_items.erase(reference_id)
	var target_area := item.get("target_area") as Area3D
	if is_instance_valid(target_area):
		target_area.queue_free()
	var physics_root := item.get("physics_root") as Node3D
	if is_instance_valid(physics_root):
		physics_root.queue_free()
	else:
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
	_show_interaction_toast("Picked up %s" % item_name)

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
		var item_name := _record_display_name(form_id)
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
	if not _player_spell_form_ids.is_empty():
		var spells_label := Label.new()
		spells_label.text = "Known spells"
		inventory_items_container.add_child(spells_label)
		for spell_form_id: int in _player_spell_form_ids:
			var spell_button := Button.new()
			var spell_name := _record_display_name(spell_form_id)
			if spell_name.is_empty():
				spell_name = "Spell %08X" % spell_form_id
			var selected_suffix := " · selected" if spell_form_id == _player_selected_spell_form_id else ""
			spell_button.text = "SPEL  %s%s" % [spell_name, selected_suffix]
			spell_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			spell_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			spell_button.pressed.connect(_select_player_spell.bind(spell_form_id))
			inventory_items_container.add_child(spell_button)
	inventory_label.text = "Inventory: %d items · %d types · %d spells" % [
		item_count, _player_inventory.size(), _player_spell_form_ids.size()
	]

func _record_display_name(form_id: int) -> String:
	if data_reader == null or form_id <= 0:
		return ""
	var display_name := str(data_reader.find_record_display_name(form_id)).strip_edges()
	if display_name.is_empty():
		display_name = str(data_reader.find_editor_id(form_id)).strip_edges()
	return display_name

func _select_player_spell(form_id: int) -> void:
	if not _player_spell_form_ids.has(form_id):
		return
	_player_selected_spell_form_id = form_id
	_refresh_inventory_hud()

func _cycle_player_spell() -> void:
	if _player_spell_form_ids.is_empty():
		_show_interaction_toast("No known spells")
		return
	var current_index := _player_spell_form_ids.find(_player_selected_spell_form_id)
	var next_index := (current_index + 1) % _player_spell_form_ids.size()
	_select_player_spell(_player_spell_form_ids[next_index])

func _on_player_gameplay_frame(delta: float, is_running: bool, jumped: bool) -> void:
	if not _player_actor_values_ready:
		return
	if jumped:
		_player_actor_values.apply_jump_cost()
	_player_actor_values.advance_time(delta, is_running)

func _cast_selected_spell() -> void:
	if _world_loading or _inventory_open or not _player_actor_values_ready:
		return
	if _player_selected_spell_form_id <= 0:
		_show_interaction_toast("No spell selected")
		return
	var spell: Dictionary = data_reader.find_spell(_player_selected_spell_form_id)
	if spell.is_empty():
		_show_interaction_toast("Spell data unavailable")
		return
	if int(spell.get("spell_type", -1)) not in [0, 3]:
		_show_interaction_toast("This spell cannot be cast directly")
		return
	var effects: Array = spell.get("effects", [])
	if effects.is_empty():
		_show_interaction_toast("Spell has no effects")
		return
	for effect_value: Variant in effects:
		var effect: Dictionary = effect_value
		var effect_flags := int(effect.get("magic_effect_flags", 0))
		if int(effect.get("range_type", -1)) != 0 or (effect_flags & (1 << 4)) == 0:
			_show_interaction_toast("This spell needs a target")
			return
		if str(effect.get("code", "")) not in ["REHE", "REMA", "REFA"] or (effect_flags & (1 << 3)) != 0:
			_show_interaction_toast("This spell effect is not supported yet")
			return
	var magicka_cost := _spell_cast_cost(spell)
	if not _player_actor_values.spend_magicka(float(magicka_cost)):
		_show_interaction_toast("Not enough Magicka")
		return
	for effect_value: Variant in effects:
		var effect: Dictionary = effect_value
		var effect_flags := int(effect.get("magic_effect_flags", 0))
		var duration := 1.0 if (effect_flags & (1 << 7)) != 0 else maxf(1.0, float(effect.get("duration", 0)))
		var restored_amount := float(effect.get("magnitude", 0)) * duration
		match str(effect.get("code", "")):
			"REHE":
				_player_actor_values.restore_health(restored_amount)
			"REMA":
				_player_actor_values.restore_magicka(restored_amount)
			"REFA":
				_player_actor_values.modify_fatigue(restored_amount)
	_sync_player_actor_values_to_quest_world()
	var spell_name := _record_display_name(_player_selected_spell_form_id)
	_show_interaction_toast("Cast %s · %d Magicka" % [spell_name, magicka_cost])

func _spell_cast_cost(spell: Dictionary) -> int:
	var effects: Array = spell.get("effects", [])
	var total_cost := 0.0
	var dominant_effect_cost := -1.0
	var dominant_school := -1
	for effect_value: Variant in effects:
		var effect: Dictionary = effect_value
		var effect_flags := int(effect.get("magic_effect_flags", 0))
		var base_cost := float(effect.get("base_cost", 0.0))
		if base_cost <= 0.0:
			continue
		var magnitude_factor := 1.0
		if (effect_flags & (1 << 8)) == 0:
			magnitude_factor = pow(
				maxf(1.0, float(effect.get("magnitude", 0))),
				float(_player_game_settings.get("fMagicCostScale", 0.0))
			)
		var duration_factor := 1.0
		if (effect_flags & (1 << 7)) == 0:
			duration_factor = maxf(1.0, float(effect.get("duration", 0)))
		var area_factor := 1.0
		if (effect_flags & (1 << 9)) == 0:
			area_factor = maxf(
				1.0,
				float(effect.get("area", 0)) * float(_player_game_settings.get("fMagicAreaBaseCostMult", 0.0))
			)
		var range_factor := 1.0
		if int(effect.get("range_type", 0)) == 2:
			range_factor = float(_player_game_settings.get("fMagicRangeTargetCostMult", 0.0))
		var unscaled_effect_cost := maxf(
			1.0,
			base_cost
				* float(_player_game_settings.get("fMagicDurMagBaseCostMult", 0.0))
				* magnitude_factor * duration_factor * area_factor * range_factor
		)
		if unscaled_effect_cost > dominant_effect_cost:
			dominant_effect_cost = unscaled_effect_cost
			dominant_school = int(effect.get("magic_school", -1))
		var skill_factor := _magic_skill_cost_factor(int(effect.get("magic_school", -1)))
		total_cost += unscaled_effect_cost * skill_factor
	if (int(spell.get("flags", 0)) & 1) != 0 or total_cost <= 0.0:
		var manual_cost_factor := _magic_skill_cost_factor(dominant_school)
		total_cost = float(spell.get("cost", 0)) * manual_cost_factor
	return ceili(maxf(0.0, total_cost))

func _magic_skill_cost_factor(school: int) -> float:
	var base := float(_player_game_settings.get("fMagicCasterSkillCostBase", 0.0))
	var multiplier := float(_player_game_settings.get("fMagicCasterSkillCostMult", 0.0))
	var skill: float = _player_actor_values.school_skill(school)
	return maxf(0.0, base + (1.0 - skill / 100.0) * multiplier)

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
		_add_terrain_cell_collider(land)

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

func _player_first_person_camera_anchor() -> Vector3:
	if _player_skeleton == null:
		return Vector3(0.0, 1.5, 0.0)
	var camera_bone_index := _player_skeleton.find_bone("Camera01")
	if camera_bone_index >= 0:
		var camera_position := _player_skeleton.to_global(_player_skeleton.get_bone_global_pose(camera_bone_index).origin)
		return player.to_local(camera_position)
	var eye_position_sum := Vector3.ZERO
	var eye_count := 0
	for eye_mesh: MeshInstance3D in _player_eye_meshes:
		if not is_instance_valid(eye_mesh) or eye_mesh.mesh == null:
			continue
		eye_position_sum += eye_mesh.global_transform * eye_mesh.mesh.get_aabb().get_center()
		eye_count += 1
	if eye_count > 0:
		return player.to_local(eye_position_sum / float(eye_count))
	return _player_face_camera_anchor()

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

func _load_cell_actors(cell: Dictionary, target_reference_id: int = -1, clear_existing: bool = true) -> void:
	if clear_existing:
		_clear_cell_actors()
	_register_cell_npc_references(cell)
	var stream_generation := _npc_stream_generation
	var actor_count := 0
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
		# An actor a script killed or disabled stays that way when its cell is loaded again.
		if quest_bridge.is_actor_removed(reference_id):
			_npc_loaded_reference_ids[reference_id] = true
			continue
		var actor_root := CharacterBody3D.new()
		actor_root.set_script(NpcRouteController)
		var actor_name := str(reference.get("reference_name", "")).strip_edges()
		if actor_name.is_empty():
			actor_name = str(npc.get("editor_id", "")).strip_edges()
		if actor_name.is_empty():
			actor_name = "NPC_%08X" % int(reference.get("form_id", 0))
		var actor_reference_name := str(reference.get("reference_name", "")).strip_edges()
		if actor_reference_name.is_empty():
			actor_reference_name = actor_name
		# Node names are unique: guards share a base editor id, and a quest or the bridge finds an actor by its node name.
		if has_node(NodePath(actor_name)):
			actor_name = "%s_%08X" % [actor_name, reference_id]
		actor_root.name = actor_name
		actor_root.set_meta("reference_id", reference_id)
		actor_root.set_meta("reference_name", actor_reference_name)
		actor_root.collision_layer = 4
		actor_root.collision_mask = 7
		actor_root.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
		actor_root.transform = _actor_reference_transform(reference)
		add_child(actor_root)
		_npc_pending_roots.push_back(actor_root)
		var actor_collision := CollisionShape3D.new()
		actor_collision.name = "ApproximateActorCollision"
		var actor_capsule := CapsuleShape3D.new()
		# Keep the blocker close to the actor's actual occupied space. Spawn
		# separation uses this radius only when two actors actually overlap.
		actor_capsule.radius = 0.18
		var player_collision := player.get_node_or_null("CollisionShape3D") as CollisionShape3D
		var player_capsule := player_collision.shape as CapsuleShape3D if player_collision != null else null
		if player_capsule != null:
			actor_capsule.height = player_capsule.height
		actor_capsule.margin = 0.005
		actor_collision.shape = actor_capsule
		actor_collision.position.y = actor_capsule.height * 0.5
		actor_root.add_child(actor_collision)
		var spawn_adjustment := _separate_actor_spawn(actor_root, reference_id)
		if spawn_adjustment > 0.001:
			print("OpenOB separated overlapping spawn for %s by %.3fm" % [actor_name, spawn_adjustment])
		if _place_actor_on_generated_floor(actor_root):
			grounded_actor_count += 1
		var avatar := Node3D.new()
		avatar.name = "OriginalActor"
		avatar.scale = Vector3.ONE * game_units_to_meters
		actor_root.add_child(avatar)
		var skeleton_metadata: Dictionary = assets.nif_metadata_cache.get(PLAYER_SKELETON.to_lower(), {})
		var skeleton := ActorFactory.build_skeleton(skeleton_metadata.get("nodes", []))
		if skeleton == null:
			_discard_pending_npc(actor_root)
			continue
		avatar.add_child(skeleton)
		_align_avatar_to_floor_origin(avatar, skeleton)
		var equipment_head_model_path := actors.npc_head_model_path(npc)
		_register_player_face_profile(npc, equipment_head_model_path)
		var assembled: Dictionary = await actors.assemble_npc_model(
			avatar, skeleton, npc, func() -> bool: return stream_generation == _npc_stream_generation
		)
		if assembled.is_empty():
			_discard_pending_npc(actor_root)
			return
		var face_meshes: Array[MeshInstance3D] = assembled["face_meshes"]
		var attached_item_names: Array[String] = assembled["attached_item_names"]
		print("OpenOB attached equipment to %s: %s" % [actor_name, str(attached_item_names)])
		await assets.meshes_for_model(PLAYER_IDLE_KF)
		await assets.meshes_for_model(PLAYER_DIRECTIONAL_KFS["Forward"][0])
		await assets.meshes_for_model(PLAYER_FAST_FORWARD_KF)
		if stream_generation != _npc_stream_generation:
			_discard_pending_npc(actor_root)
			return
		var animations := {
			"Idle": _animation_sequence(PLAYER_IDLE_KF, PLAYER_IDLE_SEQUENCE, skeleton),
			"Forward": _animation_sequence(PLAYER_DIRECTIONAL_KFS["Forward"][0], "Forward", skeleton),
			"FastForward": _animation_sequence(PLAYER_FAST_FORWARD_KF, "FastForward", skeleton),
		}
		var expression_cycle := _available_face_expression_cycle(face_meshes)
		# The route comes from the NPC's package for the quest stage (see _refresh_npc_routes).
		var no_route: Array[Dictionary] = []
		actor_root.call("configure_route", no_route, false, 0.0)
		var initial_expression := ""
		var npc_display_name := str(npc.get("name", "")).strip_edges()
		if npc_display_name.is_empty():
			npc_display_name = actor_name
		var actor_state := {
			"name": actor_name,
			"reference_id": reference_id,
			"display_name": npc_display_name,
			"reference_name": actor_reference_name,
			"base_form_id": int(reference.get("base_form_id", 0)),
			"npc_editor_id": str(npc.get("editor_id", "")),
			"root": actor_root,
			"skeleton": skeleton,
			"face_meshes": face_meshes,
			"face_expression": initial_expression,
			"face_expression_weight": 0.7,
			"face_expression_previous": "",
			"face_expression_previous_weight": 0.0,
			"face_expression_transition": 0.0,
			"face_talk_weight": 0.0,
			"dialogue_face_active": false,
			"dialogue_face_previous": "",
			"dialogue_face_previous_weight": 0.0,
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
		_register_quest_actor(actor_state)
		# NPCs stream in after the quest started, so they pick up their package route here.
		_refresh_actor_route(actor_state)
		_npc_pending_roots.erase(actor_root)
		_npc_loaded_reference_ids[reference_id] = true
		_apply_face_expression(actor_state)
		actor_count += 1
	print("OpenOB assembled %d placed NPCs (%d grounded), original idle/walk/fast-walk animations, and FaceGen head morphs" % [actor_count, grounded_actor_count])
	await _setup_cell_once(stream_generation)

## The cell's zones, navigation and quest are set up once per cell, not after every streamed NPC, and only by the load
## that still belongs to the current cell. Cells without NPCs run it from the streaming update.
func _setup_cell_once(stream_generation: int) -> void:
	if _cell_setup_done or stream_generation != _npc_stream_generation:
		return
	_cell_setup_done = true
	await _find_trigger_zones(stream_generation)
	if stream_generation != _npc_stream_generation:
		return
	# The routes follow the navigation tiles of the cell, so they are baked before the quest starts.
	if director.navigation_tiles == null:
		await director.build_navigation_tiles()
		if stream_generation != _npc_stream_generation:
			return
	if data_reader != null:
		director.set_pathgrid(
			data_reader.find_pathgrid(int(current_cell.get("form_id", 0))), game_units_to_meters
		)
		await get_tree().physics_frame
		await get_tree().physics_frame
		if stream_generation != _npc_stream_generation:
			return
	# The quest drives the NPCs' packages, so it starts once the cell's actors exist.
	if quest_world == null:
		for line: String in start_quest("CharacterGen", 0):
			print("OpenOB quest: " + line)
		_run_debug_stages()


## Developer check: OPENOB_DEBUG_STAGES="CharacterGen:58,CharacterGen:64" enters those quest stages one after the other
## (a few hundred frames apart) once the cell's quest runs, so the effects of late intro stages (idles, speech) can be
## watched in the log without playing the intro through.
func _run_debug_stages() -> void:
	var specification := OS.get_environment("OPENOB_DEBUG_STAGES").strip_edges()
	if specification.is_empty():
		return
	for item: String in specification.split(",", false):
		var parts := item.strip_edges().split(":")
		if parts.size() != 2 or not parts[1].is_valid_int():
			push_warning("OpenOB debug stage: expected QUEST:STAGE, got %s" % item)
			continue
		for _frame in range(400):
			await get_tree().process_frame
		if quest_world == null:
			return
		print("OpenOB debug stage: entering %s stage %s" % [parts[0], parts[1]])
		_sync_player_actor_values_to_quest_world()
		for line: String in _apply_driver_result(quest_world.start(parts[0], int(parts[1]), Callable(self, "_quest_distance"))):
			print("OpenOB quest: " + line)
		_refresh_npc_routes()

func _update_npc_streaming() -> void:
	if not _npc_stream_enabled or _npc_stream_busy or _exterior_collision_stream_busy or _world_loading or data_reader == null:
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
		if not _cell_setup_done and not current_cell.is_empty():
			_npc_stream_busy = true
			_setup_cell_without_npc.call_deferred(_npc_stream_generation)
		return
	_npc_stream_busy = true
	_load_next_streamed_npc.call_deferred(current_cell, selected_reference_id, _npc_stream_generation)

func _setup_cell_without_npc(stream_generation: int) -> void:
	if stream_generation != _npc_stream_generation:
		return
	await _setup_cell_once(stream_generation)
	if stream_generation == _npc_stream_generation:
		_npc_stream_busy = false

func _load_next_streamed_npc(cell: Dictionary, reference_id: int, stream_generation: int) -> void:
	if stream_generation != _npc_stream_generation:
		return
	await _load_cell_actors(cell, reference_id, false)
	if stream_generation == _npc_stream_generation:
		_npc_stream_busy = false

func _clear_cell_actors() -> void:
	_end_dialogue(true)
	_clear_scripted_speech_subtitle()
	director.clear_navigation_tiles()
	if quest_world != null:
		quest_world.clear_actors()
	_trigger_zones.clear()
	_cell_setup_done = false
	director.clear_door_references()
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
	_pending_idles.clear()

func _discard_pending_npc(actor_root: Node3D) -> void:
	_npc_pending_roots.erase(actor_root)
	if not is_instance_valid(actor_root):
		return
	actor_root.set_physics_process(false)
	actor_root.set_process(false)
	actor_root.queue_free()

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
	# The floor may be a few metres below the placed position (the actor falls to it) or just above (it rises to it).
	var query := PhysicsRayQueryParameters3D.create(
		start_position + Vector3.UP * 2.1,
		start_position - Vector3.UP * 12.0,
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

func _separate_actor_spawn(actor_root: CharacterBody3D, reference_id: int) -> float:
	var actor_collision := actor_root.get_node_or_null("ApproximateActorCollision") as CollisionShape3D
	var actor_capsule := actor_collision.shape as CapsuleShape3D if actor_collision != null else null
	if actor_capsule == null:
		return 0.0
	var occupied_roots: Array[Node3D] = [player]
	for pending_root: Node3D in _npc_pending_roots:
		if pending_root != actor_root and is_instance_valid(pending_root):
			occupied_roots.push_back(pending_root)
	for actor: Dictionary in _npc_actors:
		var existing_root := actor.get("root") as Node3D
		if is_instance_valid(existing_root):
			occupied_roots.push_back(existing_root)

	var original_position := actor_root.global_position
	var candidate_position := original_position
	for _iteration in range(16):
		var found_overlap := false
		for other_root: Node3D in occupied_roots:
			var other_collision := other_root.get_node_or_null("ApproximateActorCollision") as CollisionShape3D
			if other_collision == null:
				other_collision = other_root.get_node_or_null("CollisionShape3D") as CollisionShape3D
			var other_capsule := other_collision.shape as CapsuleShape3D if other_collision != null else null
			if other_capsule == null:
				continue
			var other_position := other_root.global_position
			var actor_center_y := candidate_position.y + actor_collision.position.y
			var other_center_y := other_position.y + other_collision.position.y
			if absf(actor_center_y - other_center_y) >= (actor_capsule.height + other_capsule.height) * 0.5:
				continue
			var minimum_spacing := actor_capsule.radius + other_capsule.radius + 0.02
			var offset := candidate_position - other_position
			offset.y = 0.0
			var distance := offset.length()
			if distance >= minimum_spacing:
				continue
			var away_direction: Vector3
			if distance > 0.001:
				away_direction = offset / distance
			else:
				var angle := fposmod(float(reference_id & 0xFFFF) * 2.39996323, TAU)
				away_direction = Vector3(cos(angle), 0.0, sin(angle))
			candidate_position += away_direction * (minimum_spacing - distance + 0.01)
			found_overlap = true
			break
		if not found_overlap:
			break

	actor_root.global_position = candidate_position
	var adjustment := Vector2(
		candidate_position.x - original_position.x,
		candidate_position.z - original_position.z
	).length()
	return adjustment

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


func set_npc_dialogue_expression(reference_id: int, expression_name: String, weight: float) -> void:
	for actor: Dictionary in _npc_actors:
		if int(actor.get("reference_id", 0)) != reference_id:
			continue
		if not bool(actor.get("dialogue_face_active", false)):
			actor["dialogue_face_previous"] = str(actor.get("face_expression", ""))
			actor["dialogue_face_previous_weight"] = float(actor.get("face_expression_weight", 0.0))
		actor["dialogue_face_active"] = true
		_set_face_expression(actor, expression_name, weight)
		return


func clear_npc_dialogue_expression(reference_id: int) -> void:
	for actor: Dictionary in _npc_actors:
		if int(actor.get("reference_id", 0)) != reference_id or not bool(actor.get("dialogue_face_active", false)):
			continue
		var previous_name := str(actor.get("dialogue_face_previous", ""))
		var previous_weight := float(actor.get("dialogue_face_previous_weight", 0.0))
		actor["dialogue_face_active"] = false
		actor["dialogue_face_previous"] = ""
		actor["dialogue_face_previous_weight"] = 0.0
		_set_face_expression(actor, previous_name, previous_weight)
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
		for shape_name in actors.facegen_expression_names:
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


func _update_face_talk(actor: Dictionary, delta: float, audio_manager: Node) -> void:
	if is_instance_valid(audio_manager) and audio_manager.has_method("get_dialogue_visemes"):
		var visemes_value: Variant = audio_manager.call("get_dialogue_visemes", int(actor.get("reference_id", 0)))
		if visemes_value is PackedFloat32Array and visemes_value.size() == FaceGenData.LIP_PHONEME_NAMES.size():
			var visemes: PackedFloat32Array = visemes_value
			for phoneme_index in range(FaceGenData.LIP_PHONEME_NAMES.size()):
				_set_actor_face_shape(actor, str(FaceGenData.LIP_PHONEME_NAMES[phoneme_index]), visemes[phoneme_index])
			actor["face_talk_weight"] = 0.0
			return
	for phoneme_name: StringName in FaceGenData.LIP_PHONEME_NAMES:
		_set_actor_face_shape(actor, str(phoneme_name), 0.0)
	var talk_target := 0.0
	if is_instance_valid(audio_manager) and audio_manager.has_method("get_dialogue_talk_weight"):
		talk_target = float(audio_manager.call("get_dialogue_talk_weight", int(actor.get("reference_id", 0))))
	var blend := 1.0 - exp(-maxf(delta, 0.0) * 14.0)
	var talk_weight := lerpf(float(actor.get("face_talk_weight", 0.0)), talk_target, blend)
	if talk_target == 0.0 and talk_weight < 0.001:
		talk_weight = 0.0
	actor["face_talk_weight"] = talk_weight
	_set_actor_face_shape(actor, "BigAah", talk_weight)

## A gesture that plays once holds its final pose at least this long, and while the actor is still speaking up to the
## maximum: the original special idles (pointing, halting) raise the arm in under a second and hold it, then ease back.
const NPC_GESTURE_MIN_HOLD_S := 1.5
const NPC_GESTURE_MAX_HOLD_S := 3.0
const NPC_ANIMATION_DISTANCE_M := 60.0
const NPC_ANIMATION_ALWAYS_NEAR_M := 8.0

func _gesture_hold_over(actor: Dictionary, audio_manager: Node) -> bool:
	var held := float(Time.get_ticks_msec() - int(actor.get("idle_started_ms", 0))) * 0.001
	return held >= NPC_GESTURE_MAX_HOLD_S or (held >= NPC_GESTURE_MIN_HOLD_S and not _actor_is_speaking(audio_manager, actor))

func _actor_is_speaking(audio_manager: Node, actor: Dictionary) -> bool:
	return is_instance_valid(audio_manager) and audio_manager.has_method("is_dialogue_playing") \
			and bool(audio_manager.call("is_dialogue_playing", int(actor.get("reference_id", 0))))

func _update_npc_actors(delta: float) -> void:
	var camera := player.get_node_or_null("CameraPivot/Camera3D") as Camera3D
	var audio_manager := get_tree().root.get_node_or_null("AudioManager")
	for actor: Dictionary in _npc_actors:
		var actor_root := actor.get("root") as Node3D
		var skeleton := actor.get("skeleton") as Skeleton3D
		if not is_instance_valid(actor_root) or not is_instance_valid(skeleton) or not actor_root.visible:
			continue
		_restore_npc_head_pose(actor, skeleton)
		# Animating a skeleton and morphing a face costs the main thread every frame: an NPC that is far away, or out of
		# view and not close, keeps its last pose until it is seen again.
		var distance_to_player := actor_root.global_position.distance_to(player.global_position)
		if distance_to_player > NPC_ANIMATION_DISTANCE_M:
			continue
		# A scripted idle keeps running out of view, so a gesture is not lost when the actor is looked at again.
		if (
			distance_to_player > NPC_ANIMATION_ALWAYS_NEAR_M
			and not bool(actor.get("idle_active", false))
			and camera != null
			and not camera.is_position_in_frustum(actor_root.global_position + Vector3.UP)
		):
			continue
		var look_target_active := _npc_look_target_is_active(actor)
		_update_face_blink(actor, delta)
		_update_face_expression(actor, delta)
		_update_face_talk(actor, delta, audio_manager)
		var walking := bool(actor_root.get("is_walking"))
		var horizontal_speed := Vector2(actor_root.velocity.x, actor_root.velocity.z).length()
		var requested_animation := "Idle"
		var animations: Dictionary = actor.get("animations", {})
		var base_name := "Idle"
		var upper_body_idle := bool(actor.get("idle_active", false)) and bool(actor.get("idle_upper_body", false))
		if walking:
			requested_animation = "FastForward" if horizontal_speed > 2.2 else "Forward"
			if animations.get(requested_animation, {}).is_empty():
				requested_animation = "Forward"
			base_name = requested_animation
			if not upper_body_idle:
				_end_npc_idle(actor)
		if bool(actor.get("idle_active", false)):
			var idle_animation: Dictionary = animations.get(NPC_IDLE_KEY, {})
			# A clip that plays once ends at its last key and the actor returns to its default idle.
			if idle_animation.is_empty() or (
				not bool(idle_animation.get("loops", true)) and str(actor.get("active_animation", "")) == NPC_IDLE_KEY
				and float(actor.get("animation_time", 0.0)) >= float(idle_animation.get("stop_time", 0.0))
				and _gesture_hold_over(actor, audio_manager)
			):
				_end_npc_idle(actor)
			else:
				requested_animation = NPC_IDLE_KEY
		var animation: Dictionary = animations.get(requested_animation, {})
		if animation.is_empty() and requested_animation == "FastForward":
			requested_animation = "Forward"
			animation = animations.get(requested_animation, {})
		if animation.is_empty():
			_update_npc_head_look(actor, skeleton, delta, look_target_active)
			continue
		if requested_animation != str(actor.get("active_animation", "")):
			actor["animation_from_pose"] = _capture_skeleton_pose(skeleton)
			actor["animation_blend_elapsed"] = 0.0
			actor["blend_duration"] = _blend_duration_between(str(actor.get("active_animation", "")), requested_animation)
			actor["active_animation"] = requested_animation
			actor["animation_time"] = float(animation.get("start_time", 0.0))
		actor["animation_time"] = float(actor.get("animation_time", 0.0)) + delta
		var blend_elapsed := minf(
			float(actor.get("animation_blend_elapsed", ANIMATION_BLEND_DURATION)) + delta,
			float(actor.get("blend_duration", ANIMATION_BLEND_DURATION))
		)
		actor["animation_blend_elapsed"] = blend_elapsed
		var blend_weight := blend_elapsed / float(actor.get("blend_duration", ANIMATION_BLEND_DURATION))
		var pose_from: Array[Dictionary] = []
		var pose_from_value: Variant = actor.get("animation_from_pose", [])
		if pose_from_value is Array:
			for pose_value: Variant in pose_from_value:
				if pose_value is Dictionary:
					pose_from.push_back(pose_value)
		_apply_animation_pose(
			skeleton, animation, float(actor["animation_time"]), bool(animation.get("loops", true)), pose_from, blend_weight,
			animations.get(base_name, {}) if requested_animation == NPC_IDLE_KEY else {},
			requested_animation == NPC_IDLE_KEY and walking
		)
		if blend_weight >= 1.0:
			actor["animation_from_pose"] = []
		_update_npc_head_look(actor, skeleton, delta, look_target_active)


func set_npc_look_target(reference_name: String, target_reference: String) -> String:
	var actor := _npc_actor_by_reference(reference_name.to_lower())
	if actor.is_empty():
		return ""
	var target_name := target_reference.strip_edges().to_lower()
	var target: Node3D
	if target_name == "player":
		target = player
	else:
		var target_actor := _npc_actor_by_reference(target_name)
		target = target_actor.get("root") as Node3D
	if not is_instance_valid(target):
		return ""
	actor["look_target"] = target
	actor["look_blend"] = 0.0
	return str(actor.get("reference_name", reference_name))


func stop_npc_look_target(reference_name: String) -> String:
	var actor := _npc_actor_by_reference(reference_name.to_lower())
	if actor.is_empty():
		return ""
	actor["look_target"] = null
	actor["look_blend"] = 0.0
	var skeleton := actor.get("skeleton") as Skeleton3D
	if is_instance_valid(skeleton):
		_restore_npc_head_pose(actor, skeleton)
	return str(actor.get("reference_name", reference_name))


func _restore_npc_head_pose(actor: Dictionary, skeleton: Skeleton3D) -> void:
	if not bool(actor.get("look_pose_applied", false)):
		return
	var bone_index := int(actor.get("look_bone_index", -1))
	if bone_index >= 0 and bone_index < skeleton.get_bone_count():
		var base_rotation: Quaternion = actor.get("look_base_pose_rotation", Quaternion.IDENTITY)
		skeleton.set_bone_pose_rotation(bone_index, base_rotation)
	actor["look_pose_applied"] = false


func _look_target_world_position(target: Node3D) -> Vector3:
	if target == player:
		# In first person the hidden avatar's eye meshes can be offset from the actual viewpoint.
		# Aim NPC dialogue gaze at the camera lens, which sits at the center of the player's view.
		if player.is_first_person:
			var camera := player.get_node_or_null("CameraPivot/Camera3D") as Camera3D
			if is_instance_valid(camera):
				return camera.global_position
		return _player_gaze_target_world_position()
	for actor: Dictionary in _npc_actors:
		if actor.get("root") == target:
			return _dialogue_head_position(actor)
	return target.global_position + Vector3.UP * 1.45


func _player_gaze_target_world_position() -> Vector3:
	# Face-preview's anchor is tuned for camera framing. NPC gaze should use the actual face location instead.
	var eye_position_sum := Vector3.ZERO
	var eye_count := 0
	for eye_mesh: MeshInstance3D in _player_eye_meshes:
		if not is_instance_valid(eye_mesh) or not eye_mesh.is_inside_tree() or eye_mesh.mesh == null:
			continue
		eye_position_sum += eye_mesh.global_transform * eye_mesh.mesh.get_aabb().get_center()
		eye_count += 1
	if eye_count > 0:
		return eye_position_sum / float(eye_count)
	if is_instance_valid(_player_skeleton):
		var head_bone_index := _player_skeleton.find_bone("Bip01 Head")
		if head_bone_index >= 0:
			return _player_skeleton.to_global(_player_skeleton.get_bone_global_pose(head_bone_index).origin)
	return player.global_position + Vector3.UP * 1.45


func _npc_look_target_is_active(actor: Dictionary) -> bool:
	var target := actor.get("look_target") as Node3D
	var actor_root := actor.get("root") as Node3D
	if not is_instance_valid(target) or not is_instance_valid(actor_root):
		return false
	var from_position := _dialogue_head_position(actor)
	var to_position := _look_target_world_position(target)
	var offset := to_position - from_position
	var distance := offset.length()
	if distance <= 0.06:
		return true
	var direction := offset / distance
	var query := PhysicsRayQueryParameters3D.create(
		from_position + direction * 0.04, to_position - direction * 0.04, 2, [actor_root.get_rid()]
	)
	query.collide_with_areas = false
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _update_npc_head_look(actor: Dictionary, skeleton: Skeleton3D, delta: float, look_target_active: bool) -> void:
	if not look_target_active:
		return
	var target := actor.get("look_target") as Node3D
	if not is_instance_valid(target):
		return
	var bone_index := int(actor.get("look_bone_index", -1))
	if bone_index < 0:
		bone_index = skeleton.find_bone("Bip01 Head")
		if bone_index < 0:
			bone_index = skeleton.find_bone("Bip01 Neck")
		actor["look_bone_index"] = bone_index
	if bone_index < 0:
		return
	var base_rotation := skeleton.get_bone_pose_rotation(bone_index)
	var head_transform := skeleton.global_transform * skeleton.get_bone_global_pose(bone_index)
	var target_position := _look_target_world_position(target)
	var actor_root := actor.get("root") as Node3D
	if is_instance_valid(actor_root) and not bool(actor_root.get("is_walking")):
		var body_direction := target_position - actor_root.global_position
		body_direction.y = 0.0
		if body_direction.length_squared() > 0.0001:
			var body_target_yaw := atan2(-body_direction.x, -body_direction.z)
			var body_yaw_error := wrapf(body_target_yaw - actor_root.rotation.y, -PI, PI)
			if absf(body_yaw_error) > deg_to_rad(48.0):
				actor_root.rotation.y = lerp_angle(actor_root.rotation.y, body_target_yaw, 1.0 - exp(-5.0 * delta))
	var target_direction := target_position - head_transform.origin
	if target_direction.length_squared() <= 0.0001:
		return
	target_direction = target_direction.normalized()
	var current_forward := -head_transform.basis.z.normalized()
	var world_delta := Quaternion(current_forward, target_direction)
	var max_angle := NPC_HEAD_LOOK_MAX_ANGLE
	var angle := world_delta.get_angle()
	if angle > max_angle:
		world_delta = Quaternion.IDENTITY.slerp(world_delta, max_angle / angle)
	var desired_world_basis := Basis(world_delta) * head_transform.basis.orthonormalized()
	var parent_index := skeleton.get_bone_parent(bone_index)
	var parent_global_basis := skeleton.global_transform.basis
	if parent_index >= 0:
		parent_global_basis = skeleton.global_transform.basis * skeleton.get_bone_global_pose(parent_index).basis
	var rest_basis := skeleton.get_bone_rest(bone_index).basis
	var desired_pose_basis := rest_basis.inverse() * parent_global_basis.inverse() * desired_world_basis
	var desired_pose_rotation := desired_pose_basis.orthonormalized().get_rotation_quaternion()
	var blend := 1.0 - exp(-5.0 * delta)
	actor["look_base_pose_rotation"] = base_rotation
	actor["look_pose_applied"] = true
	actor["look_blend"] = minf(1.0, float(actor.get("look_blend", 0.0)) + blend)
	skeleton.set_bone_pose_rotation(
		bone_index,
	base_rotation.slerp(desired_pose_rotation, float(actor["look_blend"]))
	)

## The idle manager's PickIdle for one NPC (see QuestWorld.pick_idle): plays the chosen original clip on the actor
## with the reference name. An empty path means no idle matched: the actor returns to its default idle. An actor that
## is not in the scene yet gets the idle when it loads. Returns what was done, for the quest log.
func play_npc_idle(reference_name: String, kf_path: String, idle_id: String, _group_flags: int) -> String:
	var key := reference_name.to_lower()
	var actor := _npc_actor_by_reference(key)
	if actor.is_empty():
		if kf_path.is_empty():
			_pending_idles.erase(key)
			return "%s is not in this cell, default idle" % reference_name
		_pending_idles[key] = {"path": kf_path, "idle_id": idle_id}
		return "%s is not loaded yet, %s waits for it" % [reference_name, idle_id]
	if kf_path.is_empty():
		var was_active := bool(actor.get("idle_active", false))
		_end_npc_idle(actor)
		return "%s returns to its default idle%s" % [reference_name, "" if was_active else " (no idle was playing)"]
	_start_npc_idle(actor, kf_path, idle_id)
	return "%s starts %s (%s)" % [reference_name, idle_id, kf_path]

func _npc_actor_by_reference(lower_reference_name: String) -> Dictionary:
	for actor: Dictionary in _npc_actors:
		if str(actor.get("reference_name", "")).to_lower() == lower_reference_name:
			return actor
	return {}

## Loads the clip on first use through the asset queue and plays it on the actor, blending from its current pose.
## A newer idle or an ended one makes the pending load a no-op.
func _start_npc_idle(actor: Dictionary, kf_path: String, idle_id: String) -> void:
	var request := int(actor.get("idle_request", 0)) + 1
	actor["idle_request"] = request
	var skeleton := actor.get("skeleton") as Skeleton3D
	var animation := await _gesture_animation(kf_path.replace("\\", "/"), skeleton)
	if request != int(actor.get("idle_request", 0)) or not is_instance_valid(skeleton):
		return
	if animation.is_empty():
		push_warning("OpenOB npc idle: %s could not be loaded for %s" % [kf_path, str(actor.get("reference_name", ""))])
		return
	var animations: Dictionary = actor.get("animations", {})
	animations[NPC_IDLE_KEY] = animation
	actor["idle_active"] = true
	actor["idle_started_ms"] = Time.get_ticks_msec()
	# The IDLE record's group flag is not a reliable marker (PointForward is group 4, "special idle"), and gestures such as
	# PointDownward or HoldUp key a few leg bones too. A clip that plays once is a gesture: it plays on over the walk (leg
	# tracks skipped, the walk cycle underneath) instead of ending when the actor starts walking. Looping clips are states
	# (praying, sitting) and end when the actor walks.
	actor["idle_upper_body"] = not bool(animation.get("loops", true))
	# The pose to blend from is captured when the requested clip changes (see _update_npc_actors); a clip replaced by
	# another starts from the first clip's pose, so force the change.
	if str(actor.get("active_animation", "")) == NPC_IDLE_KEY:
		actor["active_animation"] = ""
	print("OpenOB npc idle: %s plays %s (%s, %s)" % [
		str(actor.get("reference_name", "")), idle_id, kf_path, "loops" if bool(animation.loops) else "once"
	])

func _is_leg_bone_name(bone_name: String) -> bool:
	return bone_name.contains("Thigh") or bone_name.contains("Calf") or bone_name.contains("Foot") or bone_name.contains("Toe") or bone_name.contains("Pelvis")

func _end_npc_idle(actor: Dictionary) -> void:
	actor["idle_request"] = int(actor.get("idle_request", 0)) + 1
	if not bool(actor.get("idle_active", false)):
		return
	actor["idle_active"] = false
	actor["idle_upper_body"] = false
	(actor.get("animations", {}) as Dictionary).erase(NPC_IDLE_KEY)
	print("OpenOB npc idle: %s returns to its default idle" % str(actor.get("reference_name", "")))

func _align_avatar_to_floor_origin(avatar: Node3D, skeleton: Skeleton3D) -> void:
	var root_bone := skeleton.find_bone("Bip01")
	if root_bone < 0:
		return
	# Character meshes use the model origin at the soles, while Bip01 is above them.
	var rig_root_height := skeleton.get_bone_global_rest(root_bone).origin.y * game_units_to_meters
	avatar.position.y -= rig_root_height
	if skeleton == _player_skeleton:
		print("OpenOB aligned avatar mesh origin to rig root: root_height=%.3fm" % rig_root_height)

## Rebuilds animated-reference tracks from the NIF's own NiControllerSequence data.
## Static mesh vertices are already in model-root space, so each animated NiNode
## receives the delta from its rest global transform to its sampled global transform.
func _install_nif_animations(animated_root: Node3D, metadata: Dictionary, node_hosts: Dictionary) -> void:
	var sequences: Array = metadata.get("animations", [])
	var nodes: Array = metadata.get("nodes", [])
	if sequences.is_empty() or nodes.is_empty():
		return
	var node_map: Dictionary = {}
	for node_value: Variant in nodes:
		var node: Dictionary = node_value
		var node_name := str(node.get("name", ""))
		if not node_name.is_empty():
			node_map[node_name] = node
	var animation_player := AnimationPlayer.new()
	animation_player.name = "NifAnimationPlayer"
	animation_player.root_node = NodePath("..")
	animation_player.set_meta("reference_id", int(animated_root.get_meta("reference_id", 0)))
	var library := AnimationLibrary.new()
	var animation_count := 0
	for sequence_value: Variant in sequences:
		var sequence: Dictionary = sequence_value
		var sequence_name := str(sequence.get("name", ""))
		if sequence_name.is_empty() or library.has_animation(sequence_name):
			continue
		var start_time := float(sequence.get("start_time", 0.0))
		var stop_time := float(sequence.get("stop_time", start_time))
		if stop_time <= start_time:
			continue
		var sequence_tracks: Array = sequence.get("tracks", [])
		var tracks_by_node: Dictionary = {}
		var sample_times: Array[float] = [start_time, stop_time]
		for track_value: Variant in sequence_tracks:
			var track: Dictionary = track_value
			var node_name := str(track.get("node_name", ""))
			tracks_by_node[node_name] = track
			for key_spec: Array in [
				["translations", 4], ["rotations", 5], ["scales", 2]
			]:
				var keys: PackedFloat32Array = track.get(str(key_spec[0]), PackedFloat32Array())
				var stride := int(key_spec[1])
				for key_offset in range(0, keys.size(), stride):
					var key_time := float(keys[key_offset])
					if key_time >= start_time and key_time <= stop_time and not sample_times.has(key_time):
						sample_times.push_back(key_time)
		sample_times.sort()
		var animation := Animation.new()
		animation.length = stop_time - start_time
		var animated_host_count := 0
		for host_value: Variant in node_hosts.values():
			var host := host_value as Node3D
			if not is_instance_valid(host):
				continue
			var node_name := str(host.get_meta("nif_node_name", ""))
			var rest_cache: Dictionary = {}
			var rest_global := _nif_node_global_rest(node_name, node_map, rest_cache)
			var rest_inverse := rest_global.affine_inverse()
			var track_index := animation.add_track(Animation.TYPE_VALUE)
			animation.track_set_path(track_index, NodePath("%s:transform" % host.name))
			animation.track_set_interpolation_type(track_index, Animation.INTERPOLATION_LINEAR)
			var global_cache: Dictionary = {}
			for sample_time in sample_times:
				global_cache.clear()
				var animated_global := _nif_node_global_at_time(
					node_name, node_map, tracks_by_node, sample_time, global_cache
				)
				var model_delta := animated_global * rest_inverse
				animation.track_insert_key(track_index, sample_time - start_time, model_delta)
			animated_host_count += 1
		if animated_host_count == 0:
			continue
		if library.add_animation(sequence_name, animation) == OK:
			animation_count += 1
	if animation_count == 0:
		return
	animated_root.add_child(animation_player)
	animation_player.add_animation_library("", library)

func _nif_node_global_rest(node_name: String, node_map: Dictionary, cache: Dictionary) -> Transform3D:
	if cache.has(node_name):
		return cache[node_name]
	if not node_map.has(node_name):
		return Transform3D.IDENTITY
	var node: Dictionary = node_map[node_name]
	var parent_name := str(node.get("parent_name", ""))
	var local_transform := ActorFactory.godot_node_rest(node)
	var global_transform := local_transform
	if not parent_name.is_empty() and node_map.has(parent_name):
		global_transform = _nif_node_global_rest(parent_name, node_map, cache) * local_transform
	cache[node_name] = global_transform
	return global_transform

func _nif_node_global_at_time(
	node_name: String,
	node_map: Dictionary,
	tracks_by_node: Dictionary,
	time: float,
	cache: Dictionary
) -> Transform3D:
	if cache.has(node_name):
		return cache[node_name]
	if not node_map.has(node_name):
		return Transform3D.IDENTITY
	var node: Dictionary = node_map[node_name]
	var rest_transform := ActorFactory.godot_node_rest(node)
	var translation := rest_transform.origin
	var rotation := rest_transform.basis.orthonormalized().get_rotation_quaternion()
	var scale := float(node.get("scale", 1.0))
	var track: Dictionary = tracks_by_node.get(node_name, {})
	var translations: PackedFloat32Array = track.get("translations", PackedFloat32Array())
	if translations.size() >= 4:
		translation = _sample_vector_keys(translations, 4, time)
	var rotations: PackedFloat32Array = track.get("rotations", PackedFloat32Array())
	if rotations.size() >= 5:
		rotation = _sample_quaternion_keys(rotations, time)
	var scales: PackedFloat32Array = track.get("scales", PackedFloat32Array())
	if scales.size() >= 2:
		scale = _sample_scalar_keys(scales, time)
	var local_transform := Transform3D(
		Basis(rotation).scaled(Vector3.ONE * scale),
		translation
	)
	var parent_name := str(node.get("parent_name", ""))
	var global_transform := local_transform
	if not parent_name.is_empty() and node_map.has(parent_name):
		global_transform = _nif_node_global_at_time(
			parent_name, node_map, tracks_by_node, time, cache
		) * local_transform
	cache[node_name] = global_transform
	return global_transform

func _animation_sequence(asset_path: String, sequence_name: String, target_skeleton: Skeleton3D = null) -> Dictionary:
	var key := asset_path.to_lower().replace("\\", "/")
	var metadata: Dictionary = assets.nif_metadata_cache.get(key, {})
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
	var is_on_floor_now: bool = player.is_on_floor() or player.is_stepping()
	if not is_on_floor_now and player.velocity.y <= 0.1:
		is_on_floor_now = _has_nearby_walkable_support()
	if _gesture_active and _gesture_should_end(horizontal_speed, is_on_floor_now):
		_end_gesture()
	if _gesture_active:
		_set_player_animation(GESTURE_KEY)
	elif _player_was_on_floor and not is_on_floor_now and player.velocity.y > 0.1:
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
		_player_blend_duration
	)
	var start_time := float(animation.get("start_time", 0.0))
	var stop_time := float(animation.get("stop_time", start_time))
	var duration := stop_time - start_time
	if duration <= 0.0:
		return
	var blend_weight := _player_animation_blend_elapsed / _player_blend_duration
	_apply_animation_pose(
		_player_skeleton,
		animation,
		_animation_time,
		_active_animation not in ["JumpStart", "JumpLand"] and bool(animation.get("loops", true)),
		_player_animation_from_pose,
		blend_weight,
		_player_animations.get("Idle", {}) if _active_animation == GESTURE_KEY else {}
	)
	if blend_weight >= 1.0:
		_player_animation_from_pose.clear()

func _has_nearby_walkable_support() -> bool:
	# Treat a brief floor-contact gap as grounded for animation when the capsule
	# still touches a walkable surface just below it.
	var support := KinematicCollision3D.new()
	if not player.test_move(
		player.global_transform,
		Vector3.DOWN * 0.24,
		support,
		player.safe_margin
	):
		return false
	var support_normal := support.get_normal()
	return support_normal.dot(Vector3.UP) >= cos(player.floor_max_angle)

func _player_locomotion_animation(horizontal_speed: float) -> String:
	var sneaking: bool = player.is_crouching
	if horizontal_speed <= 0.08:
		return "SneakIdle" if sneaking and _player_animations.has("SneakIdle") else "Idle"
	var local_velocity := Basis(Vector3.UP, player.rotation.y).inverse() * Vector3(player.velocity.x, 0.0, player.velocity.z)
	var is_fast := Input.is_action_pressed("run") and not sneaking
	var direction_name := "Forward"
	if absf(local_velocity.x) > absf(local_velocity.z):
		direction_name = "Left" if local_velocity.x < 0.0 else "Right"
	else:
		direction_name = "Backward" if local_velocity.z > 0.0 else "Forward"
	if sneaking and _player_animations.has("Sneak" + direction_name):
		return "Sneak" + direction_name
	return ("Fast" + direction_name) if is_fast else direction_name

func _blend_duration_between(from_animation: String, to_animation: String) -> float:
	if from_animation == GESTURE_KEY or from_animation == NPC_IDLE_KEY:
		return GESTURE_BLEND_OUT_S
	if to_animation == GESTURE_KEY or to_animation == NPC_IDLE_KEY:
		return GESTURE_BLEND_IN_S
	return ANIMATION_BLEND_DURATION

func _set_player_animation(animation_name: String) -> void:
	var animation: Dictionary = _player_animations.get(animation_name, {})
	if animation.is_empty() or animation_name == _active_animation:
		return
	if _player_skeleton != null:
		_player_animation_from_pose = _capture_skeleton_pose(_player_skeleton)
		_player_animation_blend_elapsed = 0.0
		_player_blend_duration = _blend_duration_between(_active_animation, animation_name)
	_active_animation = animation_name
	_animation_time = float(animation.get("start_time", 0.0))

func _gesture_panel_open() -> bool:
	return _gesture_panel != null and _gesture_panel.visible

func _gestures_available() -> bool:
	return (
		data_reader != null and _player_skeleton != null and _player_deferred_assets_ready
		and not _world_loading and not _inventory_open and not player.face_preview_enabled
	)

## A gesture ends when it finishes (non-looping clips), or when the player moves, jumps, crouches, or leaves the ground.
## While the picker is open the keys belong to the panel, so only the animation state is checked.
func _gesture_should_end(horizontal_speed: float, on_floor: bool) -> bool:
	if not _gesture_active:
		return false
	var animation: Dictionary = _player_animations.get(GESTURE_KEY, {})
	if animation.is_empty() or player.is_flying:
		return true
	if not bool(animation.get("loops", true)) and _active_animation == GESTURE_KEY \
			and _animation_time >= float(animation.get("stop_time", 0.0)):
		return true
	if _gesture_panel_open():
		return false
	if horizontal_speed > 0.08 or not on_floor or player.is_crouching:
		return true
	if Input.is_action_pressed("jump") or Input.is_action_pressed("crouch"):
		return true
	for action: String in GESTURE_MOVE_ACTIONS:
		if Input.is_action_pressed(action):
			return true
	return false

func _end_gesture() -> void:
	_gesture_active = false
	_gesture_request_id += 1
	_player_animations.erase(GESTURE_KEY)
	if _active_animation == GESTURE_KEY:
		_player_animation_from_pose = _capture_skeleton_pose(_player_skeleton)
		_player_animation_blend_elapsed = 0.0
		_active_animation = ""
		_set_player_animation("Idle")

## Lists every KF under the male idleanims folder in the game data, once.
func _ensure_gesture_clips() -> void:
	if not _gesture_clips.is_empty() or data_reader == null:
		return
	for path_value: Variant in data_reader.list_assets(PLAYER_GESTURE_PREFIX):
		var archive_path := str(path_value).replace("\\", "/")
		if not archive_path.ends_with(".kf"):
			continue
		_gesture_clips.push_back({
			"name": archive_path.get_file().get_basename(),
			"path": archive_path.trim_prefix("meshes/"),
		})
	_gesture_clips.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.name) < str(b.name))

func _step_gesture(direction: int) -> void:
	if not _gestures_available() or _gesture_panel_open():
		return
	_ensure_gesture_clips()
	if _gesture_clips.is_empty():
		_show_interaction_toast("No gesture clips found")
		return
	_gesture_index = posmod(_gesture_index + direction, _gesture_clips.size()) if _gesture_index >= 0 \
			else (0 if direction > 0 else _gesture_clips.size() - 1)
	_play_gesture(_gesture_index)

func _toggle_gesture_panel() -> void:
	if _gesture_panel_open():
		_gesture_panel.visible = false
		player.set_physics_process(true)
		player.capture_mouse()
		return
	if not _gestures_available():
		return
	_ensure_gesture_clips()
	if _gesture_clips.is_empty():
		_show_interaction_toast("No gesture clips found")
		return
	if _gesture_panel == null:
		_build_gesture_panel()
	player.velocity = Vector3.ZERO
	player.set_physics_process(false)
	player.release_mouse()
	_gesture_panel.visible = true
	var buttons := _gesture_list.get_children()
	var focus_index := clampi(_gesture_index, 0, buttons.size() - 1)
	(buttons[focus_index] as Button).grab_focus()

func _build_gesture_panel() -> void:
	_gesture_panel = PanelContainer.new()
	_gesture_panel.name = "GesturePanel"
	_gesture_panel.visible = false
	_gesture_panel.set_anchors_preset(Control.PRESET_CENTER)
	_gesture_panel.offset_left = -180.0
	_gesture_panel.offset_right = 180.0
	_gesture_panel.offset_top = -190.0
	_gesture_panel.offset_bottom = 190.0
	_gesture_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_gesture_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var margin := MarginContainer.new()
	for side: String in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	for side: String in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	_gesture_panel.add_child(margin)
	var contents := VBoxContainer.new()
	margin.add_child(contents)
	var title := Label.new()
	title.text = "Gestures (%d) · click or Enter to play · M to close · , . step" % _gesture_clips.size()
	contents.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(330, 310)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	contents.add_child(scroll)
	_gesture_list = VBoxContainer.new()
	_gesture_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_gesture_list)
	for index in range(_gesture_clips.size()):
		var button := Button.new()
		button.text = str(_gesture_clips[index].name)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_pick_gesture.bind(index))
		_gesture_list.add_child(button)
	$StatusLayer.add_child(_gesture_panel)

func _pick_gesture(index: int) -> void:
	_gesture_index = index
	_toggle_gesture_panel()
	_play_gesture(index)

## Builds the animation for one clip, loading it on first use, and starts it. The first sequence in the file is played;
## it loops when its cycle type is loop, otherwise it plays once and the player returns to idle.
func _play_gesture(index: int) -> void:
	var clip: Dictionary = _gesture_clips[index]
	var clip_name := str(clip.name)
	_gesture_request_id += 1
	var request_id := _gesture_request_id
	_show_interaction_toast("%s  (%d/%d)" % [clip_name, index + 1, _gesture_clips.size()])
	var animation := await _gesture_animation(str(clip.path))
	if request_id != _gesture_request_id:
		return
	if animation.is_empty():
		_show_interaction_toast("Gesture failed to load: %s" % clip_name)
		return
	if not _gestures_available():
		return
	_player_animations[GESTURE_KEY] = animation
	_gesture_active = true
	_active_animation = ""
	_set_player_animation(GESTURE_KEY)
	_show_interaction_toast("%s  (%d/%d)%s" % [
		clip_name, index + 1, _gesture_clips.size(), "" if bool(animation.loops) else " · once"
	])

func _gesture_animation(asset_path: String, target_skeleton: Skeleton3D = null) -> Dictionary:
	await assets.meshes_for_model(asset_path)
	var metadata: Dictionary = assets.nif_metadata_cache.get(asset_path.to_lower(), {})
	var sequences: Array = metadata.get("animations", [])
	if sequences.is_empty():
		return {}
	var sequence_name := str((sequences[0] as Dictionary).get("name", ""))
	var animation := _animation_sequence(asset_path, sequence_name, target_skeleton).duplicate()
	if animation.is_empty() or (animation.get("tracks", []) as Array).is_empty():
		return {}
	animation["loops"] = int(animation.get("cycle_type", 0)) == 0
	return animation

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

## `base_animation` is played under the clip: many original idles (pointing, arms crossed, the CharGen gestures) only
## key the upper body, and without a base the unkeyed bones would stay in the bind pose (a T-pose).
func _apply_animation_pose(
	skeleton: Skeleton3D,
	animation: Dictionary,
	time: float,
	looping: bool = true,
	pose_from: Array[Dictionary] = [],
	blend_weight := 1.0,
	base_animation: Dictionary = {},
	skip_leg_tracks := false
) -> void:
	var start_time := float(animation.get("start_time", 0.0))
	var stop_time := float(animation.get("stop_time", start_time))
	var duration := stop_time - start_time
	if duration <= 0.0:
		return
	var sample_time := start_time + fposmod(time - start_time, duration) if looping else clampf(time, start_time, stop_time)
	skeleton.reset_bone_poses()
	if not base_animation.is_empty():
		var base_start := float(base_animation.get("start_time", 0.0))
		var base_duration := float(base_animation.get("stop_time", base_start)) - base_start
		if base_duration > 0.0:
			var base_time := base_start + fposmod(float(Time.get_ticks_msec()) * 0.001, base_duration)
			_apply_animation_tracks(skeleton, base_animation, base_time)
	_apply_animation_tracks(skeleton, animation, sample_time, skip_leg_tracks)
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

func _apply_animation_tracks(skeleton: Skeleton3D, animation: Dictionary, sample_time: float, skip_legs := false) -> void:
	for track_value: Variant in animation.get("tracks", []):
		var track: Dictionary = track_value
		var bone_index := int(track.get("bone_index", -1))
		if bone_index < 0:
			continue
		var bone_name := str(track.get("node_name", ""))
		if skip_legs and _is_leg_bone_name(bone_name):
			continue
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

func _reference_transform(reference: Dictionary) -> Transform3D:
	var position: PackedFloat32Array = reference.get("position", PackedFloat32Array())
	var rotation: PackedFloat32Array = reference.get("rotation", PackedFloat32Array())
	if position.size() < 3 or rotation.size() < 3:
		return Transform3D.IDENTITY
	var godot_rotation := _reference_rotation(rotation)
	var godot_position := Vector3(position[0], position[2], -position[1]) * game_units_to_meters
	return Transform3D(godot_rotation.scaled(Vector3.ONE * game_units_to_meters), godot_position)

func _reference_origin(reference: Dictionary) -> Vector3:
	var position: PackedFloat32Array = reference.get("position", PackedFloat32Array())
	var rotation: PackedFloat32Array = reference.get("rotation", PackedFloat32Array())
	if position.size() < 3 or rotation.size() < 3:
		return Vector3.ZERO
	return Vector3(position[0], position[2], -position[1]) * game_units_to_meters

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
