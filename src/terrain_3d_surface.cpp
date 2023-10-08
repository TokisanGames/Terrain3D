// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#include <godot_cpp/classes/image.hpp>

#include "logger.h"
#include "terrain_3d_surface.h"

/******************************************************************
 * This class is DEPRECATED in 0.8.3. Remove 0.9. Do not use.
 ******************************************************************/

///////////////////////////
// Private Functions
///////////////////////////

bool Terrain3DSurface::_texture_is_valid(const Ref<Texture2D> &p_texture) const {
	if (p_texture.is_null()) {
		LOG(DEBUG, "Provided texture is null.");
		return true;
	}

	Ref<Image> img = p_texture->get_image();
	Image::Format format = Image::FORMAT_MAX;
	if (img.is_valid()) {
		format = img->get_format();
	}
	if (format != Image::FORMAT_DXT5) {
		LOG(ERROR, "Invalid format. Expected channel packed DXT5 RGBA8. See documentation for format.");
		return false;
	}

	return true;
}

///////////////////////////
// Public Functions
///////////////////////////

Terrain3DSurface::Terrain3DSurface() {
}

Terrain3DSurface::~Terrain3DSurface() {
}

void Terrain3DSurface::clear() {
	_data._name = "New Texture";
	_data._surface_id = 0;
	_data._albedo = Color(1.0, 1.0, 1.0, 1.0);
	_data._albedo_texture.unref();
	_data._normal_texture.unref();
	_data._uv_scale = 0.1f;
	_data._uv_rotation = 0.0f;
}

void Terrain3DSurface::set_name(String p_name) {
	_data._name = p_name;
}

void Terrain3DSurface::set_surface_id(int p_new_id) {
	int old_id = _data._surface_id;
	_data._surface_id = p_new_id;
}

void Terrain3DSurface::set_albedo(Color p_color) {
	_data._albedo = p_color;
}

void Terrain3DSurface::set_albedo_texture(const Ref<Texture2D> &p_texture) {
	if (_texture_is_valid(p_texture)) {
		_data._albedo_texture = p_texture;
	}
}

void Terrain3DSurface::set_normal_texture(const Ref<Texture2D> &p_texture) {
	if (_texture_is_valid(p_texture)) {
		_data._normal_texture = p_texture;
	}
}

void Terrain3DSurface::set_uv_scale(float p_scale) {
	_data._uv_scale = p_scale;
}

void Terrain3DSurface::set_uv_rotation(float p_rotation) {
	_data._uv_rotation = CLAMP(p_rotation, 0.0f, 1.0f);
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DSurface::_bind_methods() {
	ClassDB::bind_method(D_METHOD("clear"), &Terrain3DSurface::clear);
	ClassDB::bind_method(D_METHOD("set_name", "name"), &Terrain3DSurface::set_name);
	ClassDB::bind_method(D_METHOD("get_name"), &Terrain3DSurface::get_name);
	ClassDB::bind_method(D_METHOD("set_surface_id", "id"), &Terrain3DSurface::set_surface_id);
	ClassDB::bind_method(D_METHOD("get_surface_id"), &Terrain3DSurface::get_surface_id);
	ClassDB::bind_method(D_METHOD("set_albedo", "color"), &Terrain3DSurface::set_albedo);
	ClassDB::bind_method(D_METHOD("get_albedo"), &Terrain3DSurface::get_albedo);
	ClassDB::bind_method(D_METHOD("set_albedo_texture", "texture"), &Terrain3DSurface::set_albedo_texture);
	ClassDB::bind_method(D_METHOD("get_albedo_texture"), &Terrain3DSurface::get_albedo_texture);
	ClassDB::bind_method(D_METHOD("set_normal_texture", "texture"), &Terrain3DSurface::set_normal_texture);
	ClassDB::bind_method(D_METHOD("get_normal_texture"), &Terrain3DSurface::get_normal_texture);
	ClassDB::bind_method(D_METHOD("set_uv_scale", "scale"), &Terrain3DSurface::set_uv_scale);
	ClassDB::bind_method(D_METHOD("get_uv_scale"), &Terrain3DSurface::get_uv_scale);
	ClassDB::bind_method(D_METHOD("set_uv_rotation", "scale"), &Terrain3DSurface::set_uv_rotation);
	ClassDB::bind_method(D_METHOD("get_uv_rotation"), &Terrain3DSurface::get_uv_rotation);

	ADD_PROPERTY(PropertyInfo(Variant::STRING, "name", PROPERTY_HINT_NONE), "set_name", "get_name");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "surface_id", PROPERTY_HINT_NONE), "set_surface_id", "get_surface_id");
	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "albedo", PROPERTY_HINT_COLOR_NO_ALPHA), "set_albedo", "get_albedo");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "albedo_texture", PROPERTY_HINT_RESOURCE_TYPE, "ImageTexture,CompressedTexture2D"), "set_albedo_texture", "get_albedo_texture");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "normal_texture", PROPERTY_HINT_RESOURCE_TYPE, "ImageTexture,CompressedTexture2D"), "set_normal_texture", "get_normal_texture");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "uv_scale", PROPERTY_HINT_RANGE, "0.001, 2.0"), "set_uv_scale", "get_uv_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "uv_rotation", PROPERTY_HINT_RANGE, "0.0, 1.0"), "set_uv_rotation", "get_uv_rotation");
}