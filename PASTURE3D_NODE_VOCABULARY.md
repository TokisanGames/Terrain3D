# Pasture3D Node Vocabulary — Glossary & Rename Map

<!-- Written 2026-08-25 as the vocabulary pass BEFORE the terrain-graph work, so the graph's node
names do not calcify around the old modifier-stack terms. Ratifies three renames the user approved
(node / op() / cell·grid), splits the overloaded word "field", and records the "relief" audit
(461 uses across 27 files). This is the reference the rename commit and the graph spec both build on;
update it here first when a term changes, then propagate. -->

**Status:** Ratified vocabulary (2026-08-25). Precedes the terrain-graph node work.
**Why now:** the graph generalizes today's linear *modifier stack* into a DAG. The words the nodes
will carry should be chosen once, up front, while they are still cheap to change.

---

## 0. Migration cost tiers

Every rename lands in one tier. This is the same taxonomy the `kind → filter_type` selector rename
established.

| Tier | Touches | Recipe |
|---|---|---|
| **Code-only** | method / local / class names, wire-tag string *values* | edit GDScript (+ C++ if a wire tag). No on-disk migration. |
| **Stored-property** | a serialized `@export` name | `_set` / `_get` migration shim (see `pasture3d_relief_selector.gd`). |
| **Folder/file** | script paths embedded in `.tscn` / `.tres` | mass path rewrite (done once in SIM spec §21.7). |

The node-vocabulary renames below are almost all **code-only**, which is why this pass is cheap
today and expensive after the graph exists.

---

## 1. Ratified terms

### node — the unit of the graph (was: *modifier*)
The general thing the graph is made of. "Modifier" was precise when every step *modified* the
brush's own output; the graph also has nodes that **generate** (noise, a base field) and **combine**
(blend two inputs), which are not modifications. "Modifier" survives only as one **node role**.

- `Pasture3DBrushModifier` → **`Pasture3DNode`** (base class).
- `Pasture3DMod*` → **`Pasture3DNode*`** (the concrete nodes).
- "modifier stack" → **"node stack"** today, **"graph"** once it is a DAG.

**Node roles** (a richer split than the flat "modifier"): **generator** (field from nothing) ·
**filter** (transform one input) · **combiner** (merge inputs) · **solver** (iterate over the grid,
e.g. erosion). Roles are descriptive vocabulary, not necessarily separate base classes.

### op() — a node's operation identity (was: `kind()`)
The dispatch tag the native rasteriser switches on. Same vague word (`kind`) already rejected for the
selector; renamed for the same reason.

- `kind()` → **`op()`**, returning e.g. `&"noise"`, `&"smooth"`, `&"erode"`, `&"relief"`.
- The C++ side (`brush_mod_kind`, `BrushModStep::NOISE|RELIEF|SMOOTH|EROSION` in
  `pasture_3d_brush_raster.cpp`) matches these string *values* — **code-only, but dual-sided**:
  GDScript and C++ change together. Nothing on disk stores them (the wire block is rebuilt every
  compile), so no `.tres` migration.
- **Consequence:** "relief op" (the atomic shape inside a material) is renamed **relief shape** so
  "op" belongs unambiguously to the node dispatch tag. `RELIEF_OP_STRIDE` etc. follow.

### cell / grid — the execution axis (was: POINT / FIELD operator)
Whether a node can be evaluated one cell at a time (fusible into a single loop) or needs the whole
grid (reads neighbours). Renamed off "point" and "field", both of which were overloaded elsewhere.

- **cell node** — per-cell, no neighbours; a maximal run of them folds into one loop.
- **grid node** — needs the whole grid (a blur, an erosion solve).
- `is_field_operator()` → **`needs_grid()`**.
- Prose "POINT / FIELD operator" → "cell / grid node".

---

## 2. The "field" split — the term that meant four things

`field` was doing four unrelated jobs. Each gets its own word:

| Meaning | Was | Now | Status |
|---|---|---|---|
| The execution axis | FIELD operator | **grid node** (§1) | done |
| A precomputed grid (e.g. a DLA) | baked field, `FIELD_MIN` | **baked map** | deferred → graph |
| Inter-node published data (flow / erosion / deposition / wetness) | field context, `publish_fields` | **channels** (a node's outputs) | deferred → graph |
| Which surface a selector measures | `FieldSource` (Below Layer / Host Profile) | **source surface** (keep the enum; the word "field" leaves the prose) | prose only |

Only the execution-axis row shipped in the pre-graph pass (that was the `is_field_operator()` →
`needs_grid()` rename). "Channels" is the important one for the graph: `publish_fields` is really a
node declaring its **output channels**, which downstream nodes read — i.e. graph edges. It stays a
stored `@export` until the graph formalizes ports, so it is renamed then (with a shim), not now.

---

## 3. "Relief" — audit outcome

461 uses / 27 files. "Relief" entered when the Plow was the only host and everything was a *relief
material*. It has outgrown that. Verdict: **keep it as a generator category, dissolve it as a
structure.**

### Keep — relief is a real domain term here
The **shape family** genuinely produces relief (elevation variation): Crater, Strata, Dunes, Scree,
Terraces, Furrows, Fractal, DLA. These become **generator ops**, and **"Relief" stays their category
label** (a node-palette group). `Pasture3DRelief{Crater,Strata,…}` keep their names.

### Renamed (DONE 2026-08-25) — the selector is not relief-specific
`Pasture3DReliefSelector` gated by slope / altitude / curvature / flow / erosion / deposition /
wetness — a **general terrain mask** every node can use, not something about relief. In the graph it
is a mask on any node.

- `Pasture3DReliefSelector` → **`Pasture3DTerrainMask`** — DONE. Class-only rename; its nested
  `FilterType` / `FieldSource` / `sim_result` and the `filter_type` migration shim's legacy `&"kind"`
  are unchanged. The **file kept its name** (`pasture3d_relief_selector.gd`) so no `.tres` path
  churn — a deliberate class/filename lag, cleaned up in the later file-move pass. C++
  `relief_selector_weight` was left (internal; aligns with the relief-eval rename below).

### Deferred to the graph work — structure, not label
These rename *and* change identity when the graph lands, so renaming twice is waste. Record the
end-state, move them then:

- `Pasture3DReliefMaterial` (a stack of shapes + a selector) **is a generator node** in graph terms.
  Keep the friendly name "relief material" for now; it becomes a node.
- `Pasture3DReliefStack` **is a linear graph**. Reframes when the DAG exists.
- **"relief op" → "relief shape"** (`RELIEF_OP_STRIDE`, `relief_eval`, `ReliefSample`,
  `relief_fields_add_*`): moved here rather than done now. It is entangled with the ReliefMaterial→node
  reframe above and spans the C++ relief-eval engine, so it belongs with that work. Consequence
  meanwhile: "op" names both the node dispatch tag AND the relief atom until the graph pass — a
  conceptual overlap, not a compile clash.

### The unifying idea
`ReliefStack`, the node stack, and the Sim pass chain are **three proto-graphs**. The graph is what
they collapse into. "Relief" the structure dissolves into node + graph; "relief" the category (a kind
of generator) is the part worth keeping.

---

## 4. Rename map (actionable)

Pre-graph pass **executed 2026-08-25** on branch `refactor/node-vocabulary` (build + class-cache
regen + parse-check all green). Wire dict key `"kind"` → `"op"` changed on both sides
(`terrain_brush.gd` and `pasture_3d_brush_raster.cpp`); internal C++ `st.kind` / `st.field` /
`BrushModStep` enum and the `publish_fields` wire key were left as internal/deferred.

| From | To | Tier | Status |
|---|---|---|---|
| `Pasture3DBrushModifier` | `Pasture3DNode` | code-only | **done** |
| `Pasture3DMod{Noise,Smooth,Erosion,Relief}` | `Pasture3DNode{…}` | code-only (class only; files kept) | **done** |
| `kind()` + wire key `"kind"` | `op()` + `"op"` | code-only, dual-sided (GDScript + C++) | **done** |
| `is_field_operator()` + step key `"field"` | `needs_grid()` + `"grid"` | code-only | **done** |
| `Pasture3DReliefSelector` | `Pasture3DTerrainMask` | code-only (class only; file kept) | **done** |
| "relief op" / `RELIEF_OP_STRIDE` / `relief_eval` | "relief shape" | code-only, but spans C++ relief-eval | deferred → graph |
| `publish_fields` → "channels" | node outputs / channels | **stored @export** (needs shim) | deferred → graph |
| baked "field" | baked "map" | tangled in wire keys (`op_fields`) | deferred → graph |
| `Pasture3DReliefMaterial` | (becomes a node) | — | with the graph |
| `Pasture3DReliefStack` | (becomes a graph) | — | with the graph |
| `.gd` filenames (`pasture3d_mod_*`, `pasture3d_relief_selector`) | match new class names | file-tier (rewrites `.tres`/`.tscn` paths) | later file-move pass |

---

## 5. Deferred — flagged, not in this pass

- **"Sim"** (`Pasture3DSim{,Pass,Manager,Result}`) — vague ("simulation of what?"; it is stream-power
  *fluvial drainage*). But it is a load-bearing proper noun across the 238 KB SIM spec, gate names,
  and `§`-refs. It becomes a **solver node**; rename the concept then, leave today's symbols.
- **`connectors/` folder** — misleading (nothing there "connects"; the name came from the road
  connector, and it is now the whole node library). Renaming rewrites script paths in every scene and
  resource (folder tier). High cost, no graph-semantics gain — fold into the graph work only if those
  paths are being touched anyway.
