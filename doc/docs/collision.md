Collision
=======================

One of the most important things about a terrain is knowing where it is. Using physics based collision is not the only way, nor even the best or fastest way. There are at least 5 ways to detect terrain height: Physics based raycasting on collision, raymarching, the GPU depth texture, get_height(), and reading the heightmap directly.

You should use raycasting only when you don't already know the X, Z of the collision point (eg not vertical).


## Physics Based Collision & Raycasting

To enable physics based collision, we must generate a StaticBody and CollisionShapes that match the shape of the terrain. This means collision is only generated where you have defined regions. Out in the WorldNoise background, there is no terrain data, so no collision.

Collision generation can be slow and consume a lot of memory, so we offer five options:
* `Dynamic / Game` is the default, which only generates around the camera while in game. It is node-less and the fastest option.
* `Dynamic / Editor` generates around the camera in editor or in game. It attaches nodes to the tree, so is slightly slower, but this allows the shapes to be [visualized](#visualizing-collision).
* `Full / Game` generates collision for the entire terrain at game start, using node-less shapes. It consumes a lot of memory on large terrains.
* `Full / Editor` does the above with viewable shapes in the editor.
* `Disabled` is self explanatory.

Some addons or other activities need collision in the editor, which can be enabled with an `Editor` mode above. You can run the game with any option, but the default is recommended for the best performance. See [set_mode](../api/class_terrain3dcollision.rst#class-terrain3dcollision-property-mode) and [CollisionMode](../api/class_terrain3dcollision.rst#enum-terrain3dcollision-collisionmode).

Once the desired collision mode is set, to detect ground height with physics, you can use a [ray cast](https://docs.godotengine.org/en/stable/tutorials/physics/ray-casting.html). The colliding object will either be the [Terrain3D](../api/class_terrain3d.rst) node if in a `Game` mode. Or it will be a StaticBody if using an `Editor` mode. In the latter case, the StaticBody is a child of Terrain3D. Below is an example that will handle either scenario.

```gdscript
	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(position, position + Vector3(0, -500, 0))
	query.exclude = [ self ]
	var result: Dictionary = space_state.intersect_ray(query)
	if result:
		var node: Node = result["collider"]
		# Change node to StaticBody parent in `Editor` collision modes
		if node is StaticBody3D and node.get_parent() is Terrain3D:
			node = node.get_parent()
		# Detect Terrain3D with `is`, since printing the node returns `[Wrapped:0]`
		if node is Terrain3D:
			print("Hit: Terrain3D") 
		else:
			print("Hit: ", node)
```

Godot Physics is far from perfect. If you have issues with raycasts or other physics calculations, try switching to Jolt. If you have trouble with a perfectly vertical raycast, try angling it ever so slightly. Finally, consider using an alternate method below.


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

