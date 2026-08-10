# Pasture3D Mound Relief Spec (`Pasture3DMound.relief`)

**Status:** **IMPLEMENTED 2026-08-09.** Headless-verified only — six gates in
`bench/MoundReliefCheck.tscn`, all passing, plus the full 14-gate `bench/PlowReliefCheck.tscn` re-run
unchanged to prove the shared refactor is behaviour-preserving. Not yet looked at in the editor.
Target: Godot 4.7, Pasture3D `main`.

**Goal:** let `Pasture3DMound` stamp the `Pasture3DReliefMaterial`s built for the Plow — craggy fractals,
strata, terraces, dunes, scree, craters — into its own dome or plateau, instead of only the single
`FastNoiseLite` jitter field it has carried since the landscape tools shipped.

**Builds on:** [PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md](PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md), whose op
program, evaluator, selector table and GDScript oracle are reused **unchanged**. This spec adds a second
host for them and says what that host does differently. Read that one first; this is a delta.

---

## 1. Decisions (from the scoping interview, 2026-08-09)

| Question | Decision | Consequence |
|---|---|---|
| Which brushes | **Mound only** | Ridge and Trough are deferred; Splat is excluded outright (§2). The refactor this forces is what makes the others cheap later (§9). |
| How much of the Plow's surface | **TILE mapping + selectors; no SCATTER** | The instance table, its eight inspector properties and `relief_scatter_*` stay Plow-only. Costs less than it sounds: §4. |
| Relationship to the existing noise | **Alongside; `noise` untouched** | Both fields are added. No `Source` enum, no declared-default hazard, no migration step. §3. |

### 1.1 Why Splat is not a candidate

`Pasture3DSplat` has a `noise` / `noise_strength` pair with the same names, which makes it look like a
fourth candidate. It is not. Its noise perturbs a texture blend weight `t` in `[0,1]` that is quantised to
8 bits and encoded into the **control map**
([splat.gd:177](project/addons/pasture_3d/connectors/splat.gd:177)) — no height is involved anywhere in
that brush. A relief material there has nothing to write to.

---

## 2. What stays identical (the interface contract)

1. **A Mound with no relief assigned bakes byte-for-byte what it did before.** Gate A, with the control
   that must fail.
2. **`noise` / `noise_strength` are untouched**, in both the C++ and the GDScript path. The relief term is
   a second addition to the same `amp`, not a replacement branch.
3. **`stamp_mound_loop` keeps its signature.** The program rides in the existing `params` Dictionary, as
   it does for the Plow. No new bound method.
4. **The GDScript fallback stays an exact A/B oracle.** `force_gdscript_raster` selects it; gate D
   compares. Tolerance 1e-4 m, and see §11 for what that tolerance turned out to be measuring.

---

## 3. No migration step, by construction

The Plow needed spec §11 — an explicit placement-flow hook, and a standing warning never to set the
default in `_init()` — because it expressed the feature as a **`Source` enum whose default had to move**.
Godot omits default-valued properties when serialising, so moving that default would silently repoint
every pre-existing node.

Mound has no such problem and deliberately does not acquire one. The feature is expressed as **two
properties that are both inert at their defaults**:

```gdscript
@export var relief: Pasture3DReliefMaterial          # null
@export var relief_strength: float = 0.0             # metres
```

A legacy scene omits both, loads both as their declared defaults, and takes exactly the path it always
took. There is nothing to migrate, no version int, and no creation-route asymmetry — the Create Node
dialog and the toolbar produce identical brushes. Gate A locks this down from both directions: the
defaults are inert, **and** assigning a material changes the result (without that control, a brush that
could not stamp relief at all would report the same clean numbers).

**The cost of this choice** is that assigning a material alone does nothing until `relief_strength` is
also raised — a filled slot over flat ground. That failure mode looks exactly like a broken material, so
the brush raises a configuration warning naming the real cause rather than leaving it to be discovered.

---

## 4. Mapping: TILE only, and why that loses less than it looks

Mound evaluates the op program in **world XZ**, always. Relief therefore stays continuous where two
mounds overlap, which is the behaviour a landform-detail brush wants.

The reason this is not a real restriction is a property of the built evaluator that the Plow's own
documentation obscures. In `relief_eval`, `nu,nv` are derived from the loop's oriented frame in **every**
mapping mode; only `u,v` change
([pasture_3d_brush_raster.cpp:1276](src/pasture_3d_brush_raster.cpp:1276)):

