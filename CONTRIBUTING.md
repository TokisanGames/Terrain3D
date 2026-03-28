# Contributing To Terrain3D

We need your help to make this the best terrain plugin for Godot.

Please see [System Architecture](https://terrain3d.readthedocs.io/en/stable/docs/system_architecture.html) to gain an understanding of how the system works. Then review the [roadmap](https://github.com/users/TokisanGames/projects/3) for priority of issues.

If you wish to take on a major component, it's best to join our [discord server](https://tokisan.com/discord) and discuss your plans in #terrain3d-dev to make sure your efforts are aligned with other plans.

**Table of Contents**
* [Important Directories](#important-directories)
* [Setup Your System](#setup-your-system)
* [PR Workflow](#pr-workflow)
* [Code Style](#code-style)
* [Documentation](#documentation)
* [Maintainers](#maintainers)

 
## Important Directories

* `src` - C++ source for the library
* `src/shaders` - GLSL source for the default shader
* `doc/doc_classes` - XML docs for C++ classes
* `doc/docs` - MD tutorial docs
* `project/addons/terrain_3d`
  * `src` - GDScript for the editor plugin: the user interface for hand editing
  * `menu` - GDScript for the tools menu: bakers, channel packer
  * `tools` - GDScript for the importer, which will eventually be merged into the menu
  * `utils` - GDScript for other objects, eg. terrain_3d_objects.gd
  * `extras` - GDScript examples for users


## Setup Your System

Make sure you are setup to [build the plugin from source](https://terrain3d.readthedocs.io/en/stable/docs/building_from_source.html). 

### Install clang-format

clang-format will adjust the style of your code to a consistent standard. Once you install it you can manually run it on all of your code to see or apply changes, and you can set it up to run automatically upon each commit.

#### Installing clang-format binary onto your system.
* Download version 13 or later
* Make sure the LLVM binary directory where `clang-format` is stored gets added to the `PATH` during installation
* Linux/OSX: Install the `clang-format` package, or all of `LLVM` or `clang` if your distribution doesn't provide the standalone tool
* Windows: Download LLVM for Windows from <https://releases.llvm.org/download.html>

#### Using clang-format automatically

We use Godot's clang-format hooks that will format your code upon making a commit. Install the hooks into your repo after cloning.

* Copy `tools/hooks/*` into `.git/hooks` or run `python tools/install-hooks.py`

#### Using clang-format manually

* View a formatted file, no changes on disk: `clang-format <filenames>`
* See what changes would be made: `git-clang-format --diff <filenames>`
* Change the files in place: `clang-format -i <filenames>`

 
## PR Workflow

We use the standard [Godot PR workflow](https://contributing.godotengine.org/en/latest/organization/pull_requests/creating_pull_requests.html). Please submit PRs according to the same process Godot uses.

This includes: 
* Creating a new branch (not main) before submitting the PR.
* Never using git merge, or the `sync` button. Only fetch, push, pull.
* To update your PR to the latest main, rebase it then force push into your branch.
  * `git pull --rebase upstream main`
  * `git push -f`

Read the guide above for more details.


## Code Style

### GDScript

In general, follow the [Godot GDScript style guidelines](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html). 
In addition:
* All variables and functions are static typed, with a colon then space (eg. `var state: int = 3`)
* Auto static typing can be used *only* when the type is specifically assigned (eg. `var point := Vector2(1, 1)`)
* Two blank lines between functions

### GLSL

* Similar to C++ formatting below, except use `float` and no clang-format
* Private uniforms are prefaced with `_` and are hidden from the inspector and not accessible via set/get_shader_param()

### C++

In general, follow the [Godot C++ style guidelines](https://contributing.godotengine.org/en/latest/engine/guidelines/code_style.html).
In addition:

Use const correctness:
* Function parameters that won't be changed (almost all) should be marked const. Exceptions are pointers, or where passing a variable the function is supposed to modify, eg. Terrain3D::_generate_triangles
* Functions that won't change the object should be marked const (e.g. most get_ functions)

Pass by reference:
* Pass everything larger than 4 bytes by reference, including Ref<> and arrays, dictionaries, RIDs. e.g. `const Transform3D &xform`

* Floats:
* Use `real_t` instead of `float`
* Format float literals like `0.0f` or `0.f`
* Float literals and `real_t` variables can share operations (e.g. `mydouble += 1.0f`) unless the compiler complains. e.g. `Math::lerp(mydouble, real_t(0.0f), real_t(1.0f))`

* Standard Library & Godot Functions:
* Use `std::abs`, not `Math::abs` (same), and definitely not `abs` (broken on mingw)
* Use `std::isnan`, not `Math::is_nan` (same)

Braces:
* Everything braced - no if/for one-liners. Including switch cases
* One line setters/getters can go in the header file
* Opening brace on the initial line (eg. `if (condition) {`), and ending brace at the same tab stop as the initial line

Private & Public:
* Private variables/functions prefaced with `_`
* One initial public section for constants
* Private/public/protected for members and functions in that order, in header and cpp files
* Functions in h and cpp files in same order

Other formatting:
* One blank line between functions
* All code passed through clang-format. See above


## Documentation

All PRs that include new methods and features or changed functionality should include documentation updates. This could be in the form of a tutorial page for the user manual, or API changes to the XML Class Reference.

### User Manual

Tutorials and usage documentation lives in [doc/docs](https://github.com/TokisanGames/Terrain3D/tree/main/doc/docs) and is written in Markdown (*.md). Images are stored in `images` and videos are stored [_static/video](https://github.com/TokisanGames/Terrain3D/tree/main/doc/_static/video). 

Pages also need to be included in the table of contents `doc/index.rst`. Readthedocs will then be able to find everything it needs to build the html documentation upon a commit.

### Class Reference

The class reference documentation that contributors edit is stored in [XML files](https://github.com/TokisanGames/Terrain3D/tree/main/doc/classes). These files are used as the source for generated documentation.

Edit the class reference according to the [Godot class reference primer](https://docs.godotengine.org/en/stable/engine_details/class_reference/index.html).

Godot's doc-tool is used to extract or update the class structure from the compiled addon. See below for instructions.

### Using the Documentation Generation Tools

This step isn't required for contributors. You may ask for help generating the XML class structure so you can edit it, or generating the resulting RST files. 

#### To setup your system

1. Use a bash shell available in linux, [gitforwindows](https://gitforwindows.org), or [Microsoft's WSL](https://learn.microsoft.com/en-us/windows/wsl/install).
2. Install the following modules using python's pip: `pip install docutils myst-parser sphinx sphinx-rtd-theme sphinx-rtd-dark-mode`.
3. Edit `doc/build_docs.sh` and adjust the paths to your Godot executable and `make_rst.py`, found in the Godot repository.

#### To edit the documentation

1. Build Terrain3D with your updated code.
2. Within the `doc` folder, run `./build_docs.sh`. The following will occur:
  - The Godot executable dumps the XML structure for all classes, including those of installed addons.
  - Any existing XML files (eg Terrain3D*) will be updated with the new structure, leaving prior written documentation.
  - Sphinx RST files are generated from the XML files.
  - All non-Terrain3D XML files are removed.
  - A local html copy of the docs are generated from the Markdown and RST files, and a browser is open to view them.
3. Fill in the XML files with documentation of the new generated structure and make any other changes to the Markdown files.
4. Run the script again to update the RST files. This isn't necessary for Markdown updates, except to view the changes locally.
5. Push your updates to the Markdown, XML, and RST files to the repository. Due to the nature of generation scripts, carefully review the changes so you only push those you intend.
6. Readthedocs will detect commits to the main tree and will build the online html docs from the Markdown and RST files.

Doc generation via Sphinx is configured by conf.py and requirements.txt. Readthedocs also reads .readthedocs.yaml. The website is configured to automatically build based on specifically chosen branches and tags. `latest` is `main`. `stable` is a tag that we must manually update to point to the latest stable commit.


## Maintainers

There are various responsibilities and processes maintainers need to do to update Terrain3D.

1. Ensure PR builds are successful, and occasionally make changes to the build scripts when Github makes changes.
2. Ensure PRs are up to code standards and include XML documentation. You may need to generate the XML for them first.
3. [Update docs](#using-the-documentation-generation-tools) to generate the XML and RST files. Readthedocs will update automatically once PRs are merged. Though if it fails, you may need to log in and figure out why. It can be a bit finicky. They have automatic tags.
4. [Update C# bindings](generating_csharp_bindings.md) as the API changes.
5. Update versions and tags as indicated below.


## Updating New Versions and Releases of Terrain3D

Edit the following files on new releases and versions.

### New Terrain3D Release Version
* Set src/terrain_3d.h : _version
* Set project/addons/terrain_3d/plugin.cfg : version
* Set doc/conf.py : version
* Rebuild the docs with doc/build_docs.sh
* Review minimum version in terrain.gdextension
* Create a new tag for github
* Create a new branch for new milestones (1.0) so readthedocs will create a new version. You may need to enable it on their website.
* Reassign the `stable` tag for readthedocs to update that doc build. `latest` automatically builds off of `main`.


### New Terrain3DRegion Data Format Version
* Update src/terrain_3d_data.h : CURRENT_DATA_VERSION
* Update docs/data_format.md


### New Year:
* Update Copyright header in all source files and conf.py


## Maintaining multiple versions

Occasionally we might maintain two builds of the same version, such as `1.1-godot4.4` and `1.1` for Godot 4.5+. In this case the difference was the former used the godot-cpp 4.4 API, the latter used the 4.5 API. There was a minor but important difference in our code. I wanted all commits from one branch to be in the other branch, except for the few that changed the godot-cpp API. Here's how that process worked.

1. At the time, `main` was 1.1-dev and I had made a separate `1.1-godot4.4` branch. I made a commit changing godot-cpp to the 4.5 API.
2. Then after some commits, I cherry-picked all of the new ones from `main` into `1.1-godot4.4`.
3. On `main`, I created a tag called `_last-cherry-pick` so that when I periodically updated the 4.4 branch I knew where I left off.
4. Bulk cherry-picking is easy to do with the following:

```
git checkout 1.1-godot4.4                              # Start in the destination branch
git cherry-pick --no-merges _last-cherry-pick..main    # Use any two hashes or tags
git diff main                                          # Ensure the only difference is the 4.5 API change in this example
git push                                               # Upload all bulk cherry-picked commits
```


