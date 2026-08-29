# Pasture3D — Brush & Graph Dock Shortcuts

Status: **specified, unbuilt** (2026-08-29). Four small controls that close the loop between a brush in the
Inspector and its graphs in the bottom panel. Nothing here changes what a brush bakes; every one of them is
a shortcut for something that is already possible with more clicks.

> Read the status line with suspicion — a spec saying "unbuilt" may be half-built by the time you plan from
> it. Check for the symbols named in each phase before starting.

---

## 1. What is being asked for

Two controls in a row at the top of the **Pasture3DTerrainBrush** Inspector:

1. **Graph button** — "Add Graph" when the brush has no `Pasture3DNodeGraph` modifier, which adds one;
   "Open Graph" when it has at least one, which binds the bottom-panel editor to the first one.
2. **Evaluation toggle** — reads "Frozen" or "Live" when the brush's graph modifiers agree, "Mixed" when
   they do not, and "None" when there are none. Pressing it writes *every* graph modifier: Frozen ↔ Live,
   and Mixed → Frozen (the safe direction; press again for Live).

Two controls in the **Terrain Graph** dock toolbar:

3. **Brush Details** — points the Inspector at the brush hosting the graph being edited.
4. **Graph dropdown** — names the graph currently being edited, and drops down every graph in that brush's
   modifier stack for one-click switching.

## 2. What already exists, and what it costs us

Most of the machinery is built. Reusing it is most of the work.

| Need | Already there |
|---|---|
| A button at the top of a brush Inspector | `Pasture3DGraphInspectorPlugin` (`src/graph_inspector_plugin.gd`) — an `EditorInspectorPlugin` whose `_parse_begin` calls `add_custom_control`, already registered in `editor_plugin.gd:100` |
| Binding the dock to a graph | `Pasture3DGraphEditor.edit_graph(graph, mod, brush)` (`src/graph_editor.gd:86`) plus `plugin.make_bottom_panel_item_visible(editor)` |
| Creating a graph modifier from nothing | `_open()` in the inspector plugin already builds one for `Pasture3DPlow` — a `Pasture3DNodeGraph` with a `mountain_cone` → `output` graph |
| Knowing which brush hosts a graph | `_find_host_brush()` / `_find_host_modifier()` / `_find_brush_for_modifier()` (`graph_editor.gd:232-277`) |
| Pointing the Inspector at a node | `EditorInterface.edit_node(brush)`, used in `editor_plugin.gd:678` |
| Frozen/Live as a concept | `Pasture3DBrushModifier.Evaluation { LIVE, FROZEN }`, and `Pasture3DNodeGraph._supports_freezing()` returns `true` |
| A toolbar to add to | `graph_editor.gd:_build_ui()` builds an `HBoxContainer` of buttons ending in `_title` |

So the honest scope is: **generalise one inspector plugin from `Pasture3DPlow` to `Pasture3DTerrainBrush`,
add two toolbar controls, and fix the discovery bug that all four lean on.**

### 2.1 The bug they all lean on

`Pasture3DTerrainBrush` registers itself in the group `&"pasture3d_brush"`
(`pasture3d_terrain_brush.gd:47,157,380`). Three places look brushes up in **`"pasture3d_brushes"`**, a
group nothing ever joins:

- `graph_editor.gd:239` (`_find_brush_for_modifier` fallback)
- `graph_editor.gd:259` (`_find_host_brush` fallback)
- `pasture3d_mod_graph.gd:101`

Those loops have never matched anything. `_find_host_brush()` works today only when the brush was passed in
explicitly or happens to be selected — which is usually true, so the bug is invisible. Both dock features
here are *specifically* for the case where it is not (you are in the graph, the selection has moved on), so
they would inherit a silent failure. Fix it first, on its own, so the fix is reviewable apart from the
features that need it.

---

## Phase 0 — Fix brush group discovery

**Change:** replace the three `"pasture3d_brushes"` literals with
`Pasture3DTerrainBrush.BRUSH_GROUP`. Use the constant, not a corrected string literal — a second spelling
of a group name is what caused this.

**Files:** `src/graph_editor.gd` (2 sites), `connectors/pasture3d_mod_graph.gd` (1 site).

**Gate:** a headless probe that builds a `Pasture3DMound` with a `Pasture3DNodeGraph`, adds it to a scene
tree, *clears the editor selection*, and asserts `_find_host_brush()` returns the mound.
**The control that must fail:** the same probe run against the string `"pasture3d_brushes"` must return
`null`. Without that control the probe cannot tell "found the brush" from "the fallback was never reached
because the selection path already answered" — which is exactly how this stayed hidden.

