#pragma once

#ifndef TERRAIN3D_BG_WORLD_H
#define TERRAIN3D_BG_WORLD_H

//Code Templates for Terrain3D Managed GLSL/Godot BG_WORLD Properties

// ################################################################################
#pragma region _BG_WORLD_
// *****************
// ** BG_WORLD **
// *****************

#pragma region _HELP_
#define HELP_BG_WORLD()\
	ADD_HELP_TOPIC_DECL(bg_world, R"(
Terrain3D can automatically generate a background world of rolling hills, 
plains and mountains if you'd like.  You can adjust the overall size of 
the landforms, their maximum height, a height and position offset, and 
how detailed they are with min/max octaves settings.  Take care you 
don't raise octaves so much it impacts frame rate.
)")
#pragma endregion _HELP_

#pragma region _bg_world_helper_macros_
#define   GETR_WORLD(m_bind_id, m_type)					     GSTR( bg_world_##m_bind_id, m_type )
#define    VAR_WORLD(m_bind_id, m_type, m_value)		     VARR( bg_world_##m_bind_id, m_type##, m_value )
#define   PROP_WORLD(m_member_id, m_var_type, ...)  __PROP_GENGRP( bg_world, m_member_id, m_var_type, __VA_ARGS__ )
#define   BIND_WORLD(m_bind_id, m_param_label)		     ADD_BIND( bg_world_##m_bind_id, m_param_label )
#define SETUPD_WORLD(m_bind_id, m_type, s_log_desc)	  SETUPD__GRP( bg_world, bg_world_##m_bind_id, m_type, s_log_desc )
#define _SETPR_WORLD(m_bind_id, m_type, s_log_desc)	  __SETPR_GRP( bg_world, bg_world_##m_bind_id, m_type, s_log_desc )
#define _UPDSH_WORLD(m_member_id)				    UPDATE_SHADER( bg_world_##m_member_id )
#pragma endregion _bg_world_helper_macros_

#define UPDATE_BG_WORLD() UPDATE_GROUP(bg_world)

#define PRIV_BG_WORLD_VARS()\
	GROUP_VARS(bg_world)\
	VAR_WORLD(fill,	WorldBackground,	FLAT)\
	VAR_WORLD(max_octaves,		int,	6)\
	VAR_WORLD(min_octaves,		int,	3)\
	VAR_WORLD(lod_distance,		float,	2500.0f)\
	VAR_WORLD(scale,			float,	5.0f)\
	VAR_WORLD(height,			float,	64.0f)\
	VAR_WORLD(offset,			Vector3,Vector3())\
	VAR_WORLD(blend_near,		float,	0.5f)\
	VAR_WORLD(blend_far,		float,	1.0f)

#define PUBLIC_BG_WORLD_FUNCS()\
	GETR_WORLD(fill,	WorldBackground)\
	GETR_WORLD(max_octaves,		int)\
	GETR_WORLD(min_octaves,		int)\
	GETR_WORLD(lod_distance,	float)\
	GETR_WORLD(scale,			float)\
	GETR_WORLD(height,			float)\
	GETR_WORLD(offset,			Vector3)\
	GETR_WORLD(blend_near,		float)\
	GETR_WORLD(blend_far,		float)

#define BIND_BG_WORLD_VARS() \
	BIND_WORLD(fill,			background)\
	BIND_WORLD(max_octaves,		octaves)\
	BIND_WORLD(min_octaves,		octaves)\
	BIND_WORLD(lod_distance,	distance)\
	BIND_WORLD(scale,			size)\
	BIND_WORLD(height,			height)\
	BIND_WORLD(offset,			offset)\
	BIND_WORLD(blend_near,		range)\
	BIND_WORLD(blend_far,		range)

#define PROPS_BG_WORLD()\
	ADD_GROUP("Background World", "bg_world_");\
	PROP_WORLD(fill,			INT,	ENUM,  "None,Flat,Noise")\
	PROP_WORLD(max_octaves,		INT,	RANGE, "0, 15, 1")\
	PROP_WORLD(min_octaves,		INT,	RANGE, "0, 15, 1")\
	PROP_WORLD(lod_distance,	FLOAT,	RANGE, "0.0, 40000.0, 1.0")\
	PROP_WORLD(scale,			FLOAT,	RANGE, "0.25, 20.0, 0.01")\
	PROP_WORLD(height,			FLOAT,	RANGE, "0.0, 1000.0, 0.1")\
	PROP_WORLD(offset,			VECTOR3,NONE)\
	PROP_WORLD(blend_near,		FLOAT,	RANGE, "0.0, 0.95, 0.01")\
	PROP_WORLD(blend_far,		FLOAT,	RANGE, "0.05, 1.0, 0.01")\
	ADD_INLINE_HELP(bg_world, Background World, About Generated Background Worlds)

#define MAKE_BG_WORLD_FUNCTIONS() \
	UPDATE_GRP_START_CON(bg_world, true)\
		_UPDSH_WORLD(fill)\
		_UPDSH_WORLD(max_octaves)\
		_UPDSH_WORLD(min_octaves)\
		_UPDSH_WORLD(lod_distance)\
		_UPDSH_WORLD(scale)\
		_UPDSH_WORLD(height)\
		_UPDSH_WORLD(offset)\
		_UPDSH_WORLD(blend_near)\
		_UPDSH_WORLD(blend_far)\
	UPDATE_GRP_END()\
	SETUPD_WORLD(fill,			WorldBackground, "Fill: ")\
	_SETPR_WORLD(max_octaves,	int,	"Max Octaves: ")\
	_SETPR_WORLD(min_octaves,	int,	"Min Octaves: ")\
	_SETPR_WORLD(lod_distance,	float,	"LOD Distance: ")\
	_SETPR_WORLD(scale,			float,	"Scale: ")\
	_SETPR_WORLD(height,		float,	"Height: ")\
	_SETPR_WORLD(offset,		Vector3,"Offset: ")\
	_SETPR_WORLD(blend_near,	float,	"Blend Near: ")\
	_SETPR_WORLD(blend_far,		float,	"Blend Far: ")

#pragma endregion _BG_WORLD_
// ################################################################################
#endif