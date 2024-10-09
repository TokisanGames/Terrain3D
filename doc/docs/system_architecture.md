System Architecture
=====================

## Geometry Clipmap Terrain
Some terrain systems generate a grid of mesh chunks, centered around the camera. As the camera moves forward, old meshes far behind are destroyed and new meshes in front are created.

Like The Witcher 3, this system uses a geometry clipmap, where the mesh components are generated once, and at periodic intervals are centered on the camera location. On each update, the vertex heights of the mesh components are adjusted by the GPU in the vertex shader, by reading from the terrain heightmap. Levels of Detail (LODs) are built into the mesh generated on startup, so don't require any additional consideration once placed. Lower detail levels are automatically placed far away once all mesh components are recentered on the camera. See Mike Savage's blog for visual examples.

We provide a system where one can allocate regions for sculpting and texturing and only pay the VRAM and storage costs for only the areas used. Think of a world that takes up 16k x 16k, but has multiple small islands. Rather than pay for 16k, our system requires only allocates memory for the regions that contain the islands. The space in between can be flat, hidden, or have collision-less shader generated noise.


### Reference Material
* Mike J. Savage: [Geometry clipmaps: simple terrain rendering with level of detail](https://mikejsavage.co.uk/blog/geometry-clipmaps.html)

* NVidia GPU Gems 2: [Terrain Rendering Using GPU-Based Geometry Clipmaps](https://developer.nvidia.com/gpugems/gpugems2/part-i-geometric-complexity/chapter-2-terrain-rendering-using-gpu-based-geometry)

* GDC 2014: [The Witcher 3 Clipmap Terrain and Texturing](https://archive.org/details/GDC2014Gollent) - [Slides](https://ubm-twvideo01.s3.amazonaws.com/o1/vault/GDC2014/Presentations/Gollent_Marcin_Landscape_Creation_and.pdf)

## Architecture
Here is a diagram showing what the classes do and how they communicate.

```{image} images/sa_uml.png
:target: ../_images/sa_uml.png
```

## Architectural Design Principles

### 1 Pixel == 1 Vertex

Currently, we maintain a constant ratio where 1 pixel on height, control, and color maps correlates to 1 world vertex, on LOD0. 

We provide variable region sizes which limit the number of vertices allocated, and `Terrain3D.vertex_spacing` to allow devs to spread out or condense the spacing between vertices for higher and lower poly worlds. However this 1 pixel == 1 vertex principle is maintained. With a vertex scaling of 2.0, a 1024px^2 map represents a 2048m^2 world, using a 1024 region size.

### Global Positions are Absolute

Many functions in the API receive a global position. Before `vertex_spacing`, there was an easy translation to regions, vertex positions, and image coordinates. Now that the user can laterally scale the terrain, landscape features like mountain peaks change their global position, this introduced a design challenge.

To make this managable, we've adopted the principle that all functions in the API that take a `global_position` parameter expect an absolute global position from the users perspective. That position is generally descaled for operations internally in local or image coordinates. If a function calls other functions, it will need to send the global position. Care will need to be taken by devs to ensure the descaled and global positions are used at the right time.
