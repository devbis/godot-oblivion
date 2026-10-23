extends RefCounted
## Acquires the object under the screen center and classifies it into one target snapshot. The HUD draws the snapshot and
## the interact key acts on it, so the displayed target and the activated target are the same object.
##
## Snapshot fields: kind (none|item|container|door|npc), reference_id (-1 when absent), display_name,
## action (none|take|enter|locked|talk|attack|open), reticle_icon (0 = default crosshair), crime, locked,
## lock_level (-1 when unavailable), enemy_health_ratio (negative when unavailable), plus the source record
## (`reference`/`item`) for the executor.

## Prototype ranges, not verified Oblivion measurements.
var item_range_m := 1.8
var actor_range_m := 2.5
var door_range_m := 2.5
var container_range_m := 1.8
var reach_origin_height_m := 0.9
## Layers: 2 world references, 4 NPCs, 8 pickup areas, 16 doors/extra.
var collision_mask := 2 | 4 | 8 | 16

## Activation atlas cell per kind/action. Provisional visual inferences (see docs/hud-and-interactions-plan.md); the only
## place that maps a target to an icon. 0 is the default crosshair.
const RETICLE_ICONS := {
	"item": 1,
	"container": 2,
	"door": 8,
	"npc": 11,
	"npc_attack": 12,
}

const KIND_NONE := "none"

var player: CharacterBody3D
var world_host: Node3D
## Callables supplied by the owner: (reference_id: int) -> Dictionary; empty dictionary when the id is not that kind.
var item_lookup := Callable()
var door_lookup := Callable()
var container_lookup := Callable()
## (collider: Node) -> Dictionary of the NPC actor owning that collider, or {}.
var actor_lookup := Callable()

static func empty_snapshot() -> Dictionary:
	return {
		"kind": KIND_NONE,
		"reference_id": -1,
		"display_name": "",
		"action": "none",
		"reticle_icon": 0,
		"crime": false,
		"locked": false,
		"lock_level": -1,
		"enemy_health_ratio": -1.0,
	}

static func icon_for(kind: String, action: String) -> int:
	if kind == "npc" and action == "attack":
		return int(RETICLE_ICONS["npc_attack"])
	return int(RETICLE_ICONS.get(kind, 0))

func _snapshot(kind: String, action: String, reference_id: int, display_name: String, extra: Dictionary = {}) -> Dictionary:
	var snapshot := empty_snapshot()
	snapshot["kind"] = kind
	snapshot["action"] = action
	snapshot["reference_id"] = reference_id
	snapshot["display_name"] = display_name
	snapshot["reticle_icon"] = icon_for(kind, action)
	if bool(extra.get("locked", false)):
		snapshot["locked"] = true
		snapshot["lock_level"] = int(extra.get("lock_level", -1))
	for key: Variant in extra.keys():
		if not snapshot.has(key) or key in ["crime", "enemy_health_ratio"]:
			snapshot[key] = extra[key]
	return snapshot

func acquire() -> Dictionary:
	if player == null or world_host == null:
		return empty_snapshot()
	var camera := player.get_node_or_null("CameraPivot/Camera3D") as Camera3D
	if camera == null or not camera.current:
		return empty_snapshot()
	var screen_center := world_host.get_viewport().get_visible_rect().get_center()
	var ray_origin := camera.project_ray_origin(screen_center)
	var ray_direction := camera.project_ray_normal(screen_center)
	# The ray starts at the camera, but reach is the player's: the ranges are measured from the player's body, and the ray is
	# long enough to cover the camera's distance behind (or in front of) the player.
	var reach_origin := player.global_position + Vector3.UP * reach_origin_height_m
	var max_reach := maxf(maxf(item_range_m, container_range_m), maxf(door_range_m, actor_range_m))
	var query := PhysicsRayQueryParameters3D.create(
		ray_origin,
		ray_origin + ray_direction * (max_reach + ray_origin.distance_to(reach_origin)),
		collision_mask,
		[player.get_rid()]
	)
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := world_host.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return empty_snapshot()
	var collider := hit.get("collider") as Node
	if collider == null:
		return empty_snapshot()
	var hit_position: Vector3 = hit.get("position", ray_origin)
	# A hit behind the player (the third-person camera looks past the player) is not reachable.
	if ray_direction.dot(hit_position - reach_origin) <= 0.0:
		return empty_snapshot()
	var hit_distance := reach_origin.distance_to(hit_position)
	var reference_id := int(collider.get_meta("reference_id", 0))

	if item_lookup.is_valid():
		var item: Dictionary = item_lookup.call(reference_id)
		if not item.is_empty():
			if hit_distance > item_range_m:
				return empty_snapshot()
			# Ownership/crime data is not parsed yet, so crime stays false.
			return _snapshot("item", "take", reference_id,
				str(item.get("display_name", item.get("editor_id", "item"))), {"item": item})
	if actor_lookup.is_valid():
		var actor: Dictionary = actor_lookup.call(collider)
		if not actor.is_empty():
			if hit_distance > actor_range_m:
				return empty_snapshot()
			# No hostility data is available yet: every NPC is treated as talkable.
			var action := "attack" if bool(actor.get("hostile", false)) else "talk"
			return _snapshot("npc", action, reference_id,
				str(actor.get("display_name", actor.get("name", "NPC"))), {"actor": actor})
	if door_lookup.is_valid():
		var door: Dictionary = door_lookup.call(reference_id)
		if not door.is_empty():
			if hit_distance > door_range_m:
				return empty_snapshot()
			var reference: Dictionary = door.get("reference", {})
			var display_name := str(reference.get("reference_name", ""))
			if display_name.is_empty():
				display_name = str(reference.get("base_editor_id", "Door"))
			if display_name.is_empty():
				display_name = "Door"
			var lock_level := int(reference.get("lock_level", 0))
			var locked := lock_level > 0
			var door_action := "locked" if locked else ("enter" if int(reference.get("teleport_cell_id", 0)) != 0 else "open")
			return _snapshot("door", door_action, reference_id, display_name, {
				"reference": reference,
				"locked": locked,
				"lock_level": lock_level,
			})
	if container_lookup.is_valid():
		var container: Dictionary = container_lookup.call(reference_id)
		if not container.is_empty():
			if hit_distance > container_range_m:
				return empty_snapshot()
			var container_reference: Dictionary = container.get("reference", {})
			var container_name := str(container.get("display_name", container_reference.get("base_editor_id", "Container")))
			var container_lock := int(container_reference.get("lock_level", 0))
			# Container contents are not available yet, so the action is a take-like placeholder with no effect.
			return _snapshot("container", "take", reference_id, container_name, {
				"reference": container_reference,
				"locked": container_lock > 0,
				"lock_level": container_lock,
			})
	return empty_snapshot()
