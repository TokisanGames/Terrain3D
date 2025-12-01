Foliage Instancing
====================

Terrain3D provides two types of instancing systems that can be used to render not only grass, but also rocks, trees, pinecones, debris, or anything else you want.

1. A Particle Shader allows the GPU to automatically generate meshes around the camera. We have provided an example that you can modify and extend for your own needs in `extras/particle_example`. We refer to these meshes as `particles`.

2. [Terrain3DInstancer](../api/class_terrain3dinstancer.rst) optimally renders hundreds of thousands of meshes that have been intentionally placed either by code or by hand using Godot's [MultiMesh](https://docs.godotengine.org/en/stable/classes/class_multimesh.html) class. See this link for capabilities and engine tutorials. We refer to these meshes as `instances`.

See [Procedural Placement](#procedural-placement) for a comparision between these two methods. The rest of this page is dedicated to learning how to use the instancer for manual and code placement.


**Table of Contents**
* [How To Use The Instancer](#how-to-use-the-instancer)
* [Limitations](#limitations)
* [LOD Support](#lod-support)
* [Wind and Player Interaction](#wind-and-player-interaction)
* [Procedural Placement](#procedural-placement)
* [Importing From Other Tools](#importing-from-other-tools)


## How To Use The Instancer

### 1. Open the Asset Dock Meshes

Click the `Meshes` tab in the Asset Dock.

Use the icons to en/disable, edit, or clear an asset, or use these mouse buttons:

* <kbd>LMB</kbd> - Select.
* <kbd>RMB</kbd> - Edit.
* <kbd>MMB</kbd> - Clear the asset and remove all instances.

You can only remove entries from the end of the list. You can edit any of them, change the ID to the end, and then remove it.

```{image} images/mesh_asset_dock.png
:target: ../_images/mesh_asset_dock.png
```

### 2. Set Up A Mesh Asset

Click the large plus button to add a new mesh asset. This will `Edit` the asset and display its settings in the inspector.

```{image} images/mesh_asset_inspector.png
:target: ../_images/mesh_asset_inspector.png
```

Each mesh asset can be a generated texture card or a scene file (.tscn, .scn, .glb, .fbx). 

Changing the ID will reorder the assets in the list, allowing you to place one at the end for removal. Unlike the texture list, changing IDs won't change what is dispalyed on the ground because it also changes the mesh ID in the data.

If your mesh doesn't have a material, add or customize the override material as needed. If you are using a generated texture card, add your texture file to the `albedo_texture` slot in the material and enable transparency.

The generated texture card is 1, 2, or 3 QuadMeshes, on which you can apply a 2D texture of a plant as is commonly done in older or low poly games.

See the [Terrain3DMeshAsset API](../api/class_terrain3dmeshasset.rst) for a description of the parameters.

### 3. Select The Mesh Asset

Click the desired mesh in the Asset Dock. This should also enable the foliage tool in the toolbar, but also select that if not.

### 4. Adjust Placement Options

```{image} images/instancer_options.png
:target: ../_images/instancer_options.png
```

The instancer has many options for adjusting the height, scale, rotation, and color shifts while painting. There are options for fixed adjustments and random variances. For instance, using fixed_scale to increase all instances by 200%, and using random_scale to vary each by +/- 20%.

The paintable height offset on the tool settings bar is cummulative with the mesh asset height offset in the inspector. This allows you to specify the default on the asset, and override it while painting.

Most of the options should be self explanatory.

Adjusting the vertex color requires that `vertex_color_use_as_albedo` is enabled in your material. The hue shift applies to the specified vertex color, which should have some saturation to see any effect. e.g. Hue shift on white will not be visible. Hue shift on red will be.


### 4. Paint On The Ground

Paint instances on the terrain. You can remove instances of the selected mesh by holding <kbd>Ctrl</kbd> while painting.

Press <kbd>Ctrl + Shift + LMB</kbd> to remove mesh instances of any type.

See [User Interface](user_interface.md) for additional keys.

## Limitations

There are some caveats and limitations built into the engine that you should be aware of.

### Simple Objects

Some 3D assets are complex objects with multiple, separate meshes, such as a tree trunk and leaves, a chest and lid, or a door frame and door. MultiMeshes supports only one mesh. If you give it a complex object with separate trunk and leaves, it won't work as expected.

Either combine your complex objects into one (easy to do with the Join operation in Blender, while maintaining separate materials), or use another method of placement, such as AssetPlacer, Scatter, or manual placement.

If you use a mesh with multiple materials, make sure they are connected to the Mesh resource on import into Godot, or in the MeshInstance3D override slots in the scene. We currently provide only a single material override.

### No Individual Culling

A MultiMesh renders all instances in one draw call and does not cull individual instances via frustum, occlusion, nor distance.

We mitigate this by generating multiple MultiMeshes. Each region is divided into 32x32m cells so that these MultiMeshes can be culled by frustum or occlusion. We expose visibility ranges in each mesh asset settings so they can be culled by distance as well.


### No Collision

Multimeshes are generated and rendered on the GPU. The physics engine is on the CPU, and doesn't know anything about the placed instances. For now use this only for instances where collision is unnecessary like grass.

In the future, instance collision will be generated using the collision shapes stored in your scene file. See [PR 699](https://github.com/TokisanGames/Terrain3D/pull/699).


### No Scene Transforms

Currently, the instancer uses the first Mesh resource it finds in the scene file and uses it as is. It ignores all transforms in the file, as they are not stored in the Mesh resource.

If you've built and imported your object with a non-zero transform, and have used the position, rotation, or scale in the scene file to fix your placement, then your instanced objects are going to have strange transforms. e.g. Your tree might be laying flat or be extremely large or small.

Fix your object in blender by setting the origin point in the center or the bottom of the mesh. Move the mesh origin to (0, 0, 0). Ensure the scale is appropriate to real world units. Apply your transforms, so you have neutral transforms: position (0,0,0), rotation (0,0,0), scale (1,1,1). Be cognizant of your export and import settings. In the past, exporting via Blender FBX and importing into Godot produced a scene file where the mesh was scaled 0.01 and the parent node was scaled to 100 (or the opposite?). We use GLB/GLTF and don't have this issue. Ideally the object in Blender and all nodes in your scene file in Godot have neutral transforms, and your mesh vertex positions are scaled to real world coordinates.


### No VRAM Overrun Protection

Godot currently has no protection against filling up your VRAM. You could do so if you have a simple mesh asset, say grass, with hundreds of thousands of instances on the ground, and then replace that mesh in the asset dock with a much larger mesh. That could instantly fill your VRAM. Your console will fill with Vulkan errors complaining about running out of VRAM and you'll have to force Godot to quit and restart. Your system may also crash if you have flakey drivers or hardware.

----------------------------------

## LOD Support

Meshes are often created with multiple Levels of Detail (LODs). These are separate meshes, usually combined in the same file, which are the same mesh at higher and lower vertex counts. They usually use the same material. Often assets have as the last LOD, a single quad mesh with a flat 2D billboard texture with a picture of the mesh.

There is a quirk of the LOD numbering convention to keep in mind. LOD0 is the one closest to the camera and the highest detail. LOD4 is farther away, and lower detail. Confusingly, people might refer to LOD0 as higher than LOD4, even though 4 is greater than 0. When refering to a "higher" LOD, does this mean higher detail (LOD0) or higher LOD ID (LOD4)? We prefer using the terms near/far or first/last and avoid the terms higher/lower or greater/lesser.


### Automatic LOD Generation

By default, Godot automatically generates LODs on imported meshes. Godot MultiMeshes do work with these auto generated LODs. If that is sufficient for you, ensure [last_lod](../api/class_terrain3dmeshasset.rst#class-terrain3dmeshasset-property-last-lod) and [lod0_range](../api/class_terrain3dmeshasset.rst#class-terrain3dmeshasset-property-lod0-range) are both `0` on the [Terrain3DMeshAsset](../api/class_terrain3dmeshasset.rst) and our LOD system will be disabled for this mesh. 

You may find that the generated meshes are sub par. If so, the only way to fix it is by disabling the auto LOD generation on the mesh import settings. This can be done with existing mesh instances on the ground.

If using assets with artist created lods, you should also disable LOD generation in the import settings. 

Godot also automatically generates a shadow mesh, which you may desire to disable on import and use an artist created LOD as a [shadow impostor](#shadow-performance) instead.

### Artist Created LODs

Your scene file can contain artist created LODs and we will use up to 10. Though we recommend no more than 4, as we will be generating MultiMesh3D nodes for every mesh type, every 32m square that is in use.

The recommended tree structure looks like this. Have the MeshInstance3Ds use LOD# suffixes, and be siblings on the same level somewhere below the root node:

```{image} images/mesh_asset_lod_setup.png
:target: ../_images/mesh_asset_lod_setup.png
```

Our system scans the provided scene file for _reasonable_ LOD structures.

1. It will first search for meshes that match `*LOD?`. e.g. `MyMeshInstanceLOD0`, `MyMeshInstanceLOD1`. If found, it will sort by the last digit and use the first 10.
2. Otherwise, it will find all meshes and use the first 10 in the order provided.
3. Finally, if the root node is a mesh, it will use that as `LOD0`.

After linking your scene file, you can specify the visible distance range for each LOD or use the defaults, spacing every 32m.

Instances are drawn using a 32x32m grid of MMIs, so LODs are switched a grid cell at a time, not per instance. If your LODs are fairly similar, pop-in shouldn't be terrible unlike the extreme example shown below.

```{image} images/mesh_asset_lods.jpg
:target: ../_images/mesh_asset_lods.jpg
```


### Shadow Performance

Shadow calculation is expensive, especially when rendering a tree with tens of thousands of leaves. In most cases, this detail is far more than you need, especially when rendering on a detailed terrain.

We provide two options to improve shadow calculation performance.

1. [last_shadow_lod](../api/class_terrain3dmeshasset.rst#class-terrain3dmeshasset-property-last-shadow-lod) - This setting defines the farthest LOD that will cast shadows. LODs beyond this will render without shadows. DirectionalLight3Ds also provide a shadow distance option, but you may wish to have the DL and tree shadows rendered farther out while grass shadows stop much closer.

2. [shadow_impostor](../api/class_terrain3dmeshasset.rst#class-terrain3dmeshasset-property-shadow-impostor) - We provide the option of using a shadow impostor, which uses a lower resolution mesh to calculate the shadows while rendering a higher resolution mesh. e.g. Setting this to 2 means when an instance is rendered at LOD0, it is rendered without shadows, while its LOD2 is rendered with only shadows. When LOD2 or LOD3 are visible, they use their own shadows.

Impostors are only usable if you have more than one LOD mesh. However Godot automatically generates a shadow mesh on import of your meshes. You may wish to use it, or disable it and rely on the artist created LOD.

You can see both settings applied in the picture below. Compare with the original. The meshes are 3m above the ground so we can clearly see the shadows. `last_shadow_lod = 1`, disabling shadows for LOD2 (green) and LOD3 (blue). And `shadow_impostor = 1`, making the LOD0 sphere use the LOD1 cube shadow. 

```{image} images/mesh_asset_shadow_lods.jpg
:target: ../_images/mesh_asset_shadow_lods.jpg
```

Original: 

```{image} images/mesh_asset_lods.jpg
:target: ../_images/mesh_asset_lods.jpg
```


----------------------------------

## Wind And Player Interaction

These features can be implemented by having a wind shader or player interaction (grass flattening) shader in a ShaderMaterial attached to your mesh. We don't currently provide these shaders, but you can find both online. We may provide these shaders in the future. The instancer will use whatever material you've attached to the mesh or placed in the override slot, and the MultiMesh will automatically apply it to all instances.

## Procedural Placement

Placing instances via code is possible. See the [Terrain3DInstancer API](../api/class_terrain3dinstancer.rst) for available functions. Also read this and the next section.

One thing you must consider is if it makes sense to use the MultiMesh based instancer, or if it's more efficient to use a particle shader, such as the example included in our `extras/particle_example` directory.

**MultiMesh Pros & Cons:**
* Designed for hand painting and manual control
* Can combine hand painting and API placement
* API placement is possible, but a bit tricky
* More control over placement as you can introduce more logic and code that considers many instances
* Must place, store, and load all transforms which can be cumbersome for very large or procedural worlds
* More optimal for the same number of instances on screen since Particle Shaders use MultiMeshes under the hood

**Particle Shader Pros & Cons:**
* All automatic placement, no manual control
* Less control over placement that can only consider one instance in the logic
* No data stored, so the number of instances in memory can be significantly less. For very large or procedural worlds this is much more efficient when loading and running.

Perhaps it makes sense to use both, such as particles for grass, and instances for rocks, bushes and trees. You'll need to test and determine which methods will help you achieve your goal best.


## Importing From Other Tools

You can find a sample script that will import data from SimpleGrassTextured in `project/addons/terrain_3d/extras/3rd_party/import_sgt.gd`. SGT is another MultiMesh management tool, so the only data that we need from it are the transforms. You could do something similar for other tools.

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

