# Pasture3D Pond Water Offset Spec (`Pasture3DPond.water_offset`)

**Status:** **IMPLEMENTED 2026-08-23**, on `feat/dla-frozen-growth`. Headless-verified:
`bench/PondWaterOffsetCheck.tscn` **PASS, 0 failures, 8/8 criteria**, and each of the three ways the
feature can be broken fails a different set of them (§7.3). Target: Godot 4.7, Pasture3D `main`.

**Deviation from the spec as written, deliberate:** an eighth criterion, **W8**, was added during
implementation. W1–W7 all used a single-loop fixture, so none of them could tell `_apply_water_offset`'s
per-spline loop from an implementation that only ever touched `_get_splines()[0]`. W8 gives one pond two
loops with *different* rims, so "both pools followed" and "one pool was written twice" read differently.

**Goal:** put the pond's water level on the pond. One number on `Pasture3DPond` that says how far below
the rim the water sits, that moves water which already exists, and that never touches the carve.

---

## 1. What is wrong today

Nothing is broken. The level is *reachable* — it is just not on the tool that owns it.

A `Pasture3DPond` carves a basin and, if `auto_add_water` is on, presses Add Water for you
([pasture3d_pond.gd:122](project/addons/pasture_3d/connectors/pasture3d_pond.gd:122)). The resulting
`Pasture3DPool` is seated by `fit_to_curve()`
([pasture3d_water_body.gd:1123](project/addons/pasture_3d/connectors/pasture3d_water_body.gd:1123)) at:

```
    water y  =  lowest baked point of the loop, in world y   +   fill_offset
             =  rim                                          +   (-0.5)      # the default
```

So a stock pond is 4 m deep (`height = 4.0`, set in `_init`) with its surface 0.5 m under the rim, and
**every way to change that lives on the other node**:

| To move the water you must | and then |
|---|---|
| select the `PondWater` child in the Scene dock | find `fill_offset` under **Shape** — not **Water** |
| type a new value | press **Fit to Curve**, because `level_from_spline` is off by default |
| do it again per spline | a multi-spline pond has one pool each |

