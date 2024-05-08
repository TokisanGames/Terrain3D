#pragma once

#ifndef TERRAIN3D_DEBUG_VIEWS_H
#define TERRAIN3D_DEBUG_VIEWS_H

//Code Templates for Terrain3D Managed GLSL/Godot DEBUG_VIEWS Properties

// ################################################################################
#pragma region _DEBUG_VIEWS_
// *****************
// ** DEBUG_VIEWS **
// *****************

#pragma region _HELP_
#define HELP_DEBUG()\
	ADD_HELP_TOPIC_DECL(debug_views, R"(
There are multiple modes of viewing the terrain for debuging different characteristics.

[ Autoshader ] 
Display the area designated for use by the autoshader, which shows materials based upon slope.

[ Checkered ] 
Shows a checkerboard display using a shader rendered pattern. This is turned on if the 
Texture List is empty. Note that when a blank texture slot is created, a 1k checkerboard 
texture is generated and stored in the texture slot. That takes VRAM. The two patterns 
have a slightly different scale.

[ Colormap ] 
Places the color map in the albedo channel.

[ Control Blend ] 
Albedo shows the blend value used to blend the base and overlay textures as greyscale. This 
is especially helpful to see how the noise texture adjusts the blending edges.

[ Control Texture ] 
Albedo shows the base and overlay texture indices defined by the control map. Red pixels 
indicate the base texture, with brightness showing texture ids 0 to 31. Green pixels 
indicate the overlay texture. Yellow indicates both.

[ Grey ] 
Albedo is set to 0.2 grey.

[ Heightmap ] 
Albedo is a white to black gradient depending on height. The gradient is scaled to a height 
of 300, so above that or far below 0 will be all white or black.

[ Navigation ] 
Displays the area designated for generating the navigation mesh.

[ Roughmap ] 
Albedo is set to the roughness modification map as grey scale. Middle grey, 0.5 means no 
roughness modification. Black would be high gloss while white is very rough.

[ Texture Height ] 
Albedo is set to the painted Height textures.

[ Texture Normal ] 
Albedo is set to the painted Normal textures.

[ Texture Rough ] 
Albedo is set to the painted Roughness textures. This is different from the roughness 
modification map above.

[ Vertex Grid ] 
Show a grid on the vertices, overlaying any above shader.
)")
#pragma endregion _HELP_

#define GETR_DEBUG(m_bind_id) GSTR(debug_view_##m_bind_id, bool)
#define VAR_DEBUG(m_bind_id) VARR(debug_view_##m_bind_id, bool, false)
#define PROP_DEBUG(m_member_id) __PROP_GENGRP( debug_view, m_member_id, BOOL, NONE )
#define BIND_DEBUG(m_bind_id) ADD_BIND(debug_view_##m_bind_id, enabled) 

#define GETR_DEBUG_VEC3(m_bind_id) GSTR(debug_view_##m_bind_id, Vector3)
#define VAR_DEBUG_VEC3(m_bind_id) VARR(debug_view_##m_bind_id, Vector3, Vector3())
#define PROP_DEBUG_VEC3(m_member_id) __PROP_GENGRP( debug_view, m_member_id, VECTOR3, NONE )
#define BIND_DEBUG_VEC3(m_bind_id) ADD_BIND(debug_view_##m_bind_id, vector) 

#define GETR_DEBUG_FLOAT(m_bind_id) GSTR(debug_view_##m_bind_id, float)
#define VAR_DEBUG_FLOAT(m_bind_id) VARR(debug_view_##m_bind_id, float, 0.0f)
#define PROP_DEBUG_FLOAT(m_member_id) __PROP_GENGRP( debug_view, m_member_id, FLOAT, NONE )
#define BIND_DEBUG_FLOAT(m_bind_id) ADD_BIND(debug_view_##m_bind_id, float) 

#define _UPDSH_DEBUG(m_member_id)					 UPDATE_SHADER( debug_view_##m_member_id )

