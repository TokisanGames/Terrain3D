<img src="https://outobugi.com/images/terrain3d.png">

# Terrain3D
A high performance, editable terrain system for Godot 4, written in C++.

## Features
* Written in C++ as a GDExtension plugin, which works with official engine builds
* Can be accessed by GDScript, C#, and any language Godot supports
* Geometric Clipmap Mesh Terrain, as used in The Witcher 3. See [System Design](https://github.com/TokisanGames/Terrain3D/wiki/System-Design) 
* Up to 16k x 16k in 1k regions (imagine multiple islands without paying for 16k^2 vram)
* Up to 10 Levels of Detail (LODs)
* Up to 32 texture sets using albedo, normal, roughness, height
* Sculpting, texture painting, texture detiling, painting colors and wetness, undo/redo
* Supports importing heightmaps from [HTerrain](https://github.com/Zylann/godot_heightmap_plugin/), WorldMachine, Unity, Unreal and any tool that can export a heightmap (raw/r16/exr/+). See [importing](https://github.com/TokisanGames/Terrain3D/wiki/Importing-&-Exporting-Data)  

See the [Wiki](https://github.com/TokisanGames/Terrain3D/wiki) for project status, design, and usage.

## Requirements
* Supports Godot 4.1+. [4.0 is possible](https://github.com/TokisanGames/Terrain3D/wiki/Using-Previous-Engine-Versions).
* Supports Windows, Linux, and macOS. Other platforms pending.

## Installation & Setup

### Run the demo
1. Download the [latest release](https://github.com/TokisanGames/Terrain3D/releases) and extract the files, or [build the plugin from source](https://github.com/TokisanGames/Terrain3D/wiki/Building-From-Source).
2. Run Godot, using the console executable so you can see error messages.
3. In the project manager, import the demo project and open it. Allow Godot to restart.
4. In `Project Settings / Plugins`, ensure that Terrain3D is enabled.
5. Select `Project / Reload Current Project` to restart once more.
6. If the demo scene doesn't open automatically, open `demo/Demo.tscn`. You should see a terrain. Run the scene. 

### Install Terrain3D in your own project
1. Download the [latest release](https://github.com/TokisanGames/Terrain3D/releases) and extract the files, or [build the plugin from source](https://github.com/TokisanGames/Terrain3D/wiki/Building-From-Source).
2. Copy `addons/terrain_3d` to your project folder as `addons/terrain_3d`.
3. Run Godot, using the console executable so you can see error messages. Restart when it prompts.
6. In `Project Settings / Plugins`, ensure that Terrain3D is enabled.
7. Select `Project / Reload Current Project` to restart once more.
8. Create or open a 3D scene and add a new Terrain3D node.
9. Select Terrain3D in the scene tree. In the inspector, click the down arrow to the right of the `storage` resource and save it as a binary `.res` file. This is optional, but highly recommended. Otherwise it will save terrain data as text in the current scene file. The other resources can be left as is or saved as text `.tres`. These external files can be shared with other scenes.
10. Read the [Wiki](https://github.com/TokisanGames/Terrain3D/wiki) to learn how to properly [set up your textures](https://github.com/TokisanGames/Terrain3D/wiki/Setting-Up-Textures), [import data](https://github.com/TokisanGames/Terrain3D/wiki/Importing-&-Exporting-Data) and more. 

## Getting Support

1. Most questions have already been addressed in the [Wiki](https://github.com/TokisanGames/Terrain3D/wiki), especially [Troubleshooting](https://github.com/TokisanGames/Terrain3D/wiki/Troubleshooting) and [Setting Up Textures](https://github.com/TokisanGames/Terrain3D/wiki/Setting-Up-Textures). 

2. For questions or technical issues, join the [Tokisan discord server](https://tokisan.com/discord) and look for the #terrain-help channel.

3. For technical issues or bug reports, search through the [issues](https://github.com/TokisanGames/Terrain3D/issues) to ensure it hasn't already been reported, then create a new one. Use discord for questions.

## Credit
Developed for the Godot community by:

|||
|--|--|
| **Cory Petkovsek, Tokisan Games** | [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/twitter.png?raw=true" width="24"/>](https://twitter.com/TokisanGames) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/github.png?raw=true" width="24"/>](https://github.com/TokisanGames) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/www.png?raw=true" width="24"/>](https://tokisan.com/) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/discord.png?raw=true" width="24"/>](https://tokisan.com/discord) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/youtube.png?raw=true" width="24"/>](https://www.youtube.com/@TokisanGames)|
| **Roope Palmroos, Outobugi Games** | [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/twitter.png?raw=true" width="24"/>](https://twitter.com/outobugi) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/github.png?raw=true" width="24"/>](https://github.com/outobugi) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/www.png?raw=true" width="24"/>](https://outobugi.com/) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/youtube.png?raw=true" width="24"/>](https://www.youtube.com/@outobugi)|

And other contributors displayed on the right of the github page and in [AUTHORS.md](https://github.com/TokisanGames/Terrain3D/blob/main/AUTHORS.md).

Geometry clipmap mesh code created by [Mike J. Savage](https://mikejsavage.co.uk/blog/geometry-clipmaps.html). Blog and repository code released under the MIT license per email communication with Mike.

## Contributing

We need your help to make Terrain3D the best terrain plugin for Godot 4. Please see [CONTRIBUTING.md](https://github.com/TokisanGames/Terrain3D/blob/main/CONTRIBUTING.md) if you would like to help.


## License

This plugin has been released under the [MIT License](https://github.com/TokisanGames/Terrain3D/blob/main/LICENSE.txt).

