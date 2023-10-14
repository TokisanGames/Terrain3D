// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_MATERIAL_CLASS_H
#define TERRAIN3D_MATERIAL_CLASS_H

#include <godot_cpp/classes/shader.hpp>

#include "generated_tex.h"

using namespace godot;

class Terrain3DMaterial : public Resource {
private:
	GDCLASS(Terrain3DMaterial, Resource);
	static inline const char *__class__ = "Terrain3DMaterial";

	RID _material;
	RID _shader;
	bool _shader_override_enabled = false;
	Ref<Shader> _shader_override;
	Dictionary _shader_code;
	mutable TypedArray<StringName> _shader_param_list;
	mutable Dictionary _param_cache;

	int _texture_count = 0;
	bool _debug_view_checkered = false;
	bool _debug_view_grey = false;
	bool _debug_view_heightmap = false;
	bool _debug_view_colormap = false;
	bool _debug_view_roughmap = false;
	bool _debug_view_controlmap = false;
	bool _debug_view_tex_height = false;
	bool _debug_view_tex_normal = false;
	bool _debug_view_tex_rough = false;
	bool _debug_view_vertex_grid = false;

	bool _world_noise_enabled = false;

	// Cached data from Storage
	int _region_size = 1024;
	Vector2i _region_sizev = Vector2i(_region_size, _region_size);
	PackedByteArray _region_map;
	GeneratedTex _generated_region_blend_map; // 512x512 blurred image of region_map

	void _preload_shaders();
	String _parse_shader(String p_shader, String p_name = String(), Array p_excludes = Array());
	String _generate_shader_code();
	void _generate_region_blend_map();
	void _update_regions(const Array &p_args);
	void _update_texture_arrays(const Array &p_args);
	void _update_shader();

public:
	Terrain3DMaterial();
	~Terrain3DMaterial();

	RID get_material_rid() const { return _material; }
	RID get_shader_rid() const { return _shader; }

	void enable_shader_override(bool p_enabled);
	bool is_shader_override_enabled() const { return _shader_override_enabled; }
	void set_shader_override(const Ref<Shader> &p_shader);
	Ref<Shader> get_shader_override() const { return _shader_override; }

	void set_param_cache(const Dictionary &p_dict);
	Dictionary get_param_cache() const { return _param_cache; }

	void set_region_size(int p_size);
	int get_region_size() const { return _region_size; }
	RID get_region_blend_map() { return _generated_region_blend_map.get_rid(); }

	void set_world_noise_enabled(bool p_enabled);
	bool get_world_noise_enabled() const { return _world_noise_enabled; }

	void set_show_checkered(bool p_enabled);
	bool get_show_checkered() const { return _debug_view_checkered; }
	void set_show_grey(bool p_enabled);
	bool get_show_grey() const { return _debug_view_grey; }
	void set_show_heightmap(bool p_enabled);
	bool get_show_heightmap() const { return _debug_view_heightmap; }
	void set_show_colormap(bool p_enabled);
	bool get_show_colormap() const { return _debug_view_colormap; }
	void set_show_roughmap(bool p_enabled);
	bool get_show_roughmap() const { return _debug_view_roughmap; }
	void set_show_controlmap(bool p_enabled);
	bool get_show_controlmap() const { return _debug_view_controlmap; }
	void set_show_texture_height(bool p_enabled);
	bool get_show_texture_height() const { return _debug_view_tex_height; }
	void set_show_texture_normal(bool p_enabled);
	bool get_show_texture_normal() const { return _debug_view_tex_normal; }
	void set_show_texture_rough(bool p_enabled);
	bool get_show_texture_rough() const { return _debug_view_tex_rough; }
	void set_show_vertex_grid(bool p_enabled);
	bool get_show_vertex_grid() const { return _debug_view_vertex_grid; }

protected:
	void _get_property_list(List<PropertyInfo> *p_list) const;
	bool _property_can_revert(const StringName &p_name) const;
	bool _property_get_revert(const StringName &p_name, Variant &r_property) const;
	bool _set(const StringName &p_name, const Variant &p_property);
	bool _get(const StringName &p_name, Variant &r_property) const;

	static void _bind_methods();
};

#endif // TERRAIN3D_MATERIAL_CLASS_H