| | `u,v` (metres) | `nu,nv` |
|---|---|---|
| `TILE` | world `x,z` | loop-relative, `[-1,1]` |
| `FIT` | loop-local | loop-relative, `[-1,1]` — *identical* |

Radial ops read `nu,nv`. So a `Pasture3DReliefCrater` under Mound's TILE is still **sized and oriented by
the loop**, exactly as it is under the Plow's FIT. Gate F pins this down — an elongated loop produces an
elongated crater, and swapping the loop's extents inverts the relationship, which an axis-aligned frame
cannot do. TILE-only costs the *domain* difference for `u,v`-reading ops (fractals, dunes, furrows, warp),
which is a texture-continuity choice, not a capability.

Mound therefore does **not** inherit the Plow's "Crater under Tile repeats once per tile" warning, which
does not describe what the code does. See §12.

The oriented frame is still computed per bake, because `nu,nv` need it. `_loop_frame` moved to the base
class for exactly this reason.

---

## 5. Amplitude

```
amp += relief_strength * relief_eval(...) * profile * relief.strength
```

| Term | Why |
|---|---|
| `relief_strength` | Metres, and **deliberately not `height`**. Relief describes the surface texture of the landform; tying its amplitude to the peak would rescale every detail whenever the mound was made taller. Exactly parallel to `noise_strength`. |
| `profile` | The same 0→1 interior mask that already keeps `noise` off the rim — the ramp value, or the clamped interior mask in cone mode. Relief feathers to nothing at the loop edge, so the stamp never cuts a step. Gate B. |
| `relief.strength` | The material's own saved multiplier, so a `.tres` carries its intensity between brushes. |

The Plow's `height_scale * acc * mask * strength` has the same shape; `relief_strength` stands in for
`height_scale`, which Mound does not have.

**Accumulation order is `dome → noise → relief`, identically on both paths.** That is what makes the 1e-4
parity tolerance meaningful rather than an artefact of summing in a different order.

### 5.1 Blend mode interacts with signed relief — and MAX eats half of it

Mound's default `blend_mode` is `MAX` (raise-only). A relief material is **signed**, so under MAX every
sample it carves is discarded and only the raised half survives. A crater on a default Mound produces its
rim and nothing else.

This is correct behaviour for a raise-only blend and is not something the relief path should override —
but it is a genuine trap, and it caught this spec's own gate F on the first run, which reported "the
crater did not dig". Use `ADD` (or `MIN`) for a material that carves. The gates that isolate relief say so
in a comment at each fixture.

---

## 6. Selectors

Inherited whole, including the four `Pasture3DSimResult` channels. The design constraint that matters is
unchanged and is the reason this was cheap:

**A selector reads the surface *below this brush's own layer*, never the finished composite.** Mound
already sends a per-cell `base_below` grid whenever `relative_to_terrain`
([mound.gd:156](project/addons/pasture_3d/connectors/mound.gd:156)) — the exact input the field builder
needs. The only change is that the grid must now also travel when `need_fields` is set but
`relative_to_terrain` is not:

```gdscript
if relative_to_terrain or use_fields:
    params["base_below"] = _base_below_grid(...)
```

Gate E's **re-bake drift line is the result that matters**: 0.00000000 m. If a selector read the composite,
the relief it just wrote would change the slope it reads next time and the bake would creep on every
refresh. This is the same property the Plow's gate K exists to prove, re-proved on the new host rather
than assumed to transfer.

Field grids are built only when the compiled program actually reads them (`_needs_terrain_fields`), so a
plain fractal pays nothing.

---

## 7. Engine changes

`stamp_mound_loop` gains, all read from `params`:

```
"ops" "op_params" "op_luts" "op_selectors"     the compiled program
"relief_strength" "relief_mat_strength"        the two multipliers of §5
"fit_cx" "fit_cz" "fit_cos" "fit_sin"          the oriented frame (for nu,nv)
"fit_ex" "fit_ez"
"need_fields"  "sim_result"                    selector inputs
```

`relief_build` / `relief_fields_build` / `relief_fields_add_sim` / `relief_eval` are called exactly as
`stamp_plow_loop` calls them. **No change to `pasture_3d_relief_ops.{h,cpp}`** — the evaluator was already
brush-agnostic, taking a program and plain coordinates with no plow-specific state. That it needed no
edit is the strongest evidence the Plow spec's §4.5 "one evaluator" decision was right.

