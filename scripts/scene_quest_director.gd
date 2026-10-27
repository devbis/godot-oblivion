extends RefCounted
## Scene-level support for quests and NPC routes: the placed doors of the loaded cell and the navigation tiles baked
## from the cell's collision, with path planning through doorways.

## The scene root: parents the navigation tiles, owns the physics world and holds the player node.
var scene: Node3D

func _init(scene_root: Node3D) -> void:
	scene = scene_root

## Door bounds let navigation plan a route through a doorway. The door itself stays
## solid until an NPC route reaches it and asks the door controller to open it.
var door_boxes: Array[AABB] = []
var door_references: Array[Dictionary] = []
var door_reference_lookup_cache: Dictionary = {}

var door_registered_ids: Dictionary = {}

func clear_door_references() -> void:
	door_boxes.clear()
	door_references.clear()
	door_reference_lookup_cache.clear()
	door_registered_ids.clear()

## Records one placed DOOR reference once its meshes are known (called while the cell geometry loads, so doors exist
## whether or not an NPC is near).
func register_door_reference(reference: Dictionary, meshes: Array, reference_transform: Transform3D) -> void:
	var reference_id := int(reference.get("form_id", 0))
	if door_registered_ids.has(reference_id):
		return
	var box := AABB()
	var has_box := false
	for mesh_entry: Dictionary in meshes:
		var mesh := mesh_entry.get("mesh") as Mesh
		if mesh == null:
			continue
		box = mesh.get_aabb() if not has_box else box.merge(mesh.get_aabb())
		has_box = true
	if not has_box:
		return
	var world_box := reference_transform * box
	door_registered_ids[reference_id] = true
	door_boxes.push_back(world_box)
	var door := {
		"reference": reference,
		"box": world_box,
		"local_box": box,
		"transform": reference_transform,
	}
	door_references.push_back(door)
	door_reference_lookup_cache[reference_id] = door

func in_door_box(point: Vector3) -> bool:
	for box: AABB in door_boxes:
		if box.has_point(point):
			return true
	return false

const NAVIGATION_TILE_SIZE_M := 25.6
const NAVIGATION_TILE_OVERLAP_M := 2.0
const MAX_PATHGRID_ENDPOINT_SNAP_DISTANCE_M := 2.5
const MAX_TELEPORT_EXIT_SNAP_DISTANCE_M := 2.5
const LEDGE_DROP_MAX_HORIZONTAL_M := 6.0
const LEDGE_DROP_MIN_HEIGHT_M := 0.8
const LEDGE_DROP_MAX_HEIGHT_M := 4.0
const PREFERRED_PATHGRID_ENDPOINT_SNAP_DISTANCE_M := 0.75
const PATHGRID_NAVIGATION_LAYER := 2
const NPC_NAVIGATION_LAYERS := 1 | PATHGRID_NAVIGATION_LAYER
const PATHGRID_LINK_CONNECTION_RADIUS_M := 0.18
const PATHGRID_LINK_ENDPOINT_TOLERANCE_M := 0.15
## The navigation regions of the loaded cell, one per tile (OpenMW bakes its navigation mesh the same way).
var navigation_tiles: Node3D = null
var pathgrid_links_root: Node3D = null
var pathgrid_cell_form_id := 0
var navigation_cell_form_id := 0
var game_units_to_meters := 0.01
var pathgrid_points: PackedVector3Array = PackedVector3Array()
var pathgrid_neighbors: Array = []
var last_navigation_path_uses_pathgrid := false
## Indices in the most recent route path where an actor crosses a linked door, and their XTEL arrival positions.
var last_navigation_path_teleports: Dictionary = {}

