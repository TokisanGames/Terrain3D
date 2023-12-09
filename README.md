<img src="doc/docs/images/terrain3d.png">

# Terrain3D
A high performance, editable terrain system for Godot 4.

## Features
* Written in C++ as a GDExtension plugin, which works with official engine builds
* Can be accessed by GDScript, C#, and any language Godot supports
* Geometric Clipmap Mesh Terrain, as used in The Witcher 3. See [System Architecture](https://terrain3d.readthedocs.io/en/latest/docs/system_architecture.html) 
* Up to 16k x 16k in 1k regions (imagine multiple islands without paying for 16k^2 vram)
* Up to 10 Levels of Detail (LODs)
* Up to 32 texture sets using albedo, normal, roughness, height
* Sculpting, holes, texture painting, texture detiling, painting colors and wetness
* Supports importing heightmaps from [HTerrain](https://github.com/Zylann/godot_heightmap_plugin/), WorldMachine, Unity, Unreal and any tool that can export a heightmap (raw/r16/exr/+). See [importing data](https://terrain3d.readthedocs.io/en/latest/docs/import_export.html)

See [Project Status](https://terrain3d.readthedocs.io/en/latest/docs/project_status.html) for details.

## Getting Started

Read through our [documentation](https://terrain3d.readthedocs.io/en/latest/index.html), starting with [Installation](https://terrain3d.readthedocs.io/en/latest/docs/installation.html).

For support, read [Getting Help](https://terrain3d.readthedocs.io/en/latest/docs/getting_help.html) or join our [Discord server](https://tokisan.com/discord).

## Credit
Developed for the Godot community by:

|||
|--|--|
| **Cory Petkovsek, Tokisan Games** | [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/twitter.png?raw=true" width="24"/>](https://twitter.com/TokisanGames) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/github.png?raw=true" width="24"/>](https://github.com/TokisanGames) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/www.png?raw=true" width="24"/>](https://tokisan.com/) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/discord.png?raw=true" width="24"/>](https://tokisan.com/discord) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/youtube.png?raw=true" width="24"/>](https://www.youtube.com/@TokisanGames)|
| **Roope Palmroos, Outobugi Games** | [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/twitter.png?raw=true" width="24"/>](https://twitter.com/outobugi) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/github.png?raw=true" width="24"/>](https://github.com/outobugi) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/www.png?raw=true" width="24"/>](https://outobugi.com/) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/youtube.png?raw=true" width="24"/>](https://www.youtube.com/@outobugi)|

And other contributors displayed on the right of the github page and in [AUTHORS.md](https://github.com/TokisanGames/Terrain3D/blob/main/AUTHORS.md).

Geometry clipmap mesh code created by [Mike J. Savage](https://mikejsavage.co.uk/blog/geometry-clipmaps.html). Blog and repository code released under the MIT license per email communication with Mike.

## Contributing

Please see [CONTRIBUTING.md](https://github.com/TokisanGames/Terrain3D/blob/main/CONTRIBUTING.md) if you would like to help make Terrain3D the best terrain system for Godot.


## License

This plugin has been released under the [MIT License](https://github.com/TokisanGames/Terrain3D/blob/main/LICENSE.txt).

