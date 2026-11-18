extends RefCounted
## The player's live attributes, skill use, level and vital pools.

const ActorRules := preload("res://scripts/actor_rules.gd")
const ATTRIBUTE_INTELLIGENCE := 1
const ATTRIBUTE_STRENGTH := 0
const ATTRIBUTE_WILLPOWER := 2
const ATTRIBUTE_AGILITY := 3
const ATTRIBUTE_ENDURANCE := 5
const SCHOOL_SKILL_INDICES := [8, 9, 10, 11, 12, 13]

var _values: Dictionary = {}
var _attributes := PackedInt64Array()
var _skills := PackedInt64Array()
var _game_settings: Dictionary = {}
var _class_data: Dictionary = {}
var _skill_records: Dictionary = {}
var _abilities: Dictionary = {}
var _skill_use := PackedFloat64Array()
var _pending_levels: Array[PackedInt64Array] = []
var _attribute_advances := PackedInt64Array()
var _major_advances := 0
var _base_health := 0.0
var _active_effects: Array[Dictionary] = []
var level := 1

func initialize_from_base(player_record: Dictionary) -> bool:
	_values.clear()
	_attributes = PackedInt64Array()
	_skills = PackedInt64Array()
	_pending_levels.clear()
	_active_effects.clear()
	_major_advances = 0
	_skill_use = PackedFloat64Array()
	_skill_use.resize(21)
	_attribute_advances = PackedInt64Array()
	_attribute_advances.resize(8)
	level = 1
	if player_record.is_empty() or not bool(player_record.get("has_actor_values", false)):
		return false
	var attributes: PackedInt64Array = player_record.get("attributes", PackedInt64Array())
	var skills: PackedInt64Array = player_record.get("skills", PackedInt64Array())
	if attributes.size() <= ATTRIBUTE_ENDURANCE:
		return false
	_attributes = attributes.duplicate()
	_skills = skills.duplicate()
	var max_health := float(player_record.get("base_health", 0))
	_base_health = max_health
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

func configure_game_settings(settings: Dictionary) -> void:
	_game_settings = settings.duplicate()

func configure_progression(class_data: Dictionary, skill_records: Dictionary) -> void:
	_class_data = class_data
	_skill_records = skill_records

func change_class(previous_baseline: Dictionary, new_baseline: Dictionary, class_data: Dictionary) -> void:
	var old_attributes: PackedInt64Array = previous_baseline["attributes"]
	var new_attributes: PackedInt64Array = new_baseline["attributes"]
	for i in _attributes.size():
		_attributes[i] = mini(100, _attributes[i] + new_attributes[i] - old_attributes[i])
	var old_skills: PackedInt64Array = previous_baseline["skills"]
	var new_skills: PackedInt64Array = new_baseline["skills"]
	for i in _skills.size():
		_skills[i] = clampi(_skills[i] + new_skills[i] - old_skills[i], 0, 100)
	_base_health += float(new_baseline["base_health"]) - float(previous_baseline["base_health"])
	_class_data = class_data
	_refresh_maxima()

func attributes() -> PackedInt64Array:
	return ActorRules.values_with_abilities(_attributes, _abilities, "FOAT", 0)

func skills() -> PackedInt64Array:
	return ActorRules.values_with_abilities(_skills, _abilities, "FOSK", 12)

func skill(index: int) -> float:
	return float(_skills[index]) + float(_abilities.get("FOSK:%d" % (index + 12), 0.0)) if index >= 0 and index < _skills.size() else 0.0

func set_abilities(effects: Dictionary) -> void:
	_abilities = effects
	_refresh_maxima()

func ability(code: String) -> float:
	var amount := float(_abilities.get(code, 0.0))
	for effect: Dictionary in _active_effects:
		if effect["code"] == code:
			amount += float(effect["magnitude"])
	return amount

func clear_timed_effect(code: String) -> void:
	_active_effects = _active_effects.filter(func(effect: Dictionary) -> bool: return effect["code"] != code)

func apply_self_effect(code: String, magnitude: float, duration: float) -> void:
	if duration > 0.0 and code in ["REHE", "REMA", "REFA", "INVI", "REDG"]:
		_active_effects.push_back({"code": code, "magnitude": magnitude, "remaining": duration})
	else:
		_apply_instant_effect(code, magnitude)

func _apply_instant_effect(code: String, magnitude: float) -> void:
	match code:
		"REHE": restore_health(magnitude)
		"REMA": restore_magicka(magnitude)
		"REFA": modify_fatigue(magnitude)
		"DGFA": modify_fatigue(-magnitude)
		"DSPL": _active_effects.clear()

func record_skill_use(index: int, seconds_or_uses: float, secondary := false) -> bool:
	if index < 0 or index >= _skills.size() or _skills[index] >= 100 or seconds_or_uses <= 0.0:
		return false
	var record: Dictionary = _skill_records.get(index, {})
	var amount := float(record.get("use_secondary" if secondary else "use_primary", 0.0))
	if amount <= 0.0:
		return false
	_skill_use[index] += seconds_or_uses * amount
	var majors: PackedInt64Array = _class_data.get("major_skills", PackedInt64Array())
	var major := majors.has(index)
	var multiplier := _game_setting("fSkillUseMajorMult" if major else "fSkillUseMinorMult")
	if int(_class_data.get("specialization", -1)) == int(record.get("specialization", -2)):
		multiplier *= _game_setting("fSkillUseSpecMult")
	var advanced := false
	while _skills[index] < 100:
		var required := maxf(0.01, _game_setting("fSkillUseFactor") * pow(float(_skills[index] + 1),
			_game_setting("fSkillUseExp")) * multiplier)
		if _skill_use[index] < required:
			break
		_skill_use[index] -= required
		_skills[index] += 1
		advanced = true
		var attribute := int(record.get("attribute", -1))
		if attribute >= 0 and attribute < _attribute_advances.size():
			_attribute_advances[attribute] += 1
		if major:
			_major_advances += 1
			if _major_advances >= int(_game_setting("iLevelUpSkillCount")):
				_pending_levels.push_back(_attribute_advances.duplicate())
				_attribute_advances.fill(0)
				_major_advances = 0
	return advanced

