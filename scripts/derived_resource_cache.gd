extends RefCounted
## Stores generated Godot resources in a cache directory: the ignored project cache when the game runs from the editor,
## and the user data directory in an exported build (res:// is read-only there).

const CONVERTER_VERSION := "openob-resource-v5"
const EDITOR_CACHE_ROOT := "res://.godot/openob/cache/"
const USER_CACHE_ROOT := "user://openob/cache/"
## Files beyond this total size are removed, oldest first, when the cache is first used in a run.
const CACHE_SIZE_LIMIT_BYTES := 2 * 1024 * 1024 * 1024

static var _root := ""
static var _warned_write := false

## Directory the cache lives in, ending with a slash (res:// or user:// path).
static func cache_root() -> String:
	if _root.is_empty():
		_root = EDITOR_CACHE_ROOT if OS.has_feature("editor") else USER_CACHE_ROOT
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_root))
		_prune(_root)
	return _root

## The same directory as an absolute file system path, for the native side.
static func cache_dir() -> String:
	return ProjectSettings.globalize_path(cache_root())

## Hash of a source file. Hash it once per source and reuse the digest for each resource built from it.
static func digest_of(source_bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(source_bytes)
	return hashing.finish().hex_encode()

static func key_for_digest(source_digest: String, resource_kind: String) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(resource_kind.to_utf8_buffer())
	hashing.update(source_digest.to_utf8_buffer())
	return hashing.finish().hex_encode()

static func key_for(source_bytes: PackedByteArray, resource_kind: String) -> String:
	return key_for_digest(digest_of(source_bytes), resource_kind)

static func load_or_build(source_bytes: PackedByteArray, resource_kind: String, builder: Callable) -> Resource:
	return load_or_build_digest(digest_of(source_bytes), resource_kind, builder)

static func load_or_build_digest(source_digest: String, resource_kind: String, builder: Callable) -> Resource:
	var cache_path := cache_root() + CONVERTER_VERSION + "-" + key_for_digest(source_digest, resource_kind) + ".res"
	if ResourceLoader.exists(cache_path):
		var cached := ResourceLoader.load(cache_path)
		if cached != null:
			return cached

	# Call from the main thread: builders create Godot resources and nodes.
	var built: Resource = builder.call()
	if built == null:
		return null
	var save_error := ResourceSaver.save(built, cache_path, ResourceSaver.FLAG_COMPRESS)
	if save_error != OK and not _warned_write:
		_warned_write = true
		push_warning("Could not write derived resource cache %s: %s" % [cache_path, error_string(save_error)])
	return built

## Removes files of other converter versions and, when the cache is over its size limit, the oldest files.
static func _prune(root: String) -> void:
	var directory := DirAccess.open(root)
	if directory == null:
		return
	var current_prefix := CONVERTER_VERSION + "-"
	var kept: Array[Dictionary] = []
	var total := 0
	for file_name: String in directory.get_files():
		if not file_name.ends_with(".res"):
			continue
		var path := root + file_name
		if not file_name.begins_with(current_prefix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			continue
		var size := _file_size(path)
		total += size
		kept.push_back({"path": path, "size": size, "time": FileAccess.get_modified_time(path)})
	if total <= CACHE_SIZE_LIMIT_BYTES:
		return
	kept.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.time) < int(b.time))
	for entry: Dictionary in kept:
		if total <= CACHE_SIZE_LIMIT_BYTES:
			break
		DirAccess.remove_absolute(ProjectSettings.globalize_path(str(entry.path)))
		total -= int(entry.size)

static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var length := file.get_length()
	file.close()
	return int(length)
