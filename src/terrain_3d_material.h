// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_MATERIAL_CLASS_H
#define TERRAIN3D_MATERIAL_CLASS_H

#include <godot_cpp/classes/shader.hpp>

#include "constants.h"
#include "generated_texture.h"

class Terrain3D;

class Terrain3DMaterial : public Resource {
	GDCLASS(Terrain3DMaterial, Resource);
	CLASS_NAME();

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

	enum UpdateFlags {
		UNIFORMS_ONLY = 0,
		TEXTURE_ARRAYS = 1 << 0,
		REGION_ARRAYS = 1 << 1,
		UPDATE_ARRAYS = TEXTURE_ARRAYS | REGION_ARRAYS,
		FULL_REBUILD = (1 << 2) | UPDATE_ARRAYS,
	};

private:
	Terrain3D *_terrain = nullptr;

	RID _material;
	Ref<Shader> _shader; // Active shader
	Dictionary _shader_code; // All loaded shader and INSERT code
	bool _shader_override_enabled = false;
	Ref<Shader> _shader_override; // User's shader we copy code from
	mutable TypedArray<StringName> _active_params; // All shader params in the current shader
	mutable Dictionary _shader_params; // Public shader params saved to disk

	RID _buffer_material;
	Ref<Shader> _buffer_shader; // Active buffer shader
	bool _buffer_shader_override_enabled = false;
	Ref<Shader> _buffer_shader_override; // User's shader we copy code from
	real_t _displacement_scale = 1.0f;
	real_t _displacement_sharpness = 0.5f;
	GeneratedTexture _generated_dummy;

	// Material Features
	WorldBackground _world_background = FLAT;
	TextureFiltering _texture_filtering = LINEAR;
	bool _dual_scaling_enabled = false;
	bool _auto_shader_enabled = false;
	bool _macro_variation_enabled = false;
	bool _projection_enabled = false;

	// PBR Outputs
	bool _output_albedo_enabled = true;
	bool _output_roughness_enabled = true;
	bool _output_normal_map_enabled = true;
	bool _output_ambient_occlusion_enabled = true;

	// Overlays
	bool _show_region_grid = false;
	bool _show_instancer_grid = false;
	bool _show_vertex_grid = false;
	bool _show_contours = false;
	bool _show_navigation = false;

	// Debug Views
	bool _debug_view_checkered = false;
	bool _debug_view_grey = false;
	bool _debug_view_heightmap = false;
	bool _debug_view_jaggedness = false;
	bool _debug_view_autoshader = false;
	bool _debug_view_control_texture = false;
	bool _debug_view_control_blend = false;
	bool _debug_view_control_angle = false;
	bool _debug_view_control_scale = false;
	bool _debug_view_holes = false;
	bool _debug_view_colormap = false;
	bool _debug_view_roughmap = false;
	bool _debug_view_displacement_buffer = false;

	// PBR Views
	bool _pbr_view_tex_albedo = false;
	bool _pbr_view_tex_height = false;
	bool _pbr_view_tex_normal = false;
	bool _pbr_view_tex_ao = false;
	bool _pbr_view_tex_rough = false;

	// Functions
	void _preload_shaders();
	void _parse_shader(const String &p_shader, const String &p_name);
	String _apply_inserts(const String &p_shader, const Array &p_excludes = Array()) const;
	String _generate_shader_code() const;
	String _generate_buffer_shader_code() const;
	String _strip_comments(const String &p_shader) const;
	String _inject_editor_code(const String &p_shader) const;
	void _update_shader();
	void _update_uniforms(const RID &p_material, const uint32_t p_update = UNIFORMS_ONLY);
	void _set_shader_parameters(const Dictionary &p_dict);
	Dictionary _get_shader_parameters() const { return _shader_params; }

public:
	Terrain3DMaterial() {}
	~Terrain3DMaterial() { destroy(); }
	void initialize(Terrain3D *p_terrain);
	bool is_initialized() { return _terrain != nullptr; }
	void uninitialize();
	void destroy();

	void update(const uint32_t p_flags = UNIFORMS_ONLY);
	RID get_material_rid() const { return _material; }
	RID get_shader_rid() const { return _shader.is_valid() ? _shader->get_rid() : RID(); }

	RID get_buffer_material_rid() const { return _buffer_material; }
	RID get_buffer_shader_rid() const { return _buffer_shader.is_valid() ? _buffer_shader->get_rid() : RID(); }

