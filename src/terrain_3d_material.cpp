// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/gradient.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/noise_texture2d.hpp>
#include <godot_cpp/classes/reg_ex.hpp>
#include <godot_cpp/classes/reg_ex_match.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/resource_saver.hpp>

#include "logger.h"
#include "terrain_3d_material.h"
#include "terrain_3d_util.h"

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DMaterial::_preload_shaders() {
	// Preprocessor loading of external shader inserts
	_parse_shader(
#include "shaders/uniforms.glsl"
			, "uniforms");
	_parse_shader(
#include "shaders/world_noise.glsl"
			, "world_noise");
	_parse_shader(
#include "shaders/auto_shader.glsl"
			, "auto_shader");
	_parse_shader(
#include "shaders/dual_scaling.glsl"
			, "dual_scaling");
	_parse_shader(
#include "shaders/debug_views.glsl"
			, "debug_views");
	_parse_shader(
#include "shaders/overlays.glsl"
			, "debug_views");
	_parse_shader(
#include "shaders/editor_functions.glsl"
			, "editor_functions");

	// Load main code
	_shader_code["main"] = String(
#include "shaders/main.glsl"
	);

	if (Terrain3D::debug_level >= DEBUG) {
		Array keys = _shader_code.keys();
		for (int i = 0; i < keys.size(); i++) {
			LOG(DEBUG, "Loaded shader insert: ", keys[i]);
		}
	}
}

/**
 *	All `//INSERT: ID` blocks in p_shader are loaded into the DB _shader_code
 */
void Terrain3DMaterial::_parse_shader(const String &p_shader, const String &p_name) {
	if (p_name.is_empty()) {
		LOG(ERROR, "No dictionary key for saving shader snippets specified");
		return;
	}
	PackedStringArray parsed = p_shader.split("//INSERT:");
	for (int i = 0; i < parsed.size(); i++) {
		// First section of the file before any //INSERT:
		if (i == 0) {
			_shader_code[p_name] = parsed[0];
		} else {
			// There is at least one //INSERT:
			// Get the first ID on the first line
			PackedStringArray segment = parsed[i].split("\n", true, 1);
			// If there isn't an ID AND body, skip this insert
			if (segment.size() < 2) {
				continue;
			}
			String id = segment[0].strip_edges();
			// Process the insert
			if (!id.is_empty() && !segment[1].is_empty()) {
				_shader_code[id] = segment[1];
			}
		}
	}
	return;
}

/**
 *	`//INSERT: ID` blocks in p_shader are replaced by the entry in the DB
 *	returns a shader string with inserts applied
 *  Skips `EDITOR_*` and `DEBUG_*` inserts
 */
String Terrain3DMaterial::_apply_inserts(const String &p_shader, const Array &p_excludes) const {
	PackedStringArray parsed = p_shader.split("//INSERT:");
	String shader;
	for (int i = 0; i < parsed.size(); i++) {
		// First section of the file before any //INSERT:
		if (i == 0) {
			shader = parsed[0];
		} else {
			// There is at least one //INSERT:
			// Get the first ID on the first line
			PackedStringArray segment = parsed[i].split("\n", true, 1);
			// If there isn't an ID AND body, skip this insert
			if (segment.size() < 2) {
				continue;
			}
			String id = segment[0].strip_edges();

			// Process the insert
			if (!id.is_empty() && !p_excludes.has(id) && _shader_code.has(id)) {
				if (!id.begins_with("DEBUG_") && !id.begins_with("EDITOR_")) {
					String str = _shader_code[id];
					shader += str;
				}
			}
			shader += segment[1];
		}
	}
	return shader;
}

String Terrain3DMaterial::_generate_shader_code() const {
	LOG(INFO, "Generating default shader code");
	Array excludes;
	if (_world_background != NOISE) {
		excludes.push_back("WORLD_NOISE1");
		excludes.push_back("WORLD_NOISE2");
		excludes.push_back("WORLD_NOISE3");
	}
	if (_texture_filtering == LINEAR) {
		excludes.push_back("TEXTURE_SAMPLERS_NEAREST");
		excludes.push_back("NOISE_SAMPLER_NEAREST");
	} else {
		excludes.push_back("TEXTURE_SAMPLERS_LINEAR");
		excludes.push_back("NOISE_SAMPLER_LINEAR");
	}
	if (!_auto_shader) {
		excludes.push_back("AUTO_SHADER_UNIFORMS");
		excludes.push_back("AUTO_SHADER");
	}
	if (!_dual_scaling) {
		excludes.push_back("DUAL_SCALING_UNIFORMS");
		excludes.push_back("DUAL_SCALING");
		excludes.push_back("DUAL_SCALING_CONDITION_0");
		excludes.push_back("DUAL_SCALING_CONDITION_1");
		excludes.push_back("DUAL_SCALING_MIX");
		excludes.push_back("TRI_SCALING");
	}
	String shader = _apply_inserts(_shader_code["main"], excludes);
	return shader;
}

