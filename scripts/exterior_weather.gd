extends Node3D

const NifAssetLibrary := preload("res://scripts/nif_asset_library.gd")
const SKY_SHADER := preload("res://scripts/exterior_sky.gdshader")
const WEATHER_PERIOD_HOURS := 6.0
const SKY_UPDATE_PERIOD := 0.1
const DEFAULT_TIMING := Vector4(6.0, 10.0, 16.0, 20.0)
const RAIN_FLAG := 4
const SNOW_FLAG := 8

# Order of the color groups in WTHR NAM0.
enum WeatherColor { SKY_TOP, FOG, CLOUD_LOWER, AMBIENT, SUNLIGHT, SUN, STARS, SKY_BOTTOM, HORIZON, CLOUD_UPPER }

var game_hour := 1.0
var time_scale := 30.0
var environment := Environment.new()

var _assets: NifAssetLibrary
var _sun: DirectionalLight3D
var _sky := ShaderMaterial.new()
var _rain: GPUParticles3D
var _snow: GPUParticles3D
var _empty_cloud: ImageTexture
var _rng := RandomNumberGenerator.new()
var _exterior := false
var _last_location := Vector3i(-1, 0, 0)
var _timing := DEFAULT_TIMING
var _choices: Array = []
var _override: Dictionary = {}
var _current: Dictionary = {}
var _incoming: Dictionary = {}
var _residence := 0.0
var _transition := 0.0
var _transition_seconds := 1.0
var _sky_timer := 0.0
var _cloud_offsets: Dictionary = {}
var _lightning_wait := 0.0
var _lightning := 0.0


func configure(sun: DirectionalLight3D, assets: NifAssetLibrary) -> void:
	_sun = sun
	_assets = assets
	_sky.shader = SKY_SHADER
	var empty := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	empty.fill(Color.TRANSPARENT)
	_empty_cloud = ImageTexture.create_from_image(empty)
	for suffix in ["from", "to"]:
		_sky.set_shader_parameter("lower_" + suffix, _empty_cloud)
		_sky.set_shader_parameter("upper_" + suffix, _empty_cloud)
	var sky := Sky.new()
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	sky.sky_material = _sky
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_sky_contribution = 0.0
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_sky_affect = 0.0
	environment.fog_density = 1.0
	_rain = _make_precipitation(false)
	_snow = _make_precipitation(true)
	hide()


func initialize_clock(arguments: PackedStringArray) -> void:
	var reader := _assets.data_reader
	game_hour = fposmod(float(reader.get_global_default("GameHour", 1.0)), 24.0)
	time_scale = maxf(0.0, float(reader.get_global_default("TimeScale", 30.0)))
	var hour_argument := _option(arguments, "--game-hour")
	if hour_argument.is_valid_float() and is_finite(hour_argument.to_float()):
		game_hour = fposmod(hour_argument.to_float(), 24.0)
	var scale_argument := _option(arguments, "--time-scale")
	if scale_argument.is_valid_float() and is_finite(scale_argument.to_float()):
		time_scale = maxf(scale_argument.to_float(), 0.0)
	var weather_argument := _option(arguments, "--weather")
	if not weather_argument.is_empty():
		_override = reader.find_weather(weather_argument)
		if _override.is_empty():
			push_warning("OpenOB weather: no WTHR record named " + weather_argument)


func _option(arguments: PackedStringArray, flag: String) -> String:
	var index := arguments.find(flag)
	return arguments[index + 1] if index >= 0 and index + 1 < arguments.size() else ""


func set_exterior(enabled: bool) -> void:
	_exterior = enabled
	visible = enabled
	if not enabled:
		_rain.emitting = false
		_snow.emitting = false
		_lightning = 0.0
		_lightning_wait = 0.0
	_sky_timer = 0.0


func update_location(worldspace: int, position_world: Vector3, cell_size: float) -> void:
	var location := Vector3i(worldspace, floori(position_world.x / cell_size), floori(-position_world.z / cell_size))
	if location == _last_location:
		return
	var world_changed := location.x != _last_location.x
	_last_location = location
	var context: Dictionary = _assets.data_reader.get_weather_context(location.x, location.y, location.z)
	var timing: Vector4 = context.get("timing", DEFAULT_TIMING)
	_timing = timing if timing.x < timing.y and timing.y < timing.z and timing.z < timing.w and timing.w <= 24.0 else DEFAULT_TIMING
	var choices: Array = context.get("choices", [])
	# Keep a weather in progress across adjacent cells with the same climate distribution.
	var choices_changed := not _same_choices(_choices, choices)
	_choices = choices
	if _current.is_empty() or world_changed:
		_current = _pick_weather(true)
		_incoming.clear()
		_residence = WEATHER_PERIOD_HOURS
		_bind_clouds(_current, "from")
		print("OpenOB weather: %s at %05.2f h" % [_current.get("name", "default sky"), game_hour])
	elif choices_changed and _override.is_empty() and not _supports_weather(_incoming if not _incoming.is_empty() else _current):
		_residence = 0.0
	_sky_timer = 0.0


