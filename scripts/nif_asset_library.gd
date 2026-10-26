extends RefCounted
## Reads NIF models and textures from the game data and caches what is built from them: meshes, metadata, materials,
## textures and collision shapes. The native reader holds one asset at a time, so callers queue in meshes_for_model.

const DerivedResourceCache := preload("res://scripts/derived_resource_cache.gd")
const UNSUPPORTED_PARTICLE_MODEL_FILENAMES := [
	"fxdustcloudfaint01.nif",
	"fxdustcloud01.nif",
	"dustcloudhorizontal01.nif",
	"fxlightbeamdust01.nif",
]
const TEXTURE_FALLBACKS := {
	"textures/characters/imperial/male/earmale.dds": "textures/characters/imperial/earshuman.dds",
	"textures/characters/imperial/female/ear.dds": "textures/characters/imperial/earshuman.dds",
	"textures/characters/hairf01.dds": "textures/characters/hair/short.dds",
	"textures/characters/hairbrownm01.dds": "textures/characters/hair/short.dds",
}

## Native OblivionData reader; assigned by the owner once it exists.
var data_reader: Object
## Used for the frame waits of the reader queue.
var host: Node
## Returned for an empty texture path.
var cell_material: StandardMaterial3D
var model_cache: Dictionary = {}
var physics_mesh_cache: Dictionary = {}
var nif_metadata_cache: Dictionary = {}
var collision_cache: Dictionary = {}
var material_cache: Dictionary = {}
var texture_cache: Dictionary = {}

func _init(owner_node: Node) -> void:
	host = owner_node

var _nif_reader_busy := false

## Reads one NIF through the native reader. Only called while _nif_reader_busy is held by the caller.
func read_nif_asset(model_path: String) -> Dictionary:
	var attempts := 0
	while not data_reader.request_nif_meshes(model_path):
		attempts += 1
		if attempts > 600 or data_reader == null:
			return {"requested": false}
		await host.get_tree().process_frame
	while data_reader.is_asset_loading():
		await host.get_tree().process_frame
	var parse_error := str(data_reader.get_asset_error())
	if not parse_error.is_empty():
		return {"requested": true, "error": parse_error}
	return {"requested": true, "error": "", "result": data_reader.take_nif_meshes()}

func meshes_for_model(model_path: String) -> Array:
	var key := model_path.to_lower().replace("\\", "/")
	if model_cache.has(key):
		return model_cache[key]
	# These original particle effect NIFs are not static meshes and the reader cannot decode them.
	if key.get_file() in UNSUPPORTED_PARTICLE_MODEL_FILENAMES:
		model_cache[key] = []
		return []
	if data_reader == null or key.is_empty():
		return []
	# The native reader holds one asset at a time. Callers queue here, in order of arrival, so no request is dropped and
	# a finished result is always taken by the coroutine that asked for it.
	while _nif_reader_busy:
		await host.get_tree().process_frame
		if model_cache.has(key):
			return model_cache[key]
	_nif_reader_busy = true
	var read_result: Dictionary = await read_nif_asset(model_path)
	_nif_reader_busy = false
	if not bool(read_result.get("requested", false)):
		# The reader never accepted the request (game data still loading): nothing is cached, so a later call retries.
		return []
	var parse_error := str(read_result.get("error", ""))
	if not parse_error.is_empty():
		push_warning("Could not parse NIF %s: %s" % [model_path, parse_error])
		model_cache[key] = []
		return []

	var result: Dictionary = read_result.get("result", {})
	var source_bytes: PackedByteArray = result.get("source_bytes", PackedByteArray())
	var physics_bodies: Array = result.get("physics_bodies", [])
	var metadata := {
		"nodes": result.get("nodes", []),
		"animations": result.get("animations", []),
		"collision_enabled": bool(result.get("collision_enabled", false)),
		"physics_bodies": physics_bodies,
		"physics_constraints": result.get("physics_constraints", []),
	}
	if not physics_bodies.is_empty():
		metadata["source_bytes"] = source_bytes
	nif_metadata_cache[key] = metadata
	var raw_meshes: Array = result.get("meshes", [])
	# The NIF is hashed once; each mesh index derives its cache key from the digest.
	var source_digest := DerivedResourceCache.digest_of(source_bytes) if not raw_meshes.is_empty() else ""
	var godot_meshes: Array[Dictionary] = []
	for index in range(raw_meshes.size()):
		var mesh_data: Dictionary = raw_meshes[index]
		var builder := Callable(self, "build_godot_mesh").bind(mesh_data)
		var resource := DerivedResourceCache.load_or_build_digest(
			source_digest, "nif-arraymesh-normal-orientation-v2-%d" % index, builder
		) as ArrayMesh
		if resource != null:
			godot_meshes.push_back({
				"mesh": resource,
				"mesh_name": str(mesh_data.get("name", "")),
				"parent_node_name": str(mesh_data.get("parent_node_name", "")),
				"editor_marker": bool(mesh_data.get("editor_marker", false)),
				"parent_local_vertices": mesh_data.get("parent_local_vertices", PackedVector3Array()),
				"parent_local_normals": mesh_data.get("parent_local_normals", PackedVector3Array()),
				"uvs": mesh_data.get("uvs", PackedVector2Array()),
				"indices": mesh_data.get("indices", PackedInt32Array()),
				"bone_indices": mesh_data.get("bone_indices", PackedInt32Array()),
				"bone_weights": mesh_data.get("bone_weights", PackedFloat32Array()),
				"diffuse_texture_path": str(mesh_data.get("diffuse_texture_path", "")),
				"alpha_blend": bool(mesh_data.get("alpha_blend", false)),
				"alpha_test": bool(mesh_data.get("alpha_test", false)),
				"alpha_threshold": int(mesh_data.get("alpha_threshold", 128)),
				"bone_names": mesh_data.get("bone_names", []),
			})
	model_cache[key] = godot_meshes
	return godot_meshes