// Ripped from ShaderPreprocessor::CommentRemover::strip()
String Terrain3DMaterial::_strip_comments(const String &p_shader) const {
	Vector<char32_t> stripped;
	String code = p_shader;
	int index = 0;
	int line = 0;
	int comment_line_open = 0;
	int comments_open = 0;
	int strings_open = 0;
	const char32_t CURSOR = 0xFFFF;

	// Embedded supporting functions

	auto peek = [&]() { return (index < code.length()) ? code[index] : 0; };

	auto advance = [&](char32_t p_what) {
		while (index < code.length()) {
			char32_t c = code[index++];
			if (c == '\n') {
				line++;
				stripped.push_back('\n');
			}
			if (c == p_what) {
				return true;
			}
		}
		return false;
	};

	auto vector_to_string = [](const Vector<char32_t> &p_v, int p_start = 0, int p_end = -1) {
		const int stop = (p_end == -1) ? p_v.size() : p_end;
		const int count = stop - p_start;
		String result;
		result.resize(count + 1);
		for (int i = 0; i < count; i++) {
			result[i] = p_v[p_start + i];
		}
		result[count] = 0; // Ensure string is null terminated for length() to work.
		return result;
	};

	// Main function

	while (index < code.length()) {
		char32_t c = code[index++];
		if (c == CURSOR) {
			// Cursor. Maintain.
			stripped.push_back(c);
		} else if (c == '"') {
			if (strings_open <= 0) {
				strings_open++;
			} else {
				strings_open--;
			}
			stripped.push_back(c);
		} else if (c == '/' && strings_open == 0) {
			char32_t p = peek();
			if (p == '/') { // Single line comment.
				advance('\n');
			} else if (p == '*') { // Start of a block comment.
				index++;
				comment_line_open = line;
				comments_open++;
				while (advance('*')) {
					if (peek() == '/') { // End of a block comment.
						comments_open--;
						index++;
						break;
					}
				}
			} else {
				stripped.push_back(c);
			}
		} else if (c == '*' && strings_open == 0) {
			if (peek() == '/') { // Unmatched end of a block comment.
				comment_line_open = line;
				comments_open--;
			} else {
				stripped.push_back(c);
			}
		} else if (c == '\n') {
			line++;
			stripped.push_back(c);
		} else {
			stripped.push_back(c);
		}
	}
	return vector_to_string(stripped);
}

String Terrain3DMaterial::_inject_editor_code(const String &p_shader) const {
	String shader = _strip_comments(p_shader);

	// Insert after render_mode
	Ref<RegEx> regex;
	regex.instantiate();
	regex->compile("render_mode.*;?");
	Ref<RegExMatch> match = regex->search(shader);
	int idx = match.is_valid() ? match->get_end() : -1;
	if (idx < 0) {
		LOG(DEBUG, "No render mode; cannot inject editor code");
		return shader;
	}
	Array insert_names;

	// Whilst this currently does nothing, it can serve as placeholder for future refactor
	// when useing pre-processor headers to control shader features.
	//for (int i = 0; i < insert_names.size(); i++) {
	//	String insert = _shader_code[insert_names[i]];
	//	shader = shader.insert(idx, "\n\n" + insert);
	//	idx += insert.length();
	//}
	//insert_names.clear();

	// Insert before vertex()
	regex->compile("void\\s+vertex\\s*\\(");
	match = regex->search(shader);
	idx = match.is_valid() ? match->get_start() - 1 : -1;
	if (idx < 0) {
		LOG(DEBUG, "No void vertex(); cannot inject editor code");
		return shader;
	}
	if (IS_EDITOR && _terrain && _terrain->get_editor()) {
		insert_names.push_back("EDITOR_DECAL_SETUP");
	}
	if (_debug_view_heightmap) {
		insert_names.push_back("DEBUG_HEIGHTMAP_SETUP");
	}
	if (_show_contours) {
		insert_names.push_back("OVERLAY_CONTOURS_SETUP");
	}
	// Apply pending inserts
	for (int i = 0; i < insert_names.size(); i++) {
		String insert = _shader_code[insert_names[i]];
		shader = shader.insert(idx, "\n" + insert);
		idx += insert.length();
	}
	insert_names.clear();

	// Insert at the end of `fragment(){ }`
	// Check for each nested {} pair until the closing } is found.
	regex->compile("void\\s*fragment\\s*\\(\\s*\\)\\s*{");
	match = regex->search(shader);
	idx = -1;
	if (match.is_valid()) {
		int start_idx = match->get_end() - 1;
		int pair = 0;
		for (int i = start_idx; i < shader.length(); i++) {
			if (shader[i] == '{') {
				pair++;
			} else if (shader[i] == '}') {
				pair--;
			}
			if (pair == 0) {
				idx = i;
				break;
			}
		}
	}
	if (idx < 0) {
		LOG(DEBUG, "No ending bracket; cannot inject editor code");
		return shader;
	}

	// Debug Views
	if (_debug_view_checkered) {
		insert_names.push_back("DEBUG_CHECKERED");
	}
	if (_debug_view_grey) {
		insert_names.push_back("DEBUG_GREY");
	}
	if (_debug_view_heightmap) {
		insert_names.push_back("DEBUG_HEIGHTMAP");
	}
	if (_debug_view_jaggedness) {
		insert_names.push_back("DEBUG_JAGGEDNESS");
	}
	if (_debug_view_autoshader) {
		insert_names.push_back("DEBUG_AUTOSHADER");
	}
	if (_debug_view_control_texture) {
		insert_names.push_back("DEBUG_CONTROL_TEXTURE");
	}
	if (_debug_view_control_blend) {
		insert_names.push_back("DEBUG_CONTROL_BLEND");
	}
	if (_debug_view_control_angle) {
		insert_names.push_back("DEBUG_CONTROL_ANGLE");
	}
	if (_debug_view_control_scale) {
		insert_names.push_back("DEBUG_CONTROL_SCALE");
	}
	if (_debug_view_colormap) {
		insert_names.push_back("DEBUG_COLORMAP");
	}
	if (_debug_view_roughmap) {
		insert_names.push_back("DEBUG_ROUGHMAP");
	}
	if (_debug_view_tex_height) {
		insert_names.push_back("DEBUG_TEXTURE_HEIGHT");
	}
	if (_debug_view_tex_normal) {
		insert_names.push_back("DEBUG_TEXTURE_NORMAL");
	}
	if (_debug_view_tex_rough) {
		insert_names.push_back("DEBUG_TEXTURE_ROUGHNESS");
	}
	// Overlays
	if (_show_contours) {
		insert_names.push_back("OVERLAY_CONTOURS_RENDER");
	}
	if (_show_region_grid) {
		insert_names.push_back("OVERLAY_REGION_GRID");
	}
	if (_show_instancer_grid) {
		insert_names.push_back("OVERLAY_INSTANCER_GRID");
	}
	if (_show_vertex_grid) {
		insert_names.push_back("OVERLAY_VERTEX_GRID");
	}
	// Editor Functions
	if (_show_navigation || (IS_EDITOR && _terrain && _terrain->get_editor() && _terrain->get_editor()->get_tool() == Terrain3DEditor::NAVIGATION)) {
		insert_names.push_back("EDITOR_NAVIGATION");
	}
	if (IS_EDITOR && _terrain && _terrain->get_editor()) {
		insert_names.push_back("EDITOR_DECAL_RENDER");
	}
	// Apply pending inserts
	for (int i = 0; i < insert_names.size(); i++) {
		String insert = _shader_code[insert_names[i]];
		shader = shader.insert(idx, "\n" + insert);
		idx += insert.length();
	}
	return shader;
}