func _same_choices(previous: Array, next: Array) -> bool:
	if previous.size() != next.size():
		return false
	for index in range(previous.size()):
		if previous[index].id != next[index].id or previous[index].chance != next[index].chance:
			return false
	return true


func _supports_weather(weather: Dictionary) -> bool:
	for choice: Dictionary in _choices:
		if choice.id == weather.get("id", 0):
			return true
	return false


func _pick_weather(initial: bool = false) -> Dictionary:
	if not _override.is_empty():
		return _override.duplicate()
	var total := 0
	var most_likely: Dictionary = {}
	for choice: Dictionary in _choices:
		total += int(choice.chance)
		if most_likely.is_empty() or int(choice.chance) > int(most_likely.chance):
			most_likely = choice
	if initial or total <= 0:
		return most_likely.duplicate()
	var pick := _rng.randi_range(1, total)
	for choice: Dictionary in _choices:
		pick -= int(choice.chance)
		if pick <= 0:
			return choice.duplicate()
	return {}


func advance(delta: float, position_world: Vector3, units_to_meters: float) -> bool:
	var game_hours := delta * time_scale / 3600.0
	advance_clock(game_hours, delta)
	if not _exterior:
		return false
	global_position = position_world
	_sky_timer -= delta
	if _sky_timer > 0.0:
		return false
	_sky_timer += SKY_UPDATE_PERIOD
	if _sky_timer <= 0.0:
		_sky_timer = SKY_UPDATE_PERIOD
	_apply_sky(units_to_meters)
	return true

var elapsed_game_hours := 0.0

func advance_clock(hours: float, seconds := 0.0) -> void:
	elapsed_game_hours += hours
	game_hour = fposmod(game_hour + hours, 24.0)
	if not _current.is_empty():
		_advance_weather(seconds, hours)


func _advance_weather(delta: float, game_hours: float) -> void:
	_residence -= game_hours
	if not _incoming.is_empty():
		_transition = minf(1.0, _transition + delta / _transition_seconds)
		_advance_clouds(_incoming, delta)
		if _transition >= 1.0:
			_current = _incoming
			_incoming = {}
			_bind_clouds(_current, "from")
			_transition = 0.0
	elif _residence <= 0.0:
		_residence = WEATHER_PERIOD_HOURS
		var next := _pick_weather()
		if not next.is_empty() and next.id != _current.id:
			_incoming = next
			_transition = 0.0
			_transition_seconds = lerpf(45.0, 8.0, float(next.get("transition", 0.0)))
			_bind_clouds(next, "to")
			print("OpenOB weather: %s → %s at %05.2f h" % [_current.name, next.name, game_hour])
	_advance_clouds(_current, delta)
	_lightning = move_toward(_lightning, 0.0, delta * 4.0)
	var storm := _incoming if not _incoming.is_empty() and _transition > 0.5 else _current
	var thunder := float(storm.get("thunder", 1.0))
	if _exterior and (int(storm.get("flags", 0)) & RAIN_FLAG) != 0 and thunder < 1.0:
		_lightning_wait -= delta
		if _lightning_wait <= 0.0:
			_lightning = 0.65
			_lightning_wait = _rng.randf_range(8.0, 24.0) * lerpf(0.65, 2.0, thunder)
	else:
		_lightning_wait = 0.0


func _advance_clouds(weather: Dictionary, delta: float) -> void:
	var id := int(weather.get("id", 0))
	var speed: Vector2 = weather.get("cloud_speed", Vector2.ZERO)
	var offset: Vector4 = _cloud_offsets.get(id, Vector4.ZERO)
	offset.x = fposmod(offset.x + delta * speed.x * 0.018, 1.0)
	offset.y = fposmod(offset.y + delta * speed.x * 0.006, 1.0)
	offset.z = fposmod(offset.z + delta * speed.y * 0.015, 1.0)
	offset.w = fposmod(offset.w - delta * speed.y * 0.004, 1.0)
	_cloud_offsets[id] = offset


func _bind_clouds(weather: Dictionary, suffix: String) -> void:
	for layer in ["lower", "upper"]:
		var path := str(weather.get("cloud_" + layer, "")).replace("\\", "/")
		var texture: Texture2D = _empty_cloud
		if not path.is_empty():
			var source := _assets.texture_for_path(path if path.to_lower().begins_with("textures/") else "Textures/" + path)
			if source != null:
				texture = source
		_sky.set_shader_parameter(layer + "_" + suffix, texture)


