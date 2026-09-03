# Pasture3D Brush Gizmo — Tangent-Edit Stall & Spline Handle Correctness

**Document:** `PASTURE3D_BRUSH_GIZMO_INPUT_SPEC.md`
**Status:** **BUILT** (P1–P4) 2026-09-02. P1 gate `BrushTangentDirtyGate` green 4/4; P2/P3 gates
`GizmoMarkerGate` [DK] and [DL] green (6/6 total); `RoadPerfRegressionGate` and `MarginSeamGate`
still green. **P4 carries no gate by design** — it removes a per-event allocation and asserts
nothing new; verified by parse-check and a clean headless editor load, not by measurement.
**References:** `PASTURE3D_BRUSH_GIZMO_SPEC.md`, `PASTURE3D_BRUSH_GIZMO_SUBGIZMO_PHASES.md`,
`PASTURE3D_LAYER_AND_BRUSH_PERF_SPEC.md` (the dirty-rect bake this document narrows)
**Files:** `addons/pasture_3d/connectors/pasture3d_terrain_brush.gd`,
`addons/pasture_3d/src/brush_handles.gd`, `addons/pasture_3d/src/brush_gizmo.gd`,
`addons/pasture_3d/src/editor_plugin.gd`, `bench/GizmoMarkerGate.gd`
**Phases:** P1 (the stall) · P2 (selection bookkeeping) · P3 (one picker) · P4 (per-event selection scan)
**Gates:** `bench/BrushTangentDirtyGate.tscn` (P1) · `bench/GizmoMarkerGate.tscn` [DK], [DL] (P2, P3)

---

## 1. The stall, and why dragging a point is fast while double-clicking one is not

Double-clicking a spline point toggles it between a corner and a smooth curve
(`editor_smooth_point`). It stalls the editor. Dragging the *same* point with the subgizmo does the
same amount of curve mutation, the same undo bookkeeping, the same gizmo redraw and the same bake —
and does not stall. The whole difference is one line of cache shape.

The dirty-rect bake decides how much terrain to repaint from `_moved_point_indices(path)`, which
diffs the curve against `_curve_cache`. `_curve_cache` is filled by `_curve_point_array`, and that
function records **positions only**:

```gdscript
# pasture3d_terrain_brush.gd:2522
func _curve_point_array(path: Path3D) -> PackedVector3Array:
	for i in range(c.point_count):
		out.append(c.get_point_position(i))   # in/out tangents are not recorded
```

A tangent edit changes `get_point_in` / `get_point_out` and leaves every position identical. So:

1. `_moved_point_indices` reaches "Case 4: same count, point positions changed" (line 2572), finds
   nothing unequal, and returns an **empty** array.
2. `_spline_dirty_aabb` sees `moved_indices.is_empty()` (line 3346) and takes its whole-spline
   fallback: `_spline_footprint_aabb(path)`, merged with the previous painted box.
3. `_refresh_owner_rect` snaps that to tile boundaries and clears + repaints **the entire spline
   footprint**, and every layer-mate overlapping it.

A position drag of the same point returns one index and repaints roughly two segments. The cost
ratio is therefore the ratio of the whole spline to two of its segments — which is exactly why the
symptom scales with how long the spline is, and why nobody noticed it on a four-point test mound.

This applies to **every** tangent-only edit, not just the double-click: dragging an in/out handle,
`Shift`-breaking symmetry, and the undo of any of them all take the same whole-spline path. The
double-click is merely the cheapest gesture that triggers the most expensive bake, so it is where it
reads as a stall rather than as drag lag.

### 1.1 What is *not* the cause

Ruled out by reading, so that P1 does not start by re-litigating them:

- **Gizmo redraw.** `Sprites._sprite_material`, `_dot_texture` and `sprite_for` are all interned;
  `pick_meshes` is digest-cached and the road chunk list still holds the previous meshes at edit
  time, so the uncached fallback strip in `brush_gizmo.gd:135` does not run here. The per-redraw
  `generate_triangle_mesh()` is a twelve-triangle box.
- **Debounce.** `_arm_refresh_timer` is idempotent and the two `set_point_*` calls land in one
  `REFRESH_DELAY` window, so the toggle causes one bake, not two.
- **`Curve3D` re-baking.** Real, but small next to a full-footprint composite, and shared with the
  drag path that does not stall.

