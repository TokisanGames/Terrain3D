# Layer System Architecture

This document describes the non-destructive layer system architecture introduced to Terrain3D, enabling artists to apply procedural and stamp-based modifications to terrain maps without permanently altering the base data.

## Overview

The layer system enables:
- Non-destructive editing of height, control, and color maps
- Multiple layer types with different generation strategies (stamps, curves, local nodes)
- Real-time compositing with caching and dirty-tracking for performance
- Blending modes (Add, Subtract, Replace) with intensity and feather controls
- Coverage areas and alpha masks for precise control
- Layer groups for synchronized multi-region editing

## System Architecture with Layer System Changes

This diagram shows the complete Terrain3D architecture with the **new layer system components highlighted in green**. Components and connections shown in standard colors were part of the original architecture.

```mermaid
graph TD
    %% Styling
    classDef main fill:#00558C,stroke:#333,stroke-width:2px,color:#fff;
    classDef component fill:#444,stroke:#333,stroke-width:1px,color:#fff;
    classDef plugin fill:#4B0082,stroke:#333,stroke-width:1px,color:#fff;
    classDef layerNew fill:#2E7D32,stroke:#1B5E20,stroke-width:3px,color:#fff;
    classDef resource fill:#666,stroke:#333,stroke-width:1px,color:#fff;
    classDef gdscript fill:#8B4513,stroke:#333,stroke-width:1px,color:#fff;

    %% Main Nodes
    T3D[Terrain3D<br/>* Mesh generation<br/>* Collision generation<br/>* Camera snapping]:::main
    
    T3DM[Terrain3DMaterial<br/>* Saveable resource<br/>* Combines shader snippets<br/>* Exposes custom shader]:::resource
    
    T3DI[Terrain3DInstancer<br/>* Manages MMIs]:::component
    
    T3DD[Terrain3DData<br/>* Manages region data<br/>* Creates TextureArrays for maps<br/>* Layer group management]:::component
    
    T3DA[Terrain3DAssets<br/>* List of assets<br/>* Creates TextureArrays for textures]:::component

    GCM[GeoClipMap<br/>* Creates mesh components]:::component
    
    T3DR[Terrain3DRegion<br/>* Stores height, control, color maps<br/>* Layer compositing & caching<br/>* Dirty-tracking optimization]:::component
    
    GT[GeneratedTexture<br/>* Creates TextureArrays<br/>in RenderingServer]:::component

    T3DTA[Terrain3DTextureAsset<br/>* Albedo + Height tex<br/>* Normal + Rough tex<br/>* Texture settings]:::component
    
    T3DMA[Terrain3DMeshAsset<br/>* Scene File<br/>* Mesh settings]:::component

    T3DE[Terrain3DEditor<br/>* C++ editing functions<br/>* Operates on Data & Instancer<br/>* Undo, redo<br/>* Layer operations]:::component
    
    EP[EditorPlugin<br/>* GDScript EditorPlugin<br/>* Interacts w/ C++<br/>* Manages UI<br/>* Layer stack UI]:::plugin

    %% NEW Layer System Components
    T3DL[Terrain3DLayer<br/>* Base layer class<br/>* Payload + alpha mask<br/>* Blending modes<br/>* Coverage areas<br/>* Intensity & feather]:::layerNew
    
    T3DSL[Terrain3DStampLayer<br/>* Stamp-based layers<br/>* Static payload data]:::layerNew
    
    T3DCL[Terrain3DCurveLayer<br/>* Curve-based layers<br/>* Procedural generation<br/>* Width & depth control<br/>* Falloff curves]:::layerNew
    
    T3DLNL[Terrain3DLocalNodeLayer<br/>* Node-based layers<br/>* Transform support]:::layerNew
    
    StampAnchor[Terrain3DStampAnchor<br/>* GDScript helper node<br/>* Multi-region stamps<br/>* Auto-positioning<br/>* Group ID management]:::gdscript
    
    CurveAnchor[Terrain3DCurveLayerPath<br/>* GDScript Path3D node<br/>* Auto-updates from path<br/>* Multi-region curves<br/>* Profile sculpting]:::gdscript

    MapType[MapType Enum<br/>* TYPE_HEIGHT<br/>* TYPE_CONTROL<br/>* TYPE_COLOR<br/>* Centralized in terrain_3d_map.h]:::layerNew

    %% Original Connections
    T3D --> T3DM
    T3D --> T3DI
    T3D --> T3DD
    T3D --> T3DA
    T3D --> GCM

    T3DD --> GCM
    T3DD --> T3DR
    T3DD --> GT
    
    T3DA --> GT
    T3DA --> T3DTA
    T3DA --> T3DMA

    EP --> T3DE
    T3DE --> T3DD
    T3DE --> T3DI

    %% NEW Layer System Connections (highlighted with thick arrows)
    T3DR ==>|contains| T3DL
    T3DL ==>|specializes to| T3DSL
    T3DL ==>|specializes to| T3DCL
    T3DL ==>|specializes to| T3DLNL
    
    T3DE ==>|creates/modifies| T3DL
    T3DD ==>|manages groups| T3DL
    EP ==>|UI for| T3DL
    
    StampAnchor ==>|creates/updates| T3DSL
    CurveAnchor ==>|creates/updates| T3DCL
    
    T3DR ==>|composites layers| T3DM
    T3DL -.->|uses| MapType
    T3DR -.->|uses| MapType
    T3DD -.->|uses| MapType
```

