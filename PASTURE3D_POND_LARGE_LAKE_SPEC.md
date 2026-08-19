# Pasture3D Large Lake Spec (`Pasture3DPond` at 4 km²)

**Status:** **IMPLEMENTED 2026-08-09.** Headless-verified. A 4 km² pond bakes in **244 ms**, down from
**13.7 s**, with output proven **bit-identical** over 8405 samples. Target: Godot 4.7, Pasture3D `main`.

**Goal:** make a 2000 × 2000 m lake a usable thing to author with `Pasture3DPond`.

---

## 1. What was actually wrong

**Not correctness.** A 4 km² pond already carved correctly before any change: measured across the full
2000 m width, every interior sample carved to exactly −4.00 m. The starting assumption that something
broke at scale was wrong, and the probe that says so is `bench/PondScaleProbe.tscn`.

Two real problems, of very different size:

| # | Problem | Severity |
|---|---|---|
| **A** | A full-refresh bake cost **~3.4 µs per cell**, so a 4 km² pond froze the editor for **13.7 s** on every edit | the blocker |
| **B** | A pond reaching past the created regions carved only the covered part, **silently, with no warning** | data loss, easy to miss |

### 1.1 A measurement trap worth recording

The first version of `PondScaleProbe` reused one terrain and one origin for every size. Each pond then
overlapped the previous pond's carve, so the centre probe measured a delta against **already-carved
ground** and reported "the centre is not carved" — which read exactly like a size-dependent bug and is
not one. The probe now builds a fresh terrain per size. Any future probe that bakes more than one
fixture needs the same treatment; this is the "measured nothing vs measured correctly" failure in its
most convincing disguise, because the wrong answer is plausible and reproducible.

---

## 2. Problem B: silent region drop

Both native write paths skip cells with no region under them, and neither says anything:

- `_stamp_write` ([pasture_3d_brush_raster.cpp:343](src/pasture_3d_brush_raster.cpp:343))
- `_apply_stamp_block` — "only write where a region exists (matches _stamp_write)"

That skip is **correct**: a brush must not invent terrain. The defect is the silence. Measured on a loop
spanning [−400, +400] with regions covering only [−512, 0):

```
  x      before     after      carved?
  -300     0.00     -4.00      yes
  -100     0.00     -4.00      yes
  +100      nan       nan      NO
  +300      nan       nan      NO
  configuration warnings the brush raises: 0
```

Half the basin missing, nothing said. At 4 km² this stops being an edge case: at the 256 m default a
2 km loop spans **121 regions**, so a big lake near the edge of the built world is the normal way to meet
this, and the symptom — a lake filled with water sitting on unbuilt ground — does not point at its cause.

**Fix:** `_region_coverage()` on `Pasture3DTerrainBrush` returns `[missing, spanned]` over the brush's
spline footprints; `Pasture3DPond._get_configuration_warnings()` reports it by count:

> This pond reaches into 8 region(s) of the 16 it spans that do not exist yet. The basin will not be
> carved there — the rasteriser only writes where there is terrain — so the water will sit on unbuilt
> ground. Add the regions with the Region tool, or move or shrink the loop.

The helper is on the base class because nothing about it is Pond-specific, but **only Pond raises the
warning**. Wiring it into every brush would add a new warning to existing scenes across the board, which
is a bigger decision than this change; the helper is there for whoever makes it.

---

## 3. Problem A: the full-refresh bake composited per cell

### 3.1 The measurement

| Lake | Cells | Before | After | |
|---|---|---|---|---|
| 100 × 100 m | 0.01 M | 34 ms | **4 ms** | 8× |
| 500 × 500 m | 0.25 M | 737 ms | **18 ms** | 41× |
| 1000 × 1000 m | 1.0 M | 3 266 ms | **66 ms** | 49× |
| **2000 × 2000 m (4 km²)** | **4.0 M** | **13 691 ms** | **244 ms** | **56×** |

### 3.2 The cause

`Pasture3DData::_stamp_write` ends with:

```cpp
if (p_composite) {
    // Full-refresh path: keep the public API's get_height up to date.
    composite_region(region_loc, Rect2i(img_pos, V2I(1)), false);
}
```

A `composite_region` on a **1 × 1 rect, per cell**. Each one allocates an `acc` buffer, walks the layer
stack, calls `height_map->get_region()` (an Image allocation), `get_data()` (a `PackedByteArray` copy),
`set_data()`, and `blit_rect()`. Four million times for a 4 km² pond. It also forces the per-cell write
path, because the batched raw-tile apply is gated on `!composite`
([pasture_3d_brush_raster.cpp:637](src/pasture_3d_brush_raster.cpp:637)) — so the cost was paid twice
over: per-cell heap traffic *instead of* the fast batched commit.

