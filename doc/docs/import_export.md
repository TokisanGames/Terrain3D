Importing & Exporting Data
===========================

This page describes how to get data into or out of our tool. You should read [Heightmaps](heightmaps.md) to learn about preparing files from various data sources.

Currently importing and exporting is possible via code or our import tool. We will [make a UI](https://github.com/TokisanGames/Terrain3D/issues/81) eventually. In the meantime, we have written a script that uses the Godot Inspector as a makeshift UI. You can use it to make a data file for your other scenes.

**Table of Contents**
* [Supported Formats](#supported-formats)
* [Importing Data](#importing-data)
* [Exporting Data](#exporting-data)
* [Exporting GLTF](#exporting-gltf)


## Supported Formats

Terrain3D has three map types you can import or export: [Height](../api/class_terrain3dregion.rst#class-terrain3dregion-property-height-map), [Control](../api/class_terrain3dregion.rst#class-terrain3dregion-property-control-map), and [Color](../api/class_terrain3dregion.rst#class-terrain3dregion-property-color-map).

We can import any supported image format that Godot can read, however we have recomendations below for specific formats to use for the different maps.

### Import Formats

* [Godot supported Image file formats](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_images.html#supported-image-formats): `bmp`, `dds`, `exr`, `hdr`, `jpg`, `jpeg`, `png`, `tga`, `svg`, `webp`
* [Godot resource files](https://docs.godotengine.org/en/stable/classes/class_image.html#enum-image-format): Any data format listed at the link stored as a `tres` or `res`. 
* `exr`: Should be RGB not greyscale, 16 or 32-bit float, no transparency. Older versions of Photoshop can use [exr-io](https://www.exr-io.com/).
* `png`: Godot only supports 8-bit PNGs. This works fine for the colormap, but not for heightmaps.
* `r16`: for heightmaps only. Values are scaled based on min and max heights and stored as 16-bit unsigned int. Can be read/written by Krita. Min/max heights and image dimensions are not stored in the file, so you must keep track of them elsewhere, such as in the filename.
* `raw`: This is not a format specification! It just means the file contains a dump of values. But what format are the values? They could be 8, 16, or 32-bit, signed or unsigned ints or floats, little or big endian byte order (aka Windows or macOS, Intel or Arm/Motorola). In order to read this file you need to know all of these, *and* the dimensions. `Photoshop Raw` only supports 8/16/32-bit float, little or big endian. **Terrain3D interprets raw as r16**, as does Unity, Unreal Engine, and various commercial software.

### Export Formats

* [Godot supported Image save functions](https://docs.godotengine.org/en/stable/classes/class_image.html#class-image-method-save-exr): `exr`, `png`, `jpg`, `webp`
* `r16`: for heightmaps only.
* `res`: Godot binary resource file with `ResourceSaver::FLAG_COMPRESS` enabled. The format contained inside is defined in our API linked at the top of this section for each map type.
* `tres`: Godot text resource file. Not recommended.

 
### Height Map Recommendations

* Use `exr` or `r16/raw`. 
* If you have a 16-bit `png`, convert it.
* Only use 16 or 32-bit height data. If your data is only 8-bit, it will look terraced and require a lot of smoothing to be useable. You could convert the image to 16-bit and blur it a bit in Photoshop.
* [Zylann's HTerrain](https://github.com/Zylann/godot_heightmap_plugin/) stores height data in a `res` file which we can import directly. No need to export it first, though his tool also exports `exr` and `r16`.

 
### Control Map Recommendations

* Our control maps use a [proprietary format](controlmap_format.md). We currently only import our own format. Use `exr` to export and reimport only from this tool. This is only for transferring the data to another Terrain3D data file.


### Color Map Recommendations

* Any regular color format is fine. 
* `png` or `webp` are recommended as they are lossless, unlike `jpg`.
* The alpha channel is interpretted as a [roughness modifier](../api/class_terrain3ddata.rst#class-terrain3ddata-property-color-maps) for wetness. So if you wish to edit the color map in an external program, you may need to disable the alpha channel first.


## Importing Data

1. Open `addons/terrain_3d/tools/importer.tscn`.

2. Click Importer in the scene tree.

```{image} images/io_importer.png
:target: ../_images/io_importer.png
```

3. If you're importing a large file, you need to adjust `Terrain3D / Regions / Region Size`. You only get [1024 regions (32x32)](introduction.md#regions) so you need a region size greater than `image width / 32`. E.g., importing 10k x 10k means 10,000/32 = 312.5, so a minimum region size of 512 is required.

4. In the inspector, select a file for height, control, and/or color maps. See [formats](#supported-formats) above. File type is determined by extension.

5. Specify the `import_position` of where in the world you want to import. Values are rounded to the nearest `region_size` (defaults to 256). So a location of (-2000, 1000) will be imported at (-2048, 1024).

     Notes:
     * You can import multiple times into the greater world map by specifying different positions. So you could import multiple maps as separate islands or combined regions.
     * It will slice and pad odd sized images into region sized chunks (default is 256x256). e.g. You could import a 4k x 2k, several 1k x 1ks, and a 5123 x 3769 and position them so they are adjacent.
     * You can also reimport to the same location to overwrite anything there using individual maps or a complete set of height, control, and/or color.

6. Specify any desired `height_offset` or `import_scale`. The scale gets applied first. (eg. 100, -100 would scale the terrain by 100, then lower the whole terrain by 100).

     * We store full range values. If you sculpt a hill to a height of 50, that's what goes into the data file. Your heightmap values (esp w/ `exr`) may be normalized to the range of 0-1. If you import and the terrain is still flat, try scaling the height up by 300-500.
     * See [Scaling](heightmaps.md#scale) for more details on proper scaling and offset.

7. If you have a RAW or R16 file (same thing), it should have an extension of `r16` or `raw`. You can specify the height range and dimensions next. These are not stored in the file so you must know them. I prefer to place them in the filename.

8. Click `Run Import` and wait 10-30 seconds. Look at the console for activity or errors. If the `Terrain3D.debug_level` is set to `debug`, you'll also see progress.

9. When you are happy with the import, scroll down in the inspector until you see `Terrain3D / Data Directory`. Specify an empty directory and save.


```{image} images/io_data_directory.png
:target: ../_images/io_data_directory.png
```

You can now load this directory into Terrain3D in any of your scenes. You can also load an existing data directory in the importer, then import more data into it and save it again.


## Exporting Data

1. Open `addons/terrain_3d/tools/importer.tscn`.

2. Click Importer in the scene tree.

3. Scroll the inspector down to `Terrain3D / Data Directory`, and load the directory you wish to export from.

```{image} images/io_data_directory.png
:target: ../_images/io_data_directory.png
```

4. Scroll the inspector to `Export File`.

```{image} images/io_exporter.png
:target: ../_images/io_exporter.png
```

5. Select the type of map you wish to extract: Height (32-bit floats), Color (rgba), Control (proprietary).

6. Specify the full path and file name to save. The file type is determined based upon the extension. You can enter any location on your hard drive, or preface the file name with `res://` to save it in your Godot project folder. See [formats](#supported-formats) for recommendations.

7. Click `Run Export` and wait. 10-30s is normal. Look at your file system or the console for status.

Notes:

* The exporter takes the smallest rectangle that will fit around all active regions in the world and export that as an image. So, if you have a 1k x 1k island in the NW corner, and a 2k x 3k island in the center, with a 1k strait between them, the resulting export image will be something like 4k x 5k. You'll need to specify the location (rounded to `region_size`) when reimporting to have a perfect round trip.

* The exporter tool does not offer region by region export, but there is an API where you can retrieve any given region, then you can use `Image` to save it externally yourself.

* Upon export, the console reports the image size and minimum/maximum heights, which is necessary for r16 heightmap exports.

## Exporting GLTF

You can also export the terrain as a mesh.

1. Create a new scene, and add a Terrain3D node.
2. Load your terrain `Data Directory`.
3. Select the Terrain3D Above the viewport, select the Terrain3D 
4. At the top of the viewport, select `Terrain3D / Bake ArrayMesh...` and bake at the desired LOD.
5. Delete the Terrain3D and other nodes, leaving only the generated MeshInstance3D node in this scene.
6. In the Godot menu, select `Scene / Export As... / GLTF 2.0 Scene...`.

You can then use this mesh in Blender or other tools for reference. It's fine for reference, but isn't an optimal mesh as there is a vertex every meter. You can decimate or remesh it if you need a more optimal version.
