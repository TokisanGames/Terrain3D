Tips
======

## General

* Always run Godot with the [console](troubleshooting.md#use-the-console) open so you can see errors and messages from the engine. The output panel is slow and inadequate.

## Textures
* Right-click any texture set to bring it into edit mode.
* Middle-click any texture set to clear/delete it. You can only delete the last texture in the list.
* You can reorder the textures by changing the texture id. This will change the texture rendered in the viewport as it does not change the values painted on the control maps.

## Painting

* Many of the brush settings can be manually entered by clicking the number next to the sliders. Some can extend beyond the maximum slider value.

### Recommended Painting Technique
  * Every vertex has a base texture, an overlay texture, and a blending value.
  * Use the Paint tool to cover large sections with the base texture. Paint mountains, fields, and pathways. This tool also clears the blend value. You can and should mix different textures in an areas for natural variety. e.g. gravel and dirt; mud, dirt, and rocks.
  * Use the Spray tool to blend the edges to give it a natural look. This sets the overlay texture, replacing whatever was there before. It also increases the blend value, meaning "show more of the overlay texture". If you spray the same texture as the base, it will decrease the blend value instead.
  * Example: Use the Paint tool for a grass field and a dirt pathway, then use the Spray tool and repeatedly switch between grass and dirt to blend the edges of the path randomly until it looks realistic.
  * Use the [control texture](../api/class_terrain3dmaterial.rst#class-terrain3dmaterial-property-show-control-texture) and [control blend](../api/class_terrain3dmaterial.rst#class-terrain3dmaterial-property-show-control-blend) debug views to understand how your textures are painted and blended. 

## Shaders

### Debug shaders
Enabling the shader override will give you a copy of the shader you currently see on the terrain. If you turn on the various debug views, such as the vertex grid, then clear any existing shader override, then enable it, you'll get a copy of that debug shader. Debug shaders are typically inserted at the end with all of the normal shader parameters included but overwritten.

### Remove the mesh outside of regions
*This is built into v0.9, labeled `World Background`*

You can hide the terrain outside of your active regions by modifying the override shader. Add this to the end of `vertex()`. All of these options work on an NVidia card, you only need one:

```glsl
if(get_region_uv2(UV2).z < 0.) {
	VERTEX.x=0./0.;
	//VERTEX=vec3(0./0.);
	//VERTEX=vec3(sqrt(-1));
}
```

### Make a region smaller than 1024^2
You can use the above technique, changing the conditional test from regions to world coordinates for VERTEX. eg. Discard vertices that are < 0 or > 256. It will still build collision and consume memory for 1024 x 1024 maps, but this will allow you to control the visual world until alternate region sizes are supported.


### Regarding day/night cycles
The terrain shader is set to `cull_back`, meaning back faces are not rendered. Nor do they block light. If you have a day/night cycle and the sun sets below the horizon, it will shine through the terrain. Enable the shader override and change the second line to `cull_disabled` and the horizon will block sunlight. This does cost performance.


### Branching

Using conditionals (if/while/for) creates multiple branches or paths of code execution. An if a statement, which can be true or false, creates two separate branches.

Historically it has been taught that using branches in shaders is a bad practice and will kill GPU performance. This is not true. Branches by themselves won't slow down modern cards.

GPUs are designed to create a large group of cores that will execute the same code path, or branch. If there is an if statement that turns the left side of the screen blue and the right side red, then half of the cores will execute each branch. Having two code paths is perfectly fine.

The problem with branches comes in where the conditions for branching changes dynamically and cores will variably select different paths to execute. If a pixel:
* feeds time into a random number generator
* then if that value is above or below 0.5
* then if time is even or odd
* then depending on those 4 permutations decides to read texture 1, 2, 3 or 4

then it's going to be very difficult for the GPU to optimize. It can't identify four groups of cores to execute the four paths since the conditions are constantly changing. It doesn't have to be extreme like this. Even two nested conditionals comparing lookup values up will slow a modern GPU. And that might only mean 10-20% slower, rather than entirely killing performance.

If our shader exposes a boolean checkbox to select between alpha blending or height blending, it will change the code path. But it has no impact on performance because all cores execute the same branch. We could also apply effects to one specific texture, and any cores processing that texture will be grouped.

Sometimes we think it would be more optimal to create a branch to not perform certain operations if a condition is false. Yet when we test it, we find that performing the wasteful operations in the same branch is actually more optimal than creating a branch.

So, the old rule of thumb about not using branches and structuring your code so that all cores use the same code path is still the best practice. However, limited use of branching with static conditions is fine and may be more optimal. Just consider if your conditions allow the GPU to group large sections of core down the same branch. Avoid dynamic conditions altogether and test any branches you create for optimization to ensure they actually have a performance benefit.


### Add a custom texture map

Here's an example of using a custom texture map for one texture, such as adding an emissive texture for lava. Note, avoid sub branches: an if statement within an if statement. As shown below, I wanted a sub branch to avoid processing the emissive when not used, but this slowed down my GPU. So, I refactored it in a way that didn't cause a performance hit.

Add the uniforms for the emissive texture id and a texture:
```glsl
uniform uint emissive_id = 0;
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
out_mat = Material(vec4(0.), vec4(0.), 0u, 0u, 0.0, vec3(0.));

// After reading albedo and normal, before the blending block
vec4 emissive = vec4(0.);
if(base_tex == emissive_id) {
	emissive = texture(emissive_tex, matUV);
}

// Within the overlay block: `if (blend > 0.f)`, after reading albedo/normal, but before the albedo/normal height_blend() calls
vec4 emissive2 = vec4(0.);
emissive2 = texture(emissive_tex, matUV2) * float(over_tex == emissive_id);
emissive = height_blend(emissive, albedo_ht.a, emissive2, albedo_ht2.a, blend);

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
EMISSION = emissive;

```