func _phase() -> Vector3:
	# WTHR color slots are sunrise, day, sunset and night.
	var dawn := (_timing.x + _timing.y) * 0.5
	var dusk := (_timing.z + _timing.w) * 0.5
	if game_hour < _timing.x or game_hour >= _timing.w:
		return Vector3(3, 3, 0)
	if game_hour < dawn:
		return Vector3(3, 0, smoothstep(_timing.x, dawn, game_hour))
	if game_hour < _timing.y:
		return Vector3(0, 1, smoothstep(dawn, _timing.y, game_hour))
	if game_hour < _timing.z:
		return Vector3(1, 1, 0)
	if game_hour < dusk:
		return Vector3(1, 2, smoothstep(_timing.z, dusk, game_hour))
	return Vector3(2, 3, smoothstep(dusk, _timing.w, game_hour))


func _color(weather: Dictionary, group: int, phase: Vector3, fallback: Color) -> Color:
	var colors: PackedColorArray = weather.get("colors", PackedColorArray())
	if colors.size() != 40:
		return fallback
	var first := colors[group * 4 + int(phase.x)]
	var second := colors[group * 4 + int(phase.y)]
	return first.srgb_to_linear().lerp(second.srgb_to_linear(), phase.z).linear_to_srgb()


func _mix_color(group: int, phase: Vector3, fallback: Color) -> Color:
	var first := _color(_current, group, phase, fallback)
	if _incoming.is_empty():
		return first
	var second := _color(_incoming, group, phase, fallback)
	return first.srgb_to_linear().lerp(second.srgb_to_linear(), _transition).linear_to_srgb()


func _number(key: String, fallback: float) -> float:
	var first := float(_current.get(key, fallback))
	return first if _incoming.is_empty() else lerpf(first, float(_incoming.get(key, fallback)), _transition)


func _apply_sky(units_to_meters: float) -> void:
	var phase := _phase()
	var rise := (_timing.x + _timing.y) * 0.5
	var fall := (_timing.z + _timing.w) * 0.5
	var daylight := smoothstep(_timing.x, _timing.y, game_hour) * (1.0 - smoothstep(_timing.z, _timing.w, game_hour))
	var sun_angle := (game_hour - rise) * PI / (fall - rise)
	if game_hour < rise or game_hour > fall:
		var night_hour := game_hour + (24.0 if game_hour < rise else 0.0)
		sun_angle = PI + (night_hour - fall) * PI / (24.0 - fall + rise)
	var altitude := sin(sun_angle)
	var direction := Vector3(cos(sun_angle), altitude * 0.9, absf(altitude) * 0.33).normalized()

	var night_sky := Color(0.01, 0.025, 0.055)
	var top := _mix_color(WeatherColor.SKY_TOP, phase, night_sky.lerp(Color(0.39, 0.55, 0.75), daylight))
	var horizon := _mix_color(WeatherColor.HORIZON, phase, night_sky.lerp(Color(0.60, 0.74, 0.92), daylight))
	_sky.set_shader_parameter("zenith", top)
	_sky.set_shader_parameter("horizon", horizon)
	_sky.set_shader_parameter("below_horizon", _mix_color(WeatherColor.SKY_BOTTOM, phase, horizon))
	_sky.set_shader_parameter("sun_color", _mix_color(WeatherColor.SUN, phase, Color(1.0, 0.78, 0.53)))
	_sky.set_shader_parameter("stars_color", _mix_color(WeatherColor.STARS, phase, Color(0.8, 0.83, 1.0)))
	_sky.set_shader_parameter("sun_direction", direction)
	_sky.set_shader_parameter("sun_visibility", smoothstep(-0.08, 0.12, altitude))
	_sky.set_shader_parameter("star_visibility", 1.0 - daylight)
	_sky.set_shader_parameter("weather_mix", _transition)
	_sky.set_shader_parameter("lightning", _lightning)
	_apply_cloud_layer(_current, phase, "from")
	if not _incoming.is_empty():
		_apply_cloud_layer(_incoming, phase, "to")

	_sun.look_at(_sun.global_position - Vector3(direction.x, maxf(direction.y, 0.09), direction.z))
	_sun.light_color = _mix_color(WeatherColor.SUNLIGHT, phase, Color(1.0, 0.93, 0.83))
	_sun.light_energy = 1.05 * smoothstep(-0.08, 0.40, altitude) * clampf(_number("sunlight_dimmer", 1.0), 0.0, 2.0)
	_sun.shadow_enabled = _sun.light_energy > 0.03
	var ambient := _mix_color(WeatherColor.AMBIENT, phase, Color(0.16, 0.23, 0.39).lerp(Color(0.55, 0.62, 0.75), daylight))
	var flash := _mix_color_value("lightning_color", Color(0.92, 0.94, 1.0))
	environment.ambient_light_color = ambient.lerp(flash, _lightning)
	environment.ambient_light_energy = lerpf(0.30, 0.85, daylight) + _lightning

	var fog := _fog_distance(_current, daylight)
	if not _incoming.is_empty():
		fog = fog.lerp(_fog_distance(_incoming, daylight), _transition)
	environment.fog_light_color = _mix_color(WeatherColor.FOG, phase, horizon)
	environment.fog_depth_begin = clampf(fog.x * units_to_meters, 0.0, 10000.0)
	environment.fog_depth_end = clampf(fog.y * units_to_meters, environment.fog_depth_begin + 1.0, 20000.0)

	_update_precipitation(_rain, RAIN_FLAG)
	_update_precipitation(_snow, SNOW_FLAG)