func physics_mesh_for_entry(model_path: String, mesh_index: int, mesh_entry: Dictionary) -> ArrayMesh:
	var model_key := model_path.to_lower().replace("\\", "/")
	var cache_key := "%s|%d" % [model_key, mesh_index]
	if physics_mesh_cache.has(cache_key):
		return physics_mesh_cache[cache_key] as ArrayMesh
	var metadata: Dictionary = nif_metadata_cache.get(model_key, {})
	var source_bytes: PackedByteArray = metadata.get("source_bytes", PackedByteArray())
	var local_data := {
		"vertices": mesh_entry.get("parent_local_vertices", PackedVector3Array()),
		"normals": mesh_entry.get("parent_local_normals", PackedVector3Array()),
		"uvs": mesh_entry.get("uvs", PackedVector2Array()),
		"indices": mesh_entry.get("indices", PackedInt32Array()),
		"bone_indices": mesh_entry.get("bone_indices", PackedInt32Array()),
		"bone_weights": mesh_entry.get("bone_weights", PackedFloat32Array()),
	}
	var resource: ArrayMesh = null
	if not source_bytes.is_empty():
		var builder := Callable(self, "build_godot_mesh").bind(local_data)
		if not metadata.has("source_digest"):
			metadata["source_digest"] = DerivedResourceCache.digest_of(source_bytes)
		resource = DerivedResourceCache.load_or_build_digest(
			str(metadata["source_digest"]), "nif-havok-node-local-v1-%d" % mesh_index, builder
		) as ArrayMesh
	if resource != null:
		physics_mesh_cache[cache_key] = resource
	return resource

func ensure_collision_shape(model_path: String) -> void:
	var key := model_path.to_lower().replace("\\", "/")
	var collision_key := key
	if collision_cache.has(collision_key):
		return
	if not bool(nif_metadata_cache.get(key, {}).get("collision_enabled", false)):
		return
	var collision_faces := PackedVector3Array()
	for mesh_entry: Dictionary in model_cache.get(key, []):
		if bool(mesh_entry.get("editor_marker", false)):
			continue
		var shape_name := str(mesh_entry.get("mesh_name", "")).to_lower()
		# Not "sky" alone: the Skylite wall pieces of the prison are floors and walls with a light shaft above them.
		if shape_name.contains("skydome") or shape_name.contains("skybox") or shape_name.contains("lightbeam") or shape_name.contains("dust"):
			continue
		var mesh := mesh_entry.get("mesh") as ArrayMesh
		if mesh != null:
			collision_faces.append_array(mesh.get_faces())
	var built_shape := build_concave_shape(collision_faces)
	# A model that is not loaded yet, or that produced no faces, is not cached: it is retried once the meshes exist.
	if built_shape != null:
		collision_cache[collision_key] = built_shape

func collision_shape_for_model(model_key: String) -> Shape3D:
	ensure_collision_shape(model_key)
	return collision_cache.get(model_key) as Shape3D

static func build_concave_shape(faces: PackedVector3Array) -> ConcavePolygonShape3D:
	if faces.size() < 3 or faces.size() % 3 != 0:
		return null
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	return shape

func material_for_texture(
	texture_path: String,
	alpha_blend := false,
	alpha_test := false,
	alpha_threshold := 128,
	billboard := false
) -> StandardMaterial3D:
	var normalized_path := texture_path.strip_edges().replace("\\", "/")
	if normalized_path.is_empty():
		return cell_material
	var alpha_mode := "blend" if alpha_blend else "scissor" if alpha_test else "opaque"
	var key := "%s|%s|%d|%s" % [normalized_path.to_lower(), alpha_mode, alpha_threshold, "billboard" if billboard else "fixed"]
	if material_cache.has(key):
		return material_cache[key]

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
	var texture := await texture_for_path(normalized_path)
	if texture != null:
		material.albedo_texture = texture
	else:
		material.albedo_color = Color(0.62, 0.58, 0.5)
	material_cache[key] = material
	return material

func texture_for_path(texture_path: String) -> Texture2D:
	var key := texture_path.to_lower()
	if texture_cache.has(key):
		return texture_cache[key]
	if data_reader == null:
		return null

	var source_bytes: PackedByteArray = data_reader.read_asset(texture_path)
	if source_bytes.is_empty():
		var fallback_path := str(TEXTURE_FALLBACKS.get(key, ""))
		if not fallback_path.is_empty():
			source_bytes = data_reader.read_asset(fallback_path)
	if source_bytes.is_empty():
		push_warning("Could not read texture %s" % texture_path)
		texture_cache[key] = null
		return null
	var kind := "oblivion-texture-%s" % texture_path.get_extension().to_lower()
	var builder := Callable(self, "build_godot_texture").bind(source_bytes, texture_path)
	var resource := DerivedResourceCache.load_or_build(source_bytes, kind, builder) as Texture2D
	texture_cache[key] = resource
	return resource

func build_godot_texture(source_bytes: PackedByteArray, texture_path: String) -> Texture2D:
	var image := Image.new()
	if texture_path.get_extension().to_lower() == "dds":
		image = decode_dds_image(source_bytes)
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

func decode_dds_image(source_bytes: PackedByteArray) -> Image:
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

func build_godot_mesh(mesh_data: Dictionary) -> ArrayMesh:
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
