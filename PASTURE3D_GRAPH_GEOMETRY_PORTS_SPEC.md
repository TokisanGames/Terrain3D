# Pasture3D Graph Geometry Ports Specification

**Document:** `PASTURE3D_GRAPH_GEOMETRY_PORTS_SPEC.md`
**Status:** **P2 complete** — P2a–P2d, 2026-08-31. Road Grade on the GPU is the one named remainder; see §7.
**Target:** Pasture3D Terrain Graph (Godot 4.7 GDExtension, C++20, GDScript)
**Supersedes:** the "P2 native tier" line in `PASTURE3D_ROAD_SYSTEM_PROPOSAL.md` §P2, which described a
`BrushModStep::ROAD` that does not exist (see §2.4)
**Written:** 2026-08-31

---

## 1. What this is for

The graph can carry a **PATH** — a world-space polyline with a half-width at every vertex — from a
`Road Source` to a consumer. It has been able to since P7a. What it cannot do is carry one into **C++**.

Every geometry-reading node therefore returns `blocks_native() == true`, and because that bail is
graph-wide, a single one drops the entire graph onto the GDScript evaluator: the erosion beside it, the
noise above it, all of it. That is why the four road nodes now sit behind the developer flag
(`PASTURE3D_GDSCRIPT_CPP_NODE_SEPARATION_SPEC.md` §3.0) rather than in a user's palette.

This document specifies the missing piece: **a geometry operand in the native program**, so that a PATH
can be an input to a native op the way a surface already is.

### Why now, and why it is not really about roads

Roads are the first customer, not the point. A first-class geometry pin is what makes an entire family of
nodes possible, and every one of them is currently blocked on the same absence:

- **rivers** — a centreline that carves, with a width that varies along it (the road grader's shape,
  different parameters)
- **coastlines and lake shores** — distance-to-shore as an analytic field rather than a thresholded mask
- **cliff lines, fence lines, walls, hedgerows, treelines** — anything authored as a curve
- **boundaries and regions** — a closed path as a mask, which is `Path Mask` with `closed = true`
- **scatter and placement** — which wants the *other* geometry type, see §5.4

Hesiod ships roughly twenty path nodes. They exist because `Path` is a wire type there. Ours do not exist
because it is not one here.

---

## 2. Why it is blocked today, precisely

There are **two** blockers, not one, and only the first is obvious. A plan that fixes only the first
produces a native road that still drops the graph to GDScript in the flagship wiring.

### 2.1 The SSA program has no slot for a non-scalar operand

`GraphProgram` (`src/pasture_3d_graph_ops.h`) is a flat, parallel-array SSA form. Per slot:

- an op id (`PackedInt32Array ops`)
- sixteen scalar parameters (`params` … `params_p`, one `float` each)
- four input operands (`in0` … `in3`), each an **int index into the scratch buffer pool**, or `-1` unwired
- the parameter-port overrides (`pmap0..3`) and the flat overflow table (`pdrv_*`)
- two per-slot side tables that are *not* scalars: `noise` (`Ref<FastNoiseLite>`) and `luts`
  (`PackedFloat32Array`, for `CURVE`)

A polyline with a per-vertex width is neither an int index into a pool of float-per-cell buffers nor a
float. There is nowhere to put it.

**But note `noise` and `luts`.** The program *already* carries per-slot data that does not flow through the
arena — a resource handle and a variable-length float array, bound once when the program is built. The
mechanism this document proposes is not new machinery; it is a third instance of an existing pattern, with
the addition that one geometry entry may be shared by several slots.

### 2.2 A secondary-port wire bails to GDScript, and §8's wiring 2 *is* one

`native_supported()` refuses any active DAG containing a wire out of **port ≥ 1**:

```gdscript
# If any wire in the active DAG feeds from a secondary port (port >= 1, e.g. a solver mask),
# stay on the multi-channel GDScript evaluator so the secondary channel is correctly read.
```

`Road Grade` publishes six outputs — `height`, `roadbed`, `cut`, `fill`, `verge`, `structure` — and the
whole argument for it (`PASTURE3D_ROAD_SYSTEM_PROPOSAL.md` §8, gate [L]) is the wiring that takes
`roadbed` off **port 1** into a `Blend`'s mask:

```
Input ─→ Road Grade ─ height ──────────────┬─→ Blend(MIX).a
                    └─ roadbed ─→ Invert ──┼─→ Blend.mask
                                Erosion ───┴─→ Blend.b
```

So a native `road_grade` op, on its own, buys nothing in the configuration anyone actually wants. Native
multi-output channels are **in scope for this work**, not a follow-on (§5.3).

### 2.3 `Blend.MIX` has no opcode

The same wiring needs `MIX`, which is currently CPU-only and blocks for a reason worth restating: the
native `GRAPH_OP_BLEND` has `default: val = a` for a mode it does not know. An unimplemented mode would
therefore return a *wrong answer* silently rather than refusing. See §6.1.

### 2.4 Correction to the road proposal

`PASTURE3D_ROAD_SYSTEM_PROPOSAL.md` P2 says "native `BrushModStep::ROAD`". There is no `BrushModStep` enum
in `src/`. Brush modifiers reach native per-modifier through `Pasture3DUtil` statics — `erosion_solve_grid`
is the model — so the work is a kernel plus a binding, not a case in a dispatcher that does not exist. The
proposal's P2 row is amended by this document.

---

## 3. What Hesiod does, and what we take from it

Hesiod's graph is C++ end to end, so a port is simply a typed pointer:

```cpp
node.add_port<hmap::Path>(gnode::PortType::IN, P_PATH);
hmap::Path *p_path = node.get_value_ref<hmap::Path>(P_PATH);
```

An output **owns** its value; an input is a **reference** to it. Fanout is free — ten wires out of one
output read the same object, nothing is copied. An unwired input is a null pointer meaning *no data*,
which is how their optional `dx` / `dy` / `mask` ports work. Type compatibility is a `data_type` string in
a port catalog, and the same catalog drives drag-to-create.

Their heightmaps are tiled and the path is passed **whole** into each tile:

```cpp
*pa_out = hmap::path_sdf_to_array(*p_path, region.shape, region.bbox, pa_dx, pa_dy);
```

`hmap::Path` is `Cloud` plus ordering, and `Cloud` is `std::vector<Point>` where `Point` is `{x, y, v}` —
**one float of payload per point**. That is our `half_widths`, arrived at independently. Worth taking as
confirmation that the shape is right.

### What we cannot copy

Our graph is not C++. It is a `Pasture3DTerrainGraph` Resource, edited by an editor plugin, saved in a
scene, evaluated by a GDScript evaluator that C++ *accelerates*. GDScript owns the graph; native is a
lowering target. We cannot make ports into typed C++ pointers without rewriting the ownership model, and
that rewrite would buy nothing the geometry table does not.

### What we do take

**The idea that geometry is ambient context, not a flowing value.** In Hesiod's tile loop the arrays flow
and the path is *there*. That is exactly the split we want: geometry is bound to the program before
evaluation, alongside the input surface, and never enters the scratch arena. Fanout is then free for the
same reason it is free for them — several slots name the same table entry.

---

## 4. The wire format

### 4.1 The geometry table

`compile_graph_program` gains one key:

```gdscript
"geom": [                      # Array[Dictionary], indexed by geometry id
    {
        "kind":   0,                    # 0 = PATH (polyline), 1 = CLOUD (unordered) — see §5.4
        "closed": false,                # PATH only; a closed path connects last→first
        "points": PackedVector2Array,   # vertices, WORLD metres (see the note below)
        "values": PackedFloat32Array,   # n floats — half-width per vertex (Point.v)
        # ---- optional, present only for a ROAD_GRADE consumer ----
        "profile": {
            "height":   PackedFloat32Array,   # solved alignment height per SAMPLE
            "half":     PackedFloat32Array,
            "shoulder": PackedFloat32Array,
            "verge":    PackedFloat32Array,
            "suppress": PackedByteArray,
            "skip":     PackedByteArray,
        },
    },
    ...
]
```

