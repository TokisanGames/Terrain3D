Tips
======

## Regions

Outside of regions, there is no collision. Raycasts won't hit anything. Querying terrain heights or other data will result in NANs or INF. Look through the API for specific return values.

You can determine if a given location is within a region by using `Terrain3DData.has_regionp(global_position)`. It will return -1 if the XZ location is not within a region. Y is ignored.


## Performance
* The Terrain3DMaterial shader has some advanced features that look nice but consume some performance. You can get better performance by disabling them:
    * Set `WorldBackground` to `Flat` or `None`
	* Disable `Auto Shader`
	* Disable `Dual Scaling`
* `WorldBackground` as `Noise` exposes additional shader settings, such as octaves and LOD. You can adjust these settings for performance. However this world generating noise is expensive. Consider not using it at all in a commercial game, and instead obscure your background with meshes, or use an HDR skybox.
* Reduce the size of the mesh and levels of detail by reducing `Mesh/Size` (`mesh_size`) or `Mesh/Lods` (`mesh_lods`) in the `Terrain3D` node.
* Don't use `Terrain3D/Renderer/Cull Margin`. It should only be needed if using the noise background. Otherwise the AABB should be correctly calculated via editing, so there is no need to expand the cull margin. Keeping it enabled can cost more processing time.


## Shaders

### Day/Night cycles & light under the terrain
The terrain shader is set to `cull_back`, meaning back faces are neither rendered, nor do they block light. If you have a day/night cycle and the sun sets below the horizon, it will shine through the terrain. Enable the shader override and change the second line to `cull_disabled` and the horizon will block sunlight. This does cost performance. 

Alternatively, turn off your light when it syncs below. This will likely cause a shader recompile in the engine as it's a different lighting configuration. Instead you can change light energy to 0, or in the same frame, simultaneously turn off the sun light and turn on a moon light.


### Accessing private shader variables
Variables in the shader prefaced with `_` are considered private and not saved to disk. They can be accessed externally via the Rendering Server:

```gdscript
RenderingServer.material_get_param(terrain.get_material().get_material_rid(), "_background_mode")
```


### Using the generated height map in other shaders
Here we get the resource ID of a material on a mesh. We assign the RID of the generated heightmap to texture slot in that material.

```gdscript
var mat: RID = $MeshInstance3D.mesh.surface_get_material(0).get_rid()
RenderingServer.material_set_param(mat, "texture_albedo", get_storage().get_height_maps_rid())
```

This is a quick demonstration that shows results. However the generated texture arrays should be accessed with sampler2DArray in a shader, not the regular sampler which is what will will happen here.

This also works with the control and color maps. 


### Add a custom texture map

Here's an example of using a custom texture map for one texture, such as adding an emissive texture for lava. Add in this code and add an emissive texture, then adjust the emissive ID to match the lava texture, and adjust the strength.

Add the uniforms at the top of the file:
```glsl
uniform int emissive_id : hint_range(0, 31) = 0;
uniform float emissive_strength = 1.0;
uniform sampler2D emissive_tex : source_color, filter_linear_mipmap_anisotropic;
```

Modify the return struct to house the emissive texture.

```glsl
struct Material {
	...
	vec3 emissive;
};
```

Modify `get_material()` to read the emissive texture.
```glsl
// Add the initial value for emissive, adding the last vec3
out_mat = Material(vec4(0.), vec4(0.), 0, 0, 0.0, vec3(0.));

// Immediately after albedo_ht and normal_rg get assigned:
// albedo_ht = ...
// normal_rg = ...
vec4 emissive = vec4(0.);
if(out_mat.base == emissive_id) {
	emissive = texture(emissive_tex, matUV);
}

// Immediately after albedo_ht2 and normal_rg2 get assigned:
// albedo_ht2 = ...
// normal_rg2 = ...
vec4 emissive2 = vec4(0.);
emissive2 = texture(emissive_tex, matUV2) * float(out_mat.over == emissive_id);

// Immediately after the calls to height_blend:
// albedo_ht = height_blend(...
// normal_rg = height_blend(...
emissive = height_blend(emissive, albedo_ht.a, emissive2, albedo_ht2.a, out_mat.blend);

// At the bottom of the function, just before `return`.
out_mat.emissive = emissive.rgb;
```

// Then at the very bottom of `fragment()`, before the final }, apply the weighting and send it to the GPU.
```glsl
vec3 emissive = weight_inv * (
	mat[0].emissive * weights.x +
	mat[1].emissive * weights.y +
	mat[2].emissive * weights.z +
	mat[3].emissive * weights.w );
EMISSION = emissive * emissive_strength;
```

Note: Avoid sub branches: an if statement within an if statement, and enable your FPS counter so you can test as you build your code. Some branch configurations may be free, some may be very expensive, or even more performant than you expect.