**Key Changes:**
- **Terrain3DLayer hierarchy** (new): Base class with three specialized layer types
- **MapType refactoring** (new): Standalone enum in `terrain_3d_map.h` for better organization
- **Layer compositing** (new): Regions now composite base maps with layers on-demand
- **GDScript helpers** (new): StampAnchor and CurveLayerPath nodes for artist-friendly workflows
- **Layer group management** (new): Terrain3DData manages group IDs for multi-region coordination
- **Dirty-tracking optimization** (new): Incremental re-composition of modified areas

## Layer Class Hierarchy

```mermaid
classDiagram
    class Terrain3DLayer {
        <<Resource>>
        #MapType _map_type
        #Rect2i _coverage
        #Ref~Image~ _payload
        #Ref~Image~ _alpha
        #real_t _intensity
        #real_t _feather_radius
        #bool _enabled
        #bool _dirty
        #BlendMode _blend_mode
        #uint64_t _group_id
        #bool _user_editable
        +apply(Image target, real_t vertex_spacing)
        +apply_rect(Image target, real_t vertex_spacing, Rect2i rect)
        +mark_dirty()
        +needs_rebuild(real_t vertex_spacing) bool
        #_generate_payload(real_t vertex_spacing)
        #_compute_feather_weight(Vector2i pixel) real_t
    }
    
    class Terrain3DStampLayer {
        <<Resource>>
        +Inherits payload from Terrain3DLayer
    }
    
    class Terrain3DCurveLayer {
        <<Resource>>
        -PackedVector3Array _points
        -real_t _width
        -real_t _depth
        -bool _dual_groove
        -Ref~Curve~ _falloff_curve
        #_generate_payload(real_t vertex_spacing)
        -_closest_point_on_polyline(Vector2 point, ...) bool
    }
    
    class Terrain3DLocalNodeLayer {
        <<Resource>>
        -NodePath _source_path
        -Transform3D _local_transform
        #_generate_payload(real_t vertex_spacing)
    }
    
    class BlendMode {
        <<enumeration>>
        BLEND_ADD
        BLEND_SUBTRACT
        BLEND_REPLACE
    }
    
    Terrain3DLayer <|-- Terrain3DStampLayer
    Terrain3DLayer <|-- Terrain3DCurveLayer
    Terrain3DLayer <|-- Terrain3DLocalNodeLayer
    Terrain3DLayer --> BlendMode
```

