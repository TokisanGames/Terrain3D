// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/rendering_server.hpp>

#include "logger.h"
#include "terrain_3d_material.h"
#include "util.h"

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DMaterial::_preload_shaders() {
	// Preprocessor loading of external shader inserts
	_parse_shader(
#include "shaders/world_noise.glsl"
			, "world_noise");

	_parse_shader(
#include "shaders/debug_views.glsl"
			, "debug_views");

	_shader_code["main"] = String(
#include "shaders/main.glsl"
	);

	if (Terrain3D::_debug_level >= DEBUG) {
		Array keys = _shader_code.keys();
		for (int i = 0; i < keys.size(); i++) {
			LOG(DEBUG, "Loaded shader insert: ", keys[i]);
		}
	}
}

/**
 * Dual use function that uses the same parsing mechanics for different purposes
 * if p_name has a value, Reading mode:
 *	any //INSERT: ID in p_shader is loaded into the DB _shader_code
 *	returns String()
 * else
 *	Apply mode: any //INSERT: ID is replaced by the entry in the DB
 *	returns a shader string with inserts applied
 */
String Terrain3DMaterial::_parse_shader(String p_shader, String p_name, Array p_excludes) {
	PackedStringArray parsed = p_shader.split("//INSERT:");

	String shader;
	for (int i = 0; i < parsed.size(); i++) {
		// First section of the file before any //INSERT:
		if (i == 0) {
			if (!p_name.is_empty()) {
				// Load mode
				_shader_code[p_name] = parsed[0];
			} else {
				// Apply mode
				shader = parsed[0];
			}
		} else {
			// If there is at least one //INSERT:
			// Get the first ID on the first line
			PackedStringArray segment = parsed[i].split("\n", true, 1);
			// If there isn't an ID AND body, skip this insert
			if (segment.size() < 2) {
				continue;
			}
			String id = segment[0].strip_edges();

			// Process the insert
			if (!p_name.is_empty()) {
				// Load mode
				if (!id.is_empty()) {
					_shader_code[id] = segment[1];
				}
			} else {
				// Apply mode
				if (!id.is_empty() && !p_excludes.has(id)) {
					String str = _shader_code[id];
					shader += str;
				}
				shader += segment[1];
			}
		}
	}
	return shader;
}

String Terrain3DMaterial::_generate_shader_code() {
	LOG(INFO, "Generating default shader code");
	Array excludes;
	if (!_noise_enabled) {
		excludes.push_back("WORLD_NOISE1");
		excludes.push_back("WORLD_NOISE2");
	}
	if (!_debug_view_checkered) {
		excludes.push_back("DEBUG_CHECKERED");
	}
	if (!_debug_view_grey) {
		excludes.push_back("DEBUG_GREY");
	}
	if (!_debug_view_heightmap) {
		excludes.push_back("DEBUG_HEIGHTMAP");
	}
	if (!_debug_view_colormap) {
		excludes.push_back("DEBUG_COLORMAP");
	}
	if (!_debug_view_roughmap) {
		excludes.push_back("DEBUG_ROUGHMAP");
	}
	if (!_debug_view_tex_height) {
		excludes.push_back("DEBUG_TEXTURE_HEIGHT");
	}
	if (!_debug_view_tex_normal) {
		excludes.push_back("DEBUG_TEXTURE_NORMAL");
	}
	if (!_debug_view_tex_rough) {
		excludes.push_back("DEBUG_TEXTURE_ROUGHNESS");
	}
	if (!_debug_view_controlmap) {
		excludes.push_back("DEBUG_CONTROLMAP");
	}
	if (!_debug_view_vertex_grid) {
		excludes.push_back("DEBUG_VERTEX_GRID");
	}
	String shader = _parse_shader(_shader_code["main"], "", excludes);
	return shader;
}

