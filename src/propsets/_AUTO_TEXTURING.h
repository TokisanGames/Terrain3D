#pragma once

#ifndef TERRAIN3D_AUTO_TEXTURING_H
#define TERRAIN3D_AUTO_TEXTURING_H

//Code Templates for Terrain3D Managed GLSL/Godot AUTO_TEXTURING Properties

// ################################################################################
#pragma region _AUTO_TEXTURING_
// *****************
// ** AUTO_TEXTURING **
// *****************

#pragma region _HELP_
#define HELP_AUTO_TEXTURING()\
	ADD_HELP_TOPIC_DECL(auto_texturing, R"(
Enables selecting two texture IDs that will automatically be applied to the terrain based upon slope.
)" )
#pragma endregion _HELP_

#pragma region _auto_texturing_helper_macros_
#define GETR_AUTOS(m_bind_id, m_type) GSTR(auto_texturing_##m_bind_id, m_type)
#define  VAR_AUTOS(m_bind_id, m_type, m_value) VARR(auto_texturing_##m_bind_id, m_type##, m_value)
#define PROP_AUTOS(m_member_id, m_var_type, ...) __PROP_GENGRP( auto_texturing, m_member_id, m_var_type, __VA_ARGS__ )
#define BIND_AUTOS(m_bind_id, m_param_label) ADD_BIND(auto_texturing_##m_bind_id, m_param_label)
#define SETUPD_AUTOS(m_bind_id, m_type, s_log_desc) SETUPD__GRP(auto_texturing, auto_texturing_##m_bind_id, m_type, s_log_desc)
#define _SETPR_AUTOS(m_bind_id, m_type, s_log_desc) __SETPR_GRP(auto_texturing, auto_texturing_##m_bind_id, m_type, s_log_desc)
#define _UPDSH_AUTOS(m_member_id) UPDATE_SHADER(auto_texturing_##m_member_id)
#pragma endregion _auto_texturing_helper_macros_

#define UPDATE_AUTO_TEXTURING() UPDATE_GROUP(auto_texturing)

#define PRIV_AUTO_TEXTURING_VARS()\
	GROUP_VARS(auto_texturing)\
	VAR_AUTOS(enabled,			bool,	false)\
	VAR_AUTOS(slope,			float,	1.45f)\
	VAR_AUTOS(height_reduction,	float,	0.0f)\
	VAR_AUTOS(base_texture,		int,	0)\
	VAR_AUTOS(overlay_texture,	int,	1)

#define PUBLIC_AUTO_TEXTURING_FUNCS()\
	GETR_AUTOS(enabled,			bool)\
	GETR_AUTOS(slope,			float)\
	GETR_AUTOS(height_reduction,float)\
	GETR_AUTOS(base_texture,	int)\
	GETR_AUTOS(overlay_texture, int)

#define BIND_AUTO_TEXTURING_VARS() \
	BIND_AUTOS(enabled,				enabled)\
	BIND_AUTOS(base_texture,		layer)\
	BIND_AUTOS(overlay_texture,		layer)\
	BIND_AUTOS(height_reduction,	height)\
	BIND_AUTOS(slope,				slope)

#define PROPS_AUTO_TEXTURING()\
	ADD_GROUP("Auto Texturing", "auto_texturing_");\
	PROP_AUTOS(enabled,				BOOL,	NONE)\
	PROP_AUTOS(slope,				FLOAT,	RANGE, "0.01, 10.0, 0.01, or_greater")\
	PROP_AUTOS(height_reduction,	FLOAT,	RANGE, "-0.50, 1.0, 0.01, or_greater, or_less")\
	PROP_AUTOS(base_texture,		INT,	RANGE, "0, 31, 1")\
	PROP_AUTOS(overlay_texture,		INT,	RANGE, "0, 31, 1")\
	ADD_INLINE_HELP(auto_texturing, Auto Texturing, About Auto Texturing)

#define MAKE_AUTO_TEXTURING_FUNCTIONS() \
	UPDATE_GRP_START(auto_texturing)\
		_UPDSH_AUTOS(slope)\
		_UPDSH_AUTOS(height_reduction)\
		_UPDSH_AUTOS(base_texture)\
		_UPDSH_AUTOS(overlay_texture)\
	UPDATE_GRP_END()\
	SETUPD_AUTOS(enabled,			bool,	"Enabled: ")\
	_SETPR_AUTOS(slope,				float,	"Slope: ")\
	_SETPR_AUTOS(height_reduction,	float,	"Height Reduction: ")\
	_SETPR_AUTOS(base_texture,		int,	"Base Texture: ")\
	_SETPR_AUTOS(overlay_texture,	int,	"Overlay Texture: ")
#pragma endregion _AUTO_TEXTURING_
// ################################################################################
#endif