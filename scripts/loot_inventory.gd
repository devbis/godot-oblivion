extends RefCounted
## Item stores for looting: what a body or a container holds, and moving items between stores. A store is a Dictionary of
## form id -> count. Pure data logic; the loot window and the player's inventory are in main.gd.

const MAX_LIST_DEPTH := 8

## Adds `entries` ([{form_id, count}], as the native reader returns them) to `store`; an entry naming a leveled item list
## is rolled for `level` first (a list may name other lists).
static func add_entries(store: Dictionary, data_reader: Object, entries: Array, level: int, rng: RandomNumberGenerator, depth := 0) -> void:
	for entry_value: Variant in entries:
		var entry: Dictionary = entry_value
		var form_id := int(entry.get("form_id", 0))
		var count := maxi(int(entry.get("count", 1)), 1)
		if form_id <= 0:
			continue
		if str(data_reader.find_record_type(form_id)) == "LVLI" or not data_reader.find_leveled_list(form_id).is_empty():
			if depth < MAX_LIST_DEPTH:
				_roll_list(store, data_reader, form_id, count, level, rng, depth + 1)
			continue
		store[form_id] = int(store.get(form_id, 0)) + count

static func _roll_list(store: Dictionary, data_reader: Object, list_id: int, repeat: int, level: int, rng: RandomNumberGenerator, depth: int) -> void:
	var list: Dictionary = data_reader.find_leveled_list(list_id)
	if list.is_empty():
		return
	var flags := int(list.get("flags", 0))
	var eligible: Array = []
	for entry_value: Variant in list.get("entries", []):
		var entry: Dictionary = entry_value
		if int(entry.get("level", 0)) <= level:
			eligible.push_back(entry)
	if eligible.is_empty():
		return
	# Flag 1: only the highest level the looter has reached; 4: every eligible entry is dropped.
	if (flags & 0x04) == 0 and (flags & 0x01) == 0:
		var highest := 0
		for entry: Dictionary in eligible:
			highest = maxi(highest, int(entry.get("level", 0)))
		eligible = eligible.filter(func(entry: Dictionary) -> bool: return int(entry.get("level", 0)) == highest)
	var rolls := repeat if (flags & 0x02) != 0 else 1
	for _roll in range(rolls):
		if int(list.get("chance_none", 0)) > 0 and rng.randi_range(1, 100) <= int(list.get("chance_none", 0)):
			continue
		var chosen: Array = eligible if (flags & 0x04) != 0 else [eligible[rng.randi() % eligible.size()]]
		var picked: Array = []
		for entry: Dictionary in chosen:
			picked.push_back({"form_id": int(entry.get("form_id", 0)), "count": int(entry.get("count", 1))})
		add_entries(store, data_reader, picked, level, rng, depth)

## Moves up to `count` of an item from one store to another; the number actually moved.
static func transfer(from: Dictionary, to: Dictionary, form_id: int, count: int) -> int:
	var moved := mini(count, int(from.get(form_id, 0)))
	if moved <= 0:
		return 0
	var left := int(from[form_id]) - moved
	if left > 0:
		from[form_id] = left
	else:
		from.erase(form_id)
	to[form_id] = int(to.get(form_id, 0)) + moved
	return moved

static func total_weight(store: Dictionary, data_reader: Object) -> float:
	var weight := 0.0
	for form_id_value: Variant in store.keys():
		var stats: Dictionary = data_reader.find_item_stats(int(form_id_value))
		weight += float(stats.get("weight", 0.0)) * int(store[form_id_value])
	return weight

## Item form ids sorted by type, then name, so a list does not reshuffle between refreshes.
static func sorted_ids(store: Dictionary, data_reader: Object) -> Array[int]:
	var ids: Array[int] = []
	for form_id_value: Variant in store.keys():
		ids.push_back(int(form_id_value))
	ids.sort_custom(func(a: int, b: int) -> bool:
		var key_a := "%s|%s|%08x" % [data_reader.find_record_type(a), data_reader.find_record_display_name(a), a]
		var key_b := "%s|%s|%08x" % [data_reader.find_record_type(b), data_reader.find_record_display_name(b), b]
		return key_a < key_b)
	return ids
