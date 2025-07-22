User Interface
=================

This document describes the various UI components of Terrain3D.

**Table of Contents**
* [Main Toolbar](#main-toolbar)
* [Terrain3D Menu](#terrain3d-menu)
* [Tool Settings Bar](#tool-settings-bar)
* [Asset Dock](#asset-dock)


## Main Toolbar

After properly installing and enabling the plugin, add a Terrain3D node to your Scene and select it. This will enable the toolbar.

```{image} images/ui_tools.png
:target: ../_images/ui_tools.png
```

The tools provide options for sculpting, texturing, and other features. Each button has a tooltip that describes what it does.

First, select the Region Tool (first one: square with a cross), and click the ground. This allocates space for you to sculpt and paint.


## Terrain3D Menu

After selecting the Terrain3D node, the Terrain3D menu appears at the top of the viewport. This provides a variety of utilities such as our channel packer, mesh baker, occlusion baker, etc. These are documented elsewhere.

```{image} images/terrain3d_menu.png
:target: ../_images/terrain3d_menu.png
```

---

## Tool Settings Bar

Depending on which tool is selected on the toolbar, various tool settings will appear on the bottom bar.

```{image} images/ui_tool_settings.jpg
:target: ../_images/ui_tool_settings.jpg
```

Many tool settings offer a slider with a fixed range, and an input box where you can manually enter a much larger setting.

Click the label of any setting to reset the value to its default, or checkboxes to toggle.

The settings are saved across sessions in `Editor Settings / Terrain3D / Tool Settings`. 

Some tools like `Paint`, `Spray`, and `Color` have options to disable some features. e.g. Disabling `Texture` on `Paint` means it will only apply scale or angle. Enabling `Texture` on `Color` will filter color painting to the selected texture.

The three dots button on the right is the advanced options menu. One noteworthy setting is `Brush Spin Speed`, which is what causes the brush to spin while painting. Reduce it to zero if you don't want this.

Brushes can be edited in the `addons/terrain_3d/brushes` directory, using your OS folder explorer. The folder is hidden to Godot. The files are 100x100 alpha masks saved as EXR. Larger sizes should work fine, but will be slow if too big. We scale all brushes up to a minimum of 1024px on selection.

Most other options are self explanatory. See [Foliage Instancing](instancer.md) for specific details on its settings.

### Slope Range Filter

The slope filter on the settings bar allows you to paint by slope. If the slope filter is 0-45 degrees, then it will paint if the slope of the ground is 45 degrees or less. 

Don't confuse this with the slope sculpting tool on the left toolbar.

These tools work with the slope filter: **Paint**, **Spray**, **Color**, **Wetness**, **Instancer**.

See the [keyboard shortcuts](keyboard_shortcuts.md) for usage, including the option to inverse the slope.


---

## Asset Dock


The asset dock houses the list of textures and meshes available for use in Terrain3D. The contents are stored in the [Terrain3DAssets](../api/class_terrain3dassets.rst) resource shown in the inspector when the Terrain3D node is selected.

Click `Textures` or `Meshes` to switch between the asset types.

Mesh thumbnail generation is currently unreliable. Hover over a mesh or click `Meshes` to regenerate them.

```{image} images/ui_asset_dock_bottom.png
:target: ../_images/ui_asset_dock_bottom.png
```

### Dock Position

The dropdown option allows you to select the dock position. Shown above, it is docked to the bottom panel. Below, it is docked to the right sidebar, in the [bottom right position](https://docs.godotengine.org/en/stable/classes/class_editorplugin.html#class-editorplugin-constant-dock-slot-left-ul).

```{image} images/ui_asset_dock_sidebar.png
:target: ../_images/ui_asset_dock_sidebar.png
```

The icon with white and grey boxes in the top right can be used to pop out the dock into its own window. While in this state, there is a pin button that allows you to enable or disable always-on-top.

Next the slider will resize the thumbnails.

Finally, when the dock is in the sidebar, there are three vertical, grey dots, shown in the image above, in the top right. This also allows you to change the sidebar position, however setting it here won't save. Ignore this and use our dropdown instead.


### Adding Assets

You can add resources by dragging a texture onto the `Add Texture` icon, a mesh (a packed scene: tscn, scn, fbx, glb) onto the `Add Mesh` icon, or by clicking either `Add` button and setting them up manually.

If you add a new texture and the terrain turns white, see [Troubleshooting](troubleshooting.md#added-a-texture-now-the-terrain-is-white).

Each asset resource type has their own settings described in the API docs for [Terrain3DTextureAsset](../api/class_terrain3dtextureasset.rst) and [Terrain3DMeshAsset](../api/class_terrain3dmeshasset.rst).

You can read more about mesh setup on the [Foliage Instancer page](instancer.md#how-to-use-the-instancer).

### Dock Operations

* <kbd>LMB</kbd> - Select the asset to paint with.
* <kbd>RMB</kbd> - Edit the asset in the inspector. You can also click the pencil on the thumbnail.
* <kbd>MMB</kbd> - Clear the asset. You can also click the X on the thumbnail. If this asset is at the end of the list, this will also remove it. You can clear and reuse this asset, or change its ID to move it to the end for removal. When using the instancer, this will remove all instances painted on the ground. It will ask for confirmation first.



