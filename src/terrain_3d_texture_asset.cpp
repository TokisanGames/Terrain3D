// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/image.hpp>

#include "logger.h"
#include "terrain_3d_texture_asset.h"

///////////////////////////
// Private Functions
///////////////////////////

// Note a null texture is considered a valid format
bool Terrain3DTextureAsset::_is_valid_format(const Ref<Texture2D> &p_texture) const {
	if (p_texture.is_null()) {
		LOG(DEBUG, "Provided texture is null.");
		return true;
	}

	Ref<Image> img = p_texture->get_image();
	Image::Format format = Image::FORMAT_MAX;
	if (img.is_valid()) {
		format = img->get_format();
	}
	if (format < 0 || format >= Image::FORMAT_MAX) {
		LOG(ERROR, "Invalid texture format. See documentation for format specification.");
		return false;
	}

	return true;
}

///////////////////////////
// Public Functions
///////////////////////////

void Terrain3DTextureAsset::clear() {
	_name = "New Texture";
	_id = 0;
	_albedo_color = Color(1.0f, 1.0f, 1.0f, 1.0f);
	_albedo_texture.unref();
	_normal_texture.unref();
	_uv_scale = 0.1f;
	_detiling = 0.0f;
}

void Terrain3DTextureAsset::set_name(const String &p_name) {
	LOG(INFO, "Setting name: ", p_name);
	_name = p_name;
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_id(const int p_new_id) {
	int old_id = _id;
	_id = CLAMP(p_new_id, 0, Terrain3DAssets::MAX_TEXTURES);
	LOG(INFO, "Setting texture id: ", _id);
	emit_signal("id_changed", Terrain3DAssets::TYPE_TEXTURE, old_id, _id);
}

void Terrain3DTextureAsset::set_albedo_color(const Color &p_color) {
	LOG(INFO, "Setting color: ", p_color);
	_albedo_color = p_color;
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_albedo_texture(const Ref<Texture2D> &p_texture) {
	LOG(INFO, "Setting albedo texture: ", p_texture);
	if (_is_valid_format(p_texture)) {
		_albedo_texture = p_texture;
		if (p_texture.is_valid()) {
			String filename = p_texture->get_path().get_file().get_basename();
			if (_name == "New Texture") {
				_name = filename;
				LOG(INFO, "Naming texture based on filename: ", _name);
			}
			Ref<Image> img = p_texture->get_image();
			if (!img->has_mipmaps()) {
				LOG(WARN, "Texture '", filename, "' has no mipmaps. Change on the Import panel if desired.");
			}
			if (img->get_width() != img->get_height()) {
				LOG(WARN, "Texture '", filename, "' is not square. Mipmaps might have artifacts.");
			}
			if (!is_power_of_2(img->get_width()) || !is_power_of_2(img->get_height())) {
				LOG(WARN, "Texture '", filename, "' size is not power of 2. This is sub-optimal.");
			}
		}
		emit_signal("file_changed");
	}
}

void Terrain3DTextureAsset::set_normal_texture(const Ref<Texture2D> &p_texture) {
	LOG(INFO, "Setting normal texture: ", p_texture);
	if (_is_valid_format(p_texture)) {
		_normal_texture = p_texture;
		if (p_texture.is_valid()) {
			String filename = p_texture->get_path().get_file().get_basename();
			Ref<Image> img = p_texture->get_image();
			if (!img->has_mipmaps()) {
				LOG(WARN, "Texture '", filename, "' has no mipmaps. Change on the Import panel if desired.");
			}
			if (img->get_width() != img->get_height()) {
				LOG(WARN, "Texture '", filename, "' is not square. Not recommended. Mipmaps might have artifacts.");
			}
			if (!is_power_of_2(img->get_width()) || !is_power_of_2(img->get_height())) {
				LOG(WARN, "Texture '", filename, "' dimensions are not power of 2. This is sub-optimal.");
			}
		}
		emit_signal("file_changed");
	}
}

void Terrain3DTextureAsset::set_normal_depth(const real_t p_normal_depth) {
	_normal_depth = CLAMP(p_normal_depth, 0.0f, 2.0f);
	LOG(INFO, "Setting normal_depth: ", _normal_depth);
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_uv_scale(const real_t p_scale) {
	_uv_scale = CLAMP(p_scale, .001f, 2.f);
	LOG(INFO, "Setting uv_scale: ", _uv_scale);
	emit_signal("setting_changed");
}

void Terrain3DTextureAsset::set_detiling(const real_t p_detiling) {
	_detiling = CLAMP(p_detiling, 0.0f, 1.0f);
	LOG(INFO, "Setting detiling: ", _detiling);
	emit_signal("setting_changed");
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DTextureAsset::_bind_methods() {
	ADD_SIGNAL(MethodInfo("id_changed"));
	ADD_SIGNAL(MethodInfo("file_changed"));
	ADD_SIGNAL(MethodInfo("setting_changed"));

	ClassDB::bind_method(D_METHOD("clear"), &Terrain3DTextureAsset::clear);
	ClassDB::bind_method(D_METHOD("set_name", "name"), &Terrain3DTextureAsset::set_name);
	ClassDB::bind_method(D_METHOD("get_name"), &Terrain3DTextureAsset::get_name);
	ClassDB::bind_method(D_METHOD("set_id", "id"), &Terrain3DTextureAsset::set_id);
	ClassDB::bind_method(D_METHOD("get_id"), &Terrain3DTextureAsset::get_id);
	ClassDB::bind_method(D_METHOD("set_albedo_color", "color"), &Terrain3DTextureAsset::set_albedo_color);
	ClassDB::bind_method(D_METHOD("get_albedo_color"), &Terrain3DTextureAsset::get_albedo_color);
	ClassDB::bind_method(D_METHOD("set_albedo_texture", "texture"), &Terrain3DTextureAsset::set_albedo_texture);
	ClassDB::bind_method(D_METHOD("get_albedo_texture"), &Terrain3DTextureAsset::get_albedo_texture);
	ClassDB::bind_method(D_METHOD("set_normal_texture", "texture"), &Terrain3DTextureAsset::set_normal_texture);
	ClassDB::bind_method(D_METHOD("get_normal_texture"), &Terrain3DTextureAsset::get_normal_texture);
	ClassDB::bind_method(D_METHOD("set_normal_depth", "normal_depth"), &Terrain3DTextureAsset::set_normal_depth);
	ClassDB::bind_method(D_METHOD("get_normal_depth"), &Terrain3DTextureAsset::get_normal_depth);
	ClassDB::bind_method(D_METHOD("set_uv_scale", "scale"), &Terrain3DTextureAsset::set_uv_scale);
	ClassDB::bind_method(D_METHOD("get_uv_scale"), &Terrain3DTextureAsset::get_uv_scale);
	ClassDB::bind_method(D_METHOD("set_detiling", "detiling"), &Terrain3DTextureAsset::set_detiling);
	ClassDB::bind_method(D_METHOD("get_detiling"), &Terrain3DTextureAsset::get_detiling);

	ADD_PROPERTY(PropertyInfo(Variant::STRING, "name", PROPERTY_HINT_NONE), "set_name", "get_name");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "id", PROPERTY_HINT_NONE), "set_id", "get_id");
	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "albedo_color", PROPERTY_HINT_COLOR_NO_ALPHA), "set_albedo_color", "get_albedo_color");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "albedo_texture", PROPERTY_HINT_RESOURCE_TYPE, "ImageTexture,CompressedTexture2D"), "set_albedo_texture", "get_albedo_texture");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "normal_texture", PROPERTY_HINT_RESOURCE_TYPE, "ImageTexture,CompressedTexture2D"), "set_normal_texture", "get_normal_texture");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "normal_depth", PROPERTY_HINT_RANGE, "0.0, 2.0"), "set_normal_depth", "get_normal_depth");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "uv_scale", PROPERTY_HINT_RANGE, "0.001, 2.0"), "set_uv_scale", "get_uv_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "detiling", PROPERTY_HINT_RANGE, "0.0, 1.0"), "set_detiling", "get_detiling");
}
