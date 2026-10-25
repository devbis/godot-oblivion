extends RefCounted
## The first-person view model: the player's arms (with the readied weapon) as the original game shows them while the
## weapon is drawn. It is the original `Characters/_1stperson/skeleton.nif` rig, skinned with the arm and hand meshes only
## and posed by the `Characters/_1stperson` KF clips, parented to the camera so it stays where it is on screen while the
## view moves.

const ActorFactory := preload("res://scripts/actor_factory.gd")
const AnimationSampling := preload("res://scripts/animation_sampling.gd")
const CombatProjectile := preload("res://scripts/combat_projectile.gd")

## Fired for the text keys of a one-shot clip that gameplay reacts to ("hit", "release"), with the kind of the clip
## ("attack" or "cast").
signal clip_event(event_name: String, clip_kind: String)

const SKELETON_MODEL := "Characters/_1stperson/skeleton.nif"
const CLIP_FOLDER := "Characters/_1stperson/"
const BODY_PARTS := [
	{"model": "Characters/_male/upperbody.nif", "mesh": "arms", "slot": 0x0004},
	{"model": "Characters/_male/hand.nif", "mesh": "", "slot": 0x0010},
]
## weapon_type of a WEAP record -> the clip-name prefix of its first-person animations and the bone that holds it.
const STANCES := {
	0: {"prefix": "onehand", "hold_bone": "Weapon"},
	1: {"prefix": "twohand", "hold_bone": "Weapon"},
	2: {"prefix": "onehand", "hold_bone": "Weapon"},
	3: {"prefix": "twohand", "hold_bone": "Weapon"},
	4: {"prefix": "staff", "hold_bone": "Weapon"},
	5: {"prefix": "bow", "hold_bone": "Torch"},
}
const UNARMED_STANCE := {"prefix": "handtohand", "hold_bone": "Weapon"}
const CAMERA_BONE := "Camera01"
## The walk and run clips carry the distance travelled in this root bone's translation; the camera does not follow it, so it
## would slide the arms ahead of the view and snap them back each cycle. The game moves the player, not the rig.
const ROOT_MOTION_BONE := "Bip01"
## The view model is drawn at this fraction of its real size, moved toward the camera by the same fraction, so it looks the
## same and stays out of walls the camera is close to.
const VIEW_MODEL_SCALE := 0.4
## Oblivion.esm's fFirstPersonCameraMult: how much of the camera node's animation the view follows. The arms are not
## compensated for the rest, so the camera's bob in the walk clips shows up as the arms moving against the view.
const CAMERA_FOLLOW_MULT := 0.5
## The view model is also moved this far (camera space, metres): toward the viewer, so the shoulders sit below the screen
## edge and the arms do not look cut off from the body.
const VIEW_MODEL_OFFSET := Vector3(0.0, 0.0, 0.02)
## The clips hold the arms almost still while walking (the original adds the sway in code): a step bob, in metres at the
## view model's scale, one side-to-side and one up-down swing per step. Running swings more, sneaking less.
const BOB_SWAY_M := Vector2(0.003, 0.004)
const BOB_RUN_MULT := 1.6
const BOB_SNEAK_MULT := 0.5
const BOB_BLEND_PER_S := 5.0
## The arms trail the view when the mouse turns it and settle back (the original's fFirstPersonHandFollowMult): the share of
## each turn they keep, how fast they settle, and the most they trail.
const HAND_FOLLOW_MULT := 0.35
const HAND_FOLLOW_SETTLE_PER_S := 7.0
const HAND_FOLLOW_MAX_RAD := 0.14
const BLEND_S := 0.15
const WALK_SPEED_EPSILON := 0.08
const ARM_BODY_SLOTS := 0x0004 | 0x0010

enum Mode { HIDDEN, EQUIPPING, READY, UNEQUIPPING }

var host: Node3D
var camera: Camera3D
var root: Node3D
var skeleton: Skeleton3D
var built := false
var _building := false

