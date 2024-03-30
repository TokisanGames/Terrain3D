// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_TEXTURE_LIST_CLASS_H
#define TERRAIN3D_TEXTURE_LIST_CLASS_H

#include "constants.h"
#include "generated_texture.h"
#include "terrain_3d_texture.h"

using namespace godot;

class Terrain3DTextureList : public Resource {
	GDCLASS(Terrain3DTextureList, Resource);
	CLASS_NAME();

public: // Constants
	static inline const int MAX_TEXTURES = 32;

private:
	TypedArray<Terrain3DTexture> _textures;

	GeneratedTexture _generated_albedo_textures;
	GeneratedTexture _generated_normal_textures;
	PackedColorArray _texture_colors;
	PackedFloat32Array _texture_uv_scales;
	PackedFloat32Array _texture_uv_rotations;

	void _swap_textures(int p_old_id, int p_new_id);
	void _update_texture_files();
	void _update_texture_settings();

public:
	Terrain3DTextureList();
	~Terrain3DTextureList();

	void update_list();
	void set_texture(int p_index, const Ref<Terrain3DTexture> &p_texture);
	Ref<Terrain3DTexture> get_texture(int p_index) const { return _textures[p_index]; }
	void set_textures(const TypedArray<Terrain3DTexture> &p_textures);
	TypedArray<Terrain3DTexture> get_textures() const { return _textures; }
	int get_texture_count() const { return _textures.size(); }
	RID get_albedo_array_rid() { return _generated_albedo_textures.get_rid(); }
	RID get_normal_array_rid() { return _generated_normal_textures.get_rid(); }
	PackedColorArray get_texture_colors() { return _texture_colors; }
	PackedFloat32Array get_texture_uv_scales() { return _texture_uv_scales; }
	PackedFloat32Array get_texture_uv_rotations() { return _texture_uv_rotations; }

	void save();

protected:
	static void _bind_methods();
};

#endif // TERRAIN3D_TEXTURE_LIST_CLASS_H