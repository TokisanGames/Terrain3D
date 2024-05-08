#pragma once

#ifndef TERRAIN3D_BLENDING_H
#define TERRAIN3D_BLENDING_H

//Code Templates for Terrain3D Managed GLSL/Godot BLENDING Properties

// ################################################################################
#pragma region _BLENDING_

// *********************
// ** BLENDING **
// *********************

#pragma region _HELP_
#define HELP_BLEND()\
	ADD_HELP_TOPIC_DECL(blending, R"(
Sharpness: Affects the overall speed that materials change between layers.  
Auto-Texturing and Multi-Scaling are significantly influenced by this setting.

Texture Filtering: By default, linear mip-mapping is applied, but if you want 
you can disable that and use nearest, which as a more pixelated, chunky look 
up close.  Nearest mode is a bit faster, between the two.

By Height: Changes the way materials are blended together based on the height 
(albedo alpha channel) of each, so higher areas of one are more visible than lower 
portions of the other.
)")
#pragma endregion _HELP_

#pragma region _blending_helper_macros_
#define   GETR_BLEND(m_bind_id, m_type)					  GSTR( blending_##m_bind_id, m_type )
#define    VAR_BLEND(m_bind_id, m_type, m_value)			  VARR( blending_##m_bind_id, m_type##, m_value )
#define   PROP_BLEND(m_member_id, m_var_type, ...)  __PROP_GENGRP( blending, m_member_id, m_var_type, __VA_ARGS__ )
#define   BIND_BLEND(m_bind_id, m_param_label)	 		  ADD_BIND( blending_##m_bind_id, m_param_label )
#define SETUPD_BLEND(m_bind_id, m_type, s_log_desc)   SETUPD__GRP( blending, blending_##m_bind_id, m_type, s_log_desc )
#define _SETPR_BLEND(m_bind_id, m_type, s_log_desc)   __SETPR_GRP( blending, blending_##m_bind_id, m_type, s_log_desc )
#define _UPDSH_BLEND(m_member_id)					 UPDATE_SHADER( blending_##m_member_id )
#pragma endregion _blending_helper_macros_

#define UPDATE_BLENDING() UPDATE_GROUP(blending)

#define PRIV_BLENDING_VARS()\
	GROUP_VARS(blending)\
	VAR_BLEND(sharpness,			float,				0.6f)\
	VAR_BLEND(texture_filtering,	TextureFiltering,	LINEAR)\
	VAR_BLEND(by_height,			bool,				false)

#define PUBLIC_BLENDING_FUNCS()\
	GETR_BLEND(sharpness,			float)\
	GETR_BLEND(texture_filtering,	TextureFiltering)\
	GETR_BLEND(by_height,			bool)

#define BIND_BLENDING_VARS() \
	BIND_BLEND(sharpness,			sharpness)\
	BIND_BLEND(texture_filtering,	filtering)\
	BIND_BLEND(by_height,			by_height)

#define PROPS_BLENDING()\
	ADD_GROUP("Blending", "blending_");\
	PROP_BLEND(sharpness,			FLOAT,		RANGE, "0.001,0.999,0.001")\
	PROP_BLEND(texture_filtering,	INT,		ENUM,  "Linear,Nearest")\
	PROP_BLEND(by_height,			BOOL,		NONE)\
	ADD_INLINE_HELP(blending,		Blending,	About Blending Options)

#define MAKE_BLENDING_FUNCTIONS() \
	UPDATE_GRP_START_CON(blending,	true == true )\
		_UPDSH_BLEND(sharpness)\
	UPDATE_GRP_END()\
	_SETPR_BLEND(sharpness,			float,				"Sharpness: ")\
	SETUPD_BLEND(texture_filtering,	TextureFiltering,	"Filtering: ")\
	SETUPD_BLEND(by_height,			bool,				"Height Blending Enabled: ")

#pragma endregion _BLENDING_
// ################################################################################
#endif