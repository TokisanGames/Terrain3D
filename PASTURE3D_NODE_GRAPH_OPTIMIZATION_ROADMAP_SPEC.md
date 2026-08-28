# Pasture3D Node Graph Architecture & Optimization Roadmap Specification

This document is the official phased roadmap and technical architecture specification for transforming the **Pasture3D Procedural Terrain Graph System** into an industry-grade, real-time native terrain authoring pipeline.

---

## 1. Executive Roadmap Overview

The optimization roadmap is structured into **4 sequential milestones**:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Milestone 1: Per-Node Output Buffer Caching & Dirty Invalidation                       │
│ • Caches output grids per node                                                         │
│ • Skips clean upstream subtrees on slider edits (downstream scrubbing in 1-3 ms)       │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Milestone 2: Multi-Threaded Grid Chunking with Godot WorkerThreadPool                  │
│ • Slices 2D grid evaluations across available CPU worker threads                       │
│ • Eliminates main-thread UI hitching on 512^2 and 1024^2 bakes                         │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Milestone 3: Native C++ Port of All Unaccelerated Nodes (3 Phases)                     │
│ • Phase 3A: Heavy Procedural Generators (NoiseJordan, NoiseSwiss, GeoPrimitives, etc.) │
│ • Phase 3B: Spatial Filters & Complex Solvers (Smooth blur_nan, Scree, DLA Massif)     │
│ • Phase 3C: Point Modifiers & Combiners (Terrace, Strata, Curve, Remap, Mask, Blend)   │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Milestone 4: Native C++ DAG Graph Execution (Whole-Graph Lowering)                     │
│ • Compiles the entire DAG into a contiguous C++ pipeline kernel                        │
│ • Eliminates GDScript per-node loop dispatch & memory marshaling roundtrips            │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Future Horizon: Bundled Multi-Channel Terrain Sockets (Reserved for Socket Refactor)   │
│ • Multi-layer terrain bus (height, water_depth, sediment, bedrock, flow) on one wire   │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Milestone 1: Per-Node Output Buffer Caching & Dirty Invalidation

### 2.1 Problem Statement
Currently, whenever any parameter on any node changes, `Pasture3DTerrainGraph.evaluate()` recalculates the entire DAG from the root sources to the sink. Adjusting a `Terrace` or `Remap` node at the end of a 10-node graph forces re-execution of all heavy upstream noise generators and erosion solvers.

### 2.2 Technical Design
1. **Per-Node Cache State:**
   - In `Pasture3DGraphNode`:
     - `_cached_grid: PackedFloat32Array` (primary output port 0).
     - `_cached_aux: Dictionary` (multi-output channel grids for ports $\ge 1$).
     - `_dirty_revision: int` (incremented whenever node properties change).
     - `_inputs_hash: int` (hash of upstream incoming buffer pointers / revisions).
2. **Selective DAG Re-Evaluation:**
   - `Pasture3DTerrainGraph.evaluate()` inspects each node's `is_dirty(inputs_hash)`.
   - If inputs have not changed and `_dirty_revision == _last_baked_revision`, the node immediately serves `_cached_grid` in **$0.0\text{ ms}$**.
   - Only dirty nodes and their downstream dependents are computed.
3. **Memory Management:**
   - Graph provides `clear_cache()` and LRU eviction if total cached grid memory exceeds user-configurable threshold (e.g. 256 MB).
4. **Verification Gate:**
   - `project/bench/GraphNodeCachingGate.gd`: Verifies bit-level identity between cached and cold-evaluated graphs, and confirms downstream slider edits execute in $< 3\text{ ms}$.

---

## 3. Milestone 2: Multi-Threaded Grid Chunking with Godot `WorkerThreadPool`

### 3.1 Problem Statement
Single-threaded grid processing stalls Godot's main thread and editor frame rate on large grids ($512^2 = 262,144$ cells, $1024^2 = 1,048,576$ cells).

### 3.2 Technical Design
1. **Row-Slicing Chunk Decomposition:**
   - Grids of size $N \ge 128^2$ are partitioned into horizontal row bands (e.g., chunks of 16 or 32 rows).
2. **WorkerThreadPool Task Group Dispatch:**
   - In C++ GDExtension (`src/pasture_3d_util.cpp`):
     ```cpp
     WorkerThreadPool *pool = WorkerThreadPool::get_singleton();
     int64_t group_id = pool->add_template_group_task(
         this, &Pasture3DUtil::_process_grid_chunk, chunk_data, num_chunks);
     pool->wait_for_group_task_completion(group_id);
     ```
