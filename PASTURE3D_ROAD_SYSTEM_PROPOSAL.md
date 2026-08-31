# Pasture3D Road System — Proposal (v2, merged)

**Status:** PROPOSAL, nothing built. v1 written 2026-08-30 from a review of the terrain node graph and a
survey of other terrain tools; **v2 merges the user's brush-centred design** (RoadBrush / RoadSegment /
RoadIntersection / RoadType / RoadGroup / RoadNetwork) with v1's alignment solver, graph integration and
LOD story. Where the two disagreed, §3 records which won and why.
**Builds on:** the terrain brush + modifier stack (`connectors/pasture3d_terrain_brush.gd`,
`pasture3d_brush_modifier.gd`, `pasture3d_mod_graph.gd`), the graph (`project/addons/pasture_3d/graph/`),
the layer stack (`src/pasture_3d_layer.h` — note `set_reserved` / `set_owner_id`), the instancer
(`src/pasture_3d_instancer.h`), and the spline-snap work (`PASTURE3D_SPLINE_SURFACE_SNAP_SPEC.md`).
**Explicitly NOT built on:** `connectors/pasture3d_road_connector.gd`. That is a bridge to the
godot-road-generator addon that pokes `data.set_height` behind the terrain's back. It stays as interop;
it is not the foundation.

---

## 1. What this has to be

Three requirements, and they pull in different directions:

1. **Believable road environments.** A road is not a drape. It is a *cut* — the ground is graded to meet an
   alignment the road chose, with embankments where it fills and a batter where it cuts.
2. **Curves a game's track system can consume.** `Curve3D`s with correct up vectors, not just a mesh and a
   heightmap edit.
3. **LOD / distance streaming.** A road crosses the whole world; it cannot be one mesh and it cannot pop.

Plus the constraint that shapes everything below: **it must be as easy to use as the existing brushes, and
must leverage what is already built.**

### 1.1 What Pasture3D ships, and what it does not

**Pasture3D provides road and lane *data* and the queries over it. It does not implement traffic, AI,
gameplay or race logic.** That line holds for every consumer named in this document, and it is what keeps
the plugin a plugin rather than half a driving game:

| Pasture3D ships | The game implements |
|---|---|
| Lane curves, junction connectors, turn permissions, right-of-way and signal *phase data* | Vehicles, steering, following, gap acceptance, lane changing, signal *obedience* |
| `Pasture3DRoadRoute`, checkpoints, corridor bounds, `locate()` / `progress()` / `sample_surface()` | Timing, penalties, respawn, off-course rules, HUD |
| Generated pace-note *data* (severity, crest, dip, surface change, distance) | Co-driver audio, timing of the call, voice |
| `route.runs()` — which runs a stage occupies | Whether traffic clears that corridor, and how |
| Physics `surface_id` and blend weights along the road | Tyre model, grip, particles, audio |

Two consequences that shape the phases below:

- **The "corridor-clearing hook" is a query, not a behaviour.** Pasture3D answers *which runs is this stage
  on*; it never suppresses a spawn. For the current game, traffic is deliberately **not** cleared — cars are
  obstacles on the stage, which is a gameplay choice the plugin should have no opinion about. The query
  exists anyway, costs nothing (the route already knows its runs), and is there for a later game or another
  developer who wants it.
- **Traffic fidelity is not Pasture3D's question.** I raised "how sophisticated does the traffic need to be"
  as a P4b sizing risk; it is moot. Whether a consumer builds naive lane-followers or full gap-acceptance
  changes nothing about the data, so P4b is sized by *completeness and correctness of the lane graph*, not
  by behaviour.

**The reference agent is a gate, not a feature.** A minimal traffic agent — follows a lane, stops at an
intersection, picks a legal turn — lives in the **demo project**, not the addon, and exists to prove the
public API is sufficient. If a naive agent cannot drive the network using only shipped queries, the data is
incomplete and P4b is not done. That is the house "every criterion needs a control" discipline applied to an
API surface, and it is exactly the traffic the user intends to test with.

---

## 2. The frame: a road is a brush

The plugin's authoring idiom is a `Pasture3DTerrainBrush` with child `Path3D` splines and a **modifier
stack**, and a brush can already mount an entire node graph inside that stack
(`Pasture3DNodeGraph`, `op() == &"graph"`). So "brush-authored" and "graph-driven" are not alternatives —
the brush is the authoring surface and the stack is how its terrain effect reaches the heightmap.

`Pasture3DRoadBrush extends Pasture3DTerrainBrush` therefore gets, for nothing:

- child `Path3D` splines with the editor gizmos and `snap_to_surface` authoring,
- the debounced repaint, undo integration and configuration warnings,
- the FROZEN / stale-warning / **Bake** contract the erosion and graph modifiers already use,
- the native (and GPU) rasteriser path, once a `BrushModStep::ROAD` exists beside `GRAPH` and `ERODE`,
- `modifier_margin` handled once at the stack boundary, so the road grader never learns margins exist.

