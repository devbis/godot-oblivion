extends RefCounted
## Bounded readers for Oblivion FaceGen EGM, TRI, and dialogue LIP data.

const LIP_FRAME_RATE := 30.0
const LIP_CURVES_PER_FRAME := 33
const LIP_PHONEME_CURVE_START := 6
const LIP_PHONEME_NAMES: Array[StringName] = [
	&"Aah", &"BigAah", &"BMP", &"ChJSh", &"DST", &"Eee", &"Eh", &"FV",
	&"I", &"K", &"N", &"Oh", &"OohQ", &"R", &"Th", &"W",
]
const FACE_EXPRESSION_MORPH_NAMES: Array[StringName] = [
	&"Happy", &"Anger", &"Surprise", &"Sad", &"Fear",
]
const EXPRESSION_NORMAL_MORPH_STRENGTH := 0.5
const LIP_MAX_FRAME_COUNT := 18000
const LIP_MAX_DECODED_BYTES := 18000 * LIP_CURVES_PER_FRAME * 4


## Decodes Oblivion's FaceFX LIP stream into its 33-float-per-frame curve grid.
## Legacy files put the zero-run encoded payload directly after the 20-byte
## header; some voice archives shift it by one byte. Character-generation LIPs
## start the curve grid at byte 16 and can omit its final all-zero run.
static func decode_lip(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 20 or int(bytes.decode_u32(0)) != 1:
		return {"error": "invalid LIP header"}
	var frame_count := int(bytes.decode_u16(12))
	if frame_count <= 0 or frame_count > LIP_MAX_FRAME_COUNT:
		return {"error": "invalid LIP frame count"}
	var expected_size := frame_count * LIP_CURVES_PER_FRAME * 4
	var payload_options: Array[Dictionary] = [
		{"offset": 20, "first_offset": 16},
		{"offset": 21, "first_offset": 17},
		{"offset": 16, "first_offset": -1, "curve_grid": true},
	]
	for option_value: Variant in payload_options:
		var option: Dictionary = option_value
		var payload_offset := int(option.offset)
		if payload_offset >= bytes.size():
			continue
		var first_frame := 0
		var first_offset := int(option.first_offset)
		if first_offset >= 0:
			first_frame = _signed_int32(bytes, first_offset)
			if first_frame < -120 or first_frame > 0:
				continue
		var curve_grid := bool(option.get("curve_grid", false))
		var decoded_bytes := _decode_lip_rle(bytes, payload_offset, expected_size, curve_grid)
		if decoded_bytes.is_empty():
			continue
		if curve_grid:
			# Character-generation LIPs store the first curve value at byte 16 and
			# omit the final all-zero run. Header u16@14 is that omitted byte count + 7.
			var omitted_tail_bytes := expected_size - decoded_bytes.size()
			if omitted_tail_bytes < 0 or omitted_tail_bytes % 4 != 0:
				continue
			if omitted_tail_bytes + 7 != int(bytes.decode_u16(14)):
				continue
			decoded_bytes.resize(expected_size)
		var curves := PackedFloat32Array()
		curves.resize(frame_count * LIP_CURVES_PER_FRAME)
		var values_valid := true
		for value_index in range(curves.size()):
			var value := decoded_bytes.decode_float(value_index * 4)
			if not (value >= -2.0 and value <= 2.0):
				values_valid = false
				break
			curves[value_index] = value
		if not values_valid:
			continue
		return {
			"frame_count": frame_count,
			"first_frame": first_frame,
			"frame_rate": LIP_FRAME_RATE,
			"curves": curves,
		}
	return {"error": "invalid LIP curve payload"}


## Samples the 16 FaceGen phoneme channels at audio time, interpolating adjacent frames.
static func sample_lip_visemes(lip: Dictionary, audio_time: float) -> PackedFloat32Array:
	var weights := PackedFloat32Array()
	weights.resize(LIP_PHONEME_NAMES.size())
	var frame_count := int(lip.get("frame_count", 0))
	var curves: PackedFloat32Array = lip.get("curves", PackedFloat32Array())
	if frame_count <= 0 or curves.size() != frame_count * LIP_CURVES_PER_FRAME:
		return weights
	var frame_rate := float(lip.get("frame_rate", LIP_FRAME_RATE))
	var first_frame := int(lip.get("first_frame", 0))
	var frame_position := maxf(audio_time, 0.0) * frame_rate - float(first_frame)
	frame_position = clampf(frame_position, 0.0, float(frame_count - 1))
	var frame_a := int(floor(frame_position))
	var frame_b := mini(frame_a + 1, frame_count - 1)
	var blend := frame_position - float(frame_a)
	for phoneme_index in range(LIP_PHONEME_NAMES.size()):
		var curve_index := LIP_PHONEME_CURVE_START + phoneme_index
		var value_a := curves[frame_a * LIP_CURVES_PER_FRAME + curve_index]
		var value_b := curves[frame_b * LIP_CURVES_PER_FRAME + curve_index]
		weights[phoneme_index] = clampf(lerpf(value_a, value_b, blend), 0.0, 1.0)
	return weights


static func _decode_lip_rle(
	bytes: PackedByteArray,
	offset: int,
	expected_size: int,
	allow_short := false
) -> PackedByteArray:
	var decoded := PackedByteArray()
	var input_offset := offset
	while input_offset < bytes.size():
		var value := int(bytes[input_offset])
		if value == 0:
			if not _has_bytes(bytes, input_offset, 3):
				return PackedByteArray()
			var run_length := int(bytes.decode_u16(input_offset + 1))
			if run_length <= 0 or decoded.size() + run_length > expected_size:
				return PackedByteArray()
			decoded.resize(decoded.size() + run_length)
			input_offset += 3
		else:
			if decoded.size() >= expected_size:
				return PackedByteArray()
			decoded.push_back(value)
			input_offset += 1
		if decoded.size() > LIP_MAX_DECODED_BYTES:
			return PackedByteArray()
	if decoded.size() == expected_size or (allow_short and decoded.size() < expected_size):
		return decoded
	return PackedByteArray()


static func _signed_int32(bytes: PackedByteArray, offset: int) -> int:
	var value := int(bytes.decode_u32(offset))
	return value - 0x100000000 if value >= 0x80000000 else value

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
	if vertex_count != int(tri.get("vertex_count", -1)) or int(egm.get("vertex_count", -1)) < vertex_count:
		return null
	var tri_vertices: PackedVector3Array = tri.get("vertices", PackedVector3Array())
	if tri_vertices.size() < vertex_count:
		return null
	# FaceGen stores some component morphs in the full head basis, while rigid parts such as teeth use a local NIF basis.
	var fitted_basis := _fit_basis_transform(base_vertices, tri_vertices, vertex_count)
	if fitted_basis.is_empty() or float(fitted_basis.get("max_residual", INF)) > 0.001:
		return null
	var basis_transform: Basis = fitted_basis.get("basis", Basis.IDENTITY)
	var symmetric_modes: Array = egm.get("symmetric_modes", [])
	var asymmetric_modes: Array = egm.get("asymmetric_modes", [])
	if symmetric_coefficients.size() != symmetric_modes.size() or asymmetric_coefficients.size() != asymmetric_modes.size():
		return null
	var morphed_vertices := base_vertices.duplicate()
	_apply_modes(morphed_vertices, symmetric_modes, symmetric_coefficients, basis_transform)
	_apply_modes(morphed_vertices, asymmetric_modes, asymmetric_coefficients, basis_transform)
	# Preserve the NIF's authored smooth normals. Rebuilding them from triangles splits
	# lighting at duplicated face vertices (for example, across UV seams), which shows
	# up as a hard half-face boundary once the mouth morphs move the geometry.
	var base_normals: PackedVector3Array
	if arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array and (arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).size() == vertex_count:
		base_normals = (arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).duplicate()
	else:
		base_normals = _compute_normals(morphed_vertices, indices)
	arrays[Mesh.ARRAY_VERTEX] = morphed_vertices
	if arrays[Mesh.ARRAY_NORMAL] != null:
		arrays[Mesh.ARRAY_NORMAL] = base_normals
	var blend_shape_names: Array[String] = []
	var blend_shape_arrays: Array[Array] = []
	var morph_bounds := AABB(morphed_vertices[0], Vector3.ZERO)
	var base_geometry_normals := _compute_normals(morphed_vertices, indices, morphed_vertices)
	for vertex in morphed_vertices:
		morph_bounds = morph_bounds.expand(vertex)
	for morph_value: Variant in tri.get("difference_morphs", []):
		var morph: Dictionary = morph_value
		var morph_name := StringName(str(morph.get("name", "")))
		var source_deltas: PackedVector3Array = morph.get("deltas", PackedVector3Array())
		if source_deltas.size() != vertex_count:
			return null
		var deltas := PackedVector3Array()
		deltas.resize(vertex_count)
		var target_vertices := morphed_vertices.duplicate()
		for vertex_index in range(vertex_count):
			deltas[vertex_index] = basis_transform * source_deltas[vertex_index]
			target_vertices[vertex_index] += deltas[vertex_index]
			morph_bounds = morph_bounds.expand(target_vertices[vertex_index])
		var shape_arrays: Array = _relative_shape_arrays(
			deltas, base_normals, base_geometry_normals, target_vertices, morphed_vertices, indices,
			FACE_EXPRESSION_MORPH_NAMES.has(morph_name)
		)
		blend_shape_names.push_back(str(morph_name))
		blend_shape_arrays.push_back(shape_arrays)
	var target_vertex_count := int(tri.get("total_vertex_count", 0))
	if tri_vertices.size() != target_vertex_count:
		return null
	for morph_value: Variant in tri.get("static_morphs", []):
		var morph: Dictionary = morph_value
		var morph_name := StringName(str(morph.get("name", "")))
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
			deltas[vertex_index] = basis_transform * delta
		var target_vertices := morphed_vertices.duplicate()
		for affected_offset in range(affected.size()):
			var vertex_index := affected[affected_offset]
			target_vertices[vertex_index] += deltas[vertex_index]
			morph_bounds = morph_bounds.expand(target_vertices[vertex_index])
		var shape_arrays: Array = _relative_shape_arrays(
			deltas, base_normals, base_geometry_normals, target_vertices, morphed_vertices, indices,
			FACE_EXPRESSION_MORPH_NAMES.has(morph_name)
		)
		blend_shape_names.push_back(str(morph_name))
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
	basis_transform: Basis
) -> void:
	for mode_index in range(modes.size()):
		var coefficient := coefficients[mode_index]
		if absf(coefficient) < 0.000001:
			continue
		var mode: PackedVector3Array = modes[mode_index]
		for vertex_index in range(vertices.size()):
			vertices[vertex_index] += basis_transform * mode[vertex_index] * coefficient

