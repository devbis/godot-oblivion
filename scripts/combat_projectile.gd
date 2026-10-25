extends Node3D
## A projectile in flight: an arrow loosed from a bow or a glowing spell bolt. It flies until its ray meets a body, then an
## arrow sticks where it hit and a bolt bursts; the scene host handles actor reactions and fatigue on impact.

signal impacted(hit_position: Vector3, collider: Object)

enum Kind { ARROW, SPELL }

const HIT_COLLISION_MASK := 1 | 2 | 4 | 16
const ARROW_GRAVITY_MPS2 := 9.8
const ARROW_LIFETIME_AFTER_HIT_S := 10.0
const MAX_FLIGHT_S := 6.0
const IMPACT_IMPULSE := 2.5
const ARROW_MODEL := "Weapons/Iron/Arrow.NIF"
## The arrow NIF holds the arrow, its quiver stack and four variants; this is the single arrow, tip at the origin and pointing
## along -Z like every weapon model.
const ARROW_MESH_NAME := "arrow:0"

var kind := Kind.SPELL
var velocity := Vector3.ZERO
var color := Color(1.0, 0.45, 0.12)
var excluded_bodies: Array[RID] = []
var _age := 0.0
var _landed := false
static var _soft_dot: Texture2D

static func build_arrow_meshes(assets: RefCounted, unit_scale: float) -> Array[MeshInstance3D]:
	var instances: Array[MeshInstance3D] = []
	for entry_value: Variant in await assets.meshes_for_model(ARROW_MODEL):
		var entry: Dictionary = entry_value
		if str(entry.get("mesh_name", "")).to_lower() != ARROW_MESH_NAME:
			continue
		var instance := MeshInstance3D.new()
		instance.mesh = entry.mesh as ArrayMesh
		instance.scale = Vector3.ONE * unit_scale
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.material_override = await assets.material_for_texture(
			str(entry.diffuse_texture_path),
			bool(entry.get("alpha_blend", false)),
			bool(entry.get("alpha_test", false)),
			int(entry.get("alpha_threshold", 128))
		)
		instances.push_back(instance)
	return instances

static func new_arrow(model_meshes: Array[MeshInstance3D], launch_velocity: Vector3) -> Node3D:
	var projectile: Node3D = (load("res://scripts/combat_projectile.gd") as GDScript).new()
	projectile.kind = Kind.ARROW
	projectile.velocity = launch_velocity
	for mesh in model_meshes:
		projectile.add_child(mesh)
	return projectile

static func new_spell_bolt(bolt_color: Color, launch_velocity: Vector3) -> Node3D:
	var projectile: Node3D = (load("res://scripts/combat_projectile.gd") as GDScript).new()
	projectile.kind = Kind.SPELL
	projectile.color = bolt_color
	projectile.velocity = launch_velocity
	projectile._build_bolt_visuals()
	return projectile

## The colour of a spell bolt from the school of its first effect: fire, frost and shock damage have their own, anything
## else is a pale violet.
static func color_for_effect(effect_code: String) -> Color:
	if effect_code.begins_with("FI"):
		return Color(1.0, 0.42, 0.1)
	if effect_code.begins_with("FR"):
		return Color(0.45, 0.8, 1.0)
	if effect_code.begins_with("SH"):
		return Color(0.75, 0.8, 1.0)
	return Color(0.8, 0.55, 1.0)

func _physics_process(delta: float) -> void:
	if _landed:
		return
	_age += delta
	if _age > MAX_FLIGHT_S:
		queue_free()
		return
	if kind == Kind.ARROW:
		velocity.y -= ARROW_GRAVITY_MPS2 * delta
	var from := global_position
	var to := from + velocity * delta
	var query := PhysicsRayQueryParameters3D.create(from, to, HIT_COLLISION_MASK, excluded_bodies)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		_land(hit)
		return
	global_position = to
	if velocity.length_squared() > 0.01:
		look_at(to + velocity, Vector3.UP if absf(velocity.normalized().y) < 0.99 else Vector3.RIGHT)

func _land(hit: Dictionary) -> void:
	_landed = true
	global_position = hit.position
	var collider: Object = hit.get("collider")
	if collider is RigidBody3D:
		(collider as RigidBody3D).apply_impulse(velocity.normalized() * IMPACT_IMPULSE, hit.position - (collider as RigidBody3D).global_position)
	impacted.emit(hit.position, collider)
	if kind == Kind.ARROW:
		get_tree().create_timer(ARROW_LIFETIME_AFTER_HIT_S).timeout.connect(queue_free)
	else:
		_burst()

func _build_bolt_visuals() -> void:
	var core := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.09
	sphere.height = 0.18
	core.mesh = sphere
	core.material_override = _glow_material(color, 3.0)
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(core)
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 2.0
	light.omni_range = 6.0
	add_child(light)
	add_child(_particles(48, 0.45, 0.14, false, 0.2, 0.8))

func _burst() -> void:
	for child in get_children():
		child.queue_free()
	var flash := OmniLight3D.new()
	flash.light_color = color
	flash.light_energy = 4.0
	flash.omni_range = 8.0
	add_child(flash)
	var particles := _particles(60, 0.7, 0.2, true, 2.0, 5.0)
	add_child(particles)
	var tween := create_tween()
	tween.tween_property(flash, "light_energy", 0.0, 0.5)
	tween.tween_interval(0.5)
	tween.tween_callback(queue_free)

## A white dot fading to nothing at its edge, so a particle quad reads as a glow and not a square.
static func _soft_dot_texture() -> Texture2D:
	if _soft_dot == null:
		var fade := Gradient.new()
		fade.set_color(0, Color.WHITE)
		fade.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
		var texture := GradientTexture2D.new()
		texture.gradient = fade
		texture.fill = GradientTexture2D.FILL_RADIAL
		texture.fill_from = Vector2(0.5, 0.5)
		texture.fill_to = Vector2(1.0, 0.5)
		texture.width = 64
		texture.height = 64
		_soft_dot = texture
	return _soft_dot

func _glow_material(glow_color: Color, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = glow_color
	material.emission_enabled = true
	material.emission = glow_color
	material.emission_energy_multiplier = energy
	return material

func _particles(amount: int, lifetime: float, quad_size: float, one_shot: bool, speed_min: float, speed_max: float) -> CPUParticles3D:
	var particles := CPUParticles3D.new()
	particles.amount = amount
	particles.lifetime = lifetime
	particles.one_shot = one_shot
	particles.explosiveness = 1.0 if one_shot else 0.0
	particles.local_coords = false
	particles.direction = Vector3.ZERO
	particles.spread = 180.0
	particles.initial_velocity_min = speed_min
	particles.initial_velocity_max = speed_max
	particles.gravity = Vector3(0.0, 0.6 if not one_shot else -1.5, 0.0)
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * quad_size
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = _soft_dot_texture()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.no_depth_test = false
	quad.material = material
	particles.mesh = quad
	var ramp := Gradient.new()
	ramp.set_color(0, Color(color.r, color.g, color.b, 0.9))
	ramp.set_color(1, Color(color.r, color.g, color.b, 0.0))
	particles.color_ramp = ramp
	particles.emitting = true
	return particles
