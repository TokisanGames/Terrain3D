
// Structs & Type Definitions
#include "res://addons/terrain_3d/shader/core/t3d_material_def.gdshaderinc"

// [ NOTE: If a custom shader wants to override a mod's standard parameter provider function with a user's custom version, that must happen before this line. ]
#include "res://addons/terrain_3d/shader/core/t3d_managed_uniforms.gdshaderinc"

// Varyings
#include "res://addons/terrain_3d/shader/core/t3d_managed_varyings.gdshaderinc"

// _________________________________
// ** FIRST
// Set this define, so the included files can, when edited, ignore
// references out of scope to certain named globals.
#define __T3D_INTERNAL_GLOBALS_AVAILABLE__
// _________________________________
// ** IMPORT CORE FUNCTIONS
// These define the core internal functions the shader's vertex and fragment functions call.
#include "res://addons/terrain_3d/shader/core/t3d_standard_functions.gdshaderinc"
// **
// [ NOTE ] All requested mods parameter provider functions (or their overrides) must be declared before this line.]
// **
// ** IMPORT ADDITONAL FUNCTIONS
// _________________________________
// ** INCLUDE the prototype non-standard utility functions ( todo: 
// perhaps only include these if defines are detected that require it.  
// For now it's so light weight, it hardly matters. )
//
// #include "res://addons/terrain_3d/shader/proto/t3d_utility.gdshaderinc"
// _________________________________
// ** FEATURE function definition includes, as needed.  These includes
// only define functions, not produce output directly.  Then later, in
// the fragment function, most have a corresponding "..._inline.gdshaderinc"
// file and that gets included in the fragment at the end, and that calls
// the function(s) defined in these files.
//
#if defined(UV_DISTORTION_ENABLED)  // ------------------------------------------
#include "res://addons/terrain_3d/shader/mods/t3d_uv_distort_funcs.gdshaderinc"
#endif  // ----------------------------------------------------------------------