static func _fit_basis_transform(
	positions: PackedVector3Array,
	tri_vertices: PackedVector3Array,
	vertex_count: int
) -> Dictionary:
	if positions.size() != vertex_count or tri_vertices.size() < vertex_count or vertex_count < 4:
		return {}
	var normal: Array = []
	var rhs: Array = []
	for row in 4:
		normal.push_back([0.0, 0.0, 0.0, 0.0])
	for axis in 3:
		rhs.push_back([0.0, 0.0, 0.0, 0.0])
	for vertex_index in range(vertex_count):
		var source: Vector3 = tri_vertices[vertex_index]
		var target: Vector3 = positions[vertex_index]
		var basis_values: Array = [source.x, source.y, source.z, 1.0]
		var target_values: Array = [target.x, target.y, target.z]
		for row in 4:
			for column in 4:
				normal[row][column] += basis_values[row] * basis_values[column]
			for axis in 3:
				rhs[axis][row] += target_values[axis] * basis_values[row]
	var coefficients: Array = []
	for axis in 3:
		var augmented: Array = []
		for row in 4:
			var values: Array = [0.0, 0.0, 0.0, 0.0, 0.0]
			for column in 4:
				values[column] = normal[row][column]
			values[4] = rhs[axis][row]
			augmented.push_back(values)
		for column in 4:
			var pivot := column
			for row in range(column + 1, 4):
				if absf(float(augmented[row][column])) > absf(float(augmented[pivot][column])):
					pivot = row
			if absf(float(augmented[pivot][column])) < 0.0000000001:
				return {}
			if pivot != column:
				var swap: Array = augmented[pivot]
				augmented[pivot] = augmented[column]
				augmented[column] = swap
			var divisor := float(augmented[column][column])
			for index in range(column, 5):
				augmented[column][index] = float(augmented[column][index]) / divisor
			for row in 4:
				if row == column:
					continue
				var factor := float(augmented[row][column])
				for index in range(column, 5):
					augmented[row][index] = float(augmented[row][index]) - factor * float(augmented[column][index])
		var axis_coefficients: Array = []
		for row in 4:
			axis_coefficients.push_back(float(augmented[row][4]))
		coefficients.push_back(axis_coefficients)
	var transform := Basis(
		Vector3(coefficients[0][0], coefficients[1][0], coefficients[2][0]),
		Vector3(coefficients[0][1], coefficients[1][1], coefficients[2][1]),
		Vector3(coefficients[0][2], coefficients[1][2], coefficients[2][2])
	)
	var offset := Vector3(coefficients[0][3], coefficients[1][3], coefficients[2][3])
	var max_residual := 0.0
	for vertex_index in range(vertex_count):
		var fitted := transform * tri_vertices[vertex_index] + offset
		max_residual = maxf(max_residual, positions[vertex_index].distance_to(fitted))
	return {"basis": transform, "offset": offset, "max_residual": max_residual}

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
	base_normals: PackedVector3Array,
	base_geometry_normals: PackedVector3Array,
	target_vertices: PackedVector3Array,
	weld_vertices: PackedVector3Array,
	indices: PackedInt32Array,
	compute_morph_normal_delta: bool
) -> Array:
	var shape_arrays: Array = []
	shape_arrays.resize(Mesh.ARRAY_MAX)
	shape_arrays[Mesh.ARRAY_VERTEX] = deltas
	var normal_deltas := PackedVector3Array()
	normal_deltas.resize(base_normals.size())
	# Emotion shapes are applied one at a time and need normals that follow their
	# deformed geometry. Keep phoneme deltas at zero: overlapping LIP visemes have
	# independent weights and their isolated normal deltas can reverse one another.
	if compute_morph_normal_delta and base_geometry_normals.size() == base_normals.size():
		var target_geometry_normals := _compute_normals(target_vertices, indices, weld_vertices)
		if target_geometry_normals.size() == normal_deltas.size():
			for vertex_index in range(normal_deltas.size()):
				var base_geometry_normal := base_geometry_normals[vertex_index].normalized()
				var target_geometry_normal := target_geometry_normals[vertex_index].normalized()
				if base_geometry_normal.dot(target_geometry_normal) < 0.0:
					target_geometry_normal = -target_geometry_normal
				# Rotate the authored NIF normal by the local geometry change. Adding
				# raw triangle-normal deltas replaces its smooth shading with facets.
				var geometry_rotation := Quaternion(base_geometry_normal, target_geometry_normal)
				var normal_rotation := Quaternion.IDENTITY.slerp(
					geometry_rotation, EXPRESSION_NORMAL_MORPH_STRENGTH
				)
				var authored_normal := base_normals[vertex_index].normalized()
				var morphed_normal := (normal_rotation * authored_normal).normalized()
				normal_deltas[vertex_index] = morphed_normal - authored_normal
	shape_arrays[Mesh.ARRAY_NORMAL] = normal_deltas
	return shape_arrays


