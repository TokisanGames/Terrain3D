Generating C# Bindings
==========================

After compiling you might want to generate C# Bindings. At this point in time C# and GDScript don't share their ClassDB. You can call the functions through reflection, but providing C# Bindings, will make coding in C# much easier.

How to generate bindings
------------------------

1. compile Terrain3D as mentioned in [Building from Source](building_from_source.md).
2. clone the CSharp Wrapper git repo: [GitHub: Delsin-Yu/CSharp-Wrapper-Generator-for-GDExtension](https://github.com/Delsin-Yu/CSharp-Wrapper-Generator-for-GDExtension)
3. go into addons and delete the `terrain_3d`-folder (and all other folders except for the cs_wrapper_generator_for_gde and gdUnit4) and copy your new generated folder into it instead
4. follow the guide on how to generate bindings: [GitHub: Delsin-Yu/CSharp-Wrapper-Generator-for-GDExtension - try this out anchor](https://github.com/Delsin-Yu/CSharp-Wrapper-Generator-for-GDExtension?tab=readme-ov-file#try-this-work-in-progress-project-out)
5. at the root of the `CSharp-Wrapper-Generator-for-GDExtension`-project will be a `GDExtensionWrappers` folder rename it to `csharp`
6. do a search and replace across all files and change `namespace GDExtension.Wrappers` with `namespace TokisanGames`
7. copy the `csharp`-folder into the Terrain3D Project folder under `addons/terrain_3d` next to `plugin.cfg` and `bin`