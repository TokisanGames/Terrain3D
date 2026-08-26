# Pasture3D Terrain Graph — Spec

**Status:** Increments 1–5 built (2026-08-25) — the headless evaluator core (with the **cell-node fold**),
the brush **stack mount** (`Pasture3DNodeGraph`, FROZEN by default), and the **visual GraphEdit editor**
(`Pasture3DGraphEditor`). Plus the **C++ cell-run parity step** (2026-08-25): a native evaluator for a
lowered cell-only run, matched to the GDScript oracle to float32 rounding (gate `GraphCppParityGate`). Plus
the **Input/Output filter paradigm** (2026-08-26, §2.1): Input/Output nodes make the mounted graph a filter
over the incoming surface rather than a bare added generator. Plus the **native grid-pass interleave**
(2026-08-26): a native-supported graph now bakes end-to-end in C++ (the GDScript path stays as the A/B
oracle and the fallback for an unsupported op). No GPU backend yet (see Build order). Target: Godot 4.7,
Pasture3D.
**Builds on:** `PASTURE3D_NODE_VOCABULARY.md` (node / op() / cell·grid), the relief op-program
(`pasture3d_relief_material.gd`), and the brush node stack (`pasture3d_terrain_brush.gd`).

---

## 1. Goal

An art-directable terrain system: a **node graph** generates believable terrain, and brushes mask
regions to run graph-driven processing locally. The graph is the **DAG generalization of the three
linear stacks** the plugin already has — the brush node stack, the relief stack, and the Sim pass chain
— which collapse into it over time rather than staying parallel.

This is built the way the Sim was (`PASTURE3D_SIM_NODE_SPEC.md`): **evaluator first, headless, gated**,
then UI, then a threaded/GPU backend. Increment 1 is the evaluator and its parity gate.

---

## 2. Architecture

### 2.1 Node model
A `Pasture3DGraphNode` (Resource) reads zero or more input height grids and produces one output grid.
Ports: `input_count()` / `input_names()`; a single output unless `has_output()` is false (the Output sink),
with multi-output "channels" later. `op()` is the dispatch tag, a **superset of the stack's op()s**
(`&"noise"`, `&"smooth"`, …) — a node sharing a stack op's name must compute the same thing. `role()`
(GENERATOR / FILTER / COMBINER) is authoring metadata for the palette.

**Input / Output — the standard graph paradigm.** Two structural nodes make the graph a filter rather than
a bare generator:
- **Input** (`&"input"`, grid, no inputs) yields the surface the graph is handed — through the mount, the
  brush's own shape plus every modifier above the graph step. Wire it in to READ the terrain the graph
  processes (smooth it, add relief to it) instead of generating in a vacuum. No surface handed in ⇒ a flat 0.
- **Output** (`&"output"`, cell passthrough, one input, no output port) is the graph's SINK: its input is
  the result. A graph containing an Output node uses it as the output automatically
  (`output_index()`), so you wire the pipeline INTO it rather than pressing "Set as Output".

`output_index()` = the Output sink if present, else the legacy `output_node` designation. `reads_input()` =
an Input feeds the output (a filter, whose result depends on the incoming surface) — the mount's frozen
cache keys on that surface only when it is true.

### 2.2 Cell vs grid — the same split as the stack
`needs_grid()`, lifted from `Pasture3DNode`:
- **cell node** — point-evaluable: `eval_cell(wx, wz, inputs) -> float`, one cell at its world XZ. World
  sampling keeps the field continuous where graphs/brushes meet. Noise, Const, Blend.
- **grid node** — needs the whole grid: `eval_grid(inputs, gw, gh, mask) -> grid` (reads neighbours or
  routes). Smooth; later Erosion.

### 2.3 Graph representation
`Pasture3DTerrainGraph` (Resource) = `nodes: Array[Pasture3DGraphNode]` + `connections` (rows of
`[from_node, from_port, to_node, to_port]`) + `output_node`. Serialises as a `.tres` → "a graph per
landscape" is a resource. The shape maps 1:1 onto Godot `GraphEdit` for the later UI.

---

## 3. Evaluation model (increment 1: simplest-correct)

`evaluate(gw, gh, world_rect, mask=null)`:
1. Reduce to the output's **ancestor set** (a stray disconnected node neither runs nor breaks the sort).
2. **Topological order** (Kahn). A cycle in the ancestry → empty order → a flat 0 field (never a hang or
   stale read). `has_cycle()` reports it.
3. **Materialise one grid per node**: a cell node is a per-cell loop over `eval_cell`; a grid node is one
   `eval_grid`. An unwired input port reads a clean zeros grid.
4. Return the output node's grid.

**Built since (increment 5): the cell-node fold** — a run of cell nodes is fused into one loop and only
grid nodes / the output / fan-out points / grid-node inputs materialise; `_eval_unfolded` (the per-node
evaluator above) is kept as the oracle it matches (`bench/GraphFoldGate`).

