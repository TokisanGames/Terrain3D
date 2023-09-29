// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#include <godot_cpp/classes/resource_saver.hpp>

#include "logger.h"
#include "terrain_3d_texture_list.h"

///////////////////////////
// Private Functions
///////////////////////////

void Terrain3DTextureList::_swap_textures(int p_old_id, int p_new_id) {
	if (p_old_id < 0 || p_old_id >= _textures.size()) {
		LOG(ERROR, "Old id out of range: ", p_old_id);
		return;
	}
	Ref<Terrain3DTexture> texture_a = _textures[p_old_id];

	p_new_id = CLAMP(p_new_id, 0, _textures.size() - 1);
	if (p_new_id == p_old_id) {
		// Texture_a new id was likely out of range, reset it
		texture_a->get_data()->_texture_id = p_old_id;
		return;
	}

	LOG(DEBUG, "Swapping textures id: ", p_old_id, " and id:", p_new_id);
	Ref<Terrain3DTexture> texture_b = _textures[p_new_id];
	texture_a->get_data()->_texture_id = p_new_id;
	texture_b->get_data()->_texture_id = p_old_id;
	_textures[p_new_id] = texture_a;
	_textures[p_old_id] = texture_b;

	emit_signal("textures_changed");
}

///////////////////////////
// Public Functions
///////////////////////////

Terrain3DTextureList::Terrain3DTextureList() {
}

Terrain3DTextureList::~Terrain3DTextureList() {
}

void Terrain3DTextureList::set_texture(int p_index, const Ref<Terrain3DTexture> &p_texture) {
	LOG(INFO, "Setting texture index: ", p_index);
	if (p_index < 0 || p_index >= MAX_TEXTURES) {
		LOG(ERROR, "Invalid texture index: ", p_index, " range is 0-", MAX_TEXTURES);
		return;
	}
	//Delete texture
	if (p_texture.is_null()) {
		// If final texture, remove it
		if (p_index == get_texture_count() - 1) {
			LOG(DEBUG, "Deleting texture id: ", p_index);
			_textures.pop_back();
		} else if (p_index < get_texture_count()) {
			// Else just clear it
			Ref<Terrain3DTexture> texture = _textures[p_index];
			texture->clear();
			texture->get_data()->_texture_id = p_index;
		}
	} else {
		// Else Insert/Add Texture
		// At end if a high number
		if (p_index >= get_texture_count()) {
			p_texture->get_data()->_texture_id = get_texture_count();
			_textures.push_back(p_texture);
			if (!p_texture->is_connected("id_changed", Callable(this, "_swap_textures"))) {
				LOG(DEBUG, "Connecting to id_changed");
				p_texture->connect("id_changed", Callable(this, "_swap_textures"));
			}
		} else {
			// Else overwrite an existing slot
			_textures[p_index] = p_texture;
		}
	}
	emit_signal("textures_changed");
}

/**
 * set_textures attempts to keep the texture_id as saved in the resource file.
 * But if an ID is invalid or already taken, the new ID is changed to the next available one
 */
void Terrain3DTextureList::set_textures(const TypedArray<Terrain3DTexture> &p_textures) {
	LOG(INFO, "Setting textures");
	int max_size = CLAMP(p_textures.size(), 0, MAX_TEXTURES);
	_textures.resize(max_size);
	int filled_index = -1;
	// For all provided textures up to MAX SIZE
	for (int i = 0; i < max_size; i++) {
		Ref<Terrain3DTexture> texture = p_textures[i];
		int id = texture->get_texture_id();
		// If saved texture id is in range and doesn't exist, add it
		if (id >= 0 && id < max_size && !_textures[id]) {
			_textures[id] = texture;
		} else {
			// Else texture id is invalid or slot is already taken, insert in next available
			for (int j = filled_index + 1; j < max_size; j++) {
				if (!_textures[j]) {
					texture->set_texture_id(j);
					_textures[j] = texture;
					filled_index = j;
					break;
				}
			}
		}
		if (!texture->is_connected("id_changed", Callable(this, "_swap_textures"))) {
			LOG(DEBUG, "Connecting to id_changed");
			texture->connect("id_changed", Callable(this, "_swap_textures"));
		}
	}
	emit_signal("textures_changed");
}

void Terrain3DTextureList::save() {
	String path = get_path();
	LOG(DEBUG, "Attempting to save texture list to: " + path);
	if (path.get_extension() == "tres" || path.get_extension() == "res") {
		Error err;
		err = ResourceSaver::get_singleton()->save(this, path);
		ERR_FAIL_COND(err);
		LOG(DEBUG, "ResourceSaver return error (0 is OK): ", err);
		LOG(INFO, "Finished saving texture list");
	}
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DTextureList::_bind_methods() {
	// Private
	ClassDB::bind_method(D_METHOD("_swap_textures", "old_id", "new_id"), &Terrain3DTextureList::_swap_textures);

	// Public
	ClassDB::bind_method(D_METHOD("set_texture", "index", "texture"), &Terrain3DTextureList::set_texture);
	ClassDB::bind_method(D_METHOD("get_texture", "index"), &Terrain3DTextureList::get_texture);
	ClassDB::bind_method(D_METHOD("set_textures", "textures"), &Terrain3DTextureList::set_textures);
	ClassDB::bind_method(D_METHOD("get_textures"), &Terrain3DTextureList::get_textures);
	ClassDB::bind_method(D_METHOD("get_texture_count"), &Terrain3DTextureList::get_texture_count);

	int ro_flags = PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR | PROPERTY_USAGE_READ_ONLY;
	ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "textures", PROPERTY_HINT_ARRAY_TYPE, vformat("%tex_size/%tex_size:%tex_size", Variant::OBJECT, PROPERTY_HINT_RESOURCE_TYPE, "Terrain3DTextureList"), ro_flags), "set_textures", "get_textures");

	BIND_CONSTANT(MAX_TEXTURES);

	ADD_SIGNAL(MethodInfo("textures_changed"));
}
