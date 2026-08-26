# Pasture3D Terrain Graph Usability & UX — Spec

**Status:** Draft / Proposed (2026-08-26).
**Builds on:** `PASTURE3D_TERRAIN_GRAPH_SPEC.md` (evaluator, mount, GraphEdit editor, GPU/C++ backends),
`PASTURE3D_NODE_VOCABULARY.md`, and Godot 4.3–4.7 `GraphEdit` / `GraphNode` / `GraphFrame` capabilities.
**Target:** Godot 4.7, Pasture3D.

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
* **View / Controller (`Pasture3DGraphEditor`, `Pasture3DGraphNodeView`, `Pasture3DGraphSearchDialog`)**:
  Editor UI built on Godot `GraphEdit`, `GraphNode`, and `GraphFrame`. Intercepts user gestures,
  dispatches actions through `EditorUndoRedoManager`, and binds UI widgets to underlying resources.

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

#### 4.4.3 Rapid Wire Disconnection & Cutting
* `Alt + Right-Click Drag`: Sweeps a cut line across connections, severing all intersected wires.
* `Alt + Click` on a port: Instantly clears all connections to that port.

---

### 4.5 Phase 5: Terrain Inspection & Visual Previews

#### 4.5.1 Inline 2D Heightmap Thumbnails
* Add an optional 64×64 thumbnail preview `TextureRect` inside node bodies.
* Evaluates a small local sub-grid using a low-overhead CPU preview pass or local viewport shader.
* Displays normalized elevation as a grayscale heightmap with subtle normal/slope relief shading.
* Updates reactively when upstream parameters change.
* Toggleable globally via a top-bar button ("Show Previews") to preserve performance on large graphs.

#### 4.5.2 Preset Templates
Provide a toolbar dropdown ("Presets") allowing users to insert common node network templates:
* **Alpine Mountain**: Multi-octave Noise + Ridged Multifractal + Strata + Hydraulic Erosion.
* **Desert Dunes**: Directional Furrows + Dune Waves + Soft Blur.
* **Impact Crater Field**: Crater Generator + Voronoi Scatter + Rim Sharpening.
* **Terraced Valley**: Smooth Input + Quantized Terrace Filter + Slope Mask Blend.

---

## 5. File & Class Impact Summary

| File | Changes |
|---|---|
| `project/addons/pasture_3d/graph/pasture3d_graph_node.gd` | Add `muted`, `collapsed`, typed port metadata, and bypass evaluation logic. |
| `project/addons/pasture_3d/graph/pasture3d_terrain_graph.gd` | Add `frames` array, reroute op, clipboard serialization, and undo-friendly mutation APIs. |
| `project/addons/pasture_3d/graph/pasture3d_graph_frame_data.gd` | **[NEW]** Resource defining graph comment/grouping frames. |
| `project/addons/pasture_3d/graph/pasture3d_graph_node_reroute.gd` | **[NEW]** 1-in / 1-out pass-through reroute node. |
| `project/addons/pasture_3d/src/graph_editor.gd` | Complete overhaul: UndoRedo, inline controls, drag-drop search, minimap, framing, cutting. |
| `project/addons/pasture_3d/src/graph_search_dialog.gd` | **[NEW]** Floating fuzzy search popup for node placement. |
| `project/addons/pasture_3d/src/graph_node_view.gd` | **[NEW]** Specialized `GraphNode` view handling inline widgets, badges, and collapse states. |
| `project/addons/pasture_3d/src/graph_thumbnail_generator.gd` | **[NEW]** Lightweight 64×64 2D preview texture baker. |
| `project/bench/GraphUsabilityGate.gd` / `.tscn` | **[NEW]** Headless gate testing Undo/Redo, frame binding, mute bypass, and clipboard logic. |

---

## 6. Verification & Automated Test Gates

All additions must adhere to the project's gate discipline (asserting on field deltas and verified
with failing controls):

1. **`GraphMuteGate`**:
   * Asserts that muting an intermediate node ($A \to B \to C$) produces output equal to ($A \to C$).
   * *Control*: Unmuting changes the output field.
2. **`GraphRerouteGate`**:
   * Asserts that inserting a Reroute node ($A \to \text{Reroute} \to B$) produces bitwise identical
     floats to ($A \to B$).
   * *Control*: Disconnecting the reroute produces default/zeros.
3. **`GraphClipboardGate`**:
   * Asserts that copying a node sub-network and pasting it remaps all internal connection indices
     correctly without mutating original node connections.
4. **`GraphFrameGate`**:
   * Asserts that adding/removing frames and moving enclosed nodes serializes and deserializes
     cleanly across `.tres` save/load cycles.
