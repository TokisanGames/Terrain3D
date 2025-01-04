Heightmaps
===========

Terrain3D can be used with pre-made heightmaps. They can be found online, created from heightmap generators, or downloaded from real world data.

Once you have your heightmap source, ensure it is 16 or 32-bit, scaled properly (below), and converted to `exr` or `16`. Then read [Importing Data](import_export.md) to learn how to import it. What is not covered here is how to use Photoshop, Krita, or Gimp, but you can find tutorials on YouTube.

**Table of Contents**
* [Pre-made Heightmaps](#pre-made-heightmaps)
* [Heightmap Generators](#heightmap-generators)
* [Real World Data](#real-world-data)
* [Converting Data](#converting-data)
* [Scaling](#scaling)


## Pre-made Heightmaps

A simple web search for `download terrain heightmaps` will allow you to find heightmaps in a few minutes. Some pages might say `free heightmaps for Unity` or `Unreal Engine`. All of these will work. You need to understand what format they are giving you, ensure it is at least 16 or 32-bit, and [convert](#converting-data) that to EXR for import. 

There are also asset packs for game engines like Unreal Engine or Unity that come with premade heightmaps. Both engines provide the ability to export these to a format you can use elsewhere. Be sure to verify the license of the content you're using, but generally anything you've bought can be modified and used elsewhere.


## Heightmap Generators

You can use software to generate heightmaps, and in some cases, texture layout maps (aka splat maps, index maps, or our word: control maps). You must look through the documentation of your program to determine what formats and bit depth they export, and convert if necessary.

### Free or Open Source

Search github for `heightmap generator` or `noise generator` to see the current projects. Anything that can produce *and* export a 16-bit grayscale image will work. Here are some examples.

* [wgen](https://github.com/jice-nospam/wgen) - MIT License. Written in Rust. Exports to 16-bit PNG or EXR.

* [HTerrain](https://github.com/Zylann/godot_heightmap_plugin) - MIT License. A GDScript based terrain system for Godot. It includes a terrain generator that can save a heightmap as a native Godot .res file, or you can export to EXR. Both will work for Terrain3D.

* In the future, Terrain3D will include a generator. Follow [Issue 101](https://github.com/TokisanGames/Terrain3D/issues/101) for progress.


### Commercial Software

Some of these tools are free for non-commercial use. Generally they generate both heightmaps and control maps. Currently you can only import the heightmaps into Terrain3D.

Importing a control map is possible, but requires you or a contributor to 1) research and document the proprietary control map format available in each tool, 2) create a conversion script for our importer. As programming tasks go, this is pretty easy to do. See [issue 135](https://github.com/TokisanGames/Terrain3D/issues/135) if you'd like to help with one or both.

You could export a baked image of the textures, like a satellite image and import that on our color map, and enable `Debug Views / Colormap`. This could aid you in manual texturing, or left for display purposes.

* [Gaea](https://quadspinner.com/)

* [World Machine](https://www.world-machine.com/)

* [World Creator](https://www.world-creator.com/)

* [Terragen](https://planetside.co.uk/)

* [Houdini](https://www.sidefx.com/products/houdini/) - General procedural modeling software that includes terrain generation.

* [Instant Terrain](https://www.wysilab.com/) - Terrain generation plugin for UE or Houdini.

 
## Real World Data

There are some websites that allow you to download a heightmap from real world data, however often they are unusable 8-bit heightmaps. These sites might provide usable data:

* [https://manticorp.github.io/unrealheightmap/](https://manticorp.github.io/unrealheightmap/) - exports 16-bit PNGs
* [https://touchterrain.geol.iastate.edu/](https://touchterrain.geol.iastate.edu/) - exports GeoTiff

Geographic Information System (GIS) professionals use real world world height data from satellite and aircraft mapping. Much of it is available for free from government websites. This data is often referred to as a Digital Elevation Model (DEM), or Surface (DSM) or Terrain (DTM). A DSM might contain buildings, DTM only the ground, while DEM is the umbrella term. This data may come in a variety of formats.

Example sources:

* [USGS](https://www.usgs.gov/the-national-map-data-delivery/gis-data-download) provides several tools to download DEMs and Tiffs for the US down to 1m resolution.
* [European Space Agency Copernicus program](https://ec.europa.eu/eurostat/web/gisco/geodata/digital-elevation-model/copernicus) provides DEMs for the whole world.
* [EU-DEM](https://ec.europa.eu/eurostat/web/gisco/geodata/digital-elevation-model/eu-dem) has tiff files.
* [http://www.terrainmap.com/rm39.html](http://www.terrainmap.com/rm39.html) - Here's a list of other websites with GIS data.

There are many sources available online.

Some GIS data might include sattelite imagery. You can import that into our color map, and enable `Debug Views / Colormap`.


## Converting Data

Converting data is not trivial. Understanding how your data is stored and how to convert it to another format is an essential skill for you to learn. I promise that any time spent learning this will be useful for your entire life working with computers.

Ultimately we want the data stored as an `exr` or `r16` for import into Terrain3D. See [supported formats](import_export.md#supported-formats) for more details. 

How we get there depends on your source data and tools available. Photoshop, Krita, or Gimp are the most common tools, but you might find other useful tools or even write your own scripts to convert data. How to use these tools is out of scope for this documentation. You might need to work through multiple tools to get the right format and workflow. 


### File Format

Hopefully your source data is a 16-bit PNG or Tiff/GeoTiff file, which may allow you to convert it directly just by saving the file as an EXR or r16 in Krita. GeoTiff is a Tiff file with geospatial metadata embedded.

Some Tiff formats are newer and not supported by all image editing apps, and may require experimentation with multiple tools. 

You might be able to convert it with a python script such as the following, which produces an r16 file (named raw):
```
	from PIL import Image
	import numpy

	im = Image.open('image.tif')
	imarray = numpy.array(im)
	imarray.astype('int16').tofile("image.raw")
```

If your GIS source data is in a non-image format, you can try converting it with [VTBuilder](http://vterrain.org/). Drag the file into the window, and if it loads, use `Elevation/Export To` and save it as 16-bit PNG or GeoTiff.


### Normalized Data

Once the source file is opened in an image editing program, the map might show only an outline of your landscape, with the land in solid white or red, and the ocean in black. You can use the dropper to look at the values, which should show expected values for heights in meters. This is a map with real world values. You can use tone mapping to view the image as a gradient heightmap, however you don't want to save it this way.

If the file shows a smooth gradient heightmap, then it's normalized, with all values between 0 and 1. Ensure the image is 16 or 32-bit. 8-bit will give you an ugly terraced terrain and will require a lot of smoothing to be usable.

Either normalized values or real values are fine, as long as you understand how your data is formatted and that you must scale normalized values on import. That means knowing how much to scale by, and that info should have been provided with the data source.


### Conversion Examples

* **Ex 1:** I exported a 16-bit PNG from a commercial tool. I opened the file in Photoshop and exported it as EXR. Or I could have opened it in Krita and exported as EXR or R16.

* **Ex 2:** I downloaded a Digital Elevation Model (DEM) from a govt website and received GeoTiff files. 
  * Though I've opened other GeoTiff files in Photoshop before, it couldn't read these. Krita opened them but only displayed black. 
  * I was able open them in Gimp, and reviewing the pixel data showed the ocean at `-inf`, and the land at real world values. I exported as EXR and imported to Terrain3D, but the land was extremely high. 
  * I was able to open the EXR in Photoshop and compare with my other known working EXR files. The landscape shape appeared, but the height values were extremely large. I experimented with various color management and bit depth conversions within Gimp to see if I could get a correct looking EXR in Photoshop, but couldn't. 
  * In Gimp, I exported as Tiff, which gave me a Tiff I could open in Photoshop and gave me what I was looking, except the ocean still showed `-inf`. This was a problem as it produced holes in Terrain3D, but not our kind of holes that can be filled in. 
  * In Gimp I found `Colors / RGBClip` in the menu and used it to limit `-inf` to 0, while retaining height values above 1.
  * Then I exported the Tiff to Photoshop, confirmed the values looked good, exported that to EXR for import and finally got the desired result.


## Scaling

Terrain3D generally expects a ratio of 1px = 1m lateral space with real world heights, and provides options for manipulating these. In order to get expected results on import, there are two important characteristics you need to understand about your data:

1. **Vertical Scale**. If your data is not normalized, your data has real values and vertical scale should remain 1 on import. Most likely 0 is defined as sea level. This is how Terrain3D stores data internally. If your data is normalized with values 0-1, you can multiply by a vertical scale in the import tool to set the peak height according to what your source defines. You can also apply an offset to adjust how your data aligns with 0.

2. **Vertical Aspect Ratio (VAR)**. This is often called `resolution` in GIS and terrain documentation, but there is a crucial distinction from image resolution. Your data has an inherent ratio of lateral space to height, or a 3D aspect ratio of XZ to Y. Terrain3D expects 1px = 1m with real world heights, giving a VAR of 1m lateral to 1m vertical. If your data is 1px = 10m with real world heights, the VAR is 10:1, different by a factor of 10. This can be adjusted by scaling the heightmap image in Photoshop before import (preferred), or scaling the heights on import, or adjusting [Mesh / Vertex Spacing](../api/class_terrain3d.rst#class-terrain3d-property-vertex-spacing) on or after import.


### Scaling Examples

Here are some examples of adjusting settings to account for both of these both of these characteristics. These examples will be more meaningful if you have read the [import doc](import_export.md) and have imported at least one heightmap first.

* **Ex 1**: I downloaded GIS data that is a 20m resolution DEM and received a GeoTiff. Upon loading it in Photoshop, the dropper tool revealed that sea level is at 0 and other points on land have real world values in meters. This means the vertical scale is built in, and every 1px on the map represents 20m of lateral space, which represents our VAR of 20:1. I want to work with this map in Terrain3D at the default resolution of 1px = 1m.
  * **Option 1**: In Photoshop I crop the image down to a small 500x500px area that I want to import, then scale the image 20x to 10k x 10k. 
	* Given the large image size, in Terrain3D I increase the region size to 512 (10k / 32 = 312.5 minimum). (Read [why 32](introduction.md#regions)). 
	* Next I import with a scale of 1, offset of 0, and leave vertex_spacing at 1. 
	* I now have an accurate representation of the data within Terrain3D that I can sculpt and refine with the standard vertex spacing. This consumes the VRAM required for a 10k x 10k heightmap. A lot of that is wasted if I do nothing else, since I duplicated the pixels 20x without adding any new data. However this process has given me an accurate base to start sculpting and add my own detail at a reasonable resolution. This is likely my preferred path for real world data.
  * **Option 2**: I import the original image with scale set to 0.05 (1/20th). Now in Terrain3D I have a visually accurate representation of the data, given that the VAR is correct. However if I were to measure the heights, they would be 1/20th their real world values. 1px = 20m and height = 1/20th. There's no wasted VRAM due to duplication of pixels. This is a good path if I only want to visualize the data.
  * **Option 3**: I import the image with a scale of 1. In Terrain3D, it will look very spiky. I increase vertex_spacing to 20. Like the option above, there's no wasted VRAM. This gives I accurate heights, but the world might look a bit low poly.

* **Ex 2**: I exported a heightmap from a commercial tool and received 4 tiled 1024x1024 heightmaps. Upon opening them in Photoshop, they look like gradient heightmaps and the dropper tool confirms the data is normalized with values between 0-1. I was informed the lowest trough is -500m, highest peak 1500m, sea level is 0, and the resolution is 4px to 1m.
  * **Option 1**: In Photoshop, I combine the four tiles into one 4k image. 
	* Then I scale the whole image by 4 to 16k. 
	* On import to Terrain3D, I change region size to 512, set offset to -500m, and scale to 2000m (1500m - -500m). I change vertex_spacing to 0.25. 
	* I now have an accurate representation of the data, and am consuming the VRAM for a 16k x 16k map for a high resolution 4k x 4k world. 0.25m is probably overkill and the increased vertex density does have a performance cost.
  * **Option 2**: After combining and scaling the images into one 16k image, I scale the resolution down to 4k. This erases data between each meter. 
	* On import, I repeat the region size, offset, and scale as above, but leave vertex_spacing at 1. 
	* I still have a 4k x 4k world, with an accurate scale and VAR, but now my terrain resolution is a more optimal 1m. I could also split the difference with a 0.5 or 0.667 vertex_spacing.

Read [Importing Data](import_export.md) to learn how to import your EXR.
