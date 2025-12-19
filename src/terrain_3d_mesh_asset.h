// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_MESH_ASSET_CLASS_H
#define TERRAIN3D_MESH_ASSET_CLASS_H

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/packed_scene.hpp>
#include <godot_cpp/classes/physics_material.hpp>
#include <godot_cpp/classes/resource.hpp>
#include <godot_cpp/classes/shape3d.hpp>
#include <godot_cpp/classes/texture2d.hpp>

#include "constants.h"
#include "terrain_3d_asset_resource.h"

using ShadowCasting = RenderingServer::ShadowCastingSetting;
constexpr ShadowCasting SHADOWS_ON = RenderingServer::SHADOW_CASTING_SETTING_ON;
constexpr ShadowCasting SHADOWS_OFF = RenderingServer::SHADOW_CASTING_SETTING_OFF;
constexpr ShadowCasting SHADOWS_ONLY = RenderingServer::SHADOW_CASTING_SETTING_SHADOWS_ONLY;

/* This class requires a bit of special care because:
 * - We want custom defaults depending on if it's a texture card or a scene file
 * - Any settings saved in the assets resource file need to override the defaults
 * - generated_type = TEXTURE_CARD is the default and isn't saved in the scene file
 *
 * The caveat of this is a texture card MeshAsset needs to determine if it is
 * new, and should apply defaults, or loaded, and should retain settings.
 * The specific defaults of concern are height_offset, density, lod0_range.
 *
 * The current solution to make the distinction is,
 * Loaded Assets go through Terrain3DAssets::set_mesh_list(), _set_asset_list()
 * New Assets go through Terrain3DAssets::set_mesh_asset(), _set_asset()
 * Both call initialize() with a new/loaded flag.
 *
 * New assets might be loaded from the API, AssetDock, or Terrain3DAssets::update_mesh_list()
 * when the mesh list is empty.
 */

class Terrain3DMeshAsset : public Terrain3DAssetResource {
	GDCLASS(Terrain3DMeshAsset, Terrain3DAssetResource);
	CLASS_NAME();

public:
	enum GenType {
		TYPE_NONE,
		TYPE_TEXTURE_CARD,
		TYPE_MAX,
	};

	static constexpr int MAX_LOD_COUNT = 10;
	static constexpr int SHADOW_LOD_ID = -1; // ID used for the shadow lod in instancer

private:
	// Saved data
	bool _enabled = true;
	Ref<PackedScene> _packed_scene;
	GenType _generated_type = TYPE_NONE;
	int _generated_faces = 2;
	Vector2 _generated_size = V2(1.f);
	real_t _height_offset = 0.f;
	real_t _density = 0.f;
	ShadowCasting _cast_shadows = SHADOWS_ON;
	uint32_t _visibility_layers = 1;
	Ref<Material> _material_override;
	Ref<Material> _material_overlay;
	int _last_lod = MAX_LOD_COUNT - 1;
	int _last_shadow_lod = MAX_LOD_COUNT - 1;
	int _shadow_impostor = 0;
	PackedFloat32Array _lod_ranges;
	real_t _fade_margin = 0.f;

	// Instance collision settings
	bool _instance_collision_enabled = true;
	uint32_t _instance_collision_layers = 1;
	uint32_t _instance_collision_mask = 1;
	Ref<PhysicsMaterial> _instance_physics_material;

	// Working data
	Ref<Material> _highlight_mat;
	TypedArray<Mesh> _meshes;
	TypedArray<Mesh> _pending_meshes; // Queue to avoid warnings from RS on mesh swap
	TypedArray<Shape3D> _shapes;
	TypedArray<Transform3D> _shape_transforms;
	Ref<Texture2D> _thumbnail;
	uint32_t _instance_count = 0;

	void _clear_lod_ranges();
	static bool _sort_lod_nodes(const Node *a, const Node *b);
	Ref<ArrayMesh> _create_generated_mesh(const GenType p_type = TYPE_TEXTURE_CARD) const;
	void _assign_generated_mesh();
	Ref<Material> _get_material();
	TypedArray<Mesh> _get_meshes() const;

public:
	Terrain3DMeshAsset() { clear(); }
	~Terrain3DMeshAsset() {}
	void initialize() override;
	void clear() override;

	void set_name(const String &p_name) override;
	String get_name() const override { return _name; }
	void set_id(const int p_new_id) override;
	int get_id() const override { return _id; }
	void set_highlighted(const bool p_highlighted) override;
	bool is_highlighted() const override { return _highlighted; }
	Ref<Material> get_highlight_material() const { return _highlighted ? _highlight_mat : Ref<Material>(); }
	Color get_highlight_color() const override;
	void set_thumbnail(Ref<Texture2D> p_tex) { _thumbnail = p_tex; }
	Ref<Texture2D> get_thumbnail() const override { return _thumbnail; }
	void set_enabled(const bool p_enabled);
	bool is_enabled() const { return _enabled; }

	void update_instance_count(const int p_amount);
	void set_instance_count(const uint32_t p_amount);
	uint32_t get_instance_count() const { return _instance_count; }

