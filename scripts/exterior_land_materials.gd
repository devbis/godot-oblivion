extends RefCounted

const NifAssetLibrary := preload("res://scripts/nif_asset_library.gd")
const LAND_SHADER := preload("res://scripts/exterior_land.gdshader")
const LOD_PREFIX := "textures/landscapelod/generated/"
const LOD_CELLS := 32
const DETAIL_TEXTURE_SIZE := 256
const MAX_TEXTURES := 256
const MAX_OVERLAYS := 8
const DEFAULT_TEXTURE := "textures/landscape/terrainhddirt01.dds"
const LOAD_SLICE_USEC := 4000
const MASK_TILE := Vector2i(34, 68)
const INDEX_TILE := Vector2i(3, 4)

var _lod_paths: Dictionary = {}
var _lod_index_ready := false
var _detail_images: Dictionary = {}


func lod_path(land: Dictionary, worldspace: int, assets: NifAssetLibrary) -> String:
	if not _lod_index_ready:
		for path: String in assets.data_reader.list_assets(LOD_PREFIX):
			_lod_paths[path.to_lower().replace("\\", "/")] = true
		_lod_index_ready = true
	var chunk := _lod_chunk(land)
	var path := LOD_PREFIX + ("%d.%02d.%02d.%d.dds" % [worldspace, chunk.x, chunk.y, LOD_CELLS])
	return path if _lod_paths.has(path) else ""


func _lod_chunk(land: Dictionary) -> Vector2i:
	return Vector2i(
		floori(float(land.get("grid_x", 0)) / LOD_CELLS),
		floori(float(land.get("grid_y", 0)) / LOD_CELLS)
	) * LOD_CELLS


func _grid(land: Dictionary) -> Vector2i:
	return Vector2i(int(land.get("grid_x", 0)), int(land.get("grid_y", 0)))


func prepare_region(
	land_cells: Array, assets: NifAssetLibrary, is_current: Callable, tree: SceneTree
) -> Dictionary:
	var paths: Dictionary = {DEFAULT_TEXTURE: true}
	var min_grid := _grid(land_cells[0])
	var max_grid := min_grid
	for land: Dictionary in land_cells:
		var point := _grid(land)
		min_grid = min_grid.min(point)
		max_grid = max_grid.max(point)
		var layers: Array = land.get("surface_layers", [])
		paths[_base_path(land)] = true
		for layer: Dictionary in layers:
			var path := str(layer.get("texture_path", "")).to_lower()
			if not path.is_empty():
				paths[path] = true

	var images: Array[Image] = []
	var indices := {}
	var slice_started := Time.get_ticks_usec()
	for path: String in paths:
		if images.size() >= MAX_TEXTURES:
			break
		var image := _detail_image(path, assets)
		if image != null:
			indices[path] = images.size()
			images.push_back(image)
		if Time.get_ticks_usec() - slice_started >= LOAD_SLICE_USEC:
			await tree.process_frame
			if not is_current.call():
				return {}
			slice_started = Time.get_ticks_usec()
	if images.is_empty():
		return {"materials": {}}
	var textures := Texture2DArray.new()
	if textures.create_from_images(images) != OK:
		return {"materials": {}}

	var size := max_grid - min_grid + Vector2i.ONE
	var mask_size := size * MASK_TILE
	var index_size := size * INDEX_TILE
	var mask_bytes := PackedByteArray()
	mask_bytes.resize(mask_size.x * mask_size.y * 4)
	var index_bytes := PackedByteArray()
	index_bytes.resize(index_size.x * index_size.y * 4)
	for land: Dictionary in land_cells:
		var tile := _grid(land) - min_grid
		_write_cell(land, indices, mask_bytes, index_bytes, tile, mask_size.x, index_size.x)
		if Time.get_ticks_usec() - slice_started >= LOAD_SLICE_USEC:
			await tree.process_frame
			if not is_current.call():
				return {}
			slice_started = Time.get_ticks_usec()
	return {
		"textures": textures,
		"masks": ImageTexture.create_from_image(
			Image.create_from_data(mask_size.x, mask_size.y, false, Image.FORMAT_RGBA8, mask_bytes)
		),
		"indices": ImageTexture.create_from_image(
			Image.create_from_data(index_size.x, index_size.y, false, Image.FORMAT_RGBA8, index_bytes)
		),
		"grid_origin": min_grid,
		"materials": {},
	}