---

## 2. P1 — make a tangent edit a tangent-sized repaint

### 2.1 Record tangents in the curve cache

`_curve_point_array` returns three vectors per point instead of one, interleaved
`[pos, in, out, pos, in, out, ...]`:

```gdscript
## Flat [position, in, out] triples, one per curve point, in point order. The tangents are in the
## array because the dirty-rect diff is the only consumer and a tangent-only edit MUST be visible to
## it — a curve whose handles moved and whose positions did not used to diff as "nothing moved",
## which sent every tangent edit down the whole-spline repaint path. See §1.
func _curve_point_array(path: Path3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var c: Curve3D = path.curve if is_instance_valid(path) else null
	if c == null:
		return out
	out.resize(c.point_count * 3)
	for i in range(c.point_count):
		out[i * 3] = c.get_point_position(i)
		out[i * 3 + 1] = c.get_point_in(i)
		out[i * 3 + 2] = c.get_point_out(i)
	return out
```

This is a stored-format change with three readers. All three must move together or the diff silently
compares strides:

| Reader | File:line | Change |
|---|---|---|
| `_moved_point_indices` | 2535 | Point count is `size() / 3`; a point is unchanged only when all three of its vectors compare equal. The insert/remove cases compare triples, not vectors. |
| `_spline_dirty_aabb` prev-expansion | 3379–3386 | `prev[k]` becomes `prev[k * 3]`, and the loop bound `prev.size() - 1` becomes `prev.size() / 3 - 1`. It must also expand by the previous `prev[k*3+1]` / `prev[k*3+2]` offsets, or shrinking a long tangent leaves the old cut unpainted. |
| Anything else reading `_curve_cache` | `grep -n "_curve_cache" ` | Audit before editing; a reader that assumes one-vector-per-point and is missed here produces a *wrong* box, not an error. |

`_spline_dirty_aabb`'s forward expansion (3371–3376) already reads `get_point_in`/`get_point_out` for
the moved indices, so the new box is correct for a tangent edit as soon as the index reaches it.

### 2.2 Report the tangent's reach, not just its endpoint

The box currently grows to `position + in` and `position + out`. A cubic bezier stays inside the
convex hull of its four control points, so those two corners plus the neighbours' corners already
bound the curve — but `_total_padding()` must still be applied to the tangent corners, exactly as it
is to the position corners. Confirm it is (the `pad` at line 3357 is applied once at the end; if it
is not applied to the tangent-derived corners the cut is under-cleared by the brush width).

### 2.3 One curve mutation, one undo entry

`editor_smooth_point` registers two do-methods and two undo-methods (`set_point_in`, `set_point_out`).
Each emits `changed`. Add a single brush method and register that instead:

```gdscript
## Set both tangents of one curve point in a single mutation, so the toggle is one undo step and one
## `changed` emission rather than two of each.
func editor_set_point_tangents(path: Path3D, idx: int, p_in: Vector3, p_out: Vector3) -> void:
```

The debounce already collapses the two emissions, so this is not where the time goes — it is here so
that the undo history reads as one action and a future non-debounced caller cannot re-introduce a
double bake.

### 2.4 Gate — `BrushTangentDirtyGate.gd` (bench)

House discipline: every criterion carries a control that must fail if the path is dead, and the
suite counts completions so a run of zeros reports "measured nothing".

| Criterion | Measure | Pass | Control that must fail |
|---|---|---|---|
| **A. A tangent edit is seen as a change** | `_moved_point_indices` after setting `point_in` on index 4 of a 12-point spline | returns `[4]` (or `[3,4,5]` — a superset of the touched point, never empty and never all 12) | The same call with **no** edit at all must return `[]`. If both answer the same, the diff is not reading tangents. |
| **B. The dirty box is local** | `_spline_dirty_aabb(path, moved, prev).size.x` for that edit, against `_spline_footprint_aabb(path).size.x` on a spline ≥ 400 m long | ≤ 0.35 × the whole-spline box | The pre-fix code path (force `moved_indices = []`) must measure ≈ 1.0. A gate that cannot produce the old number cannot claim it improved anything. |
| **C. Shrinking a tangent still clears** | Set a 40 m tangent, cache, set it back to zero, take the box | The box contains the *old* handle's world position | Skip the prev-array expansion and this must fail. |
| **D. Round trip** | Bake, toggle smooth, bake, toggle back, bake; compare the height map to the pre-toggle bake | equal within 1e-3 | Corrupt one sample and the comparison must report it. |