void Terrain3DMaterial::_update_shader() {
	IS_INIT(VOID);
	LOG(INFO, "Updating shader");
	String code;
	Ref<RegEx> regex;
	Ref<RegExMatch> match;
	regex.instantiate();
	if (_shader_override_enabled && _shader_override.is_valid()) {
		if (_shader_override->get_code().is_empty()) {
			_shader_override->set_code(_generate_shader_code());
		}
		code = _shader_override->get_code();
		if (!_shader_override->is_connected("changed", callable_mp(this, &Terrain3DMaterial::_update_shader))) {
			LOG(DEBUG, "Connecting changed signal to _update_shader()");
			_shader_override->connect("changed", callable_mp(this, &Terrain3DMaterial::_update_shader));
		}
	} else {
		code = _generate_shader_code();
	}
	_shader->set_code(_inject_editor_code(code));
	RS->material_set_shader(_material, get_shader_rid());
	LOG(DEBUG, "Material rid: ", _material, ", shader rid: ", get_shader_rid());

	// Update custom shader params in RenderingServer
	{
		// Populate _active_params
		List<PropertyInfo> pi;
		_get_property_list(&pi);
		LOG(EXTREME, "_active_params: ", _active_params);
		Util::print_dict("_shader_params", _shader_params, EXTREME);
	}

	// Fetch saved shader parameters, converting textures to RIDs
	for (int i = 0; i < _active_params.size(); i++) {
		StringName param = _active_params[i];
		Variant value = _shader_params[param];
		if (value.get_type() == Variant::OBJECT) {
			Ref<Texture> tex = value;
			if (tex.is_valid()) {
				RS->material_set_param(_material, param, tex->get_rid());
			} else {
				RS->material_set_param(_material, param, Variant());
			}
		} else {
			RS->material_set_param(_material, param, value);
		}
	}

	// Set specific shader parameters
	RS->material_set_param(_material, "_background_mode", _world_background);

	// If no noise texture, generate one
	if (_active_params.has("noise_texture") && RS->material_get_param(_material, "noise_texture").get_type() == Variant::NIL) {
		LOG(INFO, "Generating default noise_texture for shader");
		Ref<FastNoiseLite> fnoise;
		fnoise.instantiate();
		fnoise->set_noise_type(FastNoiseLite::TYPE_CELLULAR);
		fnoise->set_frequency(0.03f);
		fnoise->set_cellular_jitter(3.0f);
		fnoise->set_cellular_return_type(FastNoiseLite::RETURN_CELL_VALUE);
		fnoise->set_domain_warp_enabled(true);
		fnoise->set_domain_warp_type(FastNoiseLite::DOMAIN_WARP_SIMPLEX_REDUCED);
		fnoise->set_domain_warp_amplitude(50.f);
		fnoise->set_domain_warp_fractal_type(FastNoiseLite::DOMAIN_WARP_FRACTAL_INDEPENDENT);
		fnoise->set_domain_warp_fractal_lacunarity(1.5f);
		fnoise->set_domain_warp_fractal_gain(1.f);

		Ref<Gradient> curve;
		curve.instantiate();
		PackedFloat32Array pfa;
		pfa.push_back(0.2f);
		pfa.push_back(1.0f);
		curve->set_offsets(pfa);
		PackedColorArray pca;
		pca.push_back(Color(1.f, 1.f, 1.f, 1.f));
		pca.push_back(Color(0.f, 0.f, 0.f, 1.f));
		curve->set_colors(pca);

		Ref<NoiseTexture2D> noise_tex;
		noise_tex.instantiate();
		noise_tex->set_seamless(true);
		noise_tex->set_generate_mipmaps(true);
		noise_tex->set_noise(fnoise);
		noise_tex->set_color_ramp(curve);
		_set("noise_texture", noise_tex);
	}

	notify_property_list_changed();
}

