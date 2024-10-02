// Copyright © 2024 Cory Petkovsek, Roope Palmroos, and Contributors.

R"(

//INSERT: WORLD_NOISE1
// World Noise
uniform float world_noise_region_blend : hint_range(0.05, 0.95, 0.01) = 0.33;
uniform int world_noise_max_octaves : hint_range(0, 15) = 4;
uniform int world_noise_min_octaves : hint_range(0, 15) = 2;
uniform float world_noise_lod_distance : hint_range(0, 40000, 1) = 7500.;
uniform float world_noise_scale : hint_range(0.25, 20, 0.01) = 5.0;
uniform float world_noise_height : hint_range(0, 1000, 0.1) = 64.0;
uniform vec3 world_noise_offset = vec3(0.0);

// Takes in UV2 region space coordinates, returns 1.0 or 0.0 if a region is present or not.
float check_region(const vec2 uv2) {
	ivec2 pos = ivec2(floor(uv2)) + (_region_map_size / 2);
	int layer_index = 0;
	if (uint(pos.x | pos.y) < uint(_region_map_size)) {
		layer_index = clamp(_region_map[ pos.y * _region_map_size + pos.x ] - 1, -1, 0) + 1;
	}
	return float(layer_index);
}

// Takes in UV2 region space coordinates, returns a blend value (0 - 1 range) between empty, and valid regions
float region_blend(vec2 uv2) {
	uv2 -= 0.5;
	const vec2 offset = vec2(0.0,1.0);
	float a = check_region(uv2 + offset.xy);
	float b = check_region(uv2 + offset.yy);
	float c = check_region(uv2 + offset.yx);
	float d = check_region(uv2 + offset.xx);
	vec2 w = smoothstep(vec2(0.0), vec2(1.0), fract(uv2));
	float blend = mix(mix(d, c, w.x), mix(a, b, w.x), w.y);
    return 1.0 - blend;
}

float hashf(float f) {
	return fract(sin(f) * 1e4);
}

float hashv2(vec2 v) {
	return fract(1e4 * sin( fma(17.0, v.x, v.y * 0.1)) * (0.1 + abs(sin( fma(v.y, 13.0, v.x)))));
}

// https://iquilezles.org/articles/morenoise/
vec3 noise2D(vec2 x) {
    vec2 f = fract(x);
    // Quintic Hermine Curve.  Similar to SmoothStep()
    vec2 u = f*f*f* fma(f, fma(f, vec2(6.0), vec2(-15.0) ), vec2(10.0));
    vec2 du = 30.0*f*f* fma(f, (f-2.0), vec2(1.0) );

    vec2 p = floor(x);

	// Four corners in 2D of a tile
	float a = hashv2( p+vec2(0,0) );
    float b = hashv2( p+vec2(1,0) );
    float c = hashv2( p+vec2(0,1) );
    float d = hashv2( p+vec2(1,1) );

    // Mix 4 corner percentages
    float k0 =   a;
    float k1 =   b - a;
    float k2 =   c - a;
    float k3 =   a - b - c + d;
    return vec3( k0 + fma(k1, u.x, fma(k2, u.y, k3 * u.x * u.y)),
                du * ( vec2(k1, k2) + k3 * u.yx) );
}

float world_noise(vec2 p) {
    float a = 0.0;
    float b = 1.0;
    vec2  d = vec2(0.0);

    int octaves = int( clamp(
	float(world_noise_max_octaves) - floor(v_vertex_xz_dist/(world_noise_lod_distance)),
    float(world_noise_min_octaves), float(world_noise_max_octaves)) );
	
    for( int i=0; i < octaves; i++ ) {
        vec3 n = noise2D(p);
        d += n.yz;
        a += b * n.x / (1.0 + dot(d,d));
        b *= 0.5;
        p = mat2( vec2(0.8, -0.6), vec2(0.6, 0.8) ) * p * 2.0;
    }
    return a;
}

float get_noise_height(const vec2 uv) {
	float weight = region_blend(uv);
	// only calculate world noise when it could be visibile.
	if (weight <= 1.0 - world_noise_region_blend) {
		return 0.0;
	}
	//TODO: Offset/scale UVs are semi-dependent upon region size 1024. Base on v_vertex.xz instead
	float noise = fma( world_noise(fma(world_noise_offset.xz, vec2(1024. / _region_size), uv) * world_noise_scale * _region_size / 1024. * .1),
            world_noise_height * 10., world_noise_offset.y * 100.);
	weight = smoothstep(1.0 - world_noise_region_blend, 1.0, weight);
	return mix(0.0, noise, weight);
}

// World Noise end

//INSERT: WORLD_NOISE2
	// World Noise
   	if (_background_mode == 2u) {
	    height += get_noise_height(uv);
    }
)"
