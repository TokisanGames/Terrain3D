User Interface
=================


**Table of Contents**
* [Main Toolbar](#main-toolbar)
* [Keyboard Shortcuts](#keyboard-shortcuts)
* [Tool Settings](#tool-settings)
* [Asset Dock](#asset-dock)


## Main Toolbar

After properly installing and enabling the plugin, add a Terrain3D node to your Scene and select it. This will enable the editing tools.

```{image} images/ui_tools.png
:target: ../_images/ui_tools.png
```

The tools provide options for sculpting, texturing, and other features. Each button has a tooltip that describes what it does.

First, select the Region Tool (first one: square with a cross), and click the ground. This allocates space for you to sculpt and paint.

---

## Keyboard Shortcuts

The following mouse and keyboard shortcuts are available.

*Note*: Touchscreen users will see an `Invert` checkbox on the settings bar which acts like <kbd>Ctrl</kbd> to inverse operations.

### General Keys
* <kbd>LMB</kbd> - Click the terrain to positively apply the current tool.
* <kbd>Ctrl + LMB</kbd> - **Inverse** the tool. Removes regions, height, color, wetness, autoshader, holes, navigation, foliage.
* <kbd>Shift + LMB</kbd> - Change to the **Smooth** sculpting tool if shift is the _only_ modifier pressed.
* <kbd>Ctrl + Z</kbd> - Undo. You can also view the operations in Godot's `History` panel.
* <kbd>Ctrl + Shift + Z</kbd> - Redo.
* <kbd>Ctrl + S</kbd> - Save the scene and all data.

### Sculpting Specific
* <kbd>Alt + LMB</kbd> - **Lift floors**. This lifts up lower portions of the terrain without affecting higher terrain around it. Use it along the bottom of cliff faces. See [videos demonstrating before and after](https://github.com/TokisanGames/Terrain3D/pull/409). 
* <kbd>Ctrl + Alt + LMB</kbd> - **Flatten peaks**. The inverse of the above. This reduces peaks and ridges without affecting lower terrain around it.

### Slope Operations Specific

These operations support slope: **Paint**, **Spray**, **Color**, **Wetness**, **Instancer**.

* <kbd>LMB</kbd> - Operate within the set slope.
* <kbd>Alt + LMB</kbd> - Operate outside the set slope.
* <kbd>Ctrl + Alt + LMB</kbd> - Inversely operate outside the set slope. eg. Remove color or foliage outside the defined slope setting.

### Instancer Specific
* <kbd>LMB</kbd> - Add the selected mesh instance to the terrain.
* <kbd>Ctrl + LMB</kbd> - Remove instances of the selected type.
* <kbd>Ctrl + Shift + LMB</kbd> - Remove instances of any type.


---

## Tool Settings

Depending on which tool is selected on the toolbar, various tool settings will appear on the bottom bar.

```{image} images/ui_tool_settings.jpg
:target: ../_images/ui_tool_settings.jpg
```

Many tool settings offer a slider with a fixed range, and an input box where you can manually enter a much larger setting.

The settings are saved across sessions. But you can click the label of each to reset the value to its default.

Most are self explanatory. See [Foliage Instancing](instancer.md) for specific details on its settings.

On the right is the advanced menu. One noteworthy setting is `Jitter`, which is what causes the brush to spin while painting. Reduce it to zero if you don't want this.

Brushes can be edited in the `addons/terrain_3d/brushes` directory, using your OS folder explorer. The folder is hidden to Godot. The files are 100x100 alpha masks saved as EXR. Larger sizes should work fine, but will be slow if too big.


---

## Asset Dock


The asset dock houses the list of textures and meshes available for use in Terrain3D. The contents are stored in the [Terrain3DAssets](../api/class_terrain3dassets.rst) resource shown in the inspector when the Terrain3D node is selected.

Click `Textures` or `Meshes` to switch between the asset types.

```{image} images/ui_asset_dock_bottom.png
:target: ../_images/ui_asset_dock_bottom.png
```

### Dock Position

The dropdown box allows you to select the dock position. Shown above, it is docked to the bottom panel. Below, it is docked to the right sidebar, in the [bottom right position](https://docs.godotengine.org/en/stable/classes/class_editorplugin.html#class-editorplugin-constant-dock-slot-left-ul).

```{image} images/ui_asset_dock_sidebar.png
:target: ../_images/ui_asset_dock_sidebar.png
```

The icon with white and grey boxes in the top right can be used to pop out the dock into its own window. While in this state, there is a pin button that allows you to enable or disable always-on-top.

Next the slider will resize the thumbnails.

Finally, when the dock is in the sidebar, there are three vertical, grey dots, shown in the image above in the top right. This also allows you to change the sidebar position, however setting it here won't save. Ignore this and use our dropdown instead.


### Setting Up Assets

#### Adding Assets
You can add resources by dragging a texture onto the `Add Texture` icon, a mesh (a packed scene: tscn, scn, fbx, glb) onto the `Add Mesh` icon, or by clicking either `Add` button and setting them up. 

Each asset resource type has their own settings described in the API docs for [Terrain3DTextureAsset](../api/class_terrain3dtextureasset.rst) and [Terrain3DMeshAsset](../api/class_terrain3dmeshasset.rst).

You can read more about mesh setup on the [Foliage Instancer page](instancer.md#how-to-use-the-instancer).

#### Operations

<kbd>LMB</kbd> - Select the asset to paint with.

<kbd>RMB</kbd> - Edit the asset in the inspector. You can also click the pencil on the thumbnail.

<kbd>MMB</kbd> - Clear the asset. You can also click the X on the thumbnail. If this asset is at the end of the list, this will also remove it. You can clear and reuse this asset, or change its ID to move it to the end for removal. When using the instancer, this will remove all instances painted on the ground. It will ask for confirmation first.