func _write_cell(
	land: Dictionary, indices: Dictionary, mask_bytes: PackedByteArray, index_bytes: PackedByteArray,
	tile: Vector2i, mask_stride: int, index_stride: int
) -> void:
	var fallback := int(indices.get(_base_path(land), indices.get(DEFAULT_TEXTURE, 0)))
	var layers: Array = land.get("surface_layers", [])
	for quadrant in range(4):
		var overlays: Array[Dictionary] = []
		var base_index := fallback
		for layer: Dictionary in layers:
			if int(layer.get("quadrant", -1)) != quadrant:
				continue
			var path := str(layer.get("texture_path", "")).to_lower()
			if not indices.has(path):
				continue
			if bool(layer.get("alpha_layer", false)):
				var alpha: PackedFloat32Array = layer.get("alpha", PackedFloat32Array())
				if alpha.size() == 17 * 17:
					overlays.push_back(layer)
			else:
				base_index = indices[path]
		overlays.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.layer) < int(b.layer))
		var count := mini(overlays.size(), MAX_OVERLAYS)
		# Each quadrant has three RGBA texels: count, base index and eight overlay indices.
		var offset := ((tile.y * INDEX_TILE.y + quadrant) * index_stride + tile.x * INDEX_TILE.x) * 4
		index_bytes[offset] = count
		index_bytes[offset + 1] = base_index
		var start_x := tile.x * MASK_TILE.x + (quadrant % 2) * 17
		var start_y := tile.y * MASK_TILE.y + (quadrant >> 1) * 17
		for slot in range(count):
			var layer := overlays[slot]
			index_bytes[offset + slot + 2] = indices[str(layer.texture_path).to_lower()]
			var alpha: PackedFloat32Array = layer.alpha
			# Four alpha channels per texel, with slots 4 to 7 in the lower half.
			var row := start_y + (34 if slot >= 4 else 0)
			for y in range(17):
				var pixel := ((row + y) * mask_stride + start_x) * 4 + slot % 4
				for x in range(17):
					mask_bytes[pixel + x * 4] = roundi(alpha[y * 17 + x] * 255.0)


func _detail_image(path: String, assets: NifAssetLibrary) -> Image:
	if _detail_images.has(path):
		return _detail_images[path]
	var bytes: PackedByteArray = assets.data_reader.read_asset(path)
	var image := assets.decode_dds_image(bytes)
	if image != null:
		if image.is_compressed() and image.decompress() != OK:
			image = null
		else:
			image.clear_mipmaps()
			image.convert(Image.FORMAT_RGBA8)
			if image.get_size() != Vector2i(DETAIL_TEXTURE_SIZE, DETAIL_TEXTURE_SIZE):
				image.resize(DETAIL_TEXTURE_SIZE, DETAIL_TEXTURE_SIZE, Image.INTERPOLATE_LANCZOS)
			image.generate_mipmaps()
	_detail_images[path] = image
	return image


func _base_path(land: Dictionary) -> String:
	var path := str(land.get("texture_path", "")).to_lower()
	return DEFAULT_TEXTURE if path.is_empty() else path


func region_material(
	land: Dictionary, path: String, cell_size: float, assets: NifAssetLibrary, region: Dictionary
) -> ShaderMaterial:
	var materials: Dictionary = region.get("materials", {})
	if materials.has(path):
		return materials[path]
	var lod: Texture2D = null
	if not path.is_empty():
		lod = await assets.texture_for_path(path)
	if not region.has("textures") and lod == null:
		return null
	var material := ShaderMaterial.new()
	material.shader = LAND_SHADER
	material.set_shader_parameter("cell_scale", 1.0 / cell_size)
	if lod != null:
		var chunk := _lod_chunk(land)
		material.set_shader_parameter("lod_albedo", lod)
		material.set_shader_parameter("lod_chunk", Vector2(chunk))
		material.set_shader_parameter("has_lod", true)
	if region.has("textures"):
		material.set_shader_parameter("has_detail", true)
		material.set_shader_parameter("detail_textures", region.textures)
		material.set_shader_parameter("layer_masks", region.masks)
		material.set_shader_parameter("layer_indices", region.indices)
		material.set_shader_parameter("grid_origin", region.grid_origin)
	materials[path] = material
	return material