var _meters_per_unit := 0.01
var _mode := Mode.HIDDEN
var _stance: Dictionary = UNARMED_STANCE
var _weapon_meshes: Array[MeshInstance3D] = []
var _nocked_arrow: Array[MeshInstance3D] = []
var _nocked_arrow_attachment: BoneAttachment3D
var _weapon_wanted := false
var _equipment_meshes: Array[MeshInstance3D] = []
var _body_meshes: Dictionary = {}
var _clips: Dictionary = {}
var _clips_requested: Dictionary = {}
var _available_clips: Dictionary = {}
var _posed := false
var _suppressed := false
var _camera_bone := -1
var _active_clip := ""
var _time := 0.0
var _from_pose: Array[Dictionary] = []
var _blend_elapsed := BLEND_S
var _one_shot := ""
var _one_shot_kind := ""
var _one_shot_candidates: Array[String] = []
var _one_shot_wait_s := 0.0
var _queued: Dictionary = {}
var _blocking := false
var _hide_after_cast := false
var _camera_rest := Vector3.ZERO
var _bob_phase := 0.0
var _bob_weight := 0.0
var _bob_offset := Vector3.ZERO
var _hand_lag := Quaternion.IDENTITY
var _last_camera_basis := Basis.IDENTITY

func _init(host_node: Node3D, view_camera: Camera3D, meters_per_unit: float) -> void:
	host = host_node
	camera = view_camera
	_meters_per_unit = meters_per_unit

## True from the moment the weapon starts to be drawn until it has been lowered.
func is_shown() -> bool:
	return _mode != Mode.HIDDEN

func is_ready() -> bool:
	return _mode == Mode.READY

## True while an equip, unequip, attack or cast clip runs, and no new one can start.
func is_busy() -> bool:
	return _mode == Mode.EQUIPPING or _mode == Mode.UNEQUIPPING or not _one_shot.is_empty() or not _one_shot_candidates.is_empty()

func stance_prefix() -> String:
	return str(_stance.prefix)

## Builds the rig and the arm meshes under the camera. Safe to call again; later calls do nothing.
func build() -> void:
	if built or _building or host == null or not is_instance_valid(camera):
		return
	_building = true
	var assets = host.get("assets")
	for clip_path: String in assets.data_reader.list_assets("meshes/characters/_1stperson"):
		_available_clips[clip_path.replace("\\", "/").to_lower().get_file().get_basename()] = true
	await assets.meshes_for_model(SKELETON_MODEL)
	var metadata: Dictionary = assets.nif_metadata_cache.get(SKELETON_MODEL.to_lower(), {})
	skeleton = ActorFactory.build_skeleton(metadata.get("nodes", []))
	if skeleton == null:
		_building = false
		return
	root = Node3D.new()
	root.name = "FirstPersonArms"
	root.visible = false
	camera.add_child(root)
	root.add_child(skeleton)
	_camera_bone = skeleton.find_bone(CAMERA_BONE)
	# The first-person rig keeps its camera node at the root, not under the head as the third-person rig does: the clips
	# give it an absolute eye position.
	if _camera_bone >= 0:
		skeleton.set_bone_parent(_camera_bone, 0)
	for part: Dictionary in BODY_PARTS:
		var meshes: Array = await assets.meshes_for_model(str(part.model))
		for mesh_entry: Dictionary in meshes:
			if bool(mesh_entry.get("editor_marker", false)):
				continue
			var wanted_mesh := str(part.mesh)
			if not wanted_mesh.is_empty() and str(mesh_entry.get("mesh_name", "")).to_lower() != wanted_mesh:
				continue
			var instance := MeshInstance3D.new()
			instance.name = str(part.model).get_file().get_basename() + "_" + str(mesh_entry.get("mesh_name", "Mesh"))
			instance.mesh = mesh_entry.mesh as ArrayMesh
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			instance.material_override = await assets.material_for_texture(
				str(mesh_entry.diffuse_texture_path),
				bool(mesh_entry.get("alpha_blend", false)),
				bool(mesh_entry.get("alpha_test", false)),
				int(mesh_entry.get("alpha_threshold", 128))
			)
			root.get_node("Skeleton3D").add_child(instance)
			var bone_names: Array = mesh_entry.get("bone_names", [])
			if not bone_names.is_empty():
				instance.skeleton = NodePath("..")
				instance.skin = ActorFactory.skin_for_mesh(bone_names, skeleton)
			if not _body_meshes.has(int(part.slot)):
				_body_meshes[int(part.slot)] = []
			(_body_meshes[int(part.slot)] as Array).push_back(instance)
	built = true
	_building = false
	_apply_rest_pose_placement()
	_preload_stance()

