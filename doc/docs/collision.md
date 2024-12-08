Collision
=======================

One of the most important things about a terrain is knowing where it is. Terrain3D provides several methods for detecting terrain height.

Using collision is not the only way, nor even the best or fastest way. But we'll start with it as it is the most common.

## Physics Based Collision & Raycasting

Collision is generated at runtime using the physics server. Regular PhysicsBodies will interact with this collision as expected. To detect ground height, use a [ray cast](https://docs.godotengine.org/en/stable/tutorials/physics/ray-casting.html). However, outside of regions, there is no collision, so raycasts won't hit. 

Normally the editor doesn't generate collision, but some addons or other activities do need editor collision. To generate it, enable `Terrain3D/Collision/Collision Mode`, or set `Terrain3D.collision_mode`. Set this to `Full / Editor`. You can run in game with this enabled.

This editor option will generate collision one time when enabled or at startup. If the terrain is sculpted afterwards, this collision will be inaccurate to the visual mesh until collision is disabled and enabled again. On a Core-i9 12900H, generating collision takes about 145ms per 1024m region, so updating it several times per second while sculpting is not practical. Currently all regions are regenerated, rather than only modified regions so it is not optimal. You can follow [PR#278](https://github.com/TokisanGames/Terrain3D/pull/278) for an improved system.

See the [Terrain3D API](../api/class_terrain3d.rst) for various functions that configure the collision priority, layers, and mask.

## Raycasting Without Physics

It is possible to cast a ray from any position and any direction and detect the collision point on the terrain using the GPU instead of the physics engine.

Sending the source point and ray direction to [Terrain3D.get_intersection()](../api/class_terrain3d.rst#class-terrain3d-method-get-intersection) will return the intersection point on success.

Being GPU based, this function works outside of regions.

This function works fine if called *only once per frame*, such as for a mouse pointer detecting terrain position. More than once per frame will produce conflicts.

You can review [editor.gd](https://github.com/TokisanGames/Terrain3D/blob/v0.9.1-beta/project/addons/terrain_3d/editor/editor.gd#L129-L143) to see an example of projecting the mouse position onto the terrain using this function.

Use it only when you don't already know the X, Z collision point.


## Query Height At Any Position

If you already know the X, Z position, use `get_height()`:

```gdscript
     var height: float = terrain.data.get_height(global_position)
```

`NAN` is returned if the position is a hole, or outside of regions.

This is ideal for one lookup. Use the next option for greater efficiency.


## Query Many Heights

If you wish to look up thousands of heights, it will be faster to retrieve the heightmap Image for the region and query the data directly. 

However, note that `get_height()` above will [interpolate between vertices](https://github.com/TokisanGames/Terrain3D/blob/5bab86ff311159356dd4d837ea2c340f59d139b6/src/terrain_3d_storage.cpp#L493-L502), while this code will not.

```gdscript
     var region: Terrain3DRegion = terrain.data.get_regionp(global_position)
     if region and not region.is_deleted():
         var img: Image = region.get_height_map()
         for y in img.get_height():
              for x in img.get_width():
                   var height: float = img.get_pixel(x, y).r
```

----

## Additional Tips


### Getting The Normal

After getting the height, you may also wish to get the normal with `Terrain3DData.get_normal(global_position)`. The normal is a Vector3 that points perpendulcar to the terrain face.


### Visualizing Collision

To see the collision shape, first set `Terrain3D/Collision/Collision Mode` to `Full / Editor`.

To see it in the editor, in the Godot `Perspective` menu, enable `View Gizmos`. Disable this option on slow systems.

To see debug collision in game, in the Godot `Debug` menu, enable `Visible Collision Shapes` and run the scene.