func set_pathgrid(pathgrid: Dictionary, game_units_scale: float, cell_form_id: int = 0) -> void:
	clear_pathgrid()
	navigation_cell_form_id = cell_form_id
	game_units_to_meters = game_units_scale
	var source_points: PackedVector3Array = pathgrid.get("points", PackedVector3Array())
	var edges: PackedInt32Array = pathgrid.get("edges", PackedInt32Array())
	if source_points.is_empty() or edges.is_empty():
		return
	pathgrid_cell_form_id = int(pathgrid.get("cell_form_id", 0))
	pathgrid_points.resize(source_points.size())
	pathgrid_neighbors.resize(source_points.size())
	for index in range(source_points.size()):
		pathgrid_points[index] = _pathgrid_world_position(source_points[index], game_units_to_meters)
		pathgrid_neighbors[index] = PackedInt32Array()
	pathgrid_links_root = Node3D.new()
	pathgrid_links_root.name = "PathGridLinks_%08X" % pathgrid_cell_form_id
	scene.add_child(pathgrid_links_root)
	var navigation_map := scene.get_world_3d().navigation_map
	NavigationServer3D.map_set_link_connection_radius(navigation_map, PATHGRID_LINK_CONNECTION_RADIUS_M)
	var edge_count := 0
	var link_count := 0
	for edge_index in range(0, edges.size() - 1, 2):
		var from_index := edges[edge_index]
		var to_index := edges[edge_index + 1]
		if from_index < 0 or from_index >= pathgrid_neighbors.size() \
				or to_index < 0 or to_index >= pathgrid_neighbors.size() or from_index == to_index:
			continue
		var neighbors: PackedInt32Array = pathgrid_neighbors[from_index]
		neighbors.push_back(to_index)
		pathgrid_neighbors[from_index] = neighbors
		var link := NavigationLink3D.new()
		link.name = "PGRD_%d_%d" % [from_index, to_index]
		link.bidirectional = false
		link.navigation_layers = PATHGRID_NAVIGATION_LAYER
		pathgrid_links_root.add_child(link)
		link.set_global_start_position(pathgrid_points[from_index])
		link.set_global_end_position(pathgrid_points[to_index])
		edge_count += 1
		link_count += 1
	print("OpenOB navigation: loaded cell PGRD 0x%08X with %d nodes, %d directed edges and %d nav links" % [
		pathgrid_cell_form_id, pathgrid_points.size(), edge_count, link_count
	])

func clear_pathgrid() -> void:
	if is_instance_valid(pathgrid_links_root):
		for child: Node in pathgrid_links_root.get_children():
			var link := child as NavigationLink3D
			if link != null:
				link.enabled = false
		pathgrid_links_root.queue_free()
	pathgrid_links_root = null
	pathgrid_cell_form_id = 0
	pathgrid_points.clear()
	pathgrid_neighbors.clear()
	last_navigation_path_uses_pathgrid = false
	navigation_cell_form_id = 0
	last_navigation_path_teleports.clear()

func _pathgrid_world_position(game_position: Vector3, game_units_to_meters: float) -> Vector3:
	return Vector3(game_position.x, game_position.z, -game_position.y) * game_units_to_meters

## Bakes the walkable surfaces of the loaded cell in tiles. Each tile takes the static triangles that touch it, with an
## overlap, so the tiles connect at their edges and stairs and floors on different levels join.
func build_navigation_tiles() -> void:
	var started_ms := Time.get_ticks_msec()
	clear_navigation_tiles()
	var bodies: Array = []
	_collect_static_bodies(scene, bodies)
	var triangles := PackedVector3Array()
	for body: StaticBody3D in bodies:
		for child: Node in body.get_children():
			var shape_node := child as CollisionShape3D
			if shape_node == null or not (shape_node.shape is ConcavePolygonShape3D):
				continue
			var faces: PackedVector3Array = (shape_node.shape as ConcavePolygonShape3D).get_faces()
			var transform: Transform3D = body.global_transform * shape_node.transform
			for index in range(0, faces.size(), 3):
				var a := transform * faces[index]
				var b := transform * faces[index + 1]
				var c := transform * faces[index + 2]
				# Let route planning continue through the doorway. The physical door body remains active until the NPC route
				# reaches it and opens the reference, while the floor under the doorway stays in the walkable mesh.
				var normal := (b - a).cross(c - a).normalized()
				if absf(normal.y) < 0.7 and in_door_box((a + b + c) / 3.0):
					continue
				triangles.push_back(a)
				triangles.push_back(b)
				triangles.push_back(c)
	if triangles.is_empty():
		return
	var lowest := triangles[0]
	var highest := triangles[0]
	for vertex: Vector3 in triangles:
		lowest = Vector3(minf(lowest.x, vertex.x), minf(lowest.y, vertex.y), minf(lowest.z, vertex.z))
		highest = Vector3(maxf(highest.x, vertex.x), maxf(highest.y, vertex.y), maxf(highest.z, vertex.z))
	navigation_tiles = Node3D.new()
	navigation_tiles.name = "NavigationTiles"
	scene.add_child(navigation_tiles)
	NavigationServer3D.map_set_edge_connection_margin(scene.get_world_3d().navigation_map, 1.0)
	var columns := int(ceil((highest.x - lowest.x) / NAVIGATION_TILE_SIZE_M))
	var rows := int(ceil((highest.z - lowest.z) / NAVIGATION_TILE_SIZE_M))
	var polygon_count := 0
	var tile_triangles := bin_triangles_into_tiles(triangles, lowest, columns, rows)
	for column in range(columns):
		for row in range(rows):
			var tile: PackedVector3Array = tile_triangles.get(column * rows + row, PackedVector3Array())
			if tile.is_empty():
				continue
			var geometry := NavigationMeshSourceGeometryData3D.new()
			geometry.add_faces(tile, Transform3D.IDENTITY)
			var nav_mesh := NavigationMesh.new()
			nav_mesh.agent_radius = 0.18
			var player_collision := scene.player.get_node_or_null("CollisionShape3D") as CollisionShape3D
			var player_capsule := player_collision.shape as CapsuleShape3D if player_collision != null else null
			if player_capsule != null:
				nav_mesh.agent_height = player_capsule.height
			nav_mesh.agent_max_climb = 0.4
			nav_mesh.agent_max_slope = 55.0
			nav_mesh.cell_size = 0.2
			nav_mesh.cell_height = 0.2
			NavigationServer3D.bake_from_source_geometry_data(nav_mesh, geometry)
			polygon_count += nav_mesh.get_polygon_count()
			var region := NavigationRegion3D.new()
			region.navigation_mesh = nav_mesh
			navigation_tiles.add_child(region)
	print("OpenOB navigation: %d tiles, %d polygons in %d ms" % [
		navigation_tiles.get_child_count(), polygon_count, Time.get_ticks_msec() - started_ms
	])
	# The navigation map takes the new regions on its next physics frames.
	await scene.get_tree().physics_frame
	await scene.get_tree().physics_frame