This is the single biggest reuse win available, and it is the user's design, not v1's. v1's "graph-first,
not a fourth brush" framing was wrong: the brush *is* how this codebase authors terrain, and the graph is
reachable from inside it.

---

## 3. Where v1 and the user's design disagreed

| Question | v1 said | User said | **Resolution** |
|---|---|---|---|
| Authoring surface | A graph source node reading a network resource | A brush with splines | **User.** §2. |
| Network topology | Node + edge graph | Brushes + auto-resolved intersections | **User, with v1's caution kept.** Intersections are auto-detected (ergonomics) but *stored* once resolved, so they are stable, addressable and overridable — §6. |
| Segment granularity | Arc-length chunks | One segment per spline interval, as a scene node | **Split decision** — §4.2. Segments become override *resources* keyed by arc-length range; mesh chunks are decoupled from them. |
| Settings inheritance | (not addressed) | Network → Group → Brush, pushed down on change, overridable | **User's hierarchy, v1's mechanism** — resolve at read, never copy — §5.3. |
| Elevation | Solved (cut and fill, grade-limited) | (not addressed) | **v1.** §7 — this is the realism crux. |
| Banking | Computed from curvature | (not addressed) | **v1.** §7. |
| Game curve output | Centreline + lanes + racing line + `locate()` | (not addressed) | **v1.** §9. |
| LOD / streaming | Terrain-far / chunk-mid / detail-near | (not addressed) | **v1.** §10. |
| Road types | (implicit in a Profile resource) | `Pasture3DRoadType` with `Priority` | **User, extended.** Priority decides three things, not one — §5.2. |

---

## 4. The authoring objects

### 4.1 `Pasture3DRoadBrush` — `extends Pasture3DTerrainBrush`

Lays out roads with open or closed child splines, exactly as Ridge and Trough do.

| Parameter | Notes |
|---|---|
| `road_type: Pasture3DRoadType` | The default for every segment on this brush. |
| `lane_count: int` | Override of the type's default. |
| `traffic_flow: {ONE_WAY, TWO_WAY}` | |
| ~~`traffic_side`~~ | **Moved to `Pasture3DRoadNetwork` as a world constant, no override** — see §6.4. |
| `segments: Array[Pasture3DRoadSegment]` | The override list — §4.2. Declared as a dynamic property like `modifiers` is. |
| `follow_terrain: bool` | Off (default) → the §7 alignment solve. On → drape, for footpaths and dirt tracks where a solve is overkill. |
| `snap_to_surface`, `surface_offset` | Inherited from the brush base. |

All of these are **null-able overrides** over the group's values — §5.3.

### 4.2 `Pasture3DRoadSegment` — a Resource, keyed by arc length

The user's design makes a segment the run between two spline points, as a scene node. I would change both
halves, for four reasons:

1. **Spline point spacing is an authoring convenience, not a geometric unit.** A 2 km straight is one
   point-to-point interval; a fussy corner is six.
2. **Inserting a point splits a segment** and orphans whatever was overridden on it. Users insert points
   constantly.
3. **Mesh chunk length would be dictated by where the artist clicked**, which makes region-aligned LOD
   chunking (§10) impossible.
4. **Scene nodes do not scale.** Hundreds of kilometres of road is thousands of nodes in the tree and in
   the `.tscn`. This is the cost godot-road-generator pays.

So: a segment is a **Resource in an array on the brush, addressing a range of spline arc length**
(`from_distance` / `to_distance` in metres). It carries only what it *overrides* — road type, lane count,
`is_bridge`, banking override, paint suppression. Everything unset resolves up the chain.

This keeps the user's intent (per-stretch control, exposed in the inspector, easy) while decoupling it from
both spline topology and mesh topology. It also mirrors `modifiers` exactly, so the inspector idiom, undo
behaviour and bake contract come free.

**`is_bridge`** suppresses grading over its range and emits a structure interval — and does more work than
it looks, see §6.

Segments that *do* want a gizmo — bridge endpoints, a hand-placed junction — get a lightweight child node
that points at the resource. Nodes for the few, resources for the many.

### 4.3 `Pasture3DRoadType` — a Resource

The user's design, with the parameters the alignment solver and the mesher need added:

| Parameter | Source |
|---|---|
| `lane_width`, `divider_type`, `priority` | User |
| `shoulder_width`, `crown` | Cross-section |
| `max_grade` | v1 §7 — the solver's hard constraint. A dirt track climbs what a motorway will not. |
| `max_superelevation`, `design_speed` | v1 §7 — banking |
| `cut_batter`, `fill_batter`, `verge_width` | The earthworks |
| `surface_layer_id`, `surface_material` | Terrain paint + ribbon material |
| `surface_id: StringName` | **Physics surface** (tarmac / gravel / snow / dirt), §4.4 |
| `speed_limit`, `lane_rules` | Ambient traffic, §6.4 |

