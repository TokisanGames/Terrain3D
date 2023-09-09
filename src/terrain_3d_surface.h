// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#ifndef TERRAIN3D_SURFACE_CLASS_H
#define TERRAIN3D_SURFACE_CLASS_H

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/texture2d.hpp>

using namespace godot;

/******************************************************************
 * This class is DEPRECATED in 0.8.3. Remove 0.9-1.0. Do not use.
 ******************************************************************/

class Terrain3DSurface : public Resource {
private:
	GDCLASS(Terrain3DSurface, Resource);
	static inline const char *__class__ = "Terrain3DSurface";

	struct Settings {
		String _name = "New Texture";
		int _surface_id = 0;
		Color _albedo = Color(1.0, 1.0, 1.0, 1.0);
		Ref<Texture2D> _albedo_texture;
		Ref<Texture2D> _normal_texture;
		float _uv_scale = 0.1f;
		float _uv_rotation = 0.0f;
	} _data;

	bool _texture_is_valid(const Ref<Texture2D> &p_texture) const;

public:
	Terrain3DSurface();
	~Terrain3DSurface();

	// Edit data directly to avoid signal emitting recursion
	Settings *get_data() { return &_data; }
	void clear();

	void set_name(String p_name);
	String get_name() const { return _data._name; }

	void set_surface_id(int p_new_id);
	int get_surface_id() const { return _data._surface_id; }

	void set_albedo(Color p_color);
	Color get_albedo() const { return _data._albedo; }

	void set_albedo_texture(const Ref<Texture2D> &p_texture);
	Ref<Texture2D> get_albedo_texture() const { return _data._albedo_texture; }

	void set_normal_texture(const Ref<Texture2D> &p_texture);
	Ref<Texture2D> get_normal_texture() const { return _data._normal_texture; }

	void set_uv_scale(float p_scale);
	float get_uv_scale() const { return _data._uv_scale; }

	void set_uv_rotation(float p_rotation);
	float get_uv_rotation() const { return _data._uv_rotation; }

protected:
	static void _bind_methods();
};

#endif // TERRAIN3D_SURFACE_CLASS_H