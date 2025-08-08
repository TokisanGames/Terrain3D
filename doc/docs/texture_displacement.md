Texture Displacement
====================

For a more detailed terrain mesh, you can enable texture height based displacement by increasing `tessellation_level`. This will subdivide the clipmap mesh, greatly increasing the vertex density around the camera. An atlas texture buffer is then created via a viewport and canvas_item shader that updates only when the clipmap mesh moves, reducing computational cost significantly.

```{image} images/displacement_example.png
:target: ../_images/displacement_example.png
```

It should be noted that `mesh_size` & `vertex_spacing` will have a noticable effect on the subdivision distance, and vertex density. Generally it is recommended to keep `mesh_size` as high as performance allows, and `vertex_spacing` at `1.0` for the best results.

```{image} images/displacement_wireframe.png
:target: ../_images/displacement_wireframe.png
```

Setting up textures with height data as described in [Texture Prep](texture_prep.md) is a requirement for tessellated texture displacement.

Included in the `Terrain3DTextureAsset` settings, are `displacement_offset` & `displacement_scale`. These should be adjusted so that the surface is realisticly displaced, and centered around zero to minimize collision missmatch between displaced verticies and the terrain collision.

Enabling the `displacement_buffer`debug view, will render the ammout a vertex has been displaced. Red for depressions, and Green for extrusions. This view can be handy when setting the offset and scale values, to ensure the texture is centered around 0.

```{image} images/displacement_buffer.png
:target: ../_images/displacement_buffer.png
```
