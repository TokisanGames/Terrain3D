// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_ASSETS_CLASS_H
#define TERRAIN3D_ASSETS_CLASS_H

#include "constants.h"
#include "generated_texture.h"
#include "terrain_3d_mesh_asset.h"
#include "terrain_3d_texture_asset.h"

using namespace godot;
class Terrain3D;
class Terrain3DInstancer;

class Terrain3DAssets : public Resource {
	GDCLASS(Terrain3DAssets, Resource);
	CLASS_NAME();

public: // Constants
	enum AssetType {
		TYPE_TEXTURE,
		TYPE_MESH,
	};

	static inline const int MAX_TEXTURES = 32;
	static inline const int MAX_MESHES = 256;

private:
	Terrain3D *_terrain = nullptr;

	TypedArray<Terrain3DTextureAsset> _texture_list;
	TypedArray<Terrain3DMeshAsset> _mesh_list;

	GeneratedTexture _generated_albedo_textures;
	GeneratedTexture _generated_normal_textures;
	PackedColorArray _texture_colors;
	PackedFloat32Array _texture_uv_scales;
	PackedFloat32Array _texture_detiles;

	// Mesh previews
	RID scenario;
	RID viewport;
	RID viewport_texture;
	RID camera;
	RID key_light;
	RID key_light_instance;
	RID fill_light;
	RID fill_light_instance;
	RID mesh_instance;

	void _swap_ids(const AssetType p_type, const int p_src_id, const int p_dst_id);
	void _set_asset_list(const AssetType p_type, const TypedArray<Terrain3DAssetResource> &p_list);
	void _set_asset(const AssetType p_type, const int p_id, const Ref<Terrain3DAssetResource> &p_asset);

	void _update_texture_files();
	void _update_texture_settings();
	void _update_thumbnail(const Ref<Terrain3DMeshAsset> &p_mesh_asset);

public:
	Terrain3DAssets() {}
	void initialize(Terrain3D *p_terrain);
	~Terrain3DAssets();

	void set_texture(const int p_id, const Ref<Terrain3DTextureAsset> &p_texture);
	Ref<Terrain3DTextureAsset> get_texture(const int p_id) const { return _texture_list[p_id]; }
	void set_texture_list(const TypedArray<Terrain3DTextureAsset> &p_texture_list);
	TypedArray<Terrain3DTextureAsset> get_texture_list() const { return _texture_list; }
	int get_texture_count() const { return _texture_list.size(); }
	RID get_albedo_array_rid() const { return _generated_albedo_textures.get_rid(); }
	RID get_normal_array_rid() const { return _generated_normal_textures.get_rid(); }
	PackedColorArray get_texture_colors() const { return _texture_colors; }
	PackedFloat32Array get_texture_uv_scales() const { return _texture_uv_scales; }
	PackedFloat32Array get_texture_detiles() const { return _texture_detiles; }
	void update_texture_list();

	void set_mesh_asset(const int p_id, const Ref<Terrain3DMeshAsset> &p_mesh_asset);
	Ref<Terrain3DMeshAsset> get_mesh_asset(const int p_id) const;
	void set_mesh_list(const TypedArray<Terrain3DMeshAsset> &p_mesh_list);
	TypedArray<Terrain3DMeshAsset> get_mesh_list() const { return _mesh_list; }
	int get_mesh_count() const { return _mesh_list.size(); }
	void create_mesh_thumbnails(const int p_id = -1, const Vector2i &p_size = Vector2i(128, 128));
	void update_mesh_list();

	Error save(const String &p_path = "");

protected:
	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DAssets::AssetType);

#endif // TERRAIN3D_ASSETS_CLASS_H