	void set_scene_file(const Ref<PackedScene> &p_scene_file);
	Ref<PackedScene> get_scene_file() const { return _packed_scene; }
	bool is_scene_file_pending() const { return _pending_meshes.size() > 0; }
	void commit_meshes();
	void set_generated_type(const GenType p_type);
	GenType get_generated_type() const { return _generated_type; }
	Ref<Mesh> get_mesh(const int p_lod = 0) const;
	TypedArray<Shape3D> get_shapes() const;
	int get_shape_count() const;
	TypedArray<Transform3D> get_shape_transforms() const;
	void set_height_offset(const real_t p_offset);
	real_t get_height_offset() const { return _height_offset; }
	void set_density(const real_t p_density);
	real_t get_density() const { return _density; }
	void set_cast_shadows(const ShadowCasting p_cast_shadows);
	ShadowCasting get_cast_shadows() const { return _cast_shadows; };
	ShadowCasting get_lod_cast_shadows(const int p_lod_id) const;
	void set_visibility_layers(const uint32_t p_layers);
	uint32_t get_visibility_layers() const { return _visibility_layers; }
	void set_material_override(const Ref<Material> &p_material);
	Ref<Material> get_material_override() const { return _material_override; }
	void set_material_overlay(const Ref<Material> &p_material);
	Ref<Material> get_material_overlay() const { return _material_overlay; }

	// Instance collision settings
	void set_instance_collision_enabled(const bool p_enabled);
	bool is_instance_collision_enabled() const { return _instance_collision_enabled; }
	void set_instance_collision_layers(const uint32_t p_layers);
	uint32_t get_instance_collision_layers() const { return _instance_collision_layers; }
	void set_instance_collision_mask(const uint32_t p_mask);
	uint32_t get_instance_collision_mask() const { return _instance_collision_mask; }
	void set_instance_physics_material(const Ref<PhysicsMaterial> &p_mat);
	Ref<PhysicsMaterial> get_instance_physics_material() const { return _instance_physics_material; }

	void set_generated_faces(const int p_count);
	int get_generated_faces() const { return _generated_faces; }
	void set_generated_size(const Vector2 &p_size);
	Vector2 get_generated_size() const { return _generated_size; }

	int get_lod_count() const { return _get_meshes().size(); }
	void set_last_lod(const int p_lod);
	int get_last_lod() const { return _last_lod; }
	void set_last_shadow_lod(const int p_lod);
	int get_last_shadow_lod() const { return _last_shadow_lod; }
	void set_shadow_impostor(const int p_lod);
	int get_shadow_impostor() const { return _shadow_impostor; }

	void set_lod_range(const int p_lod, const real_t p_distance);
	real_t get_lod_range(const int p_lod) const;
	real_t get_lod_range_begin(const int p_lod) const;
	real_t get_lod_range_end(const int p_lod) const;
	void set_lod0_range(const real_t p_distance) { set_lod_range(0, p_distance); }
	real_t get_lod0_range() const { return _lod_ranges[0]; }
	void set_lod1_range(const real_t p_distance) { set_lod_range(1, p_distance); }
	real_t get_lod1_range() const { return _lod_ranges[1]; }
	void set_lod2_range(const real_t p_distance) { set_lod_range(2, p_distance); }
	real_t get_lod2_range() const { return _lod_ranges[2]; }
	void set_lod3_range(const real_t p_distance) { set_lod_range(3, p_distance); }
	real_t get_lod3_range() const { return _lod_ranges[3]; }
	void set_lod4_range(const real_t p_distance) { set_lod_range(4, p_distance); }
	real_t get_lod4_range() const { return _lod_ranges[4]; }
	void set_lod5_range(const real_t p_distance) { set_lod_range(5, p_distance); }
	real_t get_lod5_range() const { return _lod_ranges[5]; }
	void set_lod6_range(const real_t p_distance) { set_lod_range(6, p_distance); }
	real_t get_lod6_range() const { return _lod_ranges[6]; }
	void set_lod7_range(const real_t p_distance) { set_lod_range(7, p_distance); }
	real_t get_lod7_range() const { return _lod_ranges[7]; }
	void set_lod8_range(const real_t p_distance) { set_lod_range(8, p_distance); }
	real_t get_lod8_range() const { return _lod_ranges[8]; }
	void set_lod9_range(const real_t p_distance) { set_lod_range(9, p_distance); }
	real_t get_lod9_range() const { return _lod_ranges[9]; }
	void set_fade_margin(const real_t p_fade_margin);
	real_t get_fade_margin() const { return _fade_margin; };

protected:
	void _validate_property(PropertyInfo &p_property) const;
	bool _property_can_revert(const StringName &p_name) const;
	bool _property_get_revert(const StringName &p_name, Variant &r_property) const;
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DMeshAsset::GenType);

inline TypedArray<Mesh> Terrain3DMeshAsset::_get_meshes() const {
	if (!_pending_meshes.is_empty()) {
		return _pending_meshes;
	}
	return _meshes;
}

#endif // TERRAIN3D_MESH_ASSET_CLASS_H