**Risk:** near zero. Three lookups that return nothing start returning something.

**Built 2026-08-29**, and the gate turned up two more reasons the fallback could not fire:

1. `_find_brush_for_modifier` read `EditorInterface.get_selection()` unguarded. `EditorInterface` does not
   exist outside the editor, so the call took the whole lookup down *before* the group scan — the fixed
   group name would still never have been reached from a headless or non-editor call. Now guarded by
   `Engine.is_editor_hint()`, with the group scan outside the guard where it belongs.
2. `_find_host_brush`'s entire fallback block was gated on `plugin != null`, and `plugin` is not read
   anywhere inside it. A panel holding a graph and a tree but no plugin reference skipped a search that
   would have succeeded. Condition dropped to `graph != null and is_inside_tree()`.

Neither was visible from reading the group names alone; both were found by writing the control first.
Gate: `bench/BrushGroupLookupGate.tscn`, 4 criteria, each paired with the old string as its control.

---

## Phase 1 — Brush inspector button row

**Change:** in `Pasture3DGraphInspectorPlugin`:

- `_can_handle`: `Pasture3DPlow` → `Pasture3DTerrainBrush`, so Mound gets it too. Keep
  `Pasture3DTerrainGraph` and `Pasture3DNodeGraph`.
- `_parse_begin`: for a brush, add one `HBoxContainer` holding both buttons, each with
  `size_flags_horizontal = SIZE_EXPAND_FILL`. For a graph or a graph modifier, keep the single
  "Edit in Graph Editor" button exactly as it is — those objects have no modifier stack to describe.
- **The row is its own class, `Pasture3DBrushGraphRow` (`src/brush_graph_row.gd`), not code inside the
  inspector plugin.** `EditorInspectorPlugin` can only be instantiated by the editor, so logic living
  inside one cannot be driven by a gate at all — and what this row says about a stack that disagrees with
  itself is exactly the part worth testing. The row is a plain `HBoxContainer`; the one thing it cannot do
  without the editor, revealing the bottom panel, is injected as a `Callable`.
- Guard on `brush._supports_modifiers()`. A brush that does not run a stack (Ridge, Trough, Splat, Sim)
  must get no row at all rather than a row that cannot work. This is the same rule
  `_get_property_list` already applies to the Modifiers group.

**Button 1 — Graph.** Label and action from `_graph_mods(brush)`, the ordered list of
`Pasture3DNodeGraph` entries in `brush.modifiers`:

| State | Label | Action |
|---|---|---|
| list empty | `Add Graph` | build a `Pasture3DNodeGraph` (the `mountain_cone` → `output` default that `_open()` already builds for Plow), append it, then open it |
| list non-empty | `Open Graph` | `edit_graph(mods[0].graph, mods[0], brush)` + reveal the panel |

Lift the modifier-construction half of `_open()` into `_ensure_graph_modifier(brush)` so Add and Open share
one definition of "the default graph", and `_open()` keeps working for Plow's Source = GRAPH path.

**Button 2 — Evaluation.** Reads the whole stack and writes the whole stack:

| State | Label | Action |
|---|---|---|
| no graph modifiers | `None` | disabled |
| all graph modifiers `FROZEN` | `Frozen` | set every graph modifier to `LIVE` |
| all graph modifiers `LIVE` | `Live` | set every graph modifier to `FROZEN` |
| the stack disagrees | `Mixed` | set every graph modifier to `FROZEN` |

**The label reports the whole stack, not the first of it.** An earlier draft read only `mods[0]`, which
would have described a three-graph stack by one of its members and quietly hidden the other two. `Mixed` is
the honest reading, and it is also the useful one: it is the only state that tells you to go look at the
stack.

**`Mixed` resolves to `Frozen`, deliberately.** It is the safe direction — freezing something that was
already frozen costs nothing, while flipping an unknown number of graphs to LIVE could start a solve per
drag on a graph the user has never seen. So the first press always *converges* the stack, and the second
press is an ordinary `Frozen` → `Live` on a stack that now agrees. Two presses to reach all-Live from
Mixed is the intended cost, not a rough edge; the tooltip says so.

**Two more things this must get right:**

1. **Setting `evaluation` calls `_touch()` → `emit_changed()` per modifier**, and the brush listens. Flipping
   several therefore fires several refreshes. Set them in one loop and let the brush's existing
   `_schedule_refresh` debounce coalesce it; do not add a new batching mechanism for this.
