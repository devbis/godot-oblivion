extends RefCounted
## Hostile actors. An actor starts a fight with the player when a script orders it (StartCombat), when the player has
## attacked it, or when it is aggressive enough to attack on sight: Oblivion's aggression runs from 0 (never) through
## 5 (aggressive: only enemies) and 50 (very aggressive: anyone not a friend) to 100 (frenzied), and the player has no
## friends yet, so from 50 up an actor that sees the player attacks. It then draws its weapon, runs at the player along
## the navigation path and swings (or, with a bow, shoots from a distance) with the original combat clips; the hit lands
## at the clip's "Hit" or "Release" key and costs the player health and fatigue.

const CombatProjectile := preload("res://scripts/combat_projectile.gd")

const AGGRESSION_ATTACKS_ON_SIGHT := 50
const DETECT_RADIUS_M := 22.0
const DETECT_RADIUS_FRENZIED_M := 32.0
const LOSE_INTEREST_M := 60.0
const SIGHT_EYE_HEIGHT_M := 1.5
const START_CHECK_S := 0.3
const REPATH_S := 0.5
const RUN_SPEED_MPS := 3.4
const RUNNING_ANIMATION_SPEED_MPS := 2.2
const NPC_ATTACK_RECOVERY_MIN_S := 0.9
const NPC_ATTACK_RECOVERY_MAX_S := 1.3
const CLIP_FOLDER := "Characters/_male/"
## How far past its reach a swing still lands, and how a block cuts the damage of a hit from the front.
const HIT_REACH_SLACK_M := 0.5
const BLOCKED_DAMAGE_SHARE := 0.3
const POWER_ATTACK_CHANCE := 0.2
const POWER_ATTACK_DAMAGE_MULT := 1.5
const UNARMED_DAMAGE := 4.0
const UNARMED_REACH_M := 1.4
const HIT_ATTACK_LOCK_S := 0.45
const FATIGUE_ATTACK_COST := 5.0
const FATIGUE_HIT_COST_MULT := 1.5
const NPC_HIT_KNOCKBACK_MPS := 0.3
const PLAYER_HIT_KNOCKBACK_MPS := 0.4
## Oblivion restores 10 fatigue/s; this exceeds what a ~2 s stagger clip restores between repeated hits.
const FATIGUE_HIT_MIN := 25.0
const FATIGUE_DOWN_RECOVERY_RATIO := 0.25
const FATIGUE_ATTACK_WEAPON_BASE_SETTING := "fFatigueAttackWeaponBase"
const FATIGUE_ATTACK_WEAPON_MULT_SETTING := "fFatigueAttackWeaponMult"
const FATIGUE_RETURN_BASE_SETTING := "fFatigueReturnBase"
const FATIGUE_RETURN_MULT_SETTING := "fFatigueReturnMult"
const FATIGUE_RUN_BASE_SETTING := "fFatigueRunBase"
const ATTRIBUTE_ENDURANCE := 5
## Blows between actors wear fatigue down by the damage they deal, not the player-sized minimum: with that, fights end in a
## knockdown loop instead of a death.
const ACTOR_HIT_FATIGUE_MULT := 1.0
const ALLY_HELP_RADIUS_M := 25.0
const CHASE_HOP_MAX_M := 8.0
const CHASE_HOP_LANDING_OFFSET_M := 1.2
const AGGRESSION_DEFENDS := 5
const ARCHER_RANGE_M := 14.0
const ARCHER_MIN_RANGE_M := 4.0
const ARROW_SPEED_MPS := 40.0
const WEAPON_TYPE_BOW := 5
const WEAPON_HOLD_BONES := {5: "Torch"}
const STANCE_PREFIXES := {0: "onehand", 1: "twohand", 2: "onehand", 3: "twohand", 4: "staff", 5: "bow"}
const UNARMED_PREFIX := "handtohand"

## Emitted when an actor's hit lands on the player.
signal player_hit(attacker_name: String, damage: float)

var host: Node3D
var _check_timer := 0.0
## Reference id of an actor ordered to fight -> the reference id it fights (0: the player).
var _forced: Dictionary = {}
var _provoked: Dictionary = {}
var _calmed: Dictionary = {}
var _logged_waiting: Dictionary = {}
var _player_dead := false

func _init(host_node: Node3D) -> void:
	host = host_node

## A script ordered the actor to fight the player, or the actor of `target_id` (StartCombat).
func force_combat(reference_id: int, target_id: int = 0) -> void:
	_forced[reference_id] = target_id
	_calmed.erase(reference_id)

## The player attacked the actor: it fights back whatever its aggression.
func provoke(reference_id: int) -> void:
	_provoked[reference_id] = true
	_calmed.erase(reference_id)

## StopCombat: the actor stands down and is not provoked again by the same grudge.
func stop_combat(reference_id: int) -> void:
	_forced.erase(reference_id)
	_provoked.erase(reference_id)
	_calmed[reference_id] = true
	for actor: Dictionary in host.get("_npc_actors"):
		if int(actor.get("reference_id", 0)) == reference_id and actor.has("combat"):
			_end_combat(actor)

