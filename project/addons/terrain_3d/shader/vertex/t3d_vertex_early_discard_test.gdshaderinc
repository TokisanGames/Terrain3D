// !! NOTE: After including this file, be sure there is a valid code block within curly braces,
// because it finishes with an "if...else" and the code block after is for vertices that
// passed this early discard test.
// --------------------------------------------------------------------------------------
// * Placeholder function / variable defs to appease syntax highlighter in Godot:
// --------------------------------------------------------------------------------------
#if !defined(__T3D_INTERNAL_GLOBALS_AVAILABLE__)
void placeholder_func_EARLY_DISCARD_TEST() {
// * External parameters:
const uint _CONTROL = 0u;
const uint _bg_world_fill = 1u;
const uint CAMERA_VISIBLE_LAYERS = 1u;
const uint _mouse_layer = 1u;
const ivec3 v_region = ivec3(0u);

// * Local changes to:
vec3	VERTEX	= vec3(0.); // In this code portion, VERTEX may be written to, to invalidate it.
// * Original source of:
// bool	_HOLE : No set use for this yet but it's available as needed for the remaineder of the vertex function.
// float _FRV : a floating point version of this regions index value, some branches use this later in vertex().
#endif
// --------------------------------------------------------------------------------------
// BEGIN EARLY DISCARD TEST
// --------------------------------------------------------------------------------------
	// Discard vertices for Holes. 1 lookup
	uint _rv=uint(clamp(v_region.z+1,0,1));
	float _FRV=float(_rv);
	// This check is used locally and exported for other vertex modules (or the end-user) to use
	bool _HOLE = bool(_CONTROL >>2u & 0x1u);
	
	// Show holes to all cameras except mouse camera (on exactly 1 layer)
	if (!(CAMERA_VISIBLE_LAYERS == _mouse_layer) 
		&& (_HOLE || (_bg_world_fill + _rv == 0u)) ) {
		VERTEX.x = 0./0.; } 
	else 
// --------------------------------------------------------------------------------------
// END EARLY DISCARD TEST
// --------------------------------------------------------------------------------------
#if !defined(__T3D_INTERNAL_GLOBALS_AVAILABLE__)
{ }
}
#endif