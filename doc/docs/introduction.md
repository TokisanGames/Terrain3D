Introduction
=====================

Terrain3D is an editable **clipmap terrain** system divided into **regions**. It can be hand edited or manipulated through the **API**. This page provides a quick definition of these terms and a summary of the whole system.

## Clipmap Terrain

A clipmap terrain is made of several flat meshes, which have a higher density towards the center, lower farther away. By continually centering these meshes on the camera position, they provide a flat terrain with built in Levels of Detail (LODs).

```{image} images/mesh_lods_flat.jpg
:target: ../_images/mesh_lods_flat.jpg
```

The flat meshes and heightmap data are sent to the GPU, which adjusts the vertices of the clipmap, potentially every frame. Even though the mesh vertices are constantly moving, the terrain appears stable because the height data remains fixed in place.

```{image} images/mesh_lods_height.jpg
:target: ../_images/mesh_lods_height.jpg
```


## Regions

The terrain is divided into regions, which represent both physical space, and containers for terrain data.

By default, regions are 256m x 256m, and are adjustable. This lays out a grid in the world with region borders at -256, 0, 256, 512, 768, 1024, etc. This region size also corresponds to the 256x256 pixel size of the images and textures used to store terrain data.

You pay in memory and vram only for the regions you allocate. Space between the regions can be set to empty, flat, or shader generated noise (See `Terrain3D / Material / WorldBackground`). No collisions are generated outside of regions.

Region files are stored in the data directory as individual files, with their location coordinates in the filename. e.g. terrain3d_01-02.res, which represents region (+01, -02).

The region grid is visible if `View Gizmos` is enabled in the Godot `Perspective` menu. Or if `Terrain3D / Regions / Show Grid` is enabled.

## Region Location

Region locations are the grid coordinates that regions fit into. Represented as a Vector2i, eg (-1, 0), this is the primary key used for identifying regions in the API.

Converting a global position to a region location is calculated by `floor(global position / region size)`, or by calling the function [Terrain3DData.get_region_location()](../api/class_terrain3ddata.rst#class-terrain3ddata-method-get-region-location). e.g. If region size is 1024, a global position of (2500, 0, 3700) would convert to (2, 3). It gets more complicated as [region_size](../api/class_terrain3d.rst#class-terrain3d-property-region-size) changes.

Set `Terrain3D / Regions / Label Distance` to 1024-4096 to see region coordinates in the viewport.

## Vertex Painting

This system is a vertex painter, not a pixel painter. In order to make a high performance terrain, we are spreading out say a 1024 x 1024 map over 1024m^2. Each square meter is influenced by only 4 pixels in the corners. 

We use sophisticated algorithms that allow natural blending of *quality* textures between the vertices. However, it is not magic. Pixel perfect painting is not practical. Texture artists place 4k or 8k textures on a human sized rock to acheive adequate texel density. How much larger than a rock is a 1024m^2 terrain, let alone 16km^2? Achieving the same texel density on a pixel painted terrain would consume far more VRAM than anyone has.

The system we have works well for producing natural environments and is modeled off of the Witcher 3 terrain system. It will most likely work for your game as well. You'll read more about selecting and preparing quality textures in [Texture Prep](texture_prep.md) and [Texture Painting](texture_painting.md).


## API

Aplication Programming Interface. This is the [list of variables and functions](../api/index.rst) available to you via code.

Like Godot, this documentation is separated in two parts in the sidebar. The first lists various free form tutorial pages describing each aspect of the terrain system, such as what you are reading now. 

The second is the API. You can find it at the very bottom left of the document titles. You should be familiar with both documentation types in order to make full use of Terrain3D.

Finally, this documentation is versioned. Select the version that matches your version of the plugin in the menu.