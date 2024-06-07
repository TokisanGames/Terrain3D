R"(shader_type spatial;
render_mode blend_mix , cull_disabled;

// Private uniforms
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625; // = 1/1024
uniform float _mesh_vertex_spacing = 1.0;
uniform float _mesh_vertex_density = 1.0; // = 1/_mesh_vertex_spacing
uniform int _region_map_size = 16;
uniform int _region_map[256];
uniform vec2 _region_offsets[256];
uniform sampler2DArray _height_maps : repeat_disable;
uniform uint _background_mode = 1u;  // NONE = 0, FLAT = 1, NOISE = 2
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, repeat_disable, filter_nearest; 

uniform float depth_fade_distance : hint_range(0.0, 10.0) = 1.0;
uniform float absorbance : hint_range(0.0, 10.0) = 2.0;

uniform vec3 shallow_color : source_color = vec3(0.22, 0.66, 1.0);
uniform vec3 deep_color : source_color = vec3(0.0, 0.25, 0.45);

uniform float foam_amount : hint_range(0.0, 2.0) = 0.2;
uniform vec3 foam_color : source_color = vec3(1);
uniform sampler2D foam_noise : hint_default_white;

uniform float roughness : hint_range(0.0, 1.0) = 0.05;

uniform vec2 Direction;
uniform float Speed;
uniform float Steepness : hint_range(0.0, 1.0, 0.05) = 1.0;
uniform float Amplitude = 1.0;
uniform float Wavelength = 1.0;

// Varyings
varying flat vec3 v_vertex;	// World coordinate vertex location
varying flat vec3 v_camera_pos;
varying flat float v_vertex_dist;
varying flat ivec3 v_region;
varying flat vec2 v_uv_offset;
varying flat vec2 v_uv2_offset;

////////////////////////
// Vertex
////////////////////////

// Takes in UV world space coordinates, returns ivec3 with:
// XY: (0 to _region_size) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
ivec3 get_region_uv(vec2 uv) {
	uv *= _region_texel_size;
	ivec2 pos = ivec2(floor(uv)) + (_region_map_size / 2);
	int bounds = int(pos.x>=0 && pos.x<_region_map_size && pos.y>=0 && pos.y<_region_map_size);
	int layer_index = _region_map[ pos.y * _region_map_size + pos.x ] * bounds - 1;
	return ivec3(ivec2((uv - _region_offsets[layer_index]) * _region_size), layer_index);
}

// Takes in UV2 region space coordinates, returns vec3 with:
// XY: (0 to 1) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
vec3 get_region_uv2(vec2 uv) {
	ivec2 pos = ivec2(floor(uv)) + (_region_map_size / 2);
	int bounds = int(pos.x>=0 && pos.x<_region_map_size && pos.y>=0 && pos.y<_region_map_size);
	int layer_index = _region_map[ pos.y * _region_map_size + pos.x ] * bounds - 1;
	return vec3(uv - _region_offsets[layer_index], float(layer_index));
}


uniform float sea_level;


float get_height(vec2 uv) {
	highp float height = 0.0;
	height = sea_level;
 	return height;
}

vec3 gerstner(vec3 vertex, vec2 direction , float time, float speed , float steepness, float amplitude , float wavelength){
	float x = vertex.x + (steepness/ wavelength) * direction.x * cos(wavelength * dot(direction , vertex.xz) + speed * time);
	float z = vertex.z + (steepness/ wavelength) * direction.y * cos(wavelength * dot(direction , vertex.xz) + speed * time);
	float y = vertex.y + amplitude * sin(wavelength * dot(direction, vertex.xz) + speed * time);
	return vec3(x,y,z);
}


vec3 normal(vec3 vertex , vec2 direction, float time , float speed , float steepness , float amplitude , float wavelength){
	float cosfactor = cos(wavelength * dot(direction , vertex.xz + speed * time));
	float sinfactor = sin(wavelength * dot(direction , vertex.xz + speed * time));
	
	float x = -direction.x * wavelength * amplitude * cosfactor;
	float z = -direction.y * wavelength * amplitude * cosfactor;
	float y = 1.0 - (steepness/wavelength) * wavelength * amplitude * sinfactor;
	
	return vec3(x, y, z);
}

