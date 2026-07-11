# Pasture3D — Scene-Tab-Switch Freeze: Implementation Spec

**Status:** Phase 0 done (then removed); **Phase 1 implemented + user-verified in-editor 2026-07-11**
(freeze gone across multi-tab switching; gizmo-move re-bake still works). §6.4 optional C++ polish not done.
**Author:** investigation + spec, 2026-07-11
**Scope:** Editor-only performance. Eliminate the multi-second editor freeze when switching
between scene tabs while a `Pasture3D` node is present in one or more open scenes.

---

## 1. Problem

Switching scene tabs in the Godot editor freezes the editor for several seconds when a
`Pasture3D` terrain is in play. The freeze scales with terrain size (region count × region size).

### Root cause

The editor keeps only the **active** edited scene attached to the `SceneTree`. Switching tabs
**detaches** the outgoing scene root and **attaches** the incoming one. `Pasture3D` therefore
receives `NOTIFICATION_EXIT_TREE` on the tab you leave and `NOTIFICATION_ENTER_TREE` on the tab
you return to. The current code treats every tree-exit as a **full teardown** and every tree-enter
as a **cold rebuild** — there is no "detached but alive" (dormant) state.

- **EXIT_TREE** — [`pasture_3d.cpp:1347`](src/pasture_3d.cpp) destroys the terrain mesher, ocean
  mesher, instancer, mouse picking, and displacement buffer; uninitializes assets + material; sets
  `_initialized = false`.
- **ENTER_TREE** — [`pasture_3d.cpp:1222`](src/pasture_3d.cpp) calls `_initialize()`
  ([`pasture_3d.cpp:31`](src/pasture_3d.cpp)), which — because `_initialized` was reset — re-runs the
  full heavy path.

Dominant costs on re-entry, in rough order of expected weight:

| # | Operation | Anchor | Cost driver |
|---|-----------|--------|-------------|
| 1 | **Editor collision rebuild** | `_collision->initialize()` → `build()` [`pasture_3d_collision.cpp:232`,`:235`](src/pasture_3d_collision.cpp) | `destroy()` then recreate **one `CollisionShape3D` + `HeightMapShape3D` per region**, then `update()` refills every height sample — `(region_size+1)²` floats/region (≈263 k at size 512) × region count. |
| 2 | **Instancer rebuild** | `_instancer->initialize()` → `update_mmis()` [`pasture_3d_instancer.cpp:561`,`:567`](src/pasture_3d_instancer.cpp) | Rebuilds every MultiMesh across all regions × cells × LODs. |
| 3 | **Shader recompile** | `_material->initialize()` → `update(FULL_REBUILD)` → `_update_shader()` [`pasture_3d_material.cpp:765`,`:794`,`:517`](src/pasture_3d_material.cpp) | `_shader->set_code(...)` is called unconditionally, forcing shader recompilation each entry. |
| 4 | **Mesher + displacement** | `_setup_terrain_mesher()` / `_setup_ocean_mesher()` / `_update_displacement_buffer()` [`pasture_3d.cpp:88`](src/pasture_3d.cpp) | Clipmap mesh re-init + a SubViewport GPU pass. |

Both scenes pay: the one you leave pays teardown, the one you enter pays the cold rebuild.

### What is NOT the cause (confirmed)

The layer **compositing pipeline does not re-run** on a tab switch. `Pasture3DData::initialize()`
guards `load_directory()` behind `prev_initialized` ([`pasture_3d_data.cpp:274`,`:278`](src/pasture_3d_data.cpp)),
and the GPU region texture arrays (`_generated_*_maps`) live on `_data` and are only cleared by
`_clear()` inside `load_directory` ([`pasture_3d_data.cpp:830`](src/pasture_3d_data.cpp)) — not hit on
re-entry. So `composite_regions()` / `update_maps(TYPE_MAX, true)` are **not** invoked. The perceived
"recomposite" is the collision/instancer/shader/mesh rebuild.

---

## 2. Goals / non-goals

**Goals**
- Reduce tab-switch time from multiple seconds to sub-100 ms perceived, for large terrains.
- No change to runtime (exported game) behavior.
- No regression in in-editor sculpting, brush picking, object snapping, or layer editing.

