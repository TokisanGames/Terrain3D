// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/gradient.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/noise_texture2d.hpp>
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
#include "shaders/__DEFINES.glsl"
			, "defines");
	_parse_shader(
#include "shaders/__HEADER.glsl"
			, "header");
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
void Terrain3DMaterial::_parse_shader(String p_shader, String p_name) {
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
String Terrain3DMaterial::_apply_inserts(String p_shader, Array p_excludes) {
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

String Terrain3DMaterial::_generate_shader_code(String _explicitDefines) {
	LOG(INFO, "Generating default shader code");
	Array excludes;
	// Skeletonized code retained for possible future use
	//if (_world_background != NOISE) {
	//	excludes.push_back("WORLD_NOISE1");
	//	excludes.push_back("WORLD_NOISE2");
	//}
	String shader = _add_or_update_header(_apply_inserts(_shader_code["main"], excludes), _explicitDefines);
	return shader; }

/*
* Retained for future use, this is a very handy function we just don't need it currently.
String Terrain3DMaterial::_inject_editor_code(String p_shader) {
	String shader = p_shader;
	int idx = p_shader.rfind("}");
	if (idx < 0) {
		return shader;
	}
	Array insert_names;
	// One example retained
	if (_show_navigation) {
		insert_names.push_back("EDITOR_NAVIGATION");
	}
	for (int i = 0; i < insert_names.size(); i++) {
		String insert = _shader_code[insert_names[i]];
		shader = shader.insert(idx - 1, "\n" + insert);
		idx += insert.length();
	}
	return shader;
}
*/

String Terrain3DMaterial::_add_if_exists(String _current, String _snippetID_) {
	if (_current.is_empty()) {
		_current = ""; }
	if (!_snippetID_.is_empty() && _snippetID_ != "" && _shader_code.has(_snippetID_)) {
		_current += _shader_code[_snippetID_]; }
	return _current; }

String Terrain3DMaterial::_add_if_enabled(String _current, bool _controlVar, String _snippetID_enabled, String _snippetID_disabled) {
	if (_current.is_empty()) {
		_current = ""; }
	if (_controlVar) {
		if (!_snippetID_enabled.is_empty() && _snippetID_enabled != "" && _shader_code.has(_snippetID_enabled)) {
			_current += _shader_code[_snippetID_enabled]; } } 
	else {
		if (!_snippetID_disabled.is_empty() && _snippetID_disabled != "" && _shader_code.has(_snippetID_disabled)) {
			_current += _shader_code[_snippetID_disabled]; } }
	return _current; }

Array Terrain3DMaterial::_add_if_true(Array _toset, bool _condition, String _toadd, String _toadd_if_false) {
	if (_condition) { 
		if (!_toadd.is_empty() && _toadd != "") {
			_toset.push_back(_toadd); } }
	else {
		if (!_toadd.is_empty() && _toadd_if_false != "") {
			_toset.push_back(_toadd_if_false); } }
	return _toset; }

String Terrain3DMaterial::_get_current_defines() {
	Array _defs;
	_add_if_true(_defs, _blending_texture_filtering == LINEAR,	"TEXTURE_SAMPLERS_LINEAR",	"TEXTURE_SAMPLERS_NEAREST");
	_add_if_true(_defs, _blending_by_height,					"HEIGHT_BLENDING_ENABLED");
	_add_if_true(_defs, _tinting_enabled,						"NOISE_TINT_ENABLED");
	_add_if_true(_defs, _auto_texturing_enabled,				"AUTO_TEXTURING_ENABLED");
	_add_if_true(_defs, _multi_scaling_enabled,					"MULTI_SCALING_ENABLED");
	_add_if_true(_defs, _uv_distortion_enabled,					"UV_DISTORTION_ENABLED");

	_add_if_true(_defs, _bg_world_fill >= NOISE,				"BG_WORLD_ENABLED");
	_add_if_true(_defs, _bg_world_fill == FLAT,					"BG_FLAT_ENABLED");
	_add_if_true(_defs, _bg_world_fill == NONE,					"BG_NONE");

	_add_if_true(_defs, _normals_quality == PIXEL,				"NORMALS_PER_PIXEL");
	_add_if_true(_defs, _normals_quality == VERTEX,				"NORMALS_PER_VERTEX");
	_add_if_true(_defs, _normals_quality == BY_DISTANCE,		"NORMALS_BY_DISTANCE");

	_add_if_true(_defs, _debug_view_checkered,			"DEBUG_CHECKERED");
	_add_if_true(_defs, _debug_view_grey,				"DEBUG_GREY");
	_add_if_true(_defs, _debug_view_heightmap,			"DEBUG_HEIGHTMAP");
	_add_if_true(_defs, _debug_view_colormap,			"DEBUG_COLORMAP");
	_add_if_true(_defs, _debug_view_roughmap,			"DEBUG_ROUGHMAP");
	_add_if_true(_defs, _debug_view_control_texture,	"DEBUG_CONTROL_TEXTURE");
	_add_if_true(_defs, _debug_view_control_blend,		"DEBUG_CONTROL_BLEND");
	_add_if_true(_defs, _debug_view_autoshader,			"DEBUG_AUTOSHADER");
	_add_if_true(_defs, _debug_view_holes,				"DEBUG_HOLES");
	_add_if_true(_defs, _debug_view_texture_height,		"DEBUG_TEXTURE_HEIGHT");
	_add_if_true(_defs, _debug_view_texture_normal,		"DEBUG_TEXTURE_NORMAL");
	_add_if_true(_defs, _debug_view_texture_rough,		"DEBUG_TEXTURE_ROUGHNESS");
	_add_if_true(_defs, _debug_view_vertex_grid,		"DEBUG_VERTEX_GRID");
	_add_if_true(_defs, _debug_view_navigation,			"EDITOR_NAVIGATION");

	String o= "";
	for (int d = 0; d < _defs.size(); d++) {
		o += "#define " + (String)_defs[d] + "\n"; }
	return o; }

String Terrain3DMaterial::_add_or_update_header(String _to_code, String _explicitDefines) {
	String o = _explicitDefines != "" ? _explicitDefines : _get_current_defines();
//	_last_generated_defines = o;

	// Any system level, universal defines would go in the DEFINES snippet.
	// ( Currently unused, all defines are dynamically populated.  This is probably where per-instance variants of the shader (ie one for distant, one for close) could manage their feature sets, independantly of the user options.  )
	o = _add_if_exists(o, "DEFINES");

	// The header start mark is just for clarity and currently does not get parsed 
	// for anything later.  Good place for comment banners etc.
	o = _add_if_exists(o, "HEADER_START_MARK");

	// The header itself is added next and contains used uniforms, varyins, etc.
	o = _add_if_exists(o, "HEADER");

	// Very important, add this header end mark so the next step can know how to 
	// remove the header, next time it updates.  ( Also put a banner over it to 
	// warn anyone editing the code that anything above the mark may get overwritten.
	o = _add_if_exists(o, "HEADER_END_MARK_NOTICE");
	o = _add_if_exists(o, "HEADER_END_MARK");

	// Trim any existing managed header area off the current shader, and replace it
	String _sliced = _to_code.get_slice(_shader_code["HEADER_END_MARK"], 1);
	return o + ((_sliced == "") ? _to_code : _sliced);
}

void Terrain3DMaterial::_update_shader_if_defines_have_changed() {
	String _currentDefines = _get_current_defines();
	if (_currentDefines != _last_generated_defines) {
		_update_shader(); } }

void Terrain3DMaterial::_update_shader() {
	IS_INIT(NOP);
	LOG(INFO, "Updating shader");
	RID shader_rid;
	if (_shader_override_enabled && _shader_override.is_valid()) {
		_shader_override->set_code(_shader_override->get_code().is_empty()
			? _generate_shader_code()
			: _add_or_update_header(_shader_override->get_code()));
		if (!_shader_override->is_connected("changed", Callable(this, "_update_shader_if_defines_have_changed"))) {
			LOG(DEBUG, "Connecting changed signal to _update_shader_if_defines_have_changed()");
			_shader_override->connect("changed", Callable(this, "_update_shader_if_defines_have_changed")); }
		_shader_tmp->set_code(_shader_override->get_code());
		shader_rid = _shader_tmp->get_rid(); } 
	else {
		//String code = _generate_shader_code();
		//RS->shader_set_code(_shader, _inject_editor_code(code));
		//shader_rid = _shader;

		// It seems like the RenderingServer version of setting the shader code does not 
		// activate the preprocessor?  This solves it fine for my branch but I'm unsure 
		// if there are regressions from not upkeeping "shader" as expected. - mk
		_shader_tmp->set_code(_generate_shader_code());
		shader_rid = _shader_tmp->get_rid(); }

	RS->material_set_shader(_material, shader_rid);
	LOG(DEBUG, "Material rid: ", _material, ", shader rid: ", shader_rid);

	// Update custom shader params in RenderingServer
	{
		// Populate _active_params
		List<PropertyInfo> pi;
		_get_property_list(&pi);
		LOG(DEBUG, "_active_params: ", _active_params);
		Util::print_dict("_shader_params", _shader_params, DEBUG);
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

	// If no noise texture, generate one
	if (_tinting_texture == Ref<Texture2D>() ) {
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
		_tinting_texture = noise_tex;
	}

	if(_tinting_texture.is_valid()) { RS->material_set_param(_material, "_tinting_texture", _tinting_texture->get_rid() ); }
	
	// Set specific managed shader parameters
	UPDATE_MANAGED_VARS()
	
	notify_property_list_changed();
}

void Terrain3DMaterial::_update_regions() {
	IS_STORAGE_INIT(NOP);
	LOG(INFO, "Updating region maps in shader");

	Ref<Terrain3DStorage> storage = _terrain->get_storage();
	RS->material_set_param(_material, "_height_maps", storage->get_height_rid());
	RS->material_set_param(_material, "_control_maps", storage->get_control_rid());
	RS->material_set_param(_material, "_color_maps", storage->get_color_rid());
	LOG(DEBUG, "Height map RID: ", storage->get_height_rid());
	LOG(DEBUG, "Control map RID: ", storage->get_control_rid());
	LOG(DEBUG, "Color map RID: ", storage->get_color_rid());

	PackedInt32Array region_map = storage->get_region_map();
	LOG(DEBUG, "region_map.size(): ", region_map.size());
	if (region_map.size() != Terrain3DStorage::REGION_MAP_SIZE * Terrain3DStorage::REGION_MAP_SIZE) {
		LOG(ERROR, "Expected region_map.size() of ", Terrain3DStorage::REGION_MAP_SIZE * Terrain3DStorage::REGION_MAP_SIZE);
	}
	RS->material_set_param(_material, "_region_map", region_map);
	RS->material_set_param(_material, "_region_map_size", Terrain3DStorage::REGION_MAP_SIZE);
	if (Terrain3D::debug_level >= DEBUG) {
		LOG(DEBUG, "Region map");
		for (int i = 0; i < region_map.size(); i++) {
			if (region_map[i]) {
				LOG(DEBUG, "Region id: ", region_map[i], " array index: ", i);
			}
		}
	}

	TypedArray<Vector2i> region_offsets = storage->get_region_offsets();
	LOG(DEBUG, "Region_offsets size: ", region_offsets.size(), " ", region_offsets);
	RS->material_set_param(_material, "_region_offsets", region_offsets);

	real_t region_size = real_t(storage->get_region_size());
	LOG(DEBUG, "Setting region size in material: ", region_size);
	RS->material_set_param(_material, "_region_size", region_size);
	RS->material_set_param(_material, "_region_pixel_size", 1.0f / region_size);

	real_t spacing = _terrain->get_mesh_vertex_spacing();
	LOG(DEBUG, "Setting mesh vertex spacing in material: ", spacing);
	RS->material_set_param(_material, "_mesh_vertex_spacing", spacing);
	RS->material_set_param(_material, "_mesh_vertex_density", 1.0f / spacing);

	_generate_region_blend_map();
}

void Terrain3DMaterial::_generate_region_blend_map() {
	IS_STORAGE_INIT_MESG("Material not initialized", NOP);
	PackedInt32Array region_map = _terrain->get_storage()->get_region_map();
	int rsize = Terrain3DStorage::REGION_MAP_SIZE;
	if (region_map.size() == rsize * rsize) {
		LOG(DEBUG, "Regenerating ", Vector2i(512, 512), " region blend map");
		Ref<Image> region_blend_img = Image::create(rsize, rsize, false, Image::FORMAT_RH);
		for (int y = 0; y < rsize; y++) {
			for (int x = 0; x < rsize; x++) {
				if (region_map[y * rsize + x] > 0) {
					region_blend_img->set_pixel(x, y, COLOR_WHITE);
				}
			}
		}
		region_blend_img->resize(512, 512, Image::INTERPOLATE_TRILINEAR);
		_generated_region_blend_map.clear();
		_generated_region_blend_map.create(region_blend_img);
		RS->material_set_param(_material, "_region_blend_map", _generated_region_blend_map.get_rid());
		Util::dump_gen(_generated_region_blend_map, "blend_map");
	}
}

// Called from signal connected in Terrain3D, emitted by texture_list
void Terrain3DMaterial::_update_texture_arrays() {
	IS_STORAGE_INIT_MESG("Material not initialized", NOP);
	Ref<Terrain3DTextureList> texture_list = _terrain->get_texture_list();
	LOG(INFO, "Updating texture arrays in shader");
	if (texture_list.is_null()) {
		LOG(ERROR, "Texture_list is null");
		return;
	}

	RS->material_set_param(_material, "_texture_array_albedo", texture_list->get_albedo_array_rid());
	RS->material_set_param(_material, "_texture_array_normal", texture_list->get_normal_array_rid());
	RS->material_set_param(_material, "_texture_color_array", texture_list->get_texture_colors());
	RS->material_set_param(_material, "_texture_uv_scale_array", texture_list->get_texture_uv_scales());
	RS->material_set_param(_material, "_texture_uv_rotation_array", texture_list->get_texture_uv_rotations());

	// Enable checkered view if texture_count is 0, disable if not
	if (texture_list->get_texture_count() == 0) {
		if (_debug_view_checkered == false) {
			set_debug_view_checkered(true);
			LOG(DEBUG, "No textures, enabling checkered view");
		}
	} else {
		set_debug_view_checkered(false);
		LOG(DEBUG, "Texture count >0: ", texture_list->get_texture_count(), ", disabling checkered view");
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
	if (p_terrain != nullptr) {
		_terrain = p_terrain;
	} else {
		LOG(ERROR, "Initialization failed, p_terrain is null");
		return;
	}
	LOG(INFO, "Initializing material");
	_preload_shaders();
	_material = RS->material_create();
	_shader = RS->shader_create();
	_shader_tmp.instantiate();
	LOG(DEBUG, "Mat RID: ", _material, ", _shader RID: ", _shader);
	_update_shader();
	_update_regions();
}

Terrain3DMaterial::~Terrain3DMaterial() {
	IS_INIT(NOP);
	LOG(INFO, "Destroying material");
	RS->free_rid(_material);
	RS->free_rid(_shader);
	_generated_region_blend_map.clear();
}

RID Terrain3DMaterial::get_shader_rid() const {
	if (_shader_override_enabled) {
		return _shader_tmp->get_rid();
	} else {
		return _shader;
	}
}

void Terrain3DMaterial::enable_shader_override(bool p_enabled) {
	LOG(INFO, "Enable shader override: ", p_enabled);
	_shader_override_enabled = p_enabled;
	if (_shader_override_enabled && _shader_override.is_null()) {
		_shader_override.instantiate();
		LOG(DEBUG, "_shader_override RID: ", _shader_override->get_rid());
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

void Terrain3DMaterial::save() {
	LOG(DEBUG, "Generating parameter list from shaders");
	// Get shader parameters from default shader (eg bg_world)
	Array param_list;
	param_list = RS->get_shader_parameter_list(_shader);
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

	// Save to external resource file if used
	String path = get_path();
	if (path.get_extension() == "tres" || path.get_extension() == "res") {
		LOG(DEBUG, "Attempting to save material to external file: " + path);
		Error err;
		err = ResourceSaver::get_singleton()->save(this, path, ResourceSaver::FLAG_COMPRESS);
		ERR_FAIL_COND(err);
		LOG(DEBUG, "ResourceSaver return error (0 is OK): ", err);
		LOG(INFO, "Finished saving material");
	}
}

///////////////////////////
// Protected Functions
///////////////////////////

// Add shader uniforms to properties. Hides uniforms that begin with _
void Terrain3DMaterial::_get_property_list(List<PropertyInfo> *p_list) const {
	Resource::_get_property_list(p_list);
	IS_INIT(NOP);
	Array param_list;
	if (_shader_override_enabled && _shader_override.is_valid()) {
		// Get shader parameters from custom shader
		param_list = _shader_override->get_shader_uniform_list(true);
	} else {
		// Get shader parameters from default shader (eg bg_world)
		param_list = RS->get_shader_parameter_list(_shader);
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
	RID shader;
	if (_shader_override_enabled && _shader_override.is_valid()) {
		shader = _shader_override->get_rid();
	} else {
		shader = _shader;
	}
	if (shader.is_valid()) {
		Variant default_value = RS->shader_get_parameter_default(shader, p_name);
		Variant current_value = RS->material_get_param(_material, p_name);
		return default_value != current_value;
	}
	return false;
}

// Provide uniform default values
bool Terrain3DMaterial::_property_get_revert(const StringName &p_name, Variant &r_property) const {
	IS_INIT_COND(!_active_params.has(p_name), Resource::_property_get_revert(p_name, r_property));
	RID shader;
	if (_shader_override_enabled && _shader_override.is_valid()) {
		shader = _shader_override->get_rid();
	} else {
		shader = _shader;
	}
	if (shader.is_valid()) {
		r_property = RS->shader_get_parameter_default(shader, p_name);
		return true;
	}
	return false;
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

// Original unoptimized version retained for reference (more readable) 
//float Terrain3DMaterial::hashv2(Vector2 v) {
//	return Math::fract(10000.0f * sin(17.0f * v.x + v.y * 0.1f) * (0.1f + abs(sin(v.y * 13.0f + v.x)))); }

float Terrain3DMaterial::ihashv2(Vector2i iv) {  
	Vector2 v = Vector2( iv * Vector2i(17, 13) ) + Vector2( float(iv.y) * 0.1, float(iv.x) );
	v.x = sin(v.x);
	v.y = ( abs(sin(v.y)) + 0.1 );
	return Math::fract( 1e4 * v.x * v.y ); }

// https://iquilezles.org/articles/morenoise/
Vector3 Terrain3DMaterial::noise2D(Vector2 x) {
    Vector2 f = Vector2(Math::fract(x.x),Math::fract(x.y));
    // Quintic Hermine Curve.  Similar to SmoothStep()
	Vector2 f2 = f*f;
    Vector2 u = f2*f*(f*(f*6.0f-Vector2(15.0f, 15.0f))+Vector2(10.0f, 10.0f));
    Vector2 du = 30.0f*f2*(f*(f-Vector2(2.0f, 2.0f))+Vector2(1.0f, 1.0f));

    Vector2i p = Vector2i(Math::floor(x.x), Math::floor(x.y));

	// Four corners in 2D of a tile
	float a = ihashv2( p );
    float b = ihashv2( p+Vector2i(1,0) );
    float c = ihashv2( p+Vector2i(0,1) );
    float d = ihashv2( p+Vector2i(1,1) );

    // Mix 4 corner percentages
    float k0 =   a;
    float k1 =   b - a;
    float k2 =   c - a;
    float k3 =   a - b - c + d;
	Vector2 _direvs = du * ( Vector2(k1, k2) + k3 * Vector2(u.y,u.x) );
    return Vector3( k0 + k1 * u.x + k2 * u.y + k3 * u.x * u.y, _direvs.x, _direvs.y ); }

int Terrain3DMaterial::get_octaves_by_distance(float d) {
    return int( Math::clamp(
	float(_bg_world_max_octaves) - Math::floor(d /(_bg_world_lod_distance)),
    float(_bg_world_min_octaves), float(_bg_world_max_octaves)) ); }

float Terrain3DMaterial::noise_type1(Vector2 p, int octaves) {
    float a = 0.0f;
    float b = 1.0f;
    Vector2  d = Vector2(0.0f, 0.0f);
    for( int i=0; i < octaves; i++ ) {
        Vector3 n = noise2D(p);
        d += Vector2(n.y, n.z);
        a += b * n.x / (1.0f + d.dot(d));
        b *= 0.5f;
        p = Vector2(0.8f * p.x + 0.6f * p.y, -0.6f * p.x + 0.8f * p.y) *2.0f; }
    return a; }

float Terrain3DMaterial::get_unweighted_generated_height(Vector3 worldPos, int octaves) {
	worldPos += _bg_world_offset;
	float dx, dy;
	const float _offs = 16.0f * 1024.0f;
	// Should the half pixel be added before, after, or not at all?  Not at all for now.
	dx = ((worldPos.x+_offs)/1024.0f)-16.f;
	dy = ((worldPos.z+_offs)/1024.0f)-16.f;
	Vector2 uv = Vector2(dx, dy);
	return noise_type1( uv * _bg_world_scale * .1 , octaves) * (_bg_world_height*10.0f) + (_bg_world_offset.y * 100.f); }

String Terrain3DMaterial::_format_string_for_inline_help (String _source) { 
		return _source.replace("\n\n", "[__TEMP_CRLF__]").replace("\n", "").replace("[__TEMP_CRLF__]", "\n\n"); }

void Terrain3DMaterial::_safe_material_set_param(StringName _param, Variant _value) {
	if (_terrain != nullptr && _material.is_valid()) {
		RS->material_set_param(_material, _param, _value); } }

MAKE_MANAGED_FUNCTIONS()

void Terrain3DMaterial::_bind_methods() {
	BIND_MANAGED_VARS()
	BIND_ENUM_CONSTANT(NONE);
	BIND_ENUM_CONSTANT(FLAT);
	BIND_ENUM_CONSTANT(NOISE);
	BIND_ENUM_CONSTANT(LINEAR);
	BIND_ENUM_CONSTANT(NEAREST);
	BIND_ENUM_CONSTANT(PIXEL);
	BIND_ENUM_CONSTANT(VERTEX);
	BIND_ENUM_CONSTANT(BY_DISTANCE);

	// Private
	ClassDB::bind_method(D_METHOD("_set_shader_parameters", "dict"), &Terrain3DMaterial::_set_shader_parameters);
	ClassDB::bind_method(D_METHOD("_get_shader_parameters"), &Terrain3DMaterial::_get_shader_parameters);
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "_shader_parameters", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "_set_shader_parameters", "_get_shader_parameters");

	// Public
	ClassDB::bind_method(D_METHOD("get_material_rid"), &Terrain3DMaterial::get_material_rid);
	ClassDB::bind_method(D_METHOD("get_shader_rid"), &Terrain3DMaterial::get_shader_rid);
	ClassDB::bind_method(D_METHOD("get_region_blend_map"), &Terrain3DMaterial::get_region_blend_map);
	ClassDB::bind_method(D_METHOD("enable_shader_override", "enabled"), &Terrain3DMaterial::enable_shader_override);
	ClassDB::bind_method(D_METHOD("is_shader_override_enabled"), &Terrain3DMaterial::is_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("set_shader_override", "shader"), &Terrain3DMaterial::set_shader_override);
	ClassDB::bind_method(D_METHOD("get_shader_override"), &Terrain3DMaterial::get_shader_override);
	ClassDB::bind_method(D_METHOD("set_shader_param", "name", "value"), &Terrain3DMaterial::set_shader_param);
	ClassDB::bind_method(D_METHOD("get_shader_param", "name"), &Terrain3DMaterial::get_shader_param);
	ClassDB::bind_method(D_METHOD("save"), &Terrain3DMaterial::save);
	ClassDB::bind_method(D_METHOD("get_unweighted_generated_height"), &Terrain3DMaterial::get_unweighted_generated_height);
	ClassDB::bind_method(D_METHOD("get_octaves_by_distance"), &Terrain3DMaterial::get_octaves_by_distance);
	ClassDB::bind_method(D_METHOD("noise_type1"), &Terrain3DMaterial::noise_type1);

	ADD_MANAGED_PROPS()
	
	ADD_GROUP("Custom Shader",                 "shader_");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL,   "shader_override_enabled", PROPERTY_HINT_NONE), "enable_shader_override", "is_shader_override_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_shader_override", "get_shader_override");
	ADD_INLINE_HELP(shader_override, Custom Shader, About Custom Shaders)
}
