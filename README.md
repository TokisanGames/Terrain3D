<img src="https://outobugi.com/images/terrain3d.png">

# Terrain3D
An editable terrain system for Godot 4, written in C++.

## Features
* Written in C++ as a Godot gdextension plugin, which works with official engine builds
* Geometric Clipmap mesh terrain (as used in The Witcher 3)
* Up to 16k x 16k, sliced up in non-contiguous 1k regions (think multiple islands without paying for 16k^2 vram)
* Up to 10 levels of detail (LODs)
* Up to 32 textures
* Sculpting, texture painting, texture detiling, paint colors or wetness
* Supports importing heightmaps from [HTerrain](https://github.com/Zylann/godot_heightmap_plugin/), WorldMachine, Unity, Unreal and any tool that can export a heightmap (raw/r16/exr/+)

See the [Wiki](https://github.com/TokisanGames/Terrain3D/wiki) for more details on project status, features, design, and usage.

## Requirements
* Supports Godot 4.1+. [Older 4.x versions are possible](https://github.com/TokisanGames/Terrain3D/wiki/Supporting-Older-Engine-Versions).
* Supports Windows, Linux, and macOS. Android pending.

## Installation & Setup

### Run the demo
1. Download the [latest release](https://github.com/TokisanGames/Terrain3D/releases) and extract the files, or [build the plugin from source](https://github.com/TokisanGames/Terrain3D/wiki/Building-From-Source).
2. Run Godot, using the console executable so you can see error messages.
3. Import the demo project and open it. Allow Godot to restart.
4. In `Project Settings / Plugins`, ensure that Terrain3D is enabled.
5. Select `Project / Reload Current Project` to restart once more.
6. If the demo scene doesn't open automatically, open `demo/Demo.tscn`. You should see a terrain. Run it. 

### Install Terrain3D in your own project
1. Copy `addons/terrain_3d` to your project folder in `addons/terrain_3d`.
2. Open Godot, restart when it prompts.
3. In `Project Settings / Plugins`, ensure that Terrain3D is enabled.
4. Select `Project / Reload Current Project` to restart once more.
5. Create or open a 3D scene and add a new Terrain3D node.
6. Select Terrain3D in the scene tree. In the inspector, click the down arrow to the right of the storage resource and save it as a binary .res file. This is optional, but highly recommended. Otherwise it will save terrain data as text in the current scene file.
7. Read the wiki to learn how to properly [set up your textures](https://github.com/TokisanGames/Terrain3D/wiki/Setting-Up-Textures), [import data](https://github.com/TokisanGames/Terrain3D/wiki/Importing-&-Exporting-Data) and [more](https://github.com/TokisanGames/Terrain3D/wiki). 

## Getting Support

1. Read through the [Wiki](https://github.com/TokisanGames/Terrain3D/wiki), especially [Troubleshooting](https://github.com/TokisanGames/Terrain3D/wiki/Troubleshooting).
2. Search through the [issues](https://github.com/TokisanGames/Terrain3D/issues) for known issues, or create a new one if you're sure it's not a duplicate.
3. Join the [Tokisan discord server](https://tokisan.com/discord) and look for the Terrain3D section.

## Credit
Developed for the Godot community by:

||||
|--|--|--|
|Architect | **Roope Palmroos, Outobugi Games** | [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/twitter.png?raw=true" width="24"/>](https://twitter.com/outobugi) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/github.png?raw=true" width="24"/>](https://github.com/outobugi) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/www.png?raw=true" width="24"/>](https://outobugi.com/) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/youtube.png?raw=true" width="24"/>](https://www.youtube.com/@outobugi)|
|Project Manager | **Cory Petkovsek, Tokisan Games** | [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/twitter.png?raw=true" width="24"/>](https://twitter.com/TokisanGames) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/github.png?raw=true" width="24"/>](https://github.com/TokisanGames) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/www.png?raw=true" width="24"/>](https://tokisan.com/) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/discord.png?raw=true" width="24"/>](https://tokisan.com/discord) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/youtube.png?raw=true" width="24"/>](https://www.youtube.com/@TokisanGames)|

And other contributors displayed on the right of the github page and in [CONTRIBUTORS.md](https://github.com/TokisanGames/Terrain3D/blob/main/CONTRIBUTORS.md).

Geometry clipmap mesh code created by [Mike J Savage](https://mikejsavage.co.uk/blog/geometry-clipmaps.html). Blog and repository code released under the MIT license per email communication with Mike.


## License

This plugin is released under the MIT license. See [LICENSE](https://github.com/TokisanGames/Terrain3D/blob/main/LICENSE).