3. **Contiguous Memory Slices:**
   - Tasks write directly into disjoint, non-overlapping slices of the destination `PackedFloat32Array` with zero lock contention.
4. **Verification Gate:**
   - `project/bench/GraphThreadPoolBenchmarkGate.gd`: Asserts thread-safety, zero race conditions, and $> 4\times$ throughput speedup on quad-core+ systems.

---

## 4. Milestone 3: Native C++ Port of All Unaccelerated Nodes

Upgrades all 20 GDScript nodes to high-performance C++ kernels across 3 sub-phases (adhering to [PASTURE3D_UNACCELERATED_NODES_UPGRADE_SPEC.md](file:///g:/LaughingRooster/GodotExtensions/Pasture3D/PASTURE3D_UNACCELERATED_NODES_UPGRADE_SPEC.md)):

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 3A: High-Impact Procedural Generators                                            │
│ • NoiseJordan, NoiseSwiss, GeologicalPrimitive, Furrows, Dunes, Crater, Noise          │
│ • Target: Eliminate 4.7M+ interpreted GDScript noise calls per bake.                  │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Phase 3B: Spatial Filters & Complex Solvers                                            │
│ • Smooth (blur_nan), Scree (Talus Shedding), DLA Massif (Random-walk growth)           │
│ • Target: Accelerate 2D spatial stencils and multi-pass relaxations to SIMD C++.       │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Phase 3C: Point Modifiers & Math Combiners                                             │
│ • Terrace, Strata, Curve, Remap, Mask, Blend, Const, Input/Output                      │
│ • Target: Vectorize all point-wise shaping operations in C++ float loops.              │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

For every node:
- Implement C++ kernel in `src/pasture_3d_<name>.h/.cpp`.
- Expose static binding on `Pasture3DUtil`.
- Update production node to call native kernel with fail-fast error reporting.
- Implement corresponding `[Dev/GD]` reference script.
- Add automated headless CI parity gate asserting $\text{MaxDiff} \le 1.0\times 10^{-4}\text{ m}$.

---

## 5. Milestone 4: Native C++ DAG Graph Execution (Whole-Graph Lowering)

### 5.1 Problem Statement
Once all individual nodes have native C++ kernels, orchestrating them via GDScript still incurs:
- Per-node GDScript function dispatch overhead.
- Intermediate `PackedFloat32Array` duplicate allocations.
- Multiple marshaling boundary crossings between GDScript and C++.

### 5.2 Technical Design
1. **DAG Lowering & Bytecode Representation:**
   - `Pasture3DTerrainGraph.compile()` flattens the graph DAG into a compact C++ descriptor `Pasture3DGraphPipeline`:
     - Linear array of operation structs (`op_type`, `params`, `input_buffer_slots`, `output_buffer_slots`).
     - Buffer slot allocator with intermediate buffer reuse (ping-pong memory pool).
2. **Native Pipeline Evaluator:**
   - Single native invocation:
     ```cpp
     PackedFloat32Array Pasture3DUtil::evaluate_graph_native(
         const Ref<Pasture3DGraphPipeline> &p_pipeline,
         int p_gw, int p_gh, const Rect2 &p_rect,
         const PackedFloat32Array &p_input_surface);
     ```
3. **Execution Pipeline Optimization:**
   - Keeps all intermediate grids resident in high-speed C++ CPU cache / SIMD registers.
   - Reuses a pre-allocated scratch arena without heap allocations during graph evaluation.
4. **Verification Gate:**
   - `project/bench/GraphNativePipelineGate.gd`: Verifies bit-level parity between the lowered C++ pipeline and the node-by-node reference evaluator.

---

## 6. Future Horizon: Bundled Multi-Channel Terrain Sockets

*Note: Reserved for a future release cycle when UI socket refactoring is scheduled.*

- **Concept:** Introduce a `TerrainBundle` port type representing an arbitrary collection of named 2D layer channels (`height`, `water_depth`, `sediment`, `bedrock`, `flow_rate`, `shoreline`).
- **Benefits:** Single-wire routing between complex simulation nodes and solvers without needing 4-5 parallel wires.
- **Components:** `BundlePack`, `BundleUnpack`, and `LayerExtract` utility nodes.
