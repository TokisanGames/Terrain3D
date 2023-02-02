#ifndef TERRAINMATERIAL_CLASS_H
#define TERRAINMATERIAL_CLASS_H

#ifdef WIN32
#include <windows.h>
#endif

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/material.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/shader.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/classes/texture2d_array.hpp>

using namespace godot;

class TerrainMaterial3D : public Material {
	GDCLASS(TerrainMaterial3D, Material);

	Color albedo = Color(1.0, 1.0, 1.0, 1.0);
	Ref<Texture2D> albedo_texture;
	Ref<Texture2D> normal_texture;
	Vector3 uv_scale = Vector3(1.0, 1.0, 1.0);

	RID shader;

protected:
	static void _bind_methods();

public:
	TerrainMaterial3D();
	~TerrainMaterial3D();

	Shader::Mode _get_shader_mode() const;
	RID _get_shader_rid();

	void set_albedo(Color p_color);
	Color get_albedo() const;

	void set_albedo_texture(Ref<Texture2D> &p_texture);
	Ref<Texture2D> get_albedo_texture() const;
	void set_normal_texture(Ref<Texture2D> &p_texture);
	Ref<Texture2D> get_normal_texture() const;

	void set_uv_scale(Vector3 p_scale);
	Vector3 get_uv_scale() const;

private:
	bool _texture_is_valid(Ref<Texture2D> &p_texture) const;
	void _update_shader();
};

#endif // TERRAINSTORAGE_CLASS_H