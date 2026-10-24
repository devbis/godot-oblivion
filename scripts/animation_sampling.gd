extends RefCounted
## Samples the packed NIF transform keys that the native reader returns for a KF track. Vector keys are
## time,x,y,z; quaternion keys time,x,y,z,w; scalar keys time,value. Times before the first key hold the first value.

static func vector(keys: PackedFloat32Array, stride: int, time: float) -> Vector3:
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

static func quaternion(keys: PackedFloat32Array, time: float) -> Quaternion:
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

static func scalar(keys: PackedFloat32Array, time: float) -> float:
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