**Non-goals**
- Reclaiming the memory of backgrounded (dormant) tabs — accepted as a trade (see §3).
- Keeping a non-active tab's terrain queryable by other scripts while backgrounded (§3).
- Any change to the compositing / layer pipeline.

---

## 3. Constraints (from workflow interview)

1. **Approach:** phased — measure → guard → cache. Ship the cheapest effective phase; only escalate
   if measurement says it's needed.
2. **In-editor physics collision is not relied upon.** Brush picking uses the terrain's own GPU
   mouse-picking; object snapping uses `data.get_height()` ([`pasture_3d_objects.gd:59`](project/addons/pasture_3d/utils/pasture_3d_objects.gd)),
   not raycasts. → The editor collision build (cost #1) may be **skipped or deferred** in-editor.
3. **Inactive tabs may be dormant.** A backgrounded terrain does not need to stay live. → Caching can
   simply *keep built state resident* and resume on return; it need not keep the terrain functional
   while detached.

---

## 4. Key architectural insight

On a tab switch the terrain node is **removed from the tree but not deleted** — genuine teardown is
`NOTIFICATION_PREDELETE` ([`pasture_3d.cpp:1375`](src/pasture_3d.cpp)). Its runtime-built children
(`StaticBody3D` + collision shapes, MMI nodes, SubViewports) travel with it as detached children.
Therefore, if EXIT_TREE **stops processing instead of destroying**, those structures survive and come
back for free on ENTER_TREE. Because dormant tabs are acceptable (§3.3), we do **not** need to free
them on detach; PREDELETE remains the single real-teardown path.

This is the basis for Phase 2. Phases 0–1 do not depend on it.

---

## 4a. Phase 0 RESULTS (2026-07-11) — hypothesis overturned

Instrumentation landed and was measured switching between three terrain scenes in a debug editor
build. **The collision/instancer hypothesis in §1 is wrong.** Per-subsystem breakdown (µs):

| Subsystem | First show (per scene) | Repeat switch | Verdict |
|---|---:|---:|---|
| `data` (`load_directory`) | 108 k / 429 k / 20 k | **2** | Dominant but **runs once per terrain/session**; scales with region count/size |
| `material` (`_update_shader`) | ~45 k | **~35 k** | Recurring every switch, ~constant |
| `assets` | ~17 k | **~17 k** | Recurring every switch, ~constant |
| `collision` | 1 | 1–2 | **negligible — not the cost** |
| `instancer` | 5–24 | 5–8 | **negligible — not the cost** |
| mesher / ocean / displacement / snap | ~900 / 0 / 7 / 0 | same | negligible |
| EXIT_TREE total | — | 800–1200 | negligible |

Conclusions:
- **Collision and instancer cost ~0** because their heavy structures are *not* actually freed in a way
  that forces a full rebuild here (or the rebuild is trivially cheap for these scenes). Either way the
  original §1 ranking (#1 collision, #2 instancer) does **not** hold. Drop those guards.
- **`load_directory` is the only size-scaling term** and is already guarded to once-per-terrain
  (`prev_initialized`). It is the prime suspect for a *multi-second* freeze on a large production
  terrain, but it does **not** recur on repeat tab switches.
- **Recurring per-switch cost ≈ 50 ms**, almost entirely `material` (shader recompile) + `assets`.

Demo scenes top out at ~0.48 s total, so they do **not** reproduce the reported multi-second freeze.

### 4a.1 REAL root cause found (confirmed on `sculpting_2`)

Profiling the actual freezing scene proved **the freeze is not in `_initialize()` at all** (`TOTAL`
≈ 51 ms). The multi-second hang lands *between* the `NOTIFICATION_ENTER_TREE` print and a burst of
`Pasture3DRegion::save` "Writing region…" logs. It is a **full-layer spline-brush re-bake in GDScript**.
Per-path instrumentation (`[dbg]` prints on every scheduler + bake entry) pinned the exact trigger:

1. A tab switch re-attaches the whole scene, so **every brush's child splines re-enter the SceneTree**,
   firing `child_entered_tree` on each brush → `_on_child_changed()`
   ([`terrain_brush.gd:301`,`:308`](project/addons/pasture_3d/connectors/terrain_brush.gd)).
2. `_on_child_changed()` treats any child enter/exit as a structural edit and calls **`_schedule_refresh()`
   (full)** — the instrumentation showed this firing once per brush (`full=true, nsplines=0`), i.e. a
   **whole-layer bake per brush**, for ~40 brushes.
3. The debounce timer fires after ENTER_TREE returns → `_refresh_owner()`
   ([`terrain_brush.gd:521`](project/addons/pasture_3d/connectors/terrain_brush.gd)) clears + repaints
   every tool bound to the layer, for every brush = **the freeze**.
4. The re-bake marks regions modified → written to disk (the "Writing region…" logs are the identical
   re-baked data being persisted). Explains the pre-existing `.res` churn in `git status`.

**The transform hypothesis was WRONG.** `NOTIFICATION_TRANSFORM_CHANGED` does also fire on the switch,
but the instrumentation showed the transforms are identical (`eq=true`) and correctly skipped by the
transform guard — they never bake. The bake is entirely the `child_entered_tree` path.

The `terrain_brush.gd` `create_timer`-on-null errors are the **same trigger** firing during the detach
half of the churn (tree is transiently null) — the null guard in `_arm_refresh_timer` handles them.

**Why only some scenes:** every scene with brushes schedules the refresh on switch; the *cost* scales
with how much layer-bound spline content must be re-composited. `sculpting_2` has ~40 heavy bound
brushes (freezes); `big_regions`/`simple_pasture` have little/none (imperceptible).

**Net:** collision/instancer hypothesis was wrong (~0 µs); `data`/`material`/`assets` are real but minor
(~50 ms, §6b); the reported multi-second freeze is entirely the spurious auto-refresh (§6, new).

## 5. Phase 0 — Instrument & confirm  *(DONE)*

**Purpose:** get hard numbers before changing behavior, and give a permanent, low-noise profiling
hook.

- Add a scoped timer helper (RAII `Timer` around `Time::get_ticks_usec()`), gated behind
  `LOG(DEBUG, ...)` or a `Pasture3D::_profile_init` bool, logging elapsed µs for each of:
  `_material->initialize`, `_assets->initialize`, `_collision->initialize`,
  `_instancer->initialize`, `_setup_terrain_mesher`, `_setup_ocean_mesher`,
  `_update_displacement_buffer`, and total `_initialize()`.
- Location: wrap the calls in `_initialize()` ([`pasture_3d.cpp:83`–`90`](src/pasture_3d.cpp)) and the
  two notification handlers.

**Exit criterion:** switch between `big_regions.tscn` and `sculpting_2.tscn` several times in a debug
build and record the per-subsystem breakdown. This ranks the real offenders and sets the bar Phase 1
must clear.

---

## 6. Phase 1 — Suppress the spurious spline re-bake (THE fix) — IMPLEMENTED 2026-07-11

All changes in [`terrain_brush.gd`](project/addons/pasture_3d/connectors/terrain_brush.gd), **no C++
rebuild required**. Confirmed trigger (§4a.1): `child_entered_tree` during scene re-attach →
`_on_child_changed()` → `_schedule_refresh()` (full-layer bake per brush).

### 6.1 Primary: skip child-refresh during the node's own tree-enter churn

`_on_child_changed()` ([`terrain_brush.gd:301`](project/addons/pasture_3d/connectors/terrain_brush.gd))
treats any child enter/exit as a structural edit and full-bakes the layer. On a tab switch the child
splines merely re-enter the tree — no structural change, and the baked data is already correct.

- New field `_tree_settling`. Set it `true` in the brush's `NOTIFICATION_ENTER_TREE` handler (which
  fires **before** the child `child_entered_tree` signals), and clear it via `call_deferred` after the
  frame settles.
- **Gate on `_ready_done`:** only suppress on *re*-entries. A fresh duplicate/paste/first-open has
  `_ready_done == false` at ENTER_TREE, so it is **not** suppressed and still bakes its new footprint —
  only tab switches / reparents (already baked, `_ready_done == true`) are suppressed.
- Early-return at the top of `_on_child_changed()` when `_tree_settling`. Setter-driven refreshes
  (`_schedule_refresh` from the `terrain`/param setters) are unaffected — they don't go through
  `_on_child_changed`, so a reparent still rebinds and bakes via the `terrain` setter.

### 6.2 Supporting: skip transform-refresh when the brush did not actually move

`NOTIFICATION_TRANSFORM_CHANGED` also fires on the switch (instrumentation confirmed the transforms are
identical and this path already skips), but keep a defensive guard so it can never bake on a no-op:
- `_last_baked_xform` field, baselined in `_ready`, recorded after each real bake in `_on_refresh_timer`.
- `_schedule_transform_refresh()` early-returns when `global_transform.is_equal_approx(_last_baked_xform)`
  (and until `_ready_done`).

### 6.3 Supporting: null-guard the debounce timer

`_arm_refresh_timer()` ([`terrain_brush.gd`](project/addons/pasture_3d/connectors/terrain_brush.gd))
guards `get_tree()` against null (transiently null during the detach boundary), fixing the
`create_timer`-on-null error spam (§9a item 1).

### 6.3v Verify the redundant saves stop

After 6.1, switching to `sculpting_2` should produce **no** "Writing region…" logs (nothing was
re-baked, so nothing is dirtied/saved) and **no** `[dbg]`/error spam. If saves persist, there is another
dirtying path (a property setter firing `_schedule_refresh` on load) to track down — check the setters at
[`terrain_brush.gd:53`,`:83`,`:90`](project/addons/pasture_3d/connectors/terrain_brush.gd).

### 6.4 Optional secondary — the ~50 ms recurring C++ cost (defer unless it matters)

Independent of the freeze; only worth doing if the residual ~50 ms per switch is objectionable after
6.1. Both are constant (do not scale with terrain):
- **Shader recompile (~35 ms):** `_update_shader()`
  ([`pasture_3d_material.cpp:517`](src/pasture_3d_material.cpp)) calls `_shader->set_code(...)`
  unconditionally. Cache last-applied code; skip `set_code()`/`material_set_shader()` when byte-identical.
- **Assets rebuild (~17 ms):** `_assets->initialize()` regenerates texture arrays every entry; guard with
  a dirty flag on `Pasture3DAssets` cleared on real asset edits.

### 6.5 Decision gate

Re-measure on `sculpting_2` after 6.1 + 6.2. Expected: freeze gone, no region saves on switch, no error
spam. If so, **stop.** §6.4 is optional polish; Phase 2 (pause/resume caching) is **not needed** — its
target subsystems already cost ~0.

---

## 7. Phase 2 — Pause/resume caching (LIKELY UNNECESSARY per Phase 0 — see §6.4)

> Phase 0 showed the subsystems this phase would preserve (collision, instancer) already cost ~0. Keep
> this design on record, but only implement it if §6a + §6b fail to clear the §6.4 gate.


Rework the EXIT/ENTER cycle so a tab switch **suspends** rather than destroys. Gated on §4.

### 7.1 State model

Introduce three explicit lifecycle transitions instead of the current binary init/teardown:

- `_initialize()` — first-time build (unchanged; runs once when data first becomes available).
- `_suspend()` — called from EXIT_TREE for a **detach**. Stops per-frame work; keeps built structures.
- `_resume()` — called from ENTER_TREE when structures already exist. Re-registers world-bound
  resources and resumes processing; does **not** rebuild collision/instancer/shader.

Keep a `bool _built` (distinct from `_initialized`) that stays true across suspend/resume and is only
cleared in `_destroy()` / `PREDELETE`.

### 7.2 EXIT_TREE → `_suspend()`

Replace the unconditional destroys ([`pasture_3d.cpp:1351`–`1363`](src/pasture_3d.cpp)) with:

- `set_physics_process(false)` (keep).
- **Do not** destroy instancer, collision, or meshers. Their child nodes / RIDs travel with the
  detached terrain node and are inert while out of the world.
- World-bound resources that become invalid on `EXIT_WORLD` (mesher visual instances tied to the
  `World3D` scenario, the two SubViewports) may be left in place — they re-validate on re-enter — OR
  torn down if profiling shows they must be. Prefer leaving them; verify no orphaned RIDs.
- Assets/material `uninitialize()` is a cheap `_terrain = nullptr` today; keep or drop as needed, but
  **do not** free the compiled shader.

### 7.3 ENTER_TREE → `_resume()` vs `_initialize()`

- If `!_built` → `_initialize()` (first build, as today).
- If `_built` → `_resume()`: re-point subsystems at `this`, re-register world-bound instances, call
  `snap()` ([`pasture_3d.cpp:781`](src/pasture_3d.cpp)) and `_terrain_mesher->update()`, resume physics
  process. No collision/instancer/shader rebuild.

### 7.4 Real teardown

`PREDELETE` ([`pasture_3d.cpp:1375`](src/pasture_3d.cpp)) remains the authoritative free path and is
unchanged. Because dormant tabs are acceptable (§3.3), no timer/eviction is needed; a backgrounded
terrain simply holds its memory until its scene is closed (node deleted → PREDELETE).

### 7.5 Risks specific to Phase 2

- **World3D re-binding.** Mesher/SubViewport RIDs created under one `World3D` scenario must be valid
  after `EXIT_WORLD`/`ENTER_WORLD`. Audit `Pasture3DMesher` and the SubViewport setup
  ([`pasture_3d.cpp:246`,`:312`](src/pasture_3d.cpp)) for scenario/space assumptions; re-register in
  `_resume()`.
- **Save serialization.** Runtime children (`StaticBody3D`, MMIs) set `owner`
  ([`pasture_3d_collision.cpp:257`,`:307`](src/pasture_3d_collision.cpp)). Confirm keeping them resident
  across detach doesn't cause them to be written into the `.tscn` on save (this is pre-existing behavior;
  verify Phase 2 doesn't make it worse — `NOTIFICATION_EDITOR_PRE_SAVE` handling at
  [`pasture_3d.cpp:1310`](src/pasture_3d.cpp)).
