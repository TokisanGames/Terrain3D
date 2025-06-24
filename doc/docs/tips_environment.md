Environment Tips
============================

**Table of Contents**
* [Introduction](#introduction)
* [Lighting](#lighting)
* [Foliage Assets](#foliage-assets)
* [Foliage Material](#foliage-material)


## Introduction

No matter how good of assets you have, your landscape will not look good without a proper rendering environment.

The Godot renderer has greatly improved its lighting over previous generations, but the default material shader is not good at rendering foliage.

Terrain3D provides the ground mesh with a sophisticated shader, an instancer, and a particle shader. But sourcing, using, and setting up the textures, foliage assets, materials, lighting, and environment settings are your responsibility. Your choices and artistic technique will dramatically affect what your world looks like. Prepare to spend countless hours tweaking your materials, lighting, and environment settings.

To get an attractive environment you need the following, **in order of priority**:

1. White balanced and properly exposed lighting. Use pure white light. Don't use colored light unless you really know what you're doing.
2. Quality [ground textures with heights](texture_prep.md), and [good technique in painting](texture_painting.md#texture-painting).
3. Quality foliage mesh and texture assets.
4. A good foliage shader (below). The default is inadequate.
5. Suitable `WorldEnvironment` settings to balance and polish your look.


## Lighting

Lighting is the most important. To be able to adjust your world accurately, you need to ensure the photons hitting your eyes are accurate. If your view of the world is off, your interpretation of it will be off.


### Room Lighting

There is a reason every major feature film finishes off their post production with a professional colorist. This person or team has spend tens of thousands of dollars to create a viewing studio with calibrated equipment in order to be able to work in the environment of the ideal movie theater. They can then fix issues **they might not have been able to see** in other environments, such as over or under exposure, inaccurate colors, crushed blacks, blown out highlights, flickering, etc.

The goal is not to have your game look good on all monitors. That's an impossible task. 

What a movie studio aims for is the best possible experience on reference hardware in the ideal environment. They want to meet industry standard specifications defined by THX, Dolby, etc. Then they rely on equipment manufacturers and those building professional and home theaters to also build for those specifications. The closer the end user gets to those standards, the more accurate their experience of the product will be.

You don't have to match this level of expense or effort. But you should look at your office and monitors, and fix the worst issues so that you can work in an environment closer to how gamers will consume your product.

It's going to be very difficult to produce an attractive game if your screen looks like the left:
```{image} images/monitor_calibration.jpg
:target: images/monitor_calibration.jpg
```

**Tips:**

* Ensure you don't have light shining on your screen. If you have a glossy screen, make sure there are no reflections on it.
* If you have colored lights around your office or computer, turn them off. Turn off keyboard and case LEDs.
* Adjust your room lighting for neutrality:
	* The color of room light should be neutral - close to overcast outdoor lighting. Your monitor is most likely slightly blue like outdoor light, incandescent lights are orange, cool white bulbs are too blue.
	* The overall brightness of the room should be slightly dim, but not dark. You want your monitor at near full brightness so it can render colors as designed, without competing with other lights or windows. But you don't want the room so dark the bright screen blows out your eyes.
* Before buying a screen or laptop:
	* Make sure it's a matte screen. Never buy glossy screens for graphics work as you'll always be fighting reflections.
	* Look at it in person. Open a web browser at the store, load up an monitor calibration image, and try to adjust the screen in the store to ensure you can get an accurate result at home.
	* Look up the monitor on a review website that focuses on screen testing for color and brightness uniformity and rendering.
	* Lenovo laptop monitors have been very good in recent years (through 2024 at least).
* Calibrate your monitor.

* 
### Monitor Calibration

The easy way is to buy a device to calibrate your monitor like something from Calibrite or Datacolor.

However you can do it manually, and with practice you'll get better at it and train your eye.

* Find your screen controls built into your monitor and adjust those first with the tests below. Even laptop screens have brightness controls, which should probably be at or near max. This is the first pass.
* Repeat the adjustments with the color calibration software built in to your OS. Windows has `Display Color Calibration` control panel with a wizard.
* Work through the pages in [LCD Test](http://www.lagom.nl/lcd-test/) as you adjust the physical, and then later, the software controls.
* View a `monitor calibration image` (web search) as you adjust the controls, such as [this one](https://webtransformer.com/calibrate/).
* When adjusting, think about what you're looking at on the image; the fruit, skin color, etc. Ask yourself, "Is that what it's supposed to look like?" "Is this what it would look like if it were sitting on my desk in front of me?" Look away, out the window, then look back at it and ask yourself again. Adjust the controls. Make it too saturated. Then make it desaturated. Then find the right spot. Do that with all of the controls. Too bright, too dark, just right.
* Color is the hardest. You must find neutral white, which is comprised of equal parts of red, blue, and green as your screen displays them, not what is fed from your video card. Look at white on the reference image or the background of a web browser. Is it too blue? Probably. Most factory shipped monitors and TVs are. Is it too red? Is it too green? Adjust, look away, look, adjust. Make it too red, too blue, too green, just right.
* Over many years of color and photography work, you will stop accepting what your brain interprets you're seeing (a white wall) and will perceive the raw input from your eyes (a slightly yellow-grey wall, dark grey in the shadows, a subtle orange tint around the incandescent light, and a soft blue tint from the window).


### Game Environment

In your virtual world, the most important aspects are your sky shader, directional light, and camera. The sky shader illuminates the world with reflective light, giving your world a base exposure. The directional light gives your world three-dimensional form through light and shadow. The camera is the eye that perceives the virtual light rays.

We won't discuss Global Illumination here. There aren't any good world GI solutions in Godot currently. Even if you do use it, you need to setup your base lighting properly first. Also see [Faking GI](https://docs.godotengine.org/en/stable/tutorials/3d/global_illumination/faking_global_illumination.html).

You should familiarize yourself with the Godot docs on [WorldEnvironment](https://docs.godotengine.org/en/stable/classes/class_worldenvironment.html), [Environment](https://docs.godotengine.org/en/stable/classes/class_environment.html), [DirectionalLight3D](https://docs.godotengine.org/en/stable/classes/class_directionallight3d.html), [Camera3D](https://docs.godotengine.org/en/stable/classes/class_camera3d.html), and [CameraAttributes](https://docs.godotengine.org/en/stable/classes/class_cameraattributes.html) and the Practical and Physical child classes. There are many options that need to be tweaked for a good looking setup, which you can learn over time.

For now though start with the sky. The built in procedural skies in Godot 4 are sub par. Use either an HDRI, a custom sky shader, or Sky3D.


#### HDRIs

High Dynamic Range Image. Use 32-bit HDR or EXR images as these have full dynamic range, which will give the highest quality reflective light. A web search will turn up many websites with paid and free options. Here are some sites with free HDRIs:

* [AllSkyFree](https://github.com/rpgwhitelock/AllSkyFree_Godot) - 8-bit PNGs, which may be fine for some projects, but they are attractive, game-centric and free; with paid options.
* [Polyhaven](https://polyhaven.com/hdris)
* [HDRI-Skies](https://hdri-skies.com/free-hdris/)
* [HDRMaps](https://hdrmaps.com/freebies/)

Once you have the file, resize it according to how much VRAM you want to consume, and how high of quality you want. 2k-4k is most likely all you need. Don't use it at 16k.

Place it in `WorldEnvironment/Environment/Sky/PanoramaSkyMaterial/Panorama`. See [PanoramaSkyMaterial](https://docs.godotengine.org/en/stable/classes/class_panoramaskymaterial.html).


#### Sky Shader

You can write your own sky material or look online for already written sky shaders. Place your `ShaderMaterial` in `WorldEnvironment/Environment/Sky`. For a shader developer there's no limit to what you can do. You could have clouds, stars, multiple suns, multiple moons. All of these features can provide reflective light that you'll see in reflections and psuedo bounce lighting.


#### Sky3D

We use use, maintain, and recommend [Sky3D](https://github.com/TokisanGames/Sky3D), which is a feature rich sky shader. It provides:
* Consolidated lighting & environmental controls
* A day/night cycle
* A game time manager

Sky3D renders a sun, moon, clouds, and fog. It's compatible with Godot's basic and volumetric fogs, plus has its own screen space fog. We've consolidated all of Godot's various lighting and environmental controls into one panel, and provide a great number of customizable options.

**Tips:**

* The Sky3D fog uses a `render_priority` of 100. This is relevant here because you want your foliage to render lower than this. However if you have text on screen with a Label3D, you want it to have a higher priority so it renders on top.



------------

## Foliage Assets

There are lots of ways to get foliage assets. You need to look around, acquire, and import into Godot, which is all out of scope for this document.

**Options:**

* Download countless available assets from other engine Asset stores. Almost all assets you have a license for can be legally exported for use and distribution in your Godot project. Check the license for your asset and considering how you want to use it.
	* FAB / Unreal Engine
	* Unity Engine
* Trees can be made with [Treeit](https://www.evolved-software.com/treeit/treeit).
* Make assets yourself in Blender.


------------

## Foliage Material

The default material in Godot is sub par for foliage. Here are some tips to improve rendering. However **[setup your lighting first!](#lighting)** You cannot properly adjust your materials if you aren't seeing objective "reality".

Many of the options below can only be done in a custom shader. But you can setup a StandardMaterial, place it in a material slot, then right-click and choose `Convert To ShaderMaterial`. This will turn the existing configuration into a shader you can edit.

The shader snippets below are incomplete. Where you see `void fragment() {` or `vertex()` it is assumed you will add the subsequent lines into that function; typically at the end. Study some shader tutorials to learn what you're doing if it's not working right.


### Texture Cards

Foliage is made up of texture cards: 2D textures UV mapped onto a flat polygon. This is also how hair works.

Many games place a grass texture on a QuadMesh or PlaneMesh, often using 2 or 3 cards in a cross or asterisk shape, like the default Terrain3DMeshAsset. 

With 3D foliage, the leaves are 2D textures UV mapped onto flat polygon cards distributed around 3D polygon branches.

For all of these cards, only one side of each polygon is the front face, the other is the back. By default, the back face is culled.

* If you want to see the back face, change `cull_mode` to disabled. In the shader, change the render mode at the top from `cull_back` to:
```glsl
render_mode cull_disabled;
```
* The above will make the back face dark in certain lighting conditions. Enable `Back Lighting` to allow light from the front side to shine through. In the shader:

```glsl
uniform vec3 backlight : source_color = vec3(.5, .5, .5);

void fragment() {
	BACKLIGHT = backlight.rgb;
}
```


### Normals

A normal is the perpendular vector of any given point of an object. This helps the renderer figure out the appropriate direction to bounce a light ray. 

Each mesh face has a normal. Each vertex has a normal. Each pixel of the normal map texture has a normal.

#### Mesh Face Normals

You've likely read about "recalculating your normals in Blender". That typically means recalculating the vector perpendicular to each **front face**. That needs to be done for proper rendering of a mesh or the lighting on it will look weird. Typically once calculated in Blender, this doesn't need to be accessed in the shader.

However, you can reverse the normals of back faces so that all faces will render like they are front faces. Note NORMAL, not NORMAL_MAP.
```glsl
void fragment() {
	NORMAL = !FRONT_FACING ? -NORMAL : NORMAL;
}
```

#### Vertex Normals

Each vertex also has a normal. If they are messed up, you might see odd lighting in the corners of mesh faces instead of on the whole mesh. These can also be reset in Blender. 

In real life, tree canopies are often lit as if they are a sphere or dome, rather than individual leaves as a 3D renderer would handle them. Some of your tree assets will look better by editing the vertex normals to mimic this quality of real trees.

```{image} images/vertex_normals.jpg
:target: ../_images/vertex_normals.jpg
```

Read more about this concept here:
* [https://ericchadwick.com/img/tree_shading_examples.html](https://ericchadwick.com/img/tree_shading_examples.html)
* [http://wiki.polycount.com/wiki/VertexNormal#Transfer_Attributes](http://wiki.polycount.com/wiki/VertexNormal#Transfer_Attributes)

You can achieve a similar affect in the shader by calculating vertex normals as they extend outward from the origin of the mesh.

```glsl
void vertex() {
	NORMAL = normalize(VERTEX); // Recalculate vertex normals from model origin
	TANGENT = normalize(cross(NORMAL, vec3(0., 0., 1.)));
	BINORMAL = normalize(cross(NORMAL, TANGENT));
}
```

#### Texture Normals

Normals applied by textures are assigned to `NORMAL_MAP`, whereas normals applied by vertices and faces are assigned to `NORMAL`.

Sometimes the normal map you got from an asset pack is not OpenGL or DirectX as you expected. Unlike with rocks, it's often much harder to visually tell them apart with foliage.

You can convert between OpenGL and DirectX by inverting the green channel either in Photoshop, in the Godot import settings, or with the shader code below. The latter is useful to be able to quickly compare how the light reflects off of the leaves. Make sure you're looking at the front face of the texture card (see above). Add the line referencing `NORMAL_MAP.g` after your NORMAL_MAP texture lookup, then you can toggle the uniform to switch.

```glsl
uniform bool directx_normals = false;

void fragment() {
	NORMAL_MAP = texture(texture_normal, base_uv).rgb;
	NORMAL_MAP.g += (1.0 - 2.0 * NORMAL_MAP.g) * float(directx_normals); // Invert Green if DirectX
}
```

### Thin Trees

The Godot renderer will quickly discard pixels of thin foliage as the camera moves away. To combat this, prefer broad leaf foliage over thin leaves like pine needles. Of course this isn't ideal for all environments. These shader snippets will also help.

For a deeper explanation, this is partially caused by mipmap averaged alpha values. As the mip level increases, the alpha can decrease due to more and more 0 alpha pixels being included. Say 51% of a leaf texture has alpha 0, with a clip threshold of 0.5. Mip0 will look as desired, but as the mip level increases the edges get blended under the clip threshold. This makes the foliage textures shrink aggressively. Disabling mipmaps for alpha clip textures will stop this happening, but results garbage noisy pixels. A lot of games use a MAX comparison when generating alpha clip texture mipmaps to help with this, though Godot doesn't currently have this option. We compensate for this in the snippets below.

* This code makes trees maintain volume at a distance. You can change `log` to `log2` or even remove it for greater thickness.  This boosts the alpha value closer to 1.0 as the distance increases, which counteracts the issue with mipmap averaging against 0 alpha.


```glsl
uniform float alpha_scissor_threshold : hint_range(0,1) = 0.5;
uniform float alpha_antialiasing_edge : hint_range(0,1) = 0.3;

void fragment() {
	ALPHA = clamp(albedo_tex.a * max(log(-VERTEX.z), 1.0), 0.0, 1.0);
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;
	ALPHA_ANTIALIASING_EDGE = alpha_antialiasing_edge;
}
```


* Alpha-to-coverage adjusts anti aliasing, which further helps foliage maintain density at a distance. Set the value to the size of your albedo texture, though there doesn't seem to be an issue if hard coded larger. e.g. 16384.

```glsl
render_mode alpha_to_coverage;

void fragment() {
	ALPHA_TEXTURE_COORDINATE = UV * vec2(albedo_texture_size);
}
```


### Artifacts

* If your mesh has weird colors or darkness that shouldn't be there. Disable `Vertex Color / Use as albedo`. In the shader, look for and remove `COLOR`, e.g. `ALBEDO = albedo_tex.rgb * COLOR.rgb`. If that wasn't the cause, the darkness might be due to normals. Read [Normals](#normals) above.

* If your leaves and branches are in reverse order, don't use `Transparency/Alpha`. Use only `Depth Pre-Pass`, or `Alpha Scissor`. The former initially appears to look better, but it puts the material in the slower transparency pipeline, and still has rendering and Z-order issues. We recommend using only `Alpha Scissors`. Also enable `Alpha Antialiasing Mode`. Then adjust `alpha_scissor_threshold` and `alpha_antialiasing_edge` to suit. Read [Thin Trees](#thin-trees) above.

* Specular and Roughness for reflective light are appropriate up close, but they can produce ugly artifacts when far away. If one or more of your plants are too shiny at a distance, fade out specular.

```glsl
uniform float specular_distance_fade : hint_range(0,1000,.1) = 15.;

void fragment() {
	vec3 camera_pos = INV_VIEW_MATRIX[3].xyz;
	vec3 pixel_pos = (INV_VIEW_MATRIX * vec4(VERTEX,1.0)).xyz;
	SPECULAR = mix(specular, 0., clamp(length(pixel_pos - camera_pos) / specular_distance_fade, 0., 1.));
}
```

* Some foliage renders with a white edge even though it's not visible on the texture.
	* First, ensure all of your texture samplers have the repeat_disable flag:
	```glsl
	uniform sampler2D texture_albedo : source_color, repeat_disable;
	``` 
	* Next, confirm if the issue is caused by the roughness or specular channels, and adjust as above.
	* Finally, if you're sure the issue is in ALBEDO, place this line *after* assigning the texture to ALPHA, and it will allow you to clip off white pixels.
	```glsl
	uniform float alpha_white_filter : hint_range(0,1) = 0.0;

	void fragment() {
		ALPHA *= step(alpha_white_filter, 1.0 - max(max(ALBEDO.r, ALBEDO.g), ALBEDO.b));
	}
	```

* Usually you want to keep your values appropriately clamped or normalized or you will get rendering artifacts. E.g. `ROUGHNESS = clamp(roughness, 0., 1.); NORMAL_MAP = normalize(normal);`. Other times, it's useful to use values higher than the typical range. E.g. `ALBEDO` and `BACKLIGHT`. Don't be afraid to experiment to find appropriate value ranges. But test extreme values on multiple cards and drivers before shipping your game or they might give you more artifacts.


### Conserve VRAM

Save as much VRAM as you can. The less data transfer across the bus, the faster your game will be. The smaller your texture files, the less data transfer. The more efficient your shader and fewer texture lookups, the less traffic on the bus.

* A lot of foliage leaves don't need metal/roughness/AO maps. If you get an asset with these maps, ensure they make a difference before using them. You can adjust roughness and specular without a map. Using only albedo and normal maps are often adequate for foliage.

* Material textures don't have to be the same resolution. You could have an 8k albedo texture that covers a lot of plants, and find that a 2k or 4k normal map is sufficient. Zoom your camera as close to the plant leaves as your player will be. If you can't tell a difference between a 2k, 4k, or 8k normal map or roughness texture, then use the smallest that makes a difference.
