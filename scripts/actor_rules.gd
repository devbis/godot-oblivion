extends RefCounted
## Character creation and NPC auto-calculation. Actor-value indices 0..7 are
## attributes; inventory and animation code use zero-based skill indices.

const ATTRIBUTE_NAMES := ["Strength", "Intelligence", "Willpower", "Agility", "Speed", "Endurance", "Personality", "Luck"]
const SKILL_NAMES := [
	"Armorer", "Athletics", "Blade", "Block", "Blunt", "Hand to Hand", "Heavy Armor", "Alchemy",
	"Alteration", "Conjuration", "Destruction", "Illusion", "Mysticism", "Restoration", "Acrobatics",
	"Light Armor", "Marksman", "Mercantile", "Security", "Sneak", "Speechcraft",
]
const ACROBATICS := 14
const ATHLETICS := 1
const ENDURANCE := 5
const PLAYER_SKILL_MIN := 5
const MAX_ATTRIBUTE := 100
const LEVEL_SETTINGS := {
	"fPCBaseHealthMult": 2.0,
	"fStatsHealthLevelMult": 0.1,
	"fPCBaseMagickaMult": 0.5,
	"fNPCBaseMagickaMult": 0.5,
	"fAttributeClassPrimaryBonus": 5.0,
	"fAttributeClassSecondaryBonus": 5.0,
	"fSkillUseFactor": 0.35,
	"fSkillUseExp": 1.5,
	"fSkillUseMajorMult": 0.75,
	"fSkillUseMinorMult": 1.25,
	"fSkillUseSpecMult": 0.75,
	"iLevelUpSkillCount": 10,
	"fJumpHeightMin": 64.0,
	"fJumpHeightMax": 164.0,
	"fBlockSkillBase": 0.0,
	"fBlockSkillMult": 1.0,
	"fBlockAmountWeaponMult": 0.5,
	"fBlockAmountHandToHandMult": 0.25,
	"fBlockMax": 0.75,
	"fActorStrengthEncumbranceMult": 5.0,
	"fFatigueBlockBase": 0.0,
	"fFatigueBlockMult": 1.0,
	"fFatigueBlockSkillBase": 5.0,
	"fFatigueBlockSkillMult": -0.04,
}

static func level_for(record: Dictionary, player_level: int) -> int:
	var level := int(record.get("level_or_offset", 1))
	if (int(record.get("flags", 0)) & 0x80) != 0:
		level += player_level
		level = maxi(level, int(record.get("minimum_level", 1)))
		var maximum := int(record.get("maximum_level", 0))
		if maximum > 0:
			level = mini(level, maximum)
	return maxi(level, 1)

