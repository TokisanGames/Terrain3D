Tips
======

## General

* Always run Godot with the [console](troubleshooting.md#use-the-console) open so you can see errors and messages from the engine. The output panel is slow and inadequate.

* When another mesh intersects with Terrain3D far away from the camera, such as in the case of water on a beach, the two meshes can flicker as the renderer can't decide which mesh should be displayed in front. This is also called Z-fighting. You can greatly reduce it by increasing `Camera3D.near` to 0.25. You can also set it for the editor camera in the main viewport by adjusting `View/Settings/View Z-Near`.
 
## Textures
* Right-click any texture set to bring it into edit mode.
* Middle-click any texture set to clear/delete it. You can only delete the last texture in the list.
* You can reorder the textures by changing the texture id. This will change the texture rendered in the viewport as it does not change the values painted on the control maps.

## Painting

* Many of the brush settings can be manually entered by clicking the number next to the sliders. Some can extend beyond the maximum slider value.

### Recommended Painting Technique
  * Every vertex has a base texture, an overlay texture, and a blending value.
  * Use the Paint tool to cover large sections with the base texture. Paint mountains, fields, and pathways. This tool also clears the blend value. You can and should mix different textures in an area for natural variety. e.g. gravel and dirt; mud, dirt, and rocks.
  * Use the Spray tool to blend the edges to give it a natural look. This sets the overlay texture, replacing whatever was there before. It also increases the blend value, meaning "show more of the overlay texture". If you spray the same texture as the base, it will decrease the blend value instead.
  * Example: Use the Paint tool for a grass field and a dirt pathway, then use the Spray tool and repeatedly switch between grass and dirt to blend the edges of the path randomly until it looks realistic.
  * Use the [control texture](../api/class_terrain3dmaterial.rst#class-terrain3dmaterial-property-show-control-texture) and [control blend](../api/class_terrain3dmaterial.rst#class-terrain3dmaterial-property-show-control-blend) debug views to understand how your textures are painted and blended. 

## Performance
* The Terrain3DMaterial shader has some advanced features that look nice but consume some performance. You can get better performance by disabling them:
    * Set `WorldNoise` to `Flat` or `None`
	* Disable `Auto Shader`
	* Disable `Dual Scaling`
* Reduce the size of the mesh and levels of detail by reducing `Mesh/Size` (`mesh_size`) or `Mesh/Lods` (`mesh_lods`) in the `Terrain3D` node.

## Shaders

### Make a region smaller than 1024^2
Make a custom shader, then look in `vertex()` where it sets the vertex to an invalid number `VERTEX.x = 0./0.;`. Edit the conditional above it to filter out vertices that are < 0 or > 256 for instance. It will still build collision and consume memory for 1024 x 1024 maps, but this will allow you to control the visual aspect until alternate region sizes are supported.

### Regarding day/night cycles
The terrain shader is set to `cull_back`, meaning back faces are not rendered. Nor do they block light. If you have a day/night cycle and the sun sets below the horizon, it will shine through the terrain. Enable the shader override and change the second line to `cull_disabled` and the horizon will block sunlight. This does cost performance.

### Add a custom texture map

Here's an example of using a custom texture map for one texture, such as adding an emissive texture for lava. Note, avoid sub branches: an if statement within an if statement. As shown below, I wanted a sub branch to avoid processing the emissive when not used, but this slowed down my GPU. So, I refactored it in a way that didn't cause a performance hit.

Add the uniforms for the emissive texture id and a texture:
```glsl
uniform int emissive_id : hint_range(0,31) = 0;
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

// After reading albedo and normal, before the blending block: `if (out_mat.blend > 0.f)`
vec4 emissive = vec4(0.);
if(out_mat.base == emissive_id) {
	emissive = texture(emissive_tex, matUV);
}

// Within the overlay block: `if (blend > 0.f)`, right before the albedo/normal height_blend() calls
vec4 emissive2 = vec4(0.);
emissive2 = texture(emissive_tex, matUV2) * float(out_mat.over == emissive_id);
emissive = height_blend(emissive, albedo_ht.a, emissive2, albedo_ht2.a, out_mat.blend);

// At the bottom of the function, before `return`.
out_mat.emissive = emissive.rgb;
```

Then at the bottom of `fragment()` apply the weighting and send it to the GPU.
```glsl
vec3 emissive = weight_inv * (
	mat[0].emissive * weights.x +
	mat[1].emissive * weights.y +
	mat[2].emissive * weights.z +
	mat[3].emissive * weights.w );
EMISSION = emissive * emissive_strength;
```

