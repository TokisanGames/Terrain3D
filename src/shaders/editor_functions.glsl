// Copyright © 2023 Cory Petkovsek, Roope Palmroos, and Contributors.

// These EDITOR_* are special inserts that injected into the shader code before the last `}`
// which is assumed to belong to fragment()

R"(
//INSERT: EDITOR_NAVIGATION
	// Show navigation
	if(bool(texelFetch(_control_maps, get_region_uv(floor(UV)), 0).r >>1u & 0x1u)) {
		ALBEDO *= vec3(.5, .0, .85);
	}

)"