R"(
//INSERT: HEADER_START_MARK
// MARK:__START_HEADER__

//INSERT: HEADER
shader_type spatial;
render_mode blend_mix,depth_draw_opaque,cull_back,diffuse_burley,specular_schlick_ggx;

/* This shader is generated based upon the debug views you have selected.
 * The terrain function depends on this shader. So don't change:
 * - vertex positioning in vertex()
 * - terrain normal calculation in fragment()
 * - the last function being fragment() as the editor injects code before the closing }
 *
 * Most will only want to customize the material calculation and PBR application in fragment()
 *
 * Uniforms that begin with _ are private and will not display in the inspector. However, 
 * you can set them via code. You are welcome to create more of your own hidden uniforms.
 *
 * This system only supports albedo, height, normal, roughness. Most textures don't need the other
 * PBR channels. Height can be used as an approximation for AO. For the rare textures do need
 * additional channels, you can add maps for that one texture. e.g. an emissive map for lava.
 *
 */

// ** STANDARD HEADER **
#include "res://addons/terrain_3d/shader/core/t3d_standard_header.gdshaderinc"

//INSERT: HEADER_END_MARK_NOTICE
// -------------------------------------------------------------------------
// * Note, any code above this line will be removed the next time any change
// is made to the shader parameters, or it reloads for whatever reason.  Do
// not remove or alter the line below or anything above.
// ----------------------------------------------------
//INSERT: HEADER_END_MARK
//MARK:__END_HEADER__
)"