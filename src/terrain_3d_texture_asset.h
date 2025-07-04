// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_TEXTURE_CLASS_H
#define TERRAIN3D_TEXTURE_CLASS_H

#include <godot_cpp/classes/texture2d.hpp>

#include "constants.h"
#include "terrain_3d_asset_resource.h"

using namespace godot;

class Terrain3DTextureAsset : public Terrain3DAssetResource {
	GDCLASS(Terrain3DTextureAsset, Terrain3DAssetResource);
	CLASS_NAME();
	friend class Terrain3DAssets;

	Color _albedo_color = Color(1.f, 1.f, 1.f, 1.f);
	Ref<Texture2D> _albedo_texture;
	Ref<Texture2D> _normal_texture;
	real_t _normal_depth = 0.5f;
	real_t _ao_strength = 0.5f;
	real_t _roughness = 0.f;
	real_t _uv_scale = 0.1f;
	bool _vertical_projection = false;
	real_t _detiling_rotation = 0.0f;
	real_t _detiling_shift = 0.0f;

	bool _is_valid_format(const Ref<Texture2D> &p_texture) const;

public:
	Terrain3DTextureAsset() { clear(); }
	~Terrain3DTextureAsset() {}

	void clear() override;

	void set_name(const String &p_name) override;
	String get_name() const override { return _name; }

	void set_id(const int p_new_id) override;
	int get_id() const override { return _id; }

	void set_albedo_color(const Color &p_color);
	Color get_albedo_color() const { return _albedo_color; }

	void set_albedo_texture(const Ref<Texture2D> &p_texture);
	Ref<Texture2D> get_albedo_texture() const { return _albedo_texture; }

	void set_normal_texture(const Ref<Texture2D> &p_texture);
	Ref<Texture2D> get_normal_texture() const { return _normal_texture; }

	void set_normal_depth(const real_t p_normal_depth);
	real_t get_normal_depth() const { return _normal_depth; }

	void set_ao_strength(const real_t p_ao_strength);
	real_t get_ao_strength() const { return _ao_strength; }

	void set_roughness(const real_t p_roughness);
	real_t get_roughness() const { return _roughness; }

	void set_uv_scale(const real_t p_scale);
	real_t get_uv_scale() const { return _uv_scale; }

	void set_vertical_projection(const bool p_projection);
	bool get_vertical_projection() const { return _vertical_projection; }

	void set_detiling_rotation(const real_t p_detiling_rotation);
	real_t get_detiling_rotation() const { return _detiling_rotation; }

	void set_detiling_shift(const real_t p_detiling_shift);
	real_t get_detiling_shift() const { return _detiling_shift; }

protected:
	static void _bind_methods();
};

#endif // TERRAIN3D_TEXTURE_CLASS_H
