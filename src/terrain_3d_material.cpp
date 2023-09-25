// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#include <godot_cpp/classes/rendering_server.hpp>

#include "terrain_3d_logger.h"
#include "terrain_3d_material.h"

///////////////////////////
// Private Functions
///////////////////////////

///////////////////////////
// Public Functions
///////////////////////////

Terrain3DMaterial::Terrain3DMaterial() {
}

Terrain3DMaterial::~Terrain3DMaterial() {
	//RS->free_rid(_material);
	//RS->free_rid(_shader);
}

void Terrain3DMaterial::enable_shader_override(bool p_enabled) {
	LOG(INFO, "Enable shader override: ", p_enabled);
	_shader_override_enabled = p_enabled;
	//if (_shader_override_enabled && _shader_override.is_null()) {
	//	String code = _generate_shader_code();
	//	Ref<Shader> shader;
	//	shader.instantiate();
	//	shader->set_code(code);
	//	//Ref<Terrain3DMaterial> shader_mat;
	//	//shader_mat.instantiate();
	//	//shader_mat->set_shader(shader_res);
	//	//set_shader_override(shader_mat);
	//	set_shader_override(shader);
	//} else {
	//	return ShaderMaterial::_set(p_name, p_property);
	//}
}

void Terrain3DMaterial::set_shader_override(const Ref<Shader> &p_shader) {
	LOG(INFO, "Setting override shader");
	_shader_override = p_shader;
	//setup_shader();
}

void Terrain3DMaterial::set_region_size(int p_size) {
	_region_size = CLAMP(p_size, 64, 4096);
	_region_sizev = Vector2i(_region_size, _region_size);
	//set_param("region_size", _region_size);
	//set_param("region_pixel_size", 1.0f / float(_region_size));
}

void Terrain3DMaterial::set_render_priority(int32_t priority) {
}

void Terrain3DMaterial::set_next_pass(const RID &next_material) {
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DMaterial::_bind_methods() {
	ClassDB::bind_method(D_METHOD("enable_shader_override", "enabled"), &Terrain3DMaterial::enable_shader_override);
	ClassDB::bind_method(D_METHOD("is_shader_override_enabled"), &Terrain3DMaterial::is_shader_override_enabled);
	ClassDB::bind_method(D_METHOD("set_shader_override", "shader_material"), &Terrain3DMaterial::set_shader_override);
	ClassDB::bind_method(D_METHOD("get_shader_override"), &Terrain3DMaterial::get_shader_override);

	ClassDB::bind_method(D_METHOD("set_region_size", "size"), &Terrain3DMaterial::set_region_size);
	ClassDB::bind_method(D_METHOD("get_region_size"), &Terrain3DMaterial::get_region_size);

	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "shader_override_enabled", PROPERTY_HINT_NONE), "enable_shader_override", "is_shader_override_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shader_override", PROPERTY_HINT_RESOURCE_TYPE, "Shader"), "set_shader_override", "get_shader_override");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "region_size", PROPERTY_HINT_NONE), "set_region_size", "get_region_size");
}