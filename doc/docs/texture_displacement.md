Texture Displacement
====================

For a more detailed terrain mesh, you can enable texture height based displacement by increasing `Mesh/Tessellation Level` from 0 (default) to say 3. This will subdivide the clipmap mesh, greatly increasing the vertex density around the camera. For low-poly, mobile, web, or for higher performance, keep it at 0 to disable displacement.

**Note:** Setting up textures with height data as described in [Texture Prep](texture_prep.md) is a requirement for tessellated texture displacement.

```{image} images/displacement_example.png
:target: ../_images/displacement_example.png
```

Generally, it is recommended to keep `mesh_size` as high as performance allows, and `vertex_spacing` at `1.0` for the best results. Both parameters will have a noticable effect on the subdivision density. 

```{image} images/displacement_wireframe.png
:target: ../_images/displacement_wireframe.png
```

Included in the `Terrain3DTextureAsset` settings, are `displacement_offset` and `displacement_scale`. These should be adjusted per texture asset so that the surface is realistically displaced, and centered around zero to minimize the mismatch between the displaced vertices and the terrain collision.

Enabling the `Displacement Buffer` debug view will show the amount that vertices have been displaced. Red for depressions, and Green for extrusions. This view can be handy when setting the offset and scale values for a given `Terrain3DTextureAsset`, to ensure the texture is centered around 0.

```{image} images/displacement_buffer.png
:target: ../_images/displacement_buffer.png
```

The `Material/Displacement Sharpness` parameter follows a smoother curve than `Material/Blend Sharpness`. This difference allows flatter materials to be influenced more by bumpier materials when blending.


## Displacement Buffer

To calculate displacement, an atlas texture buffer is created via a viewport and canvas_item shader. This buffer updates only when the clipmap mesh moves to save on computational cost.

You can access the buffer shader by enabling `Material/Buffer Shader Override Enabled`, which will generate the default for you. Though primarily for development use, it could be modified to read from a persistent buffer for real-time effects like footsteps in sand or mud, or to change how the blending of height textures is handled.
