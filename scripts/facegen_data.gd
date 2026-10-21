extends RefCounted
## Bounded readers for the FaceGen EGM and TRI geometry data shipped with Oblivion.

static func decode_egm(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 64 or bytes.slice(0, 8).get_string_from_ascii() != "FREGM002":
		return {"error": "invalid EGM header"}
	var vertex_count := int(bytes.decode_u32(8))
	var symmetric_count := int(bytes.decode_u32(12))
	var asymmetric_count := int(bytes.decode_u32(16))
	if vertex_count <= 0 or vertex_count > 100000 or symmetric_count > 256 or asymmetric_count > 256:
		return {"error": "invalid EGM dimensions"}
	var offset := 64
	var symmetric_modes: Array[PackedVector3Array] = []
	var asymmetric_modes: Array[PackedVector3Array] = []
	for mode_index in range(symmetric_count + asymmetric_count):
		if not _has_bytes(bytes, offset, 4 + vertex_count * 6):
			return {"error": "truncated EGM mode %d" % mode_index}
		var scale := bytes.decode_float(offset)
		offset += 4
		var mode := PackedVector3Array()
		mode.resize(vertex_count)
		for vertex_index in range(vertex_count):
			var x := _signed_short(bytes, offset) * scale
			var y := _signed_short(bytes, offset + 2) * scale
			var z := _signed_short(bytes, offset + 4) * scale
			mode[vertex_index] = Vector3(x, z, -y)
			offset += 6
		if mode_index < symmetric_count:
			symmetric_modes.push_back(mode)
		else:
			asymmetric_modes.push_back(mode)
	if offset != bytes.size():
		return {"error": "EGM size does not match its header"}
	return {
		"vertex_count": vertex_count,
		"symmetric_modes": symmetric_modes,
		"asymmetric_modes": asymmetric_modes,
	}

static func decode_tri(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 64 or bytes.slice(0, 8).get_string_from_ascii() != "FRTRI003":
		return {"error": "invalid TRI header"}
	var vertex_count := int(bytes.decode_u32(8))
	var triangle_count := int(bytes.decode_u32(12))
	var quad_count := int(bytes.decode_u32(16))
	var vertex_label_count := int(bytes.decode_u32(20))
	var surface_label_count := int(bytes.decode_u32(24))
	var texture_count := int(bytes.decode_u32(28))
	var extension_flags := int(bytes.decode_u32(32))
	var difference_morph_count := int(bytes.decode_u32(36))
	var static_morph_count := int(bytes.decode_u32(40))
	var extra_vertex_count := int(bytes.decode_u32(44))
	var total_vertex_count := vertex_count + extra_vertex_count
	if vertex_count <= 0 or vertex_count > 100000 or total_vertex_count > 200000:
		return {"error": "invalid TRI vertex count"}
	if difference_morph_count > 512 or static_morph_count > 512:
		return {"error": "invalid TRI morph count"}
	var offset := 64
	if not _has_bytes(bytes, offset, total_vertex_count * 12 + triangle_count * 12 + quad_count * 16):
		return {"error": "truncated TRI geometry"}
	var tri_vertices := PackedVector3Array()
	tri_vertices.resize(total_vertex_count)
	for vertex_index in range(total_vertex_count):
		var x := bytes.decode_float(offset)
		var y := bytes.decode_float(offset + 4)
		var z := bytes.decode_float(offset + 8)
		tri_vertices[vertex_index] = Vector3(x, z, -y)
		offset += 12
	offset += triangle_count * 12 + quad_count * 16
	for _label_index in range(vertex_label_count):
		var next_offset := _skip_label(bytes, offset, true)
		if next_offset < 0:
			return {"error": "truncated TRI vertex label"}
		offset = next_offset
	for _label_index in range(surface_label_count):
		var next_offset := _skip_label(bytes, offset, false)
		if next_offset < 0:
			return {"error": "truncated TRI surface label"}
		offset = next_offset
	if (extension_flags & 1) != 0:
		var texture_bytes := vertex_count * 8 if texture_count == 0 else texture_count * 8 + triangle_count * 12 + quad_count * 16
		if not _has_bytes(bytes, offset, texture_bytes):
			return {"error": "truncated TRI texture coordinates"}
		offset += texture_bytes
	var difference_morphs: Array[Dictionary] = []
	for _morph_index in range(difference_morph_count):
		var label := _read_morph_label(bytes, offset)
		if label.is_empty():
			return {"error": "truncated TRI difference-morph label"}
		var name: String = label.value
		offset = int(label.offset)
		if not _has_bytes(bytes, offset, 4 + vertex_count * 6):
			return {"error": "truncated TRI difference morph %s" % name}
		var scale := bytes.decode_float(offset)
		offset += 4
		var deltas := PackedVector3Array()
		deltas.resize(vertex_count)
		for vertex_index in range(vertex_count):
			var x := _signed_short(bytes, offset) * scale
			var y := _signed_short(bytes, offset + 2) * scale
			var z := _signed_short(bytes, offset + 4) * scale
			deltas[vertex_index] = Vector3(x, z, -y)
			offset += 6
		difference_morphs.push_back({"name": name, "deltas": deltas})
	var static_morphs: Array[Dictionary] = []
	var target_start := vertex_count
	for _morph_index in range(static_morph_count):
		var label := _read_morph_label(bytes, offset)
		if label.is_empty():
			return {"error": "truncated TRI static-morph label"}
		var name: String = label.value
		offset = int(label.offset)
		if not _has_bytes(bytes, offset, 4):
			return {"error": "truncated TRI static-morph count"}
		var affected_count := int(bytes.decode_u32(offset))
		offset += 4
		if affected_count < 0 or affected_count > vertex_count or not _has_bytes(bytes, offset, affected_count * 4):
			return {"error": "invalid TRI static morph %s" % name}
		var indices := PackedInt32Array()
		indices.resize(affected_count)
		for affected_index in range(affected_count):
			var vertex_index := int(bytes.decode_u32(offset))
			if vertex_index >= vertex_count:
				return {"error": "TRI static morph index is outside the base mesh"}
			indices[affected_index] = vertex_index
			offset += 4
		static_morphs.push_back({"name": name, "indices": indices, "target_start": target_start})
		target_start += affected_count
	if target_start != total_vertex_count or offset != bytes.size():
		return {"error": "TRI static morph vertices or file size do not match the header"}
	return {
		"vertex_count": vertex_count,
		"total_vertex_count": total_vertex_count,
		"vertices": tri_vertices,
		"difference_morphs": difference_morphs,
		"static_morphs": static_morphs,
	}

static func build_head_mesh(
	source_mesh: ArrayMesh,
	symmetric_coefficients: PackedFloat32Array,
	asymmetric_coefficients: PackedFloat32Array,
	egm: Dictionary,
	tri: Dictionary
) -> ArrayMesh:
	if source_mesh.get_surface_count() != 1:
		return null
	var arrays := source_mesh.surface_get_arrays(0)
	var base_vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var vertex_count := base_vertices.size()
	if vertex_count != int(tri.get("vertex_count", -1)):
		return null
	var symmetric_modes: Array = egm.get("symmetric_modes", [])
	var asymmetric_modes: Array = egm.get("asymmetric_modes", [])
	if symmetric_coefficients.size() != symmetric_modes.size() or asymmetric_coefficients.size() != asymmetric_modes.size():
		return null
	var morphed_vertices := base_vertices.duplicate()
	_apply_modes(morphed_vertices, symmetric_modes, symmetric_coefficients, vertex_count)
	_apply_modes(morphed_vertices, asymmetric_modes, asymmetric_coefficients, vertex_count)
	var base_normals := _compute_normals(morphed_vertices, indices)
	arrays[Mesh.ARRAY_VERTEX] = morphed_vertices
	if arrays[Mesh.ARRAY_NORMAL] != null:
		arrays[Mesh.ARRAY_NORMAL] = base_normals
	var blend_shape_names: Array[String] = []
	var blend_shape_arrays: Array[Array] = []
	var morph_bounds := AABB(morphed_vertices[0], Vector3.ZERO)
	for vertex in morphed_vertices:
		morph_bounds = morph_bounds.expand(vertex)
	for morph_value: Variant in tri.get("difference_morphs", []):
		var morph: Dictionary = morph_value
		var deltas: PackedVector3Array = morph.get("deltas", PackedVector3Array())
		if deltas.size() != vertex_count:
			return null
		var target_vertices := morphed_vertices.duplicate()
		for vertex_index in range(vertex_count):
			target_vertices[vertex_index] += deltas[vertex_index]
			morph_bounds = morph_bounds.expand(target_vertices[vertex_index])
		var shape_arrays: Array = _relative_shape_arrays(deltas, target_vertices, base_normals, indices)
		blend_shape_names.push_back(str(morph.get("name", "")))
		blend_shape_arrays.push_back(shape_arrays)
	var tri_vertices: PackedVector3Array = tri.get("vertices", PackedVector3Array())
	var target_vertex_count := int(tri.get("total_vertex_count", 0))
	if tri_vertices.size() != target_vertex_count:
		return null
	for morph_value: Variant in tri.get("static_morphs", []):
		var morph: Dictionary = morph_value
		var affected: PackedInt32Array = morph.get("indices", PackedInt32Array())
		var target_start := int(morph.get("target_start", -1))
		if target_start < vertex_count or target_start + affected.size() > target_vertex_count:
			return null
		var deltas := PackedVector3Array()
		deltas.resize(vertex_count)
		for affected_offset in range(affected.size()):
			var vertex_index := affected[affected_offset]
			var target_index := target_start + affected_offset
			var delta := tri_vertices[target_index] - tri_vertices[vertex_index]
			delta += _morph_delta_at(symmetric_modes, symmetric_coefficients, target_index)
			delta -= _morph_delta_at(symmetric_modes, symmetric_coefficients, vertex_index)
			delta += _morph_delta_at(asymmetric_modes, asymmetric_coefficients, target_index)
			delta -= _morph_delta_at(asymmetric_modes, asymmetric_coefficients, vertex_index)
			deltas[vertex_index] = delta
		var target_vertices := morphed_vertices.duplicate()
		for affected_offset in range(affected.size()):
			var vertex_index := affected[affected_offset]
			target_vertices[vertex_index] += deltas[vertex_index]
			morph_bounds = morph_bounds.expand(target_vertices[vertex_index])
		var shape_arrays: Array = _relative_shape_arrays(deltas, target_vertices, base_normals, indices)
		blend_shape_names.push_back(str(morph.get("name", "")))
		blend_shape_arrays.push_back(shape_arrays)
	var result := ArrayMesh.new()
	result.blend_shape_mode = Mesh.BLEND_SHAPE_MODE_RELATIVE
	for shape_name in blend_shape_names:
		result.add_blend_shape(StringName(shape_name))
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, blend_shape_arrays)
	result.custom_aabb = morph_bounds.grow(0.02)
	return result

static func _apply_modes(
	vertices: PackedVector3Array,
	modes: Array,
	coefficients: PackedFloat32Array,
	vertex_count: int
) -> void:
	for mode_index in range(modes.size()):
		var coefficient := coefficients[mode_index]
		if absf(coefficient) < 0.000001:
			continue
		var mode: PackedVector3Array = modes[mode_index]
		for vertex_index in range(vertex_count):
			vertices[vertex_index] += mode[vertex_index] * coefficient

static func _morph_delta_at(modes: Array, coefficients: PackedFloat32Array, vertex_index: int) -> Vector3:
	var result := Vector3.ZERO
	for mode_index in range(modes.size()):
		var coefficient := coefficients[mode_index]
		if absf(coefficient) >= 0.000001:
			var mode: PackedVector3Array = modes[mode_index]
			result += mode[vertex_index] * coefficient
	return result

static func _relative_shape_arrays(
	deltas: PackedVector3Array,
	target_vertices: PackedVector3Array,
	base_normals: PackedVector3Array,
	indices: PackedInt32Array
) -> Array:
	var shape_arrays: Array = []
	shape_arrays.resize(Mesh.ARRAY_MAX)
	shape_arrays[Mesh.ARRAY_VERTEX] = deltas
	var target_normals := _compute_normals(target_vertices, indices)
	var normal_deltas := PackedVector3Array()
	normal_deltas.resize(base_normals.size())
	for vertex_index in range(base_normals.size()):
		normal_deltas[vertex_index] = target_normals[vertex_index] - base_normals[vertex_index]
	shape_arrays[Mesh.ARRAY_NORMAL] = normal_deltas
	return shape_arrays

static func _compute_normals(vertices: PackedVector3Array, indices: PackedInt32Array) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(vertices.size())
	for triangle_offset in range(0, indices.size() - 2, 3):
		var a := indices[triangle_offset]
		var b := indices[triangle_offset + 1]
		var c := indices[triangle_offset + 2]
		if a >= vertices.size() or b >= vertices.size() or c >= vertices.size():
			continue
		var normal := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
		normals[a] += normal
		normals[b] += normal
		normals[c] += normal
	for vertex_index in range(normals.size()):
		# Match the reversed shading-normal convention used by the NIF converter;
		# FaceGen rebuilds these normals after applying each facial morph.
		normals[vertex_index] = -normals[vertex_index].normalized() if normals[vertex_index].length_squared() > 0.000001 else Vector3.DOWN
	return normals

static func _has_bytes(bytes: PackedByteArray, offset: int, count: int) -> bool:
	return offset >= 0 and count >= 0 and offset <= bytes.size() and count <= bytes.size() - offset

static func _signed_short(bytes: PackedByteArray, offset: int) -> int:
	var value := int(bytes.decode_u16(offset))
	return value - 65536 if value >= 32768 else value

static func _skip_label(bytes: PackedByteArray, offset: int, has_vertex_index: bool) -> int:
	var prefix := 4 if has_vertex_index else 16
	if not _has_bytes(bytes, offset, prefix + 4):
		return -1
	var length_offset := offset + prefix
	var length := int(bytes.decode_u32(length_offset))
	var next_offset := length_offset + 4 + length
	return next_offset if _has_bytes(bytes, length_offset + 4, length) else -1

static func _read_morph_label(bytes: PackedByteArray, offset: int) -> Dictionary:
	if not _has_bytes(bytes, offset, 4):
		return {}
	var length := int(bytes.decode_u32(offset))
	if length <= 0 or not _has_bytes(bytes, offset + 4, length):
		return {}
	var name_bytes := bytes.slice(offset + 4, offset + 4 + length)
	var null_index := name_bytes.find(0)
	if null_index >= 0:
		name_bytes.resize(null_index)
	var name := name_bytes.get_string_from_utf8()
	return {"value": name, "offset": offset + 4 + length}
