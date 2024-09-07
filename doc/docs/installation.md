Installation & Upgrades
==========================

**Table of Contents**
* [Requirements](#requirements)
* [Installing Terrain3D](#installing-terrain3d)
* [Upgrading Terrain3D](#upgrading-terrain3d)

## Requirements
* Supports Godot 4.2 & 4.3
* Supports Windows, Linux, and macOS. 
* macOS users should [build from source](building_from_source.md) or [adjust security settings](https://github.com/TokisanGames/Terrain3D/issues/227) to use the binary release.
* Mobile, Web, SteamDeck, & Compatibility renderer are [experimental or pending](mobile_web.md).

## Installing Terrain3D

### From The Asset Library
Terrain3D is listed in the Asset Library [here](https://godotengine.org/asset-library/asset/3134), but you can download it directly within Godot.
1. Setup a project within Godot.
2. Click `AssetLib` at the top of the Godot window.
3. Search for `Terrain3D`, and click the entry from `TokisanGames`.
4. Click `Download`.
5. Godot will ask you to install files into `addons` and `demo`. Demo is optional, but highly recommended for troubleshooting. Click `Install`.
6. Restart when Godot prompts.
7. In `Project Settings / Plugins`, ensure that Terrain3D is enabled.
8. Select `Project / Reload Current Project` to restart once more.
9. Open `demo/Demo.tscn`. You should see a terrain. Run the scene by pressing `F6`. 

**Updated 0.9.3-dev:** When using Terrain3D in your own scene, select the Terrain3D node in the Scene panel. In the Inspector, click the folder icon to the right of `data directory`, and specify a directory to store your data. This directory can be used shared with other scenes.

If it isn't working for you, watch the [tutorial videos](tutorial_videos.md) and read [Troubleshooting](troubleshooting.md) and [Getting Help](getting_help.md).

### Manually Running The Demo
1. Download the [latest binary release](https://github.com/TokisanGames/Terrain3D/releases) and extract the files, or [build the plugin from source](building_from_source.md).
2. Run Godot using the console executable so you can see error messages.
3. In the Project Manager, import the demo project and open it. Restart when it prompts.
4. In `Project Settings / Plugins`, ensure that Terrain3D is enabled.
5. Select `Project / Reload Current Project` to restart once more.
6. If the demo scene doesn't open automatically, open `demo/Demo.tscn`. You should see a terrain. Run the scene by pressing `F6`. 

If it isn't working for you, watch the [tutorial videos](tutorial_videos.md) and read [Troubleshooting](troubleshooting.md) and [Getting Help](getting_help.md).

### Manually Into Your Project (v0.9.3-dev running a nightly build)
1. Download the [latest binary release](https://github.com/TokisanGames/Terrain3D/releases) and extract the files, or [build the plugin from source](building_from_source.md).
2. Copy `addons/terrain_3d` to your project folder as `addons/terrain_3d`.
3. Run Godot using the console executable so you can see error messages. Restart when it prompts.
4. In `Project Settings / Plugins`, ensure that Terrain3D is enabled.
5. Select `Project / Reload Current Project` to restart once more.
6. Create or open a 3D scene and add a new Terrain3D node.
7. **Updated 0.9.3-dev:** Select Terrain3D in the Scene panel. In the Inspector, click the folder icon to the right of `data directory` and specify a directory to store your data. This directory can be used shared with other scenes.

If it isn't working for you, watch the [tutorial videos](tutorial_videos.md) and read [Troubleshooting](troubleshooting.md) and [Getting Help](getting_help.md).

## Upgrading Terrain3D

To update Terrain3D: 
1. Close Godot.
2. Remove `addons/terrain_3d` from your project folder.
3. Copy `addons/terrain_3d` from the new release download or from your build directory into your project addons folder.

Don't just copy the new folder over the old, as this won't remove any files that we may have intentionally removed.

### Upgrade Path

While later versions of Terrain3D can generally open previous versions, not all data will be loaded unless the supported upgrade path is followed. We occasionally deprecate or rename classes and provide upgrade paths to convert data for a limited time. 

Given the table below, to upgrade 0.8 to the latest version you would need to open your files in 0.9.0, save, then open in 0.9.3, and save again.

| Starting Version | Can Upgrade w/ Data Conversion |
|------------------|-------------------|
| 0.9.2 | 0.9.3* |
| 0.9.1 | 0.9.2 - 0.9.3* |
| 0.9.0 | 0.9.2 - 0.9.3* |
| 0.8.4 | 0.9.2 - 0.9.3* |
| 0.8.3 | 0.8.4 - 0.9.0 |
| 0.8.2 | 0.8.4 - 0.9.0 |
| 0.8.1 | 0.8.4 - 0.9.0 |
| 0.8.0 | 0.8.4 - 0.9.0 |

* 0.9.3 - Data storage changed from a single .res file to one file per region saved in a directory.
