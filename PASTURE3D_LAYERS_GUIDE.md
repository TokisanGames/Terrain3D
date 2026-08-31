# Pasture3D Height-Map Layers — Architecture & Implementation Guide

> Goal: Add **non-destructive height-map layers** to Pasture3D. In the editor a
> terrain is authored as a *stack* of layers (a base plus any number of additive /
> override layers, each only as large as the pixels it actually touches, Krita-style).
> Sculpt tools and tool-API nodes (the **RoadPastureConnector** and friends) target a
> chosen layer. On scene save the stack is **flattened** into the existing
> `pasture3d_*.res` region maps that ship in-game, so there is **zero runtime cost** —
> layers are an editor-only authoring construct.

This guide surveys how other terrain systems and raster editors architect layers,
picks an architecture that fits Pasture3D's existing data model, and lays out an
incremental implementation plan with concrete C++ data structures and APIs.

---

## 1. What Pasture3D already is (and why it's 80 % of the way there)

The single most important fact for this design: **Pasture3D's data store is already a
sparse, tiled, copy-friendly image store** — essentially the same shape as Krita's
tile manager, just at a coarser granularity.

From `src/pasture_3d_data.h` / `pasture_3d_region.h`:

| Concept | Pasture3D today | Equivalent in a raster editor |
|---|---|---|
| World is divided into fixed tiles | `Pasture3DRegion`, default `SIZE_256` (256×256) | Krita 64×64 tiles |
| Sparse storage | `_regions : Dict[Vector2i → Pasture3DRegion]` — only allocated where data exists | tile hash map; absent tile = empty |
| Per-tile pixel data | `_height_map` (`FORMAT_RF`), `_control_map` (`RF`), `_color_map` (`RGBA8`) | per-tile channel planes |
| Stable address | `region_location : Vector2i` | tile coordinate |
| GPU upload | Images → `GeneratedTexture` TextureArrays (`_generated_height_maps` …) | composited surface → screen |
| Per-pixel write | `set_pixel(map_type, global_pos, color)` → region → `img_pos` | `Tile::setPixel` |
| Recompose to GPU | `update_maps(map_type, …)` | layer-stack recomposite |
| Persistence | one `pasture3d_<loc>.res` per region (`save_region`/`load_region`) | layered file on disk |
| Editing | `Pasture3DEditor` brush ops on the active region's images | brush on active layer |

So the height map you see today **is already the composited result of exactly one
(implicit) layer**. The job is to insert a stack *above* the storage layer: keep an
editor-side set of layers, composite them down into the same `Pasture3DRegion` images
that already drive the shader and collision, and persist the stack alongside the baked
regions.

Key code touch-points the design must respect:

- `Pasture3DData::set_pixel` / `get_pixel` — the per-vertex write path. Sculpt, the road
  connector, and import all funnel through `set_height`→`set_pixel`.
- `Pasture3DData::update_maps` — rebuilds the GPU TextureArrays from the region images;
  already supports "all regions" vs "only `is_edited()` regions".
- `Pasture3DData::save_directory` / `save_region` / `load_directory` — per-region `.res`
  I/O and the legacy-migration pattern (great template for adding a parallel layer file).
- `Pasture3DEditor::_operate_map` + undo (`_original_regions`, `backup_region`, `_store_undo`)
  — sculpt strokes and their undo snapshots.
- `RoadPastureConnector` — calls `terrain.data.set_height(...)` / `set_control_hole(...)`
  then `terrain.data.update_maps(...)`. Today it writes **destructively** into the base
  height map; layers fix this.

---

## 2. Prior-art survey

### 2.1 Unreal Engine — Landscape **Edit Layers** (the closest analogue)

Unreal's Landscape Edit Layers are the reference design for *non-destructive height
layers in a game terrain*:

- A landscape owns an **ordered stack of edit layers**. Sculpting and painting always
  target the **currently-active layer**; nothing is ever written directly to the final
  heightmap.
- Each layer stores a **per-component delta** — sparse, only where that layer was
  touched — not a full-resolution copy of the whole landscape.
- Each layer has an **alpha/weight**. A heightmap layer blends as an **additive** delta
  onto the layers below; a *negative* alpha subtracts. Layers can be hidden/locked.