void vertex(){
	// Get camera pos in world vertex coords
    v_camera_pos = INV_VIEW_MATRIX[3].xyz;

	// Get vertex of flat plane in world coordinates and set world UV
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	
	// UV coordinates in world space. Values are 0 to _region_size within regions
	UV = round(v_vertex.xz * _mesh_vertex_density);

	// UV coordinates in region space + texel offset. Values are 0 to 1 within regions
	UV2 = (UV + vec2(0.5)) * _region_texel_size;

	// Get final vertex location and save it
	VERTEX.y = get_height(UV2);
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_vertex_dist = length(v_vertex - v_camera_pos);

	// Transform UVs to local to avoid poor precision during varying interpolation.
	v_uv_offset = MODEL_MATRIX[3].xz * _mesh_vertex_density;
	UV -= v_uv_offset;
	v_uv2_offset = v_uv_offset * _region_texel_size;
	UV2 -= v_uv2_offset;

	VERTEX += gerstner(VERTEX , normalize(Direction) , TIME , Speed , Steepness, Amplitude, 2.0/Wavelength);
	NORMAL += normal(VERTEX , normalize(Direction), TIME , Speed , Steepness , Amplitude , 2.0/Wavelength);
}

////////////////////////
// Fragment
////////////////////////

vec3 screen(vec3 base, vec3 blend){
	return 1.0 - (1.0 - base) * (1.0 - blend);
}

// 3 lookups
vec3 get_normal(vec2 uv, out vec3 tangent, out vec3 binormal) {
	// Get the height of the current vertex
	float height = get_height(uv);

	// Get the heights to the right and in front, but because of hardware 
	// interpolation on the edges of the heightmaps, the values are off
	// causing the normal map to look weird. So, near the edges of the map
	// get the heights to the left or behind instead. Hacky solution that 
	// reduces the artifact, but doesn't fix it entirely. See #185.
	float u, v;
	if(mod(uv.y*_region_size, _region_size) > _region_size-2.) {
		v = get_height(uv + vec2(0, -_region_texel_size)) - height;
	} else {
		v = height - get_height(uv + vec2(0, _region_texel_size));
	}
	if(mod(uv.x*_region_size, _region_size) > _region_size-2.) {
		u = get_height(uv + vec2(-_region_texel_size, 0)) - height;		
	} else {
		u = height - get_height(uv + vec2(_region_texel_size, 0));
	}

	vec3 normal = vec3(u, _mesh_vertex_spacing, v);
	normal = normalize(normal);
	tangent = cross(normal, vec3(0, 0, 1));
	binormal = cross(normal, tangent);
	return normal;
}

void fragment(){
	// Recover UVs
	vec2 uv = UV + v_uv_offset;
	vec2 uv2 = UV2 + v_uv2_offset;

	// Calculate Ocean Normals. 4 lookups
	vec3 w_tangent, w_binormal;
	vec3 w_normal = get_normal(uv2, w_tangent, w_binormal);
	NORMAL = mat3(VIEW_MATRIX) * w_normal;
	TANGENT = mat3(VIEW_MATRIX) * w_tangent;
	BINORMAL = mat3(VIEW_MATRIX) * w_binormal;

	// Depth texture magic
	float depth = texture(DEPTH_TEXTURE, SCREEN_UV, 0.0).r;
  	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	vec4 world = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	float depth_texture_y = world.y / world.w;
	float vertex_y = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).y;
	float vertical_depth = vertex_y - depth_texture_y;
	
	// Changes the color of geometry behind it as the water gets deeper
	float depth_fade_blend = exp(-vertical_depth / depth_fade_distance);
	depth_fade_blend = clamp(depth_fade_blend, 0.0, 1.0);
	
	// Makes the water more transparent as it gets more shallow
	float alpha_blend = -vertical_depth * absorbance;
	alpha_blend = clamp(1.0 - exp(alpha_blend), 0.0, 1.0);
	
	// Small layer of foam
	float foam_blend = clamp(1.0 - (vertical_depth / foam_amount), 0.0, 1.0);
	vec3 foam = foam_blend * foam_color;
	
	// Mix them all together
	vec3 color_out = mix(deep_color, shallow_color, depth_fade_blend);
	color_out = screen(color_out, foam);

	ALBEDO = color_out;
	ALPHA = alpha_blend;
	ROUGHNESS = roughness;
}
)"