## Shows the items worn on the arms and hands (shirt sleeves, gauntlets) instead of the bare arms and hands they cover.
func set_equipment(entries: Array) -> void:
	if not built or skeleton == null:
		return
	for old_mesh in _equipment_meshes:
		if is_instance_valid(old_mesh):
			old_mesh.queue_free()
	_equipment_meshes.clear()
	var covered_slots := 0
	for entry_value: Variant in entries:
		var entry: Dictionary = entry_value
		var slots := int(entry.get("slots", 0)) & ARM_BODY_SLOTS
		if slots == 0:
			continue
		covered_slots |= slots
		var meshes: Array[MeshInstance3D] = await host.get("actors").add_actor_model(
			root, skeleton, str(entry.get("model_path", ""))
		)
		for mesh in meshes:
			mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_keep_arm_triangles(mesh)
			_equipment_meshes.push_back(mesh)
	for slot_value: Variant in _body_meshes.keys():
		for body_mesh_value: Variant in _body_meshes[slot_value]:
			var body_mesh := body_mesh_value as MeshInstance3D
			if is_instance_valid(body_mesh):
				body_mesh.visible = (covered_slots & int(slot_value)) == 0

## The torso of a shirt or cuirass is never meant to be seen in first person, and the clips twist the body into view now and
## then, so only the triangles skinned mostly to arm and hand bones are kept.
func _keep_arm_triangles(instance: MeshInstance3D) -> void:
	var source := instance.mesh as ArrayMesh
	if source == null or instance.skin == null:
		return
	var filtered := ArrayMesh.new()
	for surface in range(source.get_surface_count()):
		var arrays := source.surface_get_arrays(surface)
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES] if arrays[Mesh.ARRAY_BONES] != null else PackedInt32Array()
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS] if arrays[Mesh.ARRAY_WEIGHTS] != null else PackedFloat32Array()
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var vertex_count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		if bones.size() != vertex_count * 4 or weights.size() != vertex_count * 4 or indices.is_empty():
			filtered.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			continue
		var on_arm := PackedByteArray()
		on_arm.resize(vertex_count)
		for vertex in range(vertex_count):
			var strongest := 0
			for influence in range(1, 4):
				if weights[vertex * 4 + influence] > weights[vertex * 4 + strongest]:
					strongest = influence
			on_arm[vertex] = 1 if _is_arm_bone(instance.skin.get_bind_name(bones[vertex * 4 + strongest])) else 0
		var kept := PackedInt32Array()
		for triangle in range(0, indices.size(), 3):
			if on_arm[indices[triangle]] + on_arm[indices[triangle + 1]] + on_arm[indices[triangle + 2]] >= 2:
				kept.append(indices[triangle])
				kept.append(indices[triangle + 1])
				kept.append(indices[triangle + 2])
		if kept.is_empty():
			continue
		arrays[Mesh.ARRAY_INDEX] = kept
		filtered.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	instance.mesh = filtered

static func _is_arm_bone(bone_name: String) -> bool:
	return bone_name.contains("UpperArm") or bone_name.contains("Forearm") or bone_name.contains("Hand") \
		or bone_name.contains("Finger") or bone_name.contains("Wrist")

## `weapon_type` is the WEAP record's type, or -1 for bare hands; `model_path` is empty for them.
func set_weapon(weapon_type: int, model_path: String) -> void:
	_stance = STANCES.get(weapon_type, UNARMED_STANCE)
	for old_mesh in _weapon_meshes:
		if is_instance_valid(old_mesh):
			old_mesh.queue_free()
	_weapon_meshes.clear()
	_clear_nocked_arrow()
	_preload_stance()
	if not built or skeleton == null or model_path.is_empty():
		return
	var meshes: Array[MeshInstance3D] = await host.get("actors").add_actor_model(
		root, skeleton, model_path, str(_stance.hold_bone)
	)
	if not is_instance_valid(skeleton):
		return
	for old_mesh in _weapon_meshes:
		if is_instance_valid(old_mesh):
			old_mesh.queue_free()
	_weapon_meshes = meshes
	for mesh in _weapon_meshes:
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_apply_weapon_visibility()
	if weapon_type == 5:
		await _build_nocked_arrow()

## The arrow drawn back on the bow: it rides the bow's hold bone, tip at the grip, and shows from the "Attach" key of the
## attack clip until the "Release" key.
func _build_nocked_arrow() -> void:
	var arrows := await CombatProjectile.build_arrow_meshes(host.get("assets"), 1.0)
	if arrows.is_empty() or not is_instance_valid(skeleton):
		return
	_clear_nocked_arrow()
	_nocked_arrow_attachment = BoneAttachment3D.new()
	_nocked_arrow_attachment.bone_name = str(_stance.hold_bone)
	skeleton.add_child(_nocked_arrow_attachment)
	for arrow in arrows:
		arrow.visible = false
		_nocked_arrow_attachment.add_child(arrow)
	_nocked_arrow = arrows

