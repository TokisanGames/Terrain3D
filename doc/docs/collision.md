Collision
=======================

One of the most important things about a terrain is knowing where it is. Using physics based collision is not the only way, nor even the best or fastest way. There are at least 5 ways to detect terrain height: Physics based raycasting on collision, raymarching, the GPU depth texture, get_height(), and reading the heightmap directly.

You should use raycasting only when you don't already know the X, Z of the collision point (eg not vertical).


## Physics Based Collision & Raycasting

Collision is generated at runtime using the physics server. Regular PhysicsBodies will interact with this collision as expected. 

To detect ground height with this method, use a [ray cast](https://docs.godotengine.org/en/stable/tutorials/physics/ray-casting.html). Below is an example. The colliding object will be a [Terrain3DCollision](../api/class_terrain3dcollision.rst) object, which contains but is not a StaticBody. Run `get_terrain()` to get the Terrain3D node, or `get_rid()` to retreive the StaticBody RID. See that link for other functions to configure other properties like layers, mask, priority, and physics material.

```gdscript
    var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
    var query := PhysicsRayQueryParameters3D.create(position, position + Vector3(0, -500, 0))
    query.exclude = [ self ]
    var result: Dictionary = space_state.intersect_ray(query)
    if result and result["collider"] is Terrain3DCollision:
        print("Found Terrain3DCollision")
        var terrain: Terrain3D = result["collider"].get_terrain()
        if terrain:
            print("Found Terrain3D")
```

Raycasts won't hit the terrain where no collision shapes are generated. This occurs outside of regions and may also depend on your collision mode setting. Read about `Terrain3D/Collision/Collision Mode`, or `Terrain3D.collision.mode` in the API above. 

Normally, collision mode is set `Dynamic / Game`, which only generates around the player while in game. Some addons or other activities need collision in the editor, so you can set the mode to `Full / Editor` or `Dynamic / Editor`. Full mode will generate collision for all regions when enabled or at startup. It's a bit slow due to the amount of data. You can run in game with these other modes enabled, but the default is recommended for the best performance.

Finally, Godot Physics is far from perfect. If you have issues with raycasts or other physics calculations, try switching to Jolt. Also if your raycast is perfectly vertical, you can try angling it ever so slightly, or use an option below.


## Raycasting Without Physics

It is possible to cast a ray from any position and direction to detect the collision point on the terrain without using the physics engine. We have two methods for that: raymarching and "looking" at it with the GPU.

Sending the source point and ray direction to [Terrain3D.get_intersection()](../api/class_terrain3d.rst#class-terrain3d-method-get-intersection) will return the intersection point. This function has two modes:

In raymarching mode it iterates over get_height() until an intersection is reached. This only works within regions, and is a bit heavy compared to the other mode.

In GPU mode, it "looks" at the terrain using a camera and the GPU depth texture. This works outside of regions, even on the WorldNoise. However there are caveats. It returns values for the previous frame, so can only used continuously or used with `await`, and no more than once per frame.

Be sure to read the link above to understand all caveats. Review [editor_plugin.gd:_forward_3d_gui_input](https://github.com/TokisanGames/Terrain3D/blob/main/project/addons/terrain_3d/src/editor_plugin.gd) to see an example of using this function to project the mouse position onto the terrain.


## Query Height At Any Position

If you already know the X, Z position, use `get_height()`:

```gdscript
     var height: float = terrain.data.get_height(global_position)
```

`NAN` is returned if the position is a hole, or outside of regions.

This is ideal for one lookup. Use the next option for greater efficiency.


### Retreiving The Normal

After getting the height, you may also wish to get the normal with `Terrain3DData.get_normal(global_position)`. The normal is a Vector3 that points perpendulcar to the terrain face.


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


### Visualizing Collision

To see the collision shape, first set `Terrain3D/Collision/Collision Mode` to `Full / Editor` or `Dynamic / Editor`.

To see it in the editor, in the Godot `Perspective` menu, enable `View Gizmos`. Avoid using the Full option on slow systems.

To see debug collision in game, in the Godot `Debug` menu, enable `Visible Collision Shapes` and run the scene.


### Enemy Collision

The easy approach is to give every enemy a capsule collision shape, and start creating your level. As you fill your level with terrain, rocks, caves, canyons, and dungeons, you'll quickly learn that this approach is terrible for performance.

Your system will be brought to its knees when you have 5-10 enemies follow the player into a tight area with many faceted collision shapes. The physics server will need to calculate collisions against hundreds of faces in the area for each of the 10 character bodies.

A better alternative is to use physics collision only for the player, and use raycasts for the enemies. This allows you to limit the collision checks to a few per enemy, regardless of how many collision faces there are.

However both methods above require collision shapes where the enemy is. What if you want to have enemies stay on the ground when far from the camera, while using a dynamic collision mode?

For one, you could disable all enemy processing when away from the camera. Do you really need them moving, playing animations, and applying gravity if they aren't even on screen?

If so, you can have each enemy query `Terrain3DData.get_height()`, either in conjunction with checking height with a raycast or physics, or in place of. It could come right after applying gravity so it will snap back to the surface if it dips below.

e.g.
```
    global_position.y -= gravity * p_delta
    global_position.y = maxf(global_position.y, terrain.data.get_height(global_position))
```