2. **Going FROZEN → LIVE on a big graph starts solving on every drag.** That is the documented meaning of
   LIVE (`pasture3d_mod_graph.gd` header) and the button is how you ask for it, so no confirmation — but
   the tooltip should say it, and this is the second reason `Mixed` resolves toward `Frozen`.

**Refresh:** the Inspector rebuilds `_parse_begin` on selection change, so both labels are correct on
entry. They can go stale if a modifier is added or its evaluation changed from elsewhere while the same
brush stays selected. Accept that in Phase 1 — the row is a shortcut, not a status display. If it grates,
Phase 4 has the fix.

**Gate:** headless — build a Mound, assert the row's Graph button reports `Add Graph`; press it; assert a
`Pasture3DNodeGraph` with a non-null `graph` is now in `modifiers` and the label reads `Open Graph`. Add a
second graph modifier set to LIVE while the first is FROZEN, assert the toggle reads `Mixed`; press it,
assert **both** are FROZEN and the label reads `Frozen`; press again, assert both are LIVE. Control that
must fail: the same assertions against a `Pasture3DRidge`, whose `_supports_modifiers()` is false — it must
get no row, paired with a `Pasture3DMound` that must report true, or "refused" could just mean the check
always says no.

**Built 2026-08-29.** Gate: `bench/BrushGraphRowGate.tscn`, 20 criteria, 0 failures. Three things the
building turned up:

1. **The first gate reported PASS while every criterion errored.** `Pasture3DGraphInspectorPlugin.new()`
   fails outside the editor, so each test raised a runtime error on a null object — and a runtime error
   increments no failure counter. Every gate that constructs its subject now needs a preflight that FAILS
   when the subject cannot be built; this one has one.
2. **A `class_name` does not resolve in a headless run.** It enters the project's global class cache on an
   editor filesystem scan, so a newly added one is invisible to `godot --headless <scene>`. Both the gate
   and the inspector plugin therefore `preload` the row script rather than name it.
3. **For the same reason the row has no static `create()` factory.** A static factory must name its own
   class to instantiate it, which fails on a clean checkout; construction is `.new().setup(brush, cb)`.

---

## Phase 2 — Brush Details button

**Change:** a `Brush Details` button in `graph_editor.gd:_build_ui()`, placed next to `Bake to Brush`
(same host-brush dependency, same visibility rule). On press:

```
var brush := _find_host_brush()
if brush == null: return
var sel := EditorInterface.get_selection()
sel.clear(); sel.add_node(brush)
EditorInterface.edit_node(brush)
```

Mirror `editor_plugin.gd:675-678` exactly — selecting *and* editing, not just editing, so the 3D gizmo and
the Layers dock follow along. `_edit()` already special-cases `Pasture3DTerrainBrush` to keep the terrain
context alive, so this does not disturb sculpting.

**Visibility:** hidden when `_find_host_brush()` is null, resolved in `_rebuild()` alongside
`_bake_brush_button.visible`. A dead button that reads "Brush Details" when the graph is a standalone
`.tres` with no brush is worse than no button.

**Depends on Phase 0.** This is the feature most likely to be pressed when the brush is *not* selected —
which is the exact case the broken group lookup fails.

**Built 2026-08-29.** Gate: `bench/BrushDetailsButtonGate.tscn`, 6 criteria, 0 failures. What the press
DOES is two `EditorInterface` calls that cannot run headless, so the gate pins the half that can go wrong
silently — the visibility rule and the host lookup under it. [B] binds the graph *without* handing over the
modifier or the brush, so the group scan is the only route left, which is the state the dock is really in;
that criterion returned null before Phase 0. [C] is the control: a standalone graph no brush owns must hide
the button, or "visible" could just mean the button is always visible.

Note `_rebuild()` now resolves `_find_host_brush()` once and shares it with the `Bake to Brush` visibility
check, rather than each button doing its own lookup.

---

## Phase 3 — Graph dropdown

**Change:** replace the `_title` Label in the toolbar with an `OptionButton` (`_graph_picker`).

- **Items:** every `Pasture3DNodeGraph` in `_find_host_brush().modifiers`, in stack order, whose `graph` is
  non-null. **Item text = the modifier's `label` (its `resource_name`) when set, otherwise
  `"Terrain Graph <i>"` where `<i>` is the modifier's index in `brush.modifiers`** — the same number the
  Inspector prints on the row, so a fallback name points at something the user can actually see. The
  resource path is NOT used: for a scene sub-resource it reads `simple_pasture.tscn::Resource_6pcwc`, which
  identifies nothing. Set each item's metadata to the stack index, not to the object — an `OptionButton`
  outlives a modifier being deleted underneath it.
- **Selected:** the item whose `graph == self.graph`.
- **On select:** `edit_graph(mods[i].graph, mods[i], brush)`.

