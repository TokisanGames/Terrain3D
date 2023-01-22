# gdextension

GDExtension template that automatically builds into a self-contained addon for the Godot Asset Library.

<!-- TODO: Change `master` to `4.x` on release (or `4.0`).
     TODO: Change `godot4` to `godot` on release -->

# Compatibility warning:

This template is only intended to work with the latest `master` on GitHub, _not the latest point release, such as `beta1`_. Before reporting an issue, make sure you are on the latest `master` and the submodule `godot-cpp` is up-to-date by running the command `git submodule update --remote`.

### Getting started:
1. Clone this repository (or a new repository with this template) with submodules.
    - `git clone --recurse-submodules https://github.com/nathanfranke/gdextension.git` \
    - `cd gdextension`
2. Build a debug binary for the current platform.
    - `scons`
3. Import, edit, and play `project/` using Godot Engine 4+.
    - Alternatively, run the project using the terminal.
      - Either alias an existing executable to godot4: `alias godot4="~/workspace/godot/bin/godot.linuxbsd.tools.x86_64"`
      - Or, on Arch Linux, install `godot4-bin` from the AUR (`yay -S aur/godot4-bin`).
    - Finally, `godot4 --path project/`
4. Check the output:
   ```
   Hello GDScript!
   Hello GDExtension Node!
   Hello GDExtension Singleton!
   ```

### Repository structure:
- `project/` - Godot project boilerplate.
  - `addons/example/` - Files to be distributed to other projects.¹
  - `demo/` - Scenes and scripts for internal testing. Not strictly necessary.
- `src/` - Source code of this extension.
- `godot-cpp/` - Submodule needed for GDExtension compilation.

¹ Before distributing as an addon, all binaries for all platforms must be built and copied to the `bin/` directory. This is done automatically by GitHub Actions.

### Make it your own:
1. Rename `project/addons/example/` and `project/addons/example/example.gdextension`. The library name is automatically changed to the gdextension file name.
2. Replace `LICENSE`, `README.md`, and your code in `src/`.
3. Not required, but consider leaving a note about this template if you found it helpful!

### Distributing your extension on the Godot Asset Library:
1. Go to Repository→Actions and download the latest artifact.
2. Test the artifact by extracting the addon into a project.
3. Create a new release on GitHub, uploading the artifact as an asset.
4. On the asset, Right Click→Copy Link to get a direct file URL. Don't use the artifacts directly from GitHub Actions, as they expire.
5. When submitting/updating on the Godot Asset Library, Change "Repository host" to `Custom` and "Download URL" to the one you copied.
