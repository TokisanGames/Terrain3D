// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#ifndef TERRAIN3D_SURFACE_CLASS_H
#define TERRAIN3D_SURFACE_CLASS_H

#ifdef WIN32
#include <windows.h>
#endif

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>

using namespace godot;

class Terrain3DSurface : public Resource {
private:
	GDCLASS(Terrain3DSurface, Resource);

	Color _albedo = Color(1.0, 1.0, 1.0, 1.0);
	Ref<ImageTexture> _albedo_texture;
	Ref<ImageTexture> _normal_texture;
	Vector3 _uv_scale = Vector3(0.1f, 0.1f, 0.1f);
	float _uv_rotation = 0.0f;

	bool _texture_is_valid(const Ref<ImageTexture> &p_texture) const;

public:
	Terrain3DSurface();
	~Terrain3DSurface();

	void set_albedo(Color p_color);
	Color get_albedo() const { return _albedo; }

	void set_albedo_texture(const Ref<ImageTexture> &p_texture);
	Ref<Texture2D> get_albedo_texture() const { return _albedo_texture; }

	void set_normal_texture(const Ref<ImageTexture> &p_texture);
	Ref<Texture2D> get_normal_texture() const { return _normal_texture; }

	void set_uv_scale(Vector3 p_scale);
	Vector3 get_uv_scale() const { return _uv_scale; }

	void set_uv_rotation(float p_rotation);
	float get_uv_rotation() const { return _uv_rotation; }

protected:
	static void _bind_methods();
};

#endif // TERRAIN3D_SURFACE_CLASS_H