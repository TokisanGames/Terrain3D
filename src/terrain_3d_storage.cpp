// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>

#include "terrain_3d_logger.h"
#include "terrain_3d_storage.h"

///////////////////////////
// Subclass Functions
///////////////////////////

void Terrain3DStorage::Generated::create(const TypedArray<Image> &p_layers) {
	if (!p_layers.is_empty()) {
		_rid = RenderingServer::get_singleton()->texture_2d_layered_create(p_layers, RenderingServer::TEXTURE_LAYERED_2D_ARRAY);
		_dirty = false;
	} else {
		clear();
	}
}

void Terrain3DStorage::Generated::create(const Ref<Image> &p_image) {
	_image = p_image;
	_rid = RenderingServer::get_singleton()->texture_2d_create(_image);
	_dirty = false;
}

void Terrain3DStorage::Generated::clear() {
	if (_rid.is_valid()) {
		RenderingServer::get_singleton()->free_rid(_rid);
	}
	if (_image.is_valid()) {
		_image.unref();
	}
	_rid = RID();
	_dirty = true;
}

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DStorage::_clear() {
	RenderingServer::get_singleton()->free_rid(_material);
	RenderingServer::get_singleton()->free_rid(_shader);

	_generated_height_maps.clear();
	_generated_control_maps.clear();
	_generated_color_maps.clear();
	_generated_albedo_textures.clear();
	_generated_normal_textures.clear();
	_generated_region_map.clear();
	_generated_region_blend_map.clear();
}

void Terrain3DStorage::_update_surfaces() {
	LOG(INFO, "Regenerating material surfaces");

	for (int i = 0; i < get_surface_count(); i++) {
		Ref<Terrain3DSurface> surface = _surfaces[i];

		if (surface.is_null()) {
			continue;
		}
		if (!surface->is_connected("texture_changed", Callable(this, "update_surface_textures"))) {
			surface->connect("texture_changed", Callable(this, "update_surface_textures"));
		}
		if (!surface->is_connected("value_changed", Callable(this, "update_surface_values"))) {
			surface->connect("value_changed", Callable(this, "update_surface_values"));
		}
	}
	_generated_albedo_textures.clear();
	_generated_normal_textures.clear();

	_update_surface_data(true, true);
}

void Terrain3DStorage::_update_surface_data(bool p_update_textures, bool p_update_values) {
	if (p_update_textures) {
		LOG(INFO, "Regenerating terrain textures");
		// Update materials to enable sub-materials if albedo is available
		// and '_surfaces_enabled' changes from previous state

		bool was_surfaces_enabled = _surfaces_enabled;
		_surfaces_enabled = false;

		Vector2i albedo_size = Vector2i(0, 0);
		Vector2i normal_size = Vector2i(0, 0);

		// Get image size
		for (int i = 0; i < get_surface_count(); i++) {
			Ref<Terrain3DSurface> surface = _surfaces[i];

			if (surface.is_null()) {
				continue;
			}

			Ref<Texture2D> alb_tex = surface->get_albedo_texture();
			Ref<Texture2D> nor_tex = surface->get_normal_texture();

			if (alb_tex.is_valid()) {
				Vector2i tex_size = alb_tex->get_size();
				if (albedo_size.length() == 0.0) {
					albedo_size = tex_size;
				} else {
					ERR_FAIL_COND_MSG(tex_size != albedo_size, "Albedo textures do not have same size!");
				}
			}
			if (nor_tex.is_valid()) {
				Vector2i tex_size = nor_tex->get_size();
				if (normal_size.length() == 0.0) {
					normal_size = tex_size;
				} else {
					ERR_FAIL_COND_MSG(tex_size != normal_size, "Normal map textures do not have same size!");
				}
			}
		}

		if (normal_size == Vector2i(0, 0)) {
			normal_size = albedo_size;
		} else if (albedo_size == Vector2i(0, 0)) {
			albedo_size = normal_size;
		}

		// Generate TextureArrays and replace nulls with a empty image
		if (_generated_albedo_textures.is_dirty() && albedo_size != Vector2i(0, 0)) {
			LOG(INFO, "Regenerating terrain albedo arrays");

			Array albedo_texture_array;

			for (int i = 0; i < get_surface_count(); i++) {
				Ref<Terrain3DSurface> surface = _surfaces[i];

				if (surface.is_null()) {
					continue;
				}

				Ref<Texture2D> tex = surface->get_albedo_texture();
				Ref<Image> img;

				if (tex.is_null()) {
					img = get_filled_image(albedo_size, COLOR_RB, true, Image::FORMAT_RGBA8);
					img->compress(Image::COMPRESS_S3TC, Image::COMPRESS_SOURCE_SRGB);
				} else {
					img = tex->get_image();
				}

				albedo_texture_array.push_back(img);
			}

			if (!albedo_texture_array.is_empty()) {
				_generated_albedo_textures.create(albedo_texture_array);
				_surfaces_enabled = true;
			}
		}

		if (_generated_normal_textures.is_dirty() && normal_size != Vector2i(0, 0)) {
			LOG(INFO, "Regenerating terrain normal arrays");

			Array normal_texture_array;

			for (int i = 0; i < get_surface_count(); i++) {
				Ref<Terrain3DSurface> surface = _surfaces[i];

				if (surface.is_null()) {
					continue;
				}

				Ref<Texture2D> tex = surface->get_normal_texture();
				Ref<Image> img;

				if (tex.is_null()) {
					img = get_filled_image(normal_size, COLOR_NORMAL, true, Image::FORMAT_RGBA8);
					img->compress(Image::COMPRESS_S3TC, Image::COMPRESS_SOURCE_SRGB);
				} else {
					img = tex->get_image();
				}

				normal_texture_array.push_back(img);
			}
			if (!normal_texture_array.is_empty()) {
				_generated_normal_textures.create(normal_texture_array);
			}
		}

		if (was_surfaces_enabled != _surfaces_enabled) {
			_update_material();
		}

		RenderingServer::get_singleton()->material_set_param(_material, "texture_array_albedo", _generated_albedo_textures.get_rid());
		RenderingServer::get_singleton()->material_set_param(_material, "texture_array_normal", _generated_normal_textures.get_rid());
		_modified = true;
	}

	if (p_update_values) {
		LOG(INFO, "Updating terrain color and scale arrays");
		PackedVector3Array uv_scales;
		PackedFloat32Array uv_rotations;
		PackedColorArray colors;

		for (int i = 0; i < get_surface_count(); i++) {
			Ref<Terrain3DSurface> surface = _surfaces[i];

			if (surface.is_null()) {
				continue;
			}
			uv_scales.push_back(surface->get_uv_scale());
			uv_rotations.push_back(surface->get_uv_rotation());

			colors.push_back(surface->get_albedo());
		}

		RenderingServer::get_singleton()->material_set_param(_material, "texture_uv_rotation_array", uv_rotations);
		RenderingServer::get_singleton()->material_set_param(_material, "texture_uv_scale_array", uv_scales);
		RenderingServer::get_singleton()->material_set_param(_material, "texture_color_array", colors);
		_modified = true;
	}
}

void Terrain3DStorage::_update_regions() {
	if (_generated_height_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating height layered texture from ", _height_maps.size(), " maps");
		_generated_height_maps.create(_height_maps);
		RenderingServer::get_singleton()->material_set_param(_material, "height_maps", _generated_height_maps.get_rid());
		_modified = true;
		emit_signal("height_maps_changed");
	}

	if (_generated_control_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating control layered texture from ", _control_maps.size(), " maps");
		_generated_control_maps.create(_control_maps);
		RenderingServer::get_singleton()->material_set_param(_material, "control_maps", _generated_control_maps.get_rid());
		_modified = true;
	}

	if (_generated_color_maps.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating color layered texture from ", _color_maps.size(), " maps");
		_generated_color_maps.create(_color_maps);
		RenderingServer::get_singleton()->material_set_param(_material, "color_maps", _generated_color_maps.get_rid());
		_modified = true;
	}

	if (_generated_region_map.is_dirty()) {
		LOG(DEBUG_CONT, "Regenerating ", REGION_MAP_VSIZE, " region map");
		Ref<Image> region_map_img = get_filled_image(REGION_MAP_VSIZE, COLOR_BLACK, false, Image::FORMAT_RG8);

		for (int i = 0; i < _region_offsets.size(); i++) {
			Vector2i ofs = _region_offsets[i];

			Color col = Color(float(i + 1) / 255.0, 1.0, 0, 1);
			region_map_img->set_pixelv(ofs + (REGION_MAP_VSIZE / 2), col);
		}
		_generated_region_map.create(region_map_img);
		RenderingServer::get_singleton()->material_set_param(_material, "region_map", _generated_region_map.get_rid());
		RenderingServer::get_singleton()->material_set_param(_material, "region_map_size", REGION_MAP_SIZE);
		RenderingServer::get_singleton()->material_set_param(_material, "region_offsets", _region_offsets);
		_modified = true;

		if (_noise_enabled) {
			LOG(DEBUG_CONT, "Regenerating ", Vector2i(512, 512), " region blend map");
			Ref<Image> region_blend_img = Image::create(REGION_MAP_SIZE, REGION_MAP_SIZE, false, Image::FORMAT_RH);
			for (int y = 0; y < region_map_img->get_height(); y++) {
				for (int x = 0; x < region_map_img->get_width(); x++) {
					Color c = region_map_img->get_pixel(x, y);
					c.r = c.g;
					region_blend_img->set_pixel(x, y, c);
				}
			}
			//region_blend_img->resize(512, 512, Image::INTERPOLATE_NEAREST); // No blur for use with Gaussian blur to add later
			region_blend_img->resize(512, 512, Image::INTERPOLATE_LANCZOS); // Basic blur w/ subtle artifacts

			_generated_region_blend_map.create(region_blend_img);
			RenderingServer::get_singleton()->material_set_param(_material, "region_blend_map", _generated_region_blend_map.get_rid());
		}
	}
}

