shader_type spatial;

uniform bool has_lod = false;
uniform sampler2D lod_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec2 lod_chunk;
uniform bool has_detail = false;
uniform sampler2DArray detail_textures : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_masks : filter_linear, repeat_disable;
uniform sampler2D layer_indices : filter_nearest, repeat_disable;
uniform ivec2 grid_origin;
uniform float cell_scale;

varying vec2 ground_position;

void vertex() {
	ground_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

ivec4 read_layer_indices(ivec2 pixel) {
	return ivec4(round(texelFetch(layer_indices, pixel, 0) * 255.0));
}

vec3 land_detail(vec2 grid_position) {
	ivec2 tile = ivec2(floor(grid_position)) - grid_origin;
	// A fragment on the boundary can round into the tile just beyond the atlas.
	tile = clamp(tile, ivec2(0), textureSize(layer_indices, 0) / ivec2(3, 4) - ivec2(1));
	vec2 cell_uv = clamp(grid_position - vec2(tile + grid_origin), vec2(0.0), vec2(1.0));
	ivec2 side = ivec2(greaterThanEqual(cell_uv, vec2(0.5)));
	int quadrant = side.x + 2 * side.y;
	ivec2 index_pixel = tile * ivec2(3, 4) + ivec2(0, quadrant);
	ivec4 first = read_layer_indices(index_pixel);
	// The original UV step is 1 / fLandTextureTilingMult (2 by default),
	// with 32 height intervals across a LAND cell.
	vec2 detail_uv = grid_position * 16.0;
	vec2 detail_dx = dFdx(detail_uv);
	vec2 detail_dy = dFdy(detail_uv);
	vec3 base_color = textureGrad(detail_textures, vec3(detail_uv, float(first.y)), detail_dx, detail_dy).rgb;
	if (first.x == 0) {
		return base_color;
	}
	ivec4 second = read_layer_indices(index_pixel + ivec2(1, 0));
	ivec4 third = read_layer_indices(index_pixel + ivec2(2, 0));
	vec2 quadrant_position = clamp(cell_uv * 2.0 - vec2(side), vec2(0.0), vec2(1.0));
	vec2 mask_pixel = vec2(tile * ivec2(34, 68) + side * 17) + quadrant_position * 16.0 + 0.5;
	vec2 mask_size = vec2(textureSize(layer_masks, 0));
	vec4 alpha_low = texture(layer_masks, mask_pixel / mask_size);
	vec4 alpha_high = texture(layer_masks, (mask_pixel + vec2(0.0, 34.0)) / mask_size);
	vec3 color = vec3(0.0);
	float overlay_weight = 0.0;
	for (int slot = 0; slot < first.x; slot++) {
		float alpha = slot < 4 ? alpha_low[slot] : alpha_high[slot - 4];
		int layer = slot < 2 ? first[slot + 2] : (slot < 6 ? second[slot - 2] : third[slot - 6]);
		if (alpha > 0.0) {
			vec3 layer_color = textureGrad(detail_textures, vec3(detail_uv, float(layer)), detail_dx, detail_dy).rgb;
			color += layer_color * alpha;
			overlay_weight += alpha;
		}
	}
	// The LAND base layer receives the weight left by the eight overlays.
	return (color + base_color * max(1.0 - overlay_weight, 0.0)) / max(1.0, overlay_weight);
}

void fragment() {
	vec2 grid_position = ground_position * vec2(cell_scale, -cell_scale);
	float detail_mix = 1.0;
	vec3 color = vec3(0.5);
	if (has_lod) {
		color = texture(lod_albedo, (grid_position - lod_chunk) / 32.0).rgb;
		detail_mix = 1.0 - smoothstep(86.0, 118.0, distance(ground_position, CAMERA_POSITION_WORLD.xz));
	}
	if (has_detail && detail_mix > 0.0) {
		color = mix(color, land_detail(grid_position), detail_mix);
	}
	ALBEDO = color;
	ROUGHNESS = 0.9;
}
