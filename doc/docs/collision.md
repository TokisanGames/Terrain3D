Collision
=======================

One of the most important things about a terrain is knowing where it is. Using physics based collision is not the only way, nor even the best or fastest way. There are at least 5 ways to detect terrain height: Physics based raycasting on collision, raymarching, the GPU depth texture, get_height(), and reading the heightmap directly.

You should use raycasting only when you don't already know the X, Z of the collision point (eg not vertical).


## Physics Based Collision & Raycasting

Collision is generated at runtime using the physics server. Regular PhysicsBodies will interact with this collision as expected. To detect ground height, use a [ray cast](https://docs.godotengine.org/en/stable/tutorials/physics/ray-casting.html). There is no collision outside of regions, so raycasts won't hit.

Normally the editor doesn't generate collision, but some addons or other activities do need editor collision. To generate it, set `Terrain3D/Collision/Collision Mode`, or `Terrain3D.collision_mode`, to `Full / Editor`. You can run in game with this enabled.

This option will generate collision one time when enabled or at startup. If the terrain is sculpted afterwards, this collision will be inaccurate to the visual mesh until collision is disabled and enabled again. On a Core-i9 12900H, generating collision takes about 145ms per 1024m region, so updating it several times per second while sculpting is not practical. Currently all regions are regenerated, rather than only modified regions so it is not optimal. You can follow [PR#278](https://github.com/TokisanGames/Terrain3D/pull/278) for an improved system.

See the [Terrain3D API](../api/class_terrain3d.rst) for various functions that configure the collision priority, layers, and mask.

Finally, Godot Physics is far from perfect. If you have issues with raycasts or other physics calculations, try switching to Jolt. Also if your raycast is perfectly vertical, you can try angling it ever so slightly, or use get_height().


## Raycasting Without Physics

It is possible to cast a ray from any position and direction to detect the collision point on the terrain without using the physics engine. We have two methods for that: raymarching and using the GPU.

Sending the source point and ray direction to [Terrain3D.get_intersection()](../api/class_terrain3d.rst#class-terrain3d-method-get-intersection) will return the intersection point. This function has two modes:

In raymarching mode it iterates over get_height() until an intersection is reached. This only works within regions, and is a bit heavy compared to the other modes.

In GPU mode, it "looks" at the terrain using the GPU depth texture. This works outside of regions, even on the WorldNoise. However there are caveats. It returns values for the previous frame, so can only used continuously or used with `await`, and no more than once per frame.

Be sure to read the link above to understand all caveats. Review [editor_plugin.gd](https://github.com/TokisanGames/Terrain3D/blob/main/project/addons/terrain_3d/src/editor_plugin.gd#L184-L188) to see an example of using this function to project the mouse position onto the terrain.


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