- **Reserved / procedural layers**: e.g. a *Splines* layer that the spline tool renders
  into automatically, and *Patch*/*Brush* layers fed by procedural sources. The user's
  base sculpt stays untouched underneath while the spline layer re-renders on demand.
- At cook/runtime the stack is **collapsed (flattened) into a single heightmap** — the
  layers are an editor authoring structure with no runtime presence.

The lesson: *active-layer routing + sparse additive deltas + reserved layers driven by
tools + flatten-on-cook* is precisely the shape Pasture3D wants, and it maps cleanly onto
the road-connector use case (the connector owns a reserved layer).

### 2.2 Krita / Photoshop / GIMP — raster layer stacks

- **Tile-based, copy-on-write storage** (Krita: 64×64 tiles; GIMP similar). A layer
  allocates a tile only when a pixel in that tile is written; untouched tiles cost
  nothing and can be swapped/discarded. This is the "*only as large as it needs to be*"
  behaviour the user asked for.
- Each layer tracks a **bounds/extent** smaller than the canvas, an **opacity**, a
  **blend mode**, and **visibility/lock** flags.
- Compositing walks the stack **bottom-to-top**, blending each visible layer's covered
  pixels over the accumulator by its mode and opacity. Absent tiles are skipped.
- **Coverage matters**: a paint layer needs to know *which* pixels it actually owns
  (alpha), distinct from "owns a black pixel". Heightmaps have no natural alpha channel,
  so we must carry coverage explicitly (see §4.3).

### 2.3 Others, briefly

- **Unity Terrain** — "Terrain Layers" are *texture/splat* layers only; the heightmap is a
  single array. Layered heightmap authoring there is left to third-party tools (stamping,
  MicroSplat). Confirms that *texture layering ≠ height layering* — Pasture3D can lead here.
- **World Machine / Gaea** — node graphs rather than a paint stack, but the *combiner*
  nodes (Add/Max/Mask/Chooser) are exactly the blend modes a height stack needs, and they
  reinforce **Max/Min** as first-class height operators (stamp a hill = Max; carve a
  canyon = Min).

### 2.4 Principles distilled

1. **Non-destructive**: edits go to a layer, never the base. (UE)
2. **Sparse**: a layer stores only the tiles it touches. (Krita)
3. **Explicit coverage**: height needs a weight/alpha channel to blend correctly. (Krita)
4. **Height-appropriate blend modes**: Replace, Additive (signed), Max, Min. (UE + World Machine)
5. **Tool-owned layers**: generators (roads) render into their own reserved layer and can
   re-render it without disturbing hand-sculpting. (UE Splines layer)
6. **Flatten for runtime**: the shipped data is a single composited heightmap; the stack is
   editor-only. (UE cook)

---

## 3. Chosen architecture for Pasture3D

### 3.1 Two-tier model

```
EDITOR SOURCE OF TRUTH            COMPOSITED / RUNTIME
─────────────────────            ────────────────────
Pasture3DLayerStack              Pasture3DRegion images          GPU + collision
  ├─ Layer 0 "Base"  (dense) ─┐  (_height_map / _control_map)        │
  ├─ Layer 1 "Roads" (sparse)─┼─► composite(dirty area) ──► update_maps ──► shader
  ├─ Layer 2 "Detail"(sparse)─┘        ▲                                    │
  └─ …                                 │ live recomposite on every edit     ▼
                                                                       collision
  saved as pasture3d_layers*.res   saved as pasture3d_<loc>.res (UNCHANGED, ships in game)
```

- The **`Pasture3DRegion` images stay exactly what they are today**: the *composited
  result*. The shader, collision, `get_height`, and the runtime `.res` files are all
  unchanged. A build with no layer files behaves identically to today.
- The **layer stack** is a new editor-side resource. Every edit writes to a layer, then we
  **recomposite only the affected region(s)** back into the region images and call
  `update_maps` on them — so the viewport is always live, just as now.
- **Save** does two things: (a) write the layer stack (`pasture3d_layers*.res`) as the
  editing source, and (b) write the already-composited region images as `pasture3d_<loc>.res`
  (today's path). Shipping the game needs only the latter.

This gives Unreal-style non-destructiveness with **no runtime/VRAM cost** and a trivial
migration story.

### 3.2 Base layer is dense; everything above is sparse

Mirroring a raster editor's opaque background + transparent layers:

- **Layer 0 "Base"** — dense, region-granularity, `Replace` mode, opacity 1, full coverage.
  It *is* the absolute terrain. Migrating an existing terrain = adopt its current region
  height maps as the Base layer (see §7.3). Memory ≈ today.
- **Layers 1..n** — **sparse**, sub-region tiled (§4.2), additive/override. These are where
  "only as large as it needs to be" pays off: a road that crosses a 256² region in a 6 m
  strip allocates a handful of 64² tiles (~tens of KB), not a 256 KB region image.

### 3.3 Why this fits Pasture3D specifically

- Reuses the region/`region_map`/`update_maps`/save-load machinery; the composite target
  already exists.
- The runtime path is untouched → no perf risk, no shader changes, no `.res` format break.
- Sparse sub-region tiles give Krita memory behaviour exactly where it matters (thin
  generated features like roads, rivers, paths).
- Tool-API nodes get a clean "draw into *my* layer" contract, making them idempotent.

---

## 4. Data structures (new C++ classes)

Naming follows the existing `Pasture3D*` / `src/pasture_3d_*.{h,cpp}` convention.

### 4.1 Blend modes & layer metadata

```cpp
// pasture_3d_layer.h
class Pasture3DLayer : public Resource {
    GDCLASS(Pasture3DLayer, Resource);
public:
    enum BlendMode {
        REPLACE,   // result = lerp(below, value, weight*opacity)   (absolute authoring / Base)
        ADD,       // result = below + value * weight * opacity      (signed deltas; roads, detail)
        MAX,       // result = max(below, lerp(below, value, w*op))  (stamp hills, raise-only)
        MIN,       // result = min(below, lerp(below, value, w*op))  (carve, lower-only)
        BLEND_MAX,
    };

private:
    // Metadata (saved)
    String _name = "Layer";
    BlendMode _blend = ADD;
    real_t _opacity = 1.f;
    bool _visible = true;
    bool _locked  = false;
    bool _reserved = false;     // owned by a tool/node; user edits disabled (see §6)
    String _owner_id;           // optional: node path / generator id that owns it

    // Pixel data (saved). Sparse, sub-region tiles. See §4.2/4.3.
    //   _tiles[region_location][tile_coord] -> Ref<Image>(FORMAT_RGF: R=value, G=weight)
    Dictionary _tiles;          // Dict[Vector2i region_loc] -> Dict[Vector2i tile_coord] -> Image
    int _tile_size = 64;        // sub-region tile edge in vertices (power of two, <= region_size)
public:
    // value/weight access, allocating tiles on demand
    void   set_sample(const Vector2i &p_region_loc, const Point2i &p_px, real_t v, real_t w = 1.f);
    real_t get_value (const Vector2i &p_region_loc, const Point2i &p_px) const; // NAN if uncovered
    real_t get_weight(const Vector2i &p_region_loc, const Point2i &p_px) const; // 0 if uncovered
    Ref<Image> get_tile(const Vector2i &region_loc, const Vector2i &tile_coord) const;
    void clear_region(const Vector2i &p_region_loc);   // used by tools to re-render
    Rect2i covered_region_bounds() const;
    // … metadata getters/setters, _bind_methods …
};

// pasture_3d_layer_stack.h
class Pasture3DLayerStack : public Resource {
    GDCLASS(Pasture3DLayerStack, Resource);
    TypedArray<Pasture3DLayer> _layers;  // index 0 = Base (bottom), saved in order
    int _active_layer = 0;               // editor target (not saved, or saved as a hint)
public:
    int  add_layer(const String &name, Pasture3DLayer::BlendMode mode);
    void remove_layer(int idx);
    void move_layer(int from, int to);
    int  find_layer_by_owner(const String &owner_id) const; // for tool-API
    Pasture3DLayer *get_layer(int idx) const;
    int  get_active_layer() const { return _active_layer; }
    void set_active_layer(int idx) { _active_layer = idx; }
    // …
};
```

`MapType` reuse: a layer's value image is one map type at a time. v1 ships **height layers
only** (`TYPE_HEIGHT`). The same structure generalises to `TYPE_CONTROL` (holes / texture)
and `TYPE_COLOR` later — store a `MapType _map_type` on the layer and pick the image format
from the existing `FORMAT[]` table, with weight in a parallel channel.

### 4.2 Sparse sub-region tiling

A layer keeps a **two-level sparse map**: `region_location → (tile_coord → Image)`.

- Outer key reuses the engine's existing region grid so coordinate math, `region_map`, and
  per-region saving all line up with `Pasture3DData`.
- Inner key is a sub-region tile of `_tile_size` (default 64; region default 256 ⇒ 4×4
  tiles per region). A tile is allocated lazily on first write and freed when fully cleared.
- Going coarser is allowed: `_tile_size == region_size` degrades to region-granularity
  sparsity (simpler, more memory). This makes the tile size a single tunable knob — start
  the implementation at `_tile_size = region_size` (trivial, reuses region images verbatim)
  and add sub-tiling as a drop-in optimization once compositing works.

### 4.3 Coverage / weight channel

Height has no alpha, so each layer sample is **(value, weight)**:

- Store tiles as **`FORMAT_RGF`** (two 32-bit floats): `R = value`, `G = weight ∈ [0,1]`.
  (Alternatively a parallel `R8`/`RF` mask image per tile — RGF keeps it to one image and
  blits atomically.)
- `weight == 0` ⇒ pixel not owned by this layer ⇒ skipped in compositing.
- Brush strokes accumulate weight like the existing brush alpha; the road connector writes
  `weight = 1` inside the road, feathering to 0 across `edge_falloff`.
- **⚠ Coverage vs. NaN (Phase 3 finding).** `get_weight()` is the authoritative "is this pixel
  owned?" signal — *not* a NaN `get_value()`. `get_value()` returns NaN **only when no tile exists**
  at that coordinate. With the current `_tile_size == region_size` default, the *first* `set_sample`
  in a region allocates the one region-sized tile, so every other pixel in that region is now
  "allocated but uncovered": `get_weight == 0` and `get_value == 0` (the zero fill), **never NaN**.
  Compositing already does the right thing (it tests `weight == 0` first and skips). Phase 4 code and
  tests must gate coverage on `weight`, not on `isnan(value)`. Sub-region tiling (phase 6) makes NaN
  meaningful again for *whole absent tiles*, but within an allocated tile weight is always the signal.
- The **Base layer** can skip the weight channel (always-covered) and stay a plain `RF`
  region image == today's `_height_map`, to avoid doubling Base memory. (Phase 1/2 alias the
  Base tile directly onto the region image. This is correct for load + a single flatten but
  must be un-aliased before live re-compositing — see the ⚠ note in §5.1.)

---

## 5. Compositing pipeline

### 5.1 Algorithm (per affected region, dirty-scoped)

```
for each pixel p in dirty_rect of region R:
    acc = NAN                                  # or read existing if partial
    for layer L in stack (bottom→top):
        if not L.visible: continue
        (v, w) = L.sample(R, p)                # Base: w=1, v=height
        if w == 0: continue
        a = w * L.opacity
        switch L.blend:
            REPLACE: acc = isnan(acc) ? v : lerp(acc, v, a)
            ADD:     acc = (isnan(acc)?0:acc) + v * a
            MAX:     acc = max(acc, lerp(acc, v, a))
            MIN:     acc = min(acc, lerp(acc, v, a))
    R._height_map.set_pixel(p, acc)            # writes the composited region image
R.set_edited(true)
data.update_maps(TYPE_HEIGHT, /*all_regions=*/false)  # only edited regions go to GPU
```

- **Dirty-scoped**: only recomposite the region rect an edit touched. Reuse the editor's
  existing `add_edited_area` / `_modified_area` and the `is_edited()` fast path in
  `update_maps` — this is already how strokes update the GPU today.
- **Holes / control**: control is a packed `uint32`, not blendable as a float. For v1 keep
  holes on the Base/composited control map (road connector's `set_control_hole` path
  unchanged). When control layers arrive, composite control by **topmost-covered-wins**
  (no arithmetic blend) rather than lerp.
- **NaN**: NaN already means "hole" in `get_height`. Compositing must treat an
  all-uncovered pixel as "fall through to Base"; Base is always covered so the accumulator
  is defined wherever the terrain exists.

> **⚠ Implementation note — Base-layer aliasing (Phase 2 finding).**
> `_synthesize_base_layer` makes the dense Base layer **alias** each region's `_height_map`
> (FORMAT_RF, zero-copy, §4.3), and `composite_region` writes its result back into that *same*
> image. Per pixel this is safe: the Base value is read into the accumulator *before* the
> composited value is written, and pixels are independent — so a **single composite pass is
> correct**, and the Base-only case is byte-identical (verified by `test_layer_compositing`).
>
> It is **not safe to re-composite the same region repeatedly** once `ADD`/`MAX`/`MIN` layers
> exist: the second pass would read an *already-composited* Base and re-accumulate the deltas
> (e.g. an `ADD` layer would apply twice). v1 ships with Base aliased on purpose (the memory
> win, and identity correctness for load + a single flatten). **Before Phase 4's live
> per-stroke re-compositing lands, the Base layer must own its own source image** so the
> composite *target* (`region->_height_map`) and the Base *source* are distinct buffers.
> Options: un-alias the Base (deep-copy its tile) the first time a non-Base layer is added, or
> always give Base its own buffer and treat the region image purely as the composite output.
> A REPLACE-only stack stays safe under aliasing because REPLACE overwrites rather than
> accumulates, but don't rely on that — the un-alias fix is the clean solution.

### 5.2 When compositing runs

- **On every sculpt stroke / tool write** — incrementally, dirty-scoped, for live preview.
- **On layer property change** (visibility, opacity, blend, reorder) — recomposite the
  union of that layer's covered regions.
- **On save** — guaranteed full pass is unnecessary if live compositing is correct; just
  persist. (Offer an explicit "Rebake all" action for safety / after format upgrades.)

---

## 6. Editor UX & sculpt routing

- **Layers panel** (new dock or a section of the Pasture3D tool panel): list with
  drag-reorder, add/remove/duplicate/clear, and per-row visibility, lock, opacity slider, blend
  dropdown. Active layer is highlighted.
- **Clear** wipes the active layer's tiles but keeps the layer (name, blend, `owner_id`,
  reserved flag — so a tool's binding survives), then asks the tools still bound to it to
  re-bake. That combination is the point on a **tool layer**: the layer accumulates the
  footprint of every tool that ever baked into it, so a brush that was deleted, moved to
  another layer or reassigned leaves a contribution nothing will ever clear (what the row's
  "orphan" badge flags). Clear rebuilds the layer from the tools that actually exist.
  Disabled on the Base, which while single-layer *aliases* the region height maps (§5.1).
- **Undo/redo across the toolbar.** Every toolbar action is undoable, on the terrain's scene-local
  history, but by one of two mechanisms depending on what the action actually mutates:
  - *Add / Duplicate / Remove* only rearrange **which layer objects the stack holds**, leaving the
    objects untouched. So they snapshot the layer array (plus the active index) either side of the
    operation and make both directions a restore of one of those snapshots. The snapshot shares the
    layer objects by reference, so it stays cheap however much is painted into them — and a removed
    layer stays alive purely because the snapshot array still references it, which makes undoing a
    Remove exact rather than a reconstruction. `get_layers()` returns the live array, so the
    snapshot must `duplicate()` it or it tracks the very mutation it is meant to reverse.
  - *Clear* mutates a layer's tiles **in place**, which a shared-object snapshot cannot capture, so
    it deep-copies the tiles instead. The restore copies on the way in too: the one snapshot is
    replayed on every undo, so a layer left aliasing it would have the next bake quietly rewrite the
    undo entry. It earns the extra cost because a tool layer can rebuild itself from its brushes but
    hand-painted tiles have no other source.
  - *Reorder* (buttons and drag) is its own inverse — `move(from→to)` undone by `move(to→from)` —
    so it needs neither.
  - *Row controls* (rename, visibility, lock, opacity, blend) edit one property of one layer, so the
    old→new pair is the entire state and there is nothing to snapshot. The handler applies the change
    live and the action is committed with `commit_action(false)`: re-running the "do" at commit time
    would repeat the recomposite and, for the opacity slider, rebuild the row mid-drag. The slider
    uses `MERGE_ENDS`, which keeps the *first* action's undo (the pre-drag value) and the *last*
    action's do, collapsing a drag into one entry; its action name carries the layer name so a drag
    on a different layer can't merge into the previous layer's entry.
- **Layer name field.** The name is a read-only `LineEdit` until you ask to rename it: single click
  selects the row, **double-click or F2** starts the rename, Enter or clicking away commits, Escape
  abandons it — matching how nodes are renamed in the Scene dock. It reads as a label (`flat`) until
  edited. This also fixes a longstanding bug where the field could not be clicked into at all:
  selecting a row used to call the full `refresh()`, which freed the very `LineEdit` under the
  cursor, so a caret could never land in it. Selecting now only repaints the highlight
  (`_sync_active_state`), leaving the rows alive.
- **`Pasture3DData::layers_changed`** keeps the dock live. It fires on `layer_add` /
  `_duplicate` / `_remove` / `_move` and on `create_owned_layer(_typed)` **when it actually
  creates** (never on the idempotent by-owner hit, which every tool bake goes through). Without
  it the dock only rebuilt on re-selection, so a layer made by a tool node — a brush's "Add New
  Layer", a road connector, the Sim — did not appear until the user clicked away and back.
- **Active-layer routing**: `Pasture3DEditor::_operate_map` currently writes via
  `data.set_pixel`. Change it to write into `stack.get_active_layer()` (allocating tiles),
  then recomposite the stroke's dirty rect. If the active layer is **locked** or
  **reserved**, block the stroke and flash a warning (UE behaviour).
- **Per-tool default layer**: optionally remember a preferred layer per `Tool` so switching
  to Sculpt selects the user's sculpt layer automatically.
- **Undo/redo**: today the editor snapshots whole `Pasture3DRegion`s
  (`_original_regions`/`backup_region`). Extend to snapshot the **active layer's touched
  tiles** before a stroke (cheap — they're small and sparse) plus the recomposited region
  images, so undo restores both source and composite. Keep using `EditorUndoRedoManager`.

---

## 7. Persistence & migration

### 7.1 File layout

Reuse the per-region directory convention so layers stream and diff like regions do:

| File | Contents | Ships in game? |
|---|---|---|
| `pasture3d_<loc>.res` | composited `Pasture3DRegion` (height/control/color) — **today's format, unchanged** | **Yes** |
| `pasture3d_layers.res` | `Pasture3DLayerStack` manifest: ordered layer metadata (name, blend, opacity, flags, owner_id), `_tile_size`, format version | No |
| `pasture3d_layers_<loc>.res` | per-region slice: each layer's sparse tiles that fall in `<loc>` | No |

- The manifest holds global order/metadata; per-region files hold the pixels, so large
  worlds stay sparse and a region's layer data loads with its region. (For a v1 prototype
  you may embed everything in a single `pasture3d_layers.res` — a `Dict[region_loc →
  Dict[layer_idx → tiles]]` — and split per-region later. Decide based on world size; see §11.)
- Add a `_version` to the stack resource exactly like `Pasture3DRegion::_version` so future
  format bumps upgrade gracefully.

### 7.2 Save flow (`save_directory` extension)

```
save_directory(dir):
    composite_all_dirty()                 # ensure region images are current
    for loc in _regions: save_region(...) # UNCHANGED → pasture3d_<loc>.res (runtime)
    if has_layer_stack:
        save layer manifest  → dir/pasture3d_layers.res
        for loc: save tiles  → dir/pasture3d_layers_<loc>.res