func _clear_nocked_arrow() -> void:
	if is_instance_valid(_nocked_arrow_attachment):
		_nocked_arrow_attachment.queue_free()
	_nocked_arrow_attachment = null
	_nocked_arrow.clear()

func _set_nocked_arrow_visible(arrow_visible: bool) -> void:
	for arrow in _nocked_arrow:
		if is_instance_valid(arrow):
			arrow.visible = arrow_visible

## Raises the weapon: the equip clip plays and the weapon appears at its "Attach" key. `force` raises it again
## when it is already up (a new weapon was taken).
func draw(force := false) -> void:
	if not built or (not force and not _hide_after_cast and (_mode == Mode.READY or _mode == Mode.EQUIPPING)):
		return
	_queued.clear()
	_blocking = false
	_hide_after_cast = false
	_mode = Mode.EQUIPPING
	_posed = false
	_weapon_wanted = false
	_apply_weapon_visibility()
	_begin_one_shot([str(_stance.prefix) + "equip"], "equip")

## Lowers the weapon: the unequip clip plays, the weapon leaves at its "Attach" key, and the arms hide at the end.
func holster() -> void:
	if _mode == Mode.HIDDEN or _mode == Mode.UNEQUIPPING:
		return
	_queued.clear()
	_blocking = false
	_mode = Mode.UNEQUIPPING
	_begin_one_shot([str(_stance.prefix) + "unequip"], "unequip")

## Hides the arms (a dialogue, the inventory, the third-person camera) without changing whether the weapon is drawn.
func set_suppressed(suppressed: bool) -> void:
	_suppressed = suppressed
	_refresh_visibility()

func _refresh_visibility() -> void:
	if root != null:
		root.visible = _mode != Mode.HIDDEN and _posed and not _suppressed

## An attack with the stance's clips; `side` is "right", "left" or "power". Does nothing while another clip runs.
func attack(side: String) -> bool:
	if _mode != Mode.READY or is_busy():
		return false
	var prefix := str(_stance.prefix)
	var candidates: Array[String] = []
	if prefix == "bow":
		candidates = ["bowattack"]
	else:
		candidates = [prefix + "attack" + side, prefix + "attackright"]
	_begin_one_shot(candidates, "attack")
	return true

## A cast clip for a spell's range (0 self, 1 touch, 2 target). Waits for the equip clip if the weapon is not drawn yet.
func cast(range_type: int) -> void:
	var suffix: String = ["self", "touch", "target"][clampi(range_type, 0, 2)]
	var prefix := str(_stance.prefix)
	var candidates: Array[String] = ["cast" + suffix]
	if prefix == "onehand" and _weapon_wanted:
		candidates.push_front("onehandcast" + suffix)
	if _mode == Mode.HIDDEN:
		# No weapon in hand: the bare arm casts and the arms go away again when the clip ends.
		_mode = Mode.READY
		_hide_after_cast = true
		_posed = false
		_weapon_wanted = false
		_apply_weapon_visibility()
		_begin_one_shot(candidates, "cast")
		return
	if _mode != Mode.READY or is_busy():
		_queued = {"candidates": candidates, "kind": "cast"}
		return
	_begin_one_shot(candidates, "cast")

func set_blocking(blocking: bool) -> void:
	_blocking = blocking and _mode == Mode.READY

func update(delta: float, motion: Dictionary) -> void:
	if _mode == Mode.HIDDEN or skeleton == null or not built:
		return
	_resolve_one_shot(delta)
	var wanted := _one_shot if not _one_shot.is_empty() else _base_clip(motion)
	if wanted != _active_clip:
		var wanted_clip: Dictionary = _clips.get(wanted, {})
		if wanted_clip.is_empty():
			_request_clip(wanted)
			wanted = _fallback_clip(motion)
		if wanted != _active_clip:
			_switch_to(wanted)
	var clip: Dictionary = _clips.get(_active_clip, {})
	if clip.is_empty():
		return
	var previous_time := _time
	_time += delta
	_blend_elapsed = minf(_blend_elapsed + delta, BLEND_S)
	var start_time := float(clip.start_time)
	var stop_time := float(clip.stop_time)
	var looping := _one_shot.is_empty() and bool(clip.loops)
	var sample_time := start_time + fposmod(_time - start_time, stop_time - start_time) if looping else clampf(_time, start_time, stop_time)
	_pose(clip, sample_time, _blend_elapsed / BLEND_S)
	_update_sway(delta, motion, clip)
	_place_under_camera()
	_posed = true
	_refresh_visibility()
	if not _one_shot.is_empty():
		_fire_events(clip, previous_time, minf(_time, stop_time))
		if _time >= stop_time:
			_finish_one_shot()

