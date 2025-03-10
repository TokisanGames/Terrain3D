Tips
======

## Are Certain Features Supported?

This list are for items that don't already have dedicated pages in the documentation.

| Feature | Status | 
| ------------- | ------------- | 
| Destructibility | Real-time modification is possible by changing the data and updating the maps and collision. You can sculpt heights, change textures, or make holes. If you want tunnels or caves though you need to add your own meshes or use [Zylann's Voxel Tools](https://github.com/Zylann/godot_voxel).
| GPU Sculpting| [Pending](https://github.com/TokisanGames/Terrain3D/issues/174). Currently painting occurs on the CPU in C++. It's reasonably fast, but we have a soft limit of 200 on the brush size, as larger sizes lag.
| Holes | Holes work for both visual and collision.
| Jolt | [Godot-Jolt](https://github.com/godot-jolt/godot-jolt) works as a drop-in replacement for Godot Physics. Collision is generated where regions are defined.
| Non-destructive layers | Used for things like river beds, roads or paths that follow a curve and tweak the terrain. It's [possible](https://github.com/TokisanGames/Terrain3D/issues/129) in the future.
| Object placement | The [instancer](instancer.md) supports placing foliage. Placing objects that shouldn't be in a MultiMeshInstance node is [out of scope](https://github.com/TokisanGames/Terrain3D/issues/47). See 3rd party tools below.
| Streaming | Streaming is not yet supported by Godot or Terrain3D. In the future we will stream regions.
| Water | Use [WaterWays](https://github.com/Arnklit/Waterways) for rivers, or [Realistic Water Shader](https://github.com/godot-extended-libraries/godot-realistic-water/) or [Infinite Ocean](https://stayathomedev.com/tutorials/making-an-infinite-ocean-in-godot-4/) for lakes or oceans.
|**Rendering**|
| Frustum Culling | The terrain is made up of several meshes, so half can be culled if the camera is near the ground.
| SDFGI | Works fine.
| VoxelGI | Works fine.
| Lightmaps | Not possible. There is no static mesh, nor UV2 channel to bake lightmaps on to.
| **3rd Party Tools** |
| [Scatter](https://github.com/HungryProton/scatter) | For placing objects algorithmically, with or without collision. We provide [a script](https://github.com/TokisanGames/Terrain3D/blob/main/project/addons/terrain_3d/extras/project_on_terrain3d.gd) that allows Scatter to detect our terrain. Or you can change collision mode to `Full / Editor` and use the default `Project on Colliders`.
| [AssetPlacer](https://cookiebadger.itch.io/assetplacer) | A level design tool for placing assets manually. Works on Terrain3D with placement mode set to Terrain3D or using the default mode and collision mode set to `Full / Editor`.


## Regions

Outside of regions, there is no collision. Raycasts won't hit anything. Querying terrain heights or other data will result in NANs or INF. Look through the API for specific return values.

You can determine if a given location is within a region by using `Terrain3DData.has_regionp(global_position)`. It will return -1 if the XZ location is not within a region. Y is ignored.


## Terrain3DObjects

Just as the instancer keeps foliage stuck to the ground when sculpting, we provide a special node that does the same for regular MeshInstance3D objects.

Objects that are children of this node will maintain the same vertical offset relative to the terrain as they are moved laterally or as the terrain is sculpted.

For example you can place a sphere on the ground, move it laterally where a hill exists, and it will snap up to the new ground height. Or you can lower the ground and the sphere will drop with the changes. 

You can then adjust the vertical position of the sphere so it is half embedded in the ground, then repeat either of the above and the sphere will snap with the same vertical offset, half embedded in the ground.

To use it:
* Create a new node of type Terrain3DObjects
* Add your MeshInstance3D objects as children of this node


## Performance
* The Terrain3DMaterial shader has some advanced features that look nice but consume some performance. You can get better performance by disabling them:
    * Set `WorldBackground` to `Flat` or `None`
	* Disable `Auto Shader`
	* Disable `Dual Scaling`
* `WorldBackground` as `Noise` exposes additional shader settings, such as octaves and LOD. You can adjust these settings for performance. However this world generating noise is expensive. Consider not using it at all in a commercial game, and instead obscure your background with meshes, or use an HDR skybox.
* Reduce the size of the mesh and levels of detail by reducing `Mesh/Size` (`mesh_size`) or `Mesh/Lods` (`mesh_lods`) in the `Terrain3D` node.
* Don't use `Terrain3D/Renderer/Cull Margin`. It should only be needed if using the noise background. Otherwise the AABB should be correctly calculated via editing, so there is no need to expand the cull margin. Keeping it enabled can cost more processing time.


## Shaders

### Minimal Shader

This terrain is driven by the GPU, and controlled by our shader. We provide a minimal shader that has only the code needed to shape the terrain mesh without any texturing. You can find it in `extras/minimum.gdshader`.

Load this shader into the override shader slot and enable it. It includes no texturing so you can create your own.


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
RenderingServer.material_set_param(mat, "texture_albedo", get_data().get_height_maps_rid())
```

This is a quick demonstration that shows results. However the generated texture arrays should be accessed with sampler2DArray in a shader, not the regular sampler which is what will will happen here.

This also works with the control and color maps. 


### Add a custom texture map

Here's an example of using a custom texture map for one texture, such as adding an emissive texture for lava. Add in this code and add an emissive texture, then adjust the emissive ID to match the lava texture, and adjust the strength.

Add these uniforms at the top of the file with the other uniforms:
```glsl
uniform int emissive_id : hint_range(0, 31) = 0;
uniform float emissive_strength = 1.0;
uniform sampler2D emissive_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
```

Add a variable to store emissive value in the Material struct.

```glsl
// struct Material {
	...
	vec3 emissive;
// };
```

Modify `get_material()` to read the emissive texture with the next several options. 

Add the initial value for emissive by adding a vec3 at the end
```glsl
// void get_material(vec2 base_uv, ...
	out_mat = Material(vec4(0.), vec4(0.), 0, 0, 0.0, vec3(0.));
```

Look for this conditional:
```glsl
	if (out_mat.blend > 0.) {
```

Right before that, add:
```glsl
	vec4 emissive = vec4(0.);
	if(out_mat.base == emissive_id) {
		emissive = textureGrad(emissive_tex, matUV, dd1.xy, dd1.zw);
	}

//	if (out_mat.blend > 0.) {
```

At the end of that block, before the `}`, add:
```glsl
	vec4 emissive2 = vec4(0.);
	emissive2 = textureGrad(emissive_tex, matUV2, dd2.xy, dd2.zw) * float(out_mat.over == emissive_id);
	emissive = height_blend(emissive, albedo_ht.a, emissive2, albedo_ht2.a, out_mat.blend);

//	}
```

At the end of the `get_material()` function, add the emissive value to the material
```glsl
//	out_mat.alb_ht = albedo_ht;
//	out_mat.nrm_rg = normal_rg;
	out_mat.emissive = emissive.rgb;
//	return;
//	}
```

At the very bottom of `fragment()`, before the final `}`, apply the weighting and send it to the GPU.
```glsl
vec3 emissive = 
	mat[0].emissive * weights.x +
	mat[1].emissive * weights.y +
	mat[2].emissive * weights.z +
	mat[3].emissive * weights.w ;
EMISSION = emissive * emissive_strength;

// }
```

Next, add your emissive texture to the texture sampler and adjust the values on the newly exposed uniforms.


### Avoid sub branches

Avoid placing an if statement within an if statement. Enable your FPS counter so you can test as you build your code. Some branch configurations may be free, some may be very expensive, or even more performant than you expect. Always test.

Sometimes it's faster to always calculate than it is to branch.

Sometimes you can do tricks like this to avoid sub branching:

```glsl
uniform bool auto_shader;
if (height > 256) {
   if (auto_shader) {
     albedo = snow_color;
   }
}
```

```glsl
uniform bool auto_shader;
if (height > 256) {
  albedo = float(!auto_shader)*albedo + float(auto_shader)*snow_color;
}
```

These two are equivalent, and avoids the sub branch by always calculating. If auto_shader is true, the line is `albedo = 0.*albedo + 1.*snow_color`.