## Sorts the triangles into the tiles whose overlapped rectangle they touch, keyed by `column * rows + row`. Each
## triangle is visited once rather than once per tile, so a cell with a distant collider and many empty tiles stays cheap.
## The bake expects the opposite winding to the one the collision faces come with, so the vertices go in as a, c, b.
static func bin_triangles_into_tiles(
	triangles: PackedVector3Array, lowest: Vector3, columns: int, rows: int
) -> Dictionary:
	var tiles := {}
	for index in range(0, triangles.size(), 3):
		var a := triangles[index]
		var b := triangles[index + 1]
		var c := triangles[index + 2]
		var column_from := _first_touching_tile(minf(a.x, minf(b.x, c.x)), lowest.x)
		var column_to := _last_touching_tile(maxf(a.x, maxf(b.x, c.x)), lowest.x)
		var row_from := _first_touching_tile(minf(a.z, minf(b.z, c.z)), lowest.z)
		var row_to := _last_touching_tile(maxf(a.z, maxf(b.z, c.z)), lowest.z)
		for column in range(maxi(column_from, 0), mini(column_to, columns - 1) + 1):
			for row in range(maxi(row_from, 0), mini(row_to, rows - 1) + 1):
				var key := column * rows + row
				if not tiles.has(key):
					tiles[key] = PackedVector3Array()
				# Indexing the dictionary appends in place; a local copy would be duplicated on every push.
				tiles[key].push_back(a)
				tiles[key].push_back(c)
				tiles[key].push_back(b)
	return tiles

# Tile `n` spans [origin + n * size - overlap, origin + (n + 1) * size + overlap].
static func _first_touching_tile(minimum: float, origin: float) -> int:
	return int(ceil((minimum - origin - NAVIGATION_TILE_OVERLAP_M) / NAVIGATION_TILE_SIZE_M)) - 1

static func _last_touching_tile(maximum: float, origin: float) -> int:
	return int(floor((maximum - origin + NAVIGATION_TILE_OVERLAP_M) / NAVIGATION_TILE_SIZE_M))

func clear_navigation_tiles() -> void:
	if is_instance_valid(navigation_tiles):
		navigation_tiles.queue_free()
	navigation_tiles = null
	clear_pathgrid()

func _collect_static_bodies(node: Node, bodies: Array) -> void:
	if node is StaticBody3D:
		bodies.push_back(node)
	for child: Node in node.get_children():
		_collect_static_bodies(child, bodies)