func in_combat(actor: Dictionary) -> bool:
	return actor.has("combat")

func _actor_by_id(reference_id: int) -> Dictionary:
	for candidate: Dictionary in host.get("_npc_actors"):
		if int(candidate.get("reference_id", 0)) == reference_id:
			return candidate
	return {}

func _actor_fighting(actor: Dictionary) -> bool:
	var root := actor.get("root") as Node3D
	return is_instance_valid(root) and not bool(root.get("inactive")) and root.visible and not bool(actor.get("dead", false))

func update(delta: float) -> void:
	if not bool(host.get("_player_actor_values_ready")):
		return
	var player: CharacterBody3D = host.get("player")
	if player == null:
		return
	var player_dead := _player_health() <= 0.0
	if player_dead and not _player_dead:
		host.call("_show_interaction_toast", "You died")
	_player_dead = player_dead
	_check_timer -= delta
	var check_starts := _check_timer <= 0.0
	if check_starts:
		_check_timer = START_CHECK_S
	for actor: Dictionary in host.get("_npc_actors"):
		var root := actor.get("root") as Node3D
		if not is_instance_valid(root) or bool(root.get("inactive")) or not root.visible or bool(actor.get("dead", false)):
			continue
		_advance_actor_fatigue(actor, root, delta)
		if str(actor.get("knockdown_state", "")) in ["falling", "downed", "getting_up"]:
			continue
		var hit_lock_remaining := maxf(0.0, float(actor.get("hit_attack_lock_remaining", 0.0)) - delta)
		actor["hit_attack_lock_remaining"] = hit_lock_remaining
		if hit_lock_remaining > 0.0:
			continue
		if str((actor.get("hit_reaction", {}) as Dictionary).get("kind", "")) == "stagger":
			actor.erase("hit_reaction")
			actor["active_animation"] = ""
		if actor.has("combat"):
			if _player_dead and int((actor.combat as Dictionary).get("target_id", 0)) == 0:
				_end_combat(actor)
			else:
				_update_combat(actor, root, player, delta)
		elif check_starts:
			var reference_id := int(actor.get("reference_id", 0))
			var forced_target := int(_forced.get(reference_id, 0))
			if forced_target != 0:
				var victim := _actor_by_id(forced_target)
				if victim.is_empty() and not _logged_waiting.has(reference_id):
					_logged_waiting[reference_id] = true
					print("OpenOB combat: %s is ordered to fight reference 0x%08X, which is not loaded; it waits" % [
						str(actor.get("reference_name", "NPC")), forced_target
					])
				if bool(victim.get("dead", false)):
					_forced.erase(reference_id)
				elif not _calmed.has(reference_id) and not victim.is_empty() and _actor_fighting(victim):
					_begin_combat(actor, root, forced_target)
			elif not _player_dead and _wants_to_fight(actor, root, player):
				_begin_combat(actor, root)

func _player_health() -> float:
	var vitals: Dictionary = (host.get("_player_actor_values") as RefCounted).call("snapshot")
	return float((vitals.get("health", {}) as Dictionary).get("current", 0.0))

func _aggression(actor: Dictionary) -> int:
	var overridden: Variant = (host.get("quest_bridge") as RefCounted).call(
		"actor_value_override", str(actor.get("reference_name", "")), "aggression"
	)
	return int(overridden) if overridden != null else int(actor.get("aggression", 0))

func _wants_to_fight(actor: Dictionary, root: Node3D, player: CharacterBody3D) -> bool:
	var reference_id := int(actor.get("reference_id", 0))
	if _calmed.has(reference_id) or bool(host.get("_dialogue_active")):
		return false
	var distance := root.global_position.distance_to(player.global_position)
	var aggression := _aggression(actor)
	var ordered := _forced.has(reference_id) or _provoked.has(reference_id)
	if not ordered:
		if aggression < AGGRESSION_ATTACKS_ON_SIGHT or _on_scripted_errand(actor):
			return false
		if distance > (DETECT_RADIUS_FRENZIED_M if aggression >= 80 else DETECT_RADIUS_M):
			return false
	elif distance > LOSE_INTEREST_M:
		return false
	return ordered or _sees_player(root, player)

## An actor walking to the place its quest package names is not distracted by the player; it fights when the script says.
func _on_scripted_errand(actor: Dictionary) -> bool:
	var package: Dictionary = actor.get("package", {})
	return not package.is_empty() and not bool(actor.get("package_done", false)) \
		and int(host.call("_package_destination_form_id", package)) not in [0, int(host.get("PLAYER_REFERENCE_FORM_ID"))]

