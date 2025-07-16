Displacement
====================

For a more detailed terrain mesh, you can enable texture height based displacement. This will subdivide the clipmap mesh, greatly increasing the vertex density around the camera. This feature is compatible with all platforms, including mobile and web, however it does come with a potentially significant performance cost.


```{image} images/displacement_example.jpg
:target: ../_images/displacement_example.jpg
```

```{image} images/displacement_wireframe.jpg
:target: ../_images/displacement_wireframe.jpg
```

## Enabling Displacement

You can enable displacement in the `Terrain Mesh` group, by increasing `Tessellation Level` from 0 (disabled, default) up to 6. This will subdivide the terrain around the camera. Generally, it is recommended to keep `Tessellation Level` low, `Mesh Size` as high as performance allows, and `Vertex Spacing` at `1.0` for the best results. All three parameters will have a noticable effect on the subdivision density.

When `Tessellation Level` is greater than 0, the `Displacement` subgroup appears with global options. Enable displacement, then setup your textures, then come back to these global options.

To setup your texture assets, you need a clear view of the terrain and an understanding of where the collision surface is. Explore any of these options:
* Disable instances by setting `Rendering/Instancer Mode` to `Disabled`.
* Hide your nodes in the scene that obscure the terrain surface.
* Change `Collision/Collision Mode` to editor collision, and enable view gizmos, which will show the collision mesh for direct comparison. 
* Enable the `Debug Views/Displacement Buffer`. Black areas match collision exactly. Red shows depressions into the terrain, and Green shows extrusions above the terrain.

```{image} images/displacement_buffer.jpg
:target: ../_images/displacement_buffer.jpg
```


## Configuring Textures

In order to use displacement, you must have textures packed with height textures as described in [Texture Prep](texture_prep.md).

When you configure your `Terrain3DTextureAsset`, you'll find `Displacement Offset` and `Displacement Scale` options.

First, adjust `Displacement Scale` until the dimensions of features in the textures are correctly proportioned. Eg. branches are not overly elongated, and pebbles appear round, rather than spiky.

Next, adjust `Normal Depth` so that any displaced areas are lit correctly. The normal map normals are used for the higher detail geometry.

Finally, adjust `Displacement Offset` if necessary to minimize the amount of colision mismatch. Most of the time, the default `0.0` is adequate. As an example, a cobblestone texture might have the tops of the cobbles protrude above the terrain, but a small negative offset can align the tops of the cobbles with collision.


## Displacement Global Settings

Once the texture assets are configured, the global settings can be adjusted in `Terrain Mesh/Displacement`. 

Use `Displacement Scale` for a global multiplier on all textures. This is the maximum distance that 2 adjacent verticies can be vertically seperated by. Setting this 1.0 would mean a maximum of + 0.5m, and -0.5m deviation from the collision mesh.

`Displacement Sharpness` adjusts the transition between textures. When set at `1.0`, the blending of displacment between textures will match the aldebo and normal blend sharpness exactly. Lower values will have a softer transition, avoiding harsh shapes, without compromising the albedo and normal blend sharpness. If set at or very near to `0.0`, it is possible that more displaced textures can affect less displaced textures at low blend values even if not visible.


## Displacement Buffer

To calculate displacement, an atlas texture buffer is created via a viewport and canvas_item shader. This buffer updates only when the terrain mesh moves to save on computational cost.

You can access the buffer shader by enabling `Terrain Mesh/Displacement/Buffer Shader Override Enabled`, which will generate the default for you. Though primarily for development use, it could be modified to read from a persistent buffer for real-time effects like footsteps in sand or mud, or to change how the blending of height textures is handled.

Custom uniforms can be added within the `group_uniforms displacement` block. These will show up in the `Material/Displacement` group.