**As built, `points` is a `PackedVector2Array`,** not the packed float pairs this section first
proposed. Every kernel on the road side already takes one and `Pasture3DGraphPath.points` already is one,
so packing into float pairs would have added a conversion at both ends and a second layout to keep in
step. The `profile` sub-dictionary likewise carries `ds`, `s0` and `bank` alongside the arrays, and
`crown` / `cut_batter` / `fill_batter` with them — they belong to the road, and a graph cannot reach the
road type to ask.

**Two samplings, deliberately, and this is not redundancy.** `values` is per **vertex** and answers the
`t` query. `profile` is per **alignment sample** and is the grader's own space, handed over verbatim.
Resampling one into the other would insert an interpolation between the brush's road and the graph's, and
`RoadGraphGate` [K] — which requires 0.0000 m between them — is what would fail. This mirrors the split
already documented on `Pasture3DGraphPath`.

**World metres, absolute.** The program is compiled per bake and the rect travels separately; geometry
that was rect-relative would have to be recompiled per chunk, and a road crossing chunks would then be
several different roads. Cell mapping stays `graph_cell_to_world` (cell **centres**), unchanged.

### 4.2 The operand

```cpp
PackedInt32Array in_g;   // per slot: geometry table index, or -1 for "no geometry"
```

Parallel to `in0`…`in3`, read the same way, with **one deliberate difference**: `in0..in3` index the
*scratch pool* and `in_g` indexes the *geometry table*. They are different spaces and the field name says
so. A slot whose op reads no geometry carries `-1`.

**One operand, not four.** No node in this design consumes two paths. If one ever does — a "distance to
the nearer of two rivers" — it gets `in_g2`, exactly as ports beyond four got the flat `pdrv_*` overflow
table rather than an in4/in5 schema change.

### 4.3 `-1` is an empty path, and it must read as *far away*

An unwired geometry operand is the empty path, and the answer it produces is not free choice:

| query | empty-path answer | why the other answer is a disaster |
| :--- | :--- | :--- |
| `path_query.distance` | `unreachable_distance` (10000 m) | `0` means *every cell is on the road* |
| `path_query.s` / `t` | `0` / `unreachable` | — |
| `path_mask` | `0.0` (or `1.0` if `invert`) | `1` masks the world |
| `road_grade.height` | the surface, unchanged | a flattened terrain |

This is already the GDScript behaviour and already gated (`RoadGraphGate` [E]). The native path must
reproduce it **exactly**, because the failure is silent and total: a downstream `Road Grade` fed a
zero-distance field flattens the entire terrain to the road's crown, and the graph looks like it worked.

### 4.4 Ops

Appended, never renumbered — the enum is a wire format (last used id: `GRAPH_OP_MUDSLIDE = 56`):

```cpp
GRAPH_OP_PATH_QUERY = 57,   // FILTER grid: distance / s / t from in_g          (3 outputs)
GRAPH_OP_PATH_MASK  = 58,   // FILTER grid: [0,1] corridor mask from in_g       (1 output)
GRAPH_OP_ROAD_GRADE = 59,   // SOLVER grid: cut a road into in0 using in_g      (6 outputs)
```

and, for §2.3:

```cpp
GRAPH_BLEND_MIX = 5,        // lerp(a, b, mask)
```

Each op must be added to the `SUPPORTED` allow-list in `native_supported()` in the same commit as its
`case`. An op with a `case` and no allow-list entry is invisible — the graph silently stays on GDScript —
and the allow-list already carries a comment saying so.

---

## 5. The native side

### 5.1 `Pasture3DPathGeom`

```cpp
struct Pasture3DPathGeom {
    std::vector<float> px, pz;      // vertices, world metres
    std::vector<float> width;       // half-width per vertex
    std::vector<float> cum;         // cumulative arc length, prefix-summed once
    bool closed = false;
    // uniform-grid segment index, built once per evaluation
    // profile arrays for ROAD_GRADE
};
```

Built **once** when the program is built, shared read-only across every slot naming it and every worker
thread. This is where fanout becomes free.

The index must reproduce the GDScript one's *answers*, not its internals — `RoadGraphGate` [A] already
proves the GDScript index against brute force over a hairpin, so the native index is proven the same way
against the same fixture rather than against the GDScript index's intermediate state.