func _sees_player(root: Node3D, player: CollisionObject3D) -> bool:
	var camera: Camera3D = player.get("camera")
	var to := camera.global_position if camera != null else player.global_position + Vector3.UP * SIGHT_EYE_HEIGHT_M
	var from := root.global_position + Vector3.UP * SIGHT_EYE_HEIGHT_M
	var query := PhysicsRayQueryParameters3D.create(from, to, 1 | 2, [player.get_rid(), (root as CollisionObject3D).get_rid()])
	return root.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func _weapon_type(actor: Dictionary) -> int:
	var record: Dictionary = actor.get("weapon_record", {})
	return int(record.get("weapon_type", -1)) if not record.is_empty() else -1

func _prefix(actor: Dictionary) -> String:
	return str(STANCE_PREFIXES.get(_weapon_type(actor), UNARMED_PREFIX))

func _is_archer(actor: Dictionary) -> bool:
	return _weapon_type(actor) == WEAPON_TYPE_BOW

func _reach_m(actor: Dictionary) -> float:
	var record: Dictionary = actor.get("weapon_record", {})
	if record.is_empty():
		return UNARMED_REACH_M
	return host.MELEE_BASE_REACH_M * float(record.get("reach", 1.0))

func _damage(actor: Dictionary) -> float:
	var record: Dictionary = actor.get("weapon_record", {})
	return float(record.get("damage", UNARMED_DAMAGE)) if not record.is_empty() else UNARMED_DAMAGE

func _attack_fatigue_cost(actor: Dictionary) -> float:
	if _weapon_type(actor) < 0:
		return FATIGUE_ATTACK_COST
	var settings: Dictionary = host.get("_player_game_settings")
	return float(settings.get(FATIGUE_ATTACK_WEAPON_BASE_SETTING, FATIGUE_ATTACK_COST)) \
		+ _damage(actor) * float(settings.get(FATIGUE_ATTACK_WEAPON_MULT_SETTING, 0.0))

func receive_player_hit(reference_id: int, source_position: Vector3, fatigue_damage: float) -> void:
	var actor: Dictionary = {}
	for candidate: Dictionary in host.get("_npc_actors"):
		if int(candidate.get("reference_id", 0)) == reference_id:
			actor = candidate
			break
	if actor.is_empty():
		return
	provoke(reference_id)
	_react_to_hit(actor, source_position, fatigue_damage, 0, _player_base_form_id())

## Another actor's blow: health, the flinch, and the victim (and its allies) turn on the attacker.
func receive_actor_hit(victim: Dictionary, attacker: Dictionary, damage: float) -> void:
	if bool(victim.get("dead", false)):
		return
	var attacker_root := attacker.get("root") as Node3D
	var attacker_id := int(attacker.get("reference_id", 0))
	var health: Dictionary = victim.get("health", {})
	if not health.is_empty():
		var remaining := maxf(0.0, float(health.get("current", 0.0)) - damage)
		if bool(victim.get("essential", false)):
			remaining = maxf(remaining, 1.0)
		health["current"] = remaining
		victim["health"] = health
		if remaining <= 0.0:
			_run_actor_events(victim, "OnHit", str(attacker.get("reference_name", "")))
			kill_actor(victim)
			return
	_run_actor_events(victim, "OnHit", "")
	_run_actor_events(victim, "OnHit", str(attacker.get("reference_name", "")))
	if bool(victim.get("dead", false)):
		return
	var fight_back := _aggression(victim) >= AGGRESSION_DEFENDS and not _calmed.has(int(victim.get("reference_id", 0)))
	var source := attacker_root.global_position if is_instance_valid(attacker_root) else Vector3.ZERO
	_react_to_hit(
		victim, source, damage * ACTOR_HIT_FATIGUE_MULT, attacker_id if fight_back else -1,
		int(attacker.get("base_form_id", 0))
	)
	_call_allies(victim, attacker)

func _react_to_hit(
	actor: Dictionary, source_position: Vector3, fatigue_damage: float,
	fight_target_id: int, listener_base_form_id: int
) -> void:
	var root := actor.get("root") as Node3D
	if is_instance_valid(root):
		var away := root.global_position - source_position
		away.y = 0.0
		if away.length_squared() > 0.0001:
			root.call("apply_hit_impulse", away.normalized() * NPC_HIT_KNOCKBACK_MPS)
		var audio_manager := host.get_node_or_null("/root/AudioManager") as Node
		if audio_manager != null:
			audio_manager.call(
				"play_combat_voice", root, int(actor.get("base_form_id", 0)), listener_base_form_id, "Hit"
			)
	var knockdown_state := str(actor.get("knockdown_state", ""))
	if knockdown_state in ["falling", "downed"]:
		return
	if knockdown_state == "getting_up":
		_begin_knockdown(actor)
		return
	_apply_actor_fatigue(actor, maxf(0.0, fatigue_damage))
	if _actor_fatigue_current(actor) <= 0.0:
		_begin_knockdown(actor)
	else:
		if is_instance_valid(root) and not actor.has("combat") and fight_target_id >= 0:
			_begin_combat(actor, root, fight_target_id, false)
		_begin_stagger(actor)