Types are shared assets: "Country Lane" is one resource used forty times.

### 4.4 Surfaces change mid-stage

**Settled: several surface types, changing within a single stage.** So surface is not a per-route constant —
it is per-segment data sampled along the route, and three things follow:

1. **`surface_id` is on `Pasture3DRoadType`, and a segment override switches it.** A tarmac road that turns
   to gravel for 2 km is one `Pasture3DRoadSegment` override over an arc-length range (§4.2) — which is
   precisely the case arc-length-ranged segments were chosen for, rather than spline intervals.
2. **Transitions are a first-class thing, not a seam.** Each boundary carries a blend length: the ribbon
   cross-fades its material, the terrain paint cross-fades in the control map, and the runtime reports a
   blended surface weight rather than a hard switch, so tyre physics does not step-change under the car.
   `route.sample_surface(s) -> { primary, secondary, blend }`.
3. **Pace notes call the change** (§9.4). "Gravel in 200" is one of the most useful calls in rally, and it
   comes from the same segment data.

---

## 5. Hierarchy: Network → Group → Brush → Segment

### 5.1 The three containers (the user's design, kept)

- **`Pasture3DRoadNetwork`** — resolves intersections, owns the global road-type catalogue, drives terrain
  paint. One per world.
- **`Pasture3DRoadGroup`** — a container for road brushes. Owns a terrain layer for its roads, contributes
  `group_road_types`, and hides network types via `excluded_road_types`. "Highways", "Farm Tracks",
  "Pit Lane" are groups.
- **`Pasture3DRoadBrush`** / **`Pasture3DRoadSegment`** — §4.

The group's terrain layer should be created **reserved and owned**: `Pasture3DLayer` already has
`set_reserved(true)` and `set_owner_id(node_path)`, which exist precisely so a tool can own a layer that
users cannot hand-edit out from under it. This is a direct fit, not an adaptation.

### 5.2 `Priority` decides three things, not one

The user's `Priority` picks the road type at an intersection where a dirt road meets a paved one. It should
also decide:

- **Which group's paint wins** where two roads' control-map footprints overlap. Otherwise overlap order is
  whichever group baked last, which is a source of non-deterministic terrain.
- **Which road keeps its vertical alignment through a junction.** The minor road bends to meet the trunk
  road's elevation, never the reverse. This is most of what makes a junction read as real, and it comes free
  from a field already in the design.

### 5.3 Resolve at read, never push down

The described mechanism — the group passes settings to children on add and re-pushes on update, children may
override — has a defect that will surface within a week of use: **it cannot distinguish "the child is 4
because it inherited 4" from "the child was deliberately set to 4."** When the group moves to 6, there is no
way to know which children should follow.

Instead: every inheritable field is stored **null-able on the child (null = inherit)**, and reads walk the
chain `Segment → Brush → Group → Network → RoadType default`. No copying, no re-push, no sync, no stale
state, and "reset to inherited" is a one-click clear. The inspector shows the resolved value greyed until
overridden — the standard idiom.

Same defect, same fix, in `excluded_road_types`: **exclude by resource reference, not by index into the
network's array.** Reordering that array must not silently re-point every exclusion in the project.

---

## 6. Intersections

`Pasture3DRoadIntersection` is the user's design: auto-placed by the network where road centrelines meet,
carrying stop signs / lights, and also usable as the transition where a road changes lane count or type.
Auto-placement is the right ergonomic call — the user should not hand-author what geometry already implies.

Three additions:

1. **Overlapping is not intersecting.** Detection is XZ-planar, so an overpass overlaps everything it
   crosses. **A segment marked `is_bridge` is excluded from intersection resolution**, and so is anything
   whose solved elevations differ by more than a clearance threshold. Grade separation therefore falls out
   of a flag already in the design — worth stating so it is designed in rather than patched in.
2. **Resolved intersections are stored, not recomputed from scratch each bake.** They get a stable id so a
   user's choice of "traffic light, no left turn" survives an unrelated edit to the spline 300 m away. The
   network reconciles on change; it does not rebuild.
3. **The junction takes the higher-priority road's elevation and type** (§5.2), and trims both roads back to
   its footprint so segment meshes never overlap inside it.

### 6.4 The lane graph is load-bearing data

**Settled: vehicles drive the network — but Pasture3D ships the lane graph, not the vehicles (§1.1).** This
is still the largest scope consequence of the answers, because it changes what a junction *is*. Without
consumers, a junction is a geometry problem — merge the surfaces, don't crack the mesh. With them it is also
a **connectivity** problem, and connectivity cannot be retrofitted onto geometry.

