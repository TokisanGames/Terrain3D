// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

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
void Terrain3DMeshAsset::_set_generated_type(const GenType p_type) {
	_generated_type = p_type;
	LOG(INFO, "Setting is_generated: ", p_type);
	if (p_type > TYPE_NONE && p_type < TYPE_MAX) {
		_packed_scene.unref();
		_meshes.clear();
		LOG(DEBUG, "Generating card mesh");
		_meshes.push_back(_get_generated_mesh());
		_set_material_override(_get_material());
	}
}

// This version doesn't emit a signal
void Terrain3DMeshAsset::_set_material_override(const Ref<Material> &p_material) {
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

Ref<ArrayMesh> Terrain3DMeshAsset::_get_generated_mesh() const {
	LOG(EXTREME, "Regeneratingn new mesh");
	Ref<ArrayMesh> array_mesh;
	array_mesh.instantiate();
	PackedVector3Array vertices;
	PackedVector3Array normals;
	PackedFloat32Array tangents;
	PackedVector2Array uvs;
	PackedInt32Array indices;

	int i, j, prevrow, thisrow, point = 0;
	float x, z;
	Size2 start_pos = Vector2(_generated_size.x * -0.5, -0.5f);
	Vector3 normal = Vector3(0.0, 0.0, 1.0);

#define ADD_TANGENT(m_x, m_y, m_z, m_d) \
	tangents.push_back(m_x);            \
	tangents.push_back(m_y);            \
	tangents.push_back(m_z);            \
	tangents.push_back(m_d);

	thisrow = point;
	prevrow = 0;
	Vector3 Up = Vector3(0.f, 1.f, 0.f);
	for (int m = 1; m <= _generated_faces; m++) {
		z = start_pos.y;
		real_t angle = 0.f;
		if (m > 1) {
			angle = (m - 1) * Math_PI / _generated_faces;
		}
		for (int j = 0; j <= 1; j++) {
			x = start_pos.x;
			for (int i = 0; i <= 1; i++) {
				float u = i;
				float v = j;

				vertices.push_back(Vector3(-x, z, 0.0).rotated(Up, angle));
				normals.push_back(normal);
				ADD_TANGENT(1.0, 0.0, 0.0, 1.0);
				uvs.push_back(Vector2(1.0 - u, 1.0 - v));
				point++;
				if (i > 0 && j > 0) {
					indices.push_back(prevrow + i - 1);
					indices.push_back(prevrow + i);
					indices.push_back(thisrow + i - 1);
					indices.push_back(prevrow + i);
					indices.push_back(thisrow + i);
					indices.push_back(thisrow + i - 1);
				}
				x += _generated_size.x;
			}
			z += _generated_size.y;
			prevrow = thisrow;
			thisrow = point;
		}
	}

	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = vertices;
	arrays[Mesh::ARRAY_NORMAL] = normals;
	arrays[Mesh::ARRAY_TANGENT] = tangents;
	arrays[Mesh::ARRAY_TEX_UV] = uvs;
	arrays[Mesh::ARRAY_INDEX] = indices;
	array_mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
	return array_mesh;
}

Ref<Material> Terrain3DMeshAsset::_get_material() {
	if (_material_override.is_null()) {
		Ref<StandardMaterial3D> mat;
		mat.instantiate();
		mat->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA_DEPTH_PRE_PASS);
		mat->set_cull_mode(BaseMaterial3D::CULL_DISABLED);
		mat->set_feature(BaseMaterial3D::FEATURE_BACKLIGHT, true);
		mat->set_backlight(Color(.5f, .5f, .5f));
		mat->set_flag(BaseMaterial3D::FLAG_ALBEDO_FROM_VERTEX_COLOR, true);
		mat->set_distance_fade(BaseMaterial3D::DISTANCE_FADE_PIXEL_ALPHA);
		mat->set_distance_fade_min_distance(85.f);
		mat->set_distance_fade_max_distance(75.f);
		return mat;
	} else {
		return _material_override;
	}
}

///////////////////////////
// Public Functions
///////////////////////////

Terrain3DMeshAsset::Terrain3DMeshAsset() {
	_name = "New Mesh";
	_id = 0;

	_lod_visibility_ranges.resize(MAX_LOD_COUNT);
	_lod_visibility_ranges.fill(0.f);
}