## Actors that share a faction with the victim come to its help against the attacker.
func _call_allies(victim: Dictionary, attacker: Dictionary) -> void:
	var victim_root := victim.get("root") as Node3D
	var attacker_id := int(attacker.get("reference_id", 0))
	var victim_factions: PackedInt64Array = victim.get("faction_form_ids", PackedInt64Array())
	var attacker_factions: PackedInt64Array = attacker.get("faction_form_ids", PackedInt64Array())
	if not is_instance_valid(victim_root) or victim_factions.is_empty():
		return
	for ally: Dictionary in host.get("_npc_actors"):
		var ally_root := ally.get("root") as Node3D
		if ally == victim or ally.has("combat") or not _actor_fighting(ally) or int(ally.get("reference_id", 0)) == attacker_id:
			continue
		if _aggression(ally) < AGGRESSION_DEFENDS or _calmed.has(int(ally.get("reference_id", 0))):
			continue
		if ally_root.global_position.distance_to(victim_root.global_position) > ALLY_HELP_RADIUS_M:
			continue
		var allied := false
		var ally_factions: PackedInt64Array = ally.get("faction_form_ids", PackedInt64Array())
		for faction_id: int in ally_factions:
			if victim_factions.has(faction_id) and not attacker_factions.has(faction_id):
				allied = true
				break
		if allied:
			_begin_combat(ally, ally_root, attacker_id)

## Runs an event block of the actor's own script (OnHit, OnDeath) and applies what it does.
func _run_actor_events(actor: Dictionary, event: String, detail: String) -> void:
	var quest_world: Object = host.get("quest_world")
	var quest_id := str(host.get("route_quest_editor_id"))
	if quest_world == null or quest_id.is_empty():
		print("OpenOB combat %s: %s runs nothing, no quest has started" % [event, str(actor.get("reference_name", "NPC"))])
		return
	host.call("_sync_player_actor_values_to_quest_world")
	var result: Dictionary = quest_world.call(
		"run_actor_event", quest_id, str(actor.get("npc_editor_id", "")), event, detail, Callable(host, "_quest_distance")
	)
	host.call("fill_actor_event_target", result, actor)
	host.call("log_missing_actor_event", actor, event, detail, result)
	for line: String in host.call("_apply_driver_result", result):
		print("OpenOB combat %s: %s" % [event, line])
	if bool(host.call("_needs_route_refresh", result)):
		host.call("_refresh_npc_routes")

## The actor dies: it falls and stays down, and its OnDeath script runs.
func kill_actor(actor: Dictionary) -> void:
	if bool(actor.get("dead", false)):
		return
	var root := actor.get("root") as Node3D
	var reference_id := int(actor.get("reference_id", 0))
	actor["dead"] = true
	actor.erase("combat")
	actor.erase("combat_anim")
	_forced.erase(reference_id)
	_provoked.erase(reference_id)
	_set_weapon_drawn(actor, false)
	_begin_knockdown(actor)
	if is_instance_valid(root):
		# The body lies where it fell but does not block the living (its layer is off; it still rests on the floor).
		(root as CollisionObject3D).collision_layer = 0
	print("OpenOB combat: %s dies" % str(actor.get("reference_name", "NPC")))
	_run_actor_events(actor, "OnDeath", "")

func _advance_actor_fatigue(actor: Dictionary, root: Node3D, delta: float) -> void:
	var fatigue: Dictionary = actor.get("fatigue", {})
	if fatigue.is_empty() or bool(actor.get("dead", false)):
		return
	var maximum := float(fatigue.get("max", 0.0))
	if maximum <= 0.0:
		return
	var current := float(fatigue.get("current", maximum))
	var attributes: PackedInt64Array = actor.get("attributes", PackedInt64Array())
	var endurance := float(attributes[ATTRIBUTE_ENDURANCE]) if attributes.size() > ATTRIBUTE_ENDURANCE else 0.0
	var settings: Dictionary = host.get("_player_game_settings")
	var recovery := float(settings.get(FATIGUE_RETURN_BASE_SETTING, 1.0)) \
		+ endurance * float(settings.get(FATIGUE_RETURN_MULT_SETTING, 0.0))
	if bool(root.get("is_walking")) and Vector2(root.velocity.x, root.velocity.z).length() > RUNNING_ANIMATION_SPEED_MPS:
		recovery -= float(settings.get(FATIGUE_RUN_BASE_SETTING, 0.0))
	fatigue["current"] = clampf(current + recovery * delta, 0.0, maximum)
	actor["fatigue"] = fatigue
	var knockdown_state := str(actor.get("knockdown_state", ""))
	if knockdown_state.is_empty() and float(fatigue["current"]) <= 0.0:
		_begin_knockdown(actor)
	elif knockdown_state == "downed" and float(fatigue["current"]) >= maximum * FATIGUE_DOWN_RECOVERY_RATIO:
		_begin_get_up(actor)