```

A game build simply ships the `pasture3d_<loc>.res` files and omits the `*_layers*` files —
nothing to strip, no runtime branch.

### 7.3 Loading & migrating existing terrains

```
load_directory(dir):
    load pasture3d_<loc>.res            # as today → composited region images
    if pasture3d_layers.res exists:
        load stack + per-region tiles
    else:
        synthesize a single dense "Base" layer that references the loaded region
        height maps (no pixel copy needed if Base aliases the region image)
```

So **every existing terrain opens as a one-layer stack** with no conversion step, and only
gains extra layers when the user/tools add them. This matches the legacy-`terrain3d`
migration philosophy already in `load_directory`.

---

## 8. Tool API — nodes that draw into a layer

This is the feature that makes the **RoadPastureConnector** non-destructive and is the main
reason to build layers.

### 8.1 Contract

A generator node **owns a reserved layer** identified by a stable `owner_id` (e.g. the
node's scene-unique name). On each refresh it:

1. resolves/creates its layer: `int lyr = stack.find_or_create_layer(owner_id, ADD)`;
2. **clears its layer in the affected regions** (`layer.clear_region(loc)`), so stale road
   geometry from a previous pose vanishes — no manual undo of old edits;
3. writes its samples into that layer instead of the base;
4. triggers a dirty-scoped recomposite.

Because the node only ever touches *its own* layer, hand-sculpting underneath is preserved,
and re-running the road tool is **idempotent**.

### 8.2 Proposed `Pasture3DData` additions

```cpp
// Layer-targeted writes (mirror existing absolute-write helpers)
void   set_height_on_layer(int layer_id, const Vector3 &pos, real_t height, real_t weight = 1.f);
void   add_height_on_layer (int layer_id, const Vector3 &pos, real_t delta,  real_t weight = 1.f);
real_t get_layer_height(int layer_id, const Vector3 &pos) const;