The bar is therefore *completeness*, not sophistication: the graph must contain everything a consumer could
need, expressed so a naive consumer can use it without reconstructing anything.

So the network carries **two graphs over the same roads**:

| Graph | Nodes | Edges | Consumed by |
|---|---|---|---|
| **Run graph** | Junctions | Road runs | Routes (§9), the mesher, the terrain grader |
| **Lane graph** | Lane endpoints at a junction | Lane connectors through it | Traffic AI, opponent AI, `locate()`'s lane answer |

The lane graph derives from the run graph plus the junction's turn table — it is generated, not authored —
but it has to be *modelled* from P0 or the junction resolution will be written in a shape that cannot express
it.

A junction therefore owns:

- **Lane connectors.** For each incoming lane, the set of outgoing lanes reachable through the junction, as
  short `Curve3D`s. Generated by pairing lanes across the junction by turn geometry; hand-overridable.
- **Turn permissions.** Which connectors are legal (no left turn, bus only), defaulted from geometry and the
  road types' `lane_rules`.
- **Right of way.** The stop sign / traffic light state your `Pasture3DRoadIntersection` already specifies,
  now with something that consumes it. Signal phase groups are derived from `priority` (§5.2): the
  higher-priority road gets the longer green. Pasture3D **advances the phase and publishes the current
  state**; obeying it is the consumer's job.
- **Yield relationships** for uncontrolled junctions, from `priority` again.
- **A stop line per incoming lane** — where a vehicle should hold. Trivial to emit at bake (the trim-back
  boundary already exists), and painful for a consumer to reconstruct, which is the test for what belongs in
  the data.

Two knock-on notes:

- **`traffic_side` becomes load-bearing**, not cosmetic. It decides lane ordering, which turns cross traffic,
  and which way connectors curve. It should live on `Pasture3DRoadNetwork` as a world constant with no
  per-brush override — mixed handedness in one world is a bug, not a feature. (This supersedes the
  per-brush override listed in §4.1.)
- **Stages run on a live network, and that is a gameplay decision.** For the current game traffic is *not*
  cleared — the cars are obstacles on the stage. Pasture3D therefore ships only the query (`route.runs()`,
  §9.2) and never suppresses anything; a later game, or another developer, can build clearing on top of it.

The minimum a naive consumer needs, and therefore the P4b completeness bar: **given a lane, what are my legal
next lanes, where is my stop line, what is the signal state, and who do I yield to.** Four queries. If any
of them requires the consumer to re-derive geometry, the data is wrong.

Intersections are the hardest part of any road system, and the lane graph roughly doubles the geometry-only
version. But open-world-first means junctions come **before** the runtime layer (§11, P4), because a route
is a walk through a junction graph — so this phase is on the critical path rather than deferred to the end.

---

## 7. Vertical alignment — the missing realism piece

Nothing in the user's design says what height a road is at. Left unspecified, the answer becomes "the
spline's Y, draped", and that is what makes road tools look like ribbons laid on a hill.

**The plan alignment (XZ) is authored; the elevation is solved.** Point Y is a hint the solver may ignore,
with an optional per-point *pin* for heights a designer must dictate. Given the terrain sampled under the
centreline, `z_ground(s)`, solve for `z_road(s)` minimising

```
  cost = w_earth   · Σ |z_road − z_ground| · width · ds      # cut and fill volume
       + w_balance · | Σ (z_road − z_ground) · width · ds |  # net import/export of material
       + w_smooth  · Σ (d²z/ds²)² · ds                       # ride comfort / vertical curves
  subject to  |dz/ds| ≤ max_grade                            # from the RoadType
```

An iterated clamp-and-smooth solve converges in milliseconds over a few thousand samples. It is a 1D problem
on the centreline — cheap, and testable in complete isolation from everything else here.

What it buys is the behaviour that reads as "a road": it **cuts through the crest and fills the dip** rather
than following either, it refuses a wall it cannot climb, and where the grade constraint binds against a
hillside it produces a long steady traverse — a switchback's worth of character out of one inequality.
`follow_terrain = true` (§4.1) opts out, for dirt tracks and footpaths that genuinely should drape.

**Superelevation** comes off the same pass, from the plan curvature `κ(s)`:

```
  bank(s) = clamp(design_speed² · κ(s) / g, 0, max_superelevation)
```

smoothed over a transition length. This is physics, it is what a real road does, and it is *exactly* what a
racing track wants — one number serving the environment artist and the track designer. It is baked into the
`Curve3D`'s tilt, so §9 is nearly free.

**Bridges and tunnels.** Where the solved profile sits above ground by more than `bridge_threshold`, or below
by more than `tunnel_threshold`, the solver flags the interval and suppresses grading — the automatic
counterpart to the user's manual `is_bridge`. Generating the structures is out of scope; emitting the
intervals is not, and it is what stops the system building an absurd earth dam across a valley.

