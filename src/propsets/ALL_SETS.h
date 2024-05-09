#pragma once

#ifndef TERRAIN3D_ALL_PROPSETS_H
#define TERRAIN3D_ALL_PROPSETS_H

#include "propsets/__PROPSETS.h"

//Code Templates for Terrain3D Managed GLSL/Godot Properties

// ################################################################################

#include "propsets/_BLENDING.h"
#include "propsets/_MULTI_SCALING.h"
#include "propsets/_BG_WORLD.h"
#include "propsets/_TINTING.h"
#include "propsets/_AUTO_TEXTURING.h"
#include "propsets/_UV_DISTORTION.h"
#include "propsets/_NORMALS.h"
#include "propsets/_DEBUG_VIEWS.h"

// ################################################################################
// ## MISC ##
// ################################################################################
// It's critical that this help entry for shader override is defined but currently 
// the shader override group itself is not fully managed, so to make sure this is 
// defined, it's here with the all set.
#define __help_defined_for_shader_override
#define HELP_SHADER_OVERRIDE()\
	ADD_HELP_TOPIC_DECL(shader_override, R"(
If shader_override_enabled is true and the Shader field is valid, the material will use 
that custom shader code. If it is blank when you enable the override, the system 
will generate a shader with the current settings. 

Terrain3D is now using shader include files for most dynamic functionality, with 
#defines to enable or disable certain functions.  So the generated shader is (mostly) 
static, you just add or remove defines to features on or off.  Take care not to 
position your code within the header area, as that does get dynamically parsed out 
and replaced as current settings are changed.  There is a comment in the shader code 
marking where that region ends.

A visual shader will also work here.(?see note *) However we only generate a text 
based shader so currently a visual shader needs to be constructed with the base code 
before it can work. (*) ( To-do: Confirm this is all fine since changing to includes ) 

Known Issues: 

Problem: Toggling any options on and off with a custom shader enabled and currently open in the 
Godot shader editor does not work, the options don't apply. 

Fix: You must close the file in the editor, then change the checkbox again, then it will apply. 
This may change in the future.  Alternatively, toggling the custom shader as enabled 
or not may force it to update.

Problem: When toggled an option in the material options, custom user code is lost in their 
custom shader.

Fix: Do not put any custom code within the header above the line marked __END_HEADER__. 
Every time an option is changed, that portion is removed and replace with current settings. 
Also,  it's good to put your custom code within a gdshaderinc file, then include that from 
within the generated shader, so if ever this happens it's not a big deal.
)" )

// ################################################################################

#pragma region _ALL_SETS_FUNCTIONS_

// These macros are used to group clusters of related management functions into
// one call, for clarity and compartmentalization.

// This is called by PRIVATE_MANAGED_VARS() below, from the class .h files private 
// section. It defines the functions that will provide the values to the placeholder 
// in-line "help" textareas.
#define __MAKE_MANAGED_HELP()\
	HELP_BG_WORLD()\
	HELP_BLEND()\
	HELP_NORMS()\
	HELP_TINTING()\
	HELP_MULTI()\
	HELP_AUTO_TEXTURING()\
	HELP_UVDIST()\
	HELP_DEBUG()\
	HELP_SHADER_OVERRIDE()

// This generates all of the actual functions within the class .cpp file.
#define MAKE_MANAGED_FUNCTIONS()\
	MAKE_BG_WORLD_FUNCTIONS()\
	MAKE_BLENDING_FUNCTIONS()\
	MAKE_NORMALS_FUNCTIONS()\
	MAKE_TINTING_FUNCTIONS()\
	MAKE_MULTI_SCALING_FUNCTIONS()\
	MAKE_AUTO_TEXTURING_FUNCTIONS()\
	MAKE_UV_DISTORTION_FUNCTIONS()\
	MAKE_DEBUG_VIEW_FUNCTIONS()

// This binds the necessary get/set functions for each managed property group.
#define BIND_MANAGED_VARS()\
	BIND_BG_WORLD_VARS()\
	BIND_BLENDING_VARS()\
	BIND_NORMALS_VARS()\
	BIND_TINTING_VARS()\
	BIND_MULTI_SCALING_VARS()\
	BIND_AUTO_TEXTURING_VARS()\
	BIND_UV_DISTORTION_VARS()\
	BIND_DEBUG_VIEW_VARS()

// This adds the managed properties to the Godot extension.  For sanity purposes, 
// it's probably best to call this after BIND_MANAGED_VARS, but I'm not sure 
// it really matters.
#define ADD_MANAGED_PROPS()\
	PROPS_BG_WORLD()\
	PROPS_BLENDING()\
	PROPS_NORMALS()\
	PROPS_TINTING()\
	PROPS_MULTI_SCALING()\
	PROPS_AUTO_TEXTURING()\
	PROPS_UV_DISTORTION()\
	PROPS_DEBUG_VIEW()

#define PRIVATE_MANAGED_VARS()\
	PRIV_BG_WORLD_VARS()\
	PRIV_BLENDING_VARS()\
	PRIV_NORMALS_VARS()\
	PRIV_TINTING_VARS()\
	PRIV_MULTI_SCALING_VARS()\
	PRIV_AUTO_TEXTURING_VARS()\
	PRIV_UV_DISTORTION_VARS()\
	PRIV_DEBUG_VIEW_VARS()

#define PUBLIC_MANAGED_FUNCS()\
	__MAKE_MANAGED_HELP()\
	PUBLIC_BG_WORLD_FUNCS()\
	PUBLIC_BLENDING_FUNCS()\
	PUBLIC_NORMALS_FUNCS()\
	PUBLIC_TINTING_FUNCS()\
	PUBLIC_MULTI_SCALING_FUNCS()\
	PUBLIC_AUTO_TEXTURING_FUNCS()\
	PUBLIC_UV_DISTORTION_FUNCS()\
	PUBLIC_DEBUG_VIEW_FUNCS()

#define UPDATE_MANAGED_VARS()\
	UPDATE_BG_WORLD()\
	UPDATE_BLENDING()\
	UPDATE_NORMALS()\
	UPDATE_TINTING()\
	UPDATE_MULTI_SCALING()\
	UPDATE_AUTO_TEXTURING()\
	UPDATE_UV_DISTORTION()

#pragma endregion _ALL_SETS_FUNCTIONS_
// ################################################################################

#endif