void Terrain3DStorage::_update_material() {
	LOG(INFO, "Updating material");
	if (!_material.is_valid()) {
		_material = RenderingServer::get_singleton()->material_create();
	}

	if (!_shader.is_valid()) {
		_shader = RenderingServer::get_singleton()->shader_create();
	}

	if (_shader_override_enabled && _shader_override.is_valid()) {
		RenderingServer::get_singleton()->material_set_shader(_material, _shader_override->get_rid());
	} else {
		RenderingServer::get_singleton()->shader_set_code(_shader, _generate_shader_code());
		RenderingServer::get_singleton()->material_set_shader(_material, _shader);
	}

	RenderingServer::get_singleton()->material_set_param(_material, "region_size", _region_size);
	RenderingServer::get_singleton()->material_set_param(_material, "region_pixel_size", 1.0f / float(_region_size));
	_modified = true;
}

String Terrain3DStorage::_generate_shader_code() {
	LOG(INFO, "Generating default shader code");
	String code = "shader_type spatial;\n";
	code += "render_mode depth_draw_opaque, diffuse_burley;\n";
	code += "\n";

	//Uniforms
	code += "uniform float region_size = 1024.0;\n";
	code += "uniform float region_pixel_size = 1.0;\n";
	code += "uniform int region_map_size = 16;\n";
	code += "\n\n";

	code += "uniform sampler2D region_map : hint_default_black, filter_linear, repeat_disable;\n";
	code += "uniform vec2 region_offsets[256];\n";
	code += "uniform sampler2DArray height_maps : filter_linear_mipmap, repeat_disable;\n";
	code += "uniform sampler2DArray control_maps : filter_linear_mipmap, repeat_disable;\n";
	code += "uniform sampler2DArray color_maps : filter_linear_mipmap, repeat_disable;\n";
	code += "\n\n";

	if (_surfaces_enabled) {
		LOG(INFO, "Surfaces enabled");
		code += "uniform sampler2DArray texture_array_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;\n";
		code += "uniform sampler2DArray texture_array_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;\n";
		code += "uniform vec3 texture_uv_scale_array[32];\n";
		code += "uniform float texture_uv_rotation_array[32];\n";
		code += "uniform vec3 texture_3d_projection_array[32];\n";
		code += "uniform vec4 texture_color_array[32];\n";
		code += "\n\n";
	}

	if (_noise_enabled) {
		code += "uniform sampler2D region_blend_map : hint_default_black, filter_linear, repeat_disable;\n";
		code += "uniform float noise_scale = 2.0;\n";
		code += "uniform float noise_height = 300.0;\n";
		code += "uniform float noise_blend_near = 0.5;\n";
		code += "uniform float noise_blend_far = 1.0;\n";
		code += "\n\n";

		code += "float hashv2(vec2 v) {\n ";
		code += "	return fract(1e4 * sin(17.0 * v.x + v.y * 0.1) * (0.1 + abs(sin(v.y * 13.0 + v.x))));\n ";
		code += "}\n\n";

		code += "float noise2D(vec2 st) {\n";
		code += "	vec2 i = floor(st);\n";
		code += "	vec2 f = fract(st);\n";
		code += "\n";
		code += "	// Four corners in 2D of a tile\n";
		code += "	float a = hashv2(i);\n";
		code += "	float b = hashv2(i + vec2(1.0, 0.0));\n";
		code += "	float c = hashv2(i + vec2(0.0, 1.0));\n";
		code += "	float d = hashv2(i + vec2(1.0, 1.0));\n";
		code += "\n";
		code += "	// Cubic Hermine Curve.  Same as SmoothStep()\n";
		code += "	vec2 u = f * f * (3.0 - 2.0 * f);\n";
		code += "\n";
		code += "	// Mix 4 corners percentages\n";
		code += "	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;\n";
		code += "}\n\n";
	}
	code += "\n";

	//Functions

	code += "vec3 unpack_normal(vec4 rgba) {\n";
	code += "	vec3 n = rgba.xzy * 2.0 - vec3(1.0);\n";
	code += "	n.z *= -1.0;\n";
	code += "	return n;\n";
	code += "}\n\n";

	code += "vec4 pack_normal(vec3 n, float a) {\n";
	code += "	n.z *= -1.0;\n";
	code += "	return vec4((n.xzy + vec3(1.0)) * 0.5, a);\n";
	code += "}\n\n";

	code += "// Takes in a world UV, returns UV in region space (0-region_size)\n";
	code += "// Z is the index in the map texturearray\n";
	code += "// If the UV is not in a region, Z=-1\n";
	code += "ivec3 get_region(vec2 uv) {\n";
	code += "	float index = floor(texelFetch(region_map, ivec2(floor(uv)) + (region_map_size / 2), 0).r * 255.0) - 1.0;\n";
	code += "	return ivec3(ivec2((uv - region_offsets[int(index)]) * region_size), int(index));\n";
	code += "}\n\n";

	code += "// float form of get_region. Same return values\n";
	code += "vec3 get_regionf(vec2 uv) {\n";
	code += "	float index = floor(texelFetch(region_map, ivec2(floor(uv)) + (region_map_size / 2), 0).r * 255.0) - 1.0;\n";
	code += "	return vec3(uv - region_offsets[int(index)], index);\n";
	code += "}\n\n";

	code += "float get_height(vec2 uv) {\n";
	code += "	float height = 0.0;\n\n";
	code += "	vec3 region = get_regionf(uv);\n";
	code += "	if (region.z >= 0.) {\n";
	code += "		height = texture(height_maps, region).r;\n";
	code += "	}\n";

	if (_noise_enabled) {
		code += "	float weight = texture(region_blend_map, (uv/float(region_map_size))+0.5).r;\n";
		code += "	height = mix(height, noise2D(uv * noise_scale) * noise_height, \n";
		code += "		clamp(smoothstep(noise_blend_near, noise_blend_far, 1.0 - weight), 0.0, 1.0));\n ";
	}

	code += "	return height;\n";
	code += "}\n\n";

	if (_surfaces_enabled) {
		code += "float random(in vec2 xy) {\n";
		code += "	return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);\n";
		code += "}\n\n";

		code += "float blend_weights(float weight, float detail) {\n";
		code += "	weight = sqrt(weight * 0.5);\n";
		code += "	float result = max(0.1 * weight, 10.0 * (weight + detail) + 1.0f - (detail + 10.0));\n";
		code += "	return result;\n";
		code += "}\n\n";

		code += "vec4 depth_blend(vec4 a_value, float a_bump, vec4 b_value, float b_bump, float t) {\n";
		code += "	float ma = max(a_bump + (1.0 - t), b_bump + t) - 0.1;\n";
		code += "	float ba = max(a_bump + (1.0 - t) - ma, 0.0);\n";
		code += "	float bb = max(b_bump + t - ma, 0.0);\n";
		code += "	return (a_value * ba + b_value * bb) / (ba + bb);\n";
		code += "}\n\n";

		code += "vec2 rotate(vec2 v, float cosa, float sina) {\n";
		code += "	return vec2(cosa * v.x - sina * v.y, sina * v.x + cosa * v.y);\n";
		code += "}\n\n";

		code += "// One big mess here.Optimized version of what it was in my GDScript terrain plugin.- outobugi\n";
		code += "// Using 'else' caused fps drops.If - else works the same as a ternary, where both outcomes are evaluated. Right?\n";

		code += "vec4 get_material(vec2 uv, vec4 index, vec2 uv_center, float weight, inout float total_weight, inout vec4 out_normal) {\n";
		code += "	float material = index.r * 255.0;\n";
		code += "	float materialOverlay = index.g * 255.0;\n";
		code += "	float r = random(uv_center) * PI;\n";
		code += "	float rand = r * texture_uv_rotation_array[int(material)];\n";
		code += "	float rand2 = r * texture_uv_rotation_array[int(materialOverlay)];\n";
		code += "	vec2 rot = vec2(sin(rand), cos(rand));\n";
		code += "	vec2 rot2 = vec2(sin(rand2), cos(rand2));\n";
		code += "	vec2 matUV = rotate(uv, rot.x, rot.y) * texture_uv_scale_array[int(material)].xy;\n";
		code += "	vec2 matUV2 = rotate(uv, rot2.x, rot2.y) * texture_uv_scale_array[int(materialOverlay)].xy;\n";
		code += "	vec2 ddx = dFdx(matUV);\n";
		code += "	vec2 ddy = dFdy(matUV);\n";
		code += "	vec4 albedo = vec4(1.0);\n";
		code += "	vec4 normal = vec4(0.5);\n\n";
		code += "	albedo = textureGrad(texture_array_albedo, vec3(matUV, material), ddx, ddy);\n";
		code += "	albedo.rgb *= texture_color_array[int(material)].rgb;\n";
		code += "	normal = textureGrad(texture_array_normal, vec3(matUV, material), ddx, ddy);\n";
		code += "	normal.rgb = normalize(normal.rgb);\n";
		code += "	vec3 n = unpack_normal(normal);\n";
		code += "	normal.xz = rotate(n.xz, rot.x, -rot.y);\n";
		code += "\n";
		code += "	if (index.b > 0.0) {\n";
		code += "		ddx = dFdx(matUV2);\n";
		code += "		ddy = dFdy(matUV2);\n";
		code += "		vec4 albedo2 = textureGrad(texture_array_albedo, vec3(matUV2, materialOverlay), ddx, ddy);\n";
		code += "		albedo2.rgb *= texture_color_array[int(materialOverlay)].rgb;\n";
		code += "		vec4 normal2 = textureGrad(texture_array_normal, vec3(matUV2, materialOverlay), ddx, ddy);\n";
		code += "		normal2.rgb = normalize(normal2.rgb);\n";
		code += "		n = unpack_normal(normal2);\n";
		code += "		normal2.xz = rotate(n.xz, rot2.x, -rot2.y);\n";
		code += "		albedo = depth_blend(albedo, albedo.a, albedo2, albedo2.a, index.b);\n";
		code += "		normal = depth_blend(normal, albedo.a, normal2, albedo.a, index.b);\n";
		code += "	}\n\n";

		code += "	normal = pack_normal(normal.xyz, normal.a);\n";
		code += "	weight = blend_weights(weight, albedo.a);\n";
		code += "	out_normal += normal * weight;\n";
		code += "	total_weight += weight;\n";
		code += "	return albedo * weight;\n";
		code += "}\n\n";
	}

	// Vertex Shader
	code += "void vertex() {\n";
	code += "	vec3 world_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;\n";
	code += "	UV2 = ((world_vertex.xz - vec2(0.5)) / vec2(region_size)) + vec2(0.5);\n";
	code += "	UV = world_vertex.xz * 0.5;\n\n";

	code += "	VERTEX.y = get_height(UV2);\n";
	code += "	NORMAL = vec3(0, 1, 0);\n";
	code += "}\n\n";

	// Fragment Shader
	code += "void fragment() {\n";

	code += "	// Normal calc\n";
	code += "	// Control map is also sampled 4 times, so in theory we could reduce the region samples to 4 from 8,\n";
	code += "	// but control map sampling is slightly different with the mirroring and doesn't work here.\n";
	code += "	// The region map is very, very small, so maybe the performance cost isn't too high\n\n";
	code += "	float left = get_height(UV2 + vec2(-region_pixel_size, 0));\n";
	code += "	float right = get_height(UV2 + vec2(region_pixel_size, 0));\n";
	code += "	float back = get_height(UV2 + vec2(0, -region_pixel_size));\n";
	code += "	float fore = get_height(UV2 + vec2(0, region_pixel_size));\n\n";

	code += "	vec3 horizontal = vec3(2.0, right - left, 0.0);\n";
	code += "	vec3 vertical = vec3(0.0, back - fore, 2.0);\n";
	code += "	vec3 normal = normalize(cross(vertical, horizontal));\n";
	code += "	normal.z *= -1.0;\n\n";

	code += "	NORMAL = mat3(VIEW_MATRIX) * normal;\n";
	code += "	TANGENT = cross(NORMAL, vec3(0, 0, 1));\n";
	code += "	BINORMAL = cross(NORMAL, TANGENT);\n";
	code += "\n";

	if (_surfaces_enabled) {
		code += "	// source : https://github.com/cdxntchou/IndexMapTerrain\n";
		code += "	// black magic which I don't understand at all. Seems simple but what and why?\n";
		code += "	vec2 pos_texel = UV2 * region_size + 0.5;\n";
		code += "	vec2 pos_texel00 = floor(pos_texel);\n";
		code += "	vec4 mirror = vec4(fract(pos_texel00 * 0.5) * 2.0, 1.0, 1.0);\n";
		code += "	mirror.zw = vec2(1.0) - mirror.xy;\n\n";

		code += "	ivec3 index00UV = get_region((pos_texel00 + mirror.xy) * region_pixel_size);\n";
		code += "	ivec3 index01UV = get_region((pos_texel00 + mirror.xw) * region_pixel_size);\n";
		code += "	ivec3 index10UV = get_region((pos_texel00 + mirror.zy) * region_pixel_size);\n";
		code += "	ivec3 index11UV = get_region((pos_texel00 + mirror.zw) * region_pixel_size);\n\n";

		code += "	vec4 index00 = texelFetch(control_maps, index00UV, 0);\n";
		code += "	vec4 index01 = texelFetch(control_maps, index01UV, 0);\n";
		code += "	vec4 index10 = texelFetch(control_maps, index10UV, 0);\n";
		code += "	vec4 index11 = texelFetch(control_maps, index11UV, 0);\n\n";

		code += "	vec2 weights1 = clamp(pos_texel - pos_texel00, 0, 1);\n";
		code += "	weights1 = mix(weights1, vec2(1.0) - weights1, mirror.xy);\n";
		code += "	vec2 weights0 = vec2(1.0) - weights1;\n\n";

		code += "	float total_weight = 0.0;\n";
		code += "	vec4 in_normal = vec4(0.0);\n";
		code += "	vec3 color = vec3(0.0);\n\n";

		code += "	color = get_material(UV, index00, vec2(index00UV.xy), weights0.x * weights0.y, total_weight, in_normal).rgb;\n";
		code += "	color += get_material(UV, index01, vec2(index01UV.xy), weights0.x * weights1.y, total_weight, in_normal).rgb;\n";
		code += "	color += get_material(UV, index10, vec2(index10UV.xy), weights1.x * weights0.y, total_weight, in_normal).rgb;\n";
		code += "	color += get_material(UV, index11, vec2(index11UV.xy), weights1.x * weights1.y, total_weight, in_normal).rgb;\n";

		code += "	total_weight = 1.0 / total_weight;\n";
		code += "	in_normal *= total_weight;\n";
		code += "	color *= total_weight;\n\n";

		code += "	// Look up colormap\n";
		code += "	vec3 ruv = get_regionf(UV2);\n";
		code += "	vec4 color_tex = vec4(1., 1., 1., .5);\n";
		code += "	if (ruv.z >= 0.) {\n";
		code += "		color_tex = texture(color_maps, ruv);\n";
		code += "	}\n\n";

		code += "	ALBEDO = color * color_tex.rgb;\n";
		code += "	ROUGHNESS = clamp(fma(color_tex.a-0.5, 2.0, in_normal.a), 0., 1.);\n";
		code += "	NORMAL_MAP = in_normal.rgb;\n";
		code += "	NORMAL_MAP_DEPTH = 1.0;\n";

	} else {
		code += "	vec2 p = UV * 4.0;\n";
		code += "	vec2 ddx = dFdx(p);\n";
		code += "	vec2 ddy = dFdy(p);\n";
		code += "	vec2 w = max(abs(ddx), abs(ddy)) + 0.01;\n";
		code += "	vec2 i = 2.0 * (abs(fract((p - 0.5 * w) / 2.0) - 0.5) - abs(fract((p + 0.5 * w) / 2.0) - 0.5)) / w;\n";
		code += "	ALBEDO = vec3((0.5 - 0.5 * i.x * i.y) * 0.2 + 0.2);\n";
		code += "\n";
	}
	code += "}\n\n";

	return String(code);
}