static func _compute_normals(
	vertices: PackedVector3Array,
	indices: PackedInt32Array,
	weld_positions: PackedVector3Array = PackedVector3Array()
) -> PackedVector3Array:
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
	# Merge coincident vertices before normalizing. FaceGen heads commonly duplicate
	# vertices at UV seams, but those seams should not become hard lighting edges.
	# When calculating a morph, weld by the undeformed positions so the seam stays
	# smooth even if its duplicate vertices move by slightly different amounts.
	var weld_vertices := weld_positions if weld_positions.size() == vertices.size() else vertices
	var smooth_groups: Dictionary = {}
	for vertex_index in range(vertices.size()):
		var vertex := weld_vertices[vertex_index]
		var key := Vector3i(
			roundi(vertex.x * 10000.0), roundi(vertex.y * 10000.0), roundi(vertex.z * 10000.0)
		)
		var group_normal: Vector3 = smooth_groups.get(key, Vector3.ZERO)
		smooth_groups[key] = group_normal + normals[vertex_index]
	for vertex_index in range(normals.size()):
		# Match the reversed shading-normal convention used by the NIF converter.
		var vertex := weld_vertices[vertex_index]
		var key := Vector3i(
			roundi(vertex.x * 10000.0), roundi(vertex.y * 10000.0), roundi(vertex.z * 10000.0)
		)
		var normal: Vector3 = smooth_groups[key]
		normals[vertex_index] = -normal.normalized() if normal.length_squared() > 0.000001 else Vector3.DOWN
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
