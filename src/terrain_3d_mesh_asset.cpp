// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/classes/editor_paths.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/classes/quad_mesh.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>

#include "logger.h"
#include "terrain_3d_mesh_asset.h"

///////////////////////////
// Private Functions
///////////////////////////

// This version doesn't emit a signal
void Terrain3DMeshAsset::_set_generated_type(GenType p_type) {
	_generated_type = p_type;
	LOG(INFO, "Setting is_generated: ", p_type);
	if (p_type > TYPE_NONE && p_type < TYPE_MAX) {
		_packed_scene.unref();
		_meshes.clear();

		LOG(DEBUG, "Generating card mesh");
		Ref<QuadMesh> mesh;
		mesh.instantiate();
		mesh->set_size(_generated_size);
		_meshes.push_back(mesh);
		_height_offset = 0.5f;
		_relative_density = 1.f;
		if (_material_override.is_null()) {
			Ref<StandardMaterial3D> mat;
			mat.instantiate();
			mat->set_cull_mode(BaseMaterial3D::CULL_DISABLED);
			mat->set_feature(BaseMaterial3D::FEATURE_BACKLIGHT, true);
			mat->set_backlight(Color(.5f, .5f, .5f));
			mat->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
			/*mat->set_distance_fade(BaseMaterial3D::DISTANCE_FADE_PIXEL_DITHER);
			mat->set_distance_fade_max_distance(20.f);
			mat->set_distance_fade_min_distance(30.f);*/
			_set_material_override(mat);
		} else {
			_set_material_override(_material_override);
		}
	}
}

// This version doesn't emit a signal
void Terrain3DMeshAsset::_set_material_override(const Ref<Material> p_material) {
	LOG(INFO, _name, ": Setting material override: ", p_material);
	_material_override = p_material;
	if (_material_override.is_null() && _packed_scene.is_valid()) {
		LOG(DEBUG, "Resetting material from scene file");
		set_scene_file(_packed_scene);
		return;
	}
	if (_material_override.is_valid() && _meshes.size() > 0) {
		Ref<Mesh> mesh = _meshes[0];
		if (mesh.is_null()) {
			return;
		}
		LOG(DEBUG, "Setting material for ", mesh->get_surface_count(), " surfaces");
		for (int i = 0; i < mesh->get_surface_count(); i++) {
			mesh->surface_set_material(i, _material_override);
		}
	}
}

///////////////////////////
// Public Functions
///////////////////////////

Terrain3DMeshAsset::Terrain3DMeshAsset() {
	_name = "New Mesh";
	_id = 0;
}

void Terrain3DMeshAsset::clear() {
	_name = "New Mesh";
	_id = 0;
	_height_offset = 0.0f;
	_relative_density = 1.f;
	_packed_scene.unref();
	_material_override.unref();
	_set_generated_type(TYPE_TEXTURE_CARD);
}

void Terrain3DMeshAsset::set_name(String p_name) {
	LOG(INFO, "Setting name: ", p_name);
	_name = p_name;
	emit_signal("setting_changed");
}

void Terrain3DMeshAsset::set_id(int p_new_id) {
	int old_id = _id;
	_id = CLAMP(p_new_id, 0, Terrain3DAssets::MAX_MESHES);
	LOG(INFO, "Setting mesh id: ", _id);
	emit_signal("id_changed", Terrain3DAssets::TYPE_MESH, old_id, p_new_id);
}

void Terrain3DMeshAsset::set_height_offset(real_t p_offset) {
	_height_offset = CLAMP(p_offset, -50.f, 50.f);
	LOG(INFO, "Setting height offset: ", _height_offset);
	emit_signal("setting_changed");
}

void Terrain3DMeshAsset::set_scene_file(const Ref<PackedScene> p_scene_file) {
	LOG(INFO, "Setting scene file and instantiating node: ", p_scene_file);
	_packed_scene = p_scene_file;
	if (_packed_scene.is_valid()) {
		Node *node = _packed_scene->instantiate();
		if (node == nullptr) {
			LOG(ERROR, "Drag a non-empty glb, fbx, or tscn file into the scene_file slot");
			_packed_scene.unref();
			return;
		}
		if (_generated_type > TYPE_NONE && _generated_type < TYPE_MAX) {
			// Reset for receiving a scene file
			_generated_type = TYPE_NONE;
			_material_override.unref();
			_height_offset = 0.0f;
		}
		LOG(DEBUG, "Loaded scene with parent node: ", node);
		TypedArray<Node> mesh_instances = node->find_children("*", "MeshInstance3D");
		_meshes.clear();
		for (int i = 0; i < mesh_instances.size(); i++) {
			MeshInstance3D *mi = cast_to<MeshInstance3D>(mesh_instances[i]);
			LOG(DEBUG, "Found mesh: ", mi->get_name());
			if (_name == "New Mesh") {
				_name = _packed_scene->get_path().get_file().get_basename();
				LOG(INFO, "Setting name based on filename: ", _name);
			}
			Ref<Mesh> mesh = mi->get_mesh();
			for (int j = 0; j < mi->get_surface_override_material_count(); j++) {
				Ref<Material> mat;
				if (_material_override.is_valid()) {
					mat = _material_override;
				} else {
					mat = mi->get_active_material(j);
				}
				mesh->surface_set_material(j, mat);
			}
			_meshes.push_back(mesh);
		}
		if (_meshes.size() > 0) {
			Ref<Mesh> mesh = _meshes[0];
			_relative_density = 100.f / mesh->get_aabb().get_volume();
			LOG(DEBUG, "Emitting file_changed");
			emit_signal("file_changed");
		} else {
			LOG(ERROR, "No MeshInstance3D found in scene file");
		}
	} else {
		set_generated_type(TYPE_TEXTURE_CARD);
	}
}

