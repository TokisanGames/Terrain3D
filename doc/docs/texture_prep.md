Preparing Textures
=========================

Terrain3D supports up to 32 texture sets using albedo, height, normal, and roughness textures, each set are channel packed into 2 files. This page describes everything you need to know to prepare your texture files. Continue on to [Texture Painting](texture_painting.md) to learn how to use them.

**Table of Contents**
* [Texture Requirements](#texture-format-requirements)
* [Texture Content](#texture-content)
* [Channel Pack Textures in Terrain3D](#channel-pack-textures-in-terrain3d)
* [Channel Pack Textures with Gimp](#channel-pack-textures-with-gimp)
* [Where to Get Textures](#where-to-get-textures)
* [Frequently Asked Questions](#faq)


## Texture Format Requirements

### Texture Packing

Typically "a texture" comes as a pack of individual texture map files: albedo/diffuse/base color, height/displacement, normal, smoothness/roughness, ambient occlusion (AO). For maximum efficiency we provide the option of packing these 5 separate files into 2 files, which we call a texture set.

Terrain3D is designed for texture sets that are channel-packed as follows:

| Name | Format |
| - | - |
| albedo_texture | RGB: Albedo, A: Height
| normal_texture| RGB: Normal map ([OpenGL](#normal-map-format)), RGB: [AO](#ambient-occlusion), A: [Roughness](#roughness-vs-smoothness)

The terrain can work without height, normal, AO, or roughness textures, but then you won't have height blending, roughness, or other features. This may be fine for a low-poly or stylized terrain, but a realistic terrain should use all of the textures you have available.

Textures can be channel packed using the `Pack Textures...` option in the Terrain3D menu at the top of the viewport (recommended), or with professional texture authoring tools. [Gimp](https://www.gimp.org/), Photoshop, or [Krita](https://krita.org/) are possible, but working with alpha channels or baking AO can be challenging.


### Texture Sizes

All albedo textures must be the same size, and all normal textures must be the same size. Each type gets combined into separate Texture2DArrays, so the texture sizes of the two arrays can differ.

Double-clicking a texture file in the FileSystem panel will display it in the Inspector and show the currently imported format, size, mipmaps and VRAM consumption. Settings may be adjustable on the Godot Import tab.

The demo textures are 1024x1024.

For GPU efficiency, it is recommended that all of your textures have dimensions that are a power of 2 (128, 256, 512, 1024, 2048, 4096, 8192), but this isn't required.

### Compression Format

All albedo textures must be the same format, and all normal textures must be the same format. Albedo and Normals are combined into separate Texture2DArrays, so the two can have different formats.

Double-clicking a texture file in the FileSystem panel will display it in the Inspector and show the currently imported format, size, mipmaps and VRAM consumption. Settings may be adjustable on the Godot Import tab.

The demo textures are PNG imported as HQ, which are converted to BPTC.

| Type | Supports | Format |
| - | - | - |
| **PNG** | Desktop, Mobile | RGBA, converts to DXT5 or BPTC (HQ). In Godot, go to the Import tab and select: `Mode: VRAM Compressed`, `Normal Map: Disabled`, `Mipmaps Generate: On`, optionally check `High Quality`, then reimport each file. 
| **DDS** | Desktop | BC3 / DXT5, linear (intel plugin), Color + alpha, mipmaps generated. These files are used directly by Godot and are not converted, so there are no import settings.
| **Others** | | Other [Godot supported formats](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_images.html#supported-image-formats) like KTX, TGA, JPG, WEBP should work as long as you match similar settings to PNG.
| **EXR** | | While EXRs can work, they store color data as 16/32-bit float, not 8-bit integer. Don't use them for terrain textures unless you know what you're doing.

The best recommendation right now for mobile or desktop is to pack textures with our channel packer, save as PNG, and set VRAM compressed, mipmaps, and HQ in the Godot import settings.

Notes on DDS files: Godot does not currently support importing anything higher than BC3/DXT5 in DDS files. If you use PNG with HQ set, Godot will convert it to BC6/BPTC. The standard PNG import converts to BC3/DXT5, however the compression algorithm isn't great. DDS (BC3/DXT5) files made in Gimp are much higher quality than the standard non-HQ PNG settings. When creating DDS files in Gimp you have a lot more conversion options, such as different mipmaps filtering algorithms which can be helpful to remove artifacts in reflections (eg try Mitchell). However packing in Gimp means no AO maps.

You can create DDS files by:
  * Exporting directly from Gimp
  * Exporting from Photoshop with [Intel's DDS plugin](https://www.intel.com/content/www/us/en/developer/articles/tool/intel-texture-works-plugin.html)
  * Converting RGBA PNGs using [NVidia's Texture Tools](https://developer.nvidia.com/nvidia-texture-tools-exporter)

You can create KTX files with [Khronos' KTX tools](https://github.com/KhronosGroup/KTX-Software/releases).


## Texture Content

### Seamless Textures

Make sure your textures are seamless and can be repeated without an obvious seam.

### Height Textures

If creating your own height textures, aim for a central point of grey (0.5) with bumps and divots above and below that value. Adjust the contrast so that troughs and peaks reach just about 0 and 1.

### Normal Map Format

Normal maps come in two formats: DirectX with -Y, and OpenGL with +Y. Both formats should be normalized.

DirectX can be converted to OpenGL and vice versa by inverting the green channel in a photo editing app, or in our texture packing tool.

They can often be identified visually by whether bumps appear to stick out (OpenGL) or appear pushed in (DirectX). The sphere and pyramid on the left in the image below are the clearest examples. 

```{image} images/tex_normalmap.png
:target: ../_images/tex_normalmap.png
```

Natural textures like rock or grass can be very difficult to tell. However if you get assets made for a certain engine like Unreal or Unity, you can generally assume their format and convert as needed. On occasion artists get it wrong though, so if the lighting looks off on your texture, try inverting the normal map.

| Software | DirectX | OpenGL |
|----------|---------|--------|
| 3DS Max				| ✓ | |
| Blender				| | ✓ |
| Cinema 4D				| | ✓ |
| CryEngine				| ✓ | |
| Godot Engine			| | ✓ |
| Houdini				| | ✓ |
| Marmoset Toolbag		| | ✓ |
| Maya					| | ✓ |
| Substance Painter		| ✓ | |
| Unity					| | ✓ |
| Unreal Engine			| ✓ | |
| Zbrush				| | ✓ |

### Roughness vs Smoothness

Some "roughness" textures are actually smoothness or gloss textures. You can convert between them by inverting the image in an image editor, or in our texture packing tool.

You can tell which is which just by looking at distinctive textures and thinking about the material. If it's glass it should be glossy, so on a roughness texture values will be near 0 and the texture will appear mostly black. If it's dry rock or dirt, it should be mostly white, which is near 1 roughness. A smoothness texture would show the opposite.


### Ambient Occlusion

Our built in texture packing tool allows you to easily combine AO texture maps into your normal texture set using a clever technique. We expect the normals on your normal map to be normalized (typical), which means the magnitude of the normal vector can be scaled by the AO value.

AO maps are not required for any texture. You can even mix and match AO or no AO on different textures, unlike with sizes or formats. If you haven't included an AO texture, AO will be approximated from the normal map.

If you wish to apply AO to your textures manually or in another tool, ensure your normal map is normalized, then bake in AO with: `unpacked_normal_vector * (sqrt(ao) * 0.5 + 0.5)`.


## Channel Pack Textures in Terrain3D

We recommend you use our built in tool to pack textures.

```{image} images/terrain3d_menu.png
:target: ../_images/terrain3d_menu.png
```

1. At the top of your viewport, click the `Terrain3D` menu, then `Pack Textures`.
2. Select your textures for albedo and height.
3. Optionally, select textures for normal, roughness, and if desired ambient occlusion
4. Optionally, convert a DirectX normal map to OpenGL, or smoothness to roughness map.
5. Optionally, enable Orthogonalise normals if you see a reflective checkerboard pattern appear when using detiling.
6. Click `Pack Textures As...` and save the resulting PNG files to disk.
7. Go to the Import tab and one at a time, select your new PNG files, specify the following settings and click `reimport`. 
	* `Mode: VRAM Compressed`
	* Optional: `High Quality: On` if you wish BPTC instead of DXT5.
	* `Normal Map: Disabled`
	* `Mipmaps Generate: On`

Make sure to reimport both files. Double click each file in the filesystem and ensure the inspector reveals the expected format and size. All of the files you put in your texture list must match.


## Channel Pack Textures with Gimp

> Note: Packing AO into a normal map is optional and we currently don't have a process for Gimp. Use our channel packer to include AO maps.

1. Open your RGB Albedo and greyscale Height files (or Normal and Roughness).

2. On the RGB file select `Colors/Components/Decompose`. Select `RGB`. Keep `Decompose to layers` checked. On the resulting image you have three greyscale layers for RGB. 

3. Copy the greyscale Height (or Roughness) file and paste it as a new layer into this decomposed file. Name the new layer `alpha`.

This would be a good time to invert the green channel if you need to convert a Normalmap from DirectX to OpenGL, or to invert the alpha channel if you need to convert a smoothness texture to a roughness texture.

4. Select `Colors/Components/Compose`. Select `RGBA` and ensure each named layer connects to the correct channel.

5. Now export the file with the following settings. DDS is highly recommended. 

Also recommended is to export directly into your Godot project folder. Then drag the files from the FileSystem panel into the appropriate texture slots. With this setup, you can make adjustments in Gimp and export again, and Godot will automatically update with any file changes.

### Exporting As DDS
* Change `Compression` to `BC3 / DXT5`
* `Mipmaps` to `Generate Mipmaps`. 
* Optionally, change the `Mipmap Options` `Filter`, such as to Mitchell if you get reflection artifacts in your normal+roughness texture.
* Insert into Godot and you're done.

```{image} images/io_gimp_dds_export.png
:target: ../_images/io_gimp_dds_export.png
```

### Exporting As PNG
* Change `automatic pixel format` to `8bpc RGBA`. 
* In Godot you must go to the Import tab and select: `Mode: VRAM Compressed`, `Normal Map: Disabled`, `Mipmaps Generate: On`, then click `Reimport`.

```{image} images/io_gimp_png_export.png
:target: ../_images/io_gimp_png_export.png
```

## Where to Get Textures

### Texture Creation Software

You can make textures in dedicated texture software, such as those below. There are many other tools and ai texture generators to be found online. You can also paint textures in applications like krita/gimp/photoshop.
 
* [Materialize](http://boundingboxsoftware.com/materialize/) - Great free tool for generating missing maps. e.g. you only have an albedo texture that you love and want to generate a normal and height map
* [Material Maker](https://www.materialmaker.org/) - Free, open source material maker made in Godot
* [ArmorLab](https://armorpaint.org/) - Free & open source texture creator
* Substance Designer - Commercial, "industry standard" texture maker


### Download Textures

There are numerous websites where you can download high quality, royalty free textures for free or pay. These textures come as individual maps, with the expectation that you will download only the maps you need and then channel pack them. Here are just a few:

* [PolyHaven](https://polyhaven.com/textures) - many free textures (Download PNG, not EXR)
* [AmbientCG](https://ambientcg.com/) - many free textures
* [Poliigon](https://www.poliigon.com/textures/free) - free and commercial
* [GameTextures](https://gametextures.com/) - commercial
* [Textures](https://www.textures.com/) - commercial

## FAQ

### Why do we have to channel pack textures? Why is this so difficult?

You don't have to pack your textures. You can use just the albedo map, or also just the normal map, without height, roughness, or AO. However if you want a realistic terrain with height blending and other features, you need all of the maps.

Channel packing is a very common task done by professional game developers using every engine. Performing this process once, allows us to store the data for 5 raw texture maps in the space of only 2 textures, saving precious VRAM. Every pro asset pack you've used has channel packed textures for this reason. When you download texture packs from websites, they provide individual textures so you can pack them how you want. They are not intended to be used individually!

We offer a built in `Pack Textures` tool, found in the Terrain3D menu at the top of the viewport that facilitates the texture creation process without leaving Godot. Packing a texture set can be done in 30 seconds.

Finally, we provide easy, 5-step instructions for packing textures with Gimp, which takes less than 2 minutes once you're familiar with the process. 

If we want high performance games, we need to optimize our games for graphics hardware. A shader can retrieve four RGBA channels from a texture at once. Albedo and Normal textures only use RGB. Thus, reading Alpha is free, and a waste if not used. So, we put height / roughness in the Alpha channel.

We could have the software let you specify individual maps and we pack textures for you at startup, however that would mean processing up to 160 images every time any scene with Terrain3D loads, both in the editor and running games. Exported games may not even work since Godot's image compression libraries only exist in the editor. The most reasonable path is for gamedevs to learn a simple concept that they'll use for their entire career across all engines, and process their terrain textures one time.

### What about Emissive, Metal, and other texture maps?

Most terrain textures like grass, rock, and dirt do not need these. 

Occasional textures do need additional texture maps. Lava rock might need emissive, or rock with gold veins might need metallic, or some unique texture might need both. These are most likely only 1-2 textures out of the possible 32, so setting up these additional options for all textures is a waste of memory. However, you can [customize the shader](tips_technical.md#add-a-custom-texture-map) to add an individual texture map.

### Why not use Standard Godot materials?

All materials in Godot are just shaders. The standard shader is both overly complex, and inadequate for our needs. Dirt does not need SSS, refraction, or backlighting for instance. See [a more thorough explanation](https://github.com/TokisanGames/Terrain3D/issues/199).

### What about displacement?

Godot doesn't support texture displacement via tessellation or geometry shaders in the renderer. However, we provide the option of subdividing the terrain mesh, to allow textures to displace vertices. For further details see [Displacement](displacement.md).

Effects like depth parallax or occlusion mapping etc require many samples in fragment, which can be prohibitivley expensive when applied to already complex terrain shaders. There are [alternatives](https://github.com/TokisanGames/Terrain3D/issues/175) that might prove useful in the future.

### What about...

We provide a base shader with the most commonly needed terrain options. Then we provide the option for a custom shader so you can explore `what about` on your own. Any of the options in the Godot StandardMaterial can be converted to a shader, and then you can insert that code into a custom shader. You could experiment with Godot's standard depth parallax technique, any of the alternatives above, or anything else you can imagine such as a sinewave that ripples the vertices outward for a VFX ground ripple effect, or ripples on a puddle ground texture.

