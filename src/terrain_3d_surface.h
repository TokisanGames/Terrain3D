//Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#ifndef TERRAIN3D_SURFACE_CLASS_H
#define TERRAIN3D_SURFACE_CLASS_H

#ifdef WIN32
#include <windows.h>
#endif

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/texture2d.hpp>

using namespace godot;

class Terrain3DSurface : public Resource {
	GDCLASS(Terrain3DSurface, Resource);

	Color albedo = Color(1.0, 1.0, 1.0, 1.0);
	Ref<Texture2D> albedo_texture;
	Ref<Texture2D> normal_texture;
	Vector3 uv_scale = Vector3(0.1f, 0.1f, 0.1f);
	float uv_rotation = 0.0f;

protected:
	static void _bind_methods();

public:
	Terrain3DSurface();
	~Terrain3DSurface();

	void set_albedo(Color p_color);
	Color get_albedo() const { return albedo; }

	void set_albedo_texture(const Ref<Texture2D> &p_texture);
	Ref<Texture2D> get_albedo_texture() const { return albedo_texture; }
	void set_normal_texture(const Ref<Texture2D> &p_texture);
	Ref<Texture2D> get_normal_texture() const { return normal_texture; }

	void set_uv_scale(Vector3 p_scale);
	Vector3 get_uv_scale() const { return uv_scale; }

	void set_uv_rotation(float p_rotation);
	float get_uv_rotation() const { return uv_rotation; }

private:
	bool _texture_is_valid(const Ref<Texture2D> &p_texture) const;
};

#endif // TERRAIN3D_SURFACE_CLASS_H