## Finds a path over the navigation tiles. If a closed door split the baked mesh,
## join reachable paths on both sides through that door's actual opening.
func navigation_path(
	from: Vector3, to: Vector3, actor_radius: float = 0.18, prefer_authored_pathgrid: bool = false,
	destination_arrival_distance: float = 0.35
) -> PackedVector3Array:
	last_navigation_path_uses_pathgrid = false
	last_navigation_path_teleports.clear()
	if prefer_authored_pathgrid:
		var authored_path := _pathgrid_route(from, to, PREFERRED_PATHGRID_ENDPOINT_SNAP_DISTANCE_M)
		if not authored_path.is_empty():
			last_navigation_path_uses_pathgrid = true
			return authored_path
	var navigation_map := scene.get_world_3d().navigation_map
	var path := NavigationServer3D.map_get_path(navigation_map, from, to, true, NPC_NAVIGATION_LAYERS)
	if path.is_empty():
		var disconnected_path := _pathgrid_route(from, to)
		if not disconnected_path.is_empty():
			last_navigation_path_uses_pathgrid = true
			return disconnected_path
		var teleport_path := _teleport_route(
			navigation_map, from, to, actor_radius, destination_arrival_distance
		)
		if not teleport_path.is_empty():
			last_navigation_path_uses_pathgrid = _path_uses_pathgrid_link(teleport_path)
			return teleport_path
		return PackedVector3Array([to])
	var goal_on_mesh := NavigationServer3D.map_get_closest_point(navigation_map, to)
	if _path_reaches_target(path, to, goal_on_mesh, actor_radius, destination_arrival_distance):
		last_navigation_path_uses_pathgrid = _path_uses_pathgrid_link(path)
		return path
	var best_path := PackedVector3Array()
	var best_length := INF
	for door: Dictionary in door_references:
		var portal := _door_portal_points(door, from, to, actor_radius)
		if portal.is_empty():
			continue
		var near_point: Vector3 = portal.get("near", Vector3.ZERO)
		var far_point: Vector3 = portal.get("far", Vector3.ZERO)
		var near_on_mesh := NavigationServer3D.map_get_closest_point(navigation_map, near_point)
		var far_on_mesh := NavigationServer3D.map_get_closest_point(navigation_map, far_point)
		var approach := NavigationServer3D.map_get_path(
			navigation_map, from, near_point, true, NPC_NAVIGATION_LAYERS
		)
		if approach.is_empty() or not _path_reaches(approach, near_on_mesh):
			continue
		var departure := NavigationServer3D.map_get_path(
			navigation_map, far_point, to, true, NPC_NAVIGATION_LAYERS
		)
		if departure.is_empty() or not (
			_path_reaches_target(departure, to, goal_on_mesh, actor_radius, destination_arrival_distance)
			or _path_ends_on_ledge_above(departure, to)
		):
			continue
		var candidate := PackedVector3Array()
		for point: Vector3 in approach:
			_append_path_point(candidate, point)
		_append_path_point(candidate, near_on_mesh)
		# The navmesh may be disconnected by the closed door collision. This leg
		# crosses the threshold; _open_doors_on_npc_routes opens this door as the
		# actor approaches it, before the collision body blocks the crossing.
		_append_path_point(candidate, far_on_mesh)
		for index in range(1, departure.size()):
			_append_path_point(candidate, departure[index])
		var candidate_length := _path_length(candidate)
		if candidate_length < best_length:
			best_length = candidate_length
			best_path = candidate
	if not best_path.is_empty():
		last_navigation_path_uses_pathgrid = _path_uses_pathgrid_link(best_path)
		return best_path
	var pathgrid_path := _pathgrid_route(from, to)
	if not pathgrid_path.is_empty():
		last_navigation_path_uses_pathgrid = true
		return pathgrid_path
	var teleport_path := _teleport_route(
		navigation_map, from, to, actor_radius, destination_arrival_distance
	)
	if not teleport_path.is_empty():
		last_navigation_path_uses_pathgrid = _path_uses_pathgrid_link(teleport_path)
		return teleport_path
	var ledge_path := _route_to_ledge_above(from, to, actor_radius, destination_arrival_distance)
	if not ledge_path.is_empty():
		return ledge_path
	return best_path if not best_path.is_empty() else path

var _resolving_ledge := false