## Oblivion.exe FUN_005222d0. The tutorial class suppresses class bonuses.
static func calculate_base(
	record: Dictionary, class_data: Dictionary, skill_records: Dictionary, level: int,
	settings: Dictionary, is_player: bool
) -> void:
	var attributes: PackedInt64Array = record.get("racial_attributes", PackedInt64Array())
	if attributes.size() != ATTRIBUTE_NAMES.size() or attributes.count(0) == attributes.size():
		attributes = record.get("attributes", PackedInt64Array())
	if attributes.size() != ATTRIBUTE_NAMES.size():
		return
	attributes = attributes.duplicate()
	var bonuses: PackedInt64Array = record.get("racial_skill_bonuses", PackedInt64Array())
	var authored_attributes: PackedInt64Array = record.get("attributes", PackedInt64Array())
	if not is_player and authored_attributes.size() == ATTRIBUTE_NAMES.size():
		attributes[6] = authored_attributes[6] # NPC Personality is authored.
	var favored: PackedInt64Array = class_data.get("favored_attributes", PackedInt64Array())
	var majors: PackedInt64Array = class_data.get("major_skills", PackedInt64Array())
	var specialization := int(class_data.get("specialization", -1))
	var steps := float(level - 1)
	for position in favored.size():
		var attribute := int(favored[position])
		if attribute >= 0 and attribute < attributes.size() and (is_player or attribute != 6):
			var setting := "fAttributeClassPrimaryBonus" if position == 0 else "fAttributeClassSecondaryBonus"
			attributes[attribute] += int(settings[setting])
	var skills := PackedInt64Array()
	skills.resize(21)
	for index in skills.size():
		var skill_data: Dictionary = skill_records.get(index, {})
		var major := majors.has(index)
		var value := 25.0 + steps if major else float(PLAYER_SKILL_MIN) + steps * 0.1
		if specialization >= 0 and int(skill_data.get("specialization", -1)) == specialization:
			value += 5.0 + steps * 0.5
		if bonuses.size() > index:
			value += float(bonuses[index])
		skills[index] = clampi(roundi(value), 0, 100)
	for attribute in attributes.size():
		if not is_player and attribute == 6:
			continue
		var growth := 0.0
		if not class_data.is_empty():
			for index in skills.size():
				var skill_data: Dictionary = skill_records.get(index, {})
				if int(skill_data.get("attribute", -1)) == attribute:
					growth += steps * (1.0 if majors.has(index) else 0.2)
		attributes[attribute] = clampi(roundi(float(attributes[attribute]) + growth), 0, MAX_ATTRIBUTE)
	record["attributes"] = attributes
	record["skills"] = skills
	record["has_actor_values"] = true
	var health: float
	if is_player:
		health = floorf(float(attributes[ENDURANCE]) * float(settings["fPCBaseHealthMult"]))
	else:
		var health_per_level := int(settings["iNPCBasePerLevelHealthMult"]) + int(favored.has(ENDURANCE))
		match specialization:
			0: health_per_level += 1
			1: health_per_level -= 1
		var health_factor := lerpf(
			float(settings["fLowLevelNPCBaseHealthMult"]), 1.0,
			clampf(steps / maxf(float(settings["iLowLevelNPCMaxLevel"]), 1.0), 0.0, 1.0)
		)
		health = floorf((floorf(float(attributes[0] + attributes[5]) * float(settings["fNPCAttributeHealthMult"])) 			+ float(health_per_level) * steps) * health_factor)
	record["base_health"] = maxf(1.0, health)
	record["base_magicka"] = base_magicka(attributes, settings, is_player)
	record["base_fatigue"] = base_fatigue(attributes)

static func base_magicka(attributes: PackedInt64Array, settings: Dictionary, is_player := true) -> float:
	var name := "fPCBaseMagickaMult" if is_player else "fNPCBaseMagickaMult"
	return maxf(1.0, floorf(float(attributes[1]) * (1.0 + float(settings.get(name, 0.5)))))

static func base_fatigue(attributes: PackedInt64Array) -> float:
	return maxf(1.0, float(attributes[0] + attributes[2] + attributes[3] + attributes[5]))

static func named_values(attributes: PackedInt64Array, skills: PackedInt64Array) -> Dictionary:
	var result := {}
	for i in attributes.size():
		result[ATTRIBUTE_NAMES[i].to_lower()] = attributes[i]
	for i in skills.size():
		result[SKILL_NAMES[i].to_lower().replace(" ", "")] = skills[i]
	return result

static func jump_speed(acrobatics: float, gravity: float, unit_scale: float, settings: Dictionary) -> float:
	var height := lerpf(float(settings["fJumpHeightMin"]), float(settings["fJumpHeightMax"]),
		clampf(acrobatics * 0.01, 0.0, 1.0))
	return sqrt(2.0 * gravity * height * unit_scale)

static func abilities(reader: Object, spell_ids: PackedInt64Array) -> Dictionary:
	var effects := {}
	var seen := {}
	for id: int in spell_ids:
		if seen.has(id):
			continue
		seen[id] = true
		var spell: Dictionary = reader.find_spell(id)
		if int(spell.get("spell_type", -1)) != 4:
			continue
		for effect: Dictionary in spell.get("effects", []):
			var code := str(effect.get("code", ""))
			var value := int(effect.get("actor_value", -1))
			if code in ["FOAT", "FOSK", "FOSP"]:
				code += ":%d" % value
			var magnitude := float(effect.get("magnitude", 0.0))
			effects[code] = float(effects.get(code, 0.0)) + (1.0 if code == "STMA" else magnitude)
	return effects

static func values_with_abilities(values: PackedInt64Array, effects: Dictionary, prefix: String, offset: int) -> PackedInt64Array:
	var adjusted := values.duplicate()
	for index in adjusted.size():
		adjusted[index] += int(effects.get(prefix + ":%d" % (index + offset), 0))
	return adjusted