///////////////////////////
// Public Functions
///////////////////////////

Terrain3DStorage::Terrain3DStorage() {
	if (!_initialized) {
		LOG(INFO, "Initializing terrain storage");
		_update_material();
		_initialized = true;
	}
}

Terrain3DStorage::~Terrain3DStorage() {
	if (_initialized) {
		_clear();
	}
}

void Terrain3DStorage::set_region_size(RegionSize p_size) {
	LOG(INFO, "Setting region size: ", p_size);
	//ERR_FAIL_COND(p_size < SIZE_64);
	//ERR_FAIL_COND(p_size > SIZE_2048);
	ERR_FAIL_COND(p_size != SIZE_1024);

	_region_size = p_size;
	_region_sizev = Vector2i(_region_size, _region_size);
	RenderingServer::get_singleton()->material_set_param(_material, "region_size", float(_region_size));
	RenderingServer::get_singleton()->material_set_param(_material, "region_pixel_size", 1.0f / float(_region_size));
}

void Terrain3DStorage::update_heights(float p_height) {
	if (p_height < _height_range.x) {
		_height_range.x = p_height;
	} else if (p_height > _height_range.y) {
		_height_range.y = p_height;
	}
}

void Terrain3DStorage::update_heights(Vector2 p_heights) {
	if (p_heights.x < _height_range.x) {
		_height_range.x = p_heights.x;
	}
	if (p_heights.y > _height_range.y) {
		_height_range.y = p_heights.y;
	}
}

void Terrain3DStorage::update_height_range() {
	_height_range = Vector2(0, 0);
	for (int i = 0; i < _height_maps.size(); i++) {
		update_heights(get_min_max(_height_maps[i]));
	}
	LOG(INFO, "Updated terrain height range: ", _height_range);
}

void Terrain3DStorage::set_region_offsets(const TypedArray<Vector2i> &p_array) {
	LOG(INFO, "Setting region offsets with array sized: ", p_array.size());
	_region_offsets = p_array;

	_generated_region_map.clear();
	_generated_region_blend_map.clear();
	_update_regions();
}

/** Returns a region offset given a location */
Vector2i Terrain3DStorage::get_region_offset(Vector3 p_global_position) {
	return Vector2i((Vector2(p_global_position.x, p_global_position.z) / float(_region_size) + Vector2(0.5, 0.5)).floor());
}

int Terrain3DStorage::get_region_index(Vector3 p_global_position) {
	Vector2i uv_offset = get_region_offset(p_global_position);
	int index = -1;

	if (ABS(uv_offset.x) > REGION_MAP_SIZE / 2 || ABS(uv_offset.y) > REGION_MAP_SIZE / 2) {
		return index;
	}

	Ref<Image> img = _generated_region_map.get_image();

	if (img.is_valid()) {
		index = int(img->get_pixelv(uv_offset + (REGION_MAP_VSIZE / 2)).r * 255.0) - 1;
	} else {
		for (int i = 0; i < _region_offsets.size(); i++) {
			Vector2i ofs = _region_offsets[i];
			if (ofs == uv_offset) {
				index = i;
				break;
			}
		}
	}
	return index;
}