## The destination cannot be reached: a marker in a hall below the ledge an actor's room opens onto. The route goes to the
## pathgrid node nearest the destination that lies above it and can be walked to; the caller finishes with a drop.
func _route_to_ledge_above(from: Vector3, to: Vector3, actor_radius: float, arrival: float) -> PackedVector3Array:
	if _resolving_ledge:
		return PackedVector3Array()
	var candidates: Array[Dictionary] = []
	for index in range(pathgrid_points.size()):
		var node := pathgrid_points[index]
		if _path_ends_on_ledge_above(PackedVector3Array([node]), to):
			candidates.push_back({"position": node, "distance": node.distance_to(to)})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.distance) < float(b.distance))
	_resolving_ledge = true
	var result := PackedVector3Array()
	for candidate: Dictionary in candidates:
		var node_position: Vector3 = candidate.position
		var route := navigation_path(from, node_position, actor_radius, true, arrival)
		if not route.is_empty():
			var end := route[route.size() - 1]
			if Vector2(end.x - node_position.x, end.z - node_position.z).length() <= 0.5:
				result = route
				break
	_resolving_ledge = false
	return result

## Finds a navmesh route that crosses one or more linked doors in this cell. An XTEL
## link changes position discontinuously, so its entry and exit must not be joined
## by a walkable navmesh segment.
func _teleport_route(
	navigation_map: RID, from: Vector3, to: Vector3, actor_radius: float,
	destination_arrival_distance: float
) -> PackedVector3Array:
	if navigation_cell_form_id == 0 or door_references.is_empty():
		return PackedVector3Array()
	var doors_by_id: Dictionary = {}
	for door: Dictionary in door_references:
		var reference: Dictionary = door.get("reference", {})
		var reference_id := int(reference.get("form_id", 0))
		if reference_id != 0:
			doors_by_id[reference_id] = door
	var goal_on_mesh := NavigationServer3D.map_get_closest_point(navigation_map, to)
	var pending: Array[Dictionary] = [{
		"node_id": 0,
		"position": from,
		"cost": 0.0,
		"path": PackedVector3Array(),
		"teleports": {},
		"used_doors": {},
	}]
	var best_cost_by_node: Dictionary = {0: 0.0}
	var best_path := PackedVector3Array()
	var best_teleports: Dictionary = {}
	var best_total_cost := INF
	while not pending.is_empty():
		var current_index := 0
		for index in range(1, pending.size()):
			if float(pending[index].get("cost", INF)) < float(pending[current_index].get("cost", INF)):
				current_index = index
		var current: Dictionary = pending.pop_at(current_index)
		var current_cost := float(current.get("cost", INF))
		if current_cost >= best_total_cost:
			continue
		var current_position: Vector3 = current.get("position", from)
		var current_path: PackedVector3Array = current.get("path", PackedVector3Array())
		var direct_path := NavigationServer3D.map_get_path(
			navigation_map, current_position, to, true, NPC_NAVIGATION_LAYERS
		)
		var direct_reaches_goal := _path_reaches_target(
			direct_path, to, goal_on_mesh, actor_radius, destination_arrival_distance
		)
		if not direct_reaches_goal:
			var authored_direct_path := _pathgrid_route(current_position, to)
			if not authored_direct_path.is_empty():
				direct_path = authored_direct_path
				direct_reaches_goal = true
		if direct_reaches_goal:
			var completed_path := current_path.duplicate()
			for point: Vector3 in direct_path:
				_append_path_point(completed_path, point)
			var total_cost := current_cost + _path_length(direct_path)
			if total_cost < best_total_cost:
				best_total_cost = total_cost
				best_path = completed_path
				best_teleports = (current.get("teleports", {}) as Dictionary).duplicate()
		for door: Dictionary in door_references:
			var reference: Dictionary = door.get("reference", {})
			var reference_id := int(reference.get("form_id", 0))
			var target_reference_id := int(reference.get("teleport_ref_id", 0))
			if reference_id == 0 or target_reference_id == 0 \
					or int(reference.get("teleport_cell_id", 0)) != navigation_cell_form_id \
					or int(reference.get("lock_level", 0)) > 0:
				continue
			var used_doors: Dictionary = current.get("used_doors", {})
			if used_doors.has(reference_id):
				continue
			var exit_door: Dictionary = doors_by_id.get(target_reference_id, {})
			if exit_door.is_empty():
				continue
			var teleport_position: PackedFloat32Array = reference.get("teleport_position", PackedFloat32Array())
			if teleport_position.size() < 3:
				continue
			var exit_position := Vector3(
				teleport_position[0], teleport_position[2], -teleport_position[1]
			) * game_units_to_meters
			var exit_on_mesh := NavigationServer3D.map_get_closest_point(navigation_map, exit_position)
			if exit_position.distance_to(exit_on_mesh) > MAX_TELEPORT_EXIT_SNAP_DISTANCE_M:
				continue
			var approach_options := _door_approach_paths(
				navigation_map, current_position, door, actor_radius
			)
			for approach: Dictionary in approach_options:
				var approach_path: PackedVector3Array = approach.get("path", PackedVector3Array())
				if approach_path.is_empty():
					continue
				var next_path := current_path.duplicate()
				for point: Vector3 in approach_path:
					_append_path_point(next_path, point)
				if next_path.is_empty():
					continue
				var event_index := next_path.size() - 1
				var next_teleports: Dictionary = (current.get("teleports", {}) as Dictionary).duplicate()
				next_teleports[event_index] = {"destination": exit_position, "reference_id": reference_id}
				var next_used_doors: Dictionary = used_doors.duplicate()
				next_used_doors[reference_id] = true
				_append_path_point(next_path, exit_position)
				var next_cost := current_cost + _path_length(approach_path) + 0.2
				var exit_node_id := target_reference_id
				if next_cost >= float(best_cost_by_node.get(exit_node_id, INF)):
					continue
				best_cost_by_node[exit_node_id] = next_cost
				pending.push_back({
					"node_id": exit_node_id,
					"position": exit_position,
					"cost": next_cost,
					"path": next_path,
					"teleports": next_teleports,
					"used_doors": next_used_doors,
				})
	if best_path.is_empty():
		return PackedVector3Array()
	last_navigation_path_teleports = best_teleports
	return best_path

