// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_MESH_ASSET_CLASS_H
#define TERRAIN3D_MESH_ASSET_CLASS_H

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/packed_scene.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/texture2d.hpp>

#include "constants.h"
#include "terrain_3d_asset_resource.h"

using namespace godot;

class Terrain3DMeshAsset : public Terrain3DAssetResource {
	GDCLASS(Terrain3DMeshAsset, Terrain3DAssetResource);
	CLASS_NAME();
	friend class Terrain3DAssets;

public:
	enum GenType {
		TYPE_NONE,
		TYPE_TEXTURE_CARD,
		TYPE_MAX,
	};

	static constexpr int MAX_LOD_COUNT = 4;
	static constexpr int SHADOW_LOD_ID = -1; // ID used for the shadow lod in instancer

private:
	// Saved data
	real_t _height_offset = 0.f;
	real_t _visibility_margin = 0.f;
	GeometryInstance3D::ShadowCastingSetting _cast_shadows = GeometryInstance3D::SHADOW_CASTING_SETTING_ON;
	GenType _generated_type = TYPE_NONE;
	int _generated_faces = 2;
	Vector2 _generated_size = Vector2(1.f, 1.f);
	Ref<PackedScene> _packed_scene;
	Ref<Material> _material_override;
	real_t _density = 10.f;
	int _last_lod = 0;
	int _first_shadow_lod = 0;
	int _last_shadow_lod = 0;

	PackedFloat32Array _lod_visibility_ranges;

	// Working data
	TypedArray<Mesh> _meshes;
	Ref<Texture2D> _thumbnail;

	int get_valid_lod() const;
	void _validate_lods();

	// No signal versions
	void _set_generated_type(const GenType p_type);
	void _set_material_override(const Ref<Material> &p_material);
	Ref<ArrayMesh> _get_generated_mesh() const;
	Ref<Material> _get_material();

	//DEPRECATED 1.0 - Remove 1.1
	real_t _visibility_range = 100.f;

public:
	Terrain3DMeshAsset();
	~Terrain3DMeshAsset() {}

	void clear() override;

	void set_name(const String &p_name) override;
	String get_name() const override { return _name; }

	void set_id(const int p_new_id) override;
	int get_id() const override { return _id; }

	void set_height_offset(const real_t p_offset);
	real_t get_height_offset() const { return _height_offset; }
	void set_density(const real_t p_density);
	real_t get_density() const { return _density; }

	void set_visibility_range(const real_t p_visibility_range);
	void set_visibility_margin(const real_t p_visibility_margin);
	real_t get_visibility_margin() const { return _visibility_margin; };
	void set_cast_shadows(const GeometryInstance3D::ShadowCastingSetting p_cast_shadows);
	GeometryInstance3D::ShadowCastingSetting get_cast_shadows() const { return _cast_shadows; };

	void set_last_lod(const int p_lod);
	int get_last_lod() const { return _last_lod; }
	void set_first_shadow_lod(const int p_lod);
	int get_first_shadow_lod() const { return _first_shadow_lod; }
	void set_last_shadow_lod(const int p_lod);
	int get_last_shadow_lod() const { return _last_shadow_lod; }
	Ref<Mesh> get_lod_mesh(const int p_lod_id = 0);
	GeometryInstance3D::ShadowCastingSetting get_lod_cast_shadows(const int p_lod_id) const;

	void set_lod_visibility_range(const int p_lod, const real_t p_distance);
	void set_lod_0_range(const real_t p_distance);
	real_t get_lod_0_range() const { return _lod_visibility_ranges[0]; }
	void set_lod_1_range(const real_t p_distance);
	real_t get_lod_1_range() const { return _lod_visibility_ranges[1]; }
	void set_lod_2_range(const real_t p_distance);
	real_t get_lod_2_range() const { return _lod_visibility_ranges[2]; }
	void set_lod_3_range(const real_t p_distance);
	real_t get_lod_3_range() const { return _lod_visibility_ranges[3]; }

	real_t get_lod_visibility_range_begin(const int p_lod_id) const;
	real_t get_lod_visibility_range_end(const int p_lod_id) const;

	void set_scene_file(const Ref<PackedScene> &p_scene_file);
	Ref<PackedScene> get_scene_file() const { return _packed_scene; }

	void set_material_override(const Ref<Material> &p_material);
	Ref<Material> get_material_override() const { return _material_override; }

	void set_generated_type(const GenType p_type);
	GenType get_generated_type() const { return _generated_type; }
	void set_generated_faces(const int p_count);
	int get_generated_faces() const { return _generated_faces; }
	void set_generated_size(const Vector2 &p_size);
	Vector2 get_generated_size() const { return _generated_size; }

	Ref<Mesh> get_mesh(const int p_index = 0);
	int get_mesh_count() const { return _meshes.size(); }
	void set_mesh_count(const int p_count) {} // no-op, used to expose the property in the editor
	Ref<Texture2D> get_thumbnail() const { return _thumbnail; }

	static bool sort_lod_nodes(const Node *a, const Node *b);

protected:
	void _validate_property(PropertyInfo &p_property) const;
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DMeshAsset::GenType);

#endif // TERRAIN3D_MESH_ASSET_CLASS_H