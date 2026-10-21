extends RefCounted
## Stores generated Godot resources in the ignored project cache.

const CONVERTER_VERSION := "openob-resource-v3"
const CACHE_ROOT := "res://.godot/openob/cache/"

static func key_for(source_bytes: PackedByteArray, resource_kind: String) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(CONVERTER_VERSION.to_utf8_buffer())
	hashing.update(resource_kind.to_utf8_buffer())
	hashing.update(source_bytes)
	return hashing.finish().hex_encode()

static func load_or_build(source_bytes: PackedByteArray, resource_kind: String, builder: Callable) -> Resource:
	var key := key_for(source_bytes, resource_kind)
	var cache_path := CACHE_ROOT + key + ".res"
	if ResourceLoader.exists(cache_path):
		var cached := ResourceLoader.load(cache_path)
		if cached != null:
			return cached

	# Call from the main thread: builders create Godot resources and nodes.
	var built: Resource = builder.call()
	if built == null:
		return null
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_ROOT))
	var save_error := ResourceSaver.save(built, cache_path)
	if save_error != OK:
		push_warning("Could not write derived resource cache: %s" % error_string(save_error))
	return built
