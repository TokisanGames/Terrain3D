Technical Tips
====================

## Are Certain Features Supported?

This list are for items that don't already have dedicated pages in the documentation.

| Feature | Status | 
| ------------- | ------------- | 
| Destructibility | Real-time modification is possible by changing the data and updating the maps and collision. You can sculpt heights, change textures, or make holes. If you want tunnels or caves though you need to add your own meshes or use [Zylann's Voxel Terrain](https://github.com/Zylann/godot_voxel).
| GPU Sculpting| [Pending](https://github.com/TokisanGames/Terrain3D/issues/174). Currently painting occurs on the CPU in C++. It's reasonably fast, but we have a soft limit of 200 on the brush size, as larger sizes lag.
| Holes | Holes work for both visual and collision.
| Jolt | [Godot-Jolt](https://github.com/godot-jolt/godot-jolt) was merged into Godot. Terrain3D works with both Godot and Jolt physics. Collision is generated where regions are defined.
| Non-destructive layers | Used for things like river beds, roads or paths that follow a curve and tweak the terrain. It's [possible](https://github.com/TokisanGames/Terrain3D/issues/129) in the future.
| Object placement | The [instancer](instancer.md) supports placing foliage. Placing objects that shouldn't be in a MultiMeshInstance node is [out of scope](https://github.com/TokisanGames/Terrain3D/issues/47). See 3rd party tools below.
| Streaming | There is no streaming built in to Godot. Region Streaming is [in progress](https://github.com/TokisanGames/Terrain3D/pull/675).
| Roads | Look at [Godot Road Generator](https://github.com/TheDuckCow/godot-road-generator/).
| Water | Use [WaterWays](https://github.com/Arnklit/Waterways) for rivers, or [Realistic Water Shader](https://github.com/godot-extended-libraries/godot-realistic-water/) or a variety of other water shaders available online for lakes or oceans.
|**Rendering**|
| Frustum Culling | The terrain is made up of several meshes, so half can be culled if the camera is near the ground.
| SDFGI | Works fine.
| VoxelGI | Works fine.
| Lightmaps | Not possible. There is no static mesh, nor UV2 channel to bake lightmaps on to.
| **3rd Party Tools** |
| [Scatter](https://github.com/HungryProton/scatter) | For placing MeshInstance3D objects algorithmically, with or without collision. We provide [a script](https://github.com/TokisanGames/Terrain3D/blob/main/project/addons/terrain_3d/extras/3rd_party/project_on_terrain3d.gd) that allows Scatter to detect our terrain. Or you can change collision mode to `Full / Editor` and use the default `Project on Colliders`. Don't use it for MultiMeshInstances, use our built-in instancer.
| [AssetPlacer](https://cookiebadger.itch.io/assetplacer) | A level design tool for placing MeshInstance3D assets manually. Works on Terrain3D with placement mode set to Terrain3D or using the default mode and collision mode set to `Full / Editor`.


## Regions

Outside of regions, there is no collision. Raycasts won't hit anything. Querying terrain heights or other data will result in NANs or INF. Look through the API for specific return values. See [Collision] for more.

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
* `WorldBackground` as `Noise` exposes additional shader settings, such as octaves and LOD. You can adjust these settings for performance. However this world generating noise is expensive. Consider not using it at all in a commercial game, and instead obscure your background with meshes, or use an HDR skybox with mountains built in.
* Reduce the size of the mesh and levels of detail by reducing `Terrain Mesh/Size` or `Terrain Mesh/Lods` in the `Terrain3D` node.
* Reduce `Terrain Mesh/Tessellation Level` or set to 0 (default) to completely disable texture displacement.
* Increase `Terrain Mesh/Vertex Spacing`, which increases the lateral scale and gives you a more low-poly terrain. Preferrably do this before you sculpt, but if done after, you can export the heightmap and manipulate it in Photoshop to rescale it.
* Don't use `Renderer/Cull Margin`. It should only be needed if using the noise background. Otherwise the AABB should be correctly calculated via editing, so there is no need to expand the cull margin. Keeping it enabled can cost more processing time.
* Experiment with `Renderer/free_editor_textures`, which is enabled by default. It saves VRAM by removing the initial textures used to generate the texture arrays.
* For cases where performance is paramount, an example `lightweight` shader is provided in `extras/shaders`. This shader is designed to do the minimum possible amount of texture lookups, while still providing basic texturing, including height blending. Normals are also fully calculated in `vertex()`. This shader removes advanced features like projection, detiling, and paintable rotation and scale for significant performance gains on low-end hardware, mobile, and VR applications. Or you can use the `minimum` shader and craft your own texturing and coloring without any extra features.


## Shaders

### Minimal Shaders

This terrain is driven by the GPU, and controlled by our shader. We provide a minimal shader that has only the code needed to shape the terrain mesh without any texturing that you can use as a base to build your own. There's also versions that use the color map, and have a low-poly look with flat normals. Find them all in `extras/shaders/minimum.gdshader`.

Load this shader into the override shader slot and enable it. It includes no texturing so you can create your own.

### Low-poly & PS1 Styles

Older style asthetics has a few different looks:

**PS1 style** often has blocky textures, which can be achieved by:
* Use low res textures
* In the Terrain3DTextureAsset, decreasing UV Scale
* In the material, change Texture Filtering to Nearest. If you make your own shader, make sure to change your samplers to use Nearest filtering instead of Linear.

**Low-poly Style** often has large, flat shaded polygons. To get the best results:
* Increase `vertex_spacing` to a large value like 10
* Enable `Flat Terrain Normals` in the material settings.


### Day/Night cycles & light under the terrain

If you have a day/night cycle and the sun sets below the horizon, it might shine through the terrain. There are a few options you can try:

* Check `Material / Shader Override Enabled` and change the second line of the generated shader to `cull_disabled`. The terrain shader is set to `cull_back` by default, meaning back faces are neither rendered, nor do they block light. This will change that, though it does cost some performance. 
* You can also try changing `Rendering / cast_shadows` to double sided.
* Turn off your light when it sinks below the horizon. Changing the number of visible DirectionalLight3Ds will likely cause a shader recompile in the engine as it's a different lighting configuration. Instead you can tween light energy to 0, or you could turn off the sun light and turn on a moon light as long as it is done simultaneously in the same frame.


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
struct material {
	...
	vec3 emissive;
};
```

Modify `accumulate_material()` to read the emissive texture with the next several options. 

Add the initial value for emissive by adding a vec3 at the end:
```glsl
	// Struct to accumulate all texture data.
	material mat = material(vec4(0.0), vec4(0.0), 0., 0., 0., vec3(0.));
```

Near the bottom of `accumulate_material()`:
```glsl
	mat.normal_rough += nrm * id_weight;
	mat.normal_map_depth += _texture_normal_depth_array[id] * id_weight;
	mat.ao_strength += _texture_ao_strength_array[id] * id_weight;
	mat.total_weight += id_weight;
```

on the next line add:
```glsl
	if(id == emissive_id) {
		mat.emissive += textureGrad(emissive_tex, vec3(id_uv, float(id)), id_dd.xy, id_dd.zw).rgb *= id_weight;
	}
```

Find this in `fragment()`, before the final `}`, apply the weighting and send it to the GPU.
```glsl
	// normalize accumulated values back to 0.0 - 1.0 range.
	float weight_inv = 1.0 / total_weight;
	mat.albedo_height *= weight_inv;
	...
	mat.emissive *= weight_inv;
	EMISSION = mat.emissive * emissive_strength;
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
