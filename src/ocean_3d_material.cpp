#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/gradient.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/noise_texture2d.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/resource_saver.hpp>

#include "logger.h"
#include "ocean_3d.h"
#include "ocean_3d_material.h"
#include "terrain_3d_util.h"

///////////////////////////
// Private Functions
///////////////////////////

void Ocean3DMaterial::_preload_shaders() {
	// Preprocessor loading of external shader inserts
	// 	_parse_shader(
	// #include "shaders/world_noise.glsl"
	// 			, "world_noise");

	// Load main code
	_shader_code["main"] = String(
#include "shaders/water.glsl"
	);

	if (Ocean3D::debug_level >= DEBUG) {
		Array keys = _shader_code.keys();
		for (int i = 0; i < keys.size(); i++) {
			LOG(DEBUG, "Loaded shader insert: ", keys[i]);
		}
	}
}

/**
 *	All `//INSERT: ID` blocks in p_shader are loaded into the DB _shader_code
 */
void Ocean3DMaterial::_parse_shader(String p_shader, String p_name) {
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
String Ocean3DMaterial::_apply_inserts(String p_shader, Array p_excludes) {
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

String Ocean3DMaterial::_generate_shader_code() {
	LOG(INFO, "Generating default shader code");
	Array excludes;

	// This will be removed afterwards
	if (_world_background != NONE) {
		excludes.push_back("WORLD_NOISE1");
	}
	String shader = _apply_inserts(_shader_code["main"], excludes);
	return shader;
}

String Ocean3DMaterial::_inject_editor_code(String p_shader) {
	String shader = p_shader;
	int idx = p_shader.rfind("}");
	if (idx < 0) {
		return shader;
	}
	Array insert_names;

	for (int i = 0; i < insert_names.size(); i++) {
		String insert = _shader_code[insert_names[i]];
		shader = shader.insert(idx - 1, "\n" + insert);
		idx += insert.length();
	}
	return shader;
}

void Ocean3DMaterial::_update_shader() {
	if (!_initialized) {
		return;
	}
	LOG(INFO, "Updating shader");
	RID shader_rid;
	if (_shader_override_enabled && _shader_override.is_valid()) {
		if (_shader_override->get_code().is_empty()) {
			String code = _generate_shader_code();
			_shader_override->set_code(code);
		}
		if (!_shader_override->is_connected("changed", Callable(this, "_update_shader"))) {
			LOG(DEBUG, "Connecting changed signal to _update_shader()");
			_shader_override->connect("changed", Callable(this, "_update_shader"));
		}
		String code = _shader_override->get_code();
		_shader_tmp->set_code(_inject_editor_code(code));
		shader_rid = _shader_tmp->get_rid();
	} else {
		String code = _generate_shader_code();
		RS->shader_set_code(_shader, _inject_editor_code(code));
		shader_rid = _shader;
	}
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
		if (!param.begins_with("_")) {
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
	}
	notify_property_list_changed();
}

void Ocean3DMaterial::_set_region_size(int p_size) {
	LOG(INFO, "Setting region size in material: ", p_size);
	_region_size = CLAMP(p_size, 64, 4096);
	_region_sizev = Vector2i(_region_size, _region_size);
	RS->material_set_param(_material, "_region_size", real_t(_region_size));
	RS->material_set_param(_material, "_region_pixel_size", 1.0f / real_t(_region_size));
}

void Ocean3DMaterial::_set_shader_parameters(const Dictionary &p_dict) {
	LOG(INFO, "Setting shader params dictionary: ", p_dict.size());
	_shader_params = p_dict;
}

///////////////////////////
// Public Functions
///////////////////////////

// This function serves as the constructor which is initialized by the class Terrain3D.
// Godot likes to create resource objects at startup, so this prevents it from creating
// uninitialized materials.
void Ocean3DMaterial::initialize(int p_region_size) {
	LOG(INFO, "Initializing material");
	_preload_shaders();
	_material = RS->material_create();
	_shader = RS->shader_create();
	_shader_tmp.instantiate();
	_set_region_size(p_region_size);
	set_world_background(WorldBackground::NONE);
	LOG(DEBUG, "Mat RID: ", _material, ", _shader RID: ", _shader);
	_initialized = true;
	_update_shader();
}

Ocean3DMaterial::~Ocean3DMaterial() {
	LOG(INFO, "Destroying material");
	if (_initialized) {
		RS->free_rid(_material);
		RS->free_rid(_shader);
	}
}

RID Ocean3DMaterial::get_shader_rid() const {
	if (_shader_override_enabled) {
		return _shader_tmp->get_rid();
	} else {
		return _shader;
	}
}

void Ocean3DMaterial::set_world_background(WorldBackground p_background) {
	LOG(INFO, "Enable world background: ", p_background);
	_world_background = p_background;
	_update_shader();
}

void Ocean3DMaterial::enable_shader_override(bool p_enabled) {
	LOG(INFO, "Enable shader override: ", p_enabled);
	_shader_override_enabled = p_enabled;
	if (_shader_override_enabled && _shader_override.is_null()) {
		_shader_override.instantiate();
		LOG(DEBUG, "_shader_override RID: ", _shader_override->get_rid());
	}
	_update_shader();
}

void Ocean3DMaterial::set_shader_override(const Ref<Shader> &p_shader) {
	LOG(INFO, "Setting override shader");
	_shader_override = p_shader;
	_update_shader();
}

void Ocean3DMaterial::set_shader_param(const StringName &p_name, const Variant &p_value) {
	LOG(INFO, "Setting shader parameter: ", p_name);
	_set(p_name, p_value);
}

Variant Ocean3DMaterial::get_shader_param(const StringName &p_name) const {
	LOG(INFO, "Setting shader parameter: ", p_name);
	Variant value;
	_get(p_name, value);
	return value;
}

void Ocean3DMaterial::set_mesh_vertex_spacing(real_t p_spacing) {
	LOG(INFO, "Setting mesh vertex spacing in material: ", p_spacing);
	_mesh_vertex_spacing = p_spacing;
	RS->material_set_param(_material, "_mesh_vertex_spacing", p_spacing);
	RS->material_set_param(_material, "_mesh_vertex_density", 1.0f / p_spacing);
}

void Ocean3DMaterial::save() {
	LOG(DEBUG, "Generating parameter list from shaders");
	// Get shader parameters from default shader (eg world_noise)
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
void Ocean3DMaterial::_get_property_list(List<PropertyInfo> *p_list) const {
	Resource::_get_property_list(p_list);
	if (!_initialized) {
		return;
	}

	Array param_list;
	if (_shader_override_enabled && _shader_override.is_valid()) {
		// Get shader parameters from custom shader
		param_list = _shader_override->get_shader_uniform_list(true);
	} else {
		// Get shader parameters from default shader (eg world_noise)
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

			// Store this param in a dictionary that is saved in the resource file
			// Initially set with default value
			// Also acts as a cache for _get
			// Property usage above set to EDITOR so it won't be redundantly saved,
			// which won't get loaded since there is no bound property.
			if (!_shader_params.has(name)) {
				_property_get_revert(name, _shader_params[name]);
			}
		}

		// Populate list of public and private parameters for current shader
		_active_params.push_back(name);
	}
	return;
}

// Flag uniforms with non-default values
// This is called 10x more than the others, so be efficient
bool Ocean3DMaterial::_property_can_revert(const StringName &p_name) const {
	if (!_initialized || !_active_params.has(p_name)) {
		return Resource::_property_can_revert(p_name);
	}
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
bool Ocean3DMaterial::_property_get_revert(const StringName &p_name, Variant &r_property) const {
	if (!_initialized || !_active_params.has(p_name)) {
		return Resource::_property_get_revert(p_name, r_property);
	}
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

bool Ocean3DMaterial::_set(const StringName &p_name, const Variant &p_property) {
	if (!_initialized || !_active_params.has(p_name)) {
		return Resource::_set(p_name, p_property);
	}

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
bool Ocean3DMaterial::_get(const StringName &p_name, Variant &r_property) const {
	if (!_initialized || !_active_params.has(p_name)) {
		return Resource::_get(p_name, r_property);
	}

	r_property = RS->material_get_param(_material, p_name);
	// Material server only has RIDs, but inspector needs objects for things like Textures
	// So if its an RID, return the object
	if (r_property.get_type() == Variant::RID && _shader_params.has(p_name)) {
		r_property = _shader_params[p_name];
	}
	return true;
}

void Ocean3DMaterial::_bind_methods() {
	BIND_ENUM_CONSTANT(NONE);
	BIND_ENUM_CONSTANT(INFINITE);

	// Private, but Public workaround until callable_mp is implemented
	// https://github.com/godotengine/godot-cpp/pull/1155
	ClassDB::bind_method(D_METHOD("_update_shader"), &Ocean3DMaterial::_update_shader);
	ClassDB::bind_method(D_METHOD("_set_region_size", "width"), &Ocean3DMaterial::_set_region_size);

	ClassDB::bind_method(D_METHOD("_set_shader_parameters", "dict"), &Ocean3DMaterial::_set_shader_parameters);
	ClassDB::bind_method(D_METHOD("_get_shader_parameters"), &Ocean3DMaterial::_get_shader_parameters);
	ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "_shader_parameters", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE), "_set_shader_parameters", "_get_shader_parameters");

	// Public
	ClassDB::bind_method(D_METHOD("get_material_rid"), &Ocean3DMaterial::get_material_rid);
	ClassDB::bind_method(D_METHOD("get_shader_rid"), &Ocean3DMaterial::get_shader_rid);

	ClassDB::bind_method(D_METHOD("enable_shader_override", "enabled"), &Ocean3DMaterial::enable_shader_override);
	ClassDB::bind_method(D_METHOD("is_shader_override_enabled"), &Ocean3DMaterial::is_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("set_shader_override", "shader"), &Ocean3DMaterial::set_shader_override);
	ClassDB::bind_method(D_METHOD("get_shader_override"), &Ocean3DMaterial::get_shader_override);

	ClassDB::bind_method(D_METHOD("set_shader_param", "name", "value"), &Ocean3DMaterial::set_shader_param);
	ClassDB::bind_method(D_METHOD("get_shader_param", "name"), &Ocean3DMaterial::get_shader_param);

	ClassDB::bind_method(D_METHOD("save"), &Ocean3DMaterial::save);

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "shader_override_enabled", PROPERTY_HINT_NONE), "enable_shader_override", "is_shader_override_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_shader_override", "get_shader_override");
}
