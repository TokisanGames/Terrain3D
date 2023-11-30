Storage Format Changelog
==========================
The format version is found as [Terrain3DStorage.version](../api/class_terrain3dstorage.rst#class-terrain3dstorage-property-version) and visible in the inspector under `Storage/Version`.
* 0.842 - Control map changed from FORMAT_RGB to 32-bit packed integer (encoded in FORMAT_RF) [#234](https://github.com/TokisanGames/Terrain3D/pull/234/)
* 0.841 - Colormap painted/stored as srgb and converted to linear in the shader (prev painted/stored as linear). [64dc3e4](https://github.com/TokisanGames/Terrain3D/commit/64dc3e4b5e71c11ac3f2cd4fedf9aeb7d235f45c)
* 0.84 - Separated material processing from Storage as a `Terrain3DMaterial` resource. [#224](https://github.com/TokisanGames/Terrain3D/pull/224/)
* 0.83 - Separated Surfaces (textures) from Storage as a `Terrain3DTextureList` resource. [#188](https://github.com/TokisanGames/Terrain3D/pull/188/)
* 0.8 - Initial version