func _actor_fatigue_current(actor: Dictionary) -> float:
	return float((actor.get("fatigue", {}) as Dictionary).get("current", 0.0))

func _apply_actor_fatigue(actor: Dictionary, amount: float) -> void:
	var fatigue: Dictionary = actor.get("fatigue", {})
	if fatigue.is_empty():
		return
	fatigue["current"] = maxf(0.0, float(fatigue.get("current", 0.0)) - maxf(amount, 0.0))
	actor["fatigue"] = fatigue

func _stagger_animation(actor: Dictionary) -> String:
	var prefix := _prefix(actor)
	return "bowblockhit" if prefix == "bow" else prefix + "stagger"

func _begin_stagger(actor: Dictionary) -> void:
	var clip := _stagger_animation(actor)
	actor["hit_reaction"] = {"kind": "stagger", "animation": clip}
	actor["hit_attack_lock_remaining"] = HIT_ATTACK_LOCK_S
	actor["active_animation"] = ""
	_request_clip(actor, clip)
	_interrupt_actor_attack(actor)
	var root := actor.get("root") as Node3D
	if is_instance_valid(root):
		_stop_route(root)

func _begin_knockdown(actor: Dictionary) -> void:
	if str(actor.get("knockdown_state", "")) in ["falling", "downed"]:
		return
	var root := actor.get("root") as Node3D
	actor["knockdown_state"] = "falling"
	actor["hit_attack_lock_remaining"] = 0.0
	actor["hit_reaction"] = {"kind": "stagger", "animation": _stagger_animation(actor)}
	actor["active_animation"] = ""
	_interrupt_actor_attack(actor)
	if is_instance_valid(root):
		_stop_route(root)
		root.call("set_knocked_down", true)
	_request_clip(actor, _stagger_animation(actor))
	_request_special_clip(
		actor, "Downed", "Characters/_male/idleanims/deathidle.kf", "SpecialIdle_DeathIdle", true
	)
	print("OpenOB combat: %s falls at zero fatigue" % str(actor.get("reference_name", "NPC")))

func _begin_get_up(actor: Dictionary) -> void:
	var prefix := _prefix(actor)
	if prefix not in ["handtohand", "bow"]:
		prefix = "onehand"
	var asset_path := "Characters/_male/idleanims/%sgetupfacedown.kf" % prefix
	actor["knockdown_state"] = "getting_up"
	actor["hit_reaction"] = {"kind": "getup", "animation": "GetUp"}
	actor["active_animation"] = ""
	_request_special_clip(actor, "GetUp", asset_path, "SpecialIdle_GetUpFaceDown", false)

func _interrupt_actor_attack(actor: Dictionary) -> void:
	if actor.has("combat"):
		var combat: Dictionary = actor.combat
		combat["state"] = "chase"
		combat["hit_done"] = true
		combat["cooldown"] = 0.0
		combat["clip"] = ""
		actor["combat"] = combat
		# The stagger clip overrides this animation temporarily. Keep the weapon-ready
		# idle underneath so the NPC returns to its combat stance after the flinch.
		actor["combat_anim"] = _prefix(actor) + "idle"
	else:
		actor["combat_anim"] = ""

func _request_special_clip(actor: Dictionary, clip_name: String, asset_path: String, sequence_name: String, loops: bool) -> void:
	var animations: Dictionary = actor.animations
	var requested: Dictionary = actor.get("combat_clips_requested", {})
	if animations.has(clip_name) or requested.has(clip_name):
		return
	requested[clip_name] = true
	actor["combat_clips_requested"] = requested
	var assets = host.get("assets")
	await assets.meshes_for_model(asset_path)
	var skeleton := actor.get("skeleton") as Skeleton3D
	if not is_instance_valid(skeleton):
		return
	var metadata: Dictionary = assets.nif_metadata_cache.get(asset_path.to_lower(), {})
	for sequence_value: Variant in metadata.get("animations", []):
		var sequence: Dictionary = sequence_value
		if str(sequence.get("name", "")) != sequence_name:
			continue
		var animation := (host.call("_animation_sequence", asset_path, sequence_name, skeleton) as Dictionary).duplicate()
		if not animation.is_empty():
			animation["loops"] = loops
			animations[clip_name] = animation
		return