void Terrain3DMaterial::_generate_region_blend_map() {
	int rsize = Terrain3DStorage::REGION_MAP_SIZE;
	if (_region_map.size() == rsize * rsize) {
		LOG(DEBUG, "Regenerating ", Vector2i(512, 512), " region blend map");
		Ref<Image> region_blend_img = Image::create(rsize, rsize, false, Image::FORMAT_RH);
		for (int y = 0; y < rsize; y++) {
			for (int x = 0; x < rsize; x++) {
				if (_region_map[y * rsize + x] > 0) {
					region_blend_img->set_pixel(x, y, COLOR_WHITE);
				}
			}
		}
		region_blend_img->resize(512, 512, Image::INTERPOLATE_TRILINEAR);
		_generated_region_blend_map.clear();
		_generated_region_blend_map.create(region_blend_img);
		RS->material_set_param(_material, "region_blend_map", _generated_region_blend_map.get_rid());
		Util::dump_gen(_generated_region_blend_map, "blend_map");
	}
}

// Array expects
// 0: height maps texture array RID
// 1: control maps RID
// 2: color maps RID
// 3: region map packedByteArray
// 4: region offsets array
void Terrain3DMaterial::_update_regions(const Array &p_args) {
	LOG(INFO, "Updating region maps in shader");
	if (p_args.size() != 5) {
		LOG(ERROR, "Expected 5 arguments. Received: ", p_args.size());
		return;
	}

	RID height_rid = p_args[0];
	RID control_rid = p_args[1];
	RID color_rid = p_args[2];
	RS->material_set_param(_material, "height_maps", height_rid);
	RS->material_set_param(_material, "control_maps", control_rid);
	RS->material_set_param(_material, "color_maps", color_rid);
	LOG(DEBUG, "Height map RID: ", height_rid);
	LOG(DEBUG, "Control map RID: ", control_rid);
	LOG(DEBUG, "Color map RID: ", color_rid);

	_region_map = p_args[3];
	LOG(DEBUG, "_region_map.size(): ", _region_map.size());
	if (_region_map.size() != Terrain3DStorage::REGION_MAP_SIZE * Terrain3DStorage::REGION_MAP_SIZE) {
		LOG(ERROR, "Expected _region_map.size() of ", Terrain3DStorage::REGION_MAP_SIZE * Terrain3DStorage::REGION_MAP_SIZE);
	}
	RS->material_set_param(_material, "region_map", _region_map);
	RS->material_set_param(_material, "region_map_size", Terrain3DStorage::REGION_MAP_SIZE);
	if (Terrain3D::_debug_level >= DEBUG) {
		LOG(DEBUG, "Region map");
		for (int i = 0; i < _region_map.size(); i++) {
			if (_region_map[i]) {
				LOG(DEBUG, "Region id: ", _region_map[i], " array index: ", i);
			}
		}
	}

	TypedArray<Vector2i> region_offsets = p_args[4];
	LOG(DEBUG, "Region_offsets size: ", region_offsets.size(), " ", region_offsets);
	RS->material_set_param(_material, "region_offsets", region_offsets);

	if (_noise_enabled) {
		_generate_region_blend_map();
	}
}

// Expected Arguments are as follows, * set is optional
// 0: texture count
// 1: albedo tex array
// 2: normal tex array
// 3: uv rotation array *
// 4: uv scale array *
// 5: uv color array *
void Terrain3DMaterial::_update_texture_arrays(const Array &p_args) {
	LOG(INFO, "Updating texture arrays in shader");
	if (p_args.size() < 3) {
		LOG(ERROR, "Expecting at least 2 arguments");
		return;
	}

	_texture_count = p_args[0];
	RID albedo_array = p_args[1];
	RID normal_array = p_args[2];
	RS->material_set_param(_material, "texture_array_albedo", albedo_array);
	RS->material_set_param(_material, "texture_array_normal", normal_array);

	if (p_args.size() == 6) {
		PackedFloat32Array uv_scales = p_args[3];
		PackedFloat32Array uv_rotations = p_args[4];
		PackedColorArray colors = p_args[5];
		_texture_count = uv_scales.size();
		RS->material_set_param(_material, "texture_uv_rotation_array", uv_scales);
		RS->material_set_param(_material, "texture_uv_scale_array", uv_rotations);
		RS->material_set_param(_material, "texture_color_array", colors);
	}

	// Enable checkered view if texture_count is 0, disable if not
	if (_texture_count == 0) {
		if (_debug_view_checkered == false) {
			set_show_checkered(true);
			LOG(DEBUG, "No textures, enabling checkered view");
		}
	} else {
		set_show_checkered(false);
		LOG(DEBUG, "Texture count >0, disabling checkered view");
	}
}