**Fallbacks, which are most of the work here:**

| Situation | Behaviour |
|---|---|
| no host brush (standalone `.tres`) | one non-interactive item showing `_graph_label()`, `disabled = true` — preserves today's read-only title |
| host brush, one graph | the dropdown shows it; leave it enabled, so the arrow still tells you there is only one |
| no graph bound | `(no graph)`, disabled — matches the current `_title` text |
| `graph` is not in the brush's stack (e.g. a `.tres` opened directly while a brush is selected) | append it as a trailing item named by `_graph_label()`, and select it; do not silently show the wrong name |

**Keep `_graph_label()` for the standalone case only.** It reads `resource_path.get_file()`, which is a
reasonable title for a `.tres` opened on its own and useless for a scene sub-resource. Add
`_graph_display_name(mod, index)` implementing the label-then-`"Terrain Graph <i>"` rule above and use it
for every item that comes from a brush's stack; leave `_graph_label()` untouched for the no-brush title so
existing behaviour does not move.

**Rebuild timing:** repopulate in `_rebuild()`, which already runs on `edit_graph` and on graph `changed`.
It will *not* run when a modifier is added to the brush from the Inspector. Same staleness as Phase 1,
same answer: accept it here, fix it in Phase 4.

**Built 2026-08-29.** Gate: `bench/GraphPickerGate.tscn`, 20 criteria, 0 failures. Two criteria are pinned
harder than the rest because getting them wrong is silent:

- **[E] metadata is the stack index, not the object.** Selecting re-resolves against the live stack, so a
  modifier deleted after the menu was built cannot be reopened through a stale reference. The criterion
  deletes a modifier, rebuilds, and checks the surviving one's metadata followed it from 1 to 0.
- **[D] a graph the stack does not own is appended and selected.** Showing another graph's name while
  editing this one is the failure nobody would notice; its entry carries metadata −1 so picking it is a
  no-op rather than a jump to the wrong graph.

[C] is the control for the naming rule, and it is worth stating what it actually catches: the stack is
`[Noise, labelled graph, bare graph]`, so the bare one must read `Terrain Graph 2` — its index in
`modifiers` — and not `Terrain Graph 1`, which is what counting only the graphs would give. A labelled
modifier must keep its label, or "the label is used" could just mean every item gets identical text.

---

## Phase 4 — Live sync (optional, only if 1 and 3 grate)

The two known staleness holes have one cause: nothing tells the dock or the inspector row that
`brush.modifiers` changed. The brush already emits on modifier changes — `_on_modifier_changed` rebuilds
its own property list.

**Change:** have the brush emit a signal when the modifier *list* (not a modifier's contents) changes;
`Pasture3DGraphEditor` connects to it for the host brush and calls `_rebuild()`. The inspector row is
harder — `EditorInspectorPlugin` controls are rebuilt by the Inspector, not by us — so the row should
instead re-read its labels in `_process`-free fashion: connect the same signal and update `text` in place.

**Do not start Phase 4 speculatively.** It adds a signal to a hot path (`_touch()` fires on every modifier
property write) for a cosmetic problem that may not be noticeable. Build 0–3, use them, then decide.

---

## 5. What this deliberately does not do

- **No multi-graph "open all"** — Open Graph opens the first, as asked. The dropdown is how you reach the
  rest.
- **No new evaluation state.** The toggle writes the existing `Evaluation` enum on existing modifiers; it
  is not a brush-level override, and a per-modifier Evaluation set in the Inspector still wins the moment
  you set it.
- **No change to non-graph modifiers.** Erosion also supports freezing, but the button says "graph" and
  touching Erosion from it would be a surprise. If a stack-wide freeze is wanted later it should be its own
  control, named for what it does.
- **No persistence of the dock's last graph.** Reopening the editor still starts from whatever
  `edit_graph` was last handed.

## 5.1 Status

Phases 0-3 are **built** (2026-08-29): `df7ba894`, `83f40f52`, `dd9a6710`, and this one. Four gates,
52 criteria between them, each with a control that fails. Phase 4 remains conditional and unbuilt.

## 6. Build order and why

Phase 0 first because 1–3 all sit on `_find_host_brush()`, and shipping features on top of a lookup that
silently returns null would make three features look flaky for one reason. Phase 1 next because it is
self-contained in one 80-line file and delivers the headline request. Phase 2 before 3 because it is ten
lines and proves the Phase 0 fix in real use. Phase 3 last of the required work because it is the only one
that has to reason about lists that change underneath it. Phase 4 is conditional and may never be built.