- **Stale data on resume.** If the user edits data via script while a tab is dormant (unlikely in the
  editor), `_resume()` must honor the dirty counters from §6.3 and rebuild the dirty subset.

---

## 8. Testing / verification

Manual, in-editor (no runtime surface for unit tests). Build: `python -m SCons` (per project memory;
`scons` is not on PATH).

1. **Baseline:** with Phase 0 instrumentation, record per-subsystem µs switching between
   `big_regions.tscn` and `sculpting_2.tscn` (both large; already in `project/`).
2. **After each Phase 1 guard:** re-record; confirm the targeted term drops to ~0 and no visual/edit
   regression (sculpt a stroke, move an object, toggle a layer, save+reload).
3. **Regression checks** every phase:
   - Sculpt brush still picks correctly (mouse-picking viewport intact).
   - Object snapping (`Pasture3DObjects` children reposition on edit).
   - Collision: with the Phase-1 setting **on**, editor raycasts still hit; with it **off** (default),
     game/exported collision unaffected — verify by running the scene.
   - Save → close → reopen scene: no duplicated `StaticBody3D`/MMI nodes, no orphaned RIDs (check for
     RID leak warnings on quit).
4. **Multi-tab:** ≥3 open scenes, at least two with terrain; rapid tab cycling stays responsive.