func _base_clip(motion: Dictionary) -> String:
	var prefix := str(_stance.prefix)
	var sneak := "sneak" if bool(motion.get("crouching", false)) else ""
	if _blocking:
		return prefix + "blockidle"
	if bool(motion.get("airborne", false)):
		return prefix + "jumploop"
	var local_velocity: Vector3 = motion.get("local_velocity", Vector3.ZERO)
	# The bare-hand walk and run clips lower the fists about 7 units and push them forward (and are the same clip for walking
	# and running), which the original does not do: the fists stay where they are at rest, so they use the idle clip.
	if Vector2(local_velocity.x, local_velocity.z).length() <= WALK_SPEED_EPSILON or prefix == UNARMED_STANCE.prefix:
		return sneak + prefix + "idle"
	var direction := "forward"
	if absf(local_velocity.x) > absf(local_velocity.z):
		direction = "left" if local_velocity.x < 0.0 else "right"
	elif local_velocity.z > 0.0:
		direction = "backward"
	var fast := "fast" if bool(motion.get("running", false)) and sneak.is_empty() else ""
	return sneak + prefix + fast + direction

func _fallback_clip(motion: Dictionary) -> String:
	var prefix := str(_stance.prefix)
	for candidate: String in [prefix + "idle", "handtohandidle", "idle"]:
		if not (_clips.get(candidate, {}) as Dictionary).is_empty():
			return candidate
	return _active_clip

## Queues a one-shot: it starts as soon as one of the clips has loaded, and gives up (finishing at once) when none exists.
func _begin_one_shot(candidates: Array[String], kind: String) -> void:
	_one_shot = ""
	_one_shot_kind = kind
	_one_shot_candidates = candidates
	_one_shot_wait_s = 0.0
	for candidate in candidates:
		_request_clip(candidate)

func _resolve_one_shot(delta: float) -> void:
	if _one_shot_candidates.is_empty():
		return
	var all_missing := true
	for candidate in _one_shot_candidates:
		if not (_clips.get(candidate, {}) as Dictionary).is_empty():
			_one_shot = candidate
			_one_shot_candidates = []
			_switch_to(candidate)
			return
		if not _clips_requested.get(candidate, "") == "missing":
			all_missing = false
	_one_shot_wait_s += delta
	if all_missing or _one_shot_wait_s > 4.0:
		_one_shot_candidates = []
		_finish_one_shot()

func _finish_one_shot() -> void:
	var kind := _one_shot_kind
	_one_shot = ""
	_one_shot_kind = ""
	_one_shot_candidates = []
	_set_nocked_arrow_visible(false)
	if _hide_after_cast and kind == "cast":
		_hide_after_cast = false
		_mode = Mode.HIDDEN
		_queued = {}
		_refresh_visibility()
		return
	match kind:
		"equip":
			_mode = Mode.READY
			_weapon_wanted = true
			_apply_weapon_visibility()
		"unequip":
			_mode = Mode.HIDDEN
			_weapon_wanted = false
			_refresh_visibility()
			return
	if _mode == Mode.READY and not _queued.is_empty():
		var queued := _queued
		_queued = {}
		_begin_one_shot(queued.candidates, str(queued.kind))

func _fire_events(clip: Dictionary, from_time: float, to_time: float) -> void:
	for key_value: Variant in clip.get("text_keys", []):
		var key: Dictionary = key_value
		var key_time := float(key.time)
		if key_time <= from_time or key_time > to_time:
			continue
		var key_name := str(key.name).strip_edges().to_lower()
		if key_name == "attach":
			if _one_shot_kind == "equip":
				_weapon_wanted = true
			elif _one_shot_kind == "unequip":
				_weapon_wanted = false
			elif _one_shot_kind == "attack":
				_set_nocked_arrow_visible(true)
			_apply_weapon_visibility()
		elif key_name in ["hit", "release"]:
			if key_name == "release":
				_set_nocked_arrow_visible(false)
			clip_event.emit(key_name, _one_shot_kind)