### 5.2 The query

Nearest point on a polyline: per cell, walk the candidate segments from the index, take the minimum of the
clamped projection. Embarrassingly parallel, cache-friendly, and it is the same arithmetic three times —
`distance`, `s` and `t` all fall out of one solve, which is why they are three outputs of one op and not
three ops (a second op could be given different parameters and would then describe a different road).

Threading through `Pasture3DThreadPool`, as the other grid kernels do.

### 5.3 Multi-output channels — the part §2.2 forces (BUILT, P2b)

`GRAPH_OP_ROAD_GRADE` produces six grids. The evaluator before P2b produced one grid per slot and the
compiler refused any graph wiring a port ≥ 1.

**Built:** a slot may own **N** buffers, and a wire out of port `k` reads buffer `k` of the producing
slot. Concretely:

- `GraphProgram` gains `PackedInt32Array out_count` (per slot, default 1). It reports what the **native
  kernel** writes, not what the node offers — a node whose GDScript publishes five channels but whose op
  writes one must still refuse a port-1 wire, or the graph would lower and read a zero buffer.
- The arena allocates a slot's auxiliary buffers **lazily**, and only for channels a consumer actually
  reads (per-slot per-channel refcounts, `want_aux`). A solver whose diagnostics nobody wires costs
  nothing, and — for Erosion — does not even compute them: `want_diagnostics` is now driven by whether a
  diagnostic channel was requested.
- Every op fetches operands through `buf_of(slot, channel)`. The four ops that previously indexed
  `slot_buffer[]` directly (BLEND, TERRACE, SMOOTH, OUTPUT) were the real bug: they served channel 0 to
  every port regardless of what the wire asked for, and did it silently.
- `in0..in3` gain a parallel `in0_port..in3_port` (default 0) naming which channel of the source slot the
  operand reads.
- `native_supported()`'s secondary-port bail narrows: it refuses a port ≥ 1 wire only when the **producing
  op** declares one output. It is not deleted — a port-1 wire out of a node the native side thinks is
  single-output is still a graph that must not lower.

**This unblocks more than roads.** Every existing multi-output solver — Erosion (`flow`/`ero`/`dep`/`wet`),
DLA, Lake Flooding, Water Mask — currently forces the whole graph to GDScript the moment anyone wires a
secondary channel, which is the normal way to use them. This is likely the single largest native-coverage
win in the document, and it is a prerequisite rather than a bonus.

### 5.4 CLOUD, reserved now rather than retrofitted

`kind` is in the table from the first commit, with `0 = PATH` implemented and `1 = CLOUD` reserved. A
cloud is the same table entry with the ordering ignored: points and one float of payload each — Hesiod's
`Cloud` exactly, and `Path` there literally derives from it.

Reserving it costs one int. Adding it later means changing what `in_g` indexes, in a format that by then
has saved graphs in it. Scatter, seeding and placement nodes are the customers.

### 5.5 GPU (BUILT, P2d)

The geometry table is an SSBO at binding 4: one flat float array per table entry, holding the already-built
ring, a half-width per vertex and the prefix-summed arc length. Uploaded once per entry and shared by every
dispatch naming it, so fanout is free on the GPU for the same reason it is free on the CPU. Packed as
floats rather than as a struct array because std430 alignment on a `vec2` array differs between drivers,
and a layout that is right on one machine and padded on another produces a plausible road.

**The shader walks EVERY segment where the CPU walks the bucket index, and that is deliberate.** The index
is an acceleration whose entire justification is that it returns the same answer as brute force. On the GPU
the per-pixel loop is already parallel, while a bucket walk would be a divergent gather with a
ring-stopping rule to get wrong. So the shader is the definition and the CPU is the optimisation of it,
which makes `RoadGpuParityGate` a comparison between an optimisation and the thing it optimises rather than
between two optimisations that could be wrong together.

Gated against the CPU op, never against GDScript directly, so a disagreement localises to one hop.

#### What the shader does not do, and therefore refuses

Each of these returns empty from `graph_eval_grid_gpu`, and the caller takes the CPU evaluator:

- **`GRAPH_OP_ROAD_GRADE`.** It reads a per-sample profile as well as the ring and writes six channels,
  and the GPU plan holds one buffer per slot. Named remainder, not an oversight — and it means the §8
  flagship wiring still runs on the CPU.
- **A closed `PATH_MASK`.** The region rule is even-odd winding and is not in the shader. Answered with the
  corridor rule it would be two ribbons along a boundary with a hole down the middle.
- **Any secondary channel.** P2b gave the CPU program channels; this path has none, so a program asking for
  `s` would be served `distance`. The guard is at the top of `eval_grid`, before anything is planned.

#### The tie rule, which P2d is how we found

Two segments exactly equidistant from a cell were resolved by whichever candidate the caller offered
first — and the indexed query offers them in bucket order while `nearest_brute` offers them in segment
order. `distance` is identical either way, so only `s` moves, and with it the half-width read at that `s`:
the symptom is a corridor mask stepping by the width difference on a single cell, beside a distance field
that is exact. It survived every CPU gate because both CPU paths shared the index's ordering.

The GPU's per-pixel brute-force loop is a third candidate order, which is what exposed it. `resolve` now
breaks a tie on the LOWER SEGMENT INDEX, in both the C++ and the GDScript, so the answer no longer depends
on the order candidates arrive in.

---

## 6. Invariants

### 6.1 A mode the kernel does not know must refuse, not answer

`GRAPH_OP_BLEND`'s `default: val = a` is the trap this whole area is prone to: an unimplemented case that
returns something plausible. `GRAPH_BLEND_MIX` landed in `pasture_3d_graph_ops.cpp`, in
`pasture_3d_graph_gpu.cpp` and in the enum in **one commit**, and `Pasture3DGraphNodeBlend`'s
`blocks_native()` override was deleted in that same commit.

Writing the GPU half turned up a second instance of the same trap, older and quieter: the GPU BLEND
shader never read the MASK port at all. A Blend with a mask wired ran on the GPU and ignored it, for
every mode, silently. Harmless-looking until MIX, where the mask IS the operation — so the mask fold was
added there in the same change. It is the shape this section warns about, found by looking for it.

The general rule, which this codebase has learned twice (see the acceleration guide §3.4): **a native path
that cannot do something must say so, never approximate it.** A refusal costs performance. A wrong answer
costs a terrain nobody can explain.

### 6.2 One implementation of the grading, not two

`Pasture3DRoadBrush.grade_surface` and `GRAPH_OP_ROAD_GRADE` must end up calling the **same** kernel, as
the brush erosion modifier and `Pasture3DSim` both call `erosion_solve`. `RoadGraphGate` [K] requires
0.0000 m between the brush's cut and the graph's; two implementations would drift, and [K] would then be
measuring which of two roads is on screen rather than that there is one road.

This means P2a touches the brush, and that is the intended scope, not scope creep. A native kernel used by
one of two callers is half the work done twice.

### 6.3 The oracle is already written

`dev_path_distance`, `dev_path_mask` and `dev_road_grade` — and `Pasture3DRoadGrader.grade_reference`,
which the last of those calls — are the reference implementations, gated by `RoadGraphGate` [A]–[L]: the index against brute force, `s` absolute, `t` signed
and normalised, the empty path reading far away, the mask tracking a widening road, and the graph's cut
against the brush's to 0.0000 m. Every parity gate below compares native against **those**, on **those**
fixtures. Nothing new has to be invented to know what the right answer is — which is the dividend of
having demoted them rather than deleted them.

### 6.4 NaN, and the brush-loop boundary

A NaN cell is no-data and must survive every new op as NaN, exactly as `erosion_solve_grid` restores it.
For `ROAD_GRADE` specifically: a road crossing a hole must not fill it.

---

## 7. Phases