func _begin_combat(actor: Dictionary, root: Node3D, target_id: int = 0, play_attack_voice := true) -> void:
	actor["combat"] = {"state": "chase", "repath": 0.0, "cooldown": 0.0, "clip": "", "time": 0.0, "hit_done": true, "target_id": target_id}
	actor["combat_anim"] = ""
	_set_weapon_drawn(actor, true)
	var audio_manager := host.get_node_or_null("/root/AudioManager") as Node
	if audio_manager != null:
		audio_manager.call("play_weapon_ready", root, _weapon_type(actor), true)
		if play_attack_voice:
			audio_manager.call(
				"play_combat_voice", root, int(actor.get("base_form_id", 0)),
				_combat_target_base_form_id(target_id), "Attack"
			)
	var prefix := _prefix(actor)
	var suffixes: Array[String] = ["idle", "fastforward", "forward"]
	suffixes.append_array(_attack_suffixes(prefix))
	for suffix: String in suffixes:
		_request_clip(actor, prefix + suffix)
	_stop_route(root)
	_cancel_package_route(actor)
	print("OpenOB combat: %s attacks %s (aggression %d, weapon type %d)" % [
		str(actor.get("reference_name", "NPC")),
		"the player" if target_id == 0 else str(_actor_by_id(target_id).get("reference_name", "an actor")),
		_aggression(actor), _weapon_type(actor)
	])

func _end_combat(actor: Dictionary) -> void:
	var root := actor.get("root") as Node3D
	actor.erase("combat")
	actor.erase("combat_anim")
	_set_weapon_drawn(actor, false)
	if is_instance_valid(root):
		var audio_manager := host.get_node_or_null("/root/AudioManager") as Node
		if audio_manager != null:
			audio_manager.call("play_weapon_ready", root, _weapon_type(actor), false)
		_stop_route(root)
	host.call("_refresh_actor_route", actor)

func _stop_route(root: Node3D) -> void:
	var no_route: Array[Dictionary] = []
	root.call("configure_route", no_route, false, 0.0)

func _cancel_package_route(actor: Dictionary) -> void:
	actor.erase("route_target")
	actor.erase("follow_hold_target_form_id")

func _set_weapon_drawn(actor: Dictionary, drawn: bool) -> void:
	var meshes: Array = actor.get("weapon_meshes", [])
	var hold_bone := str(WEAPON_HOLD_BONES.get(_weapon_type(actor), "Weapon"))
	for mesh_value: Variant in meshes:
		var mesh := mesh_value as MeshInstance3D
		if not is_instance_valid(mesh):
			continue
		var attachment := mesh.get_parent() as BoneAttachment3D
		if attachment == null:
			continue
		if not attachment.has_meta("stow_bone"):
			attachment.set_meta("stow_bone", attachment.bone_name)
		attachment.bone_name = hold_bone if drawn else str(attachment.get_meta("stow_bone"))

func _update_combat(actor: Dictionary, root: Node3D, player: CharacterBody3D, delta: float) -> void:
	var combat: Dictionary = actor.combat
	var target: CollisionObject3D = player
	var target_id := int(combat.get("target_id", 0))
	var target_actor: Dictionary = {}
	if target_id != 0:
		target_actor = _actor_by_id(target_id)
		if target_actor.is_empty() or not _actor_fighting(target_actor):
			if bool(target_actor.get("dead", false)) and int(_forced.get(int(actor.get("reference_id", 0)), 0)) == target_id:
				_forced.erase(int(actor.get("reference_id", 0)))
			_end_combat(actor)
			return
		target = target_actor.root as CollisionObject3D
	var to_player := target.global_position - root.global_position
	var flat := Vector2(to_player.x, to_player.z)
	var distance := flat.length()
	if distance > LOSE_INTEREST_M or bool(host.get("_dialogue_active")):
		_end_combat(actor)
		return
	combat.cooldown = maxf(float(combat.cooldown) - delta, 0.0)
	var prefix := _prefix(actor)
	if str(combat.state) == "swing":
		_update_swing(actor, root, target, target_actor, combat, delta, flat)
		return
	var archer := _is_archer(actor)
	var in_attack_range := distance <= (ARCHER_RANGE_M if archer else _reach_m(actor) * 0.85)
	if archer:
		in_attack_range = in_attack_range and distance >= ARCHER_MIN_RANGE_M and _sees_player(root, target)
	if in_attack_range:
		_stop_route(root)
		_face(root, flat, delta)
		actor["combat_anim"] = prefix + "idle"
		if float(combat.cooldown) <= 0.0:
			_begin_swing(actor, combat, prefix)
		return
	combat.repath = float(combat.repath) - delta
	if float(combat.repath) <= 0.0:
		combat.repath = REPATH_S
		_chase(actor, root, target, archer)
	var speed := Vector2(root.velocity.x, root.velocity.z).length()
	actor["combat_anim"] = prefix + ("fastforward" if speed > RUNNING_ANIMATION_SPEED_MPS else "forward")

