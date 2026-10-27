extends RefCounted
## Assembles NPC models: skeleton, body, head with FaceGen morphs, face details, hair and equipment, plus the
## FaceGen and race texture caches they use.

const NifAssetLibrary := preload("res://scripts/nif_asset_library.gd")
const FaceGenData := preload("res://scripts/facegen_data.gd")
const PLAYER_HEAD_CULL_MARGIN := 128.0
const PLAYER_FACE_DETAIL_PARTS := [
	"Characters/Imperial/eyeLeftHuman.nif",
	"Characters/Imperial/eyeRightHuman.nif",
	"Characters/Imperial/mouthHuman.nif",
	"Characters/Imperial/teethUpperHuman.nif",
	"Characters/Imperial/teethLowerHuman.nif",
	"Characters/Imperial/tongueHuman.nif",
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

## Native OblivionData reader; assigned by the owner once it exists.
var data_reader: Object
var assets: NifAssetLibrary
var facegen_cache: Dictionary = {}
var facegen_texture_cache: Dictionary = {}
var facegen_expression_names: Array[String] = []
var _race_texture_path_cache: Dictionary = {}

func _init(asset_library: NifAssetLibrary) -> void:
	assets = asset_library

## Builds the body, head, face details, hair and equipment of an NPC onto its avatar and skeleton. Returns
## {"face_meshes", "attached_item_names"}, or an empty dictionary when is_current turns false while models load (the
## caller discards the actor).
func assemble_npc_model(avatar: Node3D, skeleton: Skeleton3D, npc: Dictionary, is_current: Callable) -> Dictionary:
	var is_female := bool(npc.get("female", false))
	var race_editor_id := str(data_reader.find_editor_id(int(npc.get("race_form_id", 0)))).to_lower()
	var race_texture_key := _npc_race_texture_key(race_editor_id)
	var eye_texture_path := _npc_eye_texture_path(npc, race_editor_id)
	var head_model_path := npc_head_model_path(npc)
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
	var face_meshes: Array[MeshInstance3D] = []
	for body_part: Dictionary in _npc_body_part_entries(npc, is_female):
		if (int(body_part.get("biped_slot", 0)) & covered_body_slots) != 0:
			continue
		await add_actor_model(
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
		if not is_current.call():
			return {}
	var head_meshes: Array[MeshInstance3D] = await add_actor_model(
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
	if not is_current.call():
		return {}
	face_meshes.append_array(head_meshes)
	for detail_part: Dictionary in _npc_face_detail_entries(npc):
		var detail_path := str(detail_part.get("model_path", ""))
		var is_eye_model := int(detail_part.get("index", -1)) >= 7 or detail_path.to_lower().contains("eye")
		var is_ear_model := int(detail_part.get("index", -1)) == 1 or int(detail_part.get("index", -1)) == 2 or detail_path.to_lower().contains("ear")
		var uses_head_bone_rotation := _face_detail_uses_head_bone_rotation(
			int(detail_part.get("index", -1)), detail_path
		)
		var detail_face_data: Dictionary = {} if is_ear_model else npc
		var detail_meshes: Array[MeshInstance3D] = await add_actor_model(
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
		if not is_current.call():
			return {}
	if covered_head_slots == 0:
		var hair_form_id := int(npc.get("hair_form_id", 0))
		var hair_path := str(data_reader.find_item_model_path(hair_form_id, is_female)) if hair_form_id != 0 else ""
		if hair_path.is_empty():
			hair_path = "Characters/Imperial/female/hair01.nif" if is_female else "Characters/Imperial/male/hair01.nif"
		var hair_color: PackedByteArray = npc.get("hair_color", PackedByteArray())
		var hair_is_model_space := hair_path.to_lower().replace("\\", "/").contains("/imperial/")
		await add_actor_model(
			avatar, skeleton, hair_path, "Bip01 Head", hair_color, {}, hair_is_model_space,
			"", "", "", not hair_is_model_space
		)
		if not is_current.call():
			return {}
	var weapon_attached := false
	var weapon_form_id := 0
	var weapon_meshes: Array[MeshInstance3D] = []
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
		var attachment := await equipment_attachment(item_form_id, item_path, item_type, skeleton)
		# The cell may have been left while the NIF loaded.
		if not is_current.call() or not is_instance_valid(skeleton):
			return {}
		if bool(attachment.get("skip", false)):
			continue
		var attach_bone := str(attachment.get("bone", ""))
		var adjust_bone_orientation := bool(attachment.get("adjust_rotation", false))
		var model_space_bone_attachment := bool(attachment.get("model_space", false))
		var item_meshes := await add_actor_model(
			avatar, skeleton, item_path, attach_bone, PackedByteArray(), {}, model_space_bone_attachment,
			race_texture_key, "", "", adjust_bone_orientation
		)
		if not is_current.call():
			return {}
		attached_item_names.push_back(str(data_reader.find_editor_id(item_form_id)))
		if item_type == "WEAP":
			weapon_attached = true
			weapon_form_id = item_form_id
			weapon_meshes = item_meshes
	return {
		"face_meshes": face_meshes, "attached_item_names": attached_item_names,
		"weapon_form_id": weapon_form_id, "weapon_meshes": weapon_meshes,
	}

## A creature is its skeleton with the skinned parts its record lists (NIFZ) attached; false when the cell was left.
func assemble_creature_model(avatar: Node3D, skeleton: Skeleton3D, creature: Dictionary, is_current: Callable) -> bool:
	# NIFZ names the parts by file name, next to the skeleton.
	var model_folder := str(creature.get("model_path", "")).replace("\\", "/").get_base_dir()
	for part_name: String in creature.get("body_part_paths", PackedStringArray()):
		var part_path := part_name if part_name.contains("/") or part_name.contains("\\") else model_folder + "/" + part_name
		var part_meshes: Array = await assets.meshes_for_model(part_path)
		if not is_current.call() or not is_instance_valid(skeleton):
			return false
		# A part without skin weights (a skull, eyes, horns) is local to the bone it belongs to; its NIF node is named
		# after the part, not the bone, so the bone is chosen by what the part is.
		var attach_bone := ""
		var model_space := false
		for mesh_entry: Dictionary in part_meshes:
			if not (mesh_entry.get("bone_names", []) as Array).is_empty():
				continue
			attach_bone = _creature_part_bone(skeleton, str(mesh_entry.get("parent_node_name", "")) + " " + part_path.get_file())
			# Vertices at the bone's own height are in model space; those near the origin are local to the bone.
			model_space = (mesh_entry.mesh as ArrayMesh).get_aabb().get_center().length() > 50.0
			break
		# The vertices are in the bone's own axes (x along the bone), so the part follows the bone's full rotation.
		if not attach_bone.is_empty():
			print("OpenOB creature part %s hangs on %s (%s)" % [part_path, attach_bone, "model space" if model_space else "bone space"])
		await add_actor_model(avatar, skeleton, part_path, attach_bone, PackedByteArray(), {}, model_space)
	return true

func _creature_part_bone(skeleton: Skeleton3D, part_name: String) -> String:
	var lowered := part_name.to_lower()
	var candidates: Array[String] = []
	for head_word: String in ["head", "skull", "eye", "whisker", "horn", "cap", "helm", "hat", "jaw", "ear", "tongue"]:
		if lowered.contains(head_word):
			candidates = ["Bip01 Head", "Bip01 Skull"]
			break
	if candidates.is_empty() and (lowered.contains("bag") or lowered.contains("pack")):
		candidates = ["Bip01 Spine1", "Bip01 Spine"]
	for candidate: String in candidates:
		if skeleton.find_bone(candidate) >= 0:
			return candidate
	return ""

func npc_head_model_path(npc: Dictionary) -> String:
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
		return {"model_path": npc_head_model_path(npc), "texture_path": ""}
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

const FACEGEN_MESH_CACHE_LIMIT := 192
var _facegen_mesh_cache: Dictionary = {}

## FaceGen morphing runs in GDScript on the main thread, so a finished mesh is kept by source mesh and coefficients: the
## same NPC face (or a profile cycled back to) is not rebuilt.
func build_facegen_mesh(
	source_mesh: ArrayMesh,
	symmetric: PackedFloat32Array,
	asymmetric: PackedFloat32Array,
	facegen_data: Dictionary
) -> ArrayMesh:
	var cache_key := "%d|%d|%d" % [source_mesh.get_instance_id(), hash(symmetric), hash(asymmetric)]
	var cached := _facegen_mesh_cache.get(cache_key) as ArrayMesh
	if cached != null:
		return cached
	var built := FaceGenData.build_head_mesh(source_mesh, symmetric, asymmetric, facegen_data.egm, facegen_data.tri)
	if built != null:
		if _facegen_mesh_cache.size() >= FACEGEN_MESH_CACHE_LIMIT:
			_facegen_mesh_cache.clear()
		_facegen_mesh_cache[cache_key] = built
	return built

func ensure_facegen_data(head_model_path: String) -> Dictionary:
	var cache_key := head_model_path.to_lower().replace("\\", "/")
	if facegen_cache.has(cache_key):
		return facegen_cache[cache_key]
	var asset_stem := head_model_path.replace("\\", "/").get_basename()
	var egm_bytes: PackedByteArray = data_reader.read_asset("Meshes/" + asset_stem + ".egm")
	var tri_bytes: PackedByteArray = data_reader.read_asset("Meshes/" + asset_stem + ".tri")
	var egt_bytes: PackedByteArray = data_reader.read_asset("Meshes/" + asset_stem + ".egt")
	if egm_bytes.is_empty() or tri_bytes.is_empty():
		push_warning("Could not read FaceGen data for %s: %s" % [head_model_path, data_reader.get_error()])
		facegen_cache[cache_key] = {}
		return {}
	var egm := FaceGenData.decode_egm(egm_bytes)
	var tri := FaceGenData.decode_tri(tri_bytes)
	if egm.has("error") or tri.has("error"):
		push_warning("Could not decode FaceGen data for %s: EGM=%s TRI=%s" % [
			head_model_path, egm.get("error", "ok"), tri.get("error", "ok")
		])
		facegen_cache[cache_key] = {}
		return {}
	if int(egm.vertex_count) != int(tri.total_vertex_count):
		push_warning("FaceGen EGM/TRI vertex counts do not agree for %s" % head_model_path)
		facegen_cache[cache_key] = {}
		return {}
	for morph_value: Variant in tri.difference_morphs:
		var morph_name := str(morph_value.get("name", ""))
		if not facegen_expression_names.has(morph_name):
			facegen_expression_names.push_back(morph_name)
	for morph_value: Variant in tri.static_morphs:
		var morph_name := str(morph_value.get("name", ""))
		if not facegen_expression_names.has(morph_name):
			facegen_expression_names.push_back(morph_name)
	var decoded := {"egm": egm, "tri": tri, "egt_bytes": egt_bytes}
	facegen_cache[cache_key] = decoded
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

## How a piece of equipment is fixed to a skeleton: {bone, model_space, adjust_rotation} for add_actor_model, or
## {skip: true} when it cannot be placed. Headgear rides the head bone; a shield and a weapon ride the bone their NIF names
## (its Prn node); body armor is skinned and needs no bone.
func equipment_attachment(item_form_id: int, item_path: String, item_type: String, skeleton: Skeleton3D) -> Dictionary:
	var slots := int(data_reader.get_item_biped_slots(item_form_id))
	if item_type == "WEAP" or (slots & 0x2000) != 0:
		var bone := await _parent_reference_node(item_path)
		if not is_instance_valid(skeleton):
			return {"skip": true}
		if bone.is_empty():
			push_warning("Equipment model %s has no NIF Prn attachment node" % item_path)
			return {"skip": true}
		if skeleton.find_bone(bone) < 0:
			push_warning("Equipment model %s references missing skeleton bone %s" % [item_path, bone])
			return {"skip": true}
		return {"bone": bone}
	if (slots & 0x0003) != 0:
		return {
			"bone": "Bip01 Head",
			"adjust_rotation": true,
			"model_space": await _uses_model_space_head_attachment(item_path),
		}
	return {}

func _parent_reference_node(model_path: String) -> String:
	await assets.meshes_for_model(model_path)
	var normalized_path := model_path.to_lower().replace("\\", "/")
	var metadata: Dictionary = assets.nif_metadata_cache.get(normalized_path, {})
	for node_value: Variant in metadata.get("nodes", []):
		var node: Dictionary = node_value
		var parent_reference_node := str(node.get("parent_reference_node", "")).strip_edges()
		if not parent_reference_node.is_empty():
			return parent_reference_node
	return ""

func _uses_model_space_head_attachment(model_path: String) -> bool:
	var normalized_path := model_path.to_lower().replace("\\", "/")
	await assets.meshes_for_model(model_path)
	var metadata: Dictionary = assets.nif_metadata_cache.get(normalized_path, {})
	for node_value: Variant in metadata.get("nodes", []):
		var node: Dictionary = node_value
		if str(node.get("name", "")) == "Bip01 Head":
			# Some headgear NIFs keep their vertices at full character height;
			# local headgear is centered near the origin instead.
			return absf(float((node.get("translation", Vector3.ZERO) as Vector3).y)) > 50.0
	return false

func add_actor_model(
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
	var meshes: Array = await assets.meshes_for_model(model_path)
	var attachment: Node3D = avatar
	var added_instances: Array[MeshInstance3D] = []
	# The avatar is freed when its cell is left while the model loads.
	if not is_instance_valid(avatar) or not is_instance_valid(skeleton):
		return added_instances
	var actor_head_model_path := npc_head_model_path(npc_face_data) if not npc_face_data.is_empty() else ""
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
			facegen_data = ensure_facegen_data(model_path)
			if not facegen_data.is_empty():
				var face_mesh := build_facegen_mesh(
					source_mesh,
					npc_face_data.get("face_symmetric", PackedFloat32Array()),
					npc_face_data.get("face_asymmetric", PackedFloat32Array()),
					facegen_data
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
		var material := await assets.material_for_texture(
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
			instance.skin = skin_for_mesh(bone_names, skeleton)
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
	if facegen_texture_cache.has(cache_key):
		face_texture = facegen_texture_cache[cache_key] as Texture2D
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
		facegen_texture_cache[cache_key] = face_texture
	var material := base_material.duplicate() as StandardMaterial3D
	material.albedo_texture = face_texture
	return material

func _normalize_texture_asset_path(texture_path: String) -> String:
	var normalized := texture_path.strip_edges().replace("\\", "/")
	if normalized.to_lower().begins_with("characters/"):
		return "Textures/" + normalized
	return normalized

static func build_skeleton(node_data: Array) -> Skeleton3D:
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
			skeleton.set_bone_rest(bone_index, godot_node_rest(node))
			bone_indices[bone_name] = bone_index
			pending.erase(node_value)
			added_this_pass = true
		if not added_this_pass:
			push_warning("Could not resolve %d original skeleton node parents" % pending.size())
			break
	skeleton.reset_bone_poses()
	return skeleton

static func godot_node_rest(node: Dictionary) -> Transform3D:
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

static func skin_for_mesh(bone_names: Array, skeleton: Skeleton3D) -> Skin:
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