| Phase | Scope | Gate |
| :--- | :--- | :--- |
| **P2a** ✅ 2026-08-31 | Tier-2 kernels + bindings, all on `Pasture3DUtil`: `path_query_grid` and `path_mask_grid` (`src/pasture_3d_path_query.cpp`), `road_grade_grid` (`src/pasture_3d_road_grade.cpp`). Production `path_distance` / `path_mask` / `road_grade` nodes that call them and fail fast; `road_source` promoted as-is, having no mathematics to move. `Pasture3DRoadGrader.grade` now forwards to the kernel, so the brush and the graph are ONE grader rather than two that agree (§6.2), and the GDScript body it replaced is `grade_reference`, the oracle. `Pasture3DGraphPath.closed` and region masks (§8.1). The `Roads` palette category returns with four nodes. | `RoadNativeParityGate` — native vs the four `dev_*` oracles on the `RoadGraphGate` fixtures, to the gate's existing thresholds; the brush's cut and the graph's still agree to 0.0000 m; a control that the kernels are actually being called (a missing binding must fail, not fall back). |
| **P2b** ✅ 2026-08-31 | Multi-output channels in the program (§5.3): `GraphProgram.out_count` and `in0_port..in3_port`, lazy per-channel aux buffers, `buf_of(slot, channel)` on every operand read, and the port ≥ 1 bail narrowed to `Pasture3DTerrainGraph.native_out_count`. `GRAPH_OP_EROSION` writes all five channels and computes its diagnostics only when one is wired. | `GraphChannelLoweringGate` — all five Erosion channels lower natively and match the GDScript evaluator (worst 3.8e-6 m on height, 0.0 on flow); controls: no channel is constant, no two channels are identical, a Lake Flooding port-1 wire still refuses while its port-0 sibling lowers. |
| **P2c** ✅ 2026-08-31 | The geometry table (`GraphGeomEntry`, `GraphProgram::geom`, `in_g`) and the three ops in `graph_eval_grid` (§4). `GRAPH_BLEND_MIX` on CPU and GPU (§6.1), which also fixed the GPU BLEND shader ignoring its mask port entirely. `blocks_native()` deleted from all four road nodes and from Blend. The kernels gained `*_geom` overloads so a road is indexed once per bake rather than once per consumer, and the `Pasture3DUtil` entry points became those overloads with a build in front — one implementation, two callers. | `GraphGeometryLoweringGate`, its own gate rather than an extension of `GraphCppParityGate` (which carries no road fixtures): [A] a path reaches the lowered program, [B] both mask rules, [C] all six grader channels, [D] the §8 wiring end to end, worst 0.0000005 m, [E] fanout is one table entry. Controls: an unresolved Road Source reads 10000 m and never 0; the MIX does not collapse to either of its inputs; two roads stay two entries. |
| **P2d** ✅ 2026-08-31 | GPU: the geometry SSBO at binding 4 and the query in the compute shader (modes 26/27), shared per table entry. Road Grade, a closed mask and any secondary channel refuse (§5.5). Found and fixed the segment-tie ordering bug in `resolve`, on both the C++ and the GDScript side. | `RoadGpuParityGate` (non-headless, RTX 3070): [A] distance 0.000004 m and the `max_distance` clamp, [B] the corridor mask exact across four parameter sets, [C] the empty path reads 10000 m and an empty inverted mask reads 1, [D] all three refusals, [E] one road shared and two roads kept apart. `GraphGpuParityGate` gained [F], which is what verifies P2c's GPU BLEND mask fix: every masked mode agrees, with a control that the mask changed the answer at all. |

**P2a shipped alone**, and it is the phase that took the road nodes back out of the developer flag: a
production node calling a kernel satisfies the separation rule the day it exists, even while the graph
around it still falls back. The four are visible and still `blocks_native()`, which is a listed debt in
PASTURE3D_NODE_ACCELERATION_GUIDE.md rather than a judgement made at the keyboard — the debt is P2c.

**P2b shipped without a road in it**, which was the point: the channel machinery is what every existing
multi-output solver needed, and Erosion's four diagnostics can now be wired without dropping the graph to
GDScript.

**P2c is the phase that made the four road nodes cost nothing to have in a graph.** They were already
native in themselves after P2a; what P2c removed is the graph-wide bail, so a road no longer takes the
erosion and the noise beside it down to GDScript with it. Both rows of the acceleration guide's
exceptions table are now empty.