## Layer Compositing System

```mermaid
classDiagram
    class Terrain3DRegion {
        -Ref~Image~ _height_map
        -Ref~Image~ _control_map
        -Ref~Image~ _color_map
        -TypedArray~Terrain3DLayer~ _height_layers
        -TypedArray~Terrain3DLayer~ _control_layers
        -TypedArray~Terrain3DLayer~ _color_layers
        -Ref~Image~ _baked_height_map
        -Ref~Image~ _baked_control_map
        -Ref~Image~ _baked_color_map
        -bool _height_layers_dirty
        -bool _control_layers_dirty
        -bool _color_layers_dirty
        -Rect2i _height_dirty_rect
        -Rect2i _control_dirty_rect
        -Rect2i _color_dirty_rect
        +get_composited_map(MapType) Ref~Image~
        +add_layer(MapType, Terrain3DLayer, int) Terrain3DLayer
        +remove_layer(MapType, int)
        +mark_layers_dirty(MapType, bool)
        +mark_layers_dirty_rect(MapType, Rect2i, bool)
        -_apply_layers_to_rect(MapType, Image, Rect2i)
    }
    
    class Terrain3DData {
        -Dictionary _regions
        -TypedArray~Vector2i~ _region_locations
        -TypedArray~Image~ _height_maps
        -TypedArray~Image~ _control_maps
        -TypedArray~Image~ _color_maps
        -uint64_t _next_layer_group_id
        +ensure_layer_group_id(Terrain3DLayer) uint64_t
        +get_layer_groups(MapType) TypedArray~Dictionary~
        +add_layer_to_coverage(MapType, Terrain3DLayer, Rect2i)
        +move_layer_coverage(Terrain3DLayer, Vector2i)
        -_allocate_layer_group_id() uint64_t
        -_ensure_layer_group_id_internal(Terrain3DLayer) uint64_t
        -_find_layer_owner(Terrain3DLayer, MapType, ...) bool
    }
    
    class Terrain3DEditor {
        -Ref~Terrain3DLayer~ _active_layer
        +set_active_layer(Terrain3DLayer)
        +get_active_layer() Terrain3DLayer
        +add_stamp_layer(Vector3, real_t, Image, Image, int)
        +add_curve_layer(PackedVector3Array, real_t, real_t, int)
        +finalize_stamp_layer(Terrain3DLayer)
        -_operate_stamp_layer(regions, layer_only)
    }
    
    Terrain3DData --> Terrain3DRegion
    Terrain3DRegion --> Terrain3DLayer
    Terrain3DEditor --> Terrain3DData
    Terrain3DEditor --> Terrain3DLayer
```

## Layer Compositing Workflow

```mermaid
sequenceDiagram
    participant Renderer as RenderingServer
    participant Data as Terrain3DData
    participant Region as Terrain3DRegion
    participant Layers as Layer Stack
    participant Cache as Baked Map Cache
    
    Note over Renderer: Needs texture update
    Renderer->>Data: update_maps()
    Data->>Region: get_composited_map(TYPE_HEIGHT)
    
    alt Cache valid (not dirty)
        Region-->>Data: Return cached baked map
    else Full rebuild needed
        Region->>Region: cache = base_map.duplicate()
        loop For each layer
            Region->>Layers: layer.apply(cache, vertex_spacing)
            Layers->>Layers: _ensure_payload(vertex_spacing)
            Layers->>Layers: Apply blend mode to cache
        end
        Region->>Cache: Store in _baked_height_map
        Region->>Region: Mark clean (_height_layers_dirty = false)
        Region-->>Data: Return baked map
    else Incremental rebuild (dirty rect)
        Region->>Region: cache.blit_rect(base_map, dirty_rect)
        Region->>Region: _apply_layers_to_rect(TYPE_HEIGHT, cache, dirty_rect)
        loop For each layer
            Layers->>Layers: layer.apply_rect(cache, vertex_spacing, dirty_rect)
        end
        Region->>Region: Mark clean (_height_layers_dirty = false)
        Region-->>Data: Return updated baked map
    end
    
    Data->>Renderer: Update TextureArray with composited map
```

