Performance Tips
====================

Terrain3D is a fully featured terrain system with a lot of features, many of which are disabled by default. The idea is that you can enable what you need so you can balance performance and fidelity. However it's unreasonable to expect to be able to use every feature at the highest fidelity on mobile, web, or older cards, without any optimization of settings.

This page highlights some of the more expensive features and settings that are most important for performance. You can read more about each of them in the API.

**For Mobiles** - High end mobile GPUs are roughly equivalent to 10 year old desktop cards. E.g. An Adreno 750 is considered equivalent to a GTX 1050ti. Everything on this page applies, perhaps moreso because they are resource constrained, and require more tuning and testing by you with your users than the equivalent desktop cards. Of utmost importance though is `Max Regions` found in the [material](#material).


## Textures

The number one performance issue is poor configuration of textures.


### Lack of Mipmaps

In most all cases, your textures should have mipmaps embedded. For PNG files, you can enable mipmap generation on the Godot Import panel. You can tell that you aren't using mipmaps if your terrain is noisy, or by double clicking a texture file in the FileSystem panel and looking at the format reported by Godot. If it has mipmaps, it will say so.

### Uncompressed Textures

Your textures should almost always be compressed. Double click a texture file in the FileSystem panel and look at the format reported by Godot. It should be using BPTC or DXT1/5 for desktop, and S3TC, ETC, ASTC for Mobile. Change it to `VRAM Compressed` on the Godot Import panel.


## VRAM Consumption

You have a limited amount of VRAM, especially on mobile. 3D assets and terrains consume a lot of VRAM. Godot has a VRAM viewer in the debug panel. Run your game and you can look at the 5 unnamed texture arrays used for Heights, Control, Color, Albedo/Heights, Normal/Roughness. The first three are controlled by your [regions](#terrain-regions) below.

The latter two are controlled by your texture size, quantity, and compression method.

The more textures you have and the higher the resolution, the more VRAM is consumed. You'll probably be fine with 1k or 2k textures at most, though 256-512 might be sufficient for mobile. Maybe 4k if targeting very high end. 8k and 16k textures are unnecessary.

We allow 32 textures, but you probably don't even need that many. If your end user systems are constrained, you can and should reuse textures. For instance snow can double as sand and mud by painting wetness/dryness and brown on the colormap. Perhaps you don't need 4 rock or grass types when 1 will do with other tools for variation.


## Foliage

The second most likely performance drain is foliage and materials. Poorly constructed foliage can easily kill your renderer.

* Do you have too many vertices? Reduce vertex count, and create more LODs. Make billboards for the farthest LOD.
* Create clumps of grass or use texture cards instead of individual strands.
* Review LOD configuration. Reduce the view distance of the last LODs to stop rendering the objects sooner. Reduce the max distance of high res LODs to prefer showing lower res LODs sooner.
* Improve textures. All of the above texture issues also apply to your foliage materials. You don't need 8k textures on grass.
* Optimize your shaders. Even the Godot standard material shader has unnecessary features for foliage. Convert it to a shader and remove unnecessary features and lookups that aren't needed.
* Reduce `Last Shadow Lod` to disable shadow casting on farther LOD levels
* Use the `Shadow Imposter` to reduce shadow complexity.

## Terrain Regions

We allow you to have a non-contiguous world with discrete data blocks (regions) located sparsely in a global space of up to 65.5km per side, without having to pay for the whole space in memory. Each region has several data maps inside that are loaded in memory and in VRAM. Here's what you can do to optimize your regions.

* Remove unnecessary regions. Look at the files on disk, and turn on region labels. Ensure only the regions that exist are those you intend to have.
* Reduce region size to cut off any wasted space. If you only want 256m, you don't need a 1024m sized region.
* Segment your world. Does the whole thing need to be loaded at all times? Have part of the world in another scene and load separate regions on different game levels.
* Compress the color map and free the original. If you have no plan to edit the color map or wetness at runtime, compress it under `Regions/Advanced/Color Compress Mode` and `Free Color Map`.

Future Plans:
* Region streaming is being worked on for v1.2 and will allow us to minimize the number of regions in VRAM at any given time.
* 16-bit heights at runtime are being considered.


## Clipmap Meshes

All of these settings are found under `Terrain Mesh` and `Ocean Mesh`. The ocean and terrain do not need to have the same settings at all.

* * Reduce your vertex count and the size of the mesh by reducing `Mesh LODs`, and `Mesh Size`. View the terrain in wireframe mode to see what these do.
* Reduce `Tessellation Level` or set to 0 (default) to completely disable texture displacement.
* Increase `Vertex Spacing` and use fewer regions. This laterally scales your terrain and allows you to have a more low-poly terrain, covering more area for the same VRAM consumption and vertex budget. Ideally, you set this before you sculpt. But if done after, you can export the heightmap and rescale it inversely in photoshop.
* If the lighting design allows it, setting `Cast Shadows` to off can improve performance a lot.


## Culling

* Bake the terrain occluder. We have a whole document on [Occlusion Culling](occlusion_culling.md).
* Bake occluders on all of your other large meshes. 
* Use `Camera3D.far_clip` to cull all distant vertices. This won't work well in an open world with wide vistas. But for a world with limited visibility in any given place, this is an option.


## Rendering

* Don't use `Renderer/Cull Margin`. This expands the AABB of the terrain beyond what is calculated from sculpting the terrain. It should only be needed if using the noise background, which you shouldn't be using on a slower system anyway. Keeping it enabled can cost more processing time.

* Enable `Renderer/free_editor_textures` (default) if you don't need to edit the textures at runtime. It saves VRAM by removing the initial textures used to generate the texture arrays.


## Material

All of these settings are found in the Terrain3DMaterial resource.

The settings live in two sections, delimited by `Custom Shader`:

1. Everything above this are features that change the shader code generated for the material. Features like `Auto Shader`, `World Background`, etc. Turn them all off and test them one at a time. When you enable the custom shader, the features you have enabled are written into the generated shader file that you can modify as desired.

2. Below `Custom Shader` are the uniforms for the enabled features or those found in your custom shader. Some of these settings can impact performance. Turn on the FPS monitor and review them all.

* One key material feature for mobiles is `Max Regions`. This limits the number of regions the material will render. Reduce it to the minimum needed to render your world. It does not save VRAM; your GPU will still store all of the regions you have allocated. This setting reduces the amount of the uniform buffer we consume. Some mobiles have a severe lack of uniform buffer space and fail to render if overrun.

* In `Texture Filtering`, disabling anisotropic filtering can help on lower end hardware. You can then compensate for texture blurriness with mipmap bias in the shader uniforms. Or disable both. These two settings may do nothing for performance at all, so test it.


## Shader

The default shader generated by the material feature selections is very complex and optimized for desktop. As discussed above, change the features and generate the shader before enabling custom shader and it will generate one you can modify as much as you like.

We offer a `lightweight` shader in `extras/shaders`, which is designed to be the minimum possible amount of texture lookups, while still providing basic texturing, including height blending. Normals are also fully calculated in `vertex()`. This shader removes advanced features like projection, detiling, and paintable rotation and scale for significant performance gains on low-end hardware, mobile, and VR applications. This is a base example you can build on.

Finally, you can use the `minimum` shader in `extras/shaders` which demonstrates the minimum code needed to allow the clipmap terrain to function so you can craft your own texturing and coloring from scratch.


## Backgrounds

How you choose to represent your background has a major impact on performance. Using the terrain for background is not necessarily the best choice.

In the material, we offer three modes for `World Background`: `None` is the cheapest, `Flat` is the middle, and `Noise` is the most expensive. Noise enables the `World Background Noise` uniforms which can greatly impact fidelity and performance.

We also offer an ocean mesh, and a separate Sky3D plugin which can fill out your background.

So, depending on your game you could reasonably do any of the following and more depending on how creative you can be. Commercial games have used all of these methods. The first two are the most expensive.
* Terrain regions and sculpted/heightmap based mountains fully surrounding your level - highest detail, but a waste if not traversable.
* World Background = Noise, a shader based background without collision, with or without ocean extending to the horizon
* World Background = Flat/None with:
  * An HDR skybox with mountains built into it
  * Mesh mountains made in blender
  * Ocean extending to the horizon
  * Thick fog obscuring the horizon, with the camera far clip set just beyond the fog
  * A second Terrain3D node with large vertex scaling to make low poly mountains


## Future Plans

In the future, we anticipating building the following features that we anticipate will improve performance:
* [Region Streaming](https://github.com/TokisanGames/Terrain3D/issues/491)
* [Runtime Virtual Texture](https://github.com/TokisanGames/Terrain3D/issues/245)
* Compute - though not it won't help viewing, it will improve the content creation pipeline
