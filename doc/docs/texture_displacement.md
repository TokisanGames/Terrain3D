Texture Displacement
====================

For a more detailed terrain mesh, you can enable texture height based displacement by increasing `tessellation_level`. This will subdivide the clipmap mesh, greatly increasing the vertex density around the camera. An atlas texture buffer is then created via a viewport and canvas_item shader that updates only when the clipmap mesh moves, reducing computational cost significantly.

**Note:** Setting up textures with height data as described in [Texture Prep](texture_prep.md) is a requirement for tessellated texture displacement.

```{image} images/displacement_example.png
:target: ../_images/displacement_example.png
```

`mesh_size` & `vertex_spacing` will have a noticable effect on the subdivision density. Generally it is recommended to keep `mesh_size` as high as performance allows, and `vertex_spacing` at `1.0` for the best results.

```{image} images/displacement_wireframe.png
:target: ../_images/displacement_wireframe.png
```

Included in the `Terrain3DTextureAsset` settings, are `displacement_offset` & `displacement_scale`. These should be adjusted so that the surface is realistically displaced, and centered around zero to minimize collision mismatch between displaced vertices and the terrain collision.

Enabling the `displacement_buffer`debug view, will show the amount that a vertex has been displaced. Red for depressions, and Green for extrusions. This view can be handy when setting the offset and scale values for a given `Terrain3DTextureAsset`, to ensure the texture is centered around 0.

```{image} images/displacement_buffer.png
:target: ../_images/displacement_buffer.png
```

The `Displacement_sharpness` parameter, found under `Displacement Buffer` in the `Material` settings follows a smoother curve than `blend_sharpness`. This difference allows flatter materials to be more influenced by bumpier materials when blending.

## Displacement Buffer Shader override

Access to the buffer shader is provided, though primarily for development use, it could be modified to read from a persistent buffer for real-time effects like footsteps in sand or mud, or just to change how the blending of height textures is handled.