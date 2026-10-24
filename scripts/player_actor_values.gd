extends RefCounted
## Runtime dynamic actor values for the player. Base values come from the installed game's Player NPC record; current
## values are initialized full for a fresh session and are changed through these methods by gameplay systems.

const ATTRIBUTE_INTELLIGENCE := 1
const ATTRIBUTE_STRENGTH := 0
const ATTRIBUTE_WILLPOWER := 2
const ATTRIBUTE_AGILITY := 3
const ATTRIBUTE_ENDURANCE := 5

var _values: Dictionary = {}

func initialize_from_base(player_record: Dictionary) -> bool:
	_values.clear()
	if player_record.is_empty() or not bool(player_record.get("has_actor_values", false)):
		return false
	var attributes: PackedInt64Array = player_record.get("attributes", PackedInt64Array())
	if attributes.size() <= ATTRIBUTE_ENDURANCE:
		return false
	var max_health := float(player_record.get("base_health", 0))
	var max_magicka := float(player_record.get("base_magicka", 0))
	if max_magicka <= 0.0:
		# Oblivion's unmodified base magicka is twice Intelligence; races and birthsign effects can modify this later.
		max_magicka = float(attributes[ATTRIBUTE_INTELLIGENCE]) * 2.0
	var max_fatigue := float(player_record.get("base_fatigue", 0))
	if max_fatigue <= 0.0:
		max_fatigue = float(
			attributes[ATTRIBUTE_STRENGTH]
			+ attributes[ATTRIBUTE_WILLPOWER]
			+ attributes[ATTRIBUTE_AGILITY]
			+ attributes[ATTRIBUTE_ENDURANCE]
		)
	if max_health <= 0.0 or max_magicka <= 0.0 or max_fatigue <= 0.0:
		return false
	_values = {
		"health": {"current": max_health, "max": max_health},
		"magicka": {"current": max_magicka, "max": max_magicka},
		"fatigue": {"current": max_fatigue, "max": max_fatigue},
	}
	return true

func snapshot() -> Dictionary:
	return _values.duplicate(true)

func apply_damage(amount: float) -> void:
	_modify_current("health", -maxf(amount, 0.0))

func restore_health(amount: float) -> void:
	_modify_current("health", maxf(amount, 0.0))

func spend_magicka(amount: float) -> bool:
	var current := _current("magicka")
	if amount < 0.0 or current < amount:
		return false
	_set_current("magicka", current - amount)
	return true

func restore_magicka(amount: float) -> void:
	_modify_current("magicka", maxf(amount, 0.0))

func modify_fatigue(amount: float) -> void:
	_modify_current("fatigue", amount)

func _current(key: String) -> float:
	var value: Dictionary = _values.get(key, {})
	return float(value.get("current", 0.0))

func _modify_current(key: String, delta: float) -> void:
	_set_current(key, _current(key) + delta)

func _set_current(key: String, value: float) -> void:
	if not _values.has(key):
		return
	var vital: Dictionary = _values[key]
	vital["current"] = clampf(value, 0.0, float(vital.get("max", 0.0)))
	_values[key] = vital