**Built since (C++ parity step):** a native evaluator for a lowered cell-only run
(`src/pasture_3d_graph_ops.cpp`, bound as `Pasture3DUtil.graph_cell_eval_grid`). `compile_cell_program`
lowers a graph whose whole output ancestry is cell nodes into a flat SSA program (op / params / two input
slots / a parallel FastNoiseLite table); the native evaluator runs it per cell and matches `evaluate` to
float32 rounding (`bench/GraphCppParityGate`). It is checked headlessly against the oracle; the live bake
path is NOT yet routed through it. **Still not yet:** interleaving native grid passes (Smooth and later)
so a graph carrying a grid node can run natively end-to-end, flipping `_stack_forces_gdscript` off, and a
**GPU (RenderingDevice)** backend that keeps grids resident and reads back once. Those are pure
optimizations whose oracle is this per-node evaluator. The mask is **plumbed** to grid nodes but not applied globally: where a graph's
result lands is the host's concern (a whole-terrain bake, or the masked brush mount), not the graph's.

---

## 4. Increment 1 — what is built

`project/addons/pasture_3d/graph/` (kept out of the misleadingly-named `connectors/`):

| File | What |
|---|---|
| `pasture3d_graph_node.gd` | `Pasture3DGraphNode` base — ports, `op()`, `role()`, `needs_grid()`, `eval_cell`/`eval_grid`, `node_warnings()` |
| `pasture3d_terrain_graph.gd` | `Pasture3DTerrainGraph` — nodes+connections+output, `evaluate()`, topo/cycle, `cell_to_world` (static), `graph_warnings()` |
| `pasture3d_graph_ops.gd` | `Pasture3DGraphOps` — static grid helpers; `blur_nan` MIRRORS `Pasture3DTerrainBrush._blur_grid` byte-for-byte (consolidate at the fold) |
| `pasture3d_graph_node_noise.gd` | Noise — GENERATOR / cell (FastNoiseLite × amplitude, world XZ) |
| `pasture3d_graph_node_const.gd` | Const — GENERATOR / cell (a fixed height; the Blend bias, and a gate's known field) |
| `pasture3d_graph_node_blend.gd` | Blend — COMBINER / cell (two inputs; ADD/SUB/MUL/MAX/MIN, mirroring the relief Blend enum) |
| `pasture3d_graph_node_smooth.gd` | Smooth — FILTER / grid (shared `blur_nan`) — the first proof the cell/grid split carries |
| `pasture3d_graph_node_input.gd` | Input — SOURCE / grid (the surface handed in; §2.1) — added with the filter paradigm |
| `pasture3d_graph_node_output.gd` | Output — SINK / cell passthrough (the graph's result; `output_index`) — added with the filter paradigm |

## 5. Parity gate

`project/bench/TerrainGraphGate.{gd,tscn}` (CI: `project/bench/gates.txt`). House discipline: every
criterion measures a FIELD DELTA and carries a CONTROL that must move if the path is dead.
- **A** Noise == direct FastNoiseLite at `cell_to_world`; control: amplitude change moves the field.
- **B** Blend ADD == noise + const; control: MUL differs from ADD.
- **C** Smooth == `blur_nan`; control: the smoothed field differs from the raw.
- **D** A diamond evaluates to `2c` (topo order); control: a cycle is caught and flattens to 0.
- **E** An unwired input reads 0 (and warns); control: wiring it changes the result.

Run: `Godot --headless --path project res://bench/TerrainGraphGate.tscn` → `=== TERRAIN GRAPH PASS (0
failures) ===`.

---

## 6. Build order (later increments, each gated the same way)

1. **Stack mount — BUILT (increment 2; FILTER semantics added later).** `Pasture3DNodeGraph`
   (`pasture3d_mod_graph.gd`; a `Pasture3DNode`, `op() == &"graph"`, a grid node) hosts a
   `Pasture3DTerrainGraph` in the `modifiers` array. The host runs it in
   `Pasture3DTerrainBrush._apply_graph_step` over the brush's exact per-cell world grid (`min_x + ix*vs`, a
   half-cell-shifted rect into `cell_to_world`) as a **filter**: it hands the graph the absolute working
   surface (an Input node reads it, §2.1) and **composites the output over that surface** —
   `lerp(surface, output, amount·profile)`, feathered by the interior profile and scaled by `strength` as a
   0..1 **amount** (not metres; a generator node carries its own amplitude). A pure generator (no Input)
   still runs — its output just does not depend on the surface, so the graph replaces toward it; to ADD
   relief on top, wire `Input → Blend(ADD) ← Noise → Output`. Like the erosion step it reads/writes an
   ABSOLUTE surface (the working grid is a delta under ADD). Forces the GDScript rasteriser when a graph op
   is present (`_stack_forces_gdscript`, since native cannot run `&"graph"`). Gates: `bench/GraphMountGate`
   (composite + the filter path), `bench/GraphFilterGate` (the Input/Output paradigm at the graph level).
   **FROZEN by default (increment 4).** It caches the graph's absolute output per grid extent (a Bake Graph
   button + stale warning, via the erosion modifier's `_compile_modifiers`/`_commit_modifier_caches`
   contract). The staleness key is `content_key()` (a revision counter) for a **generator** graph — its
   output is world-fixed, so a cached grid stays valid as the spline drags within an extent, and only the
   amount and profile move (applied per bake). For a **filter** graph (`reads_input()`) the key folds in a
   hash of the input surface, exactly as the erosion cache does: a drag changes the surface and the entry
   goes stale until Bake. Nodes forward nested-resource `changed` (Noise → its FastNoiseLite) so an
   Inspector edit re-bakes and bumps the revision. Gate: `bench/GraphFreezeGate`.