func _chase(actor: Dictionary, root: Node3D, player: Node3D, archer: bool) -> void:
	var arrival := (ARCHER_RANGE_M * 0.7) if archer else _reach_m(actor) * 0.6
	var path: PackedVector3Array = host.get("director").call(
		"navigation_path", root.global_position, player.global_position, host.call("_actor_collision_radius", root), false, arrival
	)
	var waypoints: Array[Dictionary] = []
	if path.is_empty():
		waypoints.push_back({"position": player.global_position, "speed_mps": RUN_SPEED_MPS})
	else:
		waypoints = host.call("_navigation_waypoints", path, RUN_SPEED_MPS)
		# The navigation ends at the edge of what it can reach (a ledge above the target): the actor hops down to the floor
		# beside the target. A target that is far or not lower is waited for at the edge.
		var end := path[path.size() - 1]
		var gap := Vector2(end.x - player.global_position.x, end.z - player.global_position.z).length()
		if gap > arrival + 0.5:
			var away := Vector3(end.x - player.global_position.x, 0.0, end.z - player.global_position.z).normalized()
			host.call("hop_down_waypoint", waypoints, player.global_position + away * CHASE_HOP_LANDING_OFFSET_M, CHASE_HOP_MAX_M)
	root.call("configure_route", waypoints, false, 0.0, arrival, false)

func _face(root: Node3D, flat: Vector2, delta: float) -> void:
	if flat.length() < 0.05:
		return
	var desired_yaw := atan2(-flat.x, -flat.y)
	root.rotation.y = lerp_angle(root.rotation.y, desired_yaw, 1.0 - exp(-10.0 * delta))

## The attack clips a stance has (the original has no plain "attack" for fists or blades, and one swing for a staff).
func _attack_suffixes(prefix: String) -> Array[String]:
	match prefix:
		"bow":
			return ["attack"]
		"staff":
			return ["attackright"]
		"handtohand":
			return ["attackright", "attackleft"]
	return ["attackright", "attackleft", "attackpower"]

func _begin_swing(actor: Dictionary, combat: Dictionary, prefix: String) -> void:
	var options := _attack_suffixes(prefix)
	if prefix in ["onehand", "twohand"] and randf() < POWER_ATTACK_CHANCE:
		options = ["attackpower"]
	else:
		options.erase("attackpower")
	var clip_key := prefix + options[randi() % options.size()]
	var animation: Dictionary = (actor.animations as Dictionary).get(clip_key, {})
	if animation.is_empty():
		# The clip is still loading: ask again and try shortly.
		_request_clip(actor, clip_key)
		combat.cooldown = 0.15
		return
	combat.state = "swing"
	combat.clip = clip_key
	combat.time = float(animation.get("start_time", 0.0))
	combat.hit_done = false
	combat.power = clip_key.ends_with("power")
	_apply_actor_fatigue(actor, _attack_fatigue_cost(actor))
	if _actor_fatigue_current(actor) <= 0.0:
		_begin_knockdown(actor)
		return
	actor["combat_anim"] = clip_key
	actor["animation_time"] = combat.time
	actor["active_animation"] = ""

func _update_swing(actor: Dictionary, root: Node3D, player: CollisionObject3D, target_actor: Dictionary, combat: Dictionary, delta: float, flat: Vector2) -> void:
	var animation: Dictionary = (actor.animations as Dictionary).get(str(combat.clip), {})
	if animation.is_empty():
		combat.state = "chase"
		return
	_face(root, flat, delta)
	var previous := float(combat.time)
	combat.time = previous + delta
	if not bool(combat.hit_done):
		var hit_time := _hit_time(animation)
		if previous < hit_time and float(combat.time) >= hit_time:
			combat.hit_done = true
			_land_hit(actor, root, player, target_actor, combat)
	if float(combat.time) >= float(animation.get("stop_time", 0.0)):
		combat.state = "chase"
		combat.repath = 0.0
		combat.cooldown = randf_range(NPC_ATTACK_RECOVERY_MIN_S, NPC_ATTACK_RECOVERY_MAX_S)
		actor["combat_anim"] = _prefix(actor) + "idle"

## The time of the clip's "Hit" key (a bow's "Release"), or just past half the clip when it has none.
func _hit_time(animation: Dictionary) -> float:
	for key_value: Variant in animation.get("text_keys", []):
		var key: Dictionary = key_value
		var key_name := str(key.get("name", "")).to_lower()
		if key_name == "hit" or key_name == "release":
			return float(key.get("time", 0.0))
	var start := float(animation.get("start_time", 0.0))
	return start + (float(animation.get("stop_time", start)) - start) * 0.55

func _land_hit(actor: Dictionary, root: Node3D, player: CollisionObject3D, target_actor: Dictionary, combat: Dictionary) -> void:
	if _is_archer(actor):
		_loose_arrow(actor, root, player, target_actor)
		return
	var distance := Vector2(player.global_position.x - root.global_position.x, player.global_position.z - root.global_position.z).length()
	if distance > _reach_m(actor) + HIT_REACH_SLACK_M:
		return
	var damage := _damage(actor) * (POWER_ATTACK_DAMAGE_MULT if bool(combat.get("power", false)) else 1.0)
	if target_actor.is_empty():
		_hurt_player(actor, root, player as CharacterBody3D, damage)
	else:
		receive_actor_hit(target_actor, actor, damage)

