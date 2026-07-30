# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Terrain3D is a high-performance, editable terrain system for Godot 4, implemented as a C++ GDExtension addon (not a Godot module — it works with official Godot builds). The GDExtension binary is paired with a GDScript editor plugin (the hand-editing UI) that lives inside the demo/consumer project.

## Repository layout

- `src/` — C++ source for the GDExtension library (the core engine: terrain, data storage, collision, instancing, material, mesher, etc.)
- `src/shaders/` — GLSL source (`.glsl`) for the default terrain shader, included into the C++ material code
- `godot-cpp/` — git submodule; C++ bindings to Godot. Its checked-out version must match the target Godot engine version (see below)
- `doc/doc_classes/` — XML API class reference (source of truth for generated docs)
- `doc/docs/` — Markdown tutorial/user docs, built via Sphinx/Readthedocs
- `project/` — a full Godot project used for development/demo; the built extension binaries land in `project/addons/terrain_3d/bin`
  - `project/addons/terrain_3d/src` — GDScript for the editor plugin (hand-editing UI)
  - `project/addons/terrain_3d/menu` — GDScript for the tools menu (bakers, channel packer)
  - `project/addons/terrain_3d/tools` — GDScript importer (heightmaps etc.)
  - `project/addons/terrain_3d/utils` — other GDScript objects (e.g. `terrain_3d_objects.gd`)
  - `project/addons/terrain_3d/extras` — GDScript usage examples
  - `project/addons/terrain_3d/csharp` — generated C# bindings (regenerated via external tool, not hand-written)

## Build

Requires the same toolchain as building Godot itself (scons, python, a C++ compiler). The `godot-cpp` submodule must be checked out to a version compatible with the target Godot engine build — check with `git log` inside `godot-cpp/` for the nearest matching tag.

```
git submodule update --init
scons                          # debug build (editor + debug exports)
scons target=template_release  # release build
```

Output binaries land in `project/addons/terrain_3d/bin`. Then open `project/` in Godot, ensure the Terrain3D plugin is enabled (Project Settings → Plugins), and reload the project.

Useful build variants:
- `scons dev_build=yes` — build with debug symbols for source-level debugging
- `scons platform=<linux|macos|windows|android|ios|javascript>` — cross-platform builds
- `scons --clean` — clean build artifacts
- `scons --help` / `scons -H` — list all custom/scons options

There is no separate automated test suite/runner; `src/unit_testing.cpp` contains `EXPECT_TRUE`/`EXPECT_FALSE` macro-based checks (`test_differs()`) that print PASS/FAIL to the console when invoked — verification is manual, by running the plugin in the Godot editor.

## Code style

Enforced via `.clang-format` + pre-commit (`pip install pre-commit && pre-commit install`) for C/C++/GLSL-adjacent files. Full guidelines: `doc/docs/contributing.md`. Key points beyond the general Godot C++ style guide:

- Const-correct: parameters that aren't mutated are `const`; getters/non-mutating functions are `const` methods
- Pass anything >4 bytes by reference (`const Transform3D &xform`, `Ref<>`, arrays, dictionaries, RIDs)
- Use `real_t` instead of `float`; float literals as `0.0f`; use `std::abs`/`std::isnan`, not `Math::abs`/bare `abs` (broken on mingw)
- Braces required everywhere, even one-liners (if/for/switch cases); opening brace on the same line
- Private members/functions prefixed `_`; ordering is public/protected/private consistently between `.h` and `.cpp`
- One blank line between functions in C++; two blank lines between functions in GDScript
- GDScript: all vars/functions statically typed (`var state: int = 3`); `:=` only when the type is directly inferable
- GLSL: like C++ formatting but uses `float` (not `real_t`) and isn't run through clang-format; private uniforms prefixed `_`

PRs follow the standard Godot workflow: branch off `main`, never merge/sync — only fetch/push/pull; rebase + force-push to update a PR against latest `main`.

## Architecture

Full details: `doc/docs/system_architecture.md`.

- **Geometry clipmap terrain**: unlike chunk-streaming terrain systems, the mesh components are generated once at startup (with LODs baked in) and simply recentered on the camera at intervals; the GPU vertex shader displaces vertex heights by sampling the heightmap. Lower LODs are automatically positioned further from the camera.
- **Region-based sparse storage**: the world is divided into regions; only regions actually painted/sculpted consume VRAM/storage, so very large worlds (up to 65.5km × 65.5km) with sparse content stay cheap.
- **1 pixel == 1 vertex**: height/control/color maps map 1:1 to world vertices at LOD0. `Terrain3D.vertex_spacing` scales world-space distance between vertices without breaking this ratio.
- **Global positions are absolute**: any API function taking a `global_position` expects an absolute, unscaled global position from the user's perspective; it's descaled internally to local/image coordinates as needed. When one function calls another, the global (not descaled) position must be threaded through.
- **Control map encoding**: texture/paint data is packed into a single 32-bit integer per pixel (base/overlay texture id, blend, UV angle/scale, hole/nav/autoshader flags), stored in a `FORMAT_RF` image so it round-trips through Godot's image/texture system without float precision loss. Full bit layout: `doc/docs/controlmap_format.md`.
- **Data format versioning**: `Terrain3DRegion` resource files carry their own format version (see `Terrain3DData.version`), independent of the plugin's version — tracked in `doc/docs/data_format.md`.
- Core class registration/entry point: `src/register_types.cpp` (lists all `ClassDB::register_class` calls — add new engine-facing classes here).

## C# bindings

C# bindings under `project/addons/terrain_3d/csharp` are generated (not hand-written) using an external tool (CSharp-Wrapper-Generator-for-GDExtension) against a built extension; see `doc/docs/generating_csharp_bindings.md`. Regenerate after any change to the public API surface intended for C# consumers.

## Documentation

- API class reference lives in `doc/doc_classes/*.xml` — this is what contributors edit; it's the source Godot's doc-tool uses to generate RST/HTML.
- Tutorial/user docs live in `doc/docs/*.md` and must be listed in `doc/index.rst` for Readthedocs to pick them up.
- Any PR adding/changing public methods or features should update the relevant XML and/or Markdown docs.