---

## 8. The terrain effect: a road modifier, graph-reachable

The brush's terrain edit is a stack modifier, `Pasture3DRoadModifier` (`op() == &"road"`), sitting beside
`&"erode"` and `&"graph"`. It reads the working surface and the brush's resolved road geometry and writes
the graded surface plus channel masks: `roadbed`, `cut`, `fill`, `verge`, `structure`. FROZEN by default with
the inline **Bake** button, keyed on the surface hash folded with the road's content revision — the contract
`Erosion` and the graph mount already established.

The same operation is also exposed as **graph nodes**, so a road can participate in a terrain graph rather
than only in a brush stack:

| Node | Role | In | Out |
|---|---|---|---|
| **Road Source** | GENERATOR | — | `path` PATH |
| **Road Grade** | SOLVER, grid | `surface` HEIGHT, `path` PATH | `height`, `roadbed`, `cut`, `fill`, `verge`, `structure` |
| **Path Distance** | FILTER, grid | `path` PATH | `distance` (metres), `s`, `t` |
| **Path Mask** | FILTER, grid | `path` PATH | `mask` MASK |

This needs one new port type, `PortType.PATH = 9` — world-space polylines with per-vertex width — distinct
from `CURVE` (a transfer curve, an unrelated thing).

**Why bother, given §2 says the brush is the authoring surface?** Because it makes ordering against erosion
*explicit and editable*:

```
Input → Erosion → Road Grade → Output              # the road cuts the weathered mountain

Input → Road Grade ──┬─────────────────→ Blend ← Erosion   # the hillside weathers AROUND the cut
                     └─ roadbed (inv) → Blend.mask
```

Terrain3D's connector flattens the heightmap after the fact and erosion never knows. Here the choice is one
wire. The brush covers the easy 90%; the graph covers the case that needs control.

**Implementation note — `Path Distance` should be analytic, not JFA.** The distance transform uses jump
flooding because an exact scan is sequential and could not go to the GPU, so CPU and GPU would disagree and
the same terrain would change as it crossed the 256² threshold. That reasoning does not apply to a *set of
line segments*: the distance is closed-form over a small candidate set from a uniform index. Exact,
embarrassingly parallel, bit-comparable on both backends by construction — and it yields the `s` and `t`
parameters JFA cannot.

---

## 9. Game output — the Route

**Settled 2026-08-30: the world is open-world-first, and a track is a *section of the open-world network* —
a point-to-point rally stage with checkpoints, never a closed circuit.**

That is a simplification, not an extra requirement. There is no separate track authoring path and no track
asset: a stage is a **`Pasture3DRoadRoute`**, an ordered walk through the network the designer picks out of
roads that already exist for open-world reasons. Everything in §9.2 derives from the alignment §7 already
solved.

### 9.1 The runtime resource

The resolved network serialises to a resource that **loads without the editor plugin and without the
terrain**, so a race mode reads it directly.

- **Centreline.** Per run, a `Curve3D` elevated and tilted by §7. `sample_baked()` gives position,
  `sample_baked_up_vector()` gives the banked up.
- **Boundaries.** Left/right edge curves — barrier placement, and the *inner* bound of §9.3's corridor.
- **Lane curves and the lane graph.** Lateral offsets in the profile's frame, plus the junction connectors
  that join them (§6.4). **Load-bearing**, not cosmetic: ambient traffic drives this, and so does opponent
  AI.
- **Surface.** `route.sample_surface(s) -> { primary, secondary, blend }` (§4.4) — rally physics needs
  surface as *data*, and needs the blend so grip does not step-change at a transition.
- **Progress query.** `network.locate(global_position) -> { run, s, t, lane, surface, distance }` — backed by
  the same segment index §8 builds.

### 9.2 `Pasture3DRoadRoute`

```
Pasture3DRoadRoute (Resource)
├─ entries: Array[{ run_id: int, reversed: bool }]   # the walk, start to finish
├─ checkpoints: Array[float]                          # route arc length, metres
├─ corridor_width: float                              # §9.3
└─ (derived, cached) length, pace_notes
```

Three things fall out of this shape:

- **Reversibility is explicit.** A rally stage runs in both directions on different days. `reversed` flips
  tangent, left/right boundaries and lane sidedness at read time; nothing is duplicated.
- **Checkpoints are arc lengths, not placed objects.** A gate is derived at bake: a plane perpendicular to
  the centreline at distance `s`, as wide as the corridor and as tall as a configured height. So **moving
  the road moves its checkpoints**, and a stage never silently develops a gate floating beside the new
  alignment. This is the ergonomic payoff of routes being parametric rather than authored geometry.
- **Route-relative progress**, not lap-relative. `route.progress(global_position) -> { distance_from_start,
  next_checkpoint, lateral }`.