void Terrain3DMeshAsset::set_material_override(const Ref<Material> p_material) {
	_set_material_override(p_material);
	LOG(DEBUG, "Emitting setting_changed");
	emit_signal("setting_changed");
}

void Terrain3DMeshAsset::set_generated_type(GenType p_type) {
	_set_generated_type(p_type);
	LOG(DEBUG, "Emitting file_changed");
	notify_property_list_changed();
	emit_signal("file_changed");
}

void Terrain3DMeshAsset::set_generated_size(Vector2 p_size) {
	_generated_size = p_size;
	if (_generated_type > TYPE_NONE && _generated_type < TYPE_MAX && _meshes.size() > 0) {
		Ref<QuadMesh> mesh = _meshes[0];
		if (mesh.is_valid()) {
			mesh->set_size(p_size);
			LOG(DEBUG, "Emitting setting_changed");
			emit_signal("setting_changed");
		}
	}
}

Ref<Mesh> Terrain3DMeshAsset::get_mesh(int p_index) {
	if (p_index >= 0 && p_index < _meshes.size()) {
		return _meshes[p_index];
	}
	return Ref<Mesh>();
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DMeshAsset::_validate_property(PropertyInfo &p_property) const {
	if (p_property.name == StringName("generated_size")) {
		if (_generated_type == TYPE_NONE) {
			p_property.usage = PROPERTY_USAGE_NO_EDITOR;
		} else {
			p_property.usage = PROPERTY_USAGE_DEFAULT;
		}
	}
}

void Terrain3DMeshAsset::_bind_methods() {
	BIND_ENUM_CONSTANT(TYPE_NONE);
	BIND_ENUM_CONSTANT(TYPE_TEXTURE_CARD);
	BIND_ENUM_CONSTANT(TYPE_MAX);

	ADD_SIGNAL(MethodInfo("id_changed"));
	ADD_SIGNAL(MethodInfo("file_changed"));
	ADD_SIGNAL(MethodInfo("setting_changed"));

	ClassDB::bind_method(D_METHOD("clear"), &Terrain3DMeshAsset::clear);
	ClassDB::bind_method(D_METHOD("set_name", "name"), &Terrain3DMeshAsset::set_name);
	ClassDB::bind_method(D_METHOD("get_name"), &Terrain3DMeshAsset::get_name);
	ClassDB::bind_method(D_METHOD("set_id", "id"), &Terrain3DMeshAsset::set_id);
	ClassDB::bind_method(D_METHOD("get_id"), &Terrain3DMeshAsset::get_id);
	ClassDB::bind_method(D_METHOD("set_height_offset", "offset"), &Terrain3DMeshAsset::set_height_offset);
	ClassDB::bind_method(D_METHOD("get_height_offset"), &Terrain3DMeshAsset::get_height_offset);
	ClassDB::bind_method(D_METHOD("set_scene_file", "scene_file"), &Terrain3DMeshAsset::set_scene_file);
	ClassDB::bind_method(D_METHOD("get_scene_file"), &Terrain3DMeshAsset::get_scene_file);
	ClassDB::bind_method(D_METHOD("set_material_override", "material"), &Terrain3DMeshAsset::set_material_override);
	ClassDB::bind_method(D_METHOD("get_material_override"), &Terrain3DMeshAsset::get_material_override);
	ClassDB::bind_method(D_METHOD("set_generated_type", "type"), &Terrain3DMeshAsset::set_generated_type);
	ClassDB::bind_method(D_METHOD("get_generated_type"), &Terrain3DMeshAsset::get_generated_type);
	ClassDB::bind_method(D_METHOD("set_generated_size", "size"), &Terrain3DMeshAsset::set_generated_size);
	ClassDB::bind_method(D_METHOD("get_generated_size"), &Terrain3DMeshAsset::get_generated_size);
	ClassDB::bind_method(D_METHOD("get_mesh", "index"), &Terrain3DMeshAsset::get_mesh, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_mesh_count"), &Terrain3DMeshAsset::get_mesh_count);
	ClassDB::bind_method(D_METHOD("get_relative_density"), &Terrain3DMeshAsset::get_relative_density);
	ClassDB::bind_method(D_METHOD("get_thumbnail"), &Terrain3DMeshAsset::get_thumbnail);

	ADD_PROPERTY(PropertyInfo(Variant::STRING, "name", PROPERTY_HINT_NONE), "set_name", "get_name");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "id", PROPERTY_HINT_NONE), "set_id", "get_id");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "height_offset", PROPERTY_HINT_RANGE, "-20.0,20.0,.005"), "set_height_offset", "get_height_offset");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "scene_file", PROPERTY_HINT_RESOURCE_TYPE, "PackedScene"), "set_scene_file", "get_scene_file");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "material_override", PROPERTY_HINT_RESOURCE_TYPE, "BaseMaterial3D,ShaderMaterial"), "set_material_override", "get_material_override");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "generated_type", PROPERTY_HINT_ENUM, "None,Texture Card"), "set_generated_type", "get_generated_type");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "generated_size", PROPERTY_HINT_NONE), "set_generated_size", "get_generated_size");
}