#define UPDATE_DEBUG_VIEW() UPDATE_GROUP(debug_view)

#define PRIV_DEBUG_VIEW_VARS()\
	GROUP_VARS(debug_view)\
	VAR_DEBUG(navigation)\
	VAR_DEBUG(checkered)\
	VAR_DEBUG(grey)\
	VAR_DEBUG(heightmap)\
	VAR_DEBUG(colormap)\
	VAR_DEBUG(roughmap)\
	VAR_DEBUG(control_texture)\
	VAR_DEBUG(control_blend)\
	VAR_DEBUG(autoshader)\
	VAR_DEBUG(holes)\
	VAR_DEBUG(texture_height)\
	VAR_DEBUG(texture_normal)\
	VAR_DEBUG(texture_rough)\
	VAR_DEBUG(vertex_grid)

#define PUBLIC_DEBUG_VIEW_FUNCS()\
	GETR_DEBUG(navigation)\
	GETR_DEBUG(checkered)\
	GETR_DEBUG(grey)\
	GETR_DEBUG(heightmap)\
	GETR_DEBUG(colormap)\
	GETR_DEBUG(roughmap)\
	GETR_DEBUG(control_texture)\
	GETR_DEBUG(control_blend)\
	GETR_DEBUG(autoshader)\
	GETR_DEBUG(holes)\
	GETR_DEBUG(texture_height)\
	GETR_DEBUG(texture_normal)\
	GETR_DEBUG(texture_rough)\
	GETR_DEBUG(vertex_grid)

#define BIND_DEBUG_VIEW_VARS() \
	BIND_DEBUG(checkered)\
	BIND_DEBUG(grey)\
	BIND_DEBUG(heightmap)\
	BIND_DEBUG(colormap)\
	BIND_DEBUG(roughmap)\
	BIND_DEBUG(control_texture)\
	BIND_DEBUG(control_blend)\
	BIND_DEBUG(autoshader)\
	BIND_DEBUG(holes)\
	BIND_DEBUG(navigation)\
	BIND_DEBUG(texture_height)\
	BIND_DEBUG(texture_normal)\
	BIND_DEBUG(texture_rough)\
	BIND_DEBUG(vertex_grid)

#define PROPS_DEBUG_VIEW()\
	ADD_GROUP("Debug Views", "debug_view_");\
	PROP_DEBUG(checkered)\
	PROP_DEBUG(grey)\
	PROP_DEBUG(heightmap)\
	PROP_DEBUG(colormap)\
	PROP_DEBUG(roughmap)\
	PROP_DEBUG(control_texture)\
	PROP_DEBUG(control_blend)\
	PROP_DEBUG(autoshader)\
	PROP_DEBUG(holes)\
	PROP_DEBUG(navigation)\
	PROP_DEBUG(texture_height)\
	PROP_DEBUG(texture_normal)\
	PROP_DEBUG(texture_rough)\
	PROP_DEBUG(vertex_grid)\
	ADD_INLINE_HELP(debug_views, Debug Views, About Debug View Modes)

#define MAKE_DEBUG_VIEW_FUNCTIONS() \
	UPDATE_DEBUG_OPT(checkered)\
	UPDATE_DEBUG_OPT(grey)\
	UPDATE_DEBUG_OPT(heightmap)\
	UPDATE_DEBUG_OPT(colormap)\
	UPDATE_DEBUG_OPT(roughmap)\
	UPDATE_DEBUG_OPT(control_texture)\
	UPDATE_DEBUG_OPT(control_blend)\
	UPDATE_DEBUG_OPT(autoshader)\
	UPDATE_DEBUG_OPT(holes)\
	UPDATE_DEBUG_OPT(navigation)\
	UPDATE_DEBUG_OPT(texture_height)\
	UPDATE_DEBUG_OPT(texture_normal)\
	UPDATE_DEBUG_OPT(texture_rough)\
	UPDATE_DEBUG_OPT(vertex_grid)

#pragma endregion _DEBUG_VIEWS_ 
// ################################################################################

#endif