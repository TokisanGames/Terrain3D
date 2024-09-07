# Project Status

Terrain3D has been available and usable since the alpha was released in July, 2023. We have hundreds of users and are using it in our game, [Out of the Ashes](https://tokisan.com/out-of-the-ashes/). It is stable and just needs advanced features.

The status of various features are shown in the table below.

See the [Roadmap](https://github.com/users/TokisanGames/projects/3/views/1) for priorities. See [Contributing](contributing.rst) if you would like to help the project move faster.

| Feature | Status | 
| ------------- | ------------- | 
| **Platforms** | Terrain editing and exported games work on Windows, Linux, macOS. [Mobile and web platforms](mobile_web.md) are experimental.
| **Languages** | GDScript, C++, C# all work, as should any language Godot supports. See [Programming Languages](programming_languages.md)
| **Editing** |
| Sculpting Operations | Raise, Lower, Slope, Smooth.
| Painting Operations | Texture, Color, Wetness with Height blending.
| GPU Sculpting| [Pending](https://github.com/TokisanGames/Terrain3D/issues/174). Currently painting occurs on the CPU in C++. It's reasonably fast, but we have a soft limit of 200 on the brush size, as larger sizes lag.
| Advanced texturing| Paintable uv scale / rotation, 2-layer texture blending implemented. Pending slope painting, 3D projection, and more advanced texture blending.
| **Environment** |
| Foliage | Meshes without collision can be painted on the terrain and instanced via our Terrain3DInstancer which is a MultiMeshInstance painter. In the future, collision may be generated. Alternatively, you could create a particle shader for automatic placement.
| Object placement | Objects that shouldn't be in a MultiMeshInstance node is [out of scope](https://github.com/TokisanGames/Terrain3D/issues/47). See 3rd party tools below.
| Holes | Supported since 0.9. See [#60](https://github.com/TokisanGames/Terrain3D/issues/60#issuecomment-1817623935)
| Water | Use [WaterWays](https://github.com/Arnklit/Waterways) for rivers, or [Realistic Water Shader](https://github.com/godot-extended-libraries/godot-realistic-water/) or [Infinite Ocean](https://stayathomedev.com/tutorials/making-an-infinite-ocean-in-godot-4/) for lakes or oceans.
| Destructibility | Real-time modification is technically possible by fetching the height and control maps and directly modifying them. That's how the editor works. But most gamedevs who want destructible terrains are better served by [Zylann's Voxel Tools](https://github.com/Zylann/godot_voxel).
| Non-destructive layers | Used for things like river beds, roads or paths that follow a curve and tweak the terrain. It's [possible](https://github.com/TokisanGames/Terrain3D/issues/129) in the future, but low priority.
| **Physics** |
| Godot | Works within the regions you define in your world. No collision outside of those.
| Jolt | [Godot-Jolt](https://github.com/godot-jolt/godot-jolt) v0.6+ works as a drop-in replacement for Godot Physics. The above restriction applies.
| **Navigation Server** | Supported. See [Navigation](navigation.md)
| **Data** |
| Large terrains | Supports terrains up to 16km^2. [Collision will take up ~4-6GB RAM](https://github.com/TokisanGames/Terrain3D/issues/161), but that will be [improved](https://github.com/TokisanGames/Terrain3D/pull/278).
| Importing / Exporting | Works. See [Importing data](import_export.md)
| Double precision floats | [Supported](double_precision.md).
| **Rendering** |
| Frustum Culling | The terrain is made up of several meshes, so half can be culled if the camera is near the ground.
| Occlusion Culling | [Supported](occlusion_culling.md).
| SDFGI | Works fine.
| Lightmap baking | Not possible. There is no static mesh, nor UV2 channel to bake lightmaps on to.
| **3rd Party Tools** |
| [Scatter](https://github.com/HungryProton/scatter) | For placing objects algorithmically, with or without collision. We provide [a script](https://github.com/TokisanGames/Terrain3D/blob/main/project/addons/terrain_3d/extras/project_on_terrain3d.gd) that allows Scatter to detect our terrain. Or you can enable debug collision and use the default `Project on Colliders`.
| [AssetPlacer](https://cookiebadger.itch.io/assetplacer) | A level design tool for placing assets manually. Works on Terrain3D with placement mode set to Terrain3D or the default mode and `debug_show_collision` turned on.

