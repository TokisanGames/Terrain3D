// Copyright © 2023 Roope Palmroos, Cory Petkovsek, and Contributors. All rights reserved. See LICENSE.
#ifndef TERRAIN3D_MATERIAL_CLASS_H
#define TERRAIN3D_MATERIAL_CLASS_H

#include <godot_cpp/classes/shader.hpp>

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

	int _region_size = 1024;
	Vector2i _region_sizev = Vector2i(_region_size, _region_size);

public:
	Terrain3DMaterial();
	~Terrain3DMaterial();

	RID get_material_rid() const { return _material; }
	RID get_shader_rid() const { return _shader; }

	void enable_shader_override(bool p_enabled);
	bool is_shader_override_enabled() const { return _shader_override_enabled; }
	void set_shader_override(const Ref<Shader> &p_shader);
	Ref<Shader> get_shader_override() const { return _shader_override; }

	void set_region_size(int p_size);
	int get_region_size() const { return _region_size; }

	void set_render_priority(int32_t priority);
	void set_next_pass(const RID &next_material);

protected:
	static void _bind_methods();
};

#endif // TERRAIN3D_MATERIAL_CLASS_H