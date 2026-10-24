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
## The navigation regions of the loaded cell, one per tile (OpenMW bakes its navigation mesh the same way).
var navigation_tiles: Node3D = null
var pathgrid_cell_form_id := 0
var pathgrid_points: PackedVector3Array = PackedVector3Array()
var pathgrid_neighbors: Array = []
var last_navigation_path_uses_pathgrid := false

func set_pathgrid(pathgrid: Dictionary, game_units_to_meters: float) -> void:
	clear_pathgrid()
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
	var edge_count := 0
	for edge_index in range(0, edges.size() - 1, 2):
		var from_index := edges[edge_index]
		var to_index := edges[edge_index + 1]
		if from_index < 0 or from_index >= pathgrid_neighbors.size() or to_index < 0 or to_index >= pathgrid_neighbors.size():
			continue
		var neighbors: PackedInt32Array = pathgrid_neighbors[from_index]
		neighbors.push_back(to_index)
		pathgrid_neighbors[from_index] = neighbors
		edge_count += 1
	print("OpenOB navigation: loaded cell PGRD 0x%08X with %d nodes and %d directed edges" % [
		pathgrid_cell_form_id, pathgrid_points.size(), edge_count
	])

func clear_pathgrid() -> void:
	pathgrid_cell_form_id = 0
	pathgrid_points.clear()
	pathgrid_neighbors.clear()
	last_navigation_path_uses_pathgrid = false

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
func navigation_path(from: Vector3, to: Vector3, actor_radius: float = 0.18) -> PackedVector3Array:
	last_navigation_path_uses_pathgrid = false
	var navigation_map := scene.get_world_3d().navigation_map
	var path := NavigationServer3D.map_get_path(navigation_map, from, to, true)
	if path.is_empty():
		var disconnected_path := _pathgrid_route(from, to)
		if not disconnected_path.is_empty():
			last_navigation_path_uses_pathgrid = true
			return disconnected_path
		return PackedVector3Array([to])
	var goal_on_mesh := NavigationServer3D.map_get_closest_point(navigation_map, to)
	if _path_reaches(path, goal_on_mesh):
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
		var approach := NavigationServer3D.map_get_path(navigation_map, from, near_point, true)
		if approach.is_empty() or not _path_reaches(approach, near_on_mesh):
			continue
		var departure := NavigationServer3D.map_get_path(navigation_map, far_point, to, true)
		if departure.is_empty() or not _path_reaches(departure, goal_on_mesh):
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
		return best_path
	var pathgrid_path := _pathgrid_route(from, to)
	if not pathgrid_path.is_empty():
		last_navigation_path_uses_pathgrid = true
		return pathgrid_path
	return best_path if not best_path.is_empty() else path

func _pathgrid_route(from: Vector3, to: Vector3) -> PackedVector3Array:
	var count := pathgrid_points.size()
	if count == 0 or pathgrid_neighbors.size() != count:
		return PackedVector3Array()
	var start_index := _nearest_pathgrid_point(from)
	var goal_index := _nearest_pathgrid_point(to)
	if start_index < 0 or goal_index < 0:
		return PackedVector3Array()
	var start_snap_distance := from.distance_to(pathgrid_points[start_index])
	var goal_snap_distance := to.distance_to(pathgrid_points[goal_index])
	if start_snap_distance > MAX_PATHGRID_ENDPOINT_SNAP_DISTANCE_M \
			or goal_snap_distance > MAX_PATHGRID_ENDPOINT_SNAP_DISTANCE_M:
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
	print("OpenOB navigation: navmesh route disconnected; using cell PGRD 0x%08X nodes=%d snap=%.2f/%.2fm" % [
		pathgrid_cell_form_id, node_route.size(), start_snap_distance, goal_snap_distance
	])
	return result

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
	return Vector2(end.x - destination.x, end.z - destination.z).length() <= 0.35

func _append_path_point(path: PackedVector3Array, point: Vector3) -> void:
	if path.is_empty() or path[path.size() - 1].distance_squared_to(point) > 0.0025:
		path.push_back(point)

func _path_length(path: PackedVector3Array) -> float:
	var length := 0.0
	for index in range(1, path.size()):
		length += path[index - 1].distance_to(path[index])
	return length
