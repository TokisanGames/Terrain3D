#pragma once

#ifndef TERRAIN3D_NORMALS_H
#define TERRAIN3D_NORMALS_H

//Code Templates for Terrain3D Managed GLSL/Godot NORMALS Properties

// ################################################################################
#pragma region _NORMALS_

// *******************
// ** NORMALS **
// *******************

#pragma region _HELP_
#define HELP_NORMS()\
	ADD_HELP_TOPIC_DECL(normals, R"(
A mesh normal is the outward facing direction of a surface at any point. 
3D graphics smoothly shifts that normal over the entire surface.  How 
that normal is calculated impacts quality and speed inversely, with 
per-pixel providing the highest quality, but per-vertex having the fastest 
speed.  A third option is available, where beyond a certain distance 
it uses per-pixel, because the mesh density is much lower there and it 
looks better per-pixel.  But up-close where the mesh density is very high, 
per-pixel is less necessary.  It still looks better but it's harder to tell 
and in many situations it might be good enough, and offer faster speeds.

The Distance setting lets you adjust the vertex/pixel range if the By_Distance 
option is selected.
)")
#pragma endregion _HELP_

#pragma region _normals_helper_macros_
#define   GETR_NORMS(m_bind_id, m_type)                       GSTR( normals_##m_bind_id, m_type )
#define    VAR_NORMS(m_bind_id, m_type, m_value)              VARR( normals_##m_bind_id, m_type##, m_value )
#define   PROP_NORMS(m_member_id, m_var_type, ...)   __PROP_GENGRP( normals, m_member_id, m_var_type, __VA_ARGS__ )
#define   BIND_NORMS(m_bind_id, m_param_label)            ADD_BIND( normals_##m_bind_id, m_param_label )
#define SETUPD_NORMS(m_bind_id, m_type, s_log_desc)    SETUPD__GRP( normals, normals_##m_bind_id, m_type, s_log_desc )
#define _SETPR_NORMS(m_bind_id, m_type, s_log_desc)    __SETPR_GRP( normals, normals_##m_bind_id, m_type, s_log_desc )
#define _UPDSH_NORMS(m_member_id)                    UPDATE_SHADER( normals_##m_member_id )
#pragma endregion _normals_helper_macros_

#define UPDATE_NORMALS() UPDATE_GROUP(normals)

#define PRIV_NORMALS_VARS()\
	GROUP_VARS(normals)\
	VAR_NORMS(quality,			NormalCalculation,	BY_DISTANCE)\
	VAR_NORMS(distance,			float,	128.0f)

#define PUBLIC_NORMALS_FUNCS()\
	GETR_NORMS(quality,			NormalCalculation)\
	GETR_NORMS(distance,		float)

#define BIND_NORMALS_VARS() \
	BIND_NORMS(quality,			strategy)\
	BIND_NORMS(distance,		range)

#define PROPS_NORMALS()\
	ADD_GROUP("Mesh Normals", "normals_");\
	PROP_NORMS(quality,			INT,	ENUM,  "Pixel,Vertex,By_Distance")\
	PROP_NORMS(distance,		FLOAT,	RANGE, "0.0,1024.0,1., or_greater")\
	ADD_INLINE_HELP(normals, Mesh Normals, About Mesh Normals)

#define MAKE_NORMALS_FUNCTIONS() \
	UPDATE_GRP_START_CON(normals, true)\
		_UPDSH_NORMS(distance)\
	UPDATE_GRP_END()\
	SETUPD_NORMS(quality,		NormalCalculation,	"Quality: ")\
	_SETPR_NORMS(distance,		float,				"Distance: ")

#pragma endregion _NORMALS_
// ################################################################################
#endif