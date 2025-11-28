Texture Displacement
====================

```{image} images/displacement_example.png
:target: ../_images/displacement_example.png
```

```{image} images/displacement_wireframe.png
:target: ../_images/displacement_wireframe.png
```

For a more detailed terrain mesh, you can enable texture height based displacement by increasing `Mesh/Tessellation Level` from 0 (default) upto 6. This will subdivide the clipmap mesh, greatly increasing the vertex density around the camera. This feature is compatible with all platforms, including mobile and web, however it does come with a potentially significant performance cost. Set `Mesh/Tessellation Level`  to 0 to disable displacement.

Generally, it is recommended to keep `mesh_size` as high as performance allows, and `vertex_spacing` at `1.0` for the best results. Both parameters will have a noticable effect on the subdivision density.

Under the `Mesh/Displacement` subgroup you can set the global `Displacement Scale`. This is the maximum distance that 2 adjacent verticies can be vertically seperated by. Setting this 1.0 would mean a maximum of + 0.5m, and -0.5m deviation from the collision mesh.


## Configuring Textures

**Note:** Setting up textures with height data as described in [Texture Prep](texture_prep.md) is a requirement for tessellated texture displacement.

Included in the `Terrain3DTextureAsset` settings, are `displacement_offset` and `displacement_scale`.

To aid setting up a given material with a clear view, you can disable `Rendering/Show Instances`, as well as hiding any other nodes in the scene tree that obscure the terrain surface. Enabling the `Displacement Buffer` debug view will show the amount that vertices have been displaced. Black areas match collision exactly. Red shows depressions into the terrain, and Green for extrusions above the terrain. 

You can also change `collision mode` to editor collision, and enable view gizmos, which will show the collision mesh for direct comparison. 

You can also set `UV scale` to the default `0.1` and adjust back later as the ratio between the displacement and UV scales is maintained.

```{image} images/displacement_buffer.png
:target: ../_images/displacement_buffer.png
```

First, adjust `Displacement Scale` until the dimensions of objects represented by the textures are correctly proportioned. Eg Branches are not overly elongated, and pebbles appear round, rather than spikey.

Next, adjust `Normal Depth` so that the sides any displaced areas are lit correctly. The normal map normals as relied upon for the higher detail geometry.

Finally adjust `Displacement Offset` if required to, as much as is possible, minimize the ammount of colision miss-match. Most of the time, the default `0.0` is adequate. However as an example, a cobble stone texture might have the tops of the cobbles protrude above the terrain - and a small negative offset can align the tops of the cobbles with collision.

The `Material/Displacement Sharpness` parameter is an additonal modifier to `Material/Blend Sharpness`. When set at `1.0`, the blending of displacment between textures will match the aldebo/normal blend sharpness exactly. Lower values will be softer, avoiding harsh displacment transitions between materials, without compromising the abldeo/normal blend sharpness. 

**Note:** If `Material/Displacement Sharpness` is set at or very near to `0.0`, it is possible that a very highly displaced texture, can noticably impact a less displaced texture at low blend values, despite not being visible.


## Displacement Buffer

To calculate displacement, an atlas texture buffer is created via a viewport and canvas_item shader. This buffer updates only when the clipmap mesh moves to save on computational cost.

You can access the buffer shader by enabling `Mesh/Displacement/Buffer Shader Override Enabled`, which will generate the default for you. Though primarily for development use, it could be modified to read from a persistent buffer for real-time effects like footsteps in sand or mud, or to change how the blending of height textures is handled.

Custom uniforms added will show up in the `Material` properties, it is generally advised to keep custom uniforms inside the `group_uniforms displacement` uniform group in the shader code for easier access in the inspector.
