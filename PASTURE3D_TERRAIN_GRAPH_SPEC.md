# Pasture3D Terrain Graph — Spec

**Status:** Increment 1 built (2026-08-25) — the headless evaluator core. No editor UI, no C++/GPU, no
stack mount yet (see Build order). Target: Godot 4.7, Pasture3D.
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
Ports: `input_count()` / `input_names()`; single output (multi-output "channels" is later). `op()` is
the dispatch tag, a **superset of the stack's op()s** (`&"noise"`, `&"smooth"`, …) — a node sharing a
stack op's name must compute the same thing. `role()` (GENERATOR / FILTER / COMBINER) is authoring
metadata for the palette.

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

**Not yet, on purpose:** the **cell-node fold** — fusing a run of cell nodes into one loop (as the stack
does), then lowering that fused run into the relief op-program, then a **C++/GPU (RenderingDevice)**
backend that keeps grids resident and reads back once. That is a pure optimization whose oracle is this
per-node evaluator. The mask is **plumbed** to grid nodes but not applied globally: where a graph's
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

1. **Stack mount** — `Pasture3DNodeGraph` (a `Pasture3DNode`, `op() == &"graph"`, a grid node, FROZEN by
   default like erosion) hosting a `Pasture3DTerrainGraph`, evaluated over the brush footprint and the
   brush's mask, in the existing `modifiers` array. Inherits freeze/cache, field-context, warnings.
2. **GraphEdit UI** — a dock mapping `nodes`/`connections` onto `GraphEdit`; add-node palette by `role()`.
3. **Cell-node fold + C++ parity** — fuse cell-node runs; lower them into the relief op-program; a C++
   evaluator matched to the GDScript oracle to 1e-4, as relief is.
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