## Layer Blending Algorithm

```mermaid
flowchart TD
    Start([Apply Layer to Target]) --> GetPixel[Get source pixel from payload<br/>Get destination pixel from target]
    GetPixel --> CalcAlpha[Calculate alpha_weight<br/>from alpha mask if present]
    CalcAlpha --> CalcFeather[Calculate feather_weight<br/>based on distance from edge]
    CalcFeather --> CombineWeights[mask_weight = alpha_weight × feather_weight<br/>replace_weight = min mask_weight × intensity, 1<br/>additive_weight = mask_weight × intensity]
    
    CombineWeights --> CheckBlendMode{Blend Mode?}
    
    CheckBlendMode -->|BLEND_REPLACE| Replace[dst = lerp dst, payload, replace_weight]
    CheckBlendMode -->|BLEND_ADD| Add[delta = payload × additive_weight<br/>dst += delta]
    CheckBlendMode -->|BLEND_SUBTRACT| Subtract[delta = payload × additive_weight<br/>dst -= delta]
    
    Replace --> WritePixel[Write pixel to target]
    Add --> WritePixel
    Subtract --> WritePixel
    WritePixel --> NextPixel{More pixels<br/>in coverage?}
    
    NextPixel -->|Yes| GetPixel
    NextPixel -->|No| End([Done])
```

## Layer Group System

The layer group system enables multiple regions to share the same layer instance, allowing stamps and curves to span region boundaries seamlessly.

```mermaid
graph TB
    subgraph "Terrain3DData"
        NextID[_next_layer_group_id: 1, 2, 3...]
        GroupAlloc[_allocate_layer_group_id]
    end
    
    subgraph "Region A (0, 0)"
        LayerA1[StampLayer<br/>group_id: 1<br/>coverage: 100,100 to 200,200]
        LayerA2[CurveLayer<br/>group_id: 2<br/>coverage: 50,150 to 300,180]
    end
    
    subgraph "Region B (1, 0)"
        LayerB1[StampLayer<br/>group_id: 1<br/>coverage: -156,100 to -56,200]
        LayerB2[CurveLayer<br/>group_id: 2<br/>coverage: -206,150 to 44,180]
    end
    
    subgraph "Region C (0, 1)"
        LayerC1[StampLayer<br/>group_id: 1<br/>coverage: 100,-156 to 200,-56]
    end
    
    NextID --> GroupAlloc
    GroupAlloc --> LayerA1
    GroupAlloc --> LayerB1
    GroupAlloc --> LayerC1
    GroupAlloc --> LayerA2
    GroupAlloc --> LayerB2
    
    LayerA1 -.->|Same group| LayerB1
    LayerB1 -.->|Same group| LayerC1
    LayerA2 -.->|Same group| LayerB2
    
    style LayerA1 fill:#4CAF50
    style LayerB1 fill:#4CAF50
    style LayerC1 fill:#4CAF50
    style LayerA2 fill:#2196F3
    style LayerB2 fill:#2196F3
```

## Dirty Tracking & Optimization

```mermaid
stateDiagram-v2
    [*] --> Clean: Initial state
    
    Clean --> FullDirty: Layer added/removed<br/>Base map modified<br/>Layer enabled/disabled
    Clean --> RectDirty: Layer coverage moved<br/>Layer payload updated
    
    FullDirty --> Rebuilding: get_composited_map() called
    RectDirty --> IncrementalRebuild: get_composited_map() called
    
    Rebuilding --> Clean: Full re-composite complete<br/>Cache updated
    IncrementalRebuild --> Clean: Dirty rect re-composited<br/>Cache updated
    
    note right of FullDirty
        _layers_dirty = true
        _dirty_rect_valid = false
    end note
    
    note right of RectDirty
        _layers_dirty = true
        _dirty_rect_valid = true
        _dirty_rect = affected area
    end note
    
    note right of Clean
        _layers_dirty = false
        Cache valid for rendering
    end note
```