Three of those four steps are the same decision stated again, and the second is the one people miss:
`fill_offset` alone changes nothing until something re-levels the body. That is the same shape of
complaint that produced `Pasture3DPond` in the first place (see the file header: *"Three non-obvious
steps, two of which are the same decision stated twice"*). The pond fixed it for the carve and left it
standing for the water.

**The concrete ask:** set the water height relative to the brush, so it can be offset.

---

## 2. The reference frame, and why it is the rim

The offset is measured **from the loop's lowest rim point, downward-negative**:

```
  rim  ────────┬──────── y = curve_min_y            water_offset =  0.0  → brim-full
               │  ▲ water_offset                    water_offset = -0.5  → the shipped default
  water ═══════╪════════ y = curve_min_y + water_offset
               │
  floor  ──────┴──────── y ≈ curve_min_y − height   water_offset = −height → dry
```

Useful band: `[-height, 0]`. Outside it the pond is either dry or spilling, and §6 warns about both.

Three alternatives were considered and rejected:

- **Relative to the Pond node's own Y.** This is the literal reading of "relative to the brush" and it
  is the one that does not work. `relative_to_terrain` defaults to **true**, so the carve is measured
  from the per-pixel ground, not from the node — the node's Y is free to be anywhere and usually is.
  A water level pinned to it would drift away from its own basin the moment someone dragged the brush.
- **Relative to the basin floor ("water depth").** Reads well — `water_depth = 3.5` — but it is derived
  from `height`, so deepening the carve from 4 m to 8 m would silently *raise* the surface 4 m. The
  level would depend on two properties instead of one.
- **A 0..1 fill fraction.** Scale-free, but you cannot type "1.5 m below the rim", which is the thing
  people actually want to type.

The rim frame has a property none of the others do: **it maps 1:1 onto the pool's existing
`fill_offset`** ([pasture3d_water_body.gd:107](project/addons/pasture_3d/connectors/pasture3d_water_body.gd:107)).
There is no conversion, so the brush dial and the pool dial cannot disagree, and a user who opens the
pool to check sees the same number they typed on the brush.

---

## 3. The property

On `Pasture3DPond`, in a new `Water` group beside `auto_add_water`:

```gdscript
@export_group("Water")

## Metres from the loop's lowest rim point to the water surface. Negative sits the water below the
## rim, which is where a basin's water actually is; 0 is brim-full and anything above spills.
##
## This IS the pool's `fill_offset` -- same frame, same sign, same number -- pushed onto whatever
## Pasture3DPool this pond owns, and applied again as the seed when Add Water next fires. Reading it
## on the pool is reading this value back.
##
## The useful band is [-height, 0]. Past -height the surface is under the basin floor and the pond is
## dry; above 0 it is over the rim and will pour out of the low side. Both are warned about rather
## than clamped -- a pond mid-edit passes through both, and a dial that fights you while you type is
## worse than one that tells you what you did.
##
## Does nothing on a pond whose loop has been OPENED. An open curve becomes a Pasture3DStream, whose
## surface comes from the banks it flows between and whose `fill_offset` is the no-terrain fallback
## (pasture3d_stream.gd:1341 greys it out for exactly this reason).
@export var water_offset: float = -0.5:
	set(v):
		water_offset = v
		_apply_water_offset()
		update_configuration_warnings()
```

**The default is `-0.5`, matching `Pasture3DWaterBody.fill_offset`.** Not a new opinion about ponds —
this change must not move the water in any scene that already exists. §7 gates that.

**Named `water_offset`, not `fill_offset`.** The Mound this inherits from already has an `edge_offset`
that shifts the carve boundary, and the water body has a *different* `edge_offset` that grows the mesh
past the curve. A bare `fill_offset` on the brush joins a crowd of offsets that mean different things;
the `water_` prefix is the whole disambiguation.

---

## 4. Making it live

### 4.1 The push

```gdscript
## Push water_offset onto the pools this pond owns, and re-level them.
##
## One-way, and only on change. See §4.3 for why it is not applied on load.
func _apply_water_offset() -> void:
	if not is_inside_tree() or not is_configured():
		return
	for s in _get_splines():
		var p := pool_for_spline(s)
		if p == null:
			continue
		# A Pasture3DStream's fill_offset is a fallback the banks override, and read-only whenever
		# there is terrain. Writing it would look like it worked.
		if p is Pasture3DStream:
			continue
		if not is_equal_approx(p.fill_offset, water_offset):
			p.fill_offset = water_offset
		p.level_to_spline()
```

`pool_for_spline()` already exists
([pasture3d_terrain_brush.gd:2751](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:2751)) —
it walks `POOL_GROUP` looking for a body whose `source_spline` is this path. Nothing new is needed to
find the water.

### 4.2 `level_to_spline()` — one small addition to `Pasture3DWaterBody`

`_apply_spline_level()`
([pasture3d_water_body.gd:1171](project/addons/pasture_3d/connectors/pasture3d_water_body.gd:1171))
is already exactly the right operation — Y only, guarded on an actual change — and is unreachable
because it is private and gated on `level_from_spline`. Split the gate out of the operation:

```gdscript
## Move this body's Y onto the level its spline implies, now, whatever level_from_spline says.
##
## Y ONLY, and that is what makes it cheap: NOTIFICATION_TRANSFORM_CHANGED treats a Y move as needing
## no rebuild (the mesh is built flat in local space and the surface height IS this node's Y), so this
## is a transform write and a domain-origin update, not a re-mesh. Fit to Curve is the version that
## also re-seats XZ, which is a bigger act and stays a button press.
func level_to_spline() -> void:
	var level := _spline_level()
	if is_finite(level) and not is_equal_approx(level, global_position.y):
		global_position.y = level


func _apply_spline_level() -> void:
	if level_from_spline:
		level_to_spline()
```

Why not just call the existing `fit_to_curve()`? Because it re-seats XZ as well, and its own docstring
explains that it is *"never automatic"*. A `water_offset` edit should move the level and nothing else.

**Known cost, not fixed here.** `fill_offset`'s setter calls `_schedule_rebuild()`. For a level change
that is spurious — the mesh is flat and local, and its geometry does not read `fill_offset` at all on a
`Pasture3DPool`. It is debounced (`REFRESH_DELAY`), so dragging the spinner costs one rebuild after the
drag settles, which on the 4 km² lake of `PASTURE3D_POND_LARGE_LAKE_SPEC.md` is the 244 ms class. Real
but tolerable; removing the rebuild from that setter is a `Pasture3DWaterBody` change with a `Stream` to
consider (there it *is* geometry, via `_ribbon_depth`) and belongs in its own change.

### 4.3 On load: do not push

`_apply_water_offset()` is called from the setter and from nowhere else. Specifically it is **not**
called from `_ready()`.

The setter runs during deserialisation too, before children exist — `is_inside_tree()` makes that a
no-op, which is why the guard is there and not merely defensive. But the deeper reason is that on load
there is nothing to fix: the pool has its own saved `fill_offset` and its own saved transform, and both
are already whatever the last edit made them. A push on `_ready` would instead re-derive the level from
the *current* rim on every scene open — and the brushes re-snap their spline points to the terrain
surface, so the rim moves. That is precisely the drift `fit_to_curve()`'s "never automatic" note exists
to prevent, reintroduced through a side door and firing on scene load rather than on a button.

If the two have drifted apart — because someone edited the pool directly, or because the terrain under
the rim changed — §6 says so and the button in §5.1 fixes it.

### 4.4 Undo comes for free, and this is a design constraint

An inspector edit to `water_offset` is wrapped by Godot in its own undo action over that one property.
The pool writes the setter performs are **not** in that action.

They do not need to be, because the pool's level is a **pure function of `water_offset` and the rim**.
Undo restores the old `water_offset`, the setter runs again, and the water moves back. The side effect
is idempotent and derived, so it rides the property's undo without any `create_action` of its own.

This is the reason `_apply_water_offset()` must stay derived. Any future version that accumulates
(`p.fill_offset += delta`), or that remembers what it pushed last, breaks undo silently — the property
would revert and the water would not. **Criterion W6 gates it.**

The one case this does not cover: if the user hand-edits `pool.fill_offset` and *then* undoes a
`water_offset` change, the hand edit is overwritten. That is the honest consequence of a one-way dial
and is documented on the property rather than defended against.

---

## 5. Seeding new water

`_build_pool_for()`
([pasture3d_terrain_brush.gd:2857](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd:2857))
builds the pool detached, and `_apply_add_water()` calls `fit_to_curve()` once it is in the tree — which
reads `fill_offset`. So seeding is a matter of setting the property before insertion, and the level
follows.

Add a hook on the **base** class rather than overriding `add_pool_now` on the Pond, so the loop, the
idempotency and the undo wrapping are not duplicated:

```gdscript
# --- in Pasture3DTerrainBrush ---

## The fill_offset a pool created by this brush should start with, or NAN for "leave the default".
##
## On the base class because a brush that carves knows how deep its basin is and the water body does
## not. Returning NAN rather than -0.5 keeps the default in ONE place -- the water body's own property
## -- so a brush that has no opinion cannot pin an old default by restating it.
func _pool_fill_offset() -> float:
	return NAN


# --- inside _build_pool_for, right after `pool.source_spline = p_spline`, ABOVE the is_river branch ---
var seed_fill := _pool_fill_offset()
if is_finite(seed_fill):
	pool.fill_offset = seed_fill
```

```gdscript
# --- in Pasture3DPond ---

func _pool_fill_offset() -> float:
	return water_offset
```

It sits above the `is_river` branch so it seeds **both** kinds, even though §4.1 skips streams on the
later pushes. That asymmetry is deliberate: at creation there is nothing else to seed a stream's
fallback level from, so the brush's number is the best available answer. Afterwards the banks are
answering, and overwriting a value they override would only look like it worked.

### 5.1 A Level Water button

```gdscript
## Re-level this pond's water on water_offset, now. For after the terrain under the rim has moved, or
## after the pool was edited by hand -- the two cases the on-change push deliberately does not chase.
@export_tool_button("Level Water") var _level_btn = level_water


func level_water() -> void:
	_apply_water_offset()
	update_configuration_warnings()
```

Not a substitute for the live dial and not a second press for the normal path. It exists because §4.3
chose not to chase drift automatically, and a decision like that needs a manual escape or it is just a
missing feature.

---

## 6. Configuration warnings

`Pasture3DPond._get_configuration_warnings()` already exists
([pasture3d_pond.gd:144](project/addons/pasture_3d/connectors/pasture3d_pond.gd:144)) for region
coverage. Three more, all about `water_offset`:

| # | Condition | Warning |
|---|---|---|
| **1** | `water_offset > 0.0` | *"The water surface is %.2f m above the loop's lowest rim point, so it is over the edge of the basin — it will pour out of the low side and read as a plane clipping through the bank. Lower `water_offset` below 0."* |
| **2** | `water_offset <= -height` | *"The water surface is at or below the basin floor implied by `height` (%.2f m), so this pond is dry — the mesh is buried and nothing will be visible. Raise `water_offset` above -%.2f."* |
| **3** | a pool exists whose `fill_offset` differs from `water_offset` by more than 0.001 | *"'%s' sits at fill_offset %.2f but this pond's `water_offset` is %.2f. The brush pushes only when the value changes, so a hand edit on the pool stays. Press Level Water to re-apply, or set `water_offset` to %.2f."* |

Warning 2's threshold is `height` and it is approximate on purpose: the floor is at *per-pixel terrain*
− `height`, while `water_offset` is measured from the *lowest baked rim point*. Those coincide on flat
ground and diverge on a slope, so the warning is a "you have gone past the depth you asked for" signal,
not a geometric proof. It says `implied by height` for that reason.

Warning 3 is the one that pays for §4.3. Without it, "the pond says −2 and the water is at −0.5" is a
silent disagreement between two nodes.

`water_offset` is **not clamped**. A pond being dragged from 4 m to 12 m deep passes through the dry
band on the way, and a clamp would eat the value the user typed and hand back a different one.

---

## 7. Exit gate

Extends `project/bench/PondBrushCheck.gd` / `.tscn` — the existing pond gate, which already runs a plain
`Pasture3DMound` as its control for every criterion.

Parse-check first (a GDScript parse error does not fail fast; the run hangs):

```bash
G:\LaughingRooster\GodotVersions\Godot_v4.7-stable_win64\Godot_v4.7-stable_win64_console.exe --headless --path project --check-only --script bench/PondBrushCheck.gd
```

```bash
G:\LaughingRooster\GodotVersions\Godot_v4.7-stable_win64\Godot_v4.7-stable_win64_console.exe --headless --path project bench/PondBrushCheck.tscn
```

The fixture needs a real terrain and a real closed loop, because every criterion here is about a *world
y*. `bench/PondCarveCheck.tscn` already builds one; the water criteria go in a scene that reuses that
fixture rather than into the property-only `PondBrushCheck`, if the two cannot share.

### 7.1 Criteria

| # | Claim | Control that must fail |
|---|---|---|
| **W1** | A pond with `water_offset = -2.0` seeds a pool at `rim − 2.0` (±1 mm). | A plain `Pasture3DMound` with the same loop, same press, seeds at `rim − 0.5`. Without it, W1 passes on any pond whose default happens to be −2.0, and on a `_pool_fill_offset()` hook that is never called. |
| **W2** | Writing `water_offset = -3.0` on a pond that **already has water** moves the pool to `rim − 3.0` and leaves `pool.fill_offset == -3.0`. | Same write on the Mound's pool, via a property the Mound does not have: its pool must **not** move. Plus: assert the pool's Y actually *changed* from its W1 value — a fixture where the two levels coincide measures nothing. |
| **W3** | Changing `water_offset` does not change the carve. Sample baked height at basin centre and at four rim-adjacent points before and after; all identical. | The same probe run across a change to `height` must report a **difference**. A "before == after" probe reading a stale or unbaked buffer reports W3 green forever otherwise. |
| **W4** | The default is inert. A pond constructed with no property writes seeds a pool at exactly the level a pre-change pond would have: `rim − 0.5`. | Read the two defaults from the **classes** — `Pasture3DPond.new().water_offset` against a bare `Pasture3DPool.new().fill_offset` — not each against the literal −0.5. Literals on both sides keep passing after someone changes one of them. |
| **W5** | Warnings fire and stop firing. `+1.0` → warning 1 only; `-height` → warning 2 only; `-0.5` → neither; a hand-edited pool → warning 3. | The default pond raises **zero** water warnings. And count the warnings, do not substring-match one — a warning function that returned all three unconditionally would pass a substring test three times over. |
| **W6** | The push is derived, not accumulated. Write `-2.0`, then `-3.0`, then `-2.0` again: the pool ends at exactly `rim − 2.0`, bit-identical to the first write. | Run the same three writes against a deliberately accumulating variant (`fill_offset += delta`) inside the gate and show it lands somewhere else. This is the undo criterion (§4.4) measured without an editor, because `EditorUndoRedoManager` does not exist headless. |
| **W7** | An **open** loop is not silently mis-served. A pond whose curve is opened produces a `Pasture3DStream`; writing `water_offset` must not move the stream's surface and must not error — but its fallback level **was** seeded at creation (§5). | A closed-loop pond in the same fixture, same write, **does** move. Without it W7 passes on a build where the write does nothing anywhere. |
| **W8** | A pond with **two** loops moves **both** pools, each onto its own rim. | The two loops are given different rims (6 m apart) and the gate refuses to run if they are not. With equal rims, "both followed" and "one pool written twice" are the same number. Added during implementation — see the status header. |

Count completed sub-cases and compare against the expected count. A GDScript runtime error abandons the
function without incrementing the failure count, so a criterion that throws otherwise reads as a pass.

### 7.2 The break tests — what a green run is worth

Eight green criteria are worth nothing on their own. Each of the three ways this feature can be broken
was applied to the shipped code and the gate re-run; each failed a **different** set, and each left the
criteria it has no business failing green.

| Break | Failed | Still green, correctly |
|---|---|---|
| `_apply_water_offset()` returns immediately — the live dial does nothing | W2, W5, W7 control, W8 | W1, W3, W4 (the seed path is independent of the push) |
| `Pasture3DPond._pool_fill_offset()` returns `NAN` — new water is not seeded | W1, W6, W7 seed | W2, W3, W4, W5, W8 (the push still works) |
| `level_to_spline()` returns immediately — `fill_offset` is written, nothing re-levels | W2, W6, W7 control, W8 | W1, W4, W5 (`fill_offset` still reads back, so the numbers agree) |

**W6 was vacuous when written and the first break test proved it.** "Writing −2, −3, −2 lands back at
−2" is trivially satisfied by a push that never moves anything — the water never left. It now also
asserts the *intermediate* write moved the pool, and that sub-check is what caught break 3.

### 7.3 What this gate cannot reach

- **The inspector's undo action.** `EditorUndoRedoManager` does not exist headless, so W6 gates the
  *mechanism* undo depends on (an idempotent, derived push) rather than the Ctrl+Z itself. State that in
  the gate output; check the actual keystroke by hand once.
- **`_ready`-time behaviour under `Engine.is_editor_hint()`.** `_seed_setup` is editor-only
  ([pasture3d_pond.gd:89](project/addons/pasture_3d/connectors/pasture3d_pond.gd:89)), so a headless run
  never auto-seeds and must call `add_pool_now()` directly. The gate therefore proves nothing about
  auto-seeded water; say so, and hand-check that dropping a Pond in the editor with a non-default
  `water_offset` lands its water at the right level first time.
- **Whether the water looks right.** Depth drives the shader's colour and shore foam. A pond set 3.9 m
  below a 4 m rim is a puddle over a floor and will read differently from what the numbers suggest; that
  is an eyes-on check in `sculpting_2`, not a gate criterion.

---

## 8. Out of scope

- **A gizmo handle for the water level.** Dragging the surface in the viewport is the natural next step
  and is a `Pasture3DBrushGizmo` change (`PASTURE3D_BRUSH_GIZMO_SPEC.md`), not this one.
- **Removing the spurious rebuild from `fill_offset`'s setter** (§4.2).
- **Hoisting `water_offset` to `Pasture3DTerrainBrush`.** The `_pool_fill_offset()` hook is on the base
  class so any brush *can* have one; only the Pond gets the property. Giving every brush a water dial is
  a bigger decision — the same one `_region_coverage()` deferred in
  `PASTURE3D_POND_LARGE_LAKE_SPEC.md` §2.
- **Two-way binding with the pool.** Rejected: two nodes that each write the other's value have no
  answer for which one is right after a load.
- **Auto-levelling when the terrain under the rim moves.** §4.3 and §5.1.
- **A dynamic `@export_range` hint spanning `[-height, 0]`.** It would make the slider mean something,
  but `height` lives on `Pasture3DMound` with no setter, so the hint would need one added purely to call
  `notify_property_list_changed()` — a change to the parent class for a cosmetic gain on the child.

---

## 9. Files touched

| File | Change |
|---|---|
| [pasture3d_pond.gd](project/addons/pasture_3d/connectors/pasture3d_pond.gd) | `water_offset` property, `_apply_water_offset()`, `_pool_fill_offset()` override, `level_water()` + button, three warnings in `_get_configuration_warnings()` |
| [pasture3d_water_body.gd](project/addons/pasture_3d/connectors/pasture3d_water_body.gd) | `level_to_spline()` extracted from `_apply_spline_level()` (§4.2) |
| [pasture3d_terrain_brush.gd](project/addons/pasture_3d/connectors/pasture3d_terrain_brush.gd) | `_pool_fill_offset()` virtual; three lines in `_build_pool_for()` |
| `project/bench/` | W1–W7 (§7) |
| [PASTURE3D_WATER_BODIES_SPEC.md](PASTURE3D_WATER_BODIES_SPEC.md) | §7.8 step 5 now reads the brush's `_pool_fill_offset()` |
| [PASTURE3D_WATER_GUIDE.md](PASTURE3D_WATER_GUIDE.md) | "setting a pond's level" points at the brush, not the pool |

No C++. No DLL rebuild.