void Terrain3DMaterial::_update_maps() {
	IS_DATA_INIT(VOID);
	LOG(EXTREME, "Updating maps in shader");

	Terrain3DData *data = _terrain->get_data();
	PackedInt32Array region_map = data->get_region_map();
	LOG(EXTREME, "region_map.size(): ", region_map.size());
	if (region_map.size() != Terrain3DData::REGION_MAP_SIZE * Terrain3DData::REGION_MAP_SIZE) {
		LOG(ERROR, "Expected region_map.size() of ", Terrain3DData::REGION_MAP_SIZE * Terrain3DData::REGION_MAP_SIZE);
		return;
	}
	RS->material_set_param(_material, "_region_map", region_map);
	RS->material_set_param(_material, "_region_map_size", Terrain3DData::REGION_MAP_SIZE);
	if (Terrain3D::debug_level >= EXTREME) {
		LOG(EXTREME, "Region map");
		for (int i = 0; i < region_map.size(); i++) {
			if (region_map[i]) {
				LOG(EXTREME, "Region id: ", region_map[i], " array index: ", i);
			}
		}
	}

	TypedArray<Vector2i> region_locations = data->get_region_locations();
	LOG(EXTREME, "Region_locations size: ", region_locations.size(), " ", region_locations);
	RS->material_set_param(_material, "_region_locations", region_locations);

	real_t region_size = real_t(_terrain->get_region_size());
	LOG(EXTREME, "Setting region size in material: ", region_size);
	RS->material_set_param(_material, "_region_size", region_size);
	RS->material_set_param(_material, "_region_texel_size", 1.0f / region_size);

	RS->material_set_param(_material, "_height_maps", data->get_height_maps_rid());
	RS->material_set_param(_material, "_control_maps", data->get_control_maps_rid());
	RS->material_set_param(_material, "_color_maps", data->get_color_maps_rid());
	LOG(EXTREME, "Height map RID: ", data->get_height_maps_rid());
	LOG(EXTREME, "Control map RID: ", data->get_control_maps_rid());
	LOG(EXTREME, "Color map RID: ", data->get_color_maps_rid());

	real_t spacing = _terrain->get_vertex_spacing();
	LOG(EXTREME, "Setting vertex spacing in material: ", spacing);
	RS->material_set_param(_material, "_vertex_spacing", spacing);
	RS->material_set_param(_material, "_vertex_density", 1.0f / spacing);

	real_t mesh_size = real_t(_terrain->get_mesh_size());
	RS->material_set_param(_material, "_mesh_size", mesh_size);
}

// Called from signal connected in Terrain3D, emitted by texture_list
void Terrain3DMaterial::_update_texture_arrays() {
	IS_DATA_INIT(VOID);
	Ref<Terrain3DAssets> asset_list = _terrain->get_assets();
	LOG(INFO, "Updating texture arrays in shader");
	if (asset_list.is_null() || !asset_list->is_initialized()) {
		LOG(ERROR, "Asset list is not initialized");
		return;
	}

	RS->material_set_param(_material, "_texture_array_albedo", asset_list->get_albedo_array_rid());
	RS->material_set_param(_material, "_texture_array_normal", asset_list->get_normal_array_rid());
	RS->material_set_param(_material, "_texture_color_array", asset_list->get_texture_colors());
	RS->material_set_param(_material, "_texture_normal_depth_array", asset_list->get_texture_normal_depths());
	RS->material_set_param(_material, "_texture_ao_strength_array", asset_list->get_texture_ao_strengths());
	RS->material_set_param(_material, "_texture_roughness_mod_array", asset_list->get_texture_roughness_mods());
	RS->material_set_param(_material, "_texture_uv_scale_array", asset_list->get_texture_uv_scales());
	RS->material_set_param(_material, "_texture_vertical_projections", asset_list->get_texture_vertical_projections());
	RS->material_set_param(_material, "_texture_detile_array", asset_list->get_texture_detiles());

	// Enable checkered view if texture_count is 0, disable if not
	if (asset_list->get_texture_count() == 0) {
		if (_debug_view_checkered == false) {
			set_show_checkered(true);
			LOG(DEBUG, "No textures, enabling checkered view");
		}
	} else {
		set_show_checkered(false);
		LOG(DEBUG, "Texture count >0: ", asset_list->get_texture_count(), ", disabling checkered view");
	}
}

void Terrain3DMaterial::_set_shader_parameters(const Dictionary &p_dict) {
	LOG(INFO, "Setting shader params dictionary: ", p_dict.size());
	_shader_params = p_dict;
}

///////////////////////////
// Public Functions
///////////////////////////

