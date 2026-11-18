shader_type sky;

uniform vec4 zenith : source_color = vec4(0.39, 0.55, 0.75, 1.0);
uniform vec4 horizon : source_color = vec4(0.60, 0.74, 0.92, 1.0);
uniform vec4 below_horizon : source_color = vec4(0.30, 0.38, 0.42, 1.0);
uniform vec4 sun_color : source_color = vec4(1.0, 0.85, 0.66, 1.0);
uniform vec4 stars_color : source_color = vec4(0.8, 0.83, 1.0, 1.0);
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform float sun_visibility = 1.0;
uniform float star_visibility;
uniform float lightning;

uniform sampler2D lower_from : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D upper_from : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D lower_to : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D upper_to : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 lower_tint_from : source_color;
uniform vec4 upper_tint_from : source_color;
uniform vec4 lower_tint_to : source_color;
uniform vec4 upper_tint_to : source_color;
uniform vec4 cloud_offsets_from;
uniform vec4 cloud_offsets_to;
uniform float weather_mix;

vec4 clouds(sampler2D lower_layer, sampler2D upper_layer, vec2 uv, vec4 offset, vec3 lower_tint, vec3 upper_tint) {
	vec4 lower = texture(lower_layer, uv * 1.15 + offset.xy);
	vec4 upper = texture(upper_layer, uv * 0.82 + offset.zw);
	lower.rgb *= lower_tint * lower.a;
	upper.rgb *= upper_tint * upper.a;
	return lower + upper * (1.0 - lower.a);
}

float star_hash(vec2 point) {
	return fract(sin(dot(point, vec2(127.1, 311.7))) * 43758.5453);
}

void sky() {
	float height = EYEDIR.y;
	vec3 color = mix(horizon.rgb, zenith.rgb, smoothstep(0.0, 0.9, height));
	color = mix(color, below_horizon.rgb, smoothstep(0.0, 0.55, -height));

	if (!AT_CUBEMAP_PASS && height > 0.0) {
		float toward_sun = dot(EYEDIR, sun_direction);
		float disk = smoothstep(0.99993, 0.99998, toward_sun);
		float glow = pow(max(toward_sun, 0.0), 90.0) * 0.26;
		color += sun_color.rgb * (disk * 1.8 + glow) * sun_visibility;

		vec2 dome = EYEDIR.xz / (1.0 + height);
		vec2 star_grid = dome * 360.0;
		float star_seed = star_hash(floor(star_grid));
		float star = step(0.982, star_seed) * (1.0 - smoothstep(0.02, 0.19, length(fract(star_grid) - 0.5)));
		color += stars_color.rgb * star * star_visibility * smoothstep(0.05, 0.25, height);

		vec4 cloud = clouds(lower_from, upper_from, dome + 0.5, cloud_offsets_from, lower_tint_from.rgb, upper_tint_from.rgb);
		if (weather_mix > 0.0) {
			vec4 next = clouds(lower_to, upper_to, dome + 0.5, cloud_offsets_to, lower_tint_to.rgb, upper_tint_to.rgb);
			cloud = mix(cloud, next, weather_mix);
		}
		cloud *= smoothstep(0.0, 0.11, height);
		color = color * (1.0 - cloud.a) + cloud.rgb + vec3(lightning * cloud.a);
	}
	COLOR = max(color, vec3(0.0));
}