// Stack management surfaced for tools
int  get_layer_stack_size() const;
int  find_layer_by_owner(const String &owner_id) const;
int  create_owned_layer(const String &owner_id, const String &name, int blend_mode);
void clear_layer_in_area(int layer_id, const AABB &area);
void set_active_layer(int layer_id);
int  get_active_layer() const;
```

These bind in `_bind_methods` so GDScript nodes can call them, exactly like the connector
already calls `set_height` / `set_control_hole` / `update_maps`.

### 8.3 RoadPastureConnector changes (illustrative)

```gdscript
@export var target_layer_name := "Roads"      # new export
var _layer_id := -1

func _ensure_layer() -> void:
    var owner := str(get_path())              # stable owner id
    _layer_id = terrain.data.find_layer_by_owner(owner)
    if _layer_id < 0:
        # ADD so the road can sink terrain by `offset` as a signed delta,
        # or REPLACE if you prefer absolute road heights. (see §3.1 blend modes)
        _layer_id = terrain.data.create_owned_layer(owner, target_layer_name,
                        Pasture3DLayer.BlendMode.REPLACE)

func refresh_roads(mesh_parents: Array) -> void:
    _ensure_layer()
    terrain.data.clear_layer_in_area(_layer_id, _affected_aabb(mesh_parents)) # drop old road
    # … existing geometry loop, but replace:
    #     terrain.data.set_height(terrain_pos, road_y)
    #   with:
    terrain.data.set_height_on_layer(_layer_id, terrain_pos, road_y, weight)  # weight feathers falloff
    terrain.data.update_maps(PASTURE_3D_MAPTYPE_HEIGHT)