void Terrain3DMeshAsset::clear() {
	_name = "New Mesh";
	_id = 0;
	_height_offset = 0.f;
	_visibility_range = 100.f;
	_visibility_margin = 0.f;
	_cast_shadows = GeometryInstance3D::SHADOW_CASTING_SETTING_ON;
	_last_lod = 0;
	_last_shadow_lod = 0;
	_first_shadow_lod = 0;

	_lod_visibility_ranges.resize(MAX_LOD_COUNT);
	_lod_visibility_ranges.fill(0.f);

	_generated_faces = 2.f;
	_generated_size = Vector2(1.f, 1.f);
	_density = 10.f;
	_packed_scene.unref();
	_material_override.unref();
	_set_generated_type(TYPE_TEXTURE_CARD);
	notify_property_list_changed();
}

void Terrain3DMeshAsset::set_name(const String &p_name) {
	LOG(INFO, "Setting name: ", p_name);
	_name = p_name;
	emit_signal("setting_changed");
}

void Terrain3DMeshAsset::set_id(const int p_new_id) {
	int old_id = _id;
	_id = CLAMP(p_new_id, 0, Terrain3DAssets::MAX_MESHES);
	LOG(INFO, "Setting mesh id: ", _id);
	emit_signal("id_changed", Terrain3DAssets::TYPE_MESH, old_id, p_new_id);
}

void Terrain3DMeshAsset::set_height_offset(const real_t p_offset) {
	_height_offset = CLAMP(p_offset, -50.f, 50.f);
	LOG(INFO, "Setting height offset: ", _height_offset);
	emit_signal("setting_changed");
}

void Terrain3DMeshAsset::set_density(const real_t p_density) {
	LOG(INFO, "Setting mesh density: ", p_density);
	_density = CLAMP(p_density, 0.01f, 10.f);
}

void Terrain3DMeshAsset::set_visibility_margin(const real_t p_visibility_margin) {
	_visibility_margin = CLAMP(p_visibility_margin, 0.f, 100000.f);
	LOG(INFO, "Setting visbility margin: ", _visibility_margin);
	emit_signal("instancer_setting_changed");
}

void Terrain3DMeshAsset::set_cast_shadows(const GeometryInstance3D::ShadowCastingSetting p_cast_shadows) {
	_cast_shadows = p_cast_shadows;
	LOG(INFO, "Setting shadow casting mode: ", _cast_shadows);
	emit_signal("instancer_setting_changed");
}

int Terrain3DMeshAsset::get_valid_lod() const {
	// Generated meshes only have one LOD
	if (_generated_type != TYPE_NONE) {
		return 1;
	}

	// As long as the packed scene was not loaded, we don't enforce the LOD ids
	if (_packed_scene.is_null()) {
		return MAX_LOD_COUNT - 1;
	}

	return CLAMP(get_mesh_count() - 1, 0, MAX_LOD_COUNT - 1);
}

void Terrain3DMeshAsset::_validate_lods() {
	// Make sure the lods are consistent with the mesh count
	set_last_lod(_last_lod);
	set_last_shadow_lod(_last_shadow_lod);
	set_first_shadow_lod(_first_shadow_lod);
}

void Terrain3DMeshAsset::set_last_lod(const int p_lod) {
	_last_lod = CLAMP(p_lod, 0, get_valid_lod());
	LOG(INFO, "Setting maximum LOD: ", _last_lod);
	emit_signal("instancer_setting_changed");
}

void Terrain3DMeshAsset::set_last_shadow_lod(const int p_lod) {
	_last_shadow_lod = CLAMP(p_lod, 0, get_last_lod());
	LOG(INFO, "Setting maximum shadow LOD: ", _last_shadow_lod);
	emit_signal("instancer_setting_changed");
}

void Terrain3DMeshAsset::set_first_shadow_lod(const int p_lod) {
	_first_shadow_lod = CLAMP(p_lod, 0, get_last_lod());
	LOG(INFO, "Setting minimum shadow LOD: ", _first_shadow_lod);
	emit_signal("instancer_setting_changed");
}

void Terrain3DMeshAsset::set_lod_visibility_range(const int p_lod, const real_t p_distance) {
	// TODO: validate distances make sense with each other?
	_lod_visibility_ranges[p_lod] = CLAMP(p_distance, 0.f, 100000.f);
	LOG(INFO, "Setting LOD ", p_lod, " visibility range: ", _lod_visibility_ranges[p_lod]);
	emit_signal("instancer_setting_changed");
}

