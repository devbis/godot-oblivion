extends Control
## Exploration HUD: centered reticle, three vitals ribbons (lower left) and the aimed target's name/lock level (lower right).
## Draws only what set_snapshot() receives; it holds no gameplay state. All textures come from the user's installed game
## data through the asset library; nothing is vendored.

const RETICLE_PATH := "Textures/Menus/Misc/hud_reticle.dds"
const ACTIVATION_ATLAS_PATH := "Textures/Menus/Shared/all_activate_icons.dds"
const SMALL_ICONS_PATH := "Textures/Menus/Shared/all_small_icons.dds"
const RIBBON_PATH := "Textures/Menus/HUD/hud_ribbon_%s_%s.dds"
const RIBBON_KEYS := ["health", "magic", "fatigue"]
const RIBBON_SIZE := Vector2(189.0, 16.0)
const RIBBON_FILL_OFFSET := 11.0
const RIBBON_FILL_WIDTH := 163.0
const RIBBON_ROW_STEP := 18.0
const RETICLE_SIZE := 37.0
const LOCK_ICON_OFFSET := 192.0
const LOCK_ICON_SIZE := 16.0
## From hud_reticle.xml: the tint is (208, 0, 0) for a crime and white otherwise, and the reticle's code-set alpha (`user2`) starts at 128/255. That
## half transparency is why a red reticle reads as pinkish. A locked door uses the same tint; the original rule for it is not established.
const CRIME_COLOR := Color8(208, 0, 0, 128)
const NEUTRAL_COLOR := Color8(255, 255, 255, 128)
## Show the optional enemy-health overlay (off by default, matching bHealthBarShowing=0).
var show_enemy_health := false

var _reticle: TextureRect
var _fallback: Label
var _ribbons: Array[Dictionary] = []
var _ribbon_box: Control
var _info_box: VBoxContainer
var _target_name: Label
var _lock_row: HBoxContainer
var _lock_icon: TextureRect
var _lock_label: Label
var _enemy_bar: ProgressBar
var _crosshair: Texture2D
var _atlas: Texture2D
var _icon_cache: Dictionary = {}
var _ribbon_textures_ok := false
var _loaded := false

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_reticle = TextureRect.new()
	_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reticle.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_reticle.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_reticle.set_anchors_preset(Control.PRESET_CENTER)
	_reticle.offset_left = -RETICLE_SIZE * 0.5
	_reticle.offset_right = RETICLE_SIZE * 0.5
	_reticle.offset_top = -RETICLE_SIZE * 0.5
	_reticle.offset_bottom = RETICLE_SIZE * 0.5
	add_child(_reticle)
	_fallback = Label.new()
	_fallback.text = "+"
	_fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_fallback.add_theme_font_size_override("font_size", 20)
	_fallback.add_theme_color_override("font_outline_color", Color.BLACK)
	_fallback.add_theme_constant_override("outline_size", 3)
	_fallback.set_anchors_preset(Control.PRESET_CENTER)
	_fallback.offset_left = -18.0
	_fallback.offset_right = 18.0
	_fallback.offset_top = -18.0
	_fallback.offset_bottom = 18.0
	_fallback.visible = false
	add_child(_fallback)

	_ribbon_box = Control.new()
	_ribbon_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ribbon_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	var height := RIBBON_ROW_STEP * RIBBON_KEYS.size()
	_ribbon_box.offset_left = 16.0
	_ribbon_box.offset_right = 16.0 + RIBBON_SIZE.x
	_ribbon_box.offset_top = -16.0 - height
	_ribbon_box.offset_bottom = -16.0
	add_child(_ribbon_box)
	for row in RIBBON_KEYS.size():
		var empty_rect := TextureRect.new()
		empty_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		empty_rect.position = Vector2(0.0, row * RIBBON_ROW_STEP)
		empty_rect.size = RIBBON_SIZE
		empty_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_ribbon_box.add_child(empty_rect)
		# The fill is clipped, not squashed: the clip's width is 163 * ratio.
		var clip := Control.new()
		clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip.clip_contents = true
		clip.position = Vector2(RIBBON_FILL_OFFSET, row * RIBBON_ROW_STEP)
		clip.size = Vector2(RIBBON_FILL_WIDTH, RIBBON_SIZE.y)
		_ribbon_box.add_child(clip)
		var full_rect := TextureRect.new()
		full_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		full_rect.size = Vector2(RIBBON_FILL_WIDTH, RIBBON_SIZE.y)
		full_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		full_rect.stretch_mode = TextureRect.STRETCH_SCALE
		clip.add_child(full_rect)
		_ribbons.push_back({"empty": empty_rect, "clip": clip, "full": full_rect})

	_info_box = VBoxContainer.new()
	_info_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info_box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_info_box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_info_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_info_box.offset_right = -24.0
	_info_box.offset_left = -324.0
	_info_box.offset_bottom = -16.0
	_info_box.offset_top = -80.0
	_info_box.alignment = BoxContainer.ALIGNMENT_END
	add_child(_info_box)
	_target_name = Label.new()
	_target_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_style_label(_target_name)
	_info_box.add_child(_target_name)
	_lock_row = HBoxContainer.new()
	_lock_row.alignment = BoxContainer.ALIGNMENT_END
	_lock_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info_box.add_child(_lock_row)
	_lock_icon = TextureRect.new()
	_lock_icon.custom_minimum_size = Vector2(LOCK_ICON_SIZE, LOCK_ICON_SIZE)
	_lock_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_lock_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_lock_row.add_child(_lock_icon)
	_lock_label = Label.new()
	_style_label(_lock_label)
	_lock_row.add_child(_lock_label)
	_enemy_bar = ProgressBar.new()
	_enemy_bar.show_percentage = false
	_enemy_bar.max_value = 1.0
	_enemy_bar.custom_minimum_size = Vector2(0.0, 6.0)
	_enemy_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info_box.add_child(_enemy_bar)
	_lock_row.visible = false
	_enemy_bar.visible = false
	_info_box.visible = false
	_ribbon_box.visible = false
	_reticle.visible = false