```

Notes:
- `weight` lets the connector express its `edge_falloff` as coverage (1 on the road, easing
  to 0), so the composite naturally feathers into whatever is underneath — removing the
  current `get_height`→`_lerp_smoothed_height` read-modify-write against the base.
- Hole carving (`set_control_hole`) stays on the composited control map for v1; promote it
  to a control layer when control layering lands.
- Backward-compat: if no stack exists (layers feature disabled), `set_height_on_layer`
  falls back to `set_height` so the connector keeps working on plain terrains.

---

## 9. Performance & memory

- **Memory**: a 64² RGF tile = 64·64·8 B = **32 KB**. A 256² region RF image = 256 KB. A
  road across one region in a 64-wide tile band touches ~4–8 tiles ≈ 128–256 KB per region
  *only on layers that road touches* — vs. a full extra 256 KB region image per layer at
  region granularity. Sub-tiling matters most for many thin generated layers.
- **Compositing cost** scales with `dirty_pixels × visible_layers_covering_them`. Strokes
  are tiny; layer-property changes recomposite a layer's bounds. Keep the bottom-up loop
  branch-light (precompute the list of layers covering a region).
- **Threading**: compositing is per-region and embarrassingly parallel; it can reuse
  whatever threading `update_maps` already tolerates. Start single-threaded, measure.
- **GPU**: unchanged — only the final composited region images upload, exactly as now.

---

## 10. Implementation phases

Each phase is independently testable and leaves `main` shippable.

1. ✅ **Core classes, no UX.** `Pasture3DLayer` (start with `_tile_size = region_size`, RGF
   tiles), `Pasture3DLayerStack`, bound to GDScript. `Pasture3DData` holds an optional
   stack; `load_directory` synthesizes the Base layer. No behaviour change yet. **(Done.)**
2. ✅ **Compositing.** Implement `composite_region(loc, dirty_rect)` + REPLACE/ADD/MAX/MIN.
   Wire `update_maps` to read composited images. Unit-test: Base-only composite == identity
   with today's output. **(Done — see `composite_region`/`composite_regions` in
   `pasture_3d_data.cpp` and `test_layer_compositing` in `unit_testing.cpp`; surfaced the
   Base-aliasing caveat in §5.1.)**
3. ✅ **Persistence.** Save/load `pasture3d_layers*.res`; round-trip test; verify a build with
   no layer files is byte-identical in the runtime `pasture3d_<loc>.res`. **(Done — `save_layers`/
   `load_layers` in `pasture_3d_data.cpp`, wired into `save_directory`/`load_directory`;
   `Util::location_to_layer_filename`; `test_layer_persistence` in `unit_testing.cpp`, 24/24 PASSED.
   Manifest + per-region split implemented directly; Base pixels never serialized, re-aliased on
   load; load does NOT re-composite to avoid the §5.1 ADD double-apply.)**
4. ✅ **Editor routing + Layers panel.** Active-layer sculpting, visibility/opacity/blend/lock,
   reorder; undo/redo of layer tiles. **(Done — see below.)**
5. ✅ **Tool API + RoadPastureConnector.** `*_on_layer` / owned-layer methods; migrate the
   connector to a reserved "Roads" layer; confirm re-running roads is idempotent and base
   sculpt survives. **(Done — see §10.5.)**
6. ✅ **Sub-region tiling optimization.** `_tile_size` defaults to 64 (already wired); tile GC,
   sub-tile-precise clear (fixes the Phase 5 partial-refresh caveat), and a NaN-vs-weight re-audit.
   **(Done — see §10.6.)**
7. ✅ **Control & color layers.** Holes/texture/color layers using topmost-covered-wins compositing for
   control and alpha-over for color; extends the road connector's hole carving to a reserved control
   layer. **(Done — see §10.7.)**

### 10.4 Phase 4 implementation notes (done)

- **Un-alias the Base (the §5.1 prerequisite).** `Pasture3DData` detects aliasing by pointer identity
  (`_is_base_aliased()` — a Base tile that *is* the region's `_height_map` Ref) so no persisted flag is
  needed. `_unalias_base_layer()` deep-copies each aliased Base tile into a buffer the Base owns; it
  fires the first time a non-Base layer is added (`layer_add`, idx>0) and on multi-layer load. After
  that the composite *target* (region image) and Base *source* are distinct, so per-stroke
  re-compositing is idempotent. Regression guard: `test_layer_idempotent_composite` (5× composite of an
  ADD stack, no drift).
- **Routing predicate.** `Pasture3DData::is_layer_routing()` = stack exists **and** Base is un-aliased.
  A freshly loaded *plain* terrain keeps the Base aliased ⇒ routing **off** ⇒ sculpting writes the
  region image directly exactly as before (zero behaviour change until the user adds a layer).
- **Sculpt routing.** `Pasture3DEditor::start_operation` captures the active height layer into
  `_stroke_layer` for SCULPT/HEIGHT when routing is on; a locked/reserved active layer sets
  `_stroke_blocked` and flashes a warning (plugin → `flash_layer_warning` → Layers dock). In
  `_operate_map`, height writes go to `_stroke_layer->set_sample(..., value=destf, weight=1)` (the brush
  still reads `srcf` from the live composited region map, so it feels identical), and the touched
  per-region rects are recomposited (dirty-scoped) before the existing `update_maps` upload. Hand-sculpt
  layers therefore behave as REPLACE/absolute authoring; ADD/MAX/MIN are for tool-driven layers (Phase 5).
- **Undo/redo.** Alongside the existing whole-region snapshots, a stroke deep-snapshots the active
  layer's touched tiles before/after (`Pasture3DLayer::duplicate_region_tiles` / `restore_region_tiles`)
  and stores them under `layer_tiles` in the same `EditorUndoRedoManager` action, so undo restores both
  the layer **source** and the composited region image. Guard: `test_layer_undo_restore`.
- **⚠ Persistence change (supersedes the Phase 3 "Base pixels never serialized" rule).** Once the Base
  is un-aliased it holds *true base heights* that the flattened `pasture3d_<loc>.res` no longer carries,
  so `save_layers` now serializes the Base's own tiles too (only while un-aliased; an aliased/plain Base
  is still skipped). `load_layers` loads them and leaves the Base un-aliased (routing stays on); only
  regions lacking persisted Base pixels are re-aliased onto the runtime maps. The shipped runtime files
  are unchanged. Cost: per-region layer slices now include a dense Base RF tile (~region-map size) for
  layered terrains — acceptable for editor-only data. Round-trip guard: `test_layer_base_persistence`
  (Base buffer ≠ flattened map; a post-load composite reproduces the runtime image byte-for-byte).
- **Layers panel** (`project/addons/pasture_3d/src/layers_dock.gd`, docked via `add_control_to_dock`):
  top-first list with add / duplicate / remove / move-up / move-down **and** drag-reorder, per-row
  visibility, name, blend, opacity, lock, and a highlighted active row. Structural/visual changes call
  the bound `Pasture3DData::layer_*` / `recomposite_layer` helpers, which un-alias and dirty-scope
  recomposite as needed. New Data binds: `is_layer_routing`, `layer_add`, `layer_duplicate`,
  `layer_remove`, `layer_move`, `recomposite_layer`.

### 10.5 Phase 5 implementation notes (done)

- **Tool-API methods on `Pasture3DData`** (bound in `_bind_methods`, declared in the "Tool API" block of
  `pasture_3d_data.h`, implemented after `composite_regions` in `pasture_3d_data.cpp`):
  `create_owned_layer(owner_id, name, blend_mode)`, `find_layer_by_owner`, `set_height_on_layer`,
  `add_height_on_layer`, `get_layer_height`, `clear_layer_in_area(layer_id, AABB)`, `get_layer_stack_size`,
  `set_active_layer` / `get_active_layer`. A private `_global_to_region_pixel(pos, &region_loc)` reuses the
  `set_pixel` descale math (region_loc + clamped region-local vertex) so the writes line up with the sculpt path.
- **Write path.** `set_height_on_layer` resolves the layer, writes `layer->set_sample(region_loc, px, height,
  weight)`, then **dirty-scoped `composite_region(loc, Rect2i(px, 1), /*update=*/false)`** so the region image
  is live without a GPU upload — the tool calls `update_maps(TYPE_HEIGHT)` once at the end. It also marks the
  region `set_modified(true)` so the flattened result persists on save (matching the old destructive `set_height`).
  `add_height_on_layer` accumulates within the layer (uncovered reads as 0). **Backward-compat:** a null stack or
  invalid `layer_id` falls back to `set_height` (`add_height_on_layer` → `set_height(pos, get_height+delta)`), so
  plain terrains and pre-layers builds keep working.
- **`create_owned_layer` is idempotent by `owner_id`:** `ensure_layer_stack()`, then re-use an existing layer
  with that owner, else `add_layer` + mark `reserved` + set `owner_id`; un-aliases the Base when it is the first
  non-Base layer (so routing turns on and live re-compositing stays idempotent — §5.1). Reserved ⇒ user sculpt
  strokes on it are blocked (§6).
- **`clear_layer_in_area` is region-granular for v1** (settled decision; sub-tile-precise clears are phase 6):
  for every region the world-space AABB overlaps, `layer->clear_region(loc)` then a full `composite_region` so
  the dropped footprint falls back to what's below. ⚠ **Partial-refresh caveat:** because the clear is
  region-granular, an auto-refresh of a subset of roads clears whole regions and only repaints that subset, so a
  *different* road sharing a region is wiped until the next full refresh. `do_full_refresh` (the Refresh button)
  bundles all segments/intersections, so a full refresh always self-heals. Acceptable for v1; phase 6 sub-tiling fixes it.
- **Road blend = `REPLACE` + coverage weight (settled §11.2).** The connector authors absolute road height; the
  shoulder `edge_falloff` becomes a coverage weight `1 - ease(factor, -1.5)` (1 on the road easing to 0), and the
  REPLACE composite `lerp(below, road_y, weight)` feathers into whatever is underneath — **removing the old
  `get_height`→`_lerp_smoothed_height` read-modify-write** on the live-layer path.
- **`pasture3d_road_connector.gd` migration.** New `@export var target_layer_name := "Roads"`; `_ensure_layer()` resolves
  the reserved layer via `create_owned_layer(str(get_path()), target_layer_name, REPLACE)` (stable owner id =
  node path). `refresh_roads` calls `_ensure_layer()` then `clear_layer_in_area(_affected_aabb(mesh_parents))`
  before repainting. Every former `terrain.data.set_height(pos, h)` (approx + raycast + intersection) now routes
  through `_set_road_height(pos, h, weight)` → `set_height_on_layer` (or `set_height` when no layer). Falloff
  branches pass `_falloff_weight(factor)`. **Hole carving stays on the composited control map** (`set_control_hole`,
  `bake_holes` unchanged — §11.4, control layers are phase 7). If the build lacks `create_owned_layer`
  (`has_method` check) the connector keeps writing the Base directly — plain-terrain compatibility preserved.
- **Tests** (`unit_testing.{h,cpp}`, re-commented call in `pasture_3d.cpp` READY): `test_layer_road_connector`
  proves (1) `create_owned_layer` is idempotent by `owner_id` (same idx, reserved, routing on); (2)
  `set_height_on_layer` + composite places the road (REPLACE w=1) and feathers a shoulder (w=0.5 ⇒ lerp), and a
  `clear_layer_in_area` + identical repaint reproduces the same composite; (3) a Base hand-sculpt under the road
  survives the clear + road re-run; (4) the no-stack fallback writes the Base directly. Standalone like the other
  layer tests; it sets `_region_size`/`_vertex_spacing` via a `friend` declaration on `Pasture3DData` (the tool
  API needs the descale math a Pasture3D node normally supplies). All 22 checks PASSED headless on Godot 4.6.2.

### 10.6 Phase 6 implementation notes — sub-region tiling optimization (done)

**Status: ✅ implemented 2026-06-14, builds clean, 35/35 PASSED headless.** Phase 6 was less "add
sub-tiling" (already wired) and more "reclaim freed tiles + exploit the finer granularity". Net effect on
composited output is **zero** (proven by a byte-parity test); the win is editor-side memory and a fix for the
Phase 5 partial-refresh caveat.

**Already wired (confirmed).** `_tile_size` is a per-layer field (`Pasture3DLayer`, default **64** per settled
decision §11.3). `set_sample` / `get_value` / `get_weight` compute `tile_coord = px / _tile_size` and allocate a
`_tile_size`² `FORMAT_RGF` tile lazily on first write; `composite_region` reads through `get_value`/`get_weight`,
so sub-tiling is *transparent* to compositing and coordinate math. Non-Base layers added via `add_layer`
(hand-sculpt layers and the Phase 5 road layer) already default to `tile_size = 64`, so on a 256² region they are
already sub-tiled (a thin road allocates only the few 64² tiles it crosses, not a 256 KB region image — see the
sparse-allocation test). The Base stays pinned to `tile_size == region_size` (one region-size `FORMAT_RF` image via
`set_region_image`, which asserts `image size == tile_size`) and is **never** sub-tiled (the un-alias-by-pointer
invariant, §5.1 / §10.4).

**What Phase 6 added:**

1. **Tile garbage-collection** (`Pasture3DLayer::gc_region(loc)` / `gc()`, bound; `Pasture3DData::gc_layer(id)`,
   bound). A tile that became fully uncovered (every G/weight == 0) was previously never freed. `gc_region` sweeps a
   region's tiles, drops all-zero-weight tiles, and erases the region entry when its last tile goes (returns true
   when the region is now empty/absent); `gc()` sweeps all regions. A private static `_tile_all_uncovered(img)`
   does the per-pixel weight scan and treats an aliased Base `FORMAT_RF` tile as always-covered (so the Base can
   never be GC'd). Convenience getter `get_region_tile_count(loc)` (bound) reports allocated sub-tiles.
2. **Sub-tile-precise clear** (`Pasture3DLayer::clear_tiles_in_rect(loc, px_rect)`, bound). Drops only the tiles
   whose `[coord*tile_size, +tile_size)` extent intersects a region-local pixel rect, erasing the region entry if it
   empties; returns whether anything was removed. `Pasture3DData::clear_layer_in_area` now maps the world-space AABB
   to a per-region pixel rect (`_region_pixel_rect`, floor-min/ceil-max, clamped to `[0, region_size]`) and calls
   `clear_tiles_in_rect` per overlapped region, **degrading to the old region-granular `clear_region` when
   `tile_size >= region_size`** (the Base / coarse layers — the fallback the plan asked to keep). It still
   recomposites the whole region after clearing: tiles **not** overlapping the AABB (a co-located road in another
   sub-tile) survive in `_tiles` and are re-applied by that recomposite. **This fixes the Phase 5 partial-refresh
   caveat** (§10.5): auto-refreshing a subset of roads now drops only the refreshed roads' sub-tiles, so a different
   road sharing the region no longer disappears until the next full refresh.
3. **NaN-vs-weight re-audited at sub-tile granularity (no code change needed).** With `tile_size < region_size` a
   *whole absent tile* makes `get_value` return NaN again (meaningful), while *within* an allocated tile `weight == 0`
   stays the coverage signal (§4.3). `composite_region` already tests `weight == 0` first and `isnan(value)` second,
   so it is correct for both; a dedicated test asserts both behaviours and the byte-parity test exercises the mix.

**Guardrails honoured:** Base is not sub-tiled; the runtime `pasture3d_<loc>.res` format is unchanged (editor-only
authoring data); persistence already serializes `_tiles` as `Dict[region_loc → Dict[tile_coord → Image]]`, so a
multi-sub-tile layer round-trips with no format change (proven by the round-trip test, which asserts the tile count
stays 3 rather than collapsing).

**Tests** (`test_layer_subtiling` in `unit_testing.{h,cpp}`, re-commented call in `pasture_3d.cpp` READY; standalone
like the Phase 5 test, sets `_region_size`/`_vertex_spacing` via a new `friend void test_layer_subtiling();` on
`Pasture3DData`): (a) a diagonal band on a 256² `tile_size=64` layer allocates exactly the 4 diagonal sub-tiles, not
16; (b) GC frees a wiped tile and keeps a covered one, then drops the region entry when the last tile is wiped;
(c) two roads in adjacent sub-tiles of one region — clearing an AABB over only one leaves the other's samples and
composite intact (the partial-refresh regression guard); (d) the same Base+ADD data composited at `tile_size=64` vs
`=region_size` yields a **byte-identical** `_height_map`; (e) NaN for a whole absent tile vs weight 0 (non-NaN value)
for an allocated-but-uncovered pixel; (f) save/load a 3-sub-tile layer — tile count, `(value, weight)`, and a
post-load composite all survive. All 35 checks PASSED headless on Godot 4.6.2.

**Empirical / in-editor (recommended, like the Phase 5 user-verification step):**
- **Partial-refresh fix.** Place two roads that cross the **same** region, auto-refresh only one (move it), and
  confirm the other road no longer disappears. The automated guard (c) proves the storage/clear mechanism; this
  confirms it through the real connector → `clear_layer_in_area` → composite path. *(Not yet user-verified in-editor.)*
- **Memory.** Optionally log a sum of `image->get_data().size()` over a road layer's tiles to see the road
  footprint sit at a few 64² tiles per touched region instead of a full region image.
- **No regression.** The terrain should look identical and the runtime `pasture3d_<loc>.res` files byte-unchanged.

### 10.7 Phase 7 implementation notes — control & color layers (done)

**Status: ✅ implemented 2026-06-14, builds clean, 32/32 PASSED headless (full suite 139/139).** This phase
generalises the stack beyond a single blendable height channel: CONTROL is a packed `uint32` (not
float-blendable) and COLOR is `RGBA8`, so each gets its own compositing rule and its own dense base.

**Per-map-type layer storage (`Pasture3DLayer`).** A new serialized `bool _is_base` marks the dense,
always-covered base of a map type. The tile format now follows the map type (`_overlay_format()`): color
overlays are `FORMAT_RGBA8` (RGB = albedo, **A = coverage weight**), height/control overlays stay
`FORMAT_RGF` (R = value or control-as-float-bits, G = weight). New accessors: `set_sample_color` /
`get_sample` (full RGBA) alongside the scalar `set_sample` / `get_value`. `get_weight` is still the
authoritative coverage test (§4.3) and is now format-aware: a base or `FORMAT_RF` tile is always covered
(weight 1), an `RGBA8` overlay reads coverage from alpha, an `RGF` overlay from green. GC (`_tile_all_uncovered`)
scans alpha for `RGBA8` and skips base layers entirely (`gc_region` early-returns for `_is_base`). NaN still
means only "whole absent tile".

**Compositing per map type (`composite_region`).** Refactored into three passes — `_composite_height_region`
(filters `map_type==TYPE_HEIGHT`; **byte-identical** to pre-Phase-7, proven by a baseline test), the new
`_composite_control_region` (**topmost-covered-wins** — seed from the control base, then each covered control
overlay bottom→top *fully replaces* the value; no arithmetic blend, §5.1), and `_composite_color_region`
(**alpha-over** — seed from the color base, `acc.rgb = lerp(acc.rgb, overlay.rgb, weight*opacity)`, roughness
in `acc.a` preserved). Control/color passes only run when `stack->has_overlay_of_type(...)` (a new cheap
gate), so height-only terrains pay zero extra cost. `composite_region(update=true)` now pushes only the map
types it touched; the management paths (`recomposite_layer`/`layer_remove`/`layer_move`) use `update_maps(TYPE_MAX)`.

**Dense typed bases (the idempotency key).** Control/color have no Base layer in the original stack, so the
hand-authored control/color lives in the region map — which is *also* the composite target. To make a
clear+recomposite idempotent (the height un-alias problem, §5.1, for control/color), `_ensure_typed_base(map_type)`
lazily creates a dense base layer **seeded from a deep copy of the current region control/color map** the first
time a control/color overlay is created. The base is full-coverage, `reserved`, never GC'd, and never
sub-tiled. `Pasture3DLayerStack::find_base_layer(map_type)` locates it; `_adopt_region_into_bases` makes every
base (height + typed) cover regions added after the stack exists (generalising the old height-only adoption in
`add_region`). `_synthesize_base_layer` and `load_layers` now set `_is_base` on the height Base so old manifests
normalise.

**Holes → a control layer (connector).** `Pasture3DData::create_owned_layer_typed(owner,name,blend,map_type)`
(the height `create_owned_layer` now delegates to it with `TYPE_HEIGHT`), plus `set_control_on_layer`,
`set_hole_on_layer` (reads the composited control, flips the hole bit preserving texture/nav/etc, stores the
full value at weight 1 so topmost-wins replaces cleanly), and `set_color_on_layer` — all with the same
null-stack/invalid-layer fallback to the destructive `set_control`/`set_control_hole`/`set_color` path.
`pasture3d_road_connector.gd` now owns a second reserved layer (`owner_id + "#holes"`, `target_layer_name + " Holes"`,
`TYPE_CONTROL`): `bake_holes` resolves it, `clear_layer_in_area`s its footprint, re-carves via
`_set_road_hole` → `set_hole_on_layer`, then `update_maps(CONTROL)`. Carving is now non-destructive and
idempotent like the road height; on a build/terrain without typed layers it falls back to `set_control_hole`
unchanged. (Editor guard: `start_operation` only captures a height active layer as the sculpt `_stroke_layer`,
so a control/color active layer is never written height into.)

**Persistence + undo.** No format change — `save_layers`/`load_layers` already serialise `_tiles` generically
and align layers by index, so the new RGBA8 tiles and the dense control/color bases (upper layers, `i>0`)
round-trip with the height path untouched. The undo tile-snapshot primitives (`duplicate_region_tiles` /
`restore_region_tiles`) are map-type agnostic, so control/color edits undo via the existing path.

**Guardrails honoured:** the dense height Base un-alias-by-pointer identity is unchanged; the runtime
`pasture3d_<loc>.res` format is unchanged (editor-only data); non-Base layers default to `tile_size 64`; and
the height composite output is byte-identical to a pre-Phase-7 baseline.

**Tests** (`test_layer_control_color` in `unit_testing.{h,cpp}`; re-commented call in `pasture_3d.cpp` READY;
standalone, sets `_region_size`/`_vertex_spacing` via a new `friend void test_layer_control_color();` on
`Pasture3DData`): (a) control is topmost-covered-wins (upper overlay overrides lower at a shared pixel; an
uncovered pixel falls through to the hand-authored base); (b) color blends by weight (alpha-over) with
roughness preserved; (c) the height composite is byte-identical after control/color layers are added;
(d) a hole authored on a control layer carves the composited control map, survives a clear + identical
re-carve (idempotent) with the hand-authored control beneath preserved, and clearing the hole layer entirely
restores the hand-authored base (no hole); (e) save/load round-trips the control + color overlays AND their
dense bases, and a post-load composite reproduces the composited control and color region maps byte-for-byte.
All 32 checks PASSED headless on Godot 4.6.2.

**Empirical / in-editor** (full step-by-step in `PASTURE3D_LAYERS_HOLE_TESTING.md`):
- **Hole migration — ✅ confirmed working in-editor (2026-06-14):** baking holes under a road carves the
  terrain, and re-baking is idempotent. (Recommended follow-ups, not yet exhaustively run: move the road /
  re-bake and confirm the old hole vanishes with no leftovers; bake over hand-painted control and confirm it
  survives, and that clearing the hole layer restores it.)
- **No regression.** A height-only terrain looks identical and its runtime `pasture3d_<loc>.res` files are
  byte-unchanged (control/color passes never run when no control/color overlay exists).

**Follow-ups (this was the last planned phase):**
- No Layers-panel UX yet for *adding* control/color layers or painting into them by hand — they are created
  via the tool API (the connector) only. A panel affordance + an editor paint route (control/color analogue
  of the height sculpt routing) would round out hand-authoring; the compositing + storage are ready for it.
- Color overlays author albedo + coverage only (roughness is carried by the color base); a roughness/weight
  authoring channel could be added if per-layer roughness is wanted.
- `is_layer_routing()` is still count-based (`> 1`), so a terrain with only a control/color layer also enables
  height sculpt routing into the active (height Base) layer. Harmless today, but a per-map-type routing
  predicate would be cleaner if control/color hand-painting lands.

---

## 11. Settled decisions

These four were confirmed and are now binding for the implementation:

1. **Layer file granularity = manifest + per-region.** Global `pasture3d_layers.res`
   manifest (ordered metadata) plus per-region `pasture3d_layers_<loc>.res` pixel slices
   (§7.1), so layers stream and scale with the world. The single-file form is acceptable
   only as a throwaway phase-3 prototype before the per-region split lands.
2. **Road blend mode = `REPLACE`.** Roads author absolute height; the connector's
   `edge_falloff` is expressed as coverage weight that feathers the shoulder into whatever
   is underneath (§8.3). `ADD` is reserved for detail/erosion layers, not roads.
3. **Default `_tile_size` = 64.** Matches the default region size of 256 (4×4 tiles/region)
   and keeps thin generated features (roads, paths, rivers) maximally sparse (§4.2, §9).
4. **v1 was height-only.** Holes and texture/color stayed on the composited control/color maps, and the
   road connector kept carving holes via `set_control_hole` — **until phase 7 (now done, §10.7):** control
   (topmost-covered-wins) and color (alpha-over) layers exist, and the connector carves holes into a
   reserved control layer (non-destructive/idempotent), falling back to `set_control_hole` only when the
   typed-layers feature is absent.

### The map-type badge (2026-08-31)

Each row in the dock now names what the layer stores: **Height**, **Control** or **Color**.

The type was invisible and nothing else on the row implied it. Two layers named for the same feature can
be different types — the road system creates exactly that pair, a height layer for the grading and a
control layer for the surface paint — and the dock drew them as identical rows. So "delete the wrong one"
and "paint colour into the heightmap" were both one click away, and neither looked like a mistake until
the terrain moved.

The badge is read-only, and deliberately: a layer's type is fixed at creation because the tiles beneath it
are a different image format per type (§4.1), so a control that changed it here would be a control that
threw the layer's contents away. An unrecognised type renders as a red `Type N` rather than as the nearest
known name — the failure mode this exists to prevent is a layer labelled confidently and wrongly.

---

## Sources

- [Landscape Edit Layers — Unreal Engine 5.7 docs](https://dev.epicgames.com/documentation/unreal-engine/landscape-edit-layers-in-unreal-engine)
- [Landscape Sculpt Mode — Unreal Engine 5.7 docs](https://dev.epicgames.com/documentation/unreal-engine/landscape-sculpt-mode-in-unreal-engine)
- [Complete Guide to Non-Destructive Landscape Layers — World of Level Design](https://www.worldofleveldesign.com/categories/ue4/landscape-layers-01-sculpting.php)
- [Krita `Tile` (64×64 planar tile) — paint_layer docs](https://docs.rs/krita/latest/krita/paint_layer/struct.Tile.html)
- [How Krita renders tiles / tile manager discussion](https://kimageshop.kde.narkive.com/krDHO1YW/how-does-krita-render-tiles-to-the-screen)
- Pasture3D source: `src/pasture_3d_data.{h,cpp}`, `src/pasture_3d_region.h`, `src/pasture_3d_editor.h`, `project/addons/pasture_3d/connectors/pasture3d_road_connector.gd`
</content>
</invoke>