**P2d earned more than a GPU path.** The shader itself matters least: a distance field the CPU already
produces, faster. What it bought was a THIRD implementation of the same query, and the third
implementation is what found a tie-ordering bug that two agreeing implementations had shared since the
index was written. That is the argument for keeping `nearest_brute` in production, made again from the
other direction — and it is worth remembering the next time a parity gate looks like a formality.

---

## 8. Decisions

### 8.1 Closed paths are region masks, and the customer is the brush shapes — DECIDED, in scope

`closed` is honoured, and `Path Mask` on a closed path fills the interior. The reason is not roads at all:
**it lets a Mound, Plow or Pond brush's own outline be reused as a graph mask.** Today the same region has
to be drawn twice — once as the brush that shapes it, again as a Plow that masks it — and the second copy
is scene clutter that silently drifts from the first the moment either is edited.

That means the geometry table has a second producer besides `Road Source`: a **Shape Source** node naming a
brush the way `Road Source` names a road, resolved by the host the same way (§8.2), handing over that
brush's outline as a closed PATH. The host-side resolution already exists and is not brush-specific.

Two consequences to design for rather than discover:

* **Inside/outside needs a winding test, not a distance threshold.** `Path Mask`'s `t` thresholding is a
  corridor — correct for a road, wrong for a region, where a wide shape would read as two ribbons along its
  edges and a hole down the middle. A closed path uses a crossing-count test, with the existing feather
  applied to the distance at the boundary. This is a different kernel branch, not a parameter.
* **A brush outline is not guaranteed simple.** Self-intersecting or doubled-back outlines must produce
  *something* defined rather than garbage; even-odd winding is the rule, and it is stated here so the CPU
  and GPU paths cannot each pick their own.

Scheduled with `path_mask` in P2a/P2c rather than deferred: the flag costs nothing to carry, and the mask
kernel is being written once either way.

### 8.2 Rivers take per-vertex widths and NO profile — DECIDED

Surveyed HighMap/Hesiod, which is the closest system with both roads and rivers:

* `dig_path(z, path, width, decay, flattening_radius, force_downhill, bbox, depth)` — a **scalar** width.
* `dig_river(z, path_list, riverbank_talus, river_width, merging_width, depth, riverbed_talus, ...)` —
  also a scalar width, with the *variation* coming from bank talus (angle of repose) and noise, and with a
  **list** of paths plus a `merging_width` for confluences.

We should not copy the scalar. Our table already carries `values` per vertex for roads, a river that widens
downstream is the normal case, and we can drive that width from something they cannot: the Erosion node
publishes `flow`, so a river's width can be sampled from its own catchment. A scalar is the degenerate case
of a per-vertex array (fill it), so per-vertex costs nothing and buys the case that matters.

We should **not** give rivers the `profile` block, and the reason is the principle that separates the two:

> A road carries a solved vertical alignment because **a road's height is a design decision** — an engineer
> chose a gradient and the terrain is cut to it. A river's height is a **consequence**: water goes where the
> ground already sends it. A river reads the surface and carves down from it; it must not be handed a
> pre-solved elevation, because a river that ignores the terrain it is in is the exact failure people notice
> immediately.

So `profile` stays optional and road-only, which is what §4.1 already permits. Rivers need `points`,
`values`, and the surface — plus bank talus as a node parameter, not as geometry.

**Deferred, and recorded so it is not rediscovered:** confluences. HighMap takes a *list* of paths with a
merging width, because two rivers meeting is a geometry problem, not a per-cell one. `in_g` names one entry
today. When a river solver needs several, the cheapest extension is a `group` id on table entries and an
op that reads every entry in its group — not a second operand per tributary.

### 8.3 Remaining open

1. **Where the geometry table is *built*.** `Pasture3DRoadNetwork.resolve_graph_paths` already injects
   the resolved `Pasture3DGraphPath` into each Road Source before evaluation; `compile_graph_program` then
   flattens whatever it finds. No new resolution mechanism, and the host stays the only thing that
   touches the scene.
2. **Confluences** — see the end of §8.2. Deferred, with the cheapest extension recorded.
3. **A Shape Source for brush outlines** (§8.1) — decided in principle, unscheduled. It is a small node and
   a host resolver, both modelled on `Road Source`; the kernel work it depends on is in P2a.