	// Material settings
	void set_displacement_scale(const real_t p_displacement_scale);
	real_t get_displacement_scale() const { return _displacement_scale; }
	void set_displacement_sharpness(const real_t p_displacement_sharpness);
	real_t get_displacement_sharpness() const { return _displacement_sharpness; }
	void set_world_background(const WorldBackground p_background);
	WorldBackground get_world_background() const { return _world_background; }
	void set_texture_filtering(const TextureFiltering p_filtering);
	TextureFiltering get_texture_filtering() const { return _texture_filtering; }
	void set_auto_shader_enabled(const bool p_enabled);
	bool get_auto_shader_enabled() const { return _auto_shader_enabled; }
	void set_dual_scaling_enabled(const bool p_enabled);
	bool get_dual_scaling_enabled() const { return _dual_scaling_enabled; }
	void set_macro_variation_enabled(const bool p_enabled);
	bool get_macro_variation_enabled() const { return _macro_variation_enabled; }
	void set_projection_enabled(const bool p_enabled);
	bool get_projection_enabled() const { return _projection_enabled; }

	void set_shader_override_enabled(const bool p_enabled);
	bool is_shader_override_enabled() const { return _shader_override_enabled; }
	void set_shader_override(const Ref<Shader> &p_shader);
	Ref<Shader> get_shader_override() const { return _shader_override; }

	void set_buffer_shader_override_enabled(const bool p_enabled);
	bool is_buffer_shader_override_enabled() const { return _buffer_shader_override_enabled; }
	void set_buffer_shader_override(const Ref<Shader> &p_shader);
	Ref<Shader> get_buffer_shader_override() const { return _buffer_shader_override; }

	void set_shader_param(const StringName &p_name, const Variant &p_value);
	Variant get_shader_param(const StringName &p_name) const;

	// PBR outputs
	void set_output_albedo_enabled(const bool p_enabled);
	bool get_output_albedo_enabled() const { return _output_albedo_enabled; }

	void set_output_roughness_enabled(const bool p_enabled);
	bool get_output_roughness_enabled() const { return _output_roughness_enabled; }

	void set_output_normal_map_enabled(const bool p_enabled);
	bool get_output_normal_map_enabled() const { return _output_normal_map_enabled; }

	void set_output_ambient_occlusion_enabled(const bool p_enabled);
	bool get_output_ambient_occlusion_enabled() const { return _output_ambient_occlusion_enabled; }

	// Overlays
	void set_show_region_grid(const bool p_enabled);
	bool get_show_region_grid() const { return _show_region_grid; }
	void set_show_instancer_grid(const bool p_enabled);
	bool get_show_instancer_grid() const { return _show_instancer_grid; }
	void set_show_vertex_grid(const bool p_enabled);
	bool get_show_vertex_grid() const { return _show_vertex_grid; }
	void set_show_contours(const bool p_enabled);
	bool get_show_contours() const { return _show_contours; }
	void set_show_navigation(const bool p_enabled);
	bool get_show_navigation() const { return _show_navigation; }

	// Debug views
	void set_show_checkered(const bool p_enabled);
	bool get_show_checkered() const { return _debug_view_checkered; }
	void set_show_grey(const bool p_enabled);
	bool get_show_grey() const { return _debug_view_grey; }
	void set_show_heightmap(const bool p_enabled);
	bool get_show_heightmap() const { return _debug_view_heightmap; }
	void set_show_jaggedness(const bool p_enabled);
	bool get_show_jaggedness() const { return _debug_view_jaggedness; }
	void set_show_autoshader(const bool p_enabled);
	bool get_show_autoshader() const { return _debug_view_autoshader; }
	void set_show_control_texture(const bool p_enabled);
	bool get_show_control_texture() const { return _debug_view_control_texture; }
	void set_show_control_blend(const bool p_enabled);
	bool get_show_control_blend() const { return _debug_view_control_blend; }
	void set_show_control_angle(const bool p_enabled);
	bool get_show_control_angle() const { return _debug_view_control_angle; }
	void set_show_control_scale(const bool p_enabled);
	bool get_show_control_scale() const { return _debug_view_control_scale; }
	void set_show_colormap(const bool p_enabled);
	bool get_show_colormap() const { return _debug_view_colormap; }
	void set_show_roughmap(const bool p_enabled);
	bool get_show_roughmap() const { return _debug_view_roughmap; }
	void set_show_displacement_buffer(const bool p_enabled);
	bool get_show_displacement_buffer() const { return _debug_view_displacement_buffer; }

	// PBR Views
	void set_show_texture_albedo(const bool p_enabled);
	bool get_show_texture_albedo() const { return _pbr_view_tex_albedo; }
	void set_show_texture_height(const bool p_enabled);
	bool get_show_texture_height() const { return _pbr_view_tex_height; }
	void set_show_texture_normal(const bool p_enabled);
	bool get_show_texture_normal() const { return _pbr_view_tex_normal; }
	void set_show_texture_rough(const bool p_enabled);
	bool get_show_texture_rough() const { return _pbr_view_tex_rough; }
	void set_show_texture_ao(const bool p_enabled);
	bool get_show_texture_ao() const { return _pbr_view_tex_ao; }

	Error save(const String &p_path = "");

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
VARIANT_ENUM_CAST(Terrain3DMaterial::UpdateFlags);

#endif // TERRAIN3D_MATERIAL_CLASS_H