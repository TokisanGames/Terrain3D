Using Previous Engine Versions
==============================

*Editor's Note: Does anyone use this page? Ping @tokisangames on twitter or Cory in our discord if so, or it will be removed.*

In general, you want to match the compiled version of your godot-cpp folder to the engine version. As of Godot 4.1, are somewhat forward compatible, but are not backwards compatible.

Using a plugin built with an older godot-cpp version (e.g. 4.1.3) should work in future engine versions within the same minor number. (e.g. 4.1.4+). And depending on API changes, it may work with the next minor version as well (e.g. 4.2.x). 

However, a compiled plugin won't work with previous versions of the engine (eg plugin built for 4.2.2 with a 4.2.1 or 4.1.3 engine).

If you want to build the current version of Terrain3D for a previous version of the engine, it's generally possible just by changing your godot-cpp commit and rebuilding, as explained in [Building from Source](building_from_source.md). However, occasionally there are API changes required to get the plugin working in future engine versions. We attempt to document those changes here so they can be undone or worked around by you to support older an engine version, but we may miss some.

The last tagged release is the version of Terrain3D used when that version of the engine was in use, primarily for reference or testing.

**Example:** Say you wish to use the current version of Terrain3D with Godot 4.0.6. You could build the plugin with the 4.0.3 tag below using godot-cpp on 4.0.6, and make sure that works with the 4.0.6 engine. Then you'd checkout the `main` branch, and undo the commits listed for 4.2, 4.1, etc. Some of those changes might be very easily removed, such as the first from 4.0 to 4.1. Others will utilize new features of Godot that have been introduced in later versions. In those cases, you'll need to wait until Godot backports those features to your version (primary use case), or modify Terrain3D to get it working (likely very difficult).

|Version|Commits to undo|Last tagged release|
|-----|----|----|
|4.1 -> 4.2|[d74489](https://github.com/TokisanGames/Terrain3D/commit/d74489b54e219956c3509e7b86773b7b5236498f), [a34a748](https://github.com/TokisanGames/Terrain3D/commit/a34a7481434b92ef21f2ca5f52df82d43cedfc7c)|[v0.9.1](https://github.com/TokisanGames/Terrain3D/releases/tag/v0.9.1-beta)|
|4.0 -> 4.1|[da4551](https://github.com/TokisanGames/Terrain3D/commit/da455147d18674d02ba4b88bd575b58de472c617)|[v0.8](https://github.com/TokisanGames/Terrain3D/releases/tag/v0.8-alpha_gd4.0.3)|
