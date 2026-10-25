extends RefCounted
## Hostile actors. An actor starts a fight with the player when a script orders it (StartCombat), when the player has
## attacked it, or when it is aggressive enough to attack on sight: Oblivion's aggression runs from 0 (never) through
## 5 (aggressive: only enemies) and 50 (very aggressive: anyone not a friend) to 100 (frenzied), and the player has no
## friends yet, so from 50 up an actor that sees the player attacks. It then draws its weapon, runs at the player along
## the navigation path and swings (or, with a bow, shoots from a distance) with the original combat clips; the hit lands
## at the clip's "Hit" or "Release" key and costs the player health.

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
const CLIP_FOLDER := "Characters/_male/"
## How far past its reach a swing still lands, and how a block cuts the damage of a hit from the front.
const HIT_REACH_SLACK_M := 0.5
const BLOCKED_DAMAGE_SHARE := 0.3
const POWER_ATTACK_CHANCE := 0.2
const POWER_ATTACK_DAMAGE_MULT := 1.5
const UNARMED_DAMAGE := 4.0
const UNARMED_REACH_M := 1.4
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
var _forced: Dictionary = {}
var _provoked: Dictionary = {}
var _calmed: Dictionary = {}
var _player_dead := false

func _init(host_node: Node3D) -> void:
	host = host_node

## A script ordered the actor to fight the player (StartCombat).
func force_combat(reference_id: int) -> void:
	_forced[reference_id] = true
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
		if not is_instance_valid(root) or bool(root.get("inactive")) or not root.visible:
			continue
		if actor.has("combat"):
			if _player_dead:
				_end_combat(actor)
			else:
				_update_combat(actor, root, player, delta)
		elif check_starts and not _player_dead and _wants_to_fight(actor, root, player):
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
		if aggression < AGGRESSION_ATTACKS_ON_SIGHT:
			return false
		if distance > (DETECT_RADIUS_FRENZIED_M if aggression >= 80 else DETECT_RADIUS_M):
			return false
	elif distance > LOSE_INTEREST_M:
		return false
	return ordered or _sees_player(root, player)

func _sees_player(root: Node3D, player: CharacterBody3D) -> bool:
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

func _begin_combat(actor: Dictionary, root: Node3D) -> void:
	actor["combat"] = {"state": "chase", "repath": 0.0, "cooldown": 0.0, "clip": "", "time": 0.0, "hit_done": true}
	actor["combat_anim"] = ""
	_set_weapon_drawn(actor, true)
	var prefix := _prefix(actor)
	var suffixes: Array[String] = ["idle", "fastforward", "forward"]
	suffixes.append_array(_attack_suffixes(prefix))
	for suffix: String in suffixes:
		_request_clip(actor, prefix + suffix)
	_stop_route(root)
	_cancel_package_route(actor)
	print("OpenOB combat: %s attacks the player (aggression %d, weapon type %d)" % [
		str(actor.get("reference_name", "NPC")), _aggression(actor), _weapon_type(actor)
	])

func _end_combat(actor: Dictionary) -> void:
	var root := actor.get("root") as Node3D
	actor.erase("combat")
	actor.erase("combat_anim")
	_set_weapon_drawn(actor, false)
	if is_instance_valid(root):
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
	var to_player := player.global_position - root.global_position
	var flat := Vector2(to_player.x, to_player.z)
	var distance := flat.length()
	if distance > LOSE_INTEREST_M or bool(host.get("_dialogue_active")):
		_end_combat(actor)
		return
	combat.cooldown = maxf(float(combat.cooldown) - delta, 0.0)
	var prefix := _prefix(actor)
	if str(combat.state) == "swing":
		_update_swing(actor, root, player, combat, delta, flat)
		return
	var archer := _is_archer(actor)
	var in_attack_range := distance <= (ARCHER_RANGE_M if archer else _reach_m(actor) * 0.85)
	if archer:
		in_attack_range = in_attack_range and distance >= ARCHER_MIN_RANGE_M and _sees_player(root, player)
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
		_chase(actor, root, player, archer)
	var speed := Vector2(root.velocity.x, root.velocity.z).length()
	actor["combat_anim"] = prefix + ("fastforward" if speed > RUNNING_ANIMATION_SPEED_MPS else "forward")

func _chase(actor: Dictionary, root: Node3D, player: CharacterBody3D, archer: bool) -> void:
	var arrival := (ARCHER_RANGE_M * 0.7) if archer else _reach_m(actor) * 0.6
	var path: PackedVector3Array = host.get("director").call(
		"navigation_path", root.global_position, player.global_position, host.call("_actor_collision_radius", root), false, arrival
	)
	var waypoints: Array[Dictionary] = []
	if path.is_empty():
		waypoints.push_back({"position": player.global_position, "speed_mps": RUN_SPEED_MPS})
	else:
		waypoints = host.call("_navigation_waypoints", path, RUN_SPEED_MPS)
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
	actor["combat_anim"] = clip_key
	actor["animation_time"] = combat.time
	actor["active_animation"] = ""

func _update_swing(actor: Dictionary, root: Node3D, player: CharacterBody3D, combat: Dictionary, delta: float, flat: Vector2) -> void:
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
			_land_hit(actor, root, player, combat)
	if float(combat.time) >= float(animation.get("stop_time", 0.0)):
		combat.state = "chase"
		combat.repath = 0.0
		combat.cooldown = randf_range(0.3, 0.9)
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

func _land_hit(actor: Dictionary, root: Node3D, player: CharacterBody3D, combat: Dictionary) -> void:
	if _is_archer(actor):
		_loose_arrow(actor, root, player)
		return
	var distance := Vector2(player.global_position.x - root.global_position.x, player.global_position.z - root.global_position.z).length()
	if distance > _reach_m(actor) + HIT_REACH_SLACK_M:
		return
	var damage := _damage(actor) * (POWER_ATTACK_DAMAGE_MULT if bool(combat.get("power", false)) else 1.0)
	_hurt_player(actor, root, player, damage)

func _hurt_player(actor: Dictionary, root: Node3D, player: CharacterBody3D, damage: float) -> void:
	var blocking: bool = host.call("is_player_blocking")
	if blocking:
		var from_actor := (root.global_position - player.global_position)
		from_actor.y = 0.0
		var camera: Camera3D = player.get("camera")
		var view_forward := -camera.global_basis.z if camera != null else -player.global_basis.z
		view_forward.y = 0.0
		if from_actor.length() > 0.01 and view_forward.length() > 0.01 and from_actor.normalized().dot(view_forward.normalized()) > 0.3:
			damage *= BLOCKED_DAMAGE_SHARE
	(host.get("_player_actor_values") as RefCounted).call("apply_damage", damage)
	player_hit.emit(str(actor.get("reference_name", "NPC")), damage)

func _loose_arrow(actor: Dictionary, root: Node3D, player: CharacterBody3D) -> void:
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
	arrow.impacted.connect(func(_hit_position: Vector3, collider: Object) -> void:
		if collider == player and is_instance_valid(root):
			_hurt_player(actor, root, player, damage)
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
