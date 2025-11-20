Generating C# Bindings
==========================

C# Bindings need to be rebuilt after building Terrain3D. At this point in time, C# and GDScript don't share their ClassDB. You can call the functions through reflection, but providing C# Bindings makes coding in C# much easier. As of Terrain3D 1.1, these bindings are generated and included in release builds by a maintainer.

How To Generate Bindings
------------------------

1. Compile Terrain3D as shown in [Building from Source](building_from_source.md).
1. Clone the [CSharp-Wrapper-Generator-for-GDExtension](https://github.com/Delsin-Yu/CSharp-Wrapper-Generator-for-GDExtension) repo.
1. Load the CSharp Wrapper Generator project in the .NET version of Godot.
1. Build the C# project.
1. Ensure the plugin is enabled in project settings and restart.
1. You should see a Wrapper Generator panel in a side panel. Set up the namespace `TokisanGames`, save path `addons/terrain_3d/csharp`, and indentation `tabs`.
1. Add your built `addons/terrain_3d/` folder to this project. I made a link on my filesystem between my Terrain3D repo and this one so I could read from new builds, and generate C# without moving files.
1. Generate, and look for errors or warnings to address.
1. Move the generated C# files to `project/addons/terrain_3d/csharp` in your project.
1. In your project, build the C# project.
