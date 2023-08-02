// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#include <godot_cpp/core/class_db.hpp>

#include "terrain_3d_logger.h"
#include "terrain_3d_surface.h"

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

void Terrain3DSurface::set_albedo(Color p_color) {
	_albedo = p_color;
	emit_signal("value_changed");
}

void Terrain3DSurface::set_albedo_texture(const Ref<Texture2D> &p_texture) {
	if (_texture_is_valid(p_texture)) {
		_albedo_texture = p_texture;
		emit_signal("texture_changed");
	}
}

void Terrain3DSurface::set_normal_texture(const Ref<Texture2D> &p_texture) {
	if (_texture_is_valid(p_texture)) {
		_normal_texture = p_texture;
		emit_signal("texture_changed");
	}
}

void Terrain3DSurface::set_uv_scale(float p_scale) {
	_uv_scale = p_scale;
	emit_signal("value_changed");
}

void Terrain3DSurface::set_uv_rotation(float p_rotation) {
	_uv_rotation = CLAMP(p_rotation, 0.0f, 1.0f);
	emit_signal("value_changed");
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DSurface::_bind_methods() {
	ADD_SIGNAL(MethodInfo("texture_changed"));
	ADD_SIGNAL(MethodInfo("value_changed"));

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

	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "albedo", PROPERTY_HINT_COLOR_NO_ALPHA), "set_albedo", "get_albedo");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "albedo_texture", PROPERTY_HINT_RESOURCE_TYPE, "ImageTexture,CompressedTexture2D"), "set_albedo_texture", "get_albedo_texture");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "normal_texture", PROPERTY_HINT_RESOURCE_TYPE, "ImageTexture,CompressedTexture2D"), "set_normal_texture", "get_normal_texture");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "uv_scale", PROPERTY_HINT_RANGE, "0.001, 2.0"), "set_uv_scale", "get_uv_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "uv_rotation", PROPERTY_HINT_RANGE, "0.0, 1.0"), "set_uv_rotation", "get_uv_rotation");
}