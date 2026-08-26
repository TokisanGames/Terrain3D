# Pasture3D Terrain Graph Usability & UX — Spec

**Status:** BUILT — all five phases shipped and merged (PR #20, 2026-08-26). Verified by
`GraphUsabilityGate` (14 criteria A–N, 0 failures). This document has been reconciled against the
as-shipped code; where the code deviated from the original proposal the text below describes what
actually shipped, and the deviations are called out in an **As-built** note under each affected section.
**Builds on:** `PASTURE3D_TERRAIN_GRAPH_SPEC.md` (evaluator, mount, GraphEdit editor, GPU/C++ backends),
`PASTURE3D_NODE_VOCABULARY.md`, and Godot 4.3–4.7 `GraphEdit` / `GraphNode` / `GraphFrame` capabilities.
**Target:** Godot 4.7, Pasture3D.

> **As-built at a glance.** The editor view/controller is one class, `Pasture3DGraphEditor`
> (`src/graph_editor.gd`) — the proposed separate `Pasture3DGraphNodeView` was **not** built; inline
> slot controls, header badges and collapse all live in `graph_editor.gd`. The model layer
> (`Pasture3DTerrainGraph`) gained: `frames: Array` of `Pasture3DGraphFrameData`, `output_override`
> (solo preview), `content_key()`/`_revision` (frozen-cache staleness key), mute bypass inside
> `evaluate()`, and a full mutation/clipboard/frame API (`add_node`, `remove_node`, `connect_ports`,
> `disconnect_ports`, `set_output`, `group_nodes_in_frame`, `remove_frame`, `split_connection_with_node`,
> `serialize_subgraph`, `deserialize_subgraph`, `duplicate_subgraph`). `evaluate()` now takes an optional
> surface `p_input` and a preview-root `p_root_node`.

---

## 1. Goal

Transform the Pasture3D Terrain Graph editor from a functional topology-only prototype into a
fast, intuitive, production-grade node authoring environment on par with modern terrain and shader
graph workflows (Blender Geometry Nodes, Substance 3D Designer, Unreal Engine PCG/Material Editor,
and Gaea).

The core technical requirements are:
1. **Zero-friction authoring:** In-canvas parameter manipulation (no round-trips to the main Inspector),
   `Tab`/`Space` fuzzy quick-search, and wire-drop auto-connection.
2. **Robust editor plumbing:** Deep `EditorUndoRedoManager` integration, multi-selection, and
   clipboard (`Ctrl+C`, `Ctrl+V`, `Ctrl+D`) support.
3. **Visual structure & canvas organization:** `GraphFrame` comments/grouping, visual data routing
   (reroute dots), and minimap navigation.
4. **Domain-aware terrain feedback:** Inline 2D heightmap/mask previews, type-colored ports, and
   single-click node soloing/muting.

---

## 2. Architecture & Design Principles

### 2.1 Model-View-Controller Separation
* **Model (`Pasture3DTerrainGraph`, `Pasture3DGraphNode`, `Pasture3DGraphFrameData`)**: Pure Resources.
  Persist state (`.tres`), emit `changed` on parameter mutations, manage DAG topology, evaluate
  topological order, and handle serialization. Must remain headless-testable without UI dependencies.
* **View / Controller (`Pasture3DGraphEditor`, `Pasture3DGraphSearchDialog`)**:
  Editor UI built on Godot `GraphEdit`, `GraphNode`, and `GraphFrame`. Intercepts user gestures,
  dispatches actions through `EditorUndoRedoManager`, and binds UI widgets to underlying resources.
  (The proposed separate `Pasture3DGraphNodeView` was not built — per-node inline widgets, header
  badges and collapse are constructed inline by `Pasture3DGraphEditor`.)

### 2.2 Rebuild vs. In-Place Update Discipline
To prevent canvas stutter and focus loss during rapid slider drags:
* **Topology mutations** (adding/deleting nodes, rewiring, grouping into frames) perform a full or
  partial canvas reconcile.
* **Parameter edits** (changing an inline spinbox, slider, or enum) mutate the node resource directly,
  emitting `changed` on the model to trigger terrain re-bake without recreating Godot `GraphNode`
  control trees.
* **Layout edits** (`graph_position`, frame sizing) update node/frame properties without emitting
  `changed` (layout adjustments do not invalidate baked terrain caches).

---

## 3. Implementation Phases

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Phase 1: Foundation & Action Plumbing                                       │
│ • EditorUndoRedoManager integration across all graph operations              │
│ • Floating Tab / Space quick-search palette with fuzzy filtering            │
│ • Multi-node selection & Clipboard (Copy, Cut, Paste, Duplicate)            │
│ • Minimap & framing shortcuts (F, Home)                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│ Phase 2: Canvas Organization & Wire Routing                                 │
│ • GraphFrame grouping (comments, color tints, auto-shrink, frame drag)      │
│ • Reroute (Dot/Relay) node for clean noodle management                      │
│ • Connection styling, snap customization & arrange_nodes toolbar hook       │
├─────────────────────────────────────────────────────────────────────────────┤
│ Phase 3: Node Ergonomics & Inline Controls                                   │
│ • Inline slot controls (HSlider, SpinBox, OptionButton, CurveMiniEdit)      │
│ • Smart socket collapse (auto-hide inline widget when port is wired)        │
│ • Node header actions: Mute/Bypass (M), Solo/Preview (S), Collapse          │
│ • Execution tier badges ([CELL]/[GRID], [GPU]/[C++]/[GD], warning icons)   │
├─────────────────────────────────────────────────────────────────────────────┤
│ Phase 4: Smart Wiring & Port Typing                                         │
│ • Drag wire into empty canvas -> context-filtered search & auto-connect     │
│ • Type-safe colored ports (Height: Cyan, Mask: Orange, Vector: Purple)      │
│ • Alt+Right-Click wire cutting & Alt+Click quick disconnect                 │
├─────────────────────────────────────────────────────────────────────────────┤
│ Phase 5: Terrain Inspection & Visual Previews                               │
│ • Inline 2D heightmap/mask thumbnail renderers on nodes                     │
│ • Viewport 3D Brush Solo Mode (live isolate intermediate node output)       │
│ • Graph preset library (Mountain, Dune, Crater, Terrace templates)          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Detailed Component Specifications

### 4.1 Phase 1: Foundation & Action Plumbing

#### 4.1.1 `EditorUndoRedoManager` Integration
All user-facing mutations in `Pasture3DGraphEditor` must route through the plugin's
`EditorUndoRedoManager`:
* **Action Types**:
  * `Add Node / Delete Nodes`
  * `Connect Ports / Disconnect Ports`
  * `Move Nodes / Frames` (committed on `end_node_move`)
  * `Change Node Parameter` (merged when dragging sliders)
  * `Change Output Node / Solo State`
* **Implementation Pattern**:
  ```gdscript
  var ur := plugin.get_undo_redo()
  ur.create_action("Connect Terrain Graph Ports")
  ur.add_do_method(graph, &"connect_ports", from_idx, from_port, to_idx, to_port)
  ur.add_undo_method(graph, &"disconnect_ports", from_idx, from_port, to_idx, to_port)
  ur.commit_action()
  ```

#### 4.1.2 Quick-Search Palette (`Pasture3DGraphSearchDialog`)
* **Trigger**: Pressing `Tab` or `Space` over the canvas, or right-clicking on empty canvas space.
* **UI Structure**:
  * A lightweight `PopupPanel` containing a `VBoxContainer` with a `LineEdit` (search bar) and a `Tree`
    or `ItemList` (categories & matching entries).
  * Auto-focuses the text input upon opening.
  * Navigable via keyboard (`Up`/`Down` arrows to navigate, `Enter` to place, `Escape` to dismiss).
* **Fuzzy Match Engine**:
  * Matches node title, role (`Generator`, `Filter`, `Combiner`, `Source`, `Sink`), and tags
    (e.g., `"blur"` $\to$ Smooth, `"perlin"` / `"simplex"` $\to$ Noise, `"math"` $\to$ Blend).

#### 4.1.3 Multi-Selection & Clipboard Operations
* **Selection**: Support standard Godot box-select and `Shift + Click` multi-selection.
* **Duplicate (`Ctrl+D`)**:
  * Clones selected nodes (and internal intra-connections between selected nodes).
  * Offsets newly placed duplicate nodes by `Vector2(40, 40)`.
* **Copy / Cut / Paste (`Ctrl+C`, `Ctrl+X`, `Ctrl+V`)**:
  * Serializes selected nodes and internal connections to an internal dictionary clipboard.
  * Pastes at mouse cursor location (or centered in viewport).

#### 4.1.4 Minimap & Viewport Framing
* Enable `GraphEdit.minimap_enabled = true` with a toggle in the top bar.
* **Framing Shortcuts**:
  * `F` or `Numpad .`: Focus and center view on selected nodes.
  * `Home` or `A`: Frame all nodes in the graph.

---

### 4.2 Phase 2: Canvas Organization & Wire Routing

#### 4.2.1 `GraphFrame` Grouping (Comments & Sections)
* **Model Storage**: Add `frames: Array[Pasture3DGraphFrameData]` to `Pasture3DTerrainGraph`.
  ```gdscript
  class_name Pasture3DGraphFrameData extends Resource:
      @export var title: String = "Group"
      @export var tint_color: Color = Color(0.2, 0.25, 0.3, 0.75)
      @export var position_offset: Vector2 = Vector2.ZERO
      @export var size: Vector2 = Vector2(300, 200)
      @export var attached_node_indices: PackedInt32Array = []
      @export var autoshrink: bool = true
  ```
* **Editor Integration**:
  * Selecting multiple nodes and pressing `Ctrl+J` or `C` groups them into a new `GraphFrame`.
  * The frame provides an inline editable title label and a color picker button in its title bar.
  * Moving the frame moves all enclosed nodes synchronously.

#### 4.2.2 Reroute (Dot/Relay) Node
* **Op**: `&"reroute"` (`Pasture3DGraphNodeReroute`).
* **Behavior**: A minimal 1-in / 1-out pass-through cell node.
* **Canvas Rendering**: Compact 20×20 circular/square dot node without bulky title bars.
* **Quick Insertion**: Double-clicking any connection line calls `get_closest_connection_at_point()`
  and splits the connection, inserting a reroute node under the cursor.

---

### 4.3 Phase 3: Node Ergonomics & Inline Controls

#### 4.3.1 Inline Slot Controls
Instead of requiring the Inspector, common node properties are exposed directly within their
`GraphNode` slot rows:

| Node Op | Inline Controls Exposed |
|---|---|
| `&"blend"` | `OptionButton` (Add, Sub, Mul, Max, Min) |
| `&"noise"` | `SpinBox` (Frequency), `SpinBox` (Amplitude), `Button` (Randomize Seed) |
| `&"const"` | `SpinBox` / `HSlider` (Value in meters) |
| `&"smooth"` | `SpinBox` (Iterations), `HSlider` (Radius) |
| `&"terrace"` | `SpinBox` (Step Height), `HSlider` (Smoothness) |
| `&"strata"` | `SpinBox` (Frequency), `HSlider` (Warp) |
| `&"mask"` | `OptionButton` (Slope, Altitude, Curvature), `HSlider` (Threshold) |
| `&"curve"` | Compact `TextureRect` curve preview; click opens modal curve editor popup |

#### 4.3.2 Smart Socket Auto-Collapse
* When an input port has **no incoming connection**, its inline default widget is displayed.
* When a wire is **connected** to the port, the widget hides automatically (or switches to a compact
  read-only label), keeping the graph tidy.

#### 4.3.3 Node Header Actions
In `GraphNode.get_titlebar_hbox()`:
* **Mute / Bypass Toggle (`M`)**:
  * Adds `@export var muted: bool = false` to `Pasture3DGraphNode`.
  * When muted, the evaluator treats the node as a pure pass-through for input 0.
  * The node visual is rendered semi-transparent with a strikethrough title.
* **Solo / Preview Toggle (`S`)**:
  * Temporarily overrides `output_index` during editor authoring to route this node's output to the
    3D viewport preview without permanently modifying the saved graph output.
* **Collapse Toggle**:
  * Folds the node down to a title bar with port dots, hiding internal inline widgets.

#### 4.3.4 Execution & Backend Badges
Display compact indicator badges in the node header:
* `[CELL]` (green) vs `[GRID]` (blue)
* `[GPU]` (accelerated compute) vs `[C++]` (native CPU) vs `[GD]` (script fallback)
* Warning icon with tooltip when an essential input is disconnected or invalid.

---

### 4.4 Phase 4: Smart Wiring & Port Typing

#### 4.4.1 Drag-to-Create Context Menu
* Connecting a wire from a port and releasing it over empty canvas captures `connection_to_empty`.
* Automatically opens `Pasture3DGraphSearchDialog` pre-filtered to node types that accept or provide
  that port type.
* Selecting a node instances it under the drop location and connects the wire in one step.

#### 4.4.2 Port Type System & Validation
Register port types via `GraphEdit.add_valid_connection_type()`:

| Type ID | Name | Color | Description |
|---|---|---|---|
| `0` | **Heightfield** | `#5dade2` (Cyan) | Scalar elevation data (meters) |
| `1` | **Mask / Weight** | `#f39c12` (Amber) | Normalized scalar [0.0, 1.0] |
| `2` | **Vector2 / Angle** | `#af7ac5` (Purple) | Directional / gradient field |
| `3` | **Geometry / Spline** | `#2ecc71` (Emerald) | Spline curve or boundary geometry |

* Connecting incompatible ports (e.g. Vector2 directly into Height without a converter) is prevented
  by `GraphEdit` type rules.

> **As-built.** The registered valid-connection pairs are HEIGHT↔HEIGHT, MASK↔MASK, VECTOR↔VECTOR,
> CURVE↔CURVE **and HEIGHT↔MASK in both directions** — Height and Mask are deliberately cross-compatible
> (a mask is just a scalar field a downstream node can read as height, and any height can be gated).
> VECTOR and CURVE remain isolated to their own kind. Ports are colored per `Pasture3DGraphNode.PortType`
> (HEIGHT sky-blue, MASK amber, VECTOR purple, CURVE emerald).

#### 4.4.3 Rapid Wire Disconnection & Cutting
* `Alt + Right-Click Drag`: Sweeps a cut line across connections, severing all intersected wires.
* `Alt + Click` on a port: Instantly clears all connections to that port.

---

### 4.5 Phase 5: Terrain Inspection & Visual Previews

#### 4.5.1 Inline 2D Heightmap Thumbnails
* An optional thumbnail preview `TextureRect` inside node bodies, generated by
  `Pasture3DGraphThumbnailGenerator` (`src/graph_thumbnail_generator.gd`).
* Evaluates the sub-graph rooted at the node (a pure zero-input generator is sampled cell-by-cell; every
  other node runs `graph.evaluate(..., p_root_node)` over a representative brush surface).
* Displays normalized elevation with hillshade relief shading (light from NW); MASK-typed outputs are
  tinted amber, height outputs use an earth gradient; NaN (outside the brush perimeter) reads as dark.
* Updates reactively when upstream parameters change.
* Toggleable globally via a top-bar button ("Show Previews") to preserve performance on large graphs.

> **As-built.** Thumbnails render at **128×128** (`p_size` default 128), not 64×64. Nodes that read a
> surface (Input and the filters) are previewed over a **representative 3D brush mound** — a cosine bell
> (`generate_sample_brush_input`) — so a filter shows what it does to a real dome rather than a flat
> field; when the editor has a live rasterised brush surface it is resampled in via `resample_grid`
> instead. "Show Previews" defaults **off**. An early recursive-rebuild loop in the preview path was
> fixed (commit `27139b22`) before the resolution and brush-surface work landed.

#### 4.5.2 Preset Templates
A toolbar dropdown ("Presets") inserts common node-network templates, each dropped as a group inside a
titled `GraphFrame` and committed as one undoable action.

> **As-built.** **Five** presets shipped (the proposal listed four with larger, aspirational contents;
> what shipped are compact, wire-correct starter networks):
> * **Alpine Mountain** (id 0): Noise → Strata → Smooth (3 nodes, 2 wires).
> * **Desert Dunes** (id 1): Dunes + ripple Furrows (3 nodes).
> * **Impact Crater Field** (id 2): Crater + relief (3 nodes).
> * **Terraced Valley** (id 3): Input + Terrace (2 nodes).
> * **Steep Flank Mask** (id 4): slope-gate Mask + Noise.

---

## 5. File & Class Impact Summary

| File | Changes (as-built) |
|---|---|
| `project/addons/pasture_3d/graph/pasture3d_graph_node.gd` | Added `muted`, `collapsed`, `input_port_types()` / `output_port_type()` port metadata; the `PortType` enum. Bypass evaluation lives in `evaluate()`, not the node. |
| `project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd` | Added `frames` array, `output_override`, `content_key()`/`_revision`, mute bypass in `evaluate()`, `evaluate(..., p_input, p_root_node)`, and the full mutation/clipboard/frame API. |
| `project/addons/pasture_3d/graph/pasture3d_graph_frame_data.gd` | **[NEW]** Resource defining graph comment/grouping frames (`title`, `tint_color`, `position_offset`, `size`, `attached_node_indices`, `autoshrink`). |
| `project/addons/pasture_3d/graph/pasture3d_graph_node_reroute.gd` | **[NEW]** 1-in / 1-out pass-through reroute cell node (op `&"reroute"`). |
| `project/addons/pasture_3d/graph/pasture3d_graph_node_registry.gd` | Reroute added to the palette; entries carry `tags` + `description` driving fuzzy search. |
| `project/addons/pasture_3d/src/graph_editor.gd` | Complete overhaul: UndoRedo, inline slot controls + header badges + collapse (no separate view class), drag-drop search, minimap, framing, cutting, presets, preview toggle. Class `Pasture3DGraphEditor`. |
| `project/addons/pasture_3d/src/graph_search_dialog.gd` | **[NEW]** Floating fuzzy search popup for node placement. |
| ~~`src/graph_node_view.gd`~~ | **NOT BUILT** — inline widgets/badges/collapse folded into `graph_editor.gd` instead. |
| `project/addons/pasture_3d/src/graph_thumbnail_generator.gd` | **[NEW]** 128×128 2D hillshade preview texture baker (`Pasture3DGraphThumbnailGenerator`). |
| `project/bench/GraphUsabilityGate.gd` / `.tscn` | **[NEW]** Single headless gate covering all five phases (criteria A–N). |

---

## 6. Verification & Automated Test Gates

The four proposed gates were consolidated into **one** headless gate,
`project/bench/GraphUsabilityGate.{gd,tscn}` (registered in `gates.txt`), which covers all five phases.
It follows the house discipline — every criterion measures a concrete state delta and carries a control
that must fail if the path is dead — and prints `=== GRAPH USABILITY PASS (0 failures) ===`.
Pure GDScript on the graph model + editor controller; no DLL, no terrain. **Verified green 2026-08-26
(0 failures).** (A benign "resources still in use at exit" line prints after the verdict, like several
sim gates; the workflow keys on the printed verdict.)

Criteria as built:

| # | Criterion | Control |
|---|---|---|
| A | Registry search & keyword/tag fuzzy matching (`noise`, `perlin`→Noise, `blur`→Smooth, `math`→Blend) | impossible query returns 0 results |
| B | Subgraph duplication clones nodes and remaps internal wires, offsets positions | empty selection duplicates nothing |
| C | Clipboard serialize → deserialize round-trip rebuilds nodes + internal wire | empty deserialize creates no phantom nodes |
| D | Undo/Redo of add-node / connect / delete-with-wires via `EditorUndoRedoManager` | each redo restores the mutated state |
| E | Select-all + `Ctrl+D` / `Ctrl+C` / `Ctrl+V` GUI-input events mutate the graph | — |
| F | `group_nodes_in_frame`, node-removal remaps `attached_node_indices` | `remove_frame` drops the frame, leaves nodes |
| G | Reroute split ($A→$Reroute$→B$) is bit-identical passthrough | disconnecting the reroute reverts the field |
| H | Mute bypasses a Blend/Smooth node to its input 0 | unmuting restores the blended value |
| I | Inline param edit bumps `content_key()` and re-evaluates; editor mute action | — |
| J | `output_override` solo routes an intermediate node to the result; toggles off | toggling off restores the default output |
| K | Port types reported correctly (Mask→MASK, Const→HEIGHT, Blend 2×HEIGHT in) | — |
| L | Drag-to-create from/into empty canvas instances + wires a node | disconnect clears the wire |
| M | 128×128 thumbnails generate for generator / mask / input nodes | — |
| N | Preset insertion builds the network + titled frame; undo reverts it | undo empties nodes and frames |