The relief block sits after the noise block in the per-cell loop and is skipped entirely when
`relief_strength == 0` or the program is empty, so the untouched path costs one branch on a bool.

---

## 8. Brush changes

```gdscript
@export_group("Relief")
@export var relief: Pasture3DReliefMaterial      # reconnects `changed` -> _schedule_refresh
@export var relief_strength: float = 0.0
```

`_get_configuration_warnings()` gains the shared `_relief_warnings(relief)` (§9) plus the
assigned-but-zero-strength warning of §3.

Live re-bake comes free: the material emits `changed` on every property setter, and the setter wires that
to `_schedule_refresh` — the same pattern as [plow.gd:63](project/addons/pasture_3d/connectors/plow.gd:63).

---

## 9. The refactor: relief plumbing moved to the base class

Every GDScript-side helper the feature needs lived on `Pasture3DPlow`. Nothing in them was plow-specific;
they were simply written where they were first needed. They now live on `Pasture3DTerrainBrush`:

| Moved | Note |
|---|---|
| `_loop_frame` | verbatim |
| `_needs_terrain_fields` | verbatim |
| `_terrain_fields` | verbatim |
| `_sim_fields` | verbatim |
| `PERIOD_SAMPLES_MIN` | verbatim |
| `_sim_result_covers_loop` → `_sim_result_covers_splines` | renamed; it was never loop-specific |
| `_has_crater_op()` → `_relief_has_crater_op(mat)` | takes the material |
| `_finest_period()` → `_relief_finest_period(mat)` | takes the material |
| `_sim_result_for()` → `_relief_sim_result(mat)` | takes the material; the Plow keeps a thin wrapper that adds its `source` gate |

Two things were **extracted** rather than moved, because both hosts need them and the Plow had them
inline: `_relief_warnings(mat)` (the material's own complaint, the sim-result diagnostics, the periodic
resolution guard) and `_sim_result_dict(r)` (the flatten-for-C++ step).

The three that take a material do so rather than reaching for a `relief` property, so the base class does
not acquire an opinion about what its subclasses call their material slot.

**Evidence the move is behaviour-preserving:** the full 14-gate `PlowReliefCheck` re-runs with numbers
identical to the baselines recorded in the Plow spec §13 — A −1.1557, B +5.5771, C −8.0000 / −7.8131 /
+0.7836, D and M 0.00000000, E 9.8736, K 3.0788, L 1.0653, N 1.0000.

---

## 10. Verification gates

Each criterion carries a control that must fail, and each must tell "measured nothing" from "measured
correctly".

```bash
"G:/LaughingRooster/GodotVersions/Godot_v4.7-stable_win64/Godot_v4.7-stable_win64_console.exe" --headless --path project bench/MoundReliefCheck.tscn
```

Last run 2026-08-09, all six: **PASS, 0 failures.**

| Gate | Criterion | Control that must fail | Result |
|---|---|---|---|
| A | Defaults inert; a plain Mound bakes unchanged and idempotently | assigning a material must change the result | dome +18.0000, drift 0.00000000, control +1.9167 |
| B | Relief deforms the interior, feathers at the rim, idempotent | `relief_strength = 0` returns to baseline | interior +2.7105, outside +0.0000, drift 0.00000000, control +0.00000 |
| C | Relief and noise **superpose** — the height relief adds is the same with and without a noise field | both spans must be non-zero | worst 0.00000191 m; spans relief 2.7641 / noise 0.8538 |
| D | Native vs GDScript oracle, ≤ 1e-4 m | probes must carry real deformation | see §11 |
| E | A slope selector confines relief to steep ground, and the bake does not drift | ungating must bring flat ground back | steep 1.2847 / flat 0.0000; drift 0.00000000; ungated flat 0.5659 |
| F | A Crater under TILE is sized and oriented by the loop | swapping the loop's extents must invert the two probes | centre −8.0000; long −7.8131 vs short +0.0922; swapped +0.1283 / −7.8131 |