Criterion B is the one that answers the user's complaint, and it is stated as a **ratio** rather than
a wall-clock time so it does not need a benchmark run on a machine that is also running another
engine (see `ask-before-perf-tests`).

---

## 3. P2 — the selection index survives a point removal

`_h.sel_gpi` is a running point index across all of a brush's splines. Two callers change the point
list under it:

- `editor_plugin.gd:447` — the `Delete`/`Backspace` path, which **does** call
  `brush_gizmo.clear_point_selection()`.
- `editor_plugin.gd:494` — the right-click removal path, which **does not**.

After a right-click removal of a point *before* the selected one, `sel_gpi` names what used to be the
next point. `_redraw` then fills the wrong marker, `show_tangents` reveals the wrong point's handles,
and a subsequent `Delete` removes the wrong point. `editor_add_point` has the mirror problem:
inserting before the selection shifts it by one.

**Fix.** Put the invalidation where the mutation is, not at each call site — the call sites are the
thing that keeps being forgotten. `editor_remove_point` and `editor_add_point` both already call
`update_gizmos()`; have them also notify the gizmo plugin's handle state. Since the brush must not
depend on the editor plugin, invert it: `Pasture3DBrushHandles` clears its selection whenever the
resolved point count for `sel_node_id` no longer matches what it recorded at selection time.

```gdscript
## Point count of `sel_node_id`'s splines when the selection was taken. A point added or removed
## anywhere renumbers `sel_gpi`, so a mismatch means the recorded index no longer names the point the
## user picked and MUST NOT be acted on — the Delete key would remove a neighbour.
var _sel_count: int = -1
```

`selected_point()` returns `[null, -1]` on a mismatch, and `show_tangents()` answers `false`. That
makes a stale selection *inert* rather than *wrong*, which is the correct failure for a destructive
key binding, and it covers add, remove, undo of either, and an external edit to the Path3D — none of
which the two call sites would have covered.

`clear_point_selection()` stays as the explicit path.

### 3.1 Gate criteria (extend `GizmoMarkerGate.gd`)

| Criterion | Pass | Control |
|---|---|---|
| **E. Removal invalidates** | Select gpi 5, remove point 2, `selected_point()` → `[null, -1]` | Removing point **8** (after the selection, in a single-spline brush) must *still* invalidate — the count changed. A gate that only tests "before" cannot distinguish this design from an index-fixup one. |
| **F. Selection survives a non-structural edit** | Select gpi 5, drag its tangent, `selected_point()` → the same point | Bump the count artificially and it must go inert. |

---

## 4. P3 — one picker, not two

Three code paths answer "which handle is under the cursor", with two different radii and two
different notions of what is pickable:

| Caller | Uses | Radius | Sees tangents? |
|---|---|---|---|
| `_subgizmos_intersect_ray` | `_h.pick_handle` | `PICK_RADIUS` = 13 | yes |
| double-click toggle, `editor_plugin.gd:467` | `p_brush.pick_point_screen` | 14 | **no** |
| right-click remove, `editor_plugin.gd:494` | `p_brush.pick_point_screen` | 14 | **no** |

Consequences, both real:

- Double-clicking a **visible tangent handle** that lies within 14 px of its own point toggles the
  point — zeroing the very handle the user was aiming at.
- A click can select one handle (13 px, tangent-aware) and toggle a different one (14 px,
  positions-only), because the two pickers disagree about what is nearest.

**Fix.** The double-click and right-click paths call `_h.pick_handle`-derived state, not their own
picker:

- Add `Pasture3DBrushHandles.pick_point(p_node, p_camera, p_point) -> Array` — the same traversal
  and the same `PICK_RADIUS`, collapsed to `kind == 0` (`[path, idx]`), and **pure**: no selection
  mutation, no `update_gizmos`. `pick_handle` becomes `pick_point`'s traversal plus the hidden-handle
  collapse plus `_update_selected_point`.
