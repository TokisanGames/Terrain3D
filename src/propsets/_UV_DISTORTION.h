#pragma once

#ifndef TERRAIN3D_UV_DISTORTION_H
#define TERRAIN3D_UV_DISTORTION_H

//Code Templates for Terrain3D Managed GLSL/Godot UV_DISTORTION Properties

// ################################################################################
#pragma region _UV_DISTORTION_

// *******************
// ** UV_DISTORTION **
// *******************

#pragma region _HELP_
#define HELP_UVDIST()\
	ADD_HELP_TOPIC_DECL(uv_distortion, R"(
UV Distortion slightly (or drastically) shifts the textures around 
at a vertex level in a random way based on where that point in space 
is. You can adjust the size and power of the effect.

This is still a WIP so the settings a bit finicky.  The larger the 
current size is, the more power is needed to have visible effect.  
So at low sizes, power has much more effect and can look overly 
distorted.  In the future the effect power may become better unified 
to the effect size.
)")
#pragma endregion _HELP_

#pragma region _uv_distortion_helper_macros_
#define   GETR_UVDIST(m_bind_id, m_type)					  GSTR( uv_distortion_##m_bind_id, m_type )
#define    VAR_UVDIST(m_bind_id, m_type, m_value)			  VARR( uv_distortion_##m_bind_id, m_type##, m_value )
#define   PROP_UVDIST(m_member_id, m_var_type, ...)  __PROP_GENGRP( uv_distortion, m_member_id, m_var_type, __VA_ARGS__ )
#define   BIND_UVDIST(m_bind_id, m_param_label)	 		  ADD_BIND( uv_distortion_##m_bind_id, m_param_label )
#define SETUPD_UVDIST(m_bind_id, m_type, s_log_desc)   SETUPD__GRP( uv_distortion, uv_distortion_##m_bind_id, m_type, s_log_desc )
#define _SETPR_UVDIST(m_bind_id, m_type, s_log_desc)   __SETPR_GRP( uv_distortion, uv_distortion_##m_bind_id, m_type, s_log_desc )
#define _UPDSH_UVDIST(m_member_id)					 UPDATE_SHADER( uv_distortion_##m_member_id )
#pragma endregion _uv_distortion_helper_macros_

#define UPDATE_UV_DISTORTION() UPDATE_GROUP(uv_distortion)

#define PRIV_UV_DISTORTION_VARS()\
	GROUP_VARS(uv_distortion)\
	VAR_UVDIST(enabled,			bool,	false)\
	VAR_UVDIST(size,			float,	60.0f)\
	VAR_UVDIST(power,			float,	30.0f)

#define PUBLIC_UV_DISTORTION_FUNCS()\
	GETR_UVDIST(enabled,		bool)\
	GETR_UVDIST(size,			float)\
	GETR_UVDIST(power,			float)

#define BIND_UV_DISTORTION_VARS() \
	BIND_UVDIST(enabled,		enabled)\
	BIND_UVDIST(size,			scale)\
	BIND_UVDIST(power,			power)

#define PROPS_UV_DISTORTION()\
	ADD_GROUP("UV Distortion", "uv_distortion_");\
	PROP_UVDIST(enabled,	BOOL,	NONE)\
	PROP_UVDIST(size,		FLOAT,	RANGE, "0.001,100.0,0.01, or_greater")\
	PROP_UVDIST(power,		FLOAT,	RANGE, "0.001,100.0,0.01, or_greater")\
	ADD_INLINE_HELP(uv_distortion, UV Distortion, About UV Distortion)

#define MAKE_UV_DISTORTION_FUNCTIONS() \
	UPDATE_GRP_START(uv_distortion)\
		_UPDSH_UVDIST(size)\
		_UPDSH_UVDIST(power)\
	UPDATE_GRP_END()\
	SETUPD_UVDIST(enabled,	bool,	"Enabled: ")\
	_SETPR_UVDIST(size,		float,	"Size: ")\
	_SETPR_UVDIST(power,	float,	"Power: ")

#pragma endregion _UV_DISTORTION_
// ################################################################################
#endif