**The dirty-rect path already solved this.** `_refresh_owner_rect` sets `_defer_composite = true`, paints,
then calls `composite_area(clip_box, false)` once — its own comment reads "Composite the whole footprint
ONCE instead of per painted pixel — the big win for large edits."

The **full-refresh** path never got the same treatment. That is the path that runs when a brush is
placed, when any property changes, when a scene loads, and when undo rebinds — i.e. most of the time.
So the optimisation existed, and the common case was not using it.

### 3.3 The fix

Mirror the dirty-rect path in `_refresh_owner`: accumulate the union of every box the bake clears, set
`_defer_composite` on all layer-mates, paint, then composite that union once.

This is not a new mechanism. It makes the full refresh behave like the dirty-rect refresh, which has
shipped this way since Round 2 — so the two paths now agree instead of differing.

### 3.4 Why deferring is safe

The concern is a brush reading a half-composited layer back through `get_height` mid-bake. It does not
arise:

- Brushes read the ground **below their own layer** via `composite_height_below`, which accumulates
  layers under a given id and does not depend on this layer being composited.
- Two tools on one layer are combined by `_stamp_write`'s **same-layer blend** (MAX keeps the taller, MIN
  the deeper, ADD sums), not by reading each other back through the composite.
- `snap_to_surface` runs **before** the paint loop, after the clear and its composite, so it reads the
  same base it always did.

Argued here, and then **measured** — see §4, which includes fixtures for exactly these three cases.

### 3.5 What this is not

This is **not** Round 3 of `PASTURE3D_BRUSH_PERF_ROUND3_SPEC.md`. That spec's status header still says
"design agreed 2026-06-20, branch `perf/compositing-round3`", but **its part A is already built** —
`_composite_height_region` accumulates per layer into a rect buffer via `_accumulate_height`, resolving
each tile once. The header is stale and misled the choice of approach at the start of this work.

Round 3's remaining parts are still unbuilt and still worth having, and are now **less urgent**: its
part B (drop the redundant pre-paint composite) and part C (per-region layer culling) both attack the
composite that this change reduced from four million calls to one. That spec's headline ratio —
"clear 64 + composite 86 + paint 54" — was measured on a ~205 ms bake and does not describe a bake at
20 000× the cell count.

---

## 4. Verification

Compositing is correctness-critical and has no GDScript A/B oracle, so the bar set by Round 3's own
Verification section is **bit-identical output**, not "it still looks carved".

