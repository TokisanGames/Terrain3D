//Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#ifndef TERRAINSURFACE_CLASS_H
#define TERRAINSURFACE_CLASS_H

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
	Vector3 uv_scale = Vector3(1.0, 1.0, 1.0);

protected:
	static void _bind_methods();

public:
	Terrain3DSurface();
	~Terrain3DSurface();

	void set_albedo(Color p_color);
	Color get_albedo() const;

	void set_albedo_texture(const Ref<Texture2D> &p_texture);
	Ref<Texture2D> get_albedo_texture() const;
	void set_normal_texture(const Ref<Texture2D> &p_texture);
	Ref<Texture2D> get_normal_texture() const;

	void set_uv_scale(Vector3 p_scale);
	Vector3 get_uv_scale() const;

private:
	bool _texture_is_valid(const Ref<Texture2D> &p_texture) const;
};

#endif // TERRAINSURFACE_CLASS_H