/** Adds a region to the terrain
 * Option to include an array of Images to use for maps
 * Map types are Height:0, Control:1, Color:2, defined in MapType
 * If the region already exists and maps are included, the current maps will be overwritten
 * Parameters:
 *	p_global_position - the world location to place the region, rounded down to the nearest region_size multiple
 *	p_images - Optional array of [ Height, Control, Color ... ] w/ region_sized images
 *	p_update - rebuild the maps if true. Set to false if bulk adding many regions.
 */
Error Terrain3DStorage::add_region(Vector3 p_global_position, const TypedArray<Image> &p_images, bool p_update) {
	Vector2i uv_offset = get_region_offset(p_global_position);
	LOG(INFO, "Adding region at ", p_global_position, ", uv_offset ", uv_offset,
			", array size: ", p_images.size(),
			", update maps: ", p_update ? "yes" : "no");

	if (ABS(uv_offset.x) > REGION_MAP_SIZE / 2 || ABS(uv_offset.y) > REGION_MAP_SIZE / 2) {
		LOG(ERROR, "Specified position outside of maximum region map size: ", REGION_MAP_SIZE / 2 * _region_size);
		return FAILED;
	}

	if (has_region(p_global_position)) {
		if (p_images.is_empty()) {
			LOG(DEBUG, "Region at ", p_global_position, " already exists and nothing to overwrite. Doing nothing");
			return OK;
		} else {
			LOG(DEBUG, "Region at ", p_global_position, " already exists, overwriting");
			remove_region(p_global_position, false);
		}
	}

	TypedArray<Image> images = sanitize_maps(TYPE_MAX, p_images);
	if (images.is_empty()) {
		LOG(ERROR, "Sanitize_maps failed to accept images or produce blanks");
		return FAILED;
	}

	// If we're importing data into a region, check its heights for aabbs
	Vector2 min_max = Vector2(0, 0);
	if (p_images.size() > TYPE_HEIGHT) {
		min_max = get_min_max(images[TYPE_HEIGHT]);
		LOG(DEBUG, "Checking imported height range: ", min_max);
		update_heights(min_max);
	}

	LOG(DEBUG, "Pushing back ", images.size(), " images");
	_height_maps.push_back(images[TYPE_HEIGHT]);
	_control_maps.push_back(images[TYPE_CONTROL]);
	_color_maps.push_back(images[TYPE_COLOR]);
	_region_offsets.push_back(uv_offset);
	LOG(DEBUG, "Total regions after pushback: ", _region_offsets.size());

	// Region maps used by get_region_index so must be updated every time
	_generated_region_map.clear();
	_generated_region_blend_map.clear();
	if (p_update) {
		LOG(DEBUG, "Updating generated maps");
		_generated_height_maps.clear();
		_generated_control_maps.clear();
		_generated_color_maps.clear();
		_update_regions();
		notify_property_list_changed();
		emit_changed();
	} else {
		_update_regions();
	}
	return OK;
}

void Terrain3DStorage::remove_region(Vector3 p_global_position, bool p_update) {
	LOG(INFO, "Removing region at ", p_global_position, " Updating: ", p_update ? "yes" : "no");

	int index = get_region_index(p_global_position);
	ERR_FAIL_COND_MSG(index == -1, "Map does not exist.");

	LOG(INFO, "Removing region at: ", get_region_offset(p_global_position));
	_region_offsets.remove_at(index);
	LOG(DEBUG, "Removed region_offsets, new size: ", _region_offsets.size());
	_height_maps.remove_at(index);
	LOG(DEBUG, "Removed heightmaps, new size: ", _height_maps.size());
	_control_maps.remove_at(index);
	LOG(DEBUG, "Removed control maps, new size: ", _control_maps.size());
	_color_maps.remove_at(index);
	LOG(DEBUG, "Removed colormaps, new size: ", _color_maps.size());

	if (_height_maps.size() == 0) {
		_height_range = Vector2(0, 0);
	}

	// Region maps used by get_region_index so must be updated
	_generated_region_map.clear();
	_generated_region_blend_map.clear();
	if (p_update) {
		LOG(DEBUG, "Updating generated maps");
		_generated_height_maps.clear();
		_generated_control_maps.clear();
		_generated_color_maps.clear();
		_update_regions();
		notify_property_list_changed();
		emit_changed();
	} else {
		_update_regions();
	}
}

void Terrain3DStorage::set_map_region(MapType p_map_type, int p_region_index, const Ref<Image> p_image) {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			if (p_region_index >= 0 && p_region_index < _height_maps.size()) {
				_height_maps[p_region_index] = p_image;
			} else {
				LOG(ERROR, "Requested index is out of bounds. height_maps size: ", _height_maps.size());
			}
			break;
		case TYPE_CONTROL:
			if (p_region_index >= 0 && p_region_index < _control_maps.size()) {
				_control_maps[p_region_index] = p_image;
			} else {
				LOG(ERROR, "Requested index is out of bounds. control_maps size: ", _control_maps.size());
			}
			break;
		case TYPE_COLOR:
			if (p_region_index >= 0 && p_region_index < _color_maps.size()) {
				_color_maps[p_region_index] = p_image;
			} else {
				LOG(ERROR, "Requested index is out of bounds. color_maps size: ", _color_maps.size());
			}
			break;
		default:
			LOG(ERROR, "Requested map type is invalid");
			break;
	}
}

Ref<Image> Terrain3DStorage::get_map_region(MapType p_map_type, int p_region_index) const {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			if (p_region_index >= 0 && p_region_index < _height_maps.size()) {
				return _height_maps[p_region_index];
			} else {
				LOG(ERROR, "Requested index is out of bounds. height_maps size: ", _height_maps.size());
			}
			break;
		case TYPE_CONTROL:
			if (p_region_index >= 0 && p_region_index < _control_maps.size()) {
				return _control_maps[p_region_index];
			} else {
				LOG(ERROR, "Requested index is out of bounds. control_maps size: ", _control_maps.size());
			}
			break;
		case TYPE_COLOR:
			if (p_region_index >= 0 && p_region_index < _color_maps.size()) {
				return _color_maps[p_region_index];
			} else {
				LOG(ERROR, "Requested index is out of bounds. color_maps size: ", _color_maps.size());
			}
			break;
		default:
			LOG(ERROR, "Requested map type is invalid");
			break;
	}
	return Ref<Image>();
}

void Terrain3DStorage::set_maps(MapType p_map_type, const TypedArray<Image> &p_maps) {
	ERR_FAIL_COND_MSG(p_map_type < 0 || p_map_type >= TYPE_MAX, "Specified map type out of range");
	switch (p_map_type) {
		case TYPE_HEIGHT:
			set_height_maps(p_maps);
			break;
		case TYPE_CONTROL:
			set_control_maps(p_maps);
			break;
		case TYPE_COLOR:
			set_color_maps(p_maps);
			break;
		default:
			break;
	}
}

TypedArray<Image> Terrain3DStorage::get_maps(MapType p_map_type) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return TypedArray<Image>();
	}
	switch (p_map_type) {
		case TYPE_HEIGHT:
			return get_height_maps();
			break;
		case TYPE_CONTROL:
			return get_control_maps();
			break;
		case TYPE_COLOR:
			return get_color_maps();
			break;
		default:
			break;
	}
	return TypedArray<Image>();
}

TypedArray<Image> Terrain3DStorage::get_maps_copy(MapType p_map_type) const {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return TypedArray<Image>();
	}

	TypedArray<Image> maps = get_maps(p_map_type);
	TypedArray<Image> newmaps;
	newmaps.resize(maps.size());
	for (int i = 0; i < maps.size(); i++) {
		Ref<Image> img;
		img.instantiate();
		img->copy_from(maps[i]);
		newmaps[i] = img;
	}
	return newmaps;
}

void Terrain3DStorage::set_height_maps(const TypedArray<Image> &p_maps) {
	LOG(INFO, "Setting height maps: ", p_maps.size());
	_height_maps = sanitize_maps(TYPE_HEIGHT, p_maps);
	force_update_maps(TYPE_HEIGHT);
}

void Terrain3DStorage::set_control_maps(const TypedArray<Image> &p_maps) {
	LOG(INFO, "Setting control maps: ", p_maps.size());
	_control_maps = sanitize_maps(TYPE_CONTROL, p_maps);
	force_update_maps(TYPE_CONTROL);
}

void Terrain3DStorage::set_color_maps(const TypedArray<Image> &p_maps) {
	LOG(INFO, "Setting color maps: ", p_maps.size());
	_color_maps = sanitize_maps(TYPE_COLOR, p_maps);
	force_update_maps(TYPE_COLOR);
}

Color Terrain3DStorage::get_pixel(MapType p_map_type, Vector3 p_global_position) {
	if (p_map_type < 0 || p_map_type >= TYPE_MAX) {
		LOG(ERROR, "Specified map type out of range");
		return COLOR_ZERO;
	}

	int region = get_region_index(p_global_position);
	if (region < 0 || region >= _region_offsets.size()) {
		return COLOR_ZERO;
	}
	Ref<Image> map = get_map_region(p_map_type, region);
	Vector2i global_offset = Vector2i(get_region_offsets()[region]) * _region_size;
	Vector2i img_pos = Vector2i(
			Vector2(p_global_position.x - global_offset.x,
					p_global_position.z - global_offset.y)
					.floor() +
			_region_sizev / 2);
	return map->get_pixelv(img_pos);
}

