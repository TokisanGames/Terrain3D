// Copyright (c) 2023 Cory Petkovsek, Roope Palmroos, and Contributors.
//
#if !defined(__T3D_MANAGED_VARYINGS_AVAILABLE__)
#define __T3D_MANAGED_VARYINGS_AVAILABLE__
// -----------------------------------------------------------------------------
// This file is isolated from the rest of the header to make it easier to track
// any changes or additions to the varying's over time, and to run tests to make 
// sure they can properly toggle optional elements in/out of the shader without
// causing issues for other functionality.
// *****************************************************************************
varying flat	vec3	v_vertex;	// World coordinate vertex location
varying flat	vec3	v_camera_pos;
varying flat	ivec3	v_region;
varying flat	vec2	v_uv_offset;
varying flat	vec2	v_uv2_offset;
// ---
varying vec3	v_normal;
varying float	v_vertex_xz_dist;
varying float	v_region_border_mask;
// ---
#if defined(UV_DISTORTION_ENABLED)  // ------------------------------------------
varying vec2	v_uvdistort;
#endif  // ----------------------------------------------------------------------
// *****************************************************************************
// END: MANAGED VARYINGS
// -----------------------------------------------------------------------------
#endif