**Acceptance:** perceived tab-switch freeze < 100 ms on the largest test scene, with all regression
checks green.

---

## 9. Rollout

- Phase 0 instrumentation can land immediately (debug-gated, no behavior change).
- Phase 1 items land independently, each behind its own commit and re-measured.
- Phase 2 lands only if §6.4 gate fails, on its own branch, with the §7.5 audit completed first.

## 9a. Related errors surfaced during measurement

1. **`terrain_brush.gd:451` — `Cannot call method 'create_timer' on a null value`** (paired with
   `node.h:559 - Parameter "data.tree" is null`). **Same root cause as the freeze** — now fixed by
   §6.2. Not a separate item.
2. **`node_3d.cpp:649` — `Condition "!is_inside_tree()" is true. Returning: Transform3D()` (spam).**
   Seen only under rapid multi-tab switching (not in the single-switch repro). A global-transform query
   on a detached `Node3D`. Likely the same churn; if it persists after §6, find the caller (a connector
   or the objects helper reading `global_position`/`global_transform` while detached) and guard on tree
   membership. **Deferred** — address after this work if still present.

## 10. Open questions

- Does any third-party addon in the project raycast the terrain body in-editor? (Assumed no per §3.2;
  the default-off setting in §6.1 is the escape hatch.)
- Confirm `Pasture3DMesher` visual instances survive `EXIT_WORLD`/`ENTER_WORLD` without explicit
  re-registration before committing to §7.2's "leave in place" option.