func _apply_weapon_visibility() -> void:
	for mesh in _weapon_meshes:
		if is_instance_valid(mesh):
			mesh.visible = _weapon_wanted

func _switch_to(clip_name: String) -> void:
	if skeleton != null:
		_from_pose = _capture_pose()
		_blend_elapsed = 0.0
	_active_clip = clip_name
	_time = float((_clips.get(clip_name, {}) as Dictionary).get("start_time", 0.0))

func _capture_pose() -> Array[Dictionary]:
	var pose: Array[Dictionary] = []
	pose.resize(skeleton.get_bone_count())
	for bone_index in range(skeleton.get_bone_count()):
		pose[bone_index] = {
			"position": skeleton.get_bone_pose_position(bone_index),
			"rotation": skeleton.get_bone_pose_rotation(bone_index),
			"scale": skeleton.get_bone_pose_scale(bone_index),
		}
	return pose

## Applies every track of the clip: unlike the third-person clips these carry the whole body's placement (the travelled
## distance aside, see ROOT_MOTION_BONE), and the camera bone is read back from the posed rig to place the view model.
func _pose(clip: Dictionary, sample_time: float, blend_weight: float) -> void:
	skeleton.reset_bone_poses()
	for track_value: Variant in clip.tracks:
		var track: Dictionary = track_value
		var bone_index := int(track.bone_index)
		var translations: PackedFloat32Array = track.get("translations", PackedFloat32Array())
		if translations.size() >= 4:
			skeleton.set_bone_pose_position(bone_index, AnimationSampling.vector(translations, 4, sample_time))
		var rotations: PackedFloat32Array = track.get("rotations", PackedFloat32Array())
		if rotations.size() >= 5:
			skeleton.set_bone_pose_rotation(bone_index, AnimationSampling.quaternion(rotations, sample_time))
		var scales: PackedFloat32Array = track.get("scales", PackedFloat32Array())
		if scales.size() >= 2:
			skeleton.set_bone_pose_scale(bone_index, Vector3.ONE * AnimationSampling.scalar(scales, sample_time))
	if _from_pose.size() != skeleton.get_bone_count() or blend_weight >= 1.0:
		return
	var weight := clampf(blend_weight, 0.0, 1.0)
	for bone_index in range(skeleton.get_bone_count()):
		var source: Dictionary = _from_pose[bone_index]
		skeleton.set_bone_pose_position(bone_index, Vector3(source.position).lerp(skeleton.get_bone_pose_position(bone_index), weight))
		skeleton.set_bone_pose_rotation(bone_index, Quaternion(source.rotation).slerp(skeleton.get_bone_pose_rotation(bone_index), weight))
		skeleton.set_bone_pose_scale(bone_index, Vector3(source.scale).lerp(skeleton.get_bone_pose_scale(bone_index), weight))

## Walking sways the arms: a bob that follows the step cycle of the walk or run clip and fades in and out with movement,
## and a trail behind the view's turns.
func _update_sway(delta: float, motion: Dictionary, clip: Dictionary) -> void:
	var local_velocity: Vector3 = motion.get("local_velocity", Vector3.ZERO)
	var walking := (
		_one_shot.is_empty()
		and not _blocking
		and not bool(motion.get("airborne", false))
		and Vector2(local_velocity.x, local_velocity.z).length() > WALK_SPEED_EPSILON
	)
	_bob_weight = move_toward(_bob_weight, 1.0 if walking else 0.0, BOB_BLEND_PER_S * delta)
	var cycle_s := maxf(float(clip.stop_time) - float(clip.start_time), 0.1) if walking else 1.0
	_bob_phase = fposmod(_bob_phase + delta * TAU / cycle_s, TAU)
	var strength := _bob_weight
	if bool(motion.get("crouching", false)):
		strength *= BOB_SNEAK_MULT
	elif bool(motion.get("running", false)):
		strength *= BOB_RUN_MULT
	_bob_offset = Vector3(sin(_bob_phase) * BOB_SWAY_M.x, cos(_bob_phase * 2.0) * BOB_SWAY_M.y, 0.0) * strength
	var camera_basis := camera.global_basis.orthonormalized()
	var turn := Quaternion(_last_camera_basis.inverse() * camera_basis)
	_last_camera_basis = camera_basis
	var turn_angle := turn.get_angle()
	var turn_axis := turn.get_axis()
	# A turn too small to have an axis (the view is still) leaves the trail alone.
	if turn_angle > 0.0001 and turn_angle < 1.0 and turn_axis.is_normalized():
		var followed := Quaternion(turn_axis, -turn_angle * HAND_FOLLOW_MULT)
		_hand_lag = (followed * _hand_lag).normalized()
		if _hand_lag.get_angle() > HAND_FOLLOW_MAX_RAD:
			_hand_lag = Quaternion.IDENTITY.slerp(_hand_lag, HAND_FOLLOW_MAX_RAD / _hand_lag.get_angle())
	_hand_lag = _hand_lag.slerp(Quaternion.IDENTITY, 1.0 - exp(-HAND_FOLLOW_SETTLE_PER_S * delta))