func _style_label(label: Label) -> void:
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.85))
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)

## Loads the original HUD textures through the asset library (an object with `texture_for_path`).
func load_assets(assets: Object) -> void:
	_crosshair = await assets.texture_for_path(RETICLE_PATH)
	_atlas = await assets.texture_for_path(ACTIVATION_ATLAS_PATH)
	var small_icons: Texture2D = await assets.texture_for_path(SMALL_ICONS_PATH)
	if small_icons != null:
		var lock_texture := AtlasTexture.new()
		lock_texture.atlas = small_icons
		lock_texture.region = Rect2(LOCK_ICON_OFFSET, 0.0, float(small_icons.get_height()), float(small_icons.get_height()))
		_lock_icon.texture = lock_texture
	_ribbon_textures_ok = true
	for row in RIBBON_KEYS.size():
		var empty_texture: Texture2D = await assets.texture_for_path(RIBBON_PATH % [RIBBON_KEYS[row], "empty"])
		var full_texture: Texture2D = await assets.texture_for_path(RIBBON_PATH % [RIBBON_KEYS[row], "full"])
		(_ribbons[row]["empty"] as TextureRect).texture = empty_texture
		(_ribbons[row]["full"] as TextureRect).texture = full_texture
		if empty_texture == null or full_texture == null:
			_ribbon_textures_ok = false
			push_warning("HUD ribbon texture missing for %s" % RIBBON_KEYS[row])
	if _crosshair == null:
		push_warning("HUD reticle texture missing: %s" % RETICLE_PATH)
	if _atlas == null:
		push_warning("HUD activation atlas missing: %s" % ACTIVATION_ATLAS_PATH)
	_loaded = true

func _icon_texture(icon_index: int) -> Texture2D:
	if icon_index <= 0 or _atlas == null:
		return null
	if _icon_cache.has(icon_index):
		return _icon_cache[icon_index]
	var cell_size := float(_atlas.get_height())
	var left := float(icon_index - 1) * cell_size
	if left + cell_size > float(_atlas.get_width()):
		return null
	var texture := AtlasTexture.new()
	texture.atlas = _atlas
	texture.region = Rect2(left, 0.0, cell_size, cell_size)
	_icon_cache[icon_index] = texture
	return texture

## target: interaction snapshot. vitals: {health|magic|fatigue: {current, max}}. show: false while loading or a full-screen
## menu or face preview is up.
func set_snapshot(target: Dictionary, vitals: Dictionary, show: bool) -> void:
	visible = show
	if not show:
		return
	var icon_texture := _icon_texture(int(target.get("reticle_icon", 0)))
	var base_texture: Texture2D = icon_texture if icon_texture != null else _crosshair
	_reticle.texture = base_texture
	_reticle.visible = base_texture != null
	_fallback.visible = base_texture == null
	var tint := CRIME_COLOR if (bool(target.get("crime", false)) or bool(target.get("locked", false))) else NEUTRAL_COLOR
	_reticle.modulate = tint
	_fallback.modulate = tint

	_ribbon_box.visible = _loaded
	for row in RIBBON_KEYS.size():
		var vital: Dictionary = vitals.get(RIBBON_KEYS[row], {})
		var maximum := maxf(float(vital.get("max", 0.0)), 0.0)
		var ratio := clampf(float(vital.get("current", 0.0)) / maximum, 0.0, 1.0) if maximum > 0.0 else 0.0
		var clip := _ribbons[row]["clip"] as Control
		clip.size = Vector2(RIBBON_FILL_WIDTH * ratio, RIBBON_SIZE.y)
		clip.visible = ratio > 0.0

	var has_target := str(target.get("kind", "none")) != "none"
	_info_box.visible = has_target
	if has_target:
		_target_name.text = str(target.get("display_name", ""))
		var lock_level := int(target.get("lock_level", -1))
		_lock_row.visible = lock_level >= 0
		_lock_label.text = "Lock level %d" % lock_level if lock_level >= 0 else ""
		var health_ratio := float(target.get("enemy_health_ratio", -1.0))
		_enemy_bar.visible = show_enemy_health and health_ratio >= 0.0
		_enemy_bar.value = maxf(health_ratio, 0.0)
