Keyboard Shortcuts
=================

The following mouse and keyboard shortcuts or hotkeys are available.


**Table of Contents**
* [General Keys](#general-keys)
* [Overlays](#overlays)
* [Tool Selection](#tool-selection)
* [Tool Specific Keys](#tool-specific-keys)
* [Special Cases](#special-cases)


## General Keys

* <kbd>LMB</kbd> - **Apply** the current tool to the terrain.
* <kbd>Ctrl + LMB</kbd> - **Inverse** the current tool. Use <kbd>Cmd</kbd> on macOS.
* <kbd>Shift + LMB</kbd> - **Smooth** height, texture blend, color, wetness.
* <kbd>Alt + LMB</kbd> - **Alternate mode**, where applicable.
* <kbd>T</kbd> - **Invert the slope filter** on the tool settings bar.
* <kbd>Ctrl + Z</kbd> - **Undo**. View the entries in the Godot `History` panel.
* <kbd>Ctrl + Shift + Z</kbd> - **Redo**
* <kbd>Ctrl + S</kbd> - **Save** scene & modified terrain data. Saved regions are printed to the [console](troubleshooting.md#using-the-console).


## Overlays

These toggle the Overlays found in the inspector. The mouse must be in the 3D Viewport with Terrain3D selected for these to work. 

* <kbd>1</kbd> - Toggle **Region Grid**.
* <kbd>2</kbd> - Toggle **Instancer Grid**.
* <kbd>3</kbd> - Toggle **Vertex Grid**.
* <kbd>4</kbd> - Toggle **Contour Lines**. Customize in the material when enabled.


## Tool Selection

The mouse must be in the 3D Viewport with Terrain3D selected for these to work.

* <kbd>E</kbd> - Add / remove **rEgion**.
* <kbd>R</kbd> - Sculpt **Raise** or lower.
* <kbd>H</kbd> - Sculpt **Height**.
* <kbd>S</kbd> - Sculpt **Slope**.
* <kbd>B</kbd> - Paint **Base** texture.
* <kbd>V</kbd> - Spray **oVerlay** texture.
* <kbd>A</kbd> - Paint **Autoshader**.
* <kbd>C</kbd> - Paint **Color**.
* <kbd>W</kbd> - Paint **Wetness**.
* <kbd>N</kbd> - Paint **Navigation**.
* <kbd>X</kbd> - Paint **Holes**.
* <kbd>I</kbd> - Add mesh **Instances**.


## Tool Specific Keys

### Region Tool

* <kbd>LMB</kbd> - **Add** a region.
* <kbd>Ctrl + LMB</kbd> - **Remove** a region.

### Raise / Lower Tool

* <kbd>LMB</kbd> - **Raise** the terrain.
* <kbd>Ctrl + LMB</kbd> - **Lower** the terrain.
* <kbd>Shift + LMB</kbd> - **Smooth** the terrain height.
* <kbd>Alt + LMB</kbd> - **Lift floors**: Lifts up lower portions of the terrain without affecting higher terrain. Use it along the bottom of cliff faces. See [videos demonstrating before and after](https://github.com/TokisanGames/Terrain3D/pull/409). 
* <kbd>Ctrl + Alt + LMB</kbd> - **Flatten peaks**: Reduces peaks and ridges without affecting lower terrain around it.

### Height Tool

* <kbd>LMB</kbd> - **Flatten** the terrain at the height set on the [settings bar](user_interface.md#tool-settings-bar).
* <kbd>Ctrl + LMB</kbd> - **Pick & Flatten**: Flattens the terrain at the height first clicked.
* <kbd>Shift + LMB</kbd> - **Smooth** the terrain height.

### Slope Tool

*This is not to be confused* with the slope range filter on the [settings bar](user_interface.md#tool-settings-bar).

* <kbd>LMB</kbd> - Set points to automatically create a slope, or if `Drawable` is checked, manually sculpt between points.
* <kbd>Shift + LMB</kbd> - **Smooth** the terrain height.

### Paint Tool

All operations are performed within the slope range on the [settings bar](user_interface.md#tool-settings-bar).

* <kbd>LMB</kbd> - **Paint** the base texture.
* <kbd>Shift + LMB</kbd> - **Smooth** the overlay texture blend value, averaging towards 0.5.
* <kbd>Alt + Shift + LMB</kbd> - **Smooth** the blend value with a true average.

### Spray Tool

All operations are performed within the slope range on the [settings bar](user_interface.md#tool-settings-bar).

* <kbd>LMB</kbd> - **Spray** the overlay texture, increase the blend value, and once over a certain threshold, set overlay ID.
* <kbd>Alt + LMB</kbd> - **Spray** the overlay texture, increase the blend value, and set the overlay ID immediately.
* <kbd>Ctrl + LMB</kbd> - **Remove** the overlay texture. Reduces the blend value, thus showing more of the base.
* <kbd>Shift + LMB</kbd> - **Smooth** the blend value, averaging towards 0.5.
* <kbd>Alt + Shift + LMB</kbd> - **Smooth** the blend value with a true average.

Note: Yes this is a ridiculous amount of options. But our lead environment artist uses all of them in different ways so we'll keep them for now. In the future we anticipate adding a 3rd texture layer for improved blending, which will likely consolidate all Paint and Spray options into one tool.


### Autoshader Tool

* <kbd>LMB</kbd> - **Add** areas to the autoshader.
* <kbd>Ctrl + LMB</kbd> - **Remove** areas from the autoshader.

### Color Tool

All operations are performed within the slope range on the [settings bar](user_interface.md#tool-settings-bar).

* <kbd>LMB</kbd> - **Paint** color on the terrain.
* <kbd>Ctrl + LMB</kbd> - **Remove** painted color from the terrain.
* <kbd>Shift + LMB</kbd> - **Smooth** the painted colors.

### Wetness Tool

All operations are performed within the slope range on the [settings bar](user_interface.md#tool-settings-bar).

* <kbd>LMB</kbd> - **Add** wet areas to the terrain.
* <kbd>Ctrl + LMB</kbd> - **Remove** wet areas from the terrain.
* <kbd>Shift + LMB</kbd> - **Smooth** the wetness values.

### Navigation Tool

* <kbd>LMB</kbd> - **Add** navigable areas to the terrain.
* <kbd>Ctrl + LMB</kbd> - **Remove** navigable areas.

### Holes Tool

* <kbd>LMB</kbd> - **Add** holes.
* <kbd>Ctrl + LMB</kbd> - **Remove** holes.
* <kbd>Shift + LMB</kbd> - **Smooth** the terrain height.

### Instancer Tool

All operations *except smoothing* are performed within the slope range on the [settings bar](user_interface.md#tool-settings-bar).

* <kbd>LMB</kbd> - **Add** the selected mesh instances to the terrain.
* <kbd>Ctrl + LMB</kbd> - **Remove** instances of the *selected* mesh asset.
* <kbd>Ctrl + Shift + LMB</kbd> - **Remove** instances of *any* mesh asset.
* <kbd>Shift + LMB</kbd> - **Smooth** the terrain height.

---

## Special Cases

**macOS Users:** Use <kbd>Cmd</kbd> instead of <kbd>Ctrl</kbd>.

**Touchscreen Users:** You'll see an `Invert` checkbox on the settings bar which acts like <kbd>Ctrl</kbd> to inverse operations.

**Maya Users:** The <kbd>Alt</kbd> key can be changed to Space, Meta (Windows key), or Capslock in `Editor Settings / Terrain3D / Config / Alt Key Bind` so it does not conflict with Maya input settings `Editor Settings / 3D / Navigation / Navigation Scheme`.