## GDScript Helper Nodes

### Terrain3DStampAnchor Workflow

```mermaid
sequenceDiagram
    participant Scene as Scene Tree
    participant Anchor as Terrain3DStampAnchor
    participant Data as Terrain3DData
    participant Regions as Terrain3DRegion(s)
    participant Layers as Terrain3DStampLayer(s)
    
    Scene->>Anchor: _ready() / position changed
    Anchor->>Anchor: Detect overlapping regions
    
    alt No template layer set
        Anchor->>Data: Find layer at target_region[layer_index]
        Data-->>Anchor: Return template layer
        Anchor->>Anchor: Cache template properties
    end
    
    loop For each overlapping region
        Anchor->>Data: Check if layer exists for this region
        
        alt Layer doesn't exist
            Anchor->>Data: Create duplicate layer
            Data->>Regions: add_layer(TYPE_HEIGHT, new_layer)
            Regions->>Layers: Append to layer stack
        end
        
        Anchor->>Layers: Update coverage to local coordinates
        Anchor->>Layers: Set group_id (for synchronization)
        Anchor->>Layers: Mark dirty
    end
    
    Anchor->>Data: Mark regions modified
    Data->>Regions: mark_layers_dirty(TYPE_HEIGHT)
    Regions->>Regions: Invalidate cache
```

### Terrain3DCurveLayerPath Workflow

```mermaid
sequenceDiagram
    participant User as User (moves path)
    participant Path as Terrain3DCurveLayerPath
    participant Curve as Curve3D
    participant Data as Terrain3DData
    participant Regions as Terrain3DRegion(s)
    participant Layer as Terrain3DCurveLayer
    
    User->>Path: Modify path control points
    Path->>Path: _notification(TRANSFORM_CHANGED)
    Path->>Path: request_update()
    
    Path->>Curve: get_baked_points()
    Curve-->>Path: PackedVector3Array
    
    Path->>Path: Calculate affected regions
    
    loop For each affected region
        alt Layer doesn't exist for region
            Path->>Layer: Create new Terrain3DCurveLayer
            Path->>Data: add_layer(region_loc, TYPE_HEIGHT, layer)
        else Layer exists
            Path->>Layer: Get existing layer
        end
        
        Path->>Layer: set_points(local_points)
        Path->>Layer: set_width(width)
        Path->>Layer: set_depth(depth)
        Path->>Layer: set_falloff_curve(falloff_curve)
        Layer->>Layer: mark_dirty()
        Layer->>Layer: _generate_payload() on next apply()
    end
    
    Path->>Data: update_maps()
    Data->>Regions: get_composited_map(TYPE_HEIGHT)
    Regions->>Layer: apply(cache, vertex_spacing)
    Layer->>Layer: Generate procedural curve payload
    Layer->>Layer: Apply to cache with blending
```

## Data Flow: Layer Application