func _mix_color_value(key: String, fallback: Color) -> Color:
	var first: Color = _current.get(key, fallback)
	return first if _incoming.is_empty() else first.lerp(_incoming.get(key, fallback), _transition)


func _apply_cloud_layer(weather: Dictionary, phase: Vector3, suffix: String) -> void:
	_sky.set_shader_parameter("lower_tint_" + suffix, _color(weather, WeatherColor.CLOUD_LOWER, phase, Color.WHITE))
	_sky.set_shader_parameter("upper_tint_" + suffix, _color(weather, WeatherColor.CLOUD_UPPER, phase, Color.WHITE))
	_sky.set_shader_parameter("cloud_offsets_" + suffix, _cloud_offsets.get(int(weather.get("id", 0)), Vector4.ZERO))


func _fog_distance(weather: Dictionary, daylight: float) -> Vector2:
	var value: Vector4 = weather.get("fog", Vector4(4096, 68000, 4096, 32500))
	return Vector2(value.z, value.w).lerp(Vector2(value.x, value.y), daylight)


func _update_precipitation(emitter: GPUParticles3D, flag: int) -> void:
	var from := 1.0 if (int(_current.get("flags", 0)) & flag) != 0 else 0.0
	var to := 1.0 if (int(_incoming.get("flags", 0)) & flag) != 0 else 0.0
	var intensity := lerpf(from, to, _transition)
	emitter.amount_ratio = intensity
	if intensity > 0.005:
		var wind := _number("wind", 0.0)
		var motion := emitter.process_material as ParticleProcessMaterial
		var slant := lerpf(0.08, 0.72 if flag == SNOW_FLAG else 0.46, clampf(wind, 0.0, 1.0))
		motion.direction = Vector3(slant, -1.0, slant * 0.35).normalized()
	if emitter.emitting != (intensity > 0.005):
		emitter.emitting = intensity > 0.005


func _make_precipitation(snow: bool) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = "Snow" if snow else "Rain"
	particles.emitting = false
	particles.amount = 260 if snow else 420
	particles.lifetime = 3.4 if snow else 0.85
	particles.visibility_aabb = AABB(Vector3(-14, -12, -14), Vector3(28, 26, 28))
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var motion := ParticleProcessMaterial.new()
	motion.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	motion.emission_box_extents = Vector3(9, 1.5, 9)
	motion.direction = Vector3(0.17 if snow else 0.11, -1.0, 0.04).normalized()
	motion.spread = 16.0 if snow else 4.0
	motion.initial_velocity_min = 1.4 if snow else 12.0
	motion.initial_velocity_max = 2.4 if snow else 16.0
	motion.gravity = Vector3.ZERO
	particles.process_material = motion
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.055, 0.055) if snow else Vector2(0.018, 0.27)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.albedo_color = Color(0.84, 0.90, 0.98, 0.68) if snow else Color(0.58, 0.69, 0.78, 0.38)
	var texture_image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	for y in range(16):
		for x in range(16):
			var p := (Vector2(x, y) + Vector2(0.5, 0.5)) / 8.0 - Vector2.ONE
			var distance := p.length() if snow else absf(p.x)
			var alpha := (1.0 - smoothstep(0.1, 1.0, distance)) * (1.0 - absf(p.y) * 0.65)
			texture_image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	material.albedo_texture = ImageTexture.create_from_image(texture_image)
	mesh.material = material
	particles.draw_pass_1 = mesh
	particles.position.y = 5.0
	add_child(particles)
	return particles
