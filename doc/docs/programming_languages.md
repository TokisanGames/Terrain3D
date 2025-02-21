Programming Languages
===========================

Any language Godot supports should be able to work with Terrain3D via the GDExtension interface. This includes [C#](https://docs.godotengine.org/en/stable/tutorials/scripting/c_sharp/index.html), and [several others](https://docs.godotengine.org/en/stable/tutorials/scripting/gdextension/what_is_gdextension.html#supported-languages).

Here are some tips for integrating with Terrain3D.

```{image} images/integrating_gdextension.jpg
:target: ../_images/integrating_gdextension.jpg
```

## Detecting If Terrain3D Is Installed

To determine if Terrain3D is installed and active, [ask Godot](https://docs.godotengine.org/en/stable/classes/class_editorinterface.html#class-editorinterface-method-is-plugin-enabled).

**GDScript**
```gdscript
     print("Terrain3D installed: ", EditorInterface.is_plugin_enabled("terrain_3d"))
```

**C#**
```c#
     GetEditorInterface().IsPluginEnabled("terrain_3d") 
```

You can also ask ClassDB if the class exists:

**GDScript**
```gdscript
     ClassDB.class_exists("Terrain3D")
     ClassDB.can_instantiate("Terrain3D")
```
**C#**
```c#
     ClassDB.ClassExists("Terrain3D");
     ClassDB.CanInstantiate("Terrain3D");
```

## Instantiating & Calling Terrain3D

Terrain3D is instantiated and referenced like any other object.

**GDScript**

```gdscript
     var terrain: Terrain3D = Terrain3D.new()
     terrain.assets = Terrain3DAssets.new()
     print(terrain.get_version())
```

See the `CodeGenerated.tscn` demo for an example of initiating Terrain3D from script.

**C#**

You can instantiate through ClassDB, set variables and call it.

```c#
     var terrain = ClassDB.Instantiate("Terrain3D");
     terrain.AsGodotObject().Set("assets", ClassDB.Instantiate("Terrain3DAssets"));
     terrain.AsGodotObject().Call("set_show_region_grid", true);
```

You can also check if a node is a Terrain3D object:

**GDScript**

```gdscript
    if node is Terrain3D:
```

**C#**

```c#
private bool CheckTerrain3D(Node myNode) {
        if (myNode.IsClass("Terrain3D")) {
            var collisionMode = myNode.Call("get_collision_mode").AsInt32();
```

For more information on C# and other languages, read [Cross-language scripting](https://docs.godotengine.org/en/stable/tutorials/scripting/cross_language_scripting.html) in the Godot docs.

## Finding the Terrain3D Instance

These options are for programming scenarios where a user action is intented to provide your code with the Terrain3D instance.

* If collision is enabled in game (default) or in the editor (debug only), you can run a raycast and if it hits, it will return a `Terrain3D` object. See more in the [raycasting](collision.md#physics-based-collision-raycasting) section.

* Your script can provide a NodePath and allow the user to select their Terrain3D node as was done in [the script](https://github.com/TokisanGames/Terrain3D/blob/v0.9.1-beta/project/addons/terrain_3d/extras/project_on_terrain3d.gd#L14) provided for use with Scatter.

* You can search the current scene tree for [nodes of type](https://docs.godotengine.org/en/stable/classes/class_node.html#class-node-method-find-children) "Terrain3D".
```gdscript
     var terrain: Terrain3D # or Node if you aren't sure if it's installed
     if Engine.is_editor_hint(): 
          # In editor
          terrain = get_tree().get_edited_scene_root().find_children("*", "Terrain3D")
     else:
          # In game
          terrain = get_tree().get_current_scene().find_children("*", "Terrain3D")

     if terrain:
          print("Found terrain")
```



## Detecting Terrain Height

See [Collision](collision.md) for several methods.


## Getting Updates on Terrain Changes

`Terrain3DData` has [signals](../api/class_terrain3ddata.rst#signals) that fire when updates occur. You can connect to them to receive updates.