```mermaid
flowchart TB
    subgraph "Input"
        LayerDef[Layer Definition<br/>coverage, payload, alpha<br/>intensity, feather, blend_mode]
    end
    
    subgraph "Payload Generation"
        CheckCache{Payload<br/>cached?}
        Generate[_generate_payload<br/>Curve: Rasterize polyline<br/>Stamp: Use provided image<br/>LocalNode: Query node data]
        Store[Store in _payload]
    end
    
    subgraph "Blending"
        LoadBase[Load base map<br/>or cached composite]
        IterPixels[For each pixel in coverage]
        CalcWeights[Calculate alpha × feather weights]
        BlendPixel[Apply blend mode<br/>Add / Subtract / Replace]
        WritePixel[Write to target]
    end
    
    subgraph "Caching"
        UpdateCache[Update _baked_map cache]
        MarkClean[_layers_dirty = false]
    end
    
    subgraph "Output"
        ToRenderer[Send to RenderingServer<br/>as TextureArray]
        ToCollision[Update collision mesh]
        ToInstancer[Update instance placement]
    end
    
    LayerDef --> CheckCache
    CheckCache -->|No or dirty| Generate
    CheckCache -->|Yes| LoadBase
    Generate --> Store
    Store --> LoadBase
    
    LoadBase --> IterPixels
    IterPixels --> CalcWeights
    CalcWeights --> BlendPixel
    BlendPixel --> WritePixel
    WritePixel --> IterPixels
    
    IterPixels --> UpdateCache
    UpdateCache --> MarkClean
    
    MarkClean --> ToRenderer
    MarkClean --> ToCollision
    MarkClean --> ToInstancer
```

## MapType Refactoring

The `MapType` enum was extracted into a standalone header file for better code organization and to avoid circular dependencies.

```mermaid
graph LR
    subgraph "Before: terrain_3d_region.h"
        OldRegion[Terrain3DRegion class<br/>+ MapType enum]
    end
    
    subgraph "After: Separate Files"
        MapH[terrain_3d_map.h<br/>MapType enum<br/>Helper functions]
        NewRegion[terrain_3d_region.h<br/>Terrain3DRegion class]
        Layer[terrain_3d_layer.h<br/>Terrain3DLayer class]
        Data[terrain_3d_data.h<br/>Terrain3DData class]
    end
    
    OldRegion -.->|Refactored into| MapH
    OldRegion -.->|Refactored into| NewRegion
    
    NewRegion --> MapH
    Layer --> MapH
    Data --> MapH
    
    style MapH fill:#4CAF50
```

**terrain_3d_map.h** now provides:
```cpp
enum MapType {
    TYPE_HEIGHT,
    TYPE_CONTROL,
    TYPE_COLOR,
    TYPE_MAX,
};

inline Image::Format map_type_get_format(MapType p_type);
inline const char* map_type_get_string(MapType p_type);
inline Color map_type_get_default_color(MapType p_type);
```

## Editor Integration

```mermaid
graph TB
    subgraph "GDScript UI (ui.gd)"
        LayerStack[Layer Stack Panel<br/>List of layers per map type]
        LayerSettings[Layer Settings<br/>Intensity, feather, blend mode]
        AddLayerBtn[Add Layer Button]
    end
    
    subgraph "C++ Editor (terrain_3d_editor.cpp)"
        ActiveLayer[_active_layer<br/>Currently selected layer]
        StampOp[_operate_stamp_layer<br/>Paint to active layer]
        AddStamp[add_stamp_layer<br/>Create new stamp]
        AddCurve[add_curve_layer<br/>Create new curve]
        FinalizeStamp[finalize_stamp_layer<br/>Commit to region]
    end
    
    subgraph "Data Layer"
        RegionLayers[Region layer arrays<br/>_height_layers<br/>_control_layers<br/>_color_layers]
    end
    
    LayerStack -->|Select layer| ActiveLayer
    LayerSettings -->|Modify properties| ActiveLayer
    AddLayerBtn -->|Create stamp| AddStamp
    AddLayerBtn -->|Create curve| AddCurve
    
    ActiveLayer -->|Paint stroke| StampOp
    StampOp -->|Update payload| ActiveLayer
    
    AddStamp -->|Finalize| FinalizeStamp
    FinalizeStamp -->|Add to region| RegionLayers
```

## Key Features

### 1. Non-Destructive Editing
- Base maps remain unchanged
- Layers composite on top at render time
- Easy to enable/disable, reorder, or remove layers

### 2. Layer Types
- **Stamp Layers**: Static image data stamped onto terrain
- **Curve Layers**: Procedurally generated from path data
- **Local Node Layers**: Driven by scene node transforms