void Terrain3DMaterial::_update_shader() {
	LOG(INFO, "Updating shader");
	if (_shader_override_enabled && _shader_override.is_valid()) {
		RS->material_set_shader(_material, _shader_override->get_rid());
	} else {
		RS->shader_set_code(_shader, _generate_shader_code());
		RS->material_set_shader(_material, _shader);
	}
}

///////////////////////////
// Public Functions
///////////////////////////

Terrain3DMaterial::Terrain3DMaterial() {
	_preload_shaders();
	_material = RS->material_create();
	_shader = RS->shader_create();
	set_region_size(_region_size);
	_update_shader();
}

Terrain3DMaterial::~Terrain3DMaterial() {
	RS->free_rid(_material);
	RS->free_rid(_shader);
	_generated_region_blend_map.clear();
}

void Terrain3DMaterial::enable_shader_override(bool p_enabled) {
	LOG(INFO, "Enable shader override: ", p_enabled);
	_shader_override_enabled = p_enabled;
	if (_shader_override_enabled && _shader_override.is_null()) {
		_shader_override.instantiate();
		String code = _generate_shader_code();
		_shader_override->set_code(code);
	}
	_update_shader();
}

void Terrain3DMaterial::set_shader_override(const Ref<Shader> &p_shader) {
	LOG(INFO, "Setting override shader");
	_shader_override = p_shader;
	if (_shader_override.is_valid() && _shader_override->get_code().is_empty()) {
		String code = _generate_shader_code();
		_shader_override->set_code(code);
	}
	_update_shader();
}

void Terrain3DMaterial::set_region_size(int p_size) {
	LOG(INFO, "Setting region size in material: ", p_size);
	_region_size = CLAMP(p_size, 64, 4096);
	_region_sizev = Vector2i(_region_size, _region_size);
	RS->material_set_param(_material, "region_size", float(_region_size));
	RS->material_set_param(_material, "region_pixel_size", 1.0f / float(_region_size));
}