Color Terrain3DStorage::get_color(Vector3 p_global_position) {
	Color clr = get_pixel(TYPE_COLOR, p_global_position);
	clr.a = 1.0;
	return clr;
}

/**
 * Returns sanitized maps of either a region set or a uniform set
 * Verifies size, vailidity, and format of maps
 * Creates filled blanks if lacking
 * p_map_type:
 *	TYPE_HEIGHT, TYPE_CONTROL, TYPE_COLOR: uniform set - p_maps are all the same type, size=N
 *	TYPE_MAX = region set - p_maps is [ height, control, color ], size=3
 **/
TypedArray<Image> Terrain3DStorage::sanitize_maps(MapType p_map_type, const TypedArray<Image> &p_maps) {
	LOG(INFO, "Verifying image set is valid: ", p_maps.size(), " maps of type: ", TYPESTR[TYPE_MAX]);

	TypedArray<Image> images;
	int iterations;

	if (p_map_type == TYPE_MAX) {
		images.resize(TYPE_MAX);
		iterations = TYPE_MAX;
	} else {
		images.resize(p_maps.size());
		iterations = p_maps.size();
		if (iterations <= 0) {
			LOG(DEBUG, "Empty Image set. Nothing to sanitize");
			return images;
		}
	}

	Image::Format format;
	const char *type_str;
	Color color;
	for (int i = 0; i < iterations; i++) {
		if (p_map_type == TYPE_MAX) {
			format = FORMAT[i];
			type_str = TYPESTR[i];
			color = COLOR[i];
		} else {
			format = FORMAT[p_map_type];
			type_str = TYPESTR[p_map_type];
			color = COLOR[p_map_type];
		}

		if (i < p_maps.size()) {
			Ref<Image> img;
			img = p_maps[i];
			if (img.is_valid()) {
				if (img->get_size() == _region_sizev) {
					if (img->get_format() == format) {
						LOG(DEBUG, "Map type ", type_str, " correct format, size. Using image");
						images[i] = img;
					} else {
						LOG(DEBUG, "Provided ", type_str, " map wrong format: ", img->get_format(), ". Converting copy to: ", format);
						Ref<Image> newimg;
						newimg.instantiate();
						newimg->copy_from(img);
						newimg->convert(format);
						images[i] = newimg;
					}
					continue; // Continue for loop
				} else {
					LOG(DEBUG, "Provided ", type_str, " map wrong size: ", img->get_size(), ". Creating blank");
				}
			} else {
				LOG(DEBUG, "No provided ", type_str, " map. Creating blank");
			}
		} else {
			LOG(DEBUG, "p_images.size() < ", i, ". Creating blank");
		}
		images[i] = get_filled_image(_region_sizev, color, false, format);
	}

	return images;
}

void Terrain3DStorage::save() {
	if (!_modified) {
		LOG(DEBUG, "Save requested, but not modified. Skipping");
		return;
	}
	String path = get_path();
	LOG(DEBUG, "Saving the terrain data to: " + path);
	if (path.get_extension() == "tres" || path.get_extension() == "res") {
		Error err;
		if (_save_16_bit) {
			LOG(DEBUG, "16-bit save requested, converting heightmaps");
			TypedArray<Image> original_maps;
			original_maps = get_maps_copy(Terrain3DStorage::MapType::TYPE_HEIGHT);
			for (int i = 0; i < _height_maps.size(); i++) {
				Ref<Image> img = _height_maps[i];
				img->convert(Image::FORMAT_RH);
			}
			LOG(DEBUG, "Images converted, saving");
			err = ResourceSaver::get_singleton()->save(this, path, ResourceSaver::FLAG_COMPRESS);

			LOG(DEBUG, "Restoring 32-bit maps");
			_height_maps = original_maps;

		} else {
			err = ResourceSaver::get_singleton()->save(this, path, ResourceSaver::FLAG_COMPRESS);
		}
		ERR_FAIL_COND(err);
		LOG(DEBUG, "ResourceSaver return error (0 is OK): ", err);
		if (err == OK) {
			_modified = false;
		}
	}
	LOG(INFO, "Finished saving terrain data");
}

/**
 * Loads a file from disk and returns an Image
 * Parameters:
 *	p_filename - file on disk to load. EXR, R16, PNG, or a ResourceLoader format (jpg, res, tres, etc)
 *	p_cache_mode - Send this flag to the resource loader to force caching or not
 *	p_height_range - R16 format: x=Min & y=Max value ranges. Required for R16 import
 *	p_size - R16 format: Image dimensions. Default (0,0) auto detects f/ square images. Required f/ non-square R16
 */
Ref<Image> Terrain3DStorage::load_image(String p_file_name, int p_cache_mode, Vector2 p_r16_height_range, Vector2i p_r16_size) {
	if (p_file_name.is_empty()) {
		LOG(ERROR, "No file specified. Nothing imported.");
		return Ref<Image>();
	}
	if (!FileAccess::file_exists(p_file_name)) {
		LOG(ERROR, "File ", p_file_name, " does not exist. Nothing to import.");
		return Ref<Image>();
	}

	// Load file based on extension
	Ref<Image> img;
	LOG(INFO, "Attempting to load: ", p_file_name);
	String ext = p_file_name.get_extension().to_lower();
	PackedStringArray imgloader_extensions = PackedStringArray(Array::make("bmp", "dds", "exr", "hdr", "jpg", "jpeg", "png", "tga", "svg", "webp"));

	// If R16 integer format (read/writeable by Krita)
	if (ext == "r16") {
		LOG(DEBUG, "Loading file as an r16");
		Ref<FileAccess> file = FileAccess::open(p_file_name, FileAccess::READ);
		// If p_size is zero, assume square and try to auto detect size
		if (p_r16_size <= Vector2i(0, 0)) {
			file->seek_end();
			int fsize = file->get_position();
			int fwidth = sqrt(fsize / 2);
			p_r16_size = Vector2i(fwidth, fwidth);
			LOG(DEBUG, "Total file size is: ", fsize, " calculated width: ", fwidth, " dimensions: ", p_r16_size);
			file->seek(0);
		}
		img = Image::create(p_r16_size.x, p_r16_size.y, false, FORMAT[TYPE_HEIGHT]);
		for (int y = 0; y < p_r16_size.y; y++) {
			for (int x = 0; x < p_r16_size.x; x++) {
				float h = float(file->get_16()) / 65535.0f;
				h = h * (p_r16_height_range.y - p_r16_height_range.x) + p_r16_height_range.x;
				img->set_pixel(x, y, Color(h, 0, 0));
			}
		}

		// If an Image extension, use Image loader
	} else if (imgloader_extensions.has(ext)) {
		LOG(DEBUG, "ImageFormatLoader loading recognized file type: ", ext);
		img = Image::load_from_file(p_file_name);

		// Else, see if Godot's resource loader will read it as an image: RES, TRES, etc
	} else {
		LOG(DEBUG, "Loading file as a resource");
		img = ResourceLoader::get_singleton()->load(p_file_name, "", static_cast<ResourceLoader::CacheMode>(p_cache_mode));
	}

	if (!img.is_valid()) {
		LOG(ERROR, "File", p_file_name, " could not be loaded.");
		return Ref<Image>();
	}
	if (img->is_empty()) {
		LOG(ERROR, "File", p_file_name, " is empty.");
		return Ref<Image>();
	}
	LOG(DEBUG, "Loaded Image size: ", img->get_size(), " format: ", img->get_format());
	return img;
}

/**
 * Imports an Image set (Height, Control, Color) into Terrain3DStorage
 * It does NOT normalize values to 0-1. You must do that using get_min_max() and adjusting scale and offset.
 * Parameters:
 *	p_images - MapType.TYPE_MAX sized array of Images for Height, Control, Color. Images can be blank or null
 *	p_global_position - X,0,Z location on the region map. Valid range is ~ (+/-8192, +/-8192)
 *	p_offset - Add this factor to all height values, can be negative
 *	p_scale - Scale all height values by this factor (applied after offset)
 */
