Foliage Instancing
====================

The [Terrain3DInstancer](../api/class_terrain3dinstancer.rst) can be used to optimally render hundreds of thousands of meshes in a single draw call. Meshes aren't limited to plants. They can be rocks, trees, pinecones, debris, or anything else.

The instancer uses Godot's [MultiMesh](https://docs.godotengine.org/en/stable/classes/class_multimesh.html) class. See this link for capabilities and engine tutorials.

**Table of Contents**
* [How To Use The Instancer](#how-to-use-the-instancer)
* [Limitations](#limitations)
* [LOD Support](#lod-support)
* [Wind and Player Interaction](#wind-player-interaction)
* [Procedural Placement](#procedural-placement)
* [Importing From Other Tools](#importing-from-other-tools)


## How To Use The Instancer

### 1. Set Up A Mesh Asset

Click the Meshes tab in the Asset Dock and add a new mesh asset.

`Left click` an asset to select. `Right click` to edit. `Middle click` to reset or delete. You can only remove the last in the list, however you can replace their contents or reorder them by changing the ID.

```{image} images/asset_dock.png
:target: ../_images/asset_dock.png
```


Right click an asset to edit it in the Inspector.

```{image} images/mesh_asset.png
:target: ../_images/mesh_asset.png
```

Each mesh asset can be a generated texture card or a scene file (.tscn, .scn, .glb, .fbx). 

Changing the ID will reorder the assets in the list, allowing you to place one at the end for removal. Unlike the texture list, changing IDs won't change what is on the ground. You can do that by inserting a new mesh into this asset slot.

If your mesh doesn't have a material attached, add or customize the override material as needed. If you are using a generated texture card, add your texture file to the albedo_texture slot in the material and enable transparency.

The generated texture card is 1, 2, or 3 QuadMeshes, on which you can apply a 2D texture of a plant as is commonly done in older or low poly games.

See the [Terrain3DMeshAsset API](../api/class_terrain3dmeshasset.rst) for a description of the parameters.

### 2. Select The Mesh Asset

Click the desired mesh in the Asset Dock. This should also enable the foliage tool in the toolbar, but select it if not.

### 3. Adjust Placement Options

```{image} images/instancer_options.png
:target: ../_images/instancer_options.png
```

The instancer has many options for adjusting the height, scale, rotation, and color shifts while painting. There are options for fixed adjustments and random variances. For instance, using fixed_scale to increase all instances by 200%, and using random_scale to vary each by +/- 20%.

The paintable height offset is cummulative with the mesh asset height offset. This allows you to specify the default on the asset, and override it while painting.

Most of the options should be self explanatory.

Adjusting the vertex color requires that `vertex_color_use_as_albedo` is enabled in your material. The hue shift applies to the specified vertex color, which should have some saturation to see any effect. e.g. Hue shift on white will not be visible. Hue shift on red will be.


### 4. Paint On The Ground

Paint instances on the terrain. You can remove instances of the selected mesh by holding <kbd>Ctrl</kbd> while painting.

Press <kbd>Ctrl + Shift + LMB</kbd> to remove mesh instances of any type.

See [User Interface](user_interface.md) for additional keys.

## Limitations

There are some caveats and limitations built into the engine that you should be aware of.

### Simple Objects

Some 3D assets are complex objects with multiple, separate meshes, such as a tree trunk and leaves, a chest and lid, or a door frame and door. MultiMeshes support only one mesh per LOD. Our system scans the provided scene file and uses the first mesh it finds for LOD0, the second mesh as LOD1, and so on up to LOD3. If you give it a complex object with separate trunk and leaves, it won't work as expected.

Either combine your complex objects into one (easy to do with the Join operation in Blender, while maintaining separate materials), or use another method of placement, such as AssetPlacer, Scatter, or manual placement.

If you use a mesh with multiple materials, make sure they are connected to the Mesh resource on import into Godot. We currently provide only a single material override.

### No Individual Culling

A MultiMesh renders all instances in one draw call and does not cull individual instances via frustum, occlusion, nor distance.

We mitigate this by generating multiple MultiMeshes. Each region is divided into smaller cells so that these smallers MultiMeshes can be culled by frustum or occlusion. We expose distance culling parameters (visibility ranges) in the asset's settings.

### No Collision

Multimeshes are generated and rendered on the GPU. The physics engine is on the CPU, and doesn't know anything about the placed instances. For now use this only for instances where collision is unnecessary like grass.

In the future, we will likely generate collision stored in your scene file. This will come as part of or after [PR#278 Dynamic Collision](https://github.com/TokisanGames/Terrain3D/pull/278).

### No Scene Transforms

Currently, the instancer uses the first Mesh resource it finds in the scene file and uses it as is. It ignores all transforms in the file, as they are not stored in the Mesh resource.

If you've built and imported your object with a non-zero transform, and have used the position, rotation, or scale in the scene file to fix your placement, then your instanced objects are going to have strange transforms. e.g. Your tree might be laying flat or be extremely large or small.

Fix your object in blender by setting the origin point in the center or the bottom of the mesh. Move the mesh origin to (0, 0, 0). Ensure the scale is appropriate to real world units. Apply your transforms, so you have neutral transforms: position (0,0,0), rotation (0,0,0), scale (1,1,1). Be cognizant of your export and import settings. In the past, exporting via Blender FBX and importing into Godot produced a scene file where the mesh was scaled 0.01 and the parent node was scaled to 100 (or the opposite?). We use GLB/GLTF and don't have this issue. Ideally the object in Blender and all nodes in your scene file in Godot have neutral transforms, and your mesh vertex positions are scaled to real world coordinates.

### No VRAM Overrun Protection

Godot currently has no protection against filling up your VRAM. You could do so if you have a simple mesh asset, say grass, with hundreds of thousands of instances on the ground, and then replace that mesh in the asset dock with a much larger mesh. That could instantly fill your VRAM. Your console will fill with Vulkan errors complaining about running out of VRAM and you'll have to force Godot to quit and restart. Your system may also crash if you have flakey drivers or hardware.

----------------------------------

## LOD Support

#### Auto LODs

MultiMeshes do work with the auto LODs generated by the import system. There are some bugs in the engine so you may find the meshes generated are sub par. If so, the only way to fix it is by disabling the auto LOD generation on that mesh in the Godot importer and reimporting. This can be done with existing mesh instances on the ground.

#### Artist Created LODs

We also provide a way to insert artist created LODs, stored as separate meshes within your scene file. We generate a multimesh for each LOD, from LOD0 up to LOD3. The visiliby range of each LOD level can be set in the instancer options. The engine will automatically switch between LOD levels based on the distance from the camera.

<figure class="video_container">
 <video width="600px" controls="true" allowfullscreen="true">
 <source src="../_static/video/lod-001-base.mp4" type="video/mp4">
 </video>
</figure>

#### Shadows LODs

When using artist created LODs, we provide various option for shadow LODs.

The `Maximum Shadow LOD` option lets you set the maximum LOD level that will cast shadows. Objects with higher LOD levels (further away) will not cast shadows. This is used to improve performance in case where shadows are not visible in the distance (blades of grass for example).

In the following video, note how the shadows disappear as we lower the `Maximum Shadow LOD` value.

<figure class="video_container">
 <video width="600px" controls="true" allowfullscreen="true">
 <source src="../_static/video/lod-002-shadow-maximum-lod.mp4" type="video/mp4">
 </video>
</figure>

The `Minimum Shadow LOD` option lets you set the minimum LOD level that will cast shadows. Objects with lower LOD levels (closer) will appear as if they are casting the shadow of this LOD level. This is used to improve performance in case where shadows don't need as much detail as the object itself.

In the following video, note how shadows are using the (simpler) cube mesh for LODs 0 and 1 when we set the `Minimum Shadow LOD` to 2.

<figure class="video_container">
 <video width="600px" controls="true" allowfullscreen="true">
 <source src="../_static/video/lod-003-shadow-minimum-lod.mp4" type="video/mp4">
 </video>
</figure>

Be wary of double checking your LODs configuration in the editor, as we don't validate nonsensical settings for now (e.g. LOD0 range is greater than LOD1 range, or `Maximum Shadow LOD` is less than `Minimum Shadow LOD`). In the future we may provide warning once [Configuration Warnings for Resources](https://github.com/godotengine/godot/pull/90049) makes its way into the engine.

----------------------------------

## Wind, Player Interaction

These features can be implemented by having a wind shader or player interaction (grass flattening) shader in a ShaderMaterial attached to your mesh. We don't currently provide these shaders, but you can find both online. We may provide these shaders in the future. The instancer will use whatever material you've attached to the mesh or placed in the override slot, and the MultiMesh will automatically apply it to all instances.

## Procedural Placement

Placing instances via code is possible, but the API is a bit immature. See the [Terrain3DInstancer API](../api/class_terrain3dinstancer.rst).

One thing you must consider is if it makes sense to use this MultiMesh based instancer, or if it's more efficient to use a (self-implemented) particle shader.

**MultiMesh Pros & Cons:**
* Designed for hand painting and manual control
* API placement is possible, but a bit tricky
* Must manually paint, store, and load all transforms which is cumbersome for very large or procedural worlds
* More optimal for the same number of instances on screen since Particle Shaders use MultiMeshes under the hood.

**Particle Shader Pros & Cons:**
* All automatic placement, no manual control
* No data stored, so the number of instances in memory can be significantly less. For very large or procedural worlds this is much more efficient when loading and running.

## Importing From Other Tools

You can find a sample script that will import data from SimpleGrassTextured in `project/addons/terrain_3d/extras/import_sgt.gd`. SGT is another MultiMesh management tool, so the only data that we need from it are the transforms.

**To use it:**
1. Setup the mesh asset you wish to use in the asset dock.
1. Select your Terrain3D node.
1. In the inspector, click Script (very bottom) and Quick Load `import_sgt.gd`.
1. At the very top, assign your SimpleGrassTextured node.
1. Input the desired mesh asset ID.
1. Click import. The output window and console will report when finished.
1. Clear the script from your Terrain3D node, and save your scene. 

The instance transforms are now stored in your region files.

This script also serves as an example to learn how to use the API for procedural placement. Though this script uses add_multimesh(), you could manually iterate through the SGT multimesh, pull out the transforms, modify them, then send them to the instancer with add_transforms().

