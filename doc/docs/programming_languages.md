# Programming Languages

Terrain3D is a GDExtension, so any language Godot supports can access it. This includes GDScript, C#, Rust, Python and other languages that can call Godot’s ClassDB.


```{image} images/integrating_gdextension.jpg
:target: ../_images/integrating_gdextension.jpg
```

There are two ways to access Terrain3D:

* **Bindings** — Typed wrappers. Recommended. Currently only available for GDScript and C#.
* **Reflection** — Using `ClassDB` and string names. More verbose, but works for all languages. C# and C++ GDExtension examples are provided and can be adapted for Rust, Python, etc.

The code snippets below may not complete and assume you're already familiar with programming in Godot.

Also see Godot’s [Cross-language scripting](https://docs.godotengine.org/en/stable/tutorials/scripting/cross_language_scripting.html) documentation.

## Detecting If Terrain3D Is Available

### Verifying the Editor Plugin exists

Only works in the editor (tool scripts / editor plugins).

::::{tab-set}

:::{tab-item} GDScript
```gdscript
print("Terrain3D enabled: ", EditorInterface.is_plugin_enabled("terrain_3d"))
```
:::

:::{tab-item} C# (Bindings)
```csharp
using TokisanGames;

GD.Print("Terrain3D enabled: ", EditorInterface.Singleton.IsPluginEnabled(nameof(Terrain3D)));
```
:::

:::{tab-item} C# (Reflection)
```csharp
GD.Print("Terrain3D enabled: ", EditorInterface.Singleton.IsPluginEnabled("Terrain3D"));
```
:::

:::{tab-item} C++ (GDExtension)
```cpp
#include <godot_cpp/classes/editor_interface.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

UtilityFunctions::print("Terrain3D enabled: ", EditorInterface::get_singleton()->is_plugin_enabled("terrain_3d"));
```
:::

::::

### Verifying with ClassDB

Works in editor and in game.

::::{tab-set}

:::{tab-item} GDScript
```gdscript
ClassDB.class_exists("Terrain3D")
ClassDB.can_instantiate("Terrain3D")
```
:::

:::{tab-item} C# (Bindings)
```csharp
using TokisanGames;

ClassDB.ClassExists(nameof(Terrain3D));
ClassDB.CanInstantiate(nameof(Terrain3D));
```
:::

:::{tab-item} C# (Reflection)
```csharp
ClassDB.ClassExists("Terrain3D");
ClassDB.CanInstantiate("Terrain3D");
```
:::

:::{tab-item} C++ (GDExtension)
```cpp
#include <godot_cpp/classes/class_db.hpp>

using namespace godot;

ClassDB::class_exists("Terrain3D");
ClassDB::can_instantiate("Terrain3D");
```
:::

::::

## Instantiating Terrain3D

Terrain3D is created and used like any other Godot object.

::::{tab-set}

:::{tab-item} GDScript
```gdscript
var terrain: Terrain3D = Terrain3D.new()
print(terrain.get_version())
```
:::

:::{tab-item} C# (Bindings)
```csharp
using TokisanGames;

Terrain3D terrain = Terrain3D.Instantiate();
GD.Print("Terrain3D version: ", terrain.Version);
```
:::

:::{tab-item} C# (Reflection)
```csharp
var terrain = ClassDB.Instantiate("Terrain3D").AsGodotObject();
GD.Print("Terrain3D version: ", terrain.Call("get_version"));
```
:::

:::{tab-item} C++ (GDExtension)
```cpp
#include <godot_cpp/classes/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

Object *terrain = ClassDB::instantiate("Terrain3D");
if (terrain) {
    UtilityFunctions::print("Terrain3D version: ", terrain->call("get_version"));
}
```
:::

::::

## Getting A Terrain3D Node From The Scene Tree

Terrain3D nodes are retrieved like any other node. This example expects that the Terrain3D node is a child of the node this script is running on. Adjust the node path for your tree.

::::{tab-set}

:::{tab-item} GDScript
```gdscript
var terrain: Terrain3D = get_node("Terrain3D")
```
:::

:::{tab-item} C# (Bindings)
```csharp
using TokisanGames;

Terrain3D terrain = Terrain3D.Bind(GetNode("Terrain3D"));
```
:::

:::{tab-item} C# (Reflection)
```csharp
var terrain = GetNode("Terrain3D");
```
:::

:::{tab-item} C++ (GDExtension)
```cpp
Node *terrain = get_node<Node>("Terrain3D");
```
:::

::::

### Checking The Type Of A Node

::::{tab-set}

:::{tab-item} GDScript
```gdscript
if node is Terrain3D:
    pass
```
:::

:::{tab-item} C# (Bindings)
```csharp
using TokisanGames;

if (node.IsClass(nameof(Terrain3D)))
{
    // ...
}
```
:::

:::{tab-item} C# (Reflection)
```csharp
if (node.IsClass("Terrain3D"))
{
    // ...
}
```
:::

:::{tab-item} C++ (GDExtension)
```cpp
if (node->is_class("Terrain3D")) {
    // ...
}
```
:::

::::

## Finding an Existing Terrain3D Instance

Useful when the user (or another system) has already placed a Terrain3D node in the scene.

Common use cases:

- Raycasting against the terrain (requires collision enabled). See [Collision](collision.md).
- Exporting a `NodePath` and let the user assign the Terrain3D node.
- Changing the properties of the terrain.

::::{tab-set}

:::{tab-item} GDScript
```gdscript
var terrain: Terrain3D  # or Node if you aren't sure Terrain3D is installed

if Engine.is_editor_hint():
    terrain = get_tree().get_edited_scene_root().find_children("*", "Terrain3D").front()
else:
    terrain = get_tree().get_current_scene().find_children("*", "Terrain3D").front()

if terrain:
    print("Found terrain")
```
:::

:::{tab-item} C# (Bindings)
```csharp
using System.Linq;
using TokisanGames;

Terrain3D terrain = null;
Node terrainNode;

if (Engine.IsEditorHint())
    terrainNode = GetTree().GetEditedSceneRoot().FindChildren("*", nameof(Terrain3D)).FirstOrDefault();
else
    terrainNode = GetTree().GetCurrentScene().FindChildren("*", nameof(Terrain3D)).FirstOrDefault();

if (terrainNode != null)
{
    terrain = Terrain3D.Bind(terrainNode);
    GD.Print("Found terrain: ", terrain);
}
```
:::

:::{tab-item} C# (Reflection)
```csharp
using System.Linq;

Node terrainNode;

if (Engine.IsEditorHint())
    terrainNode = GetTree().GetEditedSceneRoot().FindChildren("*", "Terrain3D").FirstOrDefault();
else
    terrainNode = GetTree().GetCurrentScene().FindChildren("*", "Terrain3D").FirstOrDefault();

if (terrainNode != null)
{
    GD.Print("Found terrain: ", terrainNode);
}
```
:::

:::{tab-item} C++ (GDExtension)
```cpp
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

Node *terrain_node = nullptr;

if (Engine::get_singleton()->is_editor_hint()) {
    TypedArray<Node> nodes = get_tree()->get_edited_scene_root()->find_children("*", "Terrain3D");
    if (nodes.size() > 0) {
        terrain_node = Object::cast_to<Node>(nodes[0]);
    }
} else {
    TypedArray<Node> nodes = get_tree()->get_current_scene()->find_children("*", "Terrain3D");
    if (nodes.size() > 0) {
        terrain_node = Object::cast_to<Node>(nodes[0]);
    }
}

if (terrain_node) {
    UtilityFunctions::print("Found terrain");
}
```
:::

::::

## Working with Subsystems

Once you have a `Terrain3D` instance, the major subsystems are available as properties (or via `get`/`set` in reflection style).

### Reading And Writing Data

Get height at a global position, raise it by 5 m, write it back, and update the maps.

::::{tab-set}

:::{tab-item} GDScript
```gdscript
# Reading height
var position: Vector3 = Vector3(10, 0, 20)
var height: float = terrain.data.get_height(position)

# Writing height
terrain.data.set_height(position, height + 5.0)
var region: Terrain3DRegion = terrain.data.get_regionp(position)
region.set_edited(true)
terrain.data.update_maps(Terrain3DRegion.TYPE_HEIGHT, false)
region.set_edited(false)
```
:::

:::{tab-item} C# (Bindings)
```csharp
using TokisanGames;

// Reading height
Vector3 position = new Vector3(10, 0, 20);
float height = terrain.Data.GetHeight(position);

// Writing height
terrain.Data.SetHeight(position, height + 5.0f);
Terrain3DRegion region = terrain.Data.GetRegionp(position);
region.SetEdited(true);
terrain.Data.UpdateMaps(Terrain3DRegion.MapType.TypeHeight, false);
region.SetEdited(false);
```
:::

:::{tab-item} C# (Reflection)
```csharp
// Reading height
var position = new Vector3(10, 0, 20);
var data = terrain.Get("data").AsGodotObject();
float height = data.Call("get_height", position).AsSingle();

// Writing height
data.Call("set_height", position, height + 5.0f);
var region = data.Call("get_regionp", position).AsGodotObject();
region.Call("set_edited", true);
data.Call("update_maps", 0, false); // Terrain3DRegion.TYPE_HEIGHT
region.Call("set_edited", false);
```
:::

:::{tab-item} C++ (GDExtension)
```cpp
// Reading height
Vector3 position(10, 0, 20);
Object *data = terrain->get("data");
float height = data->call("get_height", position);

// Writing height
data->call("set_height", position, height + 5.0);
Object *region = data->call("get_regionp", position);
region->call("set_edited", true);
data->call("update_maps", 0, false); // Terrain3DRegion::TYPE_HEIGHT
region->call("set_edited", false);
```
:::

::::

### Changing Material Or Shader Parameters

::::{tab-set}

:::{tab-item} GDScript
```gdscript
var material: Terrain3DMaterial = terrain.material
material.world_background = Terrain3DMaterial.NONE
material.auto_shader_enabled = true
material.set_shader_param("auto_slope", 10.0)
```
:::

:::{tab-item} C# (Bindings)
```csharp
using TokisanGames;

Terrain3DMaterial material = terrain.Material;
material.WorldBackground = Terrain3DMaterial.WorldBackgroundEnum.None;
material.AutoShaderEnabled = true;
material.SetShaderParam("auto_slope", 10.0f);
```
:::

:::{tab-item} C# (Reflection)
```csharp
var material = terrain.Get("material").AsGodotObject();
material.Set("world_background", 0); // Terrain3DMaterial.NONE
material.Set("auto_shader_enabled", true);
material.Call("set_shader_param", "auto_slope", 10.0f);
```
:::

:::{tab-item} C++ (GDExtension)
```cpp
Object *material = terrain->get("material");
material->set("world_background", 0); // Terrain3DMaterial::NONE
material->set("auto_shader_enabled", true);
material->call("set_shader_param", "auto_slope", 10.0);
```
:::

::::

## Getting Updates On Terrain Changes

`Terrain3DData` exposes signals that fire when the terrain is modified. Connect to them the same way you connect to any other Godot signal.

::::{tab-set}

:::{tab-item} GDScript
```gdscript
terrain.data.maps_changed.connect(_on_maps_changed)
# or
terrain.data.connect("maps_changed", _on_maps_changed)

func _on_maps_changed():
    print("Terrain maps changed")
```
:::

:::{tab-item} C# (Bindings)
```csharp
using TokisanGames;

terrain.Data.MapsChanged += OnMapsChanged;
// ...
private void OnMapsChanged()
{
    GD.Print("Terrain maps changed");
}
```
:::

:::{tab-item} C# (Reflection)
```csharp
terrain.Get("data").AsGodotObject().Connect("maps_changed", Callable.From(OnMapsChanged));
// ...
private void OnMapsChanged()
{
    GD.Print("Terrain maps changed");
}
```
:::

:::{tab-item} C++ (GDExtension)
```cpp
Object *data = terrain->get("data");
data->connect("maps_changed", callable_mp(this, &MyClass::_on_maps_changed));
// ...
void MyClass::_on_maps_changed() {
    UtilityFunctions::print("Terrain maps changed");
}
```
:::

::::

See the API in [Terrain3DData](../api/class_terrain3ddata.rst#signals) and other classes for all available signals.

## Minimal Complete Example

Complete, self-contained examples that create a terrain, generate a heightmap, create textures, and place foliage are provided:

- GDScript: `project/demo/src/CodeGenerated.gd`
- C# (Bindings): `project/demo/csharp/CodeGenerated.cs`

These two files are written to behave identically so you can compare them.