void Terrain3DStorage::import_images(const TypedArray<Image> &p_images, Vector3 p_global_position, float p_offset, float p_scale) {
	if (p_images.size() != TYPE_MAX) {
		LOG(ERROR, "p_images.size() is ", p_images.size(), ". It should be ", TYPE_MAX, " even if some Images are blank or null");
		return;
	}

	Vector2i img_size = Vector2i(0, 0);
	for (int i = 0; i < TYPE_MAX; i++) {
		Ref<Image> img = p_images[i];
		if (img.is_valid() && !img->is_empty()) {
			LOG(INFO, "Importing image type ", TYPESTR[i], ", size: ", img->get_size(), ", format: ", img->get_format());
			if (i == TYPE_HEIGHT) {
				LOG(INFO, "Applying offset: ", p_offset, ", scale: ", p_scale);
			}
			if (img_size == Vector2i(0, 0)) {
				img_size = img->get_size();
			} else if (img_size != img->get_size()) {
				LOG(ERROR, "Included Images in p_images have different dimensions. Aborting import");
				return;
			}
		}
	}
	if (img_size == Vector2i(0, 0)) {
		LOG(ERROR, "All images are empty. Nothing to import");
		return;
	}

	int max_dimension = _region_size * REGION_MAP_SIZE / 2;
	if ((abs(p_global_position.x) > max_dimension) || (abs(p_global_position.z) > max_dimension)) {
		LOG(ERROR, "Specify a position within +/-", Vector3i(max_dimension, 0, max_dimension));
		return;
	}
	if ((p_global_position.x + img_size.x > max_dimension) ||
			(p_global_position.z + img_size.y > max_dimension)) {
		LOG(ERROR, img_size, " image will not fit at ", p_global_position,
				". Try ", -img_size / 2, " to center");
		return;
	}

	TypedArray<Image> tmp_images;
	tmp_images.resize(TYPE_MAX);

	for (int i = 0; i < TYPE_MAX; i++) {
		Ref<Image> img = p_images[i];
		tmp_images[i] = img;
		if (img.is_null()) {
			continue;
		}

		// Apply scale and offsets to a new heightmap if applicable
		if (i == TYPE_HEIGHT && (p_offset != 0 || p_scale != 1.0)) {
			LOG(DEBUG, "Creating new temp image to adjust scale: ", p_scale, " offset: ", p_offset);
			Ref<Image> newimg = Image::create(img->get_size().x, img->get_size().y, false, FORMAT[TYPE_HEIGHT]);
			for (int y = 0; y < img->get_height(); y++) {
				for (int x = 0; x < img->get_width(); x++) {
					Color clr = img->get_pixel(x, y);
					clr.r = (clr.r * p_scale) + p_offset;
					newimg->set_pixel(x, y, clr);
				}
			}
			tmp_images[i] = newimg;
		}
	}

	// Slice up incoming image into segments of region_size^2, and pad any remainder
	int slices_width = ceil(float(img_size.x) / float(_region_size));
	int slices_height = ceil(float(img_size.y) / float(_region_size));
	slices_width = CLAMP(slices_width, 1, REGION_MAP_SIZE);
	slices_height = CLAMP(slices_height, 1, REGION_MAP_SIZE);
	LOG(DEBUG, "Creating ", Vector2i(slices_width, slices_height), " slices for ", img_size, " images.");

	for (int y = 0; y < slices_height; y++) {
		for (int x = 0; x < slices_width; x++) {
			Vector2i start_coords = Vector2i(x * _region_size, y * _region_size);
			Vector2i end_coords = Vector2i((x + 1) * _region_size, (y + 1) * _region_size);
			LOG(DEBUG, "Reviewing image section ", start_coords, " to ", end_coords);

			Vector2i size_to_copy;
			if (end_coords.x <= img_size.x && end_coords.y <= img_size.y) {
				size_to_copy = _region_sizev;
			} else {
				size_to_copy.x = img_size.x - start_coords.x;
				size_to_copy.y = img_size.y - start_coords.y;
				LOG(DEBUG, "Uneven end piece. Copying padded slice ", Vector2i(x, y), " size to copy: ", size_to_copy);
			}

			LOG(DEBUG, "Copying ", size_to_copy, " sized segment");
			TypedArray<Image> images;
			images.resize(TYPE_MAX);
			for (int i = 0; i < TYPE_MAX; i++) {
				Ref<Image> img = tmp_images[i];
				Ref<Image> img_slice;
				if (img.is_valid() && !img->is_empty()) {
					img_slice = get_filled_image(_region_sizev, COLOR[i], false, img->get_format());
					img_slice->blit_rect(tmp_images[i], Rect2i(start_coords, size_to_copy), Vector2i(0, 0));
				} else {
					img_slice = get_filled_image(_region_sizev, COLOR[i], false, FORMAT[i]);
				}
				images[i] = img_slice;
			}
			// Add the heightmap slice and only regenerate on the last one
			Vector3 position = Vector3(p_global_position.x + start_coords.x, 0, p_global_position.z + start_coords.y);
			add_region(position, images, (x == slices_width - 1 && y == slices_height - 1));
		}
	} // for y < slices_height, x < slices_width
}

/** Exports a specified map as one of r16, exr, jpg, png, webp, res, tres
 * r16 or exr are recommended for roundtrip external editing
 * r16 can be edited by Krita, however you must know the dimensions and min/max before reimporting
 * res/tres allow storage in any of Godot's native Image formats.
 */
Error Terrain3DStorage::export_image(String p_file_name, MapType p_map_type) {
	if (p_file_name.is_empty()) {
		LOG(ERROR, "No file specified. Nothing to export");
		return FAILED;
	}
	if (get_region_count() == 0) {
		LOG(ERROR, "No valid regions. Nothing to export");
		return FAILED;
	}
	if (FileAccess::file_exists(p_file_name)) {
		LOG(INFO, "File ", p_file_name, " already exists. Attempting to overwrite");
		return FAILED;
	}

	Ref<Image> img;
	switch (p_map_type) {
		case TYPE_HEIGHT:
			img = _generated_height_maps.get_image();
			break;
		case TYPE_CONTROL:
			img = _generated_control_maps.get_image();
			break;
		case TYPE_COLOR:
			img = _generated_color_maps.get_image();
			break;
		default:
			LOG(ERROR, "Invalid map type specified: ", p_map_type, " max: ", TYPE_MAX - 1);
			return FAILED;
	}

	if (img.is_null()) {
		LOG(DEBUG, "Generated image is invalid or empty");
		img = layered_to_image(p_map_type);
	}
	if (img.is_valid() && !img->is_empty()) {
		LOG(DEBUG, "Have acquired generated map image. Size: ", img->get_size(), " format: ", img->get_format());
	} else {
		LOG(ERROR, "Could not create an export image for map type: ", TYPESTR[p_map_type]);
		return FAILED;
	}

	String ext = p_file_name.get_extension().to_lower();
	LOG(INFO, "Saving map type ", TYPESTR[p_map_type], " as ", ext, " to file: ", p_file_name);
	if (ext == "r16") {
		Vector2i minmax = get_min_max(img);
		Ref<FileAccess> file = FileAccess::open(p_file_name, FileAccess::WRITE);
		float height_min = minmax.x;
		float height_max = minmax.y;
		float hscale = 65535.0 / (height_max - height_min);
		for (int y = 0; y < img->get_height(); y++) {
			for (int x = 0; x < img->get_width(); x++) {
				int h = int((img->get_pixel(x, y).r - height_min) * hscale);
				h = CLAMP(h, 0, 65535);
				file->store_16(h);
			}
		}
		return file->get_error();
	} else if (ext == "exr") {
		return img->save_exr(p_file_name, (p_map_type == TYPE_HEIGHT) ? true : false);
	} else if (ext == "png") {
		return img->save_png(p_file_name);
	} else if (ext == "jpg") {
		return img->save_jpg(p_file_name);
	} else if (ext == "webp") {
		return img->save_webp(p_file_name);
	} else if ((ext == "res") || (ext == "tres")) {
		return ResourceSaver::get_singleton()->save(img, p_file_name, ResourceSaver::FLAG_COMPRESS);
	}

	return FAILED;
}

Ref<Image> Terrain3DStorage::layered_to_image(MapType p_map_type) {
	LOG(INFO, "Generating a full sized image for all regions including empty regions");
	if (p_map_type >= TYPE_MAX) {
		p_map_type = TYPE_HEIGHT;
	}
	Vector2i top_left = Vector2i(0, 0);
	Vector2i bottom_right = Vector2i(0, 0);
	for (int i = 0; i < _region_offsets.size(); i++) {
		LOG(DEBUG, "Region offsets[", i, "]: ", _region_offsets[i]);
		Vector2i region = _region_offsets[i];
		if (region.x < top_left.x) {
			top_left.x = region.x;
		} else if (region.x > bottom_right.x) {
			bottom_right.x = region.x;
		}
		if (region.y < top_left.y) {
			top_left.y = region.y;
		} else if (region.y > bottom_right.y) {
			bottom_right.y = region.y;
		}
	}

	LOG(DEBUG, "Full range to cover all regions: ", top_left, " to ", bottom_right);
	Vector2i img_size = Vector2i(1 + bottom_right.x - top_left.x, 1 + bottom_right.y - top_left.y) * _region_size;
	LOG(DEBUG, "Image size: ", img_size);
	Ref<Image> img = get_filled_image(img_size, COLOR[p_map_type], false, FORMAT[p_map_type]);

	for (int i = 0; i < _region_offsets.size(); i++) {
		Vector2i region = _region_offsets[i];
		int index = get_region_index(Vector3(region.x, 0, region.y) * _region_size);
		Vector2i img_location = (region - top_left) * _region_size;
		LOG(DEBUG, "Region to blit: ", region, " Export image coords: ", img_location);
		img->blit_rect(get_map_region(p_map_type, index), Rect2i(Vector2i(0, 0), _region_sizev), img_location);
	}
	return img;
}

/**
 * Returns the minimum and maximum values for a heightmap (red channel only)
 */
Vector2 Terrain3DStorage::get_min_max(const Ref<Image> p_image) {
	if (p_image.is_null()) {
		LOG(ERROR, "Provided image is not valid. Nothing to analyze");
		return Vector2(INFINITY, INFINITY);
	} else if (p_image->is_empty()) {
		LOG(ERROR, "Provided image is empty. Nothing to analyze");
		return Vector2(INFINITY, INFINITY);
	}

	Vector2 min_max = Vector2(0, 0);

	for (int y = 0; y < p_image->get_height(); y++) {
		for (int x = 0; x < p_image->get_width(); x++) {
			Color col = p_image->get_pixel(x, y);
			if (col.r < min_max.x) {
				min_max.x = col.r;
			}
			if (col.r > min_max.y) {
				min_max.y = col.r;
			}
		}
	}

	LOG(INFO, "Calculating minimum and maximum values of the image: ", min_max);
	return min_max;
}

/**
 * Returns a Image of a float heightmap normalized to RGB8 greyscale and scaled
 * Minimum of 8x8
 */