// This function serves as the constructor which is initialized by the class Terrain3D.
// Godot likes to create resource objects at startup, so this prevents it from creating
// uninitialized materials.
void Terrain3DMaterial::initialize(Terrain3D *p_terrain) {
	if (p_terrain) {
		_terrain = p_terrain;
	} else {
		LOG(ERROR, "Initialization failed, p_terrain is null");
		return;
	}
	LOG(INFO, "Initializing material");
	_preload_shaders();
	if (!_material.is_valid()) {
		_material = RS->material_create();
	}
	_shader.instantiate();
	_update_shader();
	_update_maps();
}

void Terrain3DMaterial::uninitialize() {
	LOG(INFO, "Uninitializing material");
	_terrain = nullptr;
}

void Terrain3DMaterial::destroy() {
	LOG(INFO, "Destroying material");
	_terrain = nullptr;
	_shader.unref();
	_shader_code.clear();
	_active_params.clear();
	_shader_params.clear();
	if (_material.is_valid()) {
		RS->free_rid(_material);
		_material = RID();
	}
}

void Terrain3DMaterial::update() {
	_update_shader();
	_update_maps();
}

void Terrain3DMaterial::set_world_background(const WorldBackground p_background) {
	LOG(INFO, "Enable world background: ", p_background);
	_world_background = p_background;
	_update_shader();
}

void Terrain3DMaterial::set_texture_filtering(const TextureFiltering p_filtering) {
	LOG(INFO, "Setting texture filtering: ", p_filtering);
	_texture_filtering = p_filtering;
	_update_shader();
}