`bench/BakeIdentityProbe.tscn` dumps a 41 × 41 grid of composited heights per fixture at full float
precision (as strings — JSON round-tripping a float is how a bit-comparison quietly becomes "equal to six
decimals"). Run before and after the change, then compared:

```
  mound                   1681 samples   1681 finite  span  133.204 m  DIFFER: 0
  plow_relief             1681 samples   1681 finite  span   78.518 m  DIFFER: 0
  pond                    1681 samples   1681 finite  span  109.677 m  DIFFER: 0
  snap_to_surface         1681 samples   1681 finite  span  143.867 m  DIFFER: 0
  two_tools_one_layer     1681 samples   1681 finite  span   72.244 m  DIFFER: 0

  total 8405 samples, 0 differing        RESULT: BIT-IDENTICAL
```

The fixtures are chosen to be the cases where deferring could differ, not five variations of one case:
**two tools sharing one layer and overlapping** (§3.4's second bullet), **`snap_to_surface` on** (third
bullet), and **a Plow reading the layers below its own** (first bullet). The `span` column is the control
that must fail: it proves each fixture carried 72–144 m of real relief, so a run of zeros could not have
produced the identical result.

**Regression suites, all re-run and passing:** `PlowReliefCheck` (14 gates), `MoundReliefCheck` (6),
`PondCarveCheck`, `PondBrushCheck`, `StreamBankSurfaceCheck`, `SimPhase1Gate` through `SimPhase4Gate`.

**Not run:** `WaterBodiesPhase*Gate`. Those take screenshots through `RenderingServer.frame_post_draw`
and their own run command omits `--headless`; they need a window and hang without one. Pre-existing, and
unrelated to brush compositing — but it left the water-surface path unverified, and §4a is what was
sitting in it. Worth remembering that the gap in the suite is where the next defect was found.

---

## 4a. The water surface: a spurious warning on every large lake

Found after the carve work, from the editor, on a real pond — the path §4 explicitly listed as
unverified. `Pasture3DPool._build_masked` ran the sheet-coarsening loop and set `_sheet_spacing_used`
**before** deciding whether a static sheet or the camera-centred clipmap carries the surface.

When the clipmap wins — the default for any body big enough to be masked, since `mask_static_sheet` is
`false` and `Pasture3DWaterClipmap` ships — `_surface.mesh` is set to `null`, the shore uniforms take the
fine wave spacing, and the clipmap takes its own `vertex_spacing`. The coarsened number described
geometry **that was never built**, and `_shape_warnings` reported it regardless:

> The sheet was coarsened to 2.54 m to fit max_vertices; the waves want 1.27 m. … this is the gap the
> camera-centred clipmap closes.

— on a body where the clipmap had closed it. `_last_stats["sheet_spacing"]` already reported `0.0`
correctly for clipmapped bodies; `_sheet_spacing_used`, which the warning reads, did not.

Reproduced on a 1200 × 1200 m pool: `clipmap carries true`, `surface mesh <null - clipmap>`,
`_sheet_spacing_used 2.00`, warning raised.

**Fix:** decide the carrier first. When clipmapped, skip the coarsening loop and the budget check and set
`_sheet_spacing_used = 0.0`. This also restores the invariant stated in that function's own comment —
"the field has to be the same either way or the A/B switch would not be one" — which the coarsening loop
had been breaking by reframing the SDF around a coarser pad on clipmapped bodies.

A second, **latent** defect fell out of the same ordering: `_budget_exceeded` ran on the phantom sheet,
so a clipmapped body could fail to build over vertices the clipmap never emits. Nobody hit this — the
coarsening must reach 512 m spacing first, which at the default 400 000 ceiling needs a body about
323 km across — but it was wrong where it stood and is now inside the sheet branch.

Gates in `bench/PoolClipmapWarningProbe.tscn`, all passing:

| Gate | Result |
|---|---|
| A small body still builds a real sheet, no coarsening claim | sheet mesh true, spacing 0.00 |
| B **clipmapped body does not warn** | clipmap true, mesh null, spacing 0.00, 29 580 vertices |
| C **CONTROL** same body with `mask_static_sheet` on still coarsens and still warns | spacing 2.00 m, warns |
| D budget is a sheet limit, not a body limit | clipmap drew **7× max_vertices** and built; control: sheet coarsened 2.00 → 32.00 m under the same ceiling |

Gate C is the one that matters: without it, deleting the warning outright would pass B just as well.
Gate D's first draft asserted the sheet must *refuse* under a tight budget; it does not, it **coarsens**
(1 → 32 m), so the control was rewritten to measure that pushback instead of an outcome that never
happens.

---

## 5. Limits that remain

1. **Headless has no `RenderingDevice`**, so the GPU analytic SDF path never ran in any measurement here
   — every number above is the CPU chamfer fallback. In the editor the SDF half may be faster still. The
   244 ms figure is therefore an upper bound, not an estimate of editor behaviour.
2. **Region creation is still manual.** No brush calls `add_region_blankp`, by design. §2 makes the
   consequence visible; it does not remove it. Auto-creating regions from a brush footprint is a real
   design question (it would let one dragged loop allocate hundreds of megabytes) and is deliberately
   not answered here.
3. **The per-cell rasteriser loop is still single-threaded** and is now the dominant remaining cost at
   4 km². It is embarrassingly parallel. Round 2 left it serial on purpose; with compositing no longer
   dominant, that is the next thing worth measuring.
4. **`region_size` defaults to 256 m**, so a 4 km² lake spans 121 regions. Nothing here changes that, and
   whether a large-lake workflow wants a larger region size is untested.

---

## 6. Sources

**Internal:** [pasture3d_pond.gd](project/addons/pasture_3d/connectors/pasture3d_pond.gd),
[pasture3d_terrain_brush.gd](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd),
[pasture_3d_brush_raster.cpp:325](src/pasture_3d_brush_raster.cpp:325),
[pasture_3d_data.cpp:1329](src/pasture_3d_data.cpp:1329),
`PASTURE3D_BRUSH_PERF_ROUND3_SPEC.md`, `PASTURE3D_BRUSH_PERF_ROUND2_SPEC.md`,
`PASTURE3D_WATER_BODIES_SPEC.md`, `PASTURE3D_LANDSCAPE_TOOLS_SPEC.md`.
