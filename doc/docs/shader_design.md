Shader Design
==============

Our shader combines a lot of ideas and code from [cdxntchou's IndexMapTerrain](https://github.com/cdxntchou/IndexMapTerrain) for Unity, [Zylann's HTerrain](https://github.com/Zylann/godot_heightmap_plugin/) for Godot, the Witcher 3 talk linked in the System Design page, and our own thoughts and optimizations.

In the material, you can enable `shader_override_enabled` with an empty `shader overide` slot and it will generate the default shader code so you can follow along with this document. You can also find the minimum shader needed to enable the terrain height functionality without texturing in `addons/terrain_3D/extras/minimum.gdshader`.

At its core, the current texture painting and rendering system is a vertex painter, not a pixel painter. We paint codes at each vertex, 1m apart by default, represented as a pixel on the [Control map](controlmap_format.md). The shader uses its many parameters to control how each pixel between the vertices blend together. For an artist, it's not as nice to use as a multi-layer, pixel based painter you might find in Photoshop, but the dynamic nature of the system does afford other benefits.

The following describes the various elements of the shader in a linear fashion to help you understand how it works.


## Texture Lookup Methods

First some terminology and notes about the various methods used to retreive a texture value. 

A `pixel` is a colored dot on your screen (aka `picture element`). A `texel` is a colored dot on a texture in memory (aka a `texture pixel`). When a grey value is read from a rock texture, it's a texel. When it is projected on a rock mesh with lighting and rendered on your screen, it's a pixel.

The GPU does a lot of work for gamedevs when using the standard lookup function `texture()`, such as calculating which mipmap level to use and automatically interpolating surrounding texels. A lot of this work we don't want done automatically and instead do it ourselves so we can optimize or reuse some of the process. 

Here's a quick summary of potential operations we might use to retreive a texel:

* `texture()` - We provide UVs. The GPU calculates UV derivatives and mipmap LOD, then returns an interpolated value.
* `textureGrad()` - We provide UV derivatives. The GPU calculates mipmap LOD and returns an interpolated value.
* `textureLod()` - We provide UVs and mipmap LOD. The GPU returns an interpolated value.
* `texelFetch()` - We provide UVs and mipmap LOD. The GPU returns the texel.

`texture*()` functions interpolate from multiple samples of the texture map if linear filtering is enabled. Using either nearest filtering or texelFetch() disables interpolation.


## Uniforms

[Terrain3DMaterial](../api/class_terrain3dmaterial.rst) exposes uniforms found in the shader, including any you have added. Uniforms that begin with `_` are considered private and are hidden, but you can still access them via code. See [Tips](tips.md#accessing-private-shader-variables).

These notable [Terrain3DData](../api/class_terrain3ddata.rst) arrays are passed in as uniforms. The API has more information on each.
* [_region_map](../api/class_terrain3ddata.rst#class-terrain3ddata-method-get-region-map), [_region_locations](../api/class_terrain3ddata.rst#class-terrain3ddata-property-region-locations) store the location and ID of each region
* [_height_maps](../api/class_terrain3ddata.rst#class-terrain3ddata-property-height-maps), [_control_maps](../api/class_terrain3ddata.rst#class-terrain3ddata-property-control-maps), and [_color_maps](../api/class_terrain3ddata.rst#class-terrain3ddata-property-color-maps) store the elevation, texture layout, and colors of the terrain, indexed by region ID
* [_texture_array_albedo](../api/class_terrain3dassets.rst#class-terrain3dassets-method-get-albedo-array-rid), [_texture_array_normal](../api/class_terrain3dassets.rst#class-terrain3dassets-method-get-normal-array-rid) store the ground textures, indexed by texture ID


## Vertex() & Supporting Functions

The CPU has already created flat mesh components that make up the clipmap mesh, and collision shapes with heights. The vertex shader adjusts the mesh to match the collision shape defined by the heightmap. `vertex()` is run for every vertex on these mesh components.

Noteworthy supporting functions include `get_region_uv/_uv2()` which take in UV coordinates and return region coordinates, either real or normalized. They also return the region ID, which indexes into the texture arrays.

Within `vertex()`, the controlmap is read to determine if a vertex is a hole, the heightmap is read if valid, and if world noise should be calculated. The values are accumulated to determine the final height, and vertex normal.

If the optional world noise is enabled, it generates fractal brownian noise which can be used as background hills outside of your regions. It's a visual only effect, can be costly at high octaves, and does not generate collision.

As `render_mode skip_vertex_transform` is used, we apply the necessary matrix transforms to set the final `VERTEX` position, matching the collision mesh.


## Fragment()

`fragment()` is run for every screen pixel in which the terrain mesh appears on screen. This is many more times than the number of vertices.


### Grid Offsets, Weights and Derivatives

Features like UV rotation, UV scale, detiling, and projection break the continuity of texture UVs. So we must use `textureGrad()` and provide the derivatives for it. We take 1 set of `dfdx(uv)` and `dFdy(uv)` saved in `base_derivatives` and then scale them as needed.

The lookup grid and blend weights are initially calculated here, as they are used for both normals, and material lookups. 

To see the grid, add this at the end of the shader `ALBEDO *= vec3(round(weight), 0.0) + .5;` which shows horizontal stripes in red, and vertical stripes in green. The inverse is stored in `invert`, so where horizontal stripes alternate `red, black, red`, this has `black, red, black`. You can see the vertices if you enable `Debug Views / Vertex Grid`, as shown.

```{image} images/sh_mirror.png
:target: ../_images/sh_mirror.png
```

A determination is made with the base derivatives, of whether it is reasonable to skip all additional lookups required to do the bilinear blend. Skipping this can save a significant amount of bandwidth and processing for the GPU depending on how much of the screen is occupied by distant terrain. It's worth noting that as this is calculated from screen space derivatives, it is independent of screen resolution.


### Normal Calculation

The next step is calculating the terrain normals. Clipmap terrain vertices are farther apart at lower LODs, causing certain things like normals to look strange when viewed in the distance. Because of this, we calculate normals by taking derivatives from the heightmap in `fragment()`.

We use `texelFetch()` to read the height values on each vertex without any automatic interpolation. These values are used to generate a set of normals per-index, and an interpolated value for smooth normals. Using `texture()` here would not only trigger many additional lookups of adjacent vertices for interpolation, but also create artifacts when interpolating across region boundaries.

Generating normals in the shader works fine, and modern GPUs can easily handle the load of the additional height lookups and the on-the-fly calculations. Doing this saves 3-4MB VRAM per region (sized at 1024) instead of pre-generating a normal map and passing it to the shader.


### Material Creation

Next, the control maps are queried for each of the 4 grid points and stored in `control[0]`-`control[3]`. The control map bit packed format is defined in [Controlmap Format](controlmap_format.md). 

The textures at each point are looked up and stored in an array of structs. If there is an overlay texture, the two are height-blended here. Then the pixel position within the 4 grid points is bilinearly interpolated to get the weighting for the final pixel values.

Where possible, texture lookups are branched and in some cases only 2 samples are required, bringing VRAM bandwith requirements to a minimum.


### Texture Sampling - Splat Map vs Index Map

This analysis compares the *splat map* method used by many other terrain systems with an *index map* method, used by Terrain3D and [cdxntchou's IndexMapTerrain](https://github.com/cdxntchou/IndexMapTerrain).

At their core, all height map based terrain tools are just fancy painting applications. For texturing, the "reasonable" approach would be to define a strength value for each texture ID at each pixel and blend them together as occurs when painting in Photoshop. Subtly brushing with red gradually increases the R in the RGB value of the pixel. This is how a splat map works, but instead of painting with just RGBA, it paints with RGBACDEFHIJKLMNO (for 16 textures). The "unreasonable" approach would be to use an entirely different methodology in order to reduce memory or increase speed.

The **Splat map approach** specifies an 8-bit strength value for each texture. 16 textures fits into 4 splat maps each made up of 32-bit RGBA values, for a total of 16 bytes. Double for 32 textures.  

When rendering, all splat maps are sampled, and of the 16-32 values, the 4 strongest are blended together, per terrain pixel. The blending of textures for pixels drawn between vertices is handled by the GPU's linear interpolated texture filter during texture lookups.

The **Index map approach** samples a control map at 4 fixed grid points surrounding the current terrain pixel. The 4 surrounding samples have a base texture, an overlay texture, and a blending value. The base and overlay texture values range from 0-31, each stored in 5 bits. The blend values are stored in 8-bits.

The position of the pixel within its grid square is used to bilinearly interpolate the values of the 4 surrounding samples. We disable the default GPU interpolation on texture lookups and interpolate ourselves here. At distances where the the bilinear blend would occur across only 1 pixel in sceen space, the blend is skipped, requiring only 1/4 of the normal samples.

**Comparing the two methods:**

* **Texture lookups** - Considering only lookups for which ground texture to use and loading the texture data:
  * Splat maps use 12-16 lookups per pixel depending on 16 or 32 textures:
    * 4-8 to get the 4 strongest texture IDs. 4 for 16 textures, 8 for 32. This retreives the texture ID for the closest vertex point.
    * 8 for the strongest 4 albedo_height textures and the 4 normal_rough textures
  * Terrain3D uses 5-20 lookups per pixel depending on terrain distance:
    * 1-4 for the surrounding 4 grid points on the control map.
    * 4-16 for the 2-4 albedo_height & normal_rough for the base and overlay textures, for each of the 4 grid points.

* **VRAM consumed** 
  * Splat maps store 16 texture strength values in 16 bytes per pixel, or 32 in 32 bytes per pixel. On a 4096k terrain with 16M pixels, splat maps consume 256MB for 16 textures, 512MB for 32.
  * Terrain3D stores 32 texture strengths in 18-bits. 5-bit base ID, 5-bit overlay ID, 8-bit blend value. We can store texture layout for 32 textures on a 4k terrain in only 36MB, for a 93% reduction in VRAM. 
 

The calculations above consider only the portion of lookups and VRAM used by the data that defines where textures are place on the terrain. In practical use there are many other features that greatly adjust both.

As for usage of the two techniques:

* Splat maps - 4 textures can be blended intuitively as one would paint in Photoshop. Some systems might introduce artifacts when 3-4 textures are blended in an area.

* Terrain3D - Only 2 textures can stored in a vertex. However pixels are interpolated between the 4 adjacent vertices, so can easily blend between up to 4 textures based on painted blend value, height textures, and material settings. Thus getting a natural looking blend is easily doable if textures are properly setup with heights, using [the right technique](texture_painting.md#manual-painting-technique).


### Calculating Weights & Applying PBR

Since each terrain pixel exists within four points on a grid, we can use bilinear interpolation to calculate weights based on how close we are to each grid point. e.g. The current pixel is 75% to the next X and 33% to the next Y, which gives us a weighted strength for the texture values from each adjacent point. We lookup the 4 adjacent textures, take the weighted average, and apply height blending to calculate our final value.


The color map and macro variation are multiplied onto the albedo channel. Then all PBR values are sent to the GPU.