void Terrain3DMaterial::set_auto_shader(const bool p_enabled) {
	LOG(INFO, "Enable auto shader: ", p_enabled);
	_auto_shader = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_dual_scaling(const bool p_enabled) {
	LOG(INFO, "Enable dual scaling: ", p_enabled);
	_dual_scaling = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::enable_shader_override(const bool p_enabled) {
	LOG(INFO, "Enable shader override: ", p_enabled);
	_shader_override_enabled = p_enabled;
	if (_shader_override_enabled && _shader_override.is_null()) {
		LOG(DEBUG, "Instantiating new _shader_override");
		_shader_override.instantiate();
	}
	_update_shader();
}

void Terrain3DMaterial::set_shader_override(const Ref<Shader> &p_shader) {
	LOG(INFO, "Setting override shader");
	_shader_override = p_shader;
	_update_shader();
}

void Terrain3DMaterial::set_shader_param(const StringName &p_name, const Variant &p_value) {
	LOG(INFO, "Setting shader parameter: ", p_name);
	_set(p_name, p_value);
}

Variant Terrain3DMaterial::get_shader_param(const StringName &p_name) const {
	LOG(INFO, "Getting shader parameter: ", p_name);
	Variant value;
	_get(p_name, value);
	return value;
}

void Terrain3DMaterial::set_show_region_grid(const bool p_enabled) {
	LOG(INFO, "Enable show_region_grid: ", p_enabled);
	_show_region_grid = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_instancer_grid(const bool p_enabled) {
	LOG(INFO, "Enable show_instancer_grid: ", p_enabled);
	_show_instancer_grid = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_vertex_grid(const bool p_enabled) {
	LOG(INFO, "Enable show_vertex_grid: ", p_enabled);
	_show_vertex_grid = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_contours(const bool p_enabled) {
	LOG(INFO, "Enable show_contours: ", p_enabled);
	_show_contours = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_navigation(const bool p_enabled) {
	LOG(INFO, "Enable show_navigation: ", p_enabled);
	_show_navigation = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_checkered(const bool p_enabled) {
	LOG(INFO, "Enable set_show_checkered: ", p_enabled);
	_debug_view_checkered = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_grey(const bool p_enabled) {
	LOG(INFO, "Enable show_grey: ", p_enabled);
	_debug_view_grey = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_heightmap(const bool p_enabled) {
	LOG(INFO, "Enable show_heightmap: ", p_enabled);
	_debug_view_heightmap = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_jaggedness(const bool p_enabled) {
	LOG(INFO, "Enable show_jaggedness: ", p_enabled);
	_debug_view_jaggedness = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_autoshader(const bool p_enabled) {
	LOG(INFO, "Enable show_autoshader: ", p_enabled);
	_debug_view_autoshader = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_control_texture(const bool p_enabled) {
	LOG(INFO, "Enable show_control_texture: ", p_enabled);
	_debug_view_control_texture = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_control_blend(const bool p_enabled) {
	LOG(INFO, "Enable show_control_blend: ", p_enabled);
	_debug_view_control_blend = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_control_angle(const bool p_enabled) {
	LOG(INFO, "Enable show_control_angle: ", p_enabled);
	_debug_view_control_angle = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_control_scale(const bool p_enabled) {
	LOG(INFO, "Enable show_control_scale: ", p_enabled);
	_debug_view_control_scale = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_colormap(const bool p_enabled) {
	LOG(INFO, "Enable show_colormap: ", p_enabled);
	_debug_view_colormap = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_roughmap(const bool p_enabled) {
	LOG(INFO, "Enable show_roughmap: ", p_enabled);
	_debug_view_roughmap = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_texture_height(const bool p_enabled) {
	LOG(INFO, "Enable show_texture_height: ", p_enabled);
	_debug_view_tex_height = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_texture_normal(const bool p_enabled) {
	LOG(INFO, "Enable show_texture_normal: ", p_enabled);
	_debug_view_tex_normal = p_enabled;
	_update_shader();
}

void Terrain3DMaterial::set_show_texture_rough(const bool p_enabled) {
	LOG(INFO, "Enable show_texture_rough: ", p_enabled);
	_debug_view_tex_rough = p_enabled;
	_update_shader();
}

Error Terrain3DMaterial::save(const String &p_path) {
	if (p_path.is_empty() && get_path().is_empty()) {
		return ERR_FILE_NOT_FOUND;
	}
	if (!p_path.is_empty()) {
		LOG(DEBUG, "Setting file path to ", p_path);
		take_over_path(p_path);
	}

	LOG(DEBUG, "Generating parameter list from shaders");
	// Get shader parameters from default shader (eg world_noise)
	Array param_list;
	param_list = RS->get_shader_parameter_list(get_shader_rid());
	// Get shader parameters from custom shader if present
	if (_shader_override.is_valid()) {
		param_list.append_array(_shader_override->get_shader_uniform_list(true));
	}

	// Remove saved shader params that don't exist in either shader
	Array keys = _shader_params.keys();
	for (int i = 0; i < keys.size(); i++) {
		bool has = false;
		StringName name = keys[i];
		for (int j = 0; j < param_list.size(); j++) {
			Dictionary dict;
			StringName dname;
			if (j < param_list.size()) {
				dict = param_list[j];
				dname = dict["name"];
				if (name == dname) {
					has = true;
					break;
				}
			}
		}
		if (!has) {
			LOG(DEBUG, "'", name, "' not found in shader parameters. Removing from dictionary.");
			_shader_params.erase(name);
		}
	}

	// Save to external resource file if specified
	Error err = OK;
	String path = get_path();
	if (path.get_extension() == "tres" || path.get_extension() == "res") {
		LOG(DEBUG, "Attempting to save external file: " + path);
		err = ResourceSaver::get_singleton()->save(this, path, ResourceSaver::FLAG_COMPRESS);
		if (err == OK) {
			LOG(INFO, "File saved successfully: ", path);
		} else {
			LOG(ERROR, "Cannot save file: ", path, ". Error code: ", ERROR, ". Look up @GlobalScope Error enum in the Godot docs");
		}
	}
	return err;
}

///////////////////////////
// Protected Functions
///////////////////////////

// Add shader uniforms to properties. Hides uniforms that begin with _
void Terrain3DMaterial::_get_property_list(List<PropertyInfo> *p_list) const {
	Resource::_get_property_list(p_list);
	IS_INIT(VOID);
	Array param_list;
	if (_shader_override_enabled && _shader_override.is_valid()) {
		// Get shader parameters from custom shader
		param_list = _shader_override->get_shader_uniform_list(true);
	} else {
		// Get shader parameters from default shader (eg world_noise)
		param_list = RS->get_shader_parameter_list(get_shader_rid());
	}

	_active_params.clear();
	for (int i = 0; i < param_list.size(); i++) {
		Dictionary dict = param_list[i];
		StringName name = dict["name"];
		// Filter out private uniforms that start with _
		if (!name.begins_with("_")) {
			// Populate Godot's property list
			PropertyInfo pi;
			pi.name = name;
			pi.class_name = dict["class_name"];
			pi.type = Variant::Type(int(dict["type"]));
			pi.hint = dict["hint"];
			pi.hint_string = dict["hint_string"];
			pi.usage = PROPERTY_USAGE_EDITOR;
			p_list->push_back(pi);

			// Populate list of public parameters for current shader
			_active_params.push_back(name);

			// Store this param in a dictionary that is saved in the resource file
			// Initially set with default value
			// Also acts as a cache for _get
			// Property usage above set to EDITOR so it won't be redundantly saved,
			// which won't get loaded since there is no bound property.
			if (!_shader_params.has(name)) {
				_property_get_revert(name, _shader_params[name]);
			}
		}
	}
	return;
}

// Flag uniforms with non-default values
// This is called 10x more than the others, so be efficient
bool Terrain3DMaterial::_property_can_revert(const StringName &p_name) const {
	IS_INIT_COND(!_active_params.has(p_name), Resource::_property_can_revert(p_name));
	Variant default_value = RS->shader_get_parameter_default(get_shader_rid(), p_name);
	Variant current_value = RS->material_get_param(_material, p_name);
	return default_value != current_value;
}

// Provide uniform default values in r_property
bool Terrain3DMaterial::_property_get_revert(const StringName &p_name, Variant &r_property) const {
	IS_INIT_COND(!_active_params.has(p_name), Resource::_property_get_revert(p_name, r_property));
	r_property = RS->shader_get_parameter_default(get_shader_rid(), p_name);
	return true;
}

bool Terrain3DMaterial::_set(const StringName &p_name, const Variant &p_property) {
	IS_INIT_COND(!_active_params.has(p_name), Resource::_set(p_name, p_property));
	if (p_property.get_type() == Variant::NIL) {
		RS->material_set_param(_material, p_name, Variant());
		_shader_params.erase(p_name);
		return true;
	}

	// If value is an object, assume a Texture. RS only wants RIDs, but
	// Inspector wants the object, so set the RID and save the latter for _get
	if (p_property.get_type() == Variant::OBJECT) {
		Ref<Texture> tex = p_property;
		if (tex.is_valid()) {
			_shader_params[p_name] = tex;
			RS->material_set_param(_material, p_name, tex->get_rid());
		} else {
			RS->material_set_param(_material, p_name, Variant());
		}
	} else {
		_shader_params[p_name] = p_property;
		RS->material_set_param(_material, p_name, p_property);
	}
	return true;
}

// This is called 200x more than the others, every second the material is open in the
// inspector, so be efficient
bool Terrain3DMaterial::_get(const StringName &p_name, Variant &r_property) const {
	IS_INIT_COND(!_active_params.has(p_name), Resource::_get(p_name, r_property));

	r_property = RS->material_get_param(_material, p_name);
	// Material server only has RIDs, but inspector needs objects for things like Textures
	// So if its an RID, return the object
	if (r_property.get_type() == Variant::RID && _shader_params.has(p_name)) {
		r_property = _shader_params[p_name];
	}
	return true;
}

void Terrain3DMaterial::_bind_methods() {
	BIND_ENUM_CONSTANT(NONE);
	BIND_ENUM_CONSTANT(FLAT);
	BIND_ENUM_CONSTANT(NOISE);
	BIND_ENUM_CONSTANT(LINEAR);
	BIND_ENUM_CONSTANT(NEAREST);

	// Private
	ClassDB::bind_method(D_METHOD("_set_shader_parameters", "dict"), &Terrain3DMaterial::_set_shader_parameters);
	ClassDB::bind_method(D_METHOD("_get_shader_parameters"), &Terrain3DMaterial::_get_shader_parameters);
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "_shader_parameters", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "_set_shader_parameters", "_get_shader_parameters");

	// Public
	ClassDB::bind_method(D_METHOD("update"), &Terrain3DMaterial::update);
	ClassDB::bind_method(D_METHOD("get_material_rid"), &Terrain3DMaterial::get_material_rid);
	ClassDB::bind_method(D_METHOD("get_shader_rid"), &Terrain3DMaterial::get_shader_rid);

	ClassDB::bind_method(D_METHOD("set_world_background", "background"), &Terrain3DMaterial::set_world_background);
	ClassDB::bind_method(D_METHOD("get_world_background"), &Terrain3DMaterial::get_world_background);
	ClassDB::bind_method(D_METHOD("set_texture_filtering", "filtering"), &Terrain3DMaterial::set_texture_filtering);
	ClassDB::bind_method(D_METHOD("get_texture_filtering"), &Terrain3DMaterial::get_texture_filtering);
	ClassDB::bind_method(D_METHOD("set_auto_shader", "enabled"), &Terrain3DMaterial::set_auto_shader);
	ClassDB::bind_method(D_METHOD("get_auto_shader"), &Terrain3DMaterial::get_auto_shader);
	ClassDB::bind_method(D_METHOD("set_dual_scaling", "enabled"), &Terrain3DMaterial::set_dual_scaling);
	ClassDB::bind_method(D_METHOD("get_dual_scaling"), &Terrain3DMaterial::get_dual_scaling);

	ClassDB::bind_method(D_METHOD("enable_shader_override", "enabled"), &Terrain3DMaterial::enable_shader_override);
	ClassDB::bind_method(D_METHOD("is_shader_override_enabled"), &Terrain3DMaterial::is_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("set_shader_override", "shader"), &Terrain3DMaterial::set_shader_override);
	ClassDB::bind_method(D_METHOD("get_shader_override"), &Terrain3DMaterial::get_shader_override);

	ClassDB::bind_method(D_METHOD("set_shader_param", "name", "value"), &Terrain3DMaterial::set_shader_param);
	ClassDB::bind_method(D_METHOD("get_shader_param", "name"), &Terrain3DMaterial::get_shader_param);

	// Overlays
	ClassDB::bind_method(D_METHOD("set_show_region_grid", "enabled"), &Terrain3DMaterial::set_show_region_grid);
	ClassDB::bind_method(D_METHOD("get_show_region_grid"), &Terrain3DMaterial::get_show_region_grid);
	ClassDB::bind_method(D_METHOD("set_show_instancer_grid", "enabled"), &Terrain3DMaterial::set_show_instancer_grid);
	ClassDB::bind_method(D_METHOD("get_show_instancer_grid"), &Terrain3DMaterial::get_show_instancer_grid);
	ClassDB::bind_method(D_METHOD("set_show_vertex_grid", "enabled"), &Terrain3DMaterial::set_show_vertex_grid);
	ClassDB::bind_method(D_METHOD("get_show_vertex_grid"), &Terrain3DMaterial::get_show_vertex_grid);
	ClassDB::bind_method(D_METHOD("set_show_contours", "enabled"), &Terrain3DMaterial::set_show_contours);
	ClassDB::bind_method(D_METHOD("get_show_contours"), &Terrain3DMaterial::get_show_contours);
	ClassDB::bind_method(D_METHOD("set_show_navigation", "enabled"), &Terrain3DMaterial::set_show_navigation);
	ClassDB::bind_method(D_METHOD("get_show_navigation"), &Terrain3DMaterial::get_show_navigation);

	// Debug Views
	ClassDB::bind_method(D_METHOD("set_show_checkered", "enabled"), &Terrain3DMaterial::set_show_checkered);
	ClassDB::bind_method(D_METHOD("get_show_checkered"), &Terrain3DMaterial::get_show_checkered);
	ClassDB::bind_method(D_METHOD("set_show_grey", "enabled"), &Terrain3DMaterial::set_show_grey);
	ClassDB::bind_method(D_METHOD("get_show_grey"), &Terrain3DMaterial::get_show_grey);
	ClassDB::bind_method(D_METHOD("set_show_heightmap", "enabled"), &Terrain3DMaterial::set_show_heightmap);
	ClassDB::bind_method(D_METHOD("get_show_heightmap"), &Terrain3DMaterial::get_show_heightmap);
	ClassDB::bind_method(D_METHOD("set_show_jaggedness", "enabled"), &Terrain3DMaterial::set_show_jaggedness);
	ClassDB::bind_method(D_METHOD("get_show_jaggedness"), &Terrain3DMaterial::get_show_jaggedness);
	ClassDB::bind_method(D_METHOD("set_show_autoshader", "enabled"), &Terrain3DMaterial::set_show_autoshader);
	ClassDB::bind_method(D_METHOD("get_show_autoshader"), &Terrain3DMaterial::get_show_autoshader);
	ClassDB::bind_method(D_METHOD("set_show_control_texture", "enabled"), &Terrain3DMaterial::set_show_control_texture);
	ClassDB::bind_method(D_METHOD("get_show_control_texture"), &Terrain3DMaterial::get_show_control_texture);
	ClassDB::bind_method(D_METHOD("set_show_control_blend", "enabled"), &Terrain3DMaterial::set_show_control_blend);
	ClassDB::bind_method(D_METHOD("get_show_control_blend"), &Terrain3DMaterial::get_show_control_blend);
	ClassDB::bind_method(D_METHOD("set_show_control_angle", "enabled"), &Terrain3DMaterial::set_show_control_angle);
	ClassDB::bind_method(D_METHOD("get_show_control_angle"), &Terrain3DMaterial::get_show_control_angle);
	ClassDB::bind_method(D_METHOD("set_show_control_scale", "enabled"), &Terrain3DMaterial::set_show_control_scale);
	ClassDB::bind_method(D_METHOD("get_show_control_scale"), &Terrain3DMaterial::get_show_control_scale);
	ClassDB::bind_method(D_METHOD("set_show_colormap", "enabled"), &Terrain3DMaterial::set_show_colormap);
	ClassDB::bind_method(D_METHOD("get_show_colormap"), &Terrain3DMaterial::get_show_colormap);
	ClassDB::bind_method(D_METHOD("set_show_roughmap", "enabled"), &Terrain3DMaterial::set_show_roughmap);
	ClassDB::bind_method(D_METHOD("get_show_roughmap"), &Terrain3DMaterial::get_show_roughmap);
	ClassDB::bind_method(D_METHOD("set_show_texture_height", "enabled"), &Terrain3DMaterial::set_show_texture_height);
	ClassDB::bind_method(D_METHOD("get_show_texture_height"), &Terrain3DMaterial::get_show_texture_height);
	ClassDB::bind_method(D_METHOD("set_show_texture_normal", "enabled"), &Terrain3DMaterial::set_show_texture_normal);
	ClassDB::bind_method(D_METHOD("get_show_texture_normal"), &Terrain3DMaterial::get_show_texture_normal);
	ClassDB::bind_method(D_METHOD("set_show_texture_rough", "enabled"), &Terrain3DMaterial::set_show_texture_rough);
	ClassDB::bind_method(D_METHOD("get_show_texture_rough"), &Terrain3DMaterial::get_show_texture_rough);

	ClassDB::bind_method(D_METHOD("save", "path"), &Terrain3DMaterial::save, DEFVAL(""));

	ADD_PROPERTY(PropertyInfo(Variant::INT, "world_background", PROPERTY_HINT_ENUM, "None,Flat,Noise"), "set_world_background", "get_world_background");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "texture_filtering", PROPERTY_HINT_ENUM, "Linear,Nearest"), "set_texture_filtering", "get_texture_filtering");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_shader"), "set_auto_shader", "get_auto_shader");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "dual_scaling"), "set_dual_scaling", "get_dual_scaling");

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "shader_override_enabled"), "enable_shader_override", "is_shader_override_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_shader_override", "get_shader_override");

	ADD_GROUP("Overlays", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_region_grid"), "set_show_region_grid", "get_show_region_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_instancer_grid"), "set_show_instancer_grid", "get_show_instancer_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_vertex_grid"), "set_show_vertex_grid", "get_show_vertex_grid");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_contours"), "set_show_contours", "get_show_contours");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_navigation"), "set_show_navigation", "get_show_navigation");

	ADD_GROUP("Debug Views", "show_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_checkered"), "set_show_checkered", "get_show_checkered");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_grey"), "set_show_grey", "get_show_grey");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_heightmap"), "set_show_heightmap", "get_show_heightmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_jaggedness"), "set_show_jaggedness", "get_show_jaggedness");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_autoshader"), "set_show_autoshader", "get_show_autoshader");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_texture"), "set_show_control_texture", "get_show_control_texture");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_blend"), "set_show_control_blend", "get_show_control_blend");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_angle"), "set_show_control_angle", "get_show_control_angle");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_control_scale"), "set_show_control_scale", "get_show_control_scale");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_colormap"), "set_show_colormap", "get_show_colormap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_roughmap"), "set_show_roughmap", "get_show_roughmap");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_height"), "set_show_texture_height", "get_show_texture_height");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_normal"), "set_show_texture_normal", "get_show_texture_normal");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_texture_rough"), "set_show_texture_rough", "get_show_texture_rough");
}
