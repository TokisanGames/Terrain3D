# Editable Terrain System for Godot 4

## Features
* Geometric Clipmap mesh terrain (as used in The Witcher 3)
* Up to 16k x 16k sliced up in non-contiguous 1k regions (think multiple islands without paying for 16k^2 memory)
* Up to 10 levels of detail (LODs)
* Written in C++ as a Godot plugin, which works with official engine builds
* Sculpting, texture painting, texture detiling, color map painting, import/export, undo/redo
* Supports importing from [Zylann's HTerrain](https://github.com/Zylann/godot_heightmap_plugin/) and any tool that can provide a heightmap image

See the [Wiki](https://github.com/outobugi/GDExtensionTerrain/wiki) for details on features, design, and usage.

## Requirements
* Supports Godot 4.0+
* Should work on Windows, Linux, and OSX if you build it yourself. It is being developed on Windows.

## Installation & Setup

1. Download the [latest release](https://github.com/outobugi/GDExtensionTerrain/releases) (when available), or [build the plugin from source](https://github.com/outobugi/GDExtensionTerrain/wiki/Building-From-Source).
2. Close Godot, then Copy `addons/terrain` to your project folder in `addons/terrain`.
3. Open Godot, let it complain about importing errors. Then restart Godot.
4. In Project Settings / Plugins, ensure that GDExtensionTerrain is enabled.
5. Create or open a scene. Add a new Terrain3D node.
6. Select Terrain3D and in the inspector, create a new Terrain3DStorage resource.
7. Click the down arrow to the right of the storage resource and save it as a binary .res file. This is optional, but recommended. Otherwise it will save terrain data as text in the current scene file.


## Contributing
We use the standard [Godot PR workflow](https://docs.godotengine.org/en/stable/contributing/workflow/pr_workflow.html) and other standards used by Godot. Refer to their documentation.

This means we also format our code using `clang-format`:

#### Installing clang-format
* Install the commit hooks in your repo after cloning so git will automatically run `clang-format` on your code when you commit
	* Copy `tools/hooks/*` into `.git/hooks` or run `python tools/install-hooks.py`
* Install the clang-format binary onto your system.
	* Download version 13 or later
	* Make sure the LLVM binary directory where `clang-format` is stored gets added to the `PATH` during installation
	* Linux/OSX: Install the `clang-format` package, or all of `LLVM` or `clang` if your distribution doesn't provide the standalone tool
	* Windows: Download LLVM for Windows from <https://releases.llvm.org/download.html>


## Credit
Developed for the Godot community by:

|||
|--|--|
|**Roope Palmroos, Outobugi Games** | [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/twitter.png?raw=true" width="24"/>](https://twitter.com/outobugi) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/github.png?raw=true" width="24"/>](https://github.com/outobugi) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/www.png?raw=true" width="24"/>](https://outobugi.com/) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/youtube.png?raw=true" width="24"/>](https://www.youtube.com/@vibelius)|
|**Cory Petkovsek, Tokisan Games** | [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/twitter.png?raw=true" width="24"/>](https://twitter.com/TokisanGames) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/github.png?raw=true" width="24"/>](https://github.com/TokisanGames) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/www.png?raw=true" width="24"/>](https://tokisan.com/) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/discord.png?raw=true" width="24"/>](https://tokisan.com/discord) [<img src="https://github.com/dmhendricks/signature-social-icons/blob/master/icons/round-flat-filled/35px/youtube.png?raw=true" width="24"/>](https://www.youtube.com/@TokisanGames)|

And other contributors displayed on the right of this github page and in [CONTRIBUTORS.md](https://github.com/outobugi/GDExtensionTerrain/blob/main/CONTRIBUTORS.md).

Geometry clipmap mesh code created by [Mike J Savage](https://mikejsavage.co.uk/blog/geometry-clipmaps.html). Blog and repository code released under the MIT license per email communication with Mike.


## License

This plugin is released under the MIT license. See [LICENSE](https://github.com/outobugi/GDExtensionTerrain/blob/main/LICENSE).

