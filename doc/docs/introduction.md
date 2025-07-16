Introduction
=====================

Terrain3D is an editable **clipmap terrain** system divided into **regions**. Data can be hand edited or manipulated through the **API** in realtime. This page summarizes the core concepts of the whole system.


## Clipmap Terrain

This is a Geomorphing Geometric Clipmap Mesh Terrain, as used in The Witcher 3. The terrain is made of several flat meshes, which have a higher density towards the center, and lower farther away. This provides the infrastructure for automatic Level of Detail (LOD) handling.

```{image} images/mesh_lods_flat.jpg
:target: ../_images/mesh_lods_flat.jpg
```

The LODs are then blended together in a circular pattern. 

```{image} images/mesh_circular_lods.png
:target: ../_images/mesh_circular_lods.png
```

As the camera moves, the terrain meshes are centered on the camera, keeping higher LODs near the camera and lower LODs far away. The meshes and height data are sent to the GPU which updates the vertices of the mesh every frame. Even though the meshes are constantly moving, the terrain appears stable because the height data remains fixed in place.

See [System Architecture](system_architecture.md) for more details.


## Regions

The terrain is divided into regions, which represent both physical space, and containers for terrain data.

By default, regions are 256m x 256m, but can range between 64m and 2048m. The region size defines a grid in the world with borders at -256, 0, 256, 512, 768, 1024, etc. This region size also corresponds to the 256x256 pixel size of the images and textures used to store terrain data. These sizes are independent of your ground texture sizes.

You pay in memory and VRAM only for the regions you allocate. Space between the regions can be set to empty, flat, or shader generated noise (See `Terrain3D / Material / WorldBackground`). No collisions are generated outside of regions.

```{image} images/regions_used.jpg
:target: ../_images/regions_used.jpg
```

There is currently a limit of 1024 regions or 32 x 32. So the maximum dimensions of the your world are `32 * region_size`, the maximum being 32 * 2048 or 65,536m per side.

Region files are stored in the data directory as individual files, with their location coordinates in the filename. e.g. terrain3d_01-02.res, which represents region (+01, -02).

The region grid is visible if `View Gizmos` is enabled in the Godot `Perspective` menu. Or if `Terrain3D / Regions / Show Grid` is enabled.


## Region Location

Region locations are the grid coordinates that regions fit into. Represented as a Vector2i, eg (-1, 0), this is the primary key used for identifying regions in the API.

Converting a global position to a region location is calculated by `floor(global position / region size)`, or by calling the function [Terrain3DData.get_region_location()](../api/class_terrain3ddata.rst#class-terrain3ddata-method-get-region-location). e.g. If region size is 1024, a global position of (2500, 0, 3700) would convert to (2, 3). It gets more complicated as [region_size](../api/class_terrain3d.rst#class-terrain3d-property-region-size) changes.

Set `Terrain3D / Regions / Label Distance` to 1024-4096 to see region coordinates in the viewport.


## Vertex Painting

This system is a vertex painter, not a pixel painter. In order to make a high performance terrain, we are spreading out say 1024 x 1024 pixels over 1024m x 1024m. Each square meter is influenced by only 4 pixels of data in the corners. 

We use sophisticated algorithms that allow natural blending of *quality* textures between the vertices. However, it is not magic. Pixel perfect painting is not practical. Texture artists place 4k or 8k textures on a human sized rock to acheive adequate texel density. How much larger than a rock is a 1024m x 1024m terrain, let alone 16km x 16km? Achieving the same texel density on a pixel painted terrain would consume far more VRAM than anyone has.

The system we have works well for producing natural environments and is modeled off of the Witcher 3 terrain system. It will most likely work for your game as well. You'll read more about selecting and preparing quality textures in [Texture Prep](texture_prep.md) and [Texture Painting](texture_painting.md).


## API

Aplication Programming Interface. This is the [list of variables and functions](../api/index.rst) available to you via code.

Like Godot, this documentation is separated in two parts in the sidebar. The first lists various free form tutorial pages describing each aspect of the terrain system, such as what you are reading now. 

The second section is the API. You can find it at the very bottom left of the document titles. The API is also built into the Godot editor help system, once Terrain3D is installed.

Finally, this documentation is versioned. Select the version that matches your version of the plugin in the menu.