Ref<Image> Terrain3DStorage::get_thumbnail(const Ref<Image> p_image, Vector2i p_size) {
	if (p_image.is_null()) {
		LOG(ERROR, "Provided image is not valid. Nothing to process.");
		return Ref<Image>();
	} else if (p_image->is_empty()) {
		LOG(ERROR, "Provided image is empty. Nothing to process.");
		return Ref<Image>();
	}
	p_size.x = CLAMP(p_size.x, 8, 16384);
	p_size.y = CLAMP(p_size.y, 8, 16384);

	LOG(INFO, "Drawing a thumbnail sized: ", p_size);
	// Create a temporary work image scaled to desired width
	Ref<Image> img;
	img.instantiate();
	img->copy_from(p_image);
	img->resize(p_size.x, p_size.y, Image::INTERPOLATE_LANCZOS);

	// Get minimum and maximum height values on the scaled image
	Vector2 minmax = get_min_max(img);
	float hmin = minmax.x;
	float hmax = minmax.y;
	// Define maximum range
	hmin = abs(hmin);
	hmax = abs(hmax) + hmin;
	// Avoid divide by zero
	hmax = (hmax == 0) ? 0.001 : hmax;

	// Create a new image w / normalized values
	Ref<Image> thumb = Image::create(p_size.x, p_size.y, false, Image::FORMAT_RGB8);
	for (int y = 0; y < thumb->get_height(); y++) {
		for (int x = 0; x < thumb->get_width(); x++) {
			Color col = img->get_pixel(x, y);
			col.r = (col.r + hmin) / hmax;
			col.g = col.r;
			col.b = col.r;
			thumb->set_pixel(x, y, col);
		}
	}
	return thumb;
}

Ref<Image> Terrain3DStorage::get_filled_image(Vector2i p_size, Color p_color, bool p_create_mipmaps, Image::Format p_format) {
	Ref<Image> img = Image::create(p_size.x, p_size.y, p_create_mipmaps, p_format);
	img->fill(p_color);
	if (p_create_mipmaps) {
		img->generate_mipmaps();
	}
	return img;
}

void Terrain3DStorage::set_surface(const Ref<Terrain3DSurface> &p_material, int p_index) {
	LOG(INFO, "Setting surface index: ", p_index);
	if (p_index < get_surface_count()) {
		if (p_material.is_null()) {
			Ref<Terrain3DSurface> surface = _surfaces[p_index];
			surface->disconnect("texture_changed", Callable(this, "update_surface_textures"));
			surface->disconnect("value_changed", Callable(this, "update_surface_values"));
			_surfaces.remove_at(p_index);
		} else {
			_surfaces[p_index] = p_material;
		}
	} else {
		_surfaces.push_back(p_material);
	}
	_update_surfaces();
	notify_property_list_changed();
}

void Terrain3DStorage::set_surfaces(const TypedArray<Terrain3DSurface> &p_surfaces) {
	LOG(INFO, "Setting surfaces");
	_surfaces = p_surfaces;
	_update_surfaces();
}

void Terrain3DStorage::set_shader_override(const Ref<Shader> &p_shader) {
	LOG(INFO, "Setting override shader");
	_shader_override = p_shader;
	_update_material();
}

void Terrain3DStorage::enable_shader_override(bool p_enabled) {
	LOG(INFO, "Enable shader override: ", p_enabled);
	_shader_override_enabled = p_enabled;
	if (_shader_override_enabled && _shader_override.is_null()) {
		String code = _generate_shader_code();
		Ref<Shader> shader_res;
		shader_res.instantiate();
		shader_res->set_code(code);
		set_shader_override(shader_res);
	} else {
		_update_material();
	}
}

void Terrain3DStorage::set_noise_enabled(bool p_enabled) {
	LOG(INFO, "Enable noise: ", p_enabled);
	_noise_enabled = p_enabled;
	_update_material();
	if (_noise_enabled) {
		_generated_region_map.clear();
		_generated_region_blend_map.clear();
		_update_regions();
	}
}

void Terrain3DStorage::set_noise_scale(float p_scale) {
	LOG(INFO, "Setting noise scale: ", p_scale);
	_noise_scale = p_scale;
	RenderingServer::get_singleton()->material_set_param(_material, "noise_scale", _noise_scale);
}

void Terrain3DStorage::set_noise_height(float p_height) {
	LOG(INFO, "Setting noise height: ", p_height);
	_noise_height = p_height;
	RenderingServer::get_singleton()->material_set_param(_material, "noise_height", _noise_height);
}

void Terrain3DStorage::set_noise_blend_near(float p_near) {
	LOG(INFO, "Setting noise blend near: ", p_near);
	_noise_blend_near = p_near;
	if (_noise_blend_near > _noise_blend_far) {
		set_noise_blend_far(_noise_blend_near);
	}
	RenderingServer::get_singleton()->material_set_param(_material, "noise_blend_near", _noise_blend_near);
}

void Terrain3DStorage::set_noise_blend_far(float p_far) {
	LOG(INFO, "Setting noise blend far: ", p_far);
	_noise_blend_far = p_far;
	if (_noise_blend_far < _noise_blend_near) {
		set_noise_blend_near(_noise_blend_far);
	}
	RenderingServer::get_singleton()->material_set_param(_material, "noise_blend_far", _noise_blend_far);
}

void Terrain3DStorage::update_surface_textures() {
	_generated_albedo_textures.clear();
	_generated_normal_textures.clear();
	_update_surface_data(true, false);
}

void Terrain3DStorage::update_surface_values() {
	_update_surface_data(false, true);
}

void Terrain3DStorage::force_update_maps(MapType p_map_type) {
	switch (p_map_type) {
		case TYPE_HEIGHT:
			_generated_height_maps.clear();
			break;
		case TYPE_CONTROL:
			_generated_control_maps.clear();
			break;
		case TYPE_COLOR:
			_generated_color_maps.clear();
			break;
		default:
			_generated_height_maps.clear();
			_generated_control_maps.clear();
			_generated_color_maps.clear();
			break;
	}
	_update_regions();
}