void Terrain3DMeshAsset::set_lod_0_range(const real_t p_distance) {
	set_lod_visibility_range(0, p_distance);
}

void Terrain3DMeshAsset::set_lod_1_range(const real_t p_distance) {
	set_lod_visibility_range(1, p_distance);
}

void Terrain3DMeshAsset::set_lod_2_range(const real_t p_distance) {
	set_lod_visibility_range(2, p_distance);
}

void Terrain3DMeshAsset::set_lod_3_range(const real_t p_distance) {
	set_lod_visibility_range(3, p_distance);
}

real_t Terrain3DMeshAsset::get_lod_visibility_range_begin(const int p_lod_id) const {
	if (p_lod_id == 0 || p_lod_id == SHADOW_LOD_ID) {
		return 0.f;
	}

	ASSERT(p_lod_id > 0 && p_lod_id <= _last_lod, -1.f); // Invalid LOD

	return _lod_visibility_ranges[p_lod_id - 1];
}

real_t Terrain3DMeshAsset::get_lod_visibility_range_end(const int p_lod_id) const {
	if (p_lod_id == SHADOW_LOD_ID) {
		return _lod_visibility_ranges[_first_shadow_lod];
	}

	ASSERT(p_lod_id >= 0 && p_lod_id <= _last_lod, -1.f); // Invalid LOD

	return _lod_visibility_ranges[p_lod_id];
}

void Terrain3DMeshAsset::set_scene_file(const Ref<PackedScene> &p_scene_file) {
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
		_meshes.clear();

		// Look for MeshInstance3D nodes
		TypedArray<Node> mesh_instances;
		bool meshes_found = false;

		// First look for XXXXLOD# meshes
		mesh_instances = node->find_children("*LOD?", "MeshInstance3D");
		if (mesh_instances.size() > 0) {
			LOG(INFO, "Found ", mesh_instances.size(), " meshes using LOD# naming convention, using the first ", MAX_LOD_COUNT);
			meshes_found = true;
			mesh_instances.sort_custom(callable_mp_static(&Terrain3DMeshAsset::sort_lod_nodes));
		}

		// Fallback to all the meshes
		if (!meshes_found) {
			mesh_instances = node->find_children("*", "MeshInstance3D");

			if (mesh_instances.size() > 0) {
				LOG(INFO, "No LOD# meshes found, assuming the first ", MAX_LOD_COUNT, " are LOD0-LOD3");
				meshes_found = true;
				mesh_instances.sort();
			}
		}

		// Fallback to the root mesh
		if (!meshes_found) {
			if (node->is_class("MeshInstance3D")) {
				LOG(INFO, "No LOD# meshes found, assuming the root mesh is LOD0");
				mesh_instances.push_back(node);
				meshes_found = true;
			}
		}

		// Give up finding meshes
		if (!meshes_found) {
			LOG(ERROR, "No MeshInstance3D found in scene file");
		}

		// Now process the meshes
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

			if (_meshes.size() == MAX_LOD_COUNT) {
				break;
			}
		}
		if (_meshes.size() > 0) {
			Ref<Mesh> mesh = _meshes[0];
			_density = CLAMP(10.f / mesh->get_aabb().get_volume(), 0.01f, 10.0f);
		} else {
			LOG(ERROR, "No MeshInstance3D found in scene file");
		}
		notify_property_list_changed();
	} else {
		set_generated_type(TYPE_TEXTURE_CARD);
		_density = 10.f;
	}

	// Make sure LODs are still valid
	_validate_lods();

	LOG(DEBUG, "Emitting file_changed");
	emit_signal("file_changed");
	emit_signal("instancer_setting_changed");
}

bool Terrain3DMeshAsset::sort_lod_nodes(const Node *a, const Node *b) {
	return a->get_name().right(1) < b->get_name().right(1);
}

void Terrain3DMeshAsset::set_material_override(const Ref<Material> &p_material) {
	_set_material_override(p_material);
	LOG(DEBUG, "Emitting setting_changed");
	emit_signal("setting_changed");
	emit_signal("instancer_setting_changed");
}