### 3. Compositing Performance
- Incremental dirty-rect updates minimize re-compositing cost
- Full-map caching for clean layers (no redundant processing)
- Per-map-type dirty tracking

### 4. Multi-Region Support
- Layers can span multiple regions via layer groups
- Group IDs synchronize layers across region boundaries
- Automatic region creation for stamps/curves that extend beyond loaded tiles

### 5. Blending Controls
- **Blend Modes**: Add, Subtract, Replace
- **Intensity**: Scales layer effect strength
- **Alpha Mask**: Per-pixel layer opacity
- **Feather**: Smooth edge falloff

### 6. Artist-Friendly Tools
- **Terrain3DStampAnchor**: Node3D-based stamp placement with auto-positioning
- **Terrain3DCurveLayerPath**: Path3D-based curve editing with live preview
- Both support auto-update in editor and at runtime

## Performance Characteristics

| Operation | Without Layers | With Layers (Clean) | With Layers (Dirty) |
|-----------|----------------|---------------------|---------------------|
| Map access | Direct Image lookup | Cached composite lookup | Re-composite + cache |
| Incremental edit | Modify base map | Update layer payload | Update layer + dirty rect |
| Render update | Upload base map | Upload cached composite | Re-composite then upload |
| Memory overhead | 3 maps × region_size² | + 3 cached composites | Same |
| Best for | Simple terrain | Complex multi-layer setups | Interactive layer editing |

## Usage Examples

### Creating a Stamp Layer (C++)
```cpp
// In Terrain3DEditor
Ref<Image> stamp_image = ...; // Load or generate
Ref<Image> alpha_mask = ...; // Optional
Vector3 world_pos = Vector3(100, 0, 100);
real_t radius = 50.0;

add_stamp_layer(world_pos, radius, stamp_image, alpha_mask, Terrain3DRegion::TYPE_HEIGHT);
// Returns a Terrain3DStampLayer that can be further edited
```

### Creating a Curve Layer (GDScript)
```gdscript
# Add Terrain3DCurveLayerPath node to scene
var curve_path = Terrain3DCurveLayerPath.new()
curve_path.terrain_path = ^"../Terrain3D"
curve_path.width = 10.0
curve_path.depth = -2.0  # Carve 2m deep
curve_path.feather_radius = 3.0
add_child(curve_path)

# Modify the path's curve property to define the road/river
curve_path.curve.add_point(Vector3(0, 5, 0))
curve_path.curve.add_point(Vector3(50, 5, 20))
curve_path.curve.add_point(Vector3(100, 8, 15))
```

### Placing a Multi-Region Stamp (GDScript)
```gdscript
# Add Terrain3DStampAnchor node to scene
var anchor = Terrain3DStampAnchor.new()
anchor.terrain_path = ^"../Terrain3D"
anchor.map_type = Terrain3DRegion.TYPE_HEIGHT
anchor.auto_create_regions = true  # Create regions as needed
add_child(anchor)

# Move the anchor - it automatically updates all affected regions
anchor.global_position = Vector3(500, 0, 500)
```

## Implementation Files

### C++ Core
- **src/terrain_3d_layer.h/cpp**: Base layer class and specializations
- **src/terrain_3d_region.h/cpp**: Layer compositing and caching logic
- **src/terrain_3d_data.h/cpp**: Layer group management
- **src/terrain_3d_editor.h/cpp**: Layer editing operations
- **src/terrain_3d_map.h**: MapType enum and utilities

### GDScript Helpers
- **project/addons/terrain_3d/src/stamp_layer_anchor.gd**: Stamp anchor node
- **project/addons/terrain_3d/src/curve_layer_path.gd**: Curve path node
- **project/addons/terrain_3d/src/ui.gd**: Layer stack UI integration

### Demo
- **project/demo/src/LayerDemo.gd**: Example layer usage