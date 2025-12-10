Installation & Upgrades
==========================

**Table of Contents**
* [Requirements](#requirements)
* [Installing Terrain3D](#installing-terrain3d)
* [Upgrading Terrain3D](#upgrading-terrain3d)

## Requirements
* Terrain3D 1.0.1 supports Godot 4.4+. Use 1.0.0 for 4.3.
* Supports Windows, Linux, and [macOS (read more)](platforms.md#macos).
* Some platforms and renderers are experimental or unsupported. See [Supported Platforms](platforms.md).

## Installing Terrain3D

### From The Asset Library
Terrain3D is [listed in the Asset Library](https://godotengine.org/asset-library/asset/3134), so you can download it directly within Godot.
1. Run Godot using the console executable so you can see error messages.
2. Setup a new project within Godot.
3. Click `AssetLib` at the top of the Godot window.
4. Search for `Terrain3D`, and click the entry from `TokisanGames` shown for your Godot version.
5. Click `Download`.
6. Godot will ask you to install files into `addons` and `demo`. Demo is optional, but highly recommended for troubleshooting. Click `Install`.
7. Restart when Godot prompts.
8. In `Project / Project Settings / Plugins`, ensure that Terrain3D is enabled.
9. Select `Project / Reload Current Project` to restart once more.
10. Open `demo/Demo.tscn`. You should see a terrain. Run the scene by pressing `F6`.

If the demo isn't working for you, watch the [tutorial videos](tutorial_videos.md) and see [Troubleshooting](troubleshooting.md) and [Getting Help](getting_help.md).

Continue below to [In Your Own Scene](#in-your-own-scene).

### From Github
1. Download the [latest binary release](https://github.com/TokisanGames/Terrain3D/releases) and extract the files, or [build the plugin from source](building_from_source.md).
2. Run Godot using the console executable so you can see error messages.
3. In the Project Manager, import the demo project and open it. Restart when it prompts.
4. In `Project / Project Settings / Plugins`, ensure that Terrain3D is enabled.
5. Select `Project / Reload Current Project` to restart once more.
6. If the demo scene doesn't open automatically, open `demo/Demo.tscn`. You should see a terrain. Run the scene by pressing `F6`. 

If the demo isn't working for you, watch the [tutorial videos](tutorial_videos.md) and see [Troubleshooting](troubleshooting.md) and [Getting Help](getting_help.md).

Continue below.

### In Your Own Scene
* To use Terrain3D in your own project, copy `addons/terrain_3d` to your project folder as `addons/terrain_3d`. Create the directories if they are missing.
* When making a new 3D scene, add a Terrain3D node to your Scene panel. In the Inspector, find `Data Directory` and click the folder icon to specify an empty directory in which to store your data. You can share this directory with other scenes that will load the same terrain map. Different terrain maps need separate directories.
* Optionally, click the arrow to the right of `Material` and `Assets` and save these as `.tres` files should you wish to share your material settings and asset dock resources (textures and meshes) with other scenes. This is recommended. Saving these in the data directory is fine.

Next, review the [user interface](user_interface.md) or learn how to [prepare your textures](texture_prep.md) if you're ready to start creating.


## Upgrading Terrain3D

To update Terrain3D: 
1. Close Godot.
2. Remove `addons/terrain_3d` from your project folder.
3. Copy `addons/terrain_3d` from the new release download or build directory into your project addons folder.

Don't just copy the new folder over the old, as this won't remove any files that we may have intentionally removed.

### Upgrade Path

While later versions of Terrain3D can generally open previous versions, not all data will be transfered unless the supported upgrade path is followed. We occasionally deprecate or rename classes and provide upgrade paths to convert data for a limited time. 

If upgrading from a very old version, you may need to go through multiple steps to upgrade to the latest version.

| Starting Version | Can Upgrade w/ Data Conversion |
|------------------|-------------------|
| 1.0.1 | 1.1.0 |
| 1.0.0 | 1.0.1 - 1.1.0 |
| 0.9.3 | 1.0.0 - 1.1.0 |
| 0.9.2 | 0.9.3* |
| 0.9.1 | 0.9.2 - 0.9.3* |
| 0.9.0 | 0.9.2 - 0.9.3* |
| 0.8.4 | 0.9.2 - 0.9.3* |
| 0.8.3 | 0.8.4 - 0.9.0 |
| 0.8.2 | 0.8.4 - 0.9.0 |
| 0.8.1 | 0.8.4 - 0.9.0 |
| 0.8.0 | 0.8.4 - 0.9.0 |

* 0.9.3 - Data storage changed from a single .res file to one file per region saved in a directory.

Also see [Data Format Changelog](data_format.md).