- `editor_plugin.gd:467` and `:494` call `brush_gizmo.pick_point(brush, camera, mouse_pos)`.
- A double-click whose nearest handle is a **shown tangent** zeroes that one tangent (a sharpen of
  that side) rather than toggling the point. That is the gesture the user was making.
- `Pasture3DTerrainBrush.pick_point_screen` keeps only its remaining caller,
  `pick_brush_screen_distance`. If that turns out to be the only one left, fold it in and delete it —
  deprecated pre-stack code gets removed, not shimmed (`pre-stack-code-gets-deleted`).

The purity split matters beyond tidiness: `_subgizmos_intersect_ray` is a **query** the editor may
call speculatively, and it currently writes `sel_gpi`/`sel_kind` and schedules
`update_gizmos.call_deferred()` from inside it. Keeping the traversal pure and the mutation in one
named place means a future extra query cannot cost a gizmo rebuild.

### 4.1 Gate criterion

| Criterion | Pass | Control |
|---|---|---|
| **G. One answer** | For 200 random screen points around a curve with shown tangents, `pick_point` and `pick_handle`'s `kind == 0` results agree on every point where `pick_handle` returned a position | 100% agreement | Set the old 14 px radius on one of them and the gate must report disagreements. Zero disagreements with zero samples is a fail, so the sample count is asserted. |

---

## 5. P4 — stop scanning the selection on every mouse motion

`editor_plugin._forward_3d_gui_input` calls `_current_brush()` for **every** forwarded event,
including `InputEventMouseMotion`, and `_current_brush()` allocates
`EditorInterface.get_selection().get_selected_nodes()` and type-tests it. `brush_gizmo._brush_selected`
does the same allocation once per `_redraw` and once per `_subgizmos_intersect_ray`.

**Fix.** The plugin already connects to `selection_changed` elsewhere
(`pasture3d_terrain_brush.gd:190`). Cache the current brush on that signal in `editor_plugin.gd`,
validate with `is_instance_valid` at use, and have `brush_gizmo._brush_selected` compare against the
same cached id rather than re-querying.

No gate: this is not a measured claim, it is the removal of a per-event allocation. It is listed so
it lands with the rest rather than as a stray later edit.

**As built**, with one thing the plan did not anticipate. The gizmo cannot conflate "no brush is
selected" with "the plugin has not published a selection yet": the first is a definite no, the second
has to fall back to asking the editor, or a gizmo that draws before the plugin's first callback hides
its handles. So `brush_gizmo.gd` carries `_have_selection` alongside `_selected_brush_id`, and only the
unpublished state falls back to `get_selected_nodes()`.

`set_selected_brush` also clears the recorded handle selection: `sel_gpi` belongs to whichever brush was
selected, and carrying it across a selection change would fill a marker on a brush the user has left.
That is the same rule P2 established, applied to the other way a selection can go stale.

The plugin connects `selection_changed` in `_enter_tree` (and primes it immediately, so a brush already
selected when the plugin loads is live) and disconnects in `_exit_tree`.

---

## 6. Out of scope

Named so they are not folded in by accident:

- **`Curve3D.bake_interval`.** Pasture3D never sets it, so every spline bakes at the 0.2 m default,
  and there are 18 `get_baked_points()` call sites. That is worth its own measurement and its own
  document; it is not the double-click stall and changing it here would confound P1's gate.
- **The road fallback collision strip** (`brush_gizmo.gd:135`). Uncached and O(baked points), but it
  only runs before a road's first successful chunk build.
- **The CPU raymarch per mouse-motion in `_placement_surface_hit`.** Deliberate (see its comment).

---

## 7. Order and why

P1 first and alone: it is the reported symptom, it is a stored-format change with three readers, and
its gate needs the pre-fix ratio measured before anything else moves. P2 and P3 both touch
`brush_handles.gd` and should land together to avoid two overlapping edits to the same pick
traversal. P4 last, as it is the only one that touches the input entry point.

---

## 8. Fixed-point check before calling this done

Toggle a point smooth, then sharp, then smooth again on a 30-point spline over a road brush:

- three bakes, each with a dirty box under criterion B's ratio;
- the height map after toggle 3 equal to the map after toggle 1 (criterion D applied twice);
- undo three times returns the map to the pre-toggle bake;
- the selected point is still the point the user clicked (criterion F);
- and no gizmo rebuild scheduled from inside `_subgizmos_intersect_ray`.