**Authoring: hand-picked runs, with tooling later.** `entries` is an ordered array the designer fills by
selecting road runs in sequence, validated at edit time — consecutive entries must share a junction, and the
inspector says which one fails. That is the whole P6 requirement, and it is deliberately the cheap option.

Two things to build into it now so the tooling has somewhere to land, since both are nearly free at this
stage and awkward to retrofit:

- **Runs are referenced by stable id, not array index**, so a route survives edits elsewhere in the network —
  the same discipline as §5.3's exclusion lists.
- **The validator reports the *gap*, not just the failure** — "no junction between run 12 and run 13, nearest
  connection is via run 41". A later "pick start and finish, auto-path" tool is then a solver over the same
  junction graph the validator already walks, and a "draw a line and snap" tool is that solver plus a
  projection. Neither needs the route model to change.

### 9.3 Off-course is not binary

Cutting onto the verge is legitimate rally driving; leaving the corridor is not. So off-course tests against
a **corridor**, not the carriageway edge: `|t| > corridor_width` is out, and the band between the boundary
and the corridor is the verge you are allowed to use. The `verge` mask §8 already publishes is exactly this
field, so the corridor is authored by the same number that grades the earthworks.

### 9.4 Pace notes come free — and they are why §7 earns its keep

Rally's signature output is the co-driver's call, and every quantity it needs is already computed by the
vertical alignment solve:

| Call | Source |
|---|---|
| Corner severity (1–6) and left/right | plan curvature `κ(s)` and its sign — §7 |
| Crest, dip | the sign of `d²z/ds²` — the vertical solver's own smoothness term |
| "Long", "tightens", "opens" | the derivative of `κ` along the run |
| Distance to next call | route arc length between features |
| Surface change | `surface_id` transitions — §9.1 |
| "Don't cut", "caution" | corridor narrowing, or a `structure` interval from §7 |

`route.generate_pace_notes()` is then a peak-detect over two curves the solver already produced, emitting a
list the audio system reads. It is designer-editable afterwards, like any generated artifact.

This is worth pausing on: **the vertical alignment solver was argued for on realism grounds, and it turns
out to also be the pace-note engine.** A draped road cannot produce these — `d²z/ds²` on a drape is terrain
noise, not road geometry.

### 9.5 What this lets us drop

**Racing-line optimisation is descoped.** A minimum-curvature line between boundaries is a circuit-racing
idea; on loose surfaces, point-to-point, with no repeated laps, it is neither what a driver follows nor what
an AI needs. Opponent AI wants the centreline plus a lateral-offset policy. This removes a whole solver from
the plan.

An OpenDRIVE-style export stays a plausible later add for external tooling; the model above is a superset of
what it needs.

---

## 10. LOD and streaming — three tiers

**Tier FAR — the road *is* the terrain.** The grading is already in the heightmap and the carriageway paints
into the group's reserved control/layer map via `Pasture3DData.set_control_on_layer`. At distance the road
costs *nothing*: no meshes, no draw calls, no streaming — and, critically, **nothing to pop**, because it is
terrain and it LODs with the terrain's own clipmap. Most road systems fight this; this one dissolves it, and
it only works because the road went through the heightmap rather than sitting on it.

**Tier MID — chunked ribbon mesh.** Chunks are cut on **arc length, snapped to region boundaries**, so a road
chunk's lifetime matches a terrain region's and one visibility test serves both. This is why §4.2 decoupled
chunks from spline intervals. Rules: never chunk across an intersection; seams land on shared vertices so no
crack can open; per-chunk LOD is longitudinal sample spacing plus cross-section decimation (shoulder and
camber collapse first, carriageway last). A `Pasture3DRoadChunkHost` drives it, modelled on the existing
`Pasture3DClipmapHost` / `Pasture3DWaterClipmap` — distance-driven mesh hosting has precedent in-tree.

**Tier NEAR — full detail.** Highest-LOD ribbon, collision (the EDITOR `collision_mode` lesson from the
placement-raycast work applies), lane markings from `divider_type` as a decal or second UV set, and props —
kerbs, guardrails, signs, verge vegetation — placed along the path through `Pasture3DInstancer`. The
instancer already stores per-region multimeshes keyed by region location, so **road props stream with regions
for free** and need no new streaming code at all.

Design-to note: a chunk carries its LOD meshes as one resource, so a tier change is a mesh swap, never a
rebuild. Rebuilds happen at bake time.

**A Route is a streaming hint (§9.2).** Rally's hard streaming problem is speed: at stage pace a
radius-around-the-player policy is loading chunks roughly when you arrive at them. But an active route is a
*known corridor* — the game knows the next 800 m of road before the player does. So the chunk host takes an
optional route and pins chunks along `[s, s + lookahead]`, biased by current speed, and de-prioritises the
radius behind. This costs nothing to build (the route already indexes runs to chunks) and turns the worst
streaming case in the project into the best-informed one. The same hint pre-warms terrain regions, instancer
props and surface materials along the stage.

