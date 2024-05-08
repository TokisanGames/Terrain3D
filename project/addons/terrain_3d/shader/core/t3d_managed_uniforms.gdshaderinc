// Copyright (c) 2023 Cory Petkovsek, Roope Palmroos, and Contributors.
//
#if !defined(__T3D_MANAGED_UNIFORMS_AVAILABLE__)
#define __T3D_MANAGED_UNIFORMS_AVAILABLE__
// -----------------------------------------------------------------------------
// This file declares core internal uniforms, and any module-required uniforms 
// if defines are established that signify they're needed.
// *****************************************************************************

// Private uniforms (Core internals)

// Region Samplers:
uniform usampler2DArray _control_maps	: repeat_disable;
uniform sampler2DArray	_height_maps	: repeat_disable;
// uniform sampler2DArray	_normal_maps	: repeat_disable;

// Region Data Arrays:
uniform int		_region_map[256];
uniform vec2	_region_offsets[256];

uniform int		_region_map_size = 16;
uniform float	_region_size = 1024.0;
uniform float	_region_texel_size = 0.0009765625;	// = 1/1024

// Texture Samplers:
#if defined(TEXTURE_SAMPLERS_LINEAR)
uniform sampler2DArray	_color_maps				: source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2DArray	_texture_array_albedo	: source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray	_texture_array_normal	: hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D		_tinting_texture		: source_color, filter_linear_mipmap_anisotropic, repeat_enable;
#else
// TEXTURE_SAMPLERS_NEAREST
uniform sampler2DArray	_color_maps				: source_color, filter_nearest_mipmap_anisotropic, repeat_disable;
uniform sampler2DArray	_texture_array_albedo	: source_color, filter_nearest_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray	_texture_array_normal	: hint_normal, filter_nearest_mipmap_anisotropic, repeat_enable;
uniform sampler2D		_tinting_texture		: source_color, filter_nearest_mipmap_anisotropic, repeat_enable;
#endif

// Texture Data Arrays:
uniform float _texture_uv_scale_array[32];
uniform float _texture_uv_rotation_array[32];
uniform vec4 _texture_color_array[32];

// Mesh Settings (for this material instance):
uniform float _mesh_vertex_spacing = 1.0;
uniform float _mesh_vertex_density = 1.0;			// = 1/_mesh_vertex_spacing

uniform uint _bg_world_fill = 1u;					// NONE = 0, FLAT = 1, NOISE = 2
uniform uint _mouse_layer = 0x80000000u;			// Layer 32

// The height-based or default blend sharpness value 
uniform float _blending_sharpness = 0.87;

// *****************************************************************************
// END: CORE INTERNALS
// -----------------------------------------------------------------------------
// BEGIN: MOD UNIFORMS
// *****************************************************************************
#if defined(HEIGHT_BLENDING_ENABLED)
	uniform float _height_blending_bias;
#endif  // ---------------------------------------------------------------------
#if defined(NOISE_TINT_ENABLED)
	// Generic noise at 3 scales, which can be used for anything 
	uniform vec3	_tinting_macro_variation1;
	uniform vec3	_tinting_macro_variation2;
	uniform float	_tinting_noise1_scale;
	uniform float	_tinting_noise1_angle;
	uniform vec2	_tinting_noise1_offset = vec2(0.5);
	uniform float	_tinting_noise2_scale;
	uniform float	_tinting_noise3_scale;
#endif  // ---------------------------------------------------------------------
#if defined(BG_WORLD_ENABLED)
	uniform int		_bg_world_max_octaves = 6;
	uniform int		_bg_world_min_octaves = 3;
	uniform float	_bg_world_lod_distance = 2500.;
	uniform float	_bg_world_scale = 5.;
	uniform	float	_bg_world_height = 64.;
	uniform	vec3	_bg_world_offset = vec3(0.);
	uniform	float	_bg_world_blend_near = 0.5;
	uniform	float	_bg_world_blend_far = 1.;
#endif  // ---------------------------------------------------------------------
#if defined(AUTO_TEXTURING_ENABLED)
	uniform float	_auto_texturing_slope;
	uniform float	_auto_texturing_height_reduction;
	uniform int		_auto_texturing_base_texture;
	uniform int		_auto_texturing_overlay_texture;
#endif  // ---------------------------------------------------------------------
#if defined(MULTI_SCALING_ENABLED)
	uniform int _multi_scaling_texture;
	uniform float	_multi_scaling_distant_size;
	uniform float	_multi_scaling_near_size;
	uniform float	_multi_scaling_far;
	uniform float	_multi_scaling_near;
#endif  // ---------------------------------------------------------------------
#if defined(UV_DISTORTION_ENABLED)  
	uniform float	_uv_distortion_size;
	uniform float	_uv_distortion_power;
#endif
// *****************************************************************************
// END: MOD UNIFORMS
// -----------------------------------------------------------------------------
// BEGIN: UNSORTED STAGING AREA
// *****************************************************************************

// Public uniforms
uniform float vertex_normals_distance : hint_range(0, 1024) = 128.0;

// *****************************************************************************
// END: UNSORTED STAGING AREA
// -----------------------------------------------------------------------------
#endif
