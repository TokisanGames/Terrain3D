Keyboard Shortcuts
=================

The following mouse and keyboard shortcuts or hotkeys are available.


## General Keys

* <kbd>LMB</kbd> - Click the terrain to positively apply the current tool.
* <kbd>Ctrl + LMB</kbd> - **Inverse** the tool. Removes regions, color, wetness, autoshader, holes, navigation, foliage. 
  * Ctrl + Height picks the height at the cursor then flattens.
  * Use <kbd>Cmd</kbd> on **macOS**.
* <kbd>Shift + LMB</kbd> - Temporarily change to the **Smooth** sculpting tool.
* <kbd>Alt + LMB</kbd> - Use a special alternate mode when applicable. See Raise and Slope Filter below.
* <kbd>Ctrl + Z</kbd> - **Undo**. You can view the entries in the Godot `History` panel.
* <kbd>Ctrl + Shift + Z</kbd> - **Redo**.
* <kbd>Ctrl + S</kbd> - **Save** the scene and modified terrain data. Regions saved are written to the console.


## Tool Selection

The mouse must be in the 3D Viewport for these to work.

* <kbd>E</kbd> - Add / remove **rEgion**
* <kbd>R</kbd> - Sculpt **Raise** or lower
* <kbd>H</kbd> - Sculpt **Height**
* <kbd>S</kbd> - Sculpt **Slope**
* <kbd>B</kbd> - Paint **Base** texture
* <kbd>V</kbd> - Spray **oVerlay** texture
* <kbd>A</kbd> - Paint **Autoshader**
* <kbd>C</kbd> - Paint **Color**
* <kbd>W</kbd> - Paint **Wetness**
* <kbd>N</kbd> - Paint **Navigation**
* <kbd>I</kbd> - **Instance** meshes


## Raise Sculpting Specific

These modes are applicable only when using the Raise sculpting tool.

* <kbd>Alt + LMB</kbd> - **Lift floors**. This lifts up lower portions of the terrain without affecting higher terrain. Use it along the bottom of cliff faces. See [videos demonstrating before and after](https://github.com/TokisanGames/Terrain3D/pull/409). 
* <kbd>Ctrl + Alt + LMB</kbd> - **Flatten peaks**. The inverse of the above. This reduces peaks and ridges without affecting lower terrain around it.


## Slope Filter

The slope filter on the bottom [Tool Settings](user_interface.md#tool-settings) bar allows you to paint by slope. E.g., If the slope filter is 0-45 degrees, then it will paint if the slope of the ground is 45 degrees or less. There's also an option to inverse the slope and paint if the ground is between 45 and 90 degrees.

Don't confuse this with the slope sculpting tool on the left toolbar.

These operations work with the slope filter: **Paint**, **Spray**, **Color**, **Wetness**, **Instancer**.

* <kbd>LMB</kbd> - Add as normal, within the defined slope. 
* <kbd>Ctrl + LMB</kbd> - Remove within the defined slope.
* <kbd>Alt + LMB</kbd> - Add with the slope inversed.
* <kbd>Ctrl + Alt + LMB</kbd> - Remove with the slope inversed.


## Instancer Specific
* <kbd>LMB</kbd> - Add the selected mesh to the terrain.
* <kbd>Ctrl + LMB</kbd> - Remove instances of the selected type.
* <kbd>Ctrl + Shift + LMB</kbd> - Remove instances of **any** type.


## Overlays
The mouse must be in the 3D Viewport for these.
* <kbd>1</kbd> - Overlay the **Region Grid**.
* <kbd>2</kbd> - Overlay the **Instancer Grid**.
* <kbd>3</kbd> - Overlay the **Vertex Grid**.
* <kbd>4</kbd> - Overlay **Contour Lines**. Customize in the material when enabled.

## Special Cases

**macOS Users:** Use <kbd>Cmd</kbd> instead of <kbd>Ctrl</kbd>.

**Maya Users:** The <kbd>Alt</kbd> key can be changed to Space, Meta (Windows key), or Capslock in `Editor Settings / Terrain3D / Config / Alt Key Bind` so it does not conflict with Maya input settings `Editor Settings / 3D / Navigation / Navigation Scheme`.

**Touchscreen Users:** will see an `Invert` checkbox on the settings bar which acts like <kbd>Ctrl</kbd> to inverse operations.