---

## 11. Phasing

Each phase ships with a gate under `project/bench/`, house discipline: every criterion measures a field delta
or a numeric property and carries a **control that must move if the path is dead**.

| Phase | Deliverable | Gate |
|---|---|---|
| **P0** | `RoadType` / `RoadSegment` resources; `RoadBrush` with splines; `RoadGroup` / `RoadNetwork` with the §5.3 resolve chain. No terrain effect yet. | `RoadModelGate` — resolve chain returns the right value at each level; clearing an override re-inherits; exclusion survives a reorder; control: a group change moves an un-overridden child and not an overridden one. |
| **P1** | The §7 vertical solver, standalone and headless. | `RoadAlignmentGate` — grade never exceeds `max_grade` (control: raising it changes the profile); cut/fill balance; a wall is refused; banking matches `v²κ/g`; a pinned point is honoured. |
| **P2** | `Pasture3DRoadModifier` in the brush stack — grading + masks. GDScript first, then native `BrushModStep::ROAD`, then GPU, on the existing three-tier discipline. | `RoadModifierGate` — graded height vs an independent re-derivation; mask algebra; freeze/stale/Bake; NaN passthrough at the brush-loop boundary. Plus a native A/B and `RoadGpuParityGate`. |
| **P3** | Ribbon mesh, region-aligned chunking, LOD tiers, collision, control-map paint into the group's reserved layer. | `RoadMeshGate` — no cracks at seams (shared-vertex identity), LOD vertex budgets, chunk↔region alignment, paint respects `priority`; control: LOD 0 and LOD 3 differ. |
| **P4a** | **Intersections, geometry** — auto-detection with bridge exclusion, stored resolution, trim-back, priority-driven type and elevation. **Moved ahead of the runtime layer:** open-world-first means junctions exist before any stage does, and a Route is a walk through a junction graph, so routes cannot be modelled until junctions are. | `RoadJunctionGate` — a crossing resolves; a bridge crossing does **not**; the higher-priority road keeps its alignment; a user's junction override survives an unrelated spline edit. |
| **P4b** | **Intersections, connectivity** (§6.4) — lane connectors, stop lines, turn permissions, right of way, signal phase groups from `priority`. **Data and queries only; no traffic behaviour ships** (§1.1). Split from P4a because it is roughly the same size again and has a different failure mode. | `RoadLaneGraphGate` — every incoming lane reaches a legal outgoing lane; connectors are tangent-continuous with the lanes they join; every incoming lane has a stop line inside the junction footprint; `traffic_side` flips which turn crosses traffic; a hand-override survives a re-resolve; control: forbidding a turn removes exactly that connector. **Plus the sufficiency check:** a reference agent in the demo project follows lanes and stops at intersections using only public queries — if it needs to re-derive geometry, the data is incomplete. |
| **P5** | Ribbon mesh, region-aligned chunking, LOD tiers, collision, control-map paint into the group's reserved layer. | `RoadMeshGate` — no cracks at seams (shared-vertex identity), LOD vertex budgets, chunk↔region alignment, paint respects `priority`; control: LOD 0 and LOD 3 differ. |
| **P6** | **Runtime layer** — `Pasture3DRoadRoute` (hand-picked entries + validator), checkpoints, corridor test, `locate()` / `progress()`, `sample_surface()`, pace notes, route-driven streaming lookahead, and the corridor-clearing hook for traffic. Loads with no editor and no terrain. | `RoadRouteGate` — `locate()` round-trips against sampled points; up vectors match the solved banking; a reversed route flips boundaries and travel direction; checkpoints follow a moved road; the corridor test separates verge from off-course; a surface transition blends rather than steps; the validator rejects a disconnected pair and names the gap; pace notes find a known corner, a known crest and a known surface change (control: flatten the profile and the crest call disappears). |
| **P7** | Graph nodes (`PATH` port, Road Source / Road Grade / Path Distance / Path Mask). | `RoadGraphGate` — analytic distance vs a brute-force oracle; the two §8 wirings differ as predicted. |
| **P8** | Auto-routing: anisotropic A* over graph-produced cost fields (slope, `water_mask`), emitting an editable brush. | `RoadRoutingGate` — found cost ≤ a straight line's; control: a wall in the cost field reroutes it. |

**Reordered for open-world-first (mesh and junctions swapped vs v2).** P0–P2 is the honest minimum for
"roads that look real in the editor". P0–P4 is a road *network* rather than a set of roads, which is what an
open world needs first. P5–P6 is the minimum for "a stage can be driven". The old order assumed a circuit
could be built before the network existed; it cannot, because here a stage is carved out of the network
rather than authored beside it.

