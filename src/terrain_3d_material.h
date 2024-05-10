// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_MATERIAL_CLASS_H
#define TERRAIN3D_MATERIAL_CLASS_H

#include <godot_cpp/classes/shader.hpp>

#include "constants.h"
#include "generated_texture.h"
#define __TEMPORARY_INLINE_HELP
#include "propsets/ALL_SETS.h"

class Terrain3D;
class Terrain3DTextureList;

using namespace godot;

class Terrain3DMaterial : public Resource {
	GDCLASS(Terrain3DMaterial, Resource);
	CLASS_NAME();
	friend class Terrain3D;

public: // Constants
	enum WorldBackground {
		NONE,
		FLAT,
		NOISE,
	};

	enum TextureFiltering {
		LINEAR,
		NEAREST,
	};

	enum NormalCalculation {
		PIXEL,
		VERTEX,
		BY_DISTANCE
	};

private:
	Terrain3D *_terrain = nullptr;

	RID _material;
	RID _shader;
	bool _shader_override_enabled = false;
	Ref<Shader> _shader_override;
	Ref<Shader> _shader_tmp;
	Dictionary _shader_code;
	String _last_generated_defines = "";
	mutable TypedArray<StringName> _active_params; // All shader params in the current shader
	mutable Dictionary _shader_params; // Public shader params saved to disk
	GeneratedTexture _generated_region_blend_map; // 512x512 blurred image of region_map
	PRIVATE_MANAGED_VARS()

	// Static Functions
	static String _format_string_for_inline_help (String _source);

	// Functions
	void _preload_shaders();
	void _parse_shader(String p_shader, String p_name);
	String _apply_inserts(String p_shader, Array p_excludes = Array());
	String _generate_shader_code(String _explicitDefines = "");
	//String _inject_editor_code(String p_shader);
	void _update_shader();
	void _update_regions();
	void _generate_region_blend_map();
	void _update_texture_arrays();
	void _set_shader_parameters(const Dictionary &p_dict);
	Dictionary _get_shader_parameters() const { return _shader_params; }

	int get_octaves_by_distance(float d);
	float get_unweighted_generated_height(Vector3 worldPos, int octaves);
	float noise_type1(Vector2 p, int octaves);
	Vector3 noise2D(Vector2 x);
	float ihashv2(Vector2i iv);


public:
	Terrain3DMaterial(){};
	void initialize(Terrain3D *p_terrain);
	~Terrain3DMaterial();

	RID get_material_rid() const { return _material; }
	RID get_shader_rid() const;
	RID get_region_blend_map() { return _generated_region_blend_map.get_rid(); }

	void enable_shader_override(bool p_enabled);
	bool is_shader_override_enabled() const { return _shader_override_enabled; }
	void set_shader_override(const Ref<Shader> &p_shader);
	Ref<Shader> get_shader_override() const { return _shader_override; }

	void set_shader_param(const StringName &p_name, const Variant &p_value);
	Variant get_shader_param(const StringName &p_name) const;

	void save();

	String _add_if_exists(String _current, String _snippetID_);
	String _add_if_enabled(String _current, bool _controlVar, String _snippetID_enabled, String _snippetID_disabled = "");
	Array _add_if_true(Array _toset, bool _condition, String _toadd, String _toadd_if_false = "");
	String _get_current_defines();
	String _add_or_update_header(String _to_code, String _explicitDefines = "");
	void _update_shader_if_defines_have_changed();
	void _safe_material_set_param(StringName _param, Variant _value);
	PUBLIC_MANAGED_FUNCS()

protected:
	void _get_property_list(List<PropertyInfo> *p_list) const;
	bool _property_can_revert(const StringName &p_name) const;
	bool _property_get_revert(const StringName &p_name, Variant &r_property) const;
	bool _set(const StringName &p_name, const Variant &p_property);
	bool _get(const StringName &p_name, Variant &r_property) const;

	static void _bind_methods();
};

VARIANT_ENUM_CAST(Terrain3DMaterial::WorldBackground);
VARIANT_ENUM_CAST(Terrain3DMaterial::TextureFiltering);
VARIANT_ENUM_CAST(Terrain3DMaterial::NormalCalculation);

#endif // TERRAIN3D_MATERIAL_CLASS_H