## The posed rig is moved so its camera bone sits on the camera, the view following the bone by CAMERA_FOLLOW_MULT; the
## rig's own turn is ignored, as the view keeps looking where the mouse points.
func _place_under_camera() -> void:
	if _camera_bone < 0:
		return
	var camera_pose := skeleton.get_bone_global_pose(_camera_bone)
	# Casting and drawing a bow turn the body (and this bone with it) sideways in the clips, so only its position is used.
	var eye := _camera_rest.lerp(camera_pose.origin, CAMERA_FOLLOW_MULT)
	var scale_factor := _meters_per_unit * VIEW_MODEL_SCALE
	var placed := Transform3D(
		Basis.from_scale(Vector3.ONE * scale_factor),
		-eye * scale_factor + VIEW_MODEL_OFFSET + _bob_offset
	)
	root.transform = Transform3D(Basis(_hand_lag), Vector3.ZERO) * placed

func _apply_rest_pose_placement() -> void:
	skeleton.reset_bone_poses()
	if _camera_bone >= 0:
		_camera_rest = skeleton.get_bone_global_pose(_camera_bone).origin
	_place_under_camera()

func _request_clip(clip_name: String) -> void:
	if _clips.has(clip_name) or _clips_requested.has(clip_name) or not built:
		return
	if not _available_clips.has(clip_name):
		_clips_requested[clip_name] = "missing"
		return
	_clips_requested[clip_name] = "loading"
	_load_clip(clip_name)

func _load_clip(clip_name: String) -> void:
	var path := CLIP_FOLDER + clip_name + ".kf"
	var assets = host.get("assets")
	await assets.meshes_for_model(path)
	if not is_instance_valid(skeleton):
		return
	var metadata: Dictionary = assets.nif_metadata_cache.get(path.to_lower(), {})
	var sequences: Array = metadata.get("animations", [])
	if sequences.is_empty():
		_clips_requested[clip_name] = "missing"
		return
	var sequence: Dictionary = sequences[0]
	var tracks: Array = []
	for track_value: Variant in sequence.get("tracks", []):
		var source: Dictionary = track_value
		var bone_name := str(source.get("node_name", ""))
		var bone_index := skeleton.find_bone(bone_name)
		if bone_index < 0:
			continue
		var track := source.duplicate()
		track["bone_index"] = bone_index
		if bone_name == ROOT_MOTION_BONE:
			track.erase("translations")
		tracks.push_back(track)
	var start_time := float(sequence.get("start_time", 0.0))
	var stop_time := float(sequence.get("stop_time", start_time))
	if tracks.is_empty() or stop_time <= start_time:
		_clips_requested[clip_name] = "missing"
		return
	_clips[clip_name] = {
		"tracks": tracks,
		"start_time": start_time,
		"stop_time": stop_time,
		"loops": int(sequence.get("cycle_type", 0)) == 0,
		"text_keys": sequence.get("text_keys", []),
	}
	_clips_requested[clip_name] = "loaded"

## Starts loading the clips a stance plays, so the first draw and swing do not wait on the reader.
func _preload_stance() -> void:
	var prefix := str(_stance.prefix)
	for suffix: String in [
		"idle", "equip", "unequip", "forward", "backward", "left", "right",
		"fastforward", "fastbackward", "fastleft", "fastright", "blockidle",
		"attackright", "attackleft", "attack", "jumploop",
	]:
		_request_clip(prefix + suffix)
	for cast_name: String in ["castself", "casttouch", "casttarget"]:
		_request_clip(cast_name)
