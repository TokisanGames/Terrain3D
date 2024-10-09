Troubleshooting
=================

Make sure to watch the [tutorial videos](tutorial_videos.md) which show proper installation and setup.

Also see [Tips](tips.md) which may have other helpful information.

**Table of Contents**
* [Installation](#installation)
* [Texture Setup](#texture-setup)
* [Crashing](#crashing)
* [Usage](#usage)
* [Using the Console](#using-the-console)
* [Debug Logs](#debug-logs)


## Installation

### Unable to load addon script from path

`Unable to load addon script from path: xxxxxxxxxxx. This might be due to a code error in that script. Disabling the addon at 'res://addons/terrain_3d/plugin.cfg' to prevent further errors."`

Most certainly you've installed the plugin improperly. These are the common causes:

1) You downloaded the repository code, not a [binary release](https://github.com/TokisanGames/Terrain3D/releases).

2) You moved the files into the wrong directory. The Terrain3D files should be in `project/addons/terrain_3d`. `Editor.gd` should be found at `res://addons/terrain_3d/editor/editor.gd`. [See an example issue here](https://github.com/TokisanGames/Terrain3D/issues/200).  

Basically, the required library isn't where it's supposed to be. The error messages will tell you exactly the file name and path it's looking for. View that location on your hard drive. On windows you might be looking for `libterrain.windows.debug.x86_64.dll`. Does that file exist where it's looking in the logs? Probably not. Download the correct package, and review the instructions to install the files in the right location.

### After installation, there are no tools. The texture list is blank in the demo.
Click the Terrain3D node in the scene tree. Also see the next entry.

### After clicking the Terrain3D node, there are no editor tools or texture panel.

Enable the plugin in project settings. Review the [installation instructions](installation.md).

### The editor tools panel is there, but the buttons are blank or missing.

Restart Godot twice before using it. Review the [installation instructions](installation.md).

### Start up is very slow, and/or the scene or storage file is huge.

Save the storage resource as a binary `.res` file, as described in the [installation instructions](installation.md). You've likely saved it as text `.tres`, or didn't save it separately at all, which means a ton of terrain data is saved as text in the scene.

Alternatively, you have a large terrain and are generating collision for all of it. Disable collision, or set it to dynamic to create only a small collision around the camera (pending implementation, see [PR #278](https://github.com/TokisanGames/Terrain3D/pull/278)).

---

## Texture Setup

### Added a texture, now the terrain is white

Your console also reports something like:

`Texture # albedo / normal, size / format... doesn't match size of first texture... They must be identical.`

The new texture doesn't match the format or size of the existing ones. [Texture Preparation](texture_prep.md) descibes the requirements, which includes the same format and size for each. Double click a texture in the filesystem and Godot will tell you what it is. You can also click the texture in the inspector when editing an entry in the asset dock to see the same thing.

If adding textures to the demo, the format is PNG marked HQ so it converts to BPTC, which you can read about on the link above.


### The terrain is all black

Check with the default shader by disabling any override shader you have created.

If you're using the Compatibility renderer, your textures need to be flagged as uncompressed. See [Compatibility Renderer](platforms.md#compatibility) for the current limitations in Godot.


---

## Crashing

### Godot crashes on load

If this is the first startup after installing the plugin, this is normal due to a bug in the engine currently. Restart Godot.

If it still crashes, try the demo scene. 

If that doesn't work, most likely the library version does not match the engine version. If you downloaded a release binary, download the exactly matching engine version. If you built from source review the [instructions](building_from_source.md) to make sure your `godot-cpp` directory exactly matches the engine version you want to use. 

If the demo scene does work, you have an issue in your project. It could be a setting or file given to Terrain3D, or it could be anywhere else in your project. Divide and conquer. Copy your project and start ripping things out until you find the cause.

### Exported game crashes on startup

First make sure your game works running in the editor. Then ensure it works as a debug export with the console open. If there are challenges, you can enable [Terrain3D debugging](#debug-logs) before exporting with debug so you can see activity. Only then, test in release mode. 

Make sure you have both the debug and release binaries on your system, or have built Terrain3D in [both debug and release mode](building_from_source.md#5-build-the-extension), and that upon export both libraries are in the export directory (eg. `libterrain.windows.debug.x86_64.dll` and `libterrain.windows.release.x86_64.dll`). If you don't have the necessary libraries, your game will close instantly upon startup.

---

## Usage

### Collision is offset from the mesh and it's showing lower LODs near the camera

If you're using multiple cameras, or viewports, you need to tell Terrain3D which camera you want to use with `Terrain3D.set_camera()`. You can update it every frame if you like.


### Camera flickering

When another mesh intersects with Terrain3D far away from the camera, such as in the case of water on a beach, the two meshes can flicker as the renderer can't decide which mesh should be displayed in front. This is also called Z-fighting. You can greatly reduce it by increasing `Camera3D.near` to 0.25. You can also set it for the editor camera in the main viewport by adjusting `View/Settings/View Z-Near`.

### Segments of the terrain disappear on camera movement

You can increase `Renderer/Cull Margin`. For sculpted regions this should not be necessary as sculpting sets the AABB for the meshes already. However for shader based backgrounds like WorldBackground, it has no AABB and needs an increased cull margin if it is higher than the sculpted areas. This consumes performance so it is ideal if not used.


---

## Using the Console

As a gamedev, you should always be running with the console open. This means you ran `Godot_v4.*_console.exe` or ran Godot in a terminal window.

```{image} images/console_exec.png
:target: ../_images/console_exec.png
```

This is what it looks like this when you have the console open. 

```{image} images/console_window.png
:target: ../_images/console_window.png
```

Godot, Terrain3D, and every other addon gives you additional information here, and when things don't work properly, these messages often tell you exactly why.

Godot also has an `Output` panel at the bottom of the screen, but it is slow, will skip messages if it's busy, and not all messages appear there.


## Debug Logs

Terrain3D has debug logs for everything, which it can dump to the [console](#using-the-console). These logs *may* also be saved to Godot's log files on disk.

Set `Terrain3D.debug_level` to `Info` or `Debug` and you'll get copious activity logs that will help troubleshoot problems.

You can also enable debugging from the command line by running Godot with `--terrain3d-debug=<LEVEL>` where `<LEVEL>` is one of `ERROR`, `INFO`, `DEBUG`, `EXTREME`. Extreme dumps everything including repetitive messages such as those that appear on camera movement.

To run the demo from the command line with debugging, open a terminal, and change to the project folder (where `project.godot` is):

Adjust the file paths to your system. The console executable is not needed since you're already running these commands in a terminal window.

```
# 1. Change to the project folder
cd <PATH TO PROJECT FOLDER>

# 2a. Run the project with debugging enabled at startup
<PATH TO GODOT EXECUTABLE> --terrain3d-debug=DEBUG

# 2b. Or run the editor with debugging enabled at startup
<PATH TO GODOT EXECUTABLE> -e --terrain3d-debug=DEBUG


# E.g. To run the demo with debug messages
cd /c/gd/Terrain3D/project
/c/gd/bin/Godot_v4.1.3-stable_win64.exe --terrain3d-debug=DEBUG

# Load the editor with debug messages
/c/gd/bin/Godot_v4.1.3-stable_win64.exe -e --terrain3d-debug=DEBUG
```

When asking for help on anything you can't solve yourself, you'll need to provide a full log from your console or file system. As long as Godot doesn't crash, it saves the log files on your drive. In Godot select, `Editor, Open Editor Data/Settings Menu`. On windows this opens `%appdata%\Godot` (e.g. `C:\Users\%username%\AppData\Roaming\Godot`). Look under `app_userdata\<your_project_name>\logs`. Otherwise, you can copy and paste messages from the console window above.