func _hurt_player(actor: Dictionary, root: Node3D, player: CharacterBody3D, damage: float, projectile_hit := false) -> void:
	var blocking: bool = host.call("is_player_blocking")
	var blocked := false
	if blocking:
		var from_actor := (root.global_position - player.global_position)
		from_actor.y = 0.0
		var camera: Camera3D = player.get("camera")
		var view_forward := -camera.global_basis.z if camera != null else -player.global_basis.z
		view_forward.y = 0.0
		if from_actor.length() > 0.01 and view_forward.length() > 0.01 and from_actor.normalized().dot(view_forward.normalized()) > 0.3:
			blocked = true
			damage *= BLOCKED_DAMAGE_SHARE
	var audio_manager := host.get_node_or_null("/root/AudioManager") as Node
	if audio_manager != null:
		if blocked:
			audio_manager.call("play_weapon_block", player, int(host.call("_player_weapon_type")))
		elif not projectile_hit:
			audio_manager.call(
				"play_weapon_impact", player.global_position + Vector3.UP, _weapon_type(actor), true, player
			)
	var fatigue_damage := maxf(8.0 if blocked else FATIGUE_HIT_MIN, damage * FATIGUE_HIT_COST_MULT)
	host.call("_player_take_combat_hit", root, damage, fatigue_damage, blocked, int(actor.get("base_form_id", 0)))
	player_hit.emit(str(actor.get("reference_name", "NPC")), damage)

func _player_base_form_id() -> int:
	var player_base: Dictionary = host.get("_player_base_record")
	return int(player_base.get("form_id", 0))

func _combat_target_base_form_id(reference_id: int) -> int:
	if reference_id == 0:
		return _player_base_form_id()
	for actor: Dictionary in host.get("_npc_actors"):
		if int(actor.get("reference_id", 0)) == reference_id:
			return int(actor.get("base_form_id", 0))
	return 0

func _loose_arrow(actor: Dictionary, root: Node3D, player: CollisionObject3D, target_actor: Dictionary) -> void:
	var audio_manager := host.get_node_or_null("/root/AudioManager") as Node
	if audio_manager != null:
		audio_manager.call("play_bow_shot", root)
	var meshes := await CombatProjectile.build_arrow_meshes(host.get("assets"), float(host.get("game_units_to_meters")))
	if meshes.is_empty() or not is_instance_valid(root) or not is_instance_valid(player):
		return
	var origin := root.global_position + Vector3.UP * SIGHT_EYE_HEIGHT_M
	var camera: Camera3D = player.get("camera")
	var target := (camera.global_position if camera != null else player.global_position + Vector3.UP * SIGHT_EYE_HEIGHT_M) + Vector3.DOWN * 0.3
	var direction := (target - origin).normalized()
	# Lob it slightly up to make up for the drop over the flight.
	var flight_s := origin.distance_to(target) / ARROW_SPEED_MPS
	direction.y += 0.5 * CombatProjectile.ARROW_GRAVITY_MPS2 * flight_s * flight_s / maxf(origin.distance_to(target), 1.0)
	direction = direction.normalized()
	var arrow := CombatProjectile.new_arrow(meshes, direction * ARROW_SPEED_MPS)
	var excluded: Array[RID] = [(root as CollisionObject3D).get_rid()]
	arrow.excluded_bodies = excluded
	var damage := _damage(actor)
	arrow.connect(&"impacted", func(hit_position: Vector3, collider: Object) -> void:
		var impact_audio := host.get_node_or_null("/root/AudioManager") as Node
		if impact_audio != null:
			impact_audio.call("play_arrow_impact", hit_position)
		if collider == player and is_instance_valid(root):
			if target_actor.is_empty():
				_hurt_player(actor, root, player as CharacterBody3D, damage, true)
			else:
				receive_actor_hit(target_actor, actor, damage)
	)
	host.add_child(arrow)
	arrow.global_position = origin
	arrow.look_at(origin + direction)

## Loads a combat clip into the actor's animations (the first sequence of the original KF), once.
func _request_clip(actor: Dictionary, clip_name: String) -> void:
	var animations: Dictionary = actor.animations
	var requested: Dictionary = actor.get("combat_clips_requested", {})
	if animations.has(clip_name) or requested.has(clip_name):
		return
	requested[clip_name] = true
	actor["combat_clips_requested"] = requested
	var path := CLIP_FOLDER + clip_name + ".kf"
	var assets = host.get("assets")
	await assets.meshes_for_model(path)
	var skeleton := actor.get("skeleton") as Skeleton3D
	if not is_instance_valid(skeleton):
		return
	var metadata: Dictionary = assets.nif_metadata_cache.get(path.to_lower(), {})
	var sequences: Array = metadata.get("animations", [])
	if sequences.is_empty():
		return
	var animation: Dictionary = (host.call("_animation_sequence", path, str((sequences[0] as Dictionary).get("name", "")), skeleton) as Dictionary).duplicate()
	if animation.is_empty():
		return
	animation["loops"] = int(animation.get("cycle_type", 0)) == 0
	animations[clip_name] = animation
