#ifndef OCEAN3D_MATERIAL_CLASS_H
#define OCEAN3D_MATERIAL_CLASS_H

#include <godot_cpp/classes/shader.hpp>

using namespace godot;

class Ocean3DMaterial : public Resource {
	GDCLASS(Ocean3DMaterial, Resource);

public:
	// Constants
	static inline const char *__class__ = "Ocean3DMaterial";

	enum WorldBackground {
		NONE,
		INFINITE,
	};

private:
	bool _initialized = false;
	RID _material;
	RID _shader;
	bool _shader_override_enabled = false;
	Ref<Shader> _shader_override;
	Ref<Shader> _shader_tmp;
	Dictionary _shader_code;
	mutable TypedArray<StringName> _active_params; // All shader params in the current shader
	mutable Dictionary _shader_params; // Public shader params saved to disk

	// Material Features
	WorldBackground _world_background = NONE;

	// Cached data from Storage
	int _texture_count = 0;
	int _region_size = 1024;
	real_t _mesh_vertex_spacing = 1.0f;
	Vector2i _region_sizev = Vector2i(_region_size, _region_size);
	PackedInt32Array _region_map;

	// Functions
	void _preload_shaders();
	void _parse_shader(String p_shader, String p_name);
	String _apply_inserts(String p_shader, Array p_excludes = Array());
	String _generate_shader_code();
	String _inject_editor_code(String p_shader);
	void _update_shader();
	void _set_region_size(int p_size);
	void _set_shader_parameters(const Dictionary &p_dict);
	Dictionary _get_shader_parameters() const { return _shader_params; }

public:
	Ocean3DMaterial(){};
	void initialize(int p_region_size);
	~Ocean3DMaterial();

	RID get_material_rid() const { return _material; }
	RID get_shader_rid() const;

	// Material settings
	void set_world_background(WorldBackground p_background);
	WorldBackground get_world_background() const { return _world_background; }
	void enable_shader_override(bool p_enabled);
	bool is_shader_override_enabled() const { return _shader_override_enabled; }
	void set_shader_override(const Ref<Shader> &p_shader);
	Ref<Shader> get_shader_override() const { return _shader_override; }

	void set_shader_param(const StringName &p_name, const Variant &p_value);
	Variant get_shader_param(const StringName &p_name) const;

	void set_mesh_vertex_spacing(real_t p_spacing);

	void save();

protected:
	void _get_property_list(List<PropertyInfo> *p_list) const;
	bool _property_can_revert(const StringName &p_name) const;
	bool _property_get_revert(const StringName &p_name, Variant &r_property) const;
	bool _set(const StringName &p_name, const Variant &p_property);
	bool _get(const StringName &p_name, Variant &r_property) const;

	static void _bind_methods();
};

VARIANT_ENUM_CAST(Ocean3DMaterial::WorldBackground);

#endif // OCEAN3D_MATERIAL_CLASS_H