func level_available() -> bool:
	return not _pending_levels.is_empty()

func level_bonus(attribute: int) -> int:
	if not level_available() or _attributes[attribute] >= ActorRules.MAX_ATTRIBUTE:
		return 0
	var increases := int(_pending_levels[0][attribute])
	var bonus := int(_game_settings.get("iLevelUp%02dMult" % mini(increases, 10), 1))
	return mini(bonus, ActorRules.MAX_ATTRIBUTE - _attributes[attribute])

func level_up(selected_attributes: Array[int]) -> bool:
	if not level_available():
		return false
	var available := _attributes.size() - _attributes.count(ActorRules.MAX_ATTRIBUTE)
	if selected_attributes.size() != mini(3, available):
		return false
	var seen := {}
	for index in selected_attributes:
		if index < 0 or index >= _attributes.size() or seen.has(index) or level_bonus(index) == 0:
			return false
		seen[index] = true
	for index in selected_attributes:
		_attributes[index] += level_bonus(index)
	_base_health += float(_attributes[ATTRIBUTE_ENDURANCE]) * _game_setting("fStatsHealthLevelMult")
	level += 1
	_pending_levels.pop_front()
	_refresh_maxima()
	return true

func rest() -> void:
	_active_effects.clear()
	for key: String in _values:
		if key != "magicka" or ability("STMA") <= 0.0:
			_set_current(key, _maximum(key))

func _refresh_maxima() -> void:
	if _values.is_empty():
		return
	var effective := attributes()
	var health := _base_health + ability("FOSP:8")
	var magicka := ActorRules.base_magicka(effective, _game_settings) + ability("FOSP:9")
	var fatigue := ActorRules.base_fatigue(effective) + ability("FOSP:10")
	for entry: Array in [["health", health], ["magicka", magicka], ["fatigue", fatigue]]:
		var vital: Dictionary = _values[entry[0]]
		var maximum := float(entry[1])
		var current := float(vital["current"]) + maximum - float(vital["max"])
		vital["max"] = maximum
		_set_current(entry[0], current)

## Apply the installed game's passive recovery and running drain once per simulation frame.
func advance_time(delta: float, is_running: bool) -> void:
	if delta <= 0.0 or _values.is_empty():
		return
	for index in range(_active_effects.size() - 1, -1, -1):
		var effect := _active_effects[index]
		var elapsed := minf(delta, float(effect["remaining"]))
		_apply_instant_effect(effect["code"], float(effect["magnitude"]) * elapsed)
		effect["remaining"] = float(effect["remaining"]) - elapsed
		if float(effect["remaining"]) <= 0.0:
			_active_effects.remove_at(index)
	var fatigue_change: float = (
		_game_setting("fFatigueReturnBase")
		+ (float(_attributes[ATTRIBUTE_ENDURANCE]) + ability("FOAT:5")) * _game_setting("fFatigueReturnMult")
	)
	if is_running:
		fatigue_change -= _game_setting("fFatigueRunBase")
	_modify_current("fatigue", fatigue_change * delta)
	if ability("STMA") > 0.0:
		return
	var willpower := float(_attributes[ATTRIBUTE_WILLPOWER]) + ability("FOAT:2")
	var magicka_regen_percent := 0.01 * (
		_game_setting("fMagickaReturnBase") + _game_setting("fMagickaReturnMult") * willpower
	)
	restore_magicka(_maximum("magicka") * magicka_regen_percent * delta)

func apply_jump_cost(encumbrance: float) -> void:
	modify_fatigue(-(_game_setting("fFatigueJumpBase") + _game_setting("fFatigueJumpMult") * encumbrance))

func school_skill(school: int) -> float:
	if school < 0 or school >= SCHOOL_SKILL_INDICES.size():
		return 0.0
	return skill(SCHOOL_SKILL_INDICES[school])

func snapshot() -> Dictionary:
	return _values.duplicate(true)

func progress() -> int:
	return _major_advances

func base_attributes() -> PackedInt64Array:
	return _attributes.duplicate()

func base_skills() -> PackedInt64Array:
	return _skills.duplicate()

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

func _game_setting(name: String) -> float:
	return float(_game_settings.get(name, 0.0))

func _current(key: String) -> float:
	var value: Dictionary = _values.get(key, {})
	return float(value.get("current", 0.0))

func _maximum(key: String) -> float:
	var value: Dictionary = _values.get(key, {})
	return float(value.get("max", 0.0))

func _modify_current(key: String, delta: float) -> void:
	_set_current(key, _current(key) + delta)

func _set_current(key: String, value: float) -> void:
	if not _values.has(key):
		return
	var vital: Dictionary = _values[key]
	vital["current"] = clampf(value, 0.0, float(vital.get("max", 0.0)))
	_values[key] = vital