**Where the weight now sits.** The lane graph put P4b on the critical path, and P4a+P4b together are the
largest phase in the plan — larger than the mesh, larger than the grader. That is the honest read: in an
open world with consumers, junctions *are* the road system, and the splines are the easy part. If schedule
pressure appears, the thing to cut is P8 (auto-routing) and then P7 (graph nodes), never P4b, because
connectivity cannot be retrofitted onto resolved geometry.

**What P4b is *not* sized by** is traffic sophistication (§1.1). The data is the same whether a consumer
builds lane-followers or full gap-acceptance, so the phase is sized by completeness — four queries answered
without the consumer re-deriving anything — and validated by a demo-project reference agent that is itself
the naive traffic the user intends to test with.

---

## 12. Decisions worth taking before any code

1. **Segments are arc-length-ranged Resources, not per-interval scene nodes** (§4.2). Reversible in principle,
   painful in practice once content exists.
2. **Inheritance resolves at read; nothing is pushed down** (§5.3).
3. **The plan alignment is authored; the elevation is solved** (§7), with `follow_terrain` as the explicit
   opt-out rather than the default behaviour.
4. **Superelevation is computed, not painted.** A banking-override field is the escape hatch, not the
   mechanism.
5. **Far-distance roads are terrain, not meshes** (§10). Committing to control-map paint in P3, rather than
   bolting it on, is what keeps the whole LOD story simple.
6. **Exclusion and type references are by resource, never by index** (§5.3).

---

## 13. Open questions

- ~~**Racing or open-world first?**~~ **SETTLED 2026-08-30: open-world first.** Stages are point-to-point
  rally courses with checkpoints, carved out of the open-world network — not loops, and not authored
  separately. Consequences folded into §9 (the Route model replaces the track model), §10 (route as a
  streaming hint), and §11 (junctions move ahead of the runtime layer; racing-line optimisation dropped).
- **Whole-terrain or through a brush?** The graph's own open question (`PASTURE3D_TERRAIN_GRAPH_SPEC.md` §7)
  lands hard here: a road is a long thin thing crossing many brushes, and it may be the case that forces the
  whole-terrain host.
- **Runtime editing, or editor-only?** Everything above is bake-time. Runtime placement (a city builder) is a
  much heavier design.
- **Tunnels and bridges — geometry, or just intervals?** §7 emits the intervals cheaply. Building the
  structures is a large separate system.
- **How much does `RoadGroup` really need to carry?** Its terrain layer and type catalogue are clearly right.
  Whether it also owns traffic side, default speed and prop sets is a judgement call about how many levels of
  inheritance stay comprehensible — four is already a lot.

---

## 14. Sources (survey behind v1 §2)

- Galin, Peytavie, Guérin, Benes — [*Procedural Generation of Roads*](https://perso.liris.cnrs.fr/eric.galin/Articles/2010-roads.pdf), CGF 2010 (the method behind Ghost Recon Wildlands); an [anisotropic A* implementation walkthrough](https://jflynn.xyz/portfolio/houdini-anisotropic-procedural-roads/).
- SideFX — [Labs Road Generator](https://www.sidefx.com/docs/houdini/nodes/sop/labs--road_generator.html), [HeightField Mask by Feature](https://www.sidefx.com/docs/houdini/nodes/sop/heightfield_maskbyfeature.html), [Building terrain with height fields](https://www.sidefx.com/docs/houdini/model/heightfields.html), [Procedural roads for open worlds](https://www.sidefx.com/forum/topic/68239/).
- [dandelion + burdock — *Roads? Where we're going, we don't need roads*](https://dandelion-burdock.com/articles/roads-where-were-going-we-dont-need-roads).
- Epic — [Landscape Spline data in PCG](https://forums.unrealengine.com/t/landscape-spline-data-in-pcg/2677386); [UE5 Landscape & World Partition](https://www.strayspark.studio/blog/ue5-landscape-world-partition-massive-open-worlds).
- [Cities: Skylines network asset creation](https://cslmodding.info/asset/network/) (the node/segment model); [EasyRoads3D v3 manual](https://www.easyroads3d.com/v3/html/quick_start.html) (terrain conforming, side objects).
- [*A Rational Approach to Racing Game Track Design*](https://www.gamedeveloper.com/design/a-rational-approach-to-racing-game-track-design); [*From Generation to Gameplay: Authoring Race Tracks With Repulsive Curves*](https://ieeexplore.ieee.org/iel8/7782673/11301972/10965488.pdf); [RacetrackDesign](https://racetrackdesign.com/) (OpenDRIVE + racing-line export).
- [QuadSpinner Gaea 3](https://quadspinner.com/Gaea3/) (vector tools for roads and rivers).
- [A Chunk Streaming System For An Open World Game](https://www.charlieevans.dev/documents/OpenWorldStreamingReport.pdf).
