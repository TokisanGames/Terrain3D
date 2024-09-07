Introduction
=====================

Terrain3D is an editable **clipmap terrain** system divided into **regions**. It can be hand edited or manipulated through the **API**. This page is a quick summary of the whole system.

## Clipmap Terrain

A terrain made of several flat meshes. The density of the vertices is higher in the center, sparser farther away. By continually centering these meshes on the camera position, they provide a flat terrain with built in Levels of Detail (LODs).

```{image} images/mesh_lods_flat.jpg
:target: ../_images/mesh_lods_flat.jpg
```

The flat meshes and heightmap data are sent to the GPU, which adjusts the vertices of the clipmap, potentially every frame. Even though the mesh vertices are constantly moving, the terrain appears stable because the height data remains fixed in place.

```{image} images/mesh_lods_height.jpg
:target: ../_images/mesh_lods_height.jpg
```


## Regions

The terrain is divided into regions, which represent both physical space, and containers for terrain data.

By default, regions are 1024m x 1024m, which will be adjustable in the near future. This describes a physical grid in the world with borders at -1024, 0, 1024, 2048, etc. This also corresponds to the 1024x1024 pixels size of the images and textures used to store terrain data.

A 16km x 16km terrain might be broken up into 16 x 16 (256) regions, each sized 1024m x 1024m. However one need not fill out the entire world space. A game could have 3 islands with 10 regions a piece within a larger 16km world. Rather than consuming the memory for 16k x 16k maps (256 regions, 268M pixels), it would only consume 30 x 1k maps (30 regions, 31M pixels).


## Region Location

Region locations are the grid coordinates that regions fit into. Represented as a Vector2i, eg (-1, 0), this is the primary key used for identifying regions in the API.

Converting a global position to a region location is calculated by `floor(global position / region size)`, or by calling the function [Terrain3DData.get_region_location()](../api/class_terrain3ddata.rst#class-terrain3ddata-method-get-region-location). e.g. If region size is 1024, a global position of (2500, 0, 3700) would convert to (2, 3). It gets more complicated as region sizes change.

Enable `Terrain3D / Debug / Show Region Labels` to view locations in the world.


## Global Position

Global position is the absolute X, Y, Z coordinates of a node in the 3D world. *(Non-global)* position means the X, Y, Z coordinates are relative to its parent's global position.


## Active Regions

Active regions are those rendered on screen. This means they're loaded in the list of Terrain3DData.region_locations, and are not marked for deletion.


## Vertex Painting

This system is a vertex painter, not a pixel painter. In order to make a high performance terrain, we are spreading out say a 1024 x 1024 map over 1024m^2. Each square meter is influenced by only 4 pixels in the corners. 

We use sophisticated algorithms that allow natural blending of *quality* textures between the vertices. However, it is not magic. Pixel perfect painting is not practical. Texture artists place 4k or 8k textures on a boulder to acheive adequate texel density. How much larger is even a 1024m x 1024m terrain, let alone 16km x 16km? Achieving the same texel density where pixel painting is practical would consume far more VRAM than you have.

The system we have works well for producing natural environments and is modeled off of the Witcher 3 terrain system. It will most likely work for your game as well. You'll read more about selecting and preparing good textures in [Texture Prep](texture_prep.md) and [Texture Painting](texture_painting.md).


## API

Aplication Programming Interface. This is the [list of variables and functions](../api/index.rst) available to you via code.

Like Godot, this documentation is separated into two parts. The first are various free form tutorial pages describing each aspect of the terrain system, such as what you are reading now. 

The second is the API. You can find it at the very bottom left of the document titles. You should be familiar with both documentation types so you can make full use of Terrain3D.