void Terrain3DMaterial::set_show_checkered(bool p_enabled) {
	LOG(INFO, "Enable set_show_checkered: ", p_enabled);
	_debug_view_checkered = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_grey(bool p_enabled) {
	LOG(INFO, "Enable show_grey: ", p_enabled);
	_debug_view_grey = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_heightmap(bool p_enabled) {
	LOG(INFO, "Enable show_heightmap: ", p_enabled);
	_debug_view_heightmap = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_colormap(bool p_enabled) {
	LOG(INFO, "Enable show_colormap: ", p_enabled);
	_debug_view_colormap = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_roughmap(bool p_enabled) {
	LOG(INFO, "Enable show_roughmap: ", p_enabled);
	_debug_view_roughmap = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_controlmap(bool p_enabled) {
	LOG(INFO, "Enable show_controlmap: ", p_enabled);
	_debug_view_controlmap = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_texture_height(bool p_enabled) {
	LOG(INFO, "Enable show_texture_height: ", p_enabled);
	_debug_view_tex_height = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_texture_normal(bool p_enabled) {
	LOG(INFO, "Enable show_texture_normal: ", p_enabled);
	_debug_view_tex_normal = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_texture_rough(bool p_enabled) {
	LOG(INFO, "Enable show_texture_rough: ", p_enabled);
	_debug_view_tex_rough = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_vertex_grid(bool p_enabled) {
	LOG(INFO, "Enable show_vertex_grid: ", p_enabled);
	_debug_view_vertex_grid = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_noise_enabled(bool p_enabled) {
	LOG(INFO, "Enable noise: ", p_enabled);
	_noise_enabled = p_enabled;
	if (_noise_enabled) {
		_generate_region_blend_map();
	}
	_update_shader();
}

void Terrain3DMaterial::set_noise_scale(float p_scale) {
	LOG(INFO, "Setting noise scale: ", p_scale);
	_noise_scale = p_scale;
	RS->material_set_param(_material, "noise_scale", _noise_scale);
}

void Terrain3DMaterial::set_noise_height(float p_height) {
	LOG(INFO, "Setting noise height: ", p_height);
	_noise_height = p_height;
	RS->material_set_param(_material, "noise_height", _noise_height);
}

void Terrain3DMaterial::set_noise_blend_near(float p_near) {
	LOG(INFO, "Setting noise blend near: ", p_near);
	_noise_blend_near = CLAMP(p_near, 0., 1.);
	if (_noise_blend_near + .05 > _noise_blend_far) {
		set_noise_blend_far(_noise_blend_near + .051);
	}
	RS->material_set_param(_material, "noise_blend_near", _noise_blend_near);
}

void Terrain3DMaterial::set_noise_blend_far(float p_far) {
	LOG(INFO, "Setting noise blend far: ", p_far);
	_noise_blend_far = CLAMP(p_far, 0., 1.);
	if (_noise_blend_far - .05 < _noise_blend_near) {
		set_noise_blend_near(_noise_blend_far - .051);
	}
	RS->material_set_param(_material, "noise_blend_far", _noise_blend_far);
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DMaterial::_bind_methods() {
	// Private, but Public workaround until callable_mp is implemented
	// https://github.com/godotengine/godot-cpp/pull/1155
	ClassDB::bind_method(D_METHOD("_update_regions", "args"), &Terrain3DMaterial::_update_regions);
	ClassDB::bind_method(D_METHOD("_update_texture_arrays", "args"), &Terrain3DMaterial::_update_texture_arrays);

	// Public
	ClassDB::bind_method(D_METHOD("enable_shader_override", "enabled"), &Terrain3DMaterial::enable_shader_override);
	ClassDB::bind_method(D_METHOD("is_shader_override_enabled"), &Terrain3DMaterial::is_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("set_shader_override", "shader"), &Terrain3DMaterial::set_shader_override);
	ClassDB::bind_method(D_METHOD("get_shader_override"), &Terrain3DMaterial::get_shader_override);

	ClassDB::bind_method(D_METHOD("set_show_checkered", "enabled"), &Terrain3DMaterial::set_show_checkered);
	ClassDB::bind_method(D_METHOD("get_show_checkered"), &Terrain3DMaterial::get_show_checkered);
	ClassDB::bind_method(D_METHOD("set_show_grey", "enabled"), &Terrain3DMaterial::set_show_grey);
	ClassDB::bind_method(D_METHOD("get_show_grey"), &Terrain3DMaterial::get_show_grey);
	ClassDB::bind_method(D_METHOD("set_show_heightmap", "enabled"), &Terrain3DMaterial::set_show_heightmap);
	ClassDB::bind_method(D_METHOD("get_show_heightmap"), &Terrain3DMaterial::get_show_heightmap);
	ClassDB::bind_method(D_METHOD("set_show_colormap", "enabled"), &Terrain3DMaterial::set_show_colormap);
	ClassDB::bind_method(D_METHOD("get_show_colormap"), &Terrain3DMaterial::get_show_colormap);
	ClassDB::bind_method(D_METHOD("set_show_roughmap", "enabled"), &Terrain3DMaterial::set_show_roughmap);
	ClassDB::bind_method(D_METHOD("get_show_roughmap"), &Terrain3DMaterial::get_show_roughmap);
	ClassDB::bind_method(D_METHOD("set_show_controlmap", "enabled"), &Terrain3DMaterial::set_show_controlmap);
	ClassDB::bind_method(D_METHOD("get_show_controlmap"), &Terrain3DMaterial::get_show_controlmap);
	ClassDB::bind_method(D_METHOD("set_show_texture_height", "enabled"), &Terrain3DMaterial::set_show_texture_height);
	ClassDB::bind_method(D_METHOD("get_show_texture_height"), &Terrain3DMaterial::get_show_texture_height);
	ClassDB::bind_method(D_METHOD("set_show_texture_normal", "enabled"), &Terrain3DMaterial::set_show_texture_normal);
	ClassDB::bind_method(D_METHOD("get_show_texture_normal"), &Terrain3DMaterial::get_show_texture_normal);
	ClassDB::bind_method(D_METHOD("set_show_texture_rough", "enabled"), &Terrain3DMaterial::set_show_texture_rough);
	ClassDB::bind_method(D_METHOD("get_show_texture_rough"), &Terrain3DMaterial::get_show_texture_rough);
	ClassDB::bind_method(D_METHOD("set_show_vertex_grid", "enabled"), &Terrain3DMaterial::set_show_vertex_grid);
	ClassDB::bind_method(D_METHOD("get_show_vertex_grid"), &Terrain3DMaterial::get_show_vertex_grid);

	ClassDB::bind_method(D_METHOD("set_noise_enabled", "enabled"), &Terrain3DMaterial::set_noise_enabled);
	ClassDB::bind_method(D_METHOD("get_noise_enabled"), &Terrain3DMaterial::get_noise_enabled);
	ClassDB::bind_method(D_METHOD("set_noise_scale", "scale"), &Terrain3DMaterial::set_noise_scale);
	ClassDB::bind_method(D_METHOD("get_noise_scale"), &Terrain3DMaterial::get_noise_scale);
	ClassDB::bind_method(D_METHOD("set_noise_height", "height"), &Terrain3DMaterial::set_noise_height);
	ClassDB::bind_method(D_METHOD("get_noise_height"), &Terrain3DMaterial::get_noise_height);
	ClassDB::bind_method(D_METHOD("set_noise_blend_near", "fade"), &Terrain3DMaterial::set_noise_blend_near);
	ClassDB::bind_method(D_METHOD("get_noise_blend_near"), &Terrain3DMaterial::get_noise_blend_near);
	ClassDB::bind_method(D_METHOD("set_noise_blend_far", "sharpness"), &Terrain3DMaterial::set_noise_blend_far);
	ClassDB::bind_method(D_METHOD("get_noise_blend_far"), &Terrain3DMaterial::get_noise_blend_far);

	ClassDB::bind_method(D_METHOD("get_region_blend_map"), &Terrain3DMaterial::get_region_blend_map);

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "shader_override_enabled", PROPERTY_HINT_NONE), "enable_shader_override", "is_shader_override_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_shader_override", "get_shader_override");

	ADD_GROUP("Debug Views", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_checkered", PROPERTY_HINT_NONE), "set_show_checkered", "get_show_checkered");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_grey", PROPERTY_HINT_NONE), "set_show_grey", "get_show_grey");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_heightmap", PROPERTY_HINT_NONE), "set_show_heightmap", "get_show_heightmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_colormap", PROPERTY_HINT_NONE), "set_show_colormap", "get_show_colormap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_roughmap", PROPERTY_HINT_NONE), "set_show_roughmap", "get_show_roughmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_controlmap", PROPERTY_HINT_NONE), "set_show_controlmap", "get_show_controlmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_height", PROPERTY_HINT_NONE), "set_show_texture_height", "get_show_texture_height");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_normal", PROPERTY_HINT_NONE), "set_show_texture_normal", "get_show_texture_normal");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_rough", PROPERTY_HINT_NONE), "set_show_texture_rough", "get_show_texture_rough");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_vertex_grid", PROPERTY_HINT_NONE), "set_show_vertex_grid", "get_show_vertex_grid");

	ADD_GROUP("World Noise", "noise_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "noise_enabled", PROPERTY_HINT_NONE), "set_noise_enabled", "get_noise_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_scale", PROPERTY_HINT_RANGE, "0.0, 10.0"), "set_noise_scale", "get_noise_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_height", PROPERTY_HINT_RANGE, "0.0, 1000.0"), "set_noise_height", "get_noise_height");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_blend_near", PROPERTY_HINT_RANGE, "0.0, .95"), "set_noise_blend_near", "get_noise_blend_near");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "noise_blend_far", PROPERTY_HINT_RANGE, "0.05, 1.0"), "set_noise_blend_far", "get_noise_blend_far");
}