**Gate C is the one that owns the §1 scoping decision.** "Alongside, not replacing" is a claim about
superposition, so it is measured as one: the height relief contributes must be identical whether or not a
noise field is also assigned. Had relief replaced the noise branch, `(both − noise)` would carry the noise
term too and the two columns would part company. Both spans are asserted non-zero, because two
contributions of zero superpose perfectly.

**Perf gates are not run.** Benchmarks on this machine need the user's go-ahead. The expected shape is a
Mound with a 2-op program landing within ~1.3× a `noise`-only Mound over the same loop, matching the
Plow's budget — unmeasured, and flagged as such rather than assumed.

---

## 11. What gate D actually found

The first run reported `worst |native − gdscript| = 0.00012207 m`, just over the 1e-4 tolerance, and the
obvious reading was that the new relief term had drifted between the two implementations.

It had not. Splitting the gate into a dome-only baseline and then the full expression localised it:

```
dome + falloff only, no relief:  0.00009155 m
dome + noise + relief:           0.00012207 m
relief's own contribution:       0.00003052 m
```

**The gap is pre-existing and lives in the dome term.** The reason it had never been seen is structural:
Mound normalises its dome on the SDF's `max_inside`, and the Plow **ignores `max_inside` entirely** —
it normalises on `falloff_width` ([pasture_3d_brush_raster.cpp:1152](src/pasture_3d_brush_raster.cpp:1152)).
So the Plow's parity gates, which return an exact 0.00000000, have never compared that quantity, and this
is the first A/B measurement of a Mound. Every figure is a power of two (2⁻¹⁵, 3·2⁻¹⁵, 2⁻¹³), consistent
with float32 height quantisation rather than an algorithmic divergence.

The gate is therefore written to assert the thing this feature is responsible for — **relief must not
widen the gap** — and to print the pre-existing component separately with a NOTE when it exceeds
tolerance on its own, instead of folding both into one number that gets blamed on whatever was added last.
The Mound dome's own A/B gap is left open: it is not this feature's, it is under tolerance in isolation,
and closing it means touching the shared SDF path that every brush depends on.

---

## 12. Known issues found in passing, deliberately not fixed here

1. **The Plow's Crater-under-TILE warning is wrong.** It says a crater "repeats once per tile" under
   `Mapping = Tile` ([plow.gd:254](project/addons/pasture_3d/connectors/plow.gd:254)). Per §4, `nu,nv` are
   loop-relative in every mapping mode, so it does not — under TILE a crater is fitted to the loop, which
   gate F measures directly on the same evaluator. Left alone because it is Plow-side behaviour with its
   own spec and gate suite, and changing a warning users may have learned to work around is a separate
   decision.
2. **The Mound dome's A/B parity gap**, §11.

---

## 13. Deferred: Ridge and Trough

Both have the same `noise` / `noise_strength` pair and both write height, so both are real candidates.
Neither is free, and the two reasons are worth recording:

- **No per-cell below-layer grid.** They send `base_below_pts` — one value per polyline point, interpolated
  per segment ([ridge.gd:183](project/addons/pasture_3d/connectors/ridge.gd:183)). Selectors need a grid.
  Either they gain `_base_below_grid` plumbing, or they ship relief without selectors.
- **No oriented interior.** They are open polylines. `_loop_frame` needs a closed polygon, so `nu,nv` has
  no natural definition and radial ops have no frame to sit in. The likely answer is a per-segment frame
  (along-track / across-track), which is a design question, not a port.

Everything else — the base-class helpers, the params keys, the C++ call sequence — is already shaped for
them, which was the point of doing the refactor in §9 rather than copying the plumbing into Mound.

---

## 14. Sources

**Internal:** [PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md](PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC.md),
[PASTURE3D_RELIEF_MATERIALS_GUIDE.md](PASTURE3D_RELIEF_MATERIALS_GUIDE.md),
[PASTURE3D_LANDSCAPE_TOOLS_SPEC.md](PASTURE3D_LANDSCAPE_TOOLS_SPEC.md),
[PASTURE3D_SIM_NODE_SPEC.md](PASTURE3D_SIM_NODE_SPEC.md),
[mound.gd](project/addons/pasture_3d/connectors/mound.gd),
[terrain_brush.gd](project/addons/pasture_3d/connectors/terrain_brush.gd),
[pasture_3d_brush_raster.cpp:566](src/pasture_3d_brush_raster.cpp:566),
[pasture_3d_relief_ops.h](src/pasture_3d_relief_ops.h).