## Returns approach paths from the current navmesh island to either side of a door.
func _door_approach_paths(
	navigation_map: RID, from: Vector3, door: Dictionary, actor_radius: float
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var local_box: AABB = door.get("local_box", AABB())
	var reference_transform: Transform3D = door.get("transform", Transform3D.IDENTITY)
	if local_box.size.x <= 0.0 or local_box.size.z <= 0.0:
		return result
	var normal_axis := 0 if local_box.size.x <= local_box.size.z else 2
	var normal_basis: Vector3 = reference_transform.basis.x if normal_axis == 0 else reference_transform.basis.z
	var normal_scale := normal_basis.length()
	if normal_scale <= 0.0001:
		return result
	var horizontal_normal := Vector3(normal_basis.x, 0.0, normal_basis.z).normalized()
	if horizontal_normal.length_squared() <= 0.0001:
		return result
	var center_local := local_box.position + local_box.size * 0.5
	var center := reference_transform * center_local
	center.y = from.y
	var half_thickness := local_box.size[normal_axis] * 0.5 * normal_scale
	for side: float in [-1.0, 1.0]:
		var approach_position: Vector3 = center + horizontal_normal * side * maxf(0.0, half_thickness + actor_radius - 0.08)
		var approach_on_mesh := NavigationServer3D.map_get_closest_point(navigation_map, approach_position)
		if approach_position.distance_to(approach_on_mesh) > actor_radius + 0.3:
			continue
		var path := NavigationServer3D.map_get_path(
			navigation_map, from, approach_position, true, NPC_NAVIGATION_LAYERS
		)
		if not _path_reaches(path, approach_on_mesh):
			continue
		var duplicate := false
		for existing: Dictionary in result:
			var existing_on_mesh: Vector3 = existing.get("position", Vector3.ZERO)
			if existing_on_mesh.distance_squared_to(approach_on_mesh) <= 0.01:
				duplicate = true
				break
		if not duplicate:
			result.push_back({"position": approach_on_mesh, "path": path})
	return result

func _pathgrid_route(
	from: Vector3, to: Vector3, max_endpoint_snap_distance: float = MAX_PATHGRID_ENDPOINT_SNAP_DISTANCE_M
) -> PackedVector3Array:
	var count := pathgrid_points.size()
	if count == 0 or pathgrid_neighbors.size() != count:
		return PackedVector3Array()
	var start_index := _nearest_pathgrid_point(from)
	var goal_index := _nearest_pathgrid_point(to)
	if start_index < 0 or goal_index < 0:
		return PackedVector3Array()
	var start_snap_distance := from.distance_to(pathgrid_points[start_index])
	var goal_snap_distance := to.distance_to(pathgrid_points[goal_index])
	if start_snap_distance > max_endpoint_snap_distance or goal_snap_distance > max_endpoint_snap_distance:
		return PackedVector3Array()
	var costs := PackedFloat32Array()
	costs.resize(count)
	var predecessors := PackedInt32Array()
	predecessors.resize(count)
	var visited := PackedByteArray()
	visited.resize(count)
	for index in range(count):
		costs[index] = INF
		predecessors[index] = -1
		visited[index] = 0
	costs[start_index] = 0.0
	for _iteration in range(count):
		var current := -1
		var current_cost := INF
		for index in range(count):
			if visited[index] == 0 and costs[index] < current_cost:
				current = index
				current_cost = costs[index]
		if current < 0 or current == goal_index:
			break
		visited[current] = 1
		var neighbors: PackedInt32Array = pathgrid_neighbors[current]
		for next_index: int in neighbors:
			if next_index < 0 or next_index >= count or visited[next_index] != 0:
				continue
			var candidate_cost := current_cost + pathgrid_points[current].distance_to(pathgrid_points[next_index])
			if candidate_cost < costs[next_index]:
				costs[next_index] = candidate_cost
				predecessors[next_index] = current
		if current_cost == INF:
			break
	if start_index != goal_index and predecessors[goal_index] < 0:
		return PackedVector3Array()
	var node_route: Array[int] = []
	var cursor := goal_index
	while cursor >= 0:
		node_route.push_front(cursor)
		if cursor == start_index:
			break
		cursor = predecessors[cursor]
	if node_route.is_empty() or node_route[0] != start_index:
		return PackedVector3Array()
	var result := PackedVector3Array()
	_append_path_point(result, from)
	for node_index: int in node_route:
		_append_path_point(result, pathgrid_points[node_index])
	_append_path_point(result, to)
	result = _drop_passed_start_nodes(result)
	# A chase plans a new path every few frames: say so once in a while.
	var now_msec := Time.get_ticks_msec()
	if now_msec - _last_pathgrid_log_msec >= 5000:
		_last_pathgrid_log_msec = now_msec
		print("OpenOB navigation: using cell PGRD 0x%08X nodes=%d snap=%.2f/%.2fm" % [
			pathgrid_cell_form_id, node_route.size(), start_snap_distance, goal_snap_distance
		])
	return result

var _last_pathgrid_log_msec := -5000

## A route re-planned on the move starts at the pathgrid node nearest the actor, which may lie behind it; walking back to it
## and turning round again is the stutter of a follower. The first nodes are dropped while the actor already stands past them
## on the way to the next, close to that leg (not round a corner, where cutting would go through a wall).
func _drop_passed_start_nodes(path: PackedVector3Array) -> PackedVector3Array:
	var trimmed := path
	while trimmed.size() > 2:
		var from := trimmed[0]
		var node := trimmed[1]
		var next := trimmed[2]
		var leg := Vector2(next.x - node.x, next.z - node.z)
		var leg_length := leg.length()
		if leg_length < 0.01:
			break
		var along := Vector2(from.x - node.x, from.z - node.z).dot(leg) / leg_length
		if along <= 0.0 or along >= leg_length:
			break
		var off_leg := absf(Vector2(from.x - node.x, from.z - node.z).cross(leg)) / leg_length
		if off_leg > PASSED_NODE_MAX_OFFSET_M:
			break
		trimmed.remove_at(1)
	return trimmed

const PASSED_NODE_MAX_OFFSET_M := 0.7

## The path ends on a ledge just above the target (a marker in a hall below the ledge a room opens onto): the caller
## finishes the last stretch with a drop.
func _path_ends_on_ledge_above(path: PackedVector3Array, target: Vector3) -> bool:
	if path.is_empty():
		return false
	var end := path[path.size() - 1]
	return Vector2(end.x - target.x, end.z - target.z).length() <= LEDGE_DROP_MAX_HORIZONTAL_M \
		and end.y - target.y >= LEDGE_DROP_MIN_HEIGHT_M and end.y - target.y <= LEDGE_DROP_MAX_HEIGHT_M

func _nearest_pathgrid_point(position: Vector3) -> int:
	var nearest_index := -1
	var nearest_distance_squared := INF
	for index in range(pathgrid_points.size()):
		var distance_squared := position.distance_squared_to(pathgrid_points[index])
		if distance_squared < nearest_distance_squared:
			nearest_distance_squared = distance_squared
			nearest_index = index
	return nearest_index

func _door_portal_points(door: Dictionary, from: Vector3, to: Vector3, actor_radius: float) -> Dictionary:
	var local_box: AABB = door.get("local_box", AABB())
	var reference_transform: Transform3D = door.get("transform", Transform3D.IDENTITY)
	if local_box.size.x <= 0.0 or local_box.size.z <= 0.0:
		return {}
	var normal_axis := 0 if local_box.size.x <= local_box.size.z else 2
	var lateral_axis := 2 if normal_axis == 0 else 0
	var normal_basis: Vector3 = reference_transform.basis.x if normal_axis == 0 else reference_transform.basis.z
	var lateral_basis: Vector3 = reference_transform.basis.z if lateral_axis == 2 else reference_transform.basis.x
	var normal_scale := normal_basis.length()
	var lateral_scale := lateral_basis.length()
	if normal_scale <= 0.0001 or lateral_scale <= 0.0001:
		return {}
	var inverse := reference_transform.affine_inverse()
	var local_from := inverse * from
	var local_to := inverse * to
	var center_axis := local_box.position[normal_axis] + local_box.size[normal_axis] * 0.5
	var from_delta := local_from[normal_axis] - center_axis
	var to_delta := local_to[normal_axis] - center_axis
	if from_delta * to_delta >= 0.0:
		return {}
	var axis_delta := local_to[normal_axis] - local_from[normal_axis]
	if absf(axis_delta) <= 0.0001:
		return {}
	var crossing_fraction := (center_axis - local_from[normal_axis]) / axis_delta
	if crossing_fraction <= 0.0 or crossing_fraction >= 1.0:
		return {}
	var crossing := local_from.lerp(local_to, crossing_fraction)
	var lateral_clearance := (actor_radius + 0.04) / lateral_scale
	var lateral_min := local_box.position[lateral_axis] + lateral_clearance
	var lateral_max := local_box.end[lateral_axis] - lateral_clearance
	if lateral_min > lateral_max:
		return {}
	var lateral_position := clampf(crossing[lateral_axis], lateral_min, lateral_max)
	var half_thickness := local_box.size[normal_axis] * 0.5
	var normal_clearance := half_thickness + (actor_radius + 0.12) / normal_scale
	var from_side := signf(from_delta)
	var near_local := crossing
	var far_local := crossing
	near_local[normal_axis] = center_axis + from_side * normal_clearance
	far_local[normal_axis] = center_axis - from_side * normal_clearance
	near_local[lateral_axis] = lateral_position
	far_local[lateral_axis] = lateral_position
	return {
		"near": reference_transform * near_local,
		"far": reference_transform * far_local,
	}

func _path_reaches(path: PackedVector3Array, destination: Vector3) -> bool:
	if path.is_empty():
		return false
	var end := path[path.size() - 1]
	return end.distance_to(destination) <= 0.35

func _path_reaches_target(
	path: PackedVector3Array, target: Vector3, target_on_mesh: Vector3, actor_radius: float,
	destination_arrival_distance: float
) -> bool:
	if target.distance_to(target_on_mesh) > maxf(actor_radius, destination_arrival_distance) or path.is_empty():
		return false
	if _path_reaches(path, target_on_mesh):
		return true
	var end := path[path.size() - 1]
	return Vector2(end.x - target.x, end.z - target.z).length() <= destination_arrival_distance

## Navigation links only describe connectivity. NPC locomotion must follow the authored PGRD
## elevations on a link, or horizontal steering can carry the actor off a stair landing.
func _path_uses_pathgrid_link(path: PackedVector3Array) -> bool:
	if path.size() < 2 or pathgrid_points.is_empty():
		return false
	for path_index in range(path.size() - 1):
		var from_index := _matching_pathgrid_point(path[path_index])
		var to_index := _matching_pathgrid_point(path[path_index + 1])
		if from_index < 0 or to_index < 0:
			continue
		var neighbors: PackedInt32Array = pathgrid_neighbors[from_index]
		if neighbors.has(to_index):
			return true
	return false

func _matching_pathgrid_point(position: Vector3) -> int:
	var tolerance_squared := PATHGRID_LINK_ENDPOINT_TOLERANCE_M * PATHGRID_LINK_ENDPOINT_TOLERANCE_M
	for index in range(pathgrid_points.size()):
		if position.distance_squared_to(pathgrid_points[index]) <= tolerance_squared:
			return index
	return -1

func _append_path_point(path: PackedVector3Array, point: Vector3) -> void:
	if path.is_empty() or path[path.size() - 1].distance_squared_to(point) > 0.0025:
		path.push_back(point)

func _path_length(path: PackedVector3Array) -> float:
	var length := 0.0
	for index in range(1, path.size()):
		length += path[index - 1].distance_to(path[index])
	return length
