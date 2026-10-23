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
## The navigation regions of the loaded cell, one per tile (OpenMW bakes its navigation mesh the same way).
var navigation_tiles: Node3D = null

## Bakes the walkable surfaces of the loaded cell in tiles. Each tile takes the static triangles that touch it, with an
## overlap, so the tiles connect at their edges and stairs and floors on different levels join.
func build_navigation_tiles() -> void:
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
	for column in range(columns):
		for row in range(rows):
			var min_x := lowest.x + column * NAVIGATION_TILE_SIZE_M - NAVIGATION_TILE_OVERLAP_M
			var min_z := lowest.z + row * NAVIGATION_TILE_SIZE_M - NAVIGATION_TILE_OVERLAP_M
			var max_x := min_x + NAVIGATION_TILE_SIZE_M + 2.0 * NAVIGATION_TILE_OVERLAP_M
			var max_z := min_z + NAVIGATION_TILE_SIZE_M + 2.0 * NAVIGATION_TILE_OVERLAP_M
			var tile := PackedVector3Array()
			for index in range(0, triangles.size(), 3):
				var a := triangles[index]
				var b := triangles[index + 1]
				var c := triangles[index + 2]
				if maxf(a.x, maxf(b.x, c.x)) < min_x or minf(a.x, minf(b.x, c.x)) > max_x:
					continue
				if maxf(a.z, maxf(b.z, c.z)) < min_z or minf(a.z, minf(b.z, c.z)) > max_z:
					continue
				# The bake expects the opposite winding to the one the collision faces come with.
				tile.push_back(a)
				tile.push_back(c)
				tile.push_back(b)
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
	print("OpenOB navigation: %d tiles, %d polygons" % [navigation_tiles.get_child_count(), polygon_count])
	# The navigation map takes the new regions on its next physics frames.
	await scene.get_tree().physics_frame
	await scene.get_tree().physics_frame

func clear_navigation_tiles() -> void:
	if is_instance_valid(navigation_tiles):
		navigation_tiles.queue_free()
	navigation_tiles = null

func _collect_static_bodies(node: Node, bodies: Array) -> void:
	if node is StaticBody3D:
		bodies.push_back(node)
	for child: Node in node.get_children():
		_collect_static_bodies(child, bodies)

## Finds a path over the navigation tiles. If a closed door split the baked mesh,
## join reachable paths on both sides through that door's actual opening.
func navigation_path(from: Vector3, to: Vector3, actor_radius: float = 0.18) -> PackedVector3Array:
	var navigation_map := scene.get_world_3d().navigation_map
	var path := NavigationServer3D.map_get_path(navigation_map, from, to, true)
	if path.is_empty():
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
	return best_path if not best_path.is_empty() else path

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
