Texture Displacement
====================

```{image} images/displacement_example.png
:target: ../_images/displacement_example.png
```

```{image} images/displacement_wireframe.png
:target: ../_images/displacement_wireframe.png
```

For a more detailed terrain mesh, you can enable texture height based displacement by increasing `Mesh/Tessellation Level` from 0 (default) upto 6. This will subdivide the clipmap mesh, greatly increasing the vertex density around the camera. For low-poly, mobile, web, or for higher performance, keep it at 0 to disable displacement.

Generally, it is recommended to keep `mesh_size` as high as performance allows, and `vertex_spacing` at `1.0` for the best results. Both parameters will have a noticable effect on the subdivision density. 

## Configuring Textures

**Note:** Setting up textures with height data as described in [Texture Prep](texture_prep.md) is a requirement for tessellated texture displacement.

Included in the `Terrain3DTextureAsset` settings, are `displacement_offset` and `displacement_scale`.

These should be adjusted per texture asset so that the surface is realistically displaced, and centered around zero to minimize the mismatch between the displaced vertices and the terrain collision. UV scale is accounted for, maintaining a constant height ratio.

Setting `normal_depth` appropiatley, in tandem with `displacement_scale` is important, as normal map normals as relied upon for the higher detail geometry normals.

Enabling the `Displacement Buffer` debug view will show the amount that vertices have been displaced. Black areas match collision exactly. Red shows depressions into the terrain, and Green for extrusions above the terrain. This view can be handy when setting the offset and scale values for a given `Terrain3DTextureAsset`, to ensure the texture is centered around 0.

```{image} images/displacement_buffer.png
:target: ../_images/displacement_buffer.png
```

The `Material/Displacement Sharpness` parameter is an additonal modifier to `Material/Blend Sharpness`. at 1.0, the blending of heights will match the aldebo/normal blend sharpness exactly. lower values will be softer, avoiding harsh height transitions between materials, without compromising the abldeo/normal blend sharpness.


## Displacement Buffer

To calculate displacement, an atlas texture buffer is created via a viewport and canvas_item shader. This buffer updates only when the clipmap mesh moves to save on computational cost.

You can access the buffer shader by enabling `Material/Buffer Shader Override Enabled`, which will generate the default for you. Though primarily for development use, it could be modified to read from a persistent buffer for real-time effects like footsteps in sand or mud, or to change how the blending of height textures is handled.