void Terrain3DStorage::print_audit_data() {
	LOG(INFO, "Dumping storage data");

	LOG(INFO, "_initialized: ", _initialized);
	LOG(INFO, "_modified: ", _modified);
	LOG(INFO, "Region_offsets size: ", _region_offsets.size(), " ", _region_offsets);
	LOG(INFO, "Surfaces size: ", _surfaces.size(), " ", _surfaces);
	LOG(INFO, "Map type height size: ", _height_maps.size(), " ", _height_maps);
	for (int i = 0; i < _height_maps.size(); i++) {
		Ref<Image> img = _height_maps[i];
		LOG(INFO, "\tMap size: ", img->get_size(), " format: ", img->get_format());
	}
	LOG(INFO, "Map type control size: ", _control_maps.size(), " ", _control_maps);
	for (int i = 0; i < _control_maps.size(); i++) {
		Ref<Image> img = _control_maps[i];
		LOG(INFO, "\tMap size: ", img->get_size(), " format: ", img->get_format());
	}
	LOG(INFO, "Map type color size: ", _color_maps.size(), " ", _color_maps);
	for (int i = 0; i < _color_maps.size(); i++) {
		Ref<Image> img = _color_maps[i];
		LOG(INFO, "\tMap size: ", img->get_size(), " format: ", img->get_format());
	}

	LOG(INFO, "generated_region_map RID: ", _generated_region_map.get_rid(), " dirty: ", _generated_region_map.is_dirty(), ", image: ", _generated_region_map.get_image());
	LOG(INFO, "generated_region_blend_map RID: ", _generated_region_blend_map.get_rid(), ", dirty: ", _generated_region_blend_map.is_dirty(), ", image: ", _generated_region_blend_map.get_image());
	LOG(INFO, "generated_height_maps RID: ", _generated_height_maps.get_rid(), ", dirty: ", _generated_height_maps.is_dirty(), ", image: ", _generated_height_maps.get_image());
	LOG(INFO, "generated_control_maps RID: ", _generated_control_maps.get_rid(), ", dirty: ", _generated_control_maps.is_dirty(), ", image: ", _generated_control_maps.get_image());
	LOG(INFO, "generated_color_maps RID: ", _generated_color_maps.get_rid(), ", dirty: ", _generated_color_maps.is_dirty(), ", image: ", _generated_color_maps.get_image());
	LOG(INFO, "generated_albedo_textures RID: ", _generated_albedo_textures.get_rid(), ", dirty: ", _generated_albedo_textures.is_dirty(), ", image: ", _generated_albedo_textures.get_image());
	LOG(INFO, "generated_normal_textures RID: ", _generated_normal_textures.get_rid(), ", dirty: ", _generated_normal_textures.is_dirty(), ", image: ", _generated_normal_textures.get_image());
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DStorage::_bind_methods() {
	BIND_ENUM_CONSTANT(TYPE_HEIGHT);
	BIND_ENUM_CONSTANT(TYPE_CONTROL);
	BIND_ENUM_CONSTANT(TYPE_COLOR);
	BIND_ENUM_CONSTANT(TYPE_MAX);

	//BIND_ENUM_CONSTANT(SIZE_64);
	//BIND_ENUM_CONSTANT(SIZE_128);
	//BIND_ENUM_CONSTANT(SIZE_256);
	//BIND_ENUM_CONSTANT(SIZE_512);
	BIND_ENUM_CONSTANT(SIZE_1024);
	//BIND_ENUM_CONSTANT(SIZE_2048);

	BIND_CONSTANT(REGION_MAP_SIZE);

	ClassDB::bind_method(D_METHOD("set_region_size", "size"), &Terrain3DStorage::set_region_size);
	ClassDB::bind_method(D_METHOD("get_region_size"), &Terrain3DStorage::get_region_size);
	ClassDB::bind_method(D_METHOD("set_save_16_bit", "enabled"), &Terrain3DStorage::set_save_16_bit);
	ClassDB::bind_method(D_METHOD("get_save_16_bit"), &Terrain3DStorage::get_save_16_bit);
	ClassDB::bind_method(D_METHOD("set_version", "version"), &Terrain3DStorage::set_version);
	ClassDB::bind_method(D_METHOD("get_version"), &Terrain3DStorage::get_version);

	ClassDB::bind_method(D_METHOD("set_height_range", "range"), &Terrain3DStorage::set_height_range);
	ClassDB::bind_method(D_METHOD("get_height_range"), &Terrain3DStorage::get_height_range);
	ClassDB::bind_method(D_METHOD("update_height_range"), &Terrain3DStorage::update_height_range);

	ClassDB::bind_method(D_METHOD("set_region_offsets", "offsets"), &Terrain3DStorage::set_region_offsets);
	ClassDB::bind_method(D_METHOD("get_region_offsets"), &Terrain3DStorage::get_region_offsets);
	ClassDB::bind_method(D_METHOD("get_region_count"), &Terrain3DStorage::get_region_count);
	ClassDB::bind_method(D_METHOD("get_region_offset"), &Terrain3DStorage::get_region_offset);
	ClassDB::bind_method(D_METHOD("get_region_index", "global_position"), &Terrain3DStorage::get_region_index);
	ClassDB::bind_method(D_METHOD("has_region", "global_position"), &Terrain3DStorage::has_region);
	ClassDB::bind_method(D_METHOD("add_region", "global_position", "images", "update"), &Terrain3DStorage::add_region, DEFVAL(TypedArray<Image>()), DEFVAL(true));
	ClassDB::bind_method(D_METHOD("remove_region", "global_position", "update"), &Terrain3DStorage::remove_region, DEFVAL(true));

	ClassDB::bind_method(D_METHOD("set_map_region", "map_type", "region_index", "image"), &Terrain3DStorage::set_map_region);
	ClassDB::bind_method(D_METHOD("get_map_region", "map_type", "region_index"), &Terrain3DStorage::get_map_region);
	ClassDB::bind_method(D_METHOD("set_maps", "map_type", "maps"), &Terrain3DStorage::set_maps);
	ClassDB::bind_method(D_METHOD("get_maps", "map_type"), &Terrain3DStorage::get_maps);
	ClassDB::bind_method(D_METHOD("get_maps_copy", "map_type"), &Terrain3DStorage::get_maps_copy);
	ClassDB::bind_method(D_METHOD("set_height_maps", "maps"), &Terrain3DStorage::set_height_maps);
	ClassDB::bind_method(D_METHOD("get_height_maps"), &Terrain3DStorage::get_height_maps);
	ClassDB::bind_method(D_METHOD("set_control_maps", "maps"), &Terrain3DStorage::set_control_maps);
	ClassDB::bind_method(D_METHOD("get_control_maps"), &Terrain3DStorage::get_control_maps);
	ClassDB::bind_method(D_METHOD("set_color_maps", "maps"), &Terrain3DStorage::set_color_maps);
	ClassDB::bind_method(D_METHOD("get_color_maps"), &Terrain3DStorage::get_color_maps);
	ClassDB::bind_method(D_METHOD("get_pixel", "map_type", "global_position"), &Terrain3DStorage::get_pixel);
	ClassDB::bind_method(D_METHOD("get_height", "global_position"), &Terrain3DStorage::get_height);
	ClassDB::bind_method(D_METHOD("get_color", "global_position"), &Terrain3DStorage::get_color);
	ClassDB::bind_method(D_METHOD("get_control", "global_position"), &Terrain3DStorage::get_control);
	ClassDB::bind_method(D_METHOD("get_roughness", "global_position"), &Terrain3DStorage::get_roughness);

	ClassDB::bind_static_method("Terrain3DStorage", D_METHOD("load_image", "file_name", "cache_mode", "r16_height_range", "r16_size"), &Terrain3DStorage::load_image, DEFVAL(ResourceLoader::CACHE_MODE_IGNORE), DEFVAL(Vector2(0, 255)), DEFVAL(Vector2i(0, 0)));
	ClassDB::bind_method(D_METHOD("import_images", "images", "global_position", "offset", "scale"), &Terrain3DStorage::import_images, DEFVAL(Vector3(0, 0, 0)), DEFVAL(0.0), DEFVAL(1.0));
	ClassDB::bind_method(D_METHOD("export_image", "file_name", "map_type"), &Terrain3DStorage::export_image);
	ClassDB::bind_method(D_METHOD("layered_to_image", "map_type"), &Terrain3DStorage::layered_to_image);
	ClassDB::bind_static_method("Terrain3DStorage", D_METHOD("get_min_max", "image"), &Terrain3DStorage::get_min_max);
	ClassDB::bind_static_method("Terrain3DStorage", D_METHOD("get_thumbnail", "image", "size"), &Terrain3DStorage::get_thumbnail, DEFVAL(Vector2i(256, 256)));

	ClassDB::bind_method(D_METHOD("set_surface", "material", "index"), &Terrain3DStorage::set_surface);
	ClassDB::bind_method(D_METHOD("get_surface", "index"), &Terrain3DStorage::get_surface);
	ClassDB::bind_method(D_METHOD("set_surfaces", "surfaces"), &Terrain3DStorage::set_surfaces);
	ClassDB::bind_method(D_METHOD("get_surfaces"), &Terrain3DStorage::get_surfaces);
	ClassDB::bind_method(D_METHOD("get_surface_count"), &Terrain3DStorage::get_surface_count);

	ClassDB::bind_method(D_METHOD("set_shader_override", "shader"), &Terrain3DStorage::set_shader_override);
	ClassDB::bind_method(D_METHOD("get_shader_override"), &Terrain3DStorage::get_shader_override);
	ClassDB::bind_method(D_METHOD("enable_shader_override", "enabled"), &Terrain3DStorage::enable_shader_override);
	ClassDB::bind_method(D_METHOD("is_shader_override_enabled"), &Terrain3DStorage::is_shader_override_enabled);

	ClassDB::bind_method(D_METHOD("set_noise_enabled", "enabled"), &Terrain3DStorage::set_noise_enabled);
	ClassDB::bind_method(D_METHOD("get_noise_enabled"), &Terrain3DStorage::get_noise_enabled);
	ClassDB::bind_method(D_METHOD("set_noise_scale", "scale"), &Terrain3DStorage::set_noise_scale);
	ClassDB::bind_method(D_METHOD("get_noise_scale"), &Terrain3DStorage::get_noise_scale);
	ClassDB::bind_method(D_METHOD("set_noise_height", "height"), &Terrain3DStorage::set_noise_height);
	ClassDB::bind_method(D_METHOD("get_noise_height"), &Terrain3DStorage::get_noise_height);
	ClassDB::bind_method(D_METHOD("set_noise_blend_near", "fade"), &Terrain3DStorage::set_noise_blend_near);
	ClassDB::bind_method(D_METHOD("get_noise_blend_near"), &Terrain3DStorage::get_noise_blend_near);
	ClassDB::bind_method(D_METHOD("set_noise_blend_far", "sharpness"), &Terrain3DStorage::set_noise_blend_far);
	ClassDB::bind_method(D_METHOD("get_noise_blend_far"), &Terrain3DStorage::get_noise_blend_far);
	ClassDB::bind_method(D_METHOD("get_region_blend_map"), &Terrain3DStorage::get_region_blend_map);

	ClassDB::bind_method(D_METHOD("update_surface_textures"), &Terrain3DStorage::update_surface_textures);
	ClassDB::bind_method(D_METHOD("update_surface_values"), &Terrain3DStorage::update_surface_values);
	ClassDB::bind_method(D_METHOD("force_update_maps", "map_type"), &Terrain3DStorage::force_update_maps, DEFVAL(TYPE_MAX));

	//ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_ENUM, "64:64, 128:128, 256:256, 512:512, 1024:1024, 2048:2048"), "set_region_size", "get_region_size");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_ENUM, "1024:1024"), "set_region_size", "get_region_size");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "save_16-bit", PROPERTY_HINT_NONE), "set_save_16_bit", "get_save_16_bit");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "shader_override_enabled", PROPERTY_HINT_NONE), "enable_shader_override", "is_shader_override_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_shader_override", "get_shader_override");

	ADD_GROUP("World Noise", "noise_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "noise_enabled", PROPERTY_HINT_NONE), "set_noise_enabled", "get_noise_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_scale", PROPERTY_HINT_RANGE, "0.0, 10.0"), "set_noise_scale", "get_noise_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_height", PROPERTY_HINT_RANGE, "0.0, 1000.0"), "set_noise_height", "get_noise_height");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_blend_near", PROPERTY_HINT_RANGE, "0.0, 1.0"), "set_noise_blend_near", "get_noise_blend_near");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_blend_far", PROPERTY_HINT_RANGE, "0.0, 1.0"), "set_noise_blend_far", "get_noise_blend_far");

	ADD_GROUP("Read Only", "data_");
	int ro_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "data_version", PROPERTY_HINT_NONE, "", ro_flags), "set_version", "get_version");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "data_height_range", PROPERTY_HINT_NONE, "", ro_flags), "set_height_range", "get_height_range");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_region_offsets", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::VECTOR2, PROPERTY_HINT_NONE), ro_flags), "set_region_offsets", "get_region_offsets");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_height_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), ro_flags), "set_height_maps", "get_height_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_control_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), ro_flags), "set_control_maps", "get_control_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_color_maps", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Image"), ro_flags), "set_color_maps", "get_color_maps");
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "data_surfaces", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DSurface"), ro_flags), "set_surfaces", "get_surfaces");

	ADD_SIGNAL(MethodInfo("height_maps_changed"));
}