void Terrain3DMeshAsset::set_generated_type(const GenType p_type) {
	_set_generated_type(p_type);
	LOG(DEBUG, "Emitting file_changed");
	notify_property_list_changed();
	emit_signal("file_changed");
	emit_signal("instancer_setting_changed");
}

void Terrain3DMeshAsset::set_generated_faces(const int p_count) {
	if (_generated_faces != p_count) {
		_generated_faces = CLAMP(p_count, 1, 3);
		LOG(INFO, "Setting generated face count: ", _generated_faces);
		if (_generated_type > TYPE_NONE && _generated_type < TYPE_MAX && _meshes.size() == 1) {
			_meshes[0] = _get_generated_mesh();
			_set_material_override(_get_material());
			LOG(DEBUG, "Emitting setting_changed");
			emit_signal("setting_changed");
			emit_signal("instancer_setting_changed");
		}
	}
}

void Terrain3DMeshAsset::set_generated_size(const Vector2 &p_size) {
	if (_generated_size != p_size) {
		_generated_size = p_size;
		LOG(INFO, "Setting generated size: ", _generated_faces);
		if (_generated_type > TYPE_NONE && _generated_type < TYPE_MAX && _meshes.size() == 1) {
			_meshes[0] = _get_generated_mesh();
			_set_material_override(_get_material());
			LOG(DEBUG, "Emitting setting_changed");
			emit_signal("setting_changed");
			emit_signal("instancer_setting_changed");
		}
	}
}

GeometryInstance3D::ShadowCastingSetting Terrain3DMeshAsset::get_lod_cast_shadows(const int p_lod_id) const {
	// Shadow casting is disabled
	if (_cast_shadows == GeometryInstance3D::SHADOW_CASTING_SETTING_OFF) {
		return GeometryInstance3D::SHADOW_CASTING_SETTING_OFF;
	}
	// We never cast shadows
	if (_cast_shadows == GeometryInstance3D::SHADOW_CASTING_SETTING_SHADOWS_ONLY) {
		return GeometryInstance3D::SHADOW_CASTING_SETTING_SHADOWS_ONLY;
	}
	// This lod id is for the shadow impostor and is set to cast shadows only
	if (p_lod_id == SHADOW_LOD_ID) {
		return GeometryInstance3D::SHADOW_CASTING_SETTING_SHADOWS_ONLY;
	}
	// This lod relies on the shadow impostor
	if (p_lod_id < _first_shadow_lod) {
		return GeometryInstance3D::SHADOW_CASTING_SETTING_OFF;
	}
	// This lod is too far to cast a shadow
	if (p_lod_id > _last_shadow_lod) {
		return GeometryInstance3D::SHADOW_CASTING_SETTING_OFF;
	}
	return _cast_shadows;
}

Ref<Mesh> Terrain3DMeshAsset::get_lod_mesh(const int p_lod_id) {
	if (p_lod_id == SHADOW_LOD_ID) {
		// Each lod uses its own shadow
		if (_first_shadow_lod == 0) {
			return Ref<Mesh>();
		}
		// We completely disabled shadows
		if (_cast_shadows == GeometryInstance3D::SHADOW_CASTING_SETTING_OFF) {
			return Ref<Mesh>();
		}

		return get_mesh(_first_shadow_lod);
	}

	// This lod is too far to get a mesh
	if (p_lod_id > _last_lod) {
		return Ref<Mesh>();
	}

	// In the case where we're rendering shadows only,
	// This lod is also too far to get a mesh
	if (_cast_shadows == GeometryInstance3D::SHADOW_CASTING_SETTING_SHADOWS_ONLY && p_lod_id >= _last_shadow_lod) {
		return Ref<Mesh>();
	}

	return get_mesh(p_lod_id);
}

Ref<Mesh> Terrain3DMeshAsset::get_mesh(const int p_index) {
	if (p_index >= 0 && p_index < _meshes.size()) {
		return _meshes[p_index];
	}
	return Ref<Mesh>();
}

///////////////////////////
// Protected Functions
///////////////////////////