2. **GraphEdit UI — BUILT (increment 3).** `Pasture3DGraphEditor` (`src/graph_editor.gd`), a bottom
   panel mapping `nodes`/`connections` onto `GraphEdit`, opened by the "Edit in Graph Editor" button an
   `EditorInspectorPlugin` (`src/graph_inspector_plugin.gd`) adds to a graph / graph modifier. Topology
   is edited on the canvas (add via `Pasture3DGraphNodeRegistry`, wire, "Set as Output", delete); node
   params are edited in the Inspector (select a node → `EditorInterface.edit_resource`). The graph's
   editing API (`add_node`/`connect_ports`/…) is on `Pasture3DTerrainGraph` and gated by
   `bench/GraphEditModelGate`. **Later:** inline node params, undo/redo, copy/paste, node search, minimap.
3. **Cell-node fold — BUILT (increment 5).** `evaluate` fuses cell-node runs into one loop, materialising
   only grid nodes / the output / fan-out points / grid-node inputs; `_eval_unfolded` is the oracle it
   matches (gate `bench/GraphFoldGate`).
   **C++ cell-run parity — BUILT.** `Pasture3DTerrainGraph.compile_cell_program` lowers a cell-only graph
   to a flat SSA program (`ops`/`params`/`in_a`/`in_b`/`noise`/`output`, a wire format shared with
   `src/pasture_3d_graph_ops.h`); the native `Pasture3DUtil.graph_cell_eval_grid` evaluates it per cell and
   matches `evaluate` to float32 rounding (gate `bench/GraphCppParityGate`, ≤5e-7 m measured). Modelled on
   the relief op-program's style, not a literal reuse — a graph diamond does not fit relief's linear
   accumulator, and the noise resource travels as-is rather than being rebuilt from params.
   **Native grid-pass interleave — stage 1 BUILT.** `Pasture3DTerrainGraph.compile_graph_program()` lowers
   the WHOLE graph (Input/Smooth/Output plus the cell ops) to a flat program; `Pasture3DUtil.graph_eval_grid`
   (C++ `graph_eval_grid`, `pasture_3d_graph_ops`) materialises every node in topological order — the
   analogue of `_eval_unfolded`, which it matches to float32 rounding (gate `bench/GraphNativeGraphGate`),
   and the folded `evaluate` loosely. `native_supported()` reports whether every op in the ancestry is one
   the native evaluator implements. **Stage 2 BUILT:** a `BrushModStep::GRAPH`
   (`pasture_3d_brush_raster.cpp`) in the native rasteriser's stack loop (absolute surface + amount·profile composite + a frozen cache mirroring
   `brush_mod_erode`, keyed on the surface for a `reads_input` filter and the revision alone for a
   generator). `_stack_forces_gdscript` now forces GDScript ONLY when `not graph.native_supported()`, so a
   native-supported graph bakes end-to-end in C++. `bench/GraphNativeBakeGate` A/Bs the native bake against
   the GDScript oracle on a terrain fixture (adds <1e-4 m beyond the pre-existing dome float/double gap);
   `BrushStackGate`/`BrushErosionGate` confirm the relief/erosion native paths did not regress. **Next:**
   the GPU backend below.
4. **GPU backend (RenderingDevice)** — each grid pass a compute dispatch over resident textures, the
   mask bound, one readback at the bake. Keeps cross-platform (see the `gpu_spike/` de-risk); only the
   test matrix is scoped to Windows+Linux.
5. **Multi-output channels** — a node exposing named outputs (flow/erosion/…), generalizing
   `publish_fields`.

---

## 7. Open questions

- **World mapping** is cell-centre `min + (i+0.5)*size/count`. The stack mount must reconcile this with
  the brush's `vertex_spacing` grid so a graph baked through a brush lands on terrain vertices exactly.
- **Mask semantics** at the mount: blend the graph result into the layer BY the mask (like the brush
  composite), vs. hand the mask to nodes that gate on it. Likely both; settle when mounting.
- **Whole-terrain host** (a graph that drives a region directly, no brush) vs. always-through-a-brush.