void Terrain3DMeshAsset::_validate_property(PropertyInfo &p_property) const {
	if (p_property.name != StringName("generated_type") &&
			p_property.name.begins_with("generated_")) {
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
	ADD_SIGNAL(MethodInfo("instancer_setting_changed"));

	ClassDB::bind_method(D_METHOD("clear"), &Terrain3DMeshAsset::clear);
	ClassDB::bind_method(D_METHOD("set_name", "name"), &Terrain3DMeshAsset::set_name);
	ClassDB::bind_method(D_METHOD("get_name"), &Terrain3DMeshAsset::get_name);
	ClassDB::bind_method(D_METHOD("set_id", "id"), &Terrain3DMeshAsset::set_id);
	ClassDB::bind_method(D_METHOD("get_id"), &Terrain3DMeshAsset::get_id);
	ClassDB::bind_method(D_METHOD("set_height_offset", "offset"), &Terrain3DMeshAsset::set_height_offset);
	ClassDB::bind_method(D_METHOD("get_height_offset"), &Terrain3DMeshAsset::get_height_offset);
	ClassDB::bind_method(D_METHOD("set_density", "density"), &Terrain3DMeshAsset::set_density);
	ClassDB::bind_method(D_METHOD("get_density"), &Terrain3DMeshAsset::get_density);
	ClassDB::bind_method(D_METHOD("set_visibility_margin", "distance"), &Terrain3DMeshAsset::set_visibility_margin);
	ClassDB::bind_method(D_METHOD("get_visibility_margin"), &Terrain3DMeshAsset::get_visibility_margin);
	ClassDB::bind_method(D_METHOD("set_cast_shadows", "mode"), &Terrain3DMeshAsset::set_cast_shadows);
	ClassDB::bind_method(D_METHOD("get_cast_shadows"), &Terrain3DMeshAsset::get_cast_shadows);
	ClassDB::bind_method(D_METHOD("set_last_lod", "lod"), &Terrain3DMeshAsset::set_last_lod);
	ClassDB::bind_method(D_METHOD("get_last_lod"), &Terrain3DMeshAsset::get_last_lod);
	ClassDB::bind_method(D_METHOD("set_last_shadow_lod", "lod"), &Terrain3DMeshAsset::set_last_shadow_lod);
	ClassDB::bind_method(D_METHOD("get_last_shadow_lod"), &Terrain3DMeshAsset::get_last_shadow_lod);
	ClassDB::bind_method(D_METHOD("set_first_shadow_lod", "lod"), &Terrain3DMeshAsset::set_first_shadow_lod);
	ClassDB::bind_method(D_METHOD("get_first_shadow_lod"), &Terrain3DMeshAsset::get_first_shadow_lod);
	ClassDB::bind_method(D_METHOD("set_lod_0_range", "distance"), &Terrain3DMeshAsset::set_lod_0_range);
	ClassDB::bind_method(D_METHOD("get_lod_0_range"), &Terrain3DMeshAsset::get_lod_0_range);
	ClassDB::bind_method(D_METHOD("set_lod_1_range", "distance"), &Terrain3DMeshAsset::set_lod_1_range);
	ClassDB::bind_method(D_METHOD("get_lod_1_range"), &Terrain3DMeshAsset::get_lod_1_range);
	ClassDB::bind_method(D_METHOD("set_lod_2_range", "distance"), &Terrain3DMeshAsset::set_lod_2_range);
	ClassDB::bind_method(D_METHOD("get_lod_2_range"), &Terrain3DMeshAsset::get_lod_2_range);
	ClassDB::bind_method(D_METHOD("set_lod_3_range", "distance"), &Terrain3DMeshAsset::set_lod_3_range);
	ClassDB::bind_method(D_METHOD("get_lod_3_range"), &Terrain3DMeshAsset::get_lod_3_range);
	ClassDB::bind_method(D_METHOD("set_scene_file", "scene_file"), &Terrain3DMeshAsset::set_scene_file);
	ClassDB::bind_method(D_METHOD("get_scene_file"), &Terrain3DMeshAsset::get_scene_file);
	ClassDB::bind_method(D_METHOD("set_material_override", "material"), &Terrain3DMeshAsset::set_material_override);
	ClassDB::bind_method(D_METHOD("get_material_override"), &Terrain3DMeshAsset::get_material_override);
	ClassDB::bind_method(D_METHOD("set_generated_type", "type"), &Terrain3DMeshAsset::set_generated_type);
	ClassDB::bind_method(D_METHOD("get_generated_type"), &Terrain3DMeshAsset::get_generated_type);
	ClassDB::bind_method(D_METHOD("set_generated_faces", "count"), &Terrain3DMeshAsset::set_generated_faces);
	ClassDB::bind_method(D_METHOD("get_generated_faces"), &Terrain3DMeshAsset::get_generated_faces);
	ClassDB::bind_method(D_METHOD("set_generated_size", "size"), &Terrain3DMeshAsset::set_generated_size);
	ClassDB::bind_method(D_METHOD("get_generated_size"), &Terrain3DMeshAsset::get_generated_size);
	ClassDB::bind_method(D_METHOD("get_mesh", "index"), &Terrain3DMeshAsset::get_mesh, DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_mesh_count"), &Terrain3DMeshAsset::get_mesh_count);
	ClassDB::bind_method(D_METHOD("set_mesh_count", "count"), &Terrain3DMeshAsset::set_mesh_count);
	ClassDB::bind_method(D_METHOD("get_thumbnail"), &Terrain3DMeshAsset::get_thumbnail);

	ADD_PROPERTY(PropertyInfo(Variant::STRING, "name", PROPERTY_HINT_NONE), "set_name", "get_name");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "id", PROPERTY_HINT_NONE), "set_id", "get_id");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "height_offset", PROPERTY_HINT_RANGE, "-20.0,20.0,.005"), "set_height_offset", "get_height_offset");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "density", PROPERTY_HINT_RANGE, ".01,10.0,.005"), "set_density", "get_density");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "mesh_count", PROPERTY_HINT_NONE), "", "get_mesh_count");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "scene_file", PROPERTY_HINT_RESOURCE_TYPE, "PackedScene"), "set_scene_file", "get_scene_file");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "material_override", PROPERTY_HINT_RESOURCE_TYPE, "BaseMaterial3D,ShaderMaterial"), "set_material_override", "get_material_override");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "generated_type", PROPERTY_HINT_ENUM, "None,Texture Card"), "set_generated_type", "get_generated_type");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "cast_shadows", PROPERTY_HINT_ENUM, "Off,On,Double-Sided,Shadows Only"), "set_cast_shadows", "get_cast_shadows");

	ADD_GROUP("Mesh Generation", "");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "generated_faces", PROPERTY_HINT_NONE), "set_generated_faces", "get_generated_faces");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "generated_size", PROPERTY_HINT_NONE), "set_generated_size", "get_generated_size");

	ADD_GROUP("LODs", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "visibility_margin", PROPERTY_HINT_RANGE, "0.,4096.0,.05,or_greater"), "set_visibility_margin", "get_visibility_margin");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "last_lod", PROPERTY_HINT_NONE), "set_last_lod", "get_last_lod");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "first_shadow_lod", PROPERTY_HINT_NONE), "set_first_shadow_lod", "get_first_shadow_lod");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "last_shadow_lod", PROPERTY_HINT_NONE), "set_last_shadow_lod", "get_last_shadow_lod");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lod_0_range", PROPERTY_HINT_RANGE, "0.,4096.0,.05,or_greater"), "set_lod_0_range", "get_lod_0_range");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lod_1_range", PROPERTY_HINT_RANGE, "0.,4096.0,.05,or_greater"), "set_lod_1_range", "get_lod_1_range");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lod_2_range", PROPERTY_HINT_RANGE, "0.,4096.0,.05,or_greater"), "set_lod_2_range", "get_lod_2_range");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "lod_3_range", PROPERTY_HINT_RANGE, "0.,4096.0,.05,or_greater"), "set_lod_3_range", "get_lod_3_range");

	//DEPRECATED 1.0 - Remove 1.1
	ClassDB::bind_method(D_METHOD("set_visibility_range", "distance"), &Terrain3DMeshAsset::set_visibility_range);
	ClassDB::bind_method(D_METHOD("get_visibility_range"), &Terrain3DMeshAsset::get_lod_0_range);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "visibility_range", PROPERTY_HINT_RANGE, "0.,4096.0,.05,or_greater", PROPERTY_USAGE_NO_EDITOR), "set_visibility_range", "get_visibility_range");
}

//DEPRECATED 1.0 - Remove 1.1
void Terrain3DMeshAsset::set_visibility_range(const real_t p_visibility_range) {
	set_lod_0_range(p_visibility_range);
}
