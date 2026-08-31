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

### P7a implementation notes (done 2026-08-31)

**A PATH is the one port that does not carry a grid.** Everything else in the graph travels as a
`PackedFloat32Array` because everything else *is* a field. A road is not: it is a centreline and a width.
Rasterising it into a grid to send it down a wire would fix its resolution at the wire rather than at the
consumer, throw away the arc length that makes it a road rather than a shape, and make `Road Grade`
re-extract from pixels what the brush already knew exactly. So the resource travels **beside** the grids,
in the same place a multi-output solver's channels already travel (`aux`), and each consumer rasterises
at its own resolution from the real geometry.

A PATH producer still occupies a grid slot, filled with zeros. That is deliberate: the alternative is a
special case in every loop that indexes `grids` by node, bought for one saved array on one node.

**Cache invalidation needed nothing new, and that is worth stating because it looks like it should.** A
PATH produces no input grid, so the geometry never reaches a consumer's input hash by the normal route —
the source's grid slot is zeros before and after a road moves. What saves it is that
`_append_input_signature` already folds the *source node's* revision, and `Road Source` re-emits `changed`
when its path resource does. Two links, both easy to omit, and if either is missing the graph serves the
old distance field forever: the road moves in the viewport and the terrain keeps the old cut. [G] breaks
exactly that.

**The query is analytic, and §8's argument holds up.** Point-to-segment is closed form, the candidate set
comes from a uniform bucket index, and every cell is independent — exact and bit-comparable on both
backends by construction rather than by tolerance, which is precisely what the JFA distance transform
cannot be. `nearest_brute` lives in **production**, not in the gate: it is the definition the indexed path
must match, and a definition that lives only in a test drifts from the thing it defines. It is also what
`nearest` itself falls back to below five segments, where building buckets costs more than checking all
of them.

The index's correctness is one stopping rule — a segment in a bucket *k* rings out is at least
`(k-1) * cell` away, so the search may stop once the best answer beats that. Off by one there returns a
*wrong nearest segment*, which is silent: the distance stays plausible and only `s` is absurd. That is why
[A] compares `segment` and `s` and not only `distance`, over a **hairpin** rather than a straight road —
on a straight road every wrong nearest segment is also nearly the right distance.

[A] also had to learn the difference between a wrong answer and a **tie**. A query level with a vertex is
exactly equidistant from the two segments meeting there, and both answers name the same point; 286 of
1700 probes were that. Counting them as failures would have made the criterion demand that two searches
visiting segments in different orders break ties identically — a claim about iteration order, not about
the answer. A tie is a tie only when the distance *and* the arc length agree.

**`s` and `t` are the two things a flood cannot give you**, and each has a way of being wrong that no
preview shows. `s` is absolute metres: restarting it per segment gives a sawtooth that reads as a
repeating pattern, and normalising it to [0,1] moves every arc-length-placed thing in the graph the moment
the road gets longer. `t` is the across-position **normalised by the half-width there**, so |t| <= 1 is
"on the road" whatever the width does along its length — unnormalised it would just be a signed copy of
`distance` and a corridor mask would be constant-width down a road that is not. Its sign follows the road
system's existing convention (positive is the driver's right), and a fixture sharing the code's own
convention cannot catch that being inverted, so [D]'s control is a road driven the *other way* past the
same world point.

**An unresolved path reads far away.** A Road Source with no host produces nothing, and that is a normal
state — a graph opened on its own, a road not yet baked, a brush just deleted. Both obvious fills are
catastrophic: 0 means every cell is on the road, so a downstream `Road Grade` flattens the whole terrain
to it; INF turns every downstream arithmetic node into NAN and never recovers. `unreachable_distance`
defaults to 10 km.

**A road did not survive being saved.** Reported as "the ribbons and assets have to be regenerated
every time I launch the editor", and the diagnosis is worth keeping because the missing piece was not
where the symptom was.

Almost everything a road produces DOES save: the heightmap it graded, the surface it painted, the
junction records, the lane connectors, the baked runtime. Two things did not. The chunk hosts are built
output and are deliberately unowned by the edited scene — that part is right, and a few thousand
vertices per road in the .tscn would be worse. But `last_alignment`, the SOLVED VERTICAL PROFILE, was a
plain var, and it is what every downstream read goes through: `build_run`, `graph_path`, the ribbon
mesher, the lane graph, `corridor_ahead`, the pace notes. So a reloaded road was drawn into the terrain
and could answer nothing about itself, and nothing could rebuild the mesh even if it had been asked to.

And nothing asked. `build_chunks` is reached only from `resolve_junctions`, which is reached only from a
brush finishing a bake — so the ribbon existed for exactly as long as the editor session that baked it.

Two changes, and the split between them matters. `Pasture3DNodeRoad.last_alignment` is now exported, so
the profile survives; `Pasture3DRoadNetwork.restore_built_output` rebuilds the mesh and the lane graphs
on `_ready`. It deliberately does NOT grade, paint or re-resolve junctions: those three write to the
terrain and to `junctions`, their results are already on disk, and redoing them from a load hook would
dirty the scene and fill the undo history so that opening and closing a scene was a modification.

The stored profile is GUARDED rather than trusted. `Pasture3DRoadAlignment.input_digest` records what it
was solved from — the plan polyline in WORLD space, the sample spacing, the gradient limit, the design
speed, drape-or-solve, and the junction pins — and `restorable_alignment` refuses it when that no
longer matches, so a spline edited or moved with the plugin disabled produces "needs a bake" instead of a
ribbon confidently drawn along a centreline the road no longer has. Both the writing and the checking go
through one function, because a digest computed one way when storing and another way when checking is a
staleness test that passes when it should fail.

`RoadNetworkGate` [I] round-trips a settled network through `ResourceSaver.save` and `ResourceLoader.load`
and requires the same mesh count back with no bake. THE FIRST VERSION OF IT PASSED AGAINST THE BUG: an
in-memory `PackedScene.pack`/`instantiate` keeps sub-resources by REFERENCE, so the modifier came along
whether it was exported or not. A criterion about what survives serialisation has to actually serialise.
Confirmed by A/B: with the export removed the gate reports `0/2 road(s), 7 -> 0 mesh(es)`.

**P7a shipped twice, and the first time it was unreachable.** Both halves are worth recording because
neither is a kernel bug and no criterion in `RoadGraphGate` [A]–[G] could have failed on either.

*The palette dropped both nodes.* `Pasture3DGraphNodeRegistry.categories()` was a hardcoded ordered list,
and the Add menu walks it and pulls the entries matching each name — so an entry whose category is not in
that list is discarded without a word. Road Source and Path Distance were registered, instantiable,
searchable, gated, and absent from the editor. The list is now the ORDER and not the membership: any
category an entry names and the list does not is appended rather than dropped, so the worst outcome is a
category in the wrong place instead of a node nobody can add. `GraphPaletteAndConstantsGate` now asserts
that *every registered node reaches the palette*, which is the general form of the rule; `RoadGraphGate`
[I] asserts the specific one, because a road system gate should fail when the road nodes cannot be added.

*Nothing resolved a Road Source.* The node holds a road key and the host was supposed to fill it in — and
the host side was never built, so a Road Source dropped into a real graph produced an empty path forever.
`Pasture3DRoadNetwork.resolve_graph_paths` now walks a graph's nodes before it is evaluated, from the
terrain brush (which covers the deferred worker path too — that solve runs off the main thread and must
not be walking the scene tree) and from the graph editor's preview (or a road previews as the unreachable
fill and reads as a broken node rather than an unresolved one).

Three decisions inside it, each of which has a plausible opposite:

* **An empty key means "the road this graph is on."** It is the common case by a wide margin, and
  requiring the key to be typed out would make the simplest use of the feature the one that needs a name
  nobody has looked up.
* **A key naming no road leaves the path alone** rather than clearing it. Clearing would make a road
  mid-rename, or one whose brush is being reparented, flatten every terrain reading it for one bake — in
  a way that reads as a solver bug rather than as a failed lookup.
* **An unchanged road must not be re-assigned.** Assigning emits `changed`, which bumps the node's
  revision, which invalidates every downstream cache; a graph containing a road would then re-solve its
  erosion from scratch whenever anything in the scene was baked, and the cache would look broken rather
  than bypassed. The comparison is by CONTENT, since the path is rebuilt from the road each time and is a
  different object even when nothing moved.

`graph_path()` samples the road's own plan polyline at its own vertices rather than resampling onto a
tidier spacing, so a graph-graded road and a brush-graded road cannot differ by a fraction of a metre in
the corners — exactly the size of difference nobody sees and everybody debugs later.

**Road Source blocks native, and the bail is graph-wide.** Native cannot carry a resource down a wire, so
one Road Source drops the *whole* graph to the GDScript path. Said out loud in the node rather than
discovered as a slowdown: it is a real cost, and it is the reason §8 frames the graph route as the case
that needs control, not as the route a plain road should take.

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

### P6a implementation notes (done 2026-08-31)

**The runtime is a COPY, and the copy is the contract.** Nothing in `Pasture3DRoadRun` or
`Pasture3DRoadRuntime` resolves through a scene tree — no brush, no node path that is ever dereferenced,
no terrain. That is what makes §9.1's "loads without the editor plugin and without the terrain" real
rather than aspirational, and it is also what keeps the system inside its scope: Pasture3D publishes road
and lane *data*, and a project's traffic, AI and race logic stay that project's to write. There is nothing
in the runtime to drive anything with. The cost, stated rather than hidden: a run is stale the moment the
road is edited, like a baked lightmap. The network rebuilds it on resolve.

**What reversing flips — four things, and one that must not.** A stage runs both ways on different days,
and `reversed` is applied at read time so nothing is stored twice. Arc length, tangent, curvature *sign*
and bank *sign* all flip. Height does not: negate `z` and the stage runs underground, because a climb
driven backwards is a descent by virtue of travelling the profile the other way, not by inverting it.

The subtle one is the up vector, and the gate's first version asserted it backwards. `bank` flips because
it is signed in the *driver's* frame; the tangent flips too; so the world-space up rotates by
`atan(bank)` about a negated axis and comes out **identical**. That is correct and it is the criterion:
the tarmac's tilt is a fact about the world and driving the other way does not re-cant the road. The
cancellation holds only if both flips are expressed in the same frame, so an up vector that *changed*
with the direction of travel would be a road that banks the wrong way on one of the two stage days.

**Route arc length is not run arc length**, and they are kept visibly distinct. A checkpoint at 250 m
means 250 m into the *stage*, which may be 150 m into the third run; a system that used the run's own
arc length would look for 250 m along a 900 m road, clamp, and place the gate wrongly without a word.

**Surfaces are names, not texture indices.** The texture a road is painted with is a rendering choice
that can change without the road changing. Physics asking "am I on gravel" must not depend on which slot
gravel occupies in this project's asset list — which is also why `surface_intervals()` is built by asking
the override chain at segment boundaries rather than by reading the control map back.

### P6b implementation notes (done 2026-08-31)

**A transition is half and half at the line.** `sample_surface` returns `{primary, secondary, blend}`,
and the blend band straddles the boundary so that at the boundary itself the two surfaces are equal.
Anything else makes the transition asymmetric, and which way it leaned would then depend on the
direction of travel — the same stage would grip differently on the reverse day. Away from a boundary
`secondary` is empty and `blend` is 0, so a caller that ignores blending entirely still gets the right
answer everywhere except inside the transition. The road's own ends are boundaries too and are
deliberately *not* blended: fading into nothing there would fade grip away at the start line.

The gate's monotonicity control was written with the blend read backwards, which made a correct
transition look like it doubled back at the line. Worth recording because the mistake is the natural
one: `blend` runs from *primary* toward *secondary*, and which surface is primary **swaps** as you cross
the boundary, so a fraction-of-gravel reading has to swap with it.

**Pace notes are a peak detect, not a solver.** Corner severity and side come from plan curvature and its
sign; crests and dips from the sign of d²z/ds², which is the vertical solver's own smoothness term;
"tightens" and "opens" from the derivative of curvature *read in the direction of travel*, so reversing
swaps them. Two conventions are stated rather than assumed, because both have a defensible opposite:
severity **1 is a hairpin and 6 is nearly straight**, and a crest is where the profile is concave *down*.
Getting the second backwards calls every brow a dip, which reads as plausible until a driver jumps one.

The control §9.4 asks for is the argument for §7 in executable form: **flatten the profile and the crest
calls must disappear** while the corner survives. A draped road cannot produce these calls at all —
d²z/ds² on a drape is terrain noise sampled at the road's position, so it would emit a crest every few
metres and none of them would mean anything.

**Lookahead is along the route, not around the player.** At stage pace a radius policy loads chunks
roughly when you arrive at them; an active route is a *known corridor*, so the hint returns what lies
ahead **along it**. A run passing close by but not on the route is never pulled in, however large the
window — which is the claim a radius cannot make. The window is biased by speed because time is what
runs out, not distance: 400 m is generous at 60 km/h and about four seconds at stage pace.

**`corridor_ahead()` clears nothing.** It reports which stretch of which runs is about to be driven.
Despawning traffic, pulling cars over and suppressing spawns are the project's own logic, deliberately:
Pasture3D publishes road and lane data and does not implement traffic. What the hook can do is answer the
question precisely, so a traffic system does not have to re-derive the route's geometry to ask it.

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
| **P4a** | **Intersections, geometry** — auto-detection with bridge exclusion, stored resolution, trim-back, priority-driven type and elevation. **Moved ahead of the runtime layer:** open-world-first means junctions exist before any stage does, and a Route is a walk through a junction graph, so routes cannot be modelled until junctions are. | `RoadJunctionGate` — a crossing resolves; a bridge crossing does **not**; the higher-priority road keeps its alignment; a user's junction override survives an unrelated spline edit, and survives its centre drifting across the metre boundary its id is minted from. Plus `RoadNetworkGate` for the seam between them: the network finds the crossing its own brushes make, the pin reaches the minor road's alignment solve, the trim-back keeps that road out of the footprint, and bake→resolve→bake reaches a fixed point. **Built and verified in the editor 2026-08-31.** |
| **P4b** | **Intersections, connectivity** (§6.4) — lane connectors, stop lines, turn permissions, right of way, signal phase groups from `priority`. **Data and queries only; no traffic behaviour ships** (§1.1). Split from P4a because it is roughly the same size again and has a different failure mode. | `RoadLaneGraphGate` — every incoming lane reaches a legal outgoing lane; connectors are tangent-continuous with the lanes they join; every incoming lane has a stop line inside the junction footprint; `traffic_side` flips which turn crosses traffic; a hand-override survives a re-resolve; control: forbidding a turn removes exactly that connector. **Plus the sufficiency check:** a reference agent in the demo project follows lanes and stops at intersections using only public queries — if it needs to re-derive geometry, the data is incomplete. |
**Status 2026-08-31: P4b is complete, sufficiency check included.** `RoadLaneGraphGate` runs fourteen criteria (A–N) covering the cross-section, connectors, stop lines, conflicts, yield rules and the signal cycle. Two decisions are worth recording because both were arrived at by first writing the other one:

- **Right of way is a relation between two CONNECTORS, not between two roads.** "The minor road yields" is wrong at the first junction you look at closely: a right turn off the minor road crosses nothing, and a left turn off the *major* road crosses its own oncoming traffic. Conflicts are therefore found geometrically — two connector curves are tested for a crossing or a shared exit — so a skew crossing or a three-arm junction needs no case of its own, and no case can be missed.
- **`control` is not an input to right of way.** A stop sign says a vehicle must halt, and a signal says it must wait its phase; neither changes who has priority once both are moving. So the permissive turn yields on a green light for exactly the reason it yields at an uncontrolled crossroads, out of one rule rather than two. `signal_state` returns `NONE` rather than `GREEN` at an unsignalised junction, so a naive consumer cannot read a green light where there is no light.

The sufficiency check is `RoadSufficiencyGate`, driving `bench/reference/road_lane_follower.gd` — a reference vehicle that follows lanes, holds at junctions and yields using nothing but the four published queries. It lives in `bench/`, never in `addons/`: it is the customer, not the product (§1.1). The gate reads the follower's *source* and fails if it names any solver, because a consumer that quietly compensates for missing data still works, and that is exactly the failure being looked for.

Writing it found three gaps, all closed in the DATA rather than worked around in the consumer:

| Gap | Why it was a gap |
|---|---|
| A stop line carried no arc length | A vehicle tracks its position as an arc length; turning the world-space point back into one means projecting onto the plan and solving — re-deriving geometry. The solver already knew the number. |
| `lane_stop` answered with the first junction, not the next one | A road crossing two others has two stop lines in the same lane, so a vehicle halfway along was told to stop at the junction it had already passed. Not a consumer error to guard against — a query answering the wrong question. |
| A road would not say how long it was | A consumer following a lane has to know where the road ends; the alternatives were reaching into the modifier's alignment or re-measuring the spline. |

The gate also caught a defect in the follower itself, which is the other half of its value: it decided its movement a stopping distance short of the line and then entered the connector from there, teleporting the vehicle that margin — because a connector begins at the stop line. Criterion [F] asks the *position* whether anything moved further than it could have driven, so no bookkeeping error can hide inside it.
| **P5a** ✅ | **Tier FAR (§10)** — the carriageway painted into the group's reserved control layer: a `surface` coverage mask out of the grader, a pure control-word kernel (`Pasture3DRoadPaint`), and a network paint pass in ascending priority. GDScript; native/GPU later with this as the A/B oracle. | `RoadPaintGate` — coverage is solid to the edge of formation and smoothsteps out over the shoulder (control: zero fade gives a hard edge); control words pack where the engine reads them, asserted against literal shifts (control: a texture id of 31 must not bleed into the next field); the base texture and the hole bit survive a paint (control: `preserve_base` off replaces the base); coverage becomes blend and a bare cell is not written at all (control: full coverage writes every cell); paint order is ascending priority (control: swapping the priorities reverses it); a cell lands where the bake grid says it does (control: a different vertex spacing scales it). |
| **P5b** ✅ | **Tier MID (§10)** — the chunked ribbon: `Pasture3DRoadMesher` (a pure kernel) plus `Pasture3DRoadChunkHost` (LOD swap by distance, hidden beyond tier FAR). Cuts snap to region boundaries and never cross a junction footprint. | `RoadMeshGate` — cuts land on region boundaries (controls: a different region size moves them; a 45° road is cut on both axes); seam vertices are compared for EXACT equality, at LOD 0 and at LOD 2; nothing chunks across a footprint (controls: something did cover it without one, and the road either side survives); LOD coarsens monotonically, never narrows the carriageway, and drops camber before shoulder; ribbon height is checked against the GRADER, not against a copy of its formula; the surface is wound face-up with recomputed normals; UVs run in metres; distance picks the tier its thresholds name (control: more thresholds than LOD levels must clamp, not index past the meshes). |
| **P5c** ✅ | **Tier NEAR (§10)** — lane markings (`Pasture3DRoadMarkings`, a pure kernel split into a stripe *plan* and a *builder*), per-chunk collision at lift zero, and verge props (`Pasture3DRoadProps`) handed to `Pasture3DInstancer` so they stream with terrain regions. | `RoadNearGate` — a one-way road has no centre line whatever its type says (control: the same road two-way must draw one); each divider type draws the stripes it names, with DASHED_SOLID's no-crossing side asserted (control: NONE removes the divider and nothing else); the divider sits where the DIRECTION changes, checked on a 2+1 where that differs from the middle of the road (controls: the two rules must disagree on the fixture; traffic side mirrors it); dashes are placed in absolute arc length and a dash across a cut is split, not dropped (control: a solid stripe stays one run); markings sit on the graded surface and strictly above the ribbon, wound Godot's way; collision matches the GRADED surface, not the lifted ribbon (control: the drawn ribbon must be higher by exactly DEPTH_LIFT); props stand on the side asked for, absolute spacing, and the far verge is TURNED not copied (control: splitting on an exact multiple of the spacing must not double a prop). A criterion that crashes before reporting is counted as a failure. |
| **P6a** ✅ | **Runtime layer, part one** — `Pasture3DRoadRun` / `Pasture3DRoadRuntime` (baked copies, no node references), `Pasture3DRoadRoute` with reversible entries by stable id, derived checkpoint gates, the corridor test, `locate()` and `progress()`, and the validator that names the gap. Loads with no editor and no terrain. | `RoadRouteGate` — the runtime answers with no brush, node or terrain anywhere in the gate (control: surfaces come back as NAMES, not texture indices); reversing flips arc length, tangent, curvature sign and bank sign but NOT height (controls: the fixture must actually turn and bank; the world-space up must be identical both ways because the tarmac does not re-cant); `locate()` round-trips against sampled points (controls: a signed lateral in the driver's frame; the corridor separates verge from off-course); route arc length is not run arc length (controls: the two must differ on the fixture; progress is route-relative); a moved road moves its gates (control: the gate is a plane across the corridor, not a point); the validator names the missing hop (controls: a deleted run is not reported as a missing junction; an unreachable run gets no invented connection). A criterion that crashes before reporting counts as a failure. |
| **P6b** ✅ | **Runtime layer, part two** — `sample_surface()` with blended transitions, `Pasture3DRoadPaceNotes` (§9.4) plus `Route.generate_pace_notes()`, route-driven streaming `lookahead()`, and `corridor_ahead()`, the reporting hook a project's own traffic system uses. | `RoadRouteGate` [G]–[I] — a transition blends and is exactly half and half at the line (controls: no blend away from a boundary; the blend is MONOTONIC across the band; the road's own ends do not fade); pace notes find a known corner at the right severity and side, a known crest and a known surface change (controls: flatten the profile and the crest calls disappear while the corner survives; reversed, the right-hander is called left); lookahead follows the route (controls: an off-route run is absent at a 100 km window; speed widens it; the traffic hook describes the corridor and clears nothing). |
| **P7a** ✅ | **The PATH port and the analytic query** — `PortType.PATH`, `Pasture3DGraphPath`, `Road Source`, `Path Distance` (distance / s / t). | `RoadGraphGate` [A]–[G] — the index agrees with the brute-force oracle over a hairpin (controls: the index must actually narrow the search; the unindexed fallback must agree too); distance clamps at the ends; s is absolute, not per-segment and not normalised (control: lengthening the road must not move it); t is normalised by half-width and positive is the driver’s right (control: the same point on a road driven the other way is on the other side); an unresolved path reads far away, not 0 and not INF; the path travels down the WIRE (control: cut it and the same node falls back); a moved path invalidates the cache (control: an unchanged re-evaluation must be identical). |
| **P7b** | `Road Grade` and `Path Mask`, and the two §8 wirings. | `RoadGraphGate` extensions — the two wirings differ as predicted: erosion before the cut leaves a graded road, erosion masked by `roadbed` leaves the hillside weathered around it. |
| **P8** | Auto-routing: anisotropic A* over graph-produced cost fields (slope, `water_mask`), emitting an editable brush. | `RoadRoutingGate` — found cost ≤ a straight line's; control: a wall in the cost field reroutes it. |

**P5a landed 2026-08-31.** Tier FAR is the tier that is always on, and it is cheap only because P1/P2
already put the road INTO the heightmap: by the time the paint runs the ground is the right shape, and
the only thing left to say is what the surface is made of. Two decisions in it are worth keeping:

* **The road goes in the OVERLAY field and the base is preserved**, with coverage as the blend. The
  shader then feathers base → road, so a half-covered edge cell shows the grass beside the road.
  Writing the road into both fields and feathering with the LAYER weight instead looks identical on
  bare terrain and wrong everywhere else, because the layer weight decides how much of the *layer*
  covers — a half-covered cell would show the layer *below* the road, not what is beside it.
* **A cell below `MIN_COVERAGE` is not written at all**, rather than written at weight zero. A
  weight-zero sample still marks the layer as covering that cell, which would grow the road's footprint
  to the whole corridor and surround every road with a rectangle of dead ground.

The write itself is not gated: `set_control_on_layer` needs regions, a layer stack and a composite,
which no headless gate can assemble honestly — the same boundary `RoadNetworkGate` draws, and the
editor is what covers it. What IS gated out of the wiring is the paint ORDER, because a paint in the
wrong order still produces a fully painted road — just the other road's.

**P5b landed 2026-08-31.** Three things settled here that the rest of tier MID hangs off:

* **A ring is a pure function of arc length.** Not of the chunk, the vertex index, or an accumulated
  walk. That is what makes two chunks meeting at `s` produce *bit-identical* vertices rather than
  nearby ones, and it is why the gate compares seams with `==`. A mesher accumulating `s += step` per
  chunk agrees to six decimal places, passes any tolerance you would think to write, and cracks. The
  other half is that both chunks are ASKED about the same `s`, so a span's final ring is `to` itself
  rather than wherever the walk stopped.
* **The road profile lives in the grader**, as `surface_height`, and the mesher calls it. The ribbon
  and the ground it sits on are the same function of the same arc length; a millimetre of drift would
  z-fight along the whole road and read as a rendering bug rather than as arithmetic. `plan_point_at`
  and `plan_tangent_at` moved there too, and the brush delegates rather than keeping a copy.
* **Chunks are built by the NETWORK, after the resolve** — not at the end of each brush's bake. A
  road's chunks are cut around its junction footprints, and a junction is not resolved until every
  road meeting at it has baked, so a brush chunking itself would cut around the footprints as they
  stood before the road it crosses existed.

Hiding is the interesting end of the LOD chain. Beyond `far_distance` the host simply stops drawing,
because P5a already painted the carriageway into the terrain — the road is still there, still the
right shape, still the right surface. Nothing to fade, nothing to pop, and it only works in that
direction: a system whose farthest tier were "a coarser mesh" would have to cross-fade.

**The junction surface (2026-08-31).** A ribbon that stops at every footprint leaves a hole there. Two
things fill it, and only one of them is a mesh:

* **The major road is not skipped.** `junction_skips()` originally returned a range for *every*
  participant, but `grade_surface` skips only for `not is_major` — the major road paves straight through.
  So the major ribbon stopped where its ground did not, and the graded carriageway showed through the
  gap. This reads as a missing junction mesh rather than as the approach rule being applied to a road it
  does not apply to, which is why `RoadMeshGate` [J] now mirrors the grader's condition rather than
  restating it.
* **The apron follows the major road.** The ground inside a footprint is that road's own crowned,
  banked, climbing surface, so `build_apron` projects every fan vertex onto its plan and heights it
  through the same `surface_height`. A flat disc at the junction's `elevation` would sit a crown above
  the carriageway edges and cut into the middle — a saucer at every crossroads. Gate [I] measures against
  the grader, with a control requiring the flat disc to be visibly wrong on the fixture, and a second
  control on the fan's winding: reversed, an apron is a hole with a lid nobody can see. Its radius is
  `max(radius, widest_trim_back)`, because an apron smaller than the hole leaves a ring of bare ground.

Aprons are hosted on the NETWORK's own chunk host, not on any road's: a junction belongs to no single
road. Each carries one mesh repeated across the LOD slots — two dozen triangles have nothing worth
decimating, and sharing the resource buys them the existing distance culling with no second code path.

**P5c landed 2026-08-31.** Tier NEAR is wrong in a different way to the tiers below it. FAR and MID fail
*visibly* — an unpainted road, a cracked seam, an invisible ribbon. NEAR fails **legibly but falsely**: a
centre line down a one-way road renders perfectly and tells a driver the far lane is oncoming. So the
markings kernel is split in two, `plan()` and `build()`, and the split is what makes that checkable: "this
road has no centre line" is a claim about a handful of numbers, and reading it back out of a mesh would be
an inference about vertex positions instead.

Three things settled here:

* **A one-way road has no centre line**, whatever `divider_type` says, and the divider sits where the
  *direction changes* rather than at the middle of the carriageway. Those coincide on a symmetric two-way
  road and diverge on every 2+1 — which is exactly the road where a driver most needs the line to be right.
  Taking `divider_type` at face value is the obvious implementation and it is wrong on both.
* **Collision is built at lift ZERO.** The ribbon floats `DEPTH_LIFT` above the ground so it cannot z-fight
  with the surface it was graded into; a collider inheriting that lift is a road sitting two centimetres
  above itself, where a wheel rests early and a ground raycast hits the road before the terrain. The lift
  fixes a rendering problem and collision has no rendering problem to fix. And the collider is not the
  driving surface at all — the road went through the heightmap, so the terrain already holds the car up.
  What it adds is *identity*: "am I on tarmac", on its own physics layer, off by default.
* **Props are placed on a HALF-OPEN interval.** Closed at both ends, two chunks meeting at an exact
  multiple of the spacing both place a prop there — two posts in the same hole at every region boundary
  that lands on the grid. The gate's first version cut at 13 m and passed; cutting at 20 m, on a prop,
  failed. Half-open costs at most one prop at the very end of a road.

**Tier switching, fixed 2026-08-31.** Two bugs in the host, both of which presented as something else.

**Distance was measured to the chunk's CENTRE.** A chunk is cut to a terrain region, so at the default
256 m region it is up to 256 m long, and the centre is up to 128 m from either end. Measured that way:

* The chunk you are *standing on* reports ~126 m and is given LOD 1 or 2. Tier NEAR effectively did not
  exist on a full-length chunk, and the road looked permanently coarse — which reads as the LOD meshes
  being wrong, not as the distance being taken from the wrong point.
* Whole chunks popped. A centre crossing `far_distance` took 256 m of road with it in one frame, while
  the near end of that chunk was still 470 m away.

Distance is now to the chunk's own AABB, which is exact and already computed, so it costs a clamp.

**There was no hysteresis.** The thresholds are hard comparisons over a distance that jitters, so a
camera hovering on a line crossed it dozens of times a second and each crossing was a mesh swap. The gate
measures this directly: jittering 1 m either side of the 60 m line for 40 frames produced **40 swaps**
before, and 0 after. `lod_hysteresis` (12 m) is a dead band on every threshold including the far-hide.

Both are gated by `RoadMeshGate` [K] and [L], and [K] needed a **full 256 m fixture** to catch anything
— the gate's usual 100 m road puts its centre at 48 m, inside the first LOD band, where both rules agree.
The control caught that the first time it was written, which is the case for controls in one line.

**A setting on a chunk host is a setting nobody can reach.** Found straight after the two above, by
going to turn collision on and not finding it. Chunk hosts are built output: created on first bake,
replaced on the next, and deliberately not owned by the edited scene, so they never appear in the scene
dock and cannot be selected. Every `@export` on one is therefore unreachable — `collision_enabled` was
declared, defaulted and documented at length, and had no way in. So was the whole LOD group, which is
why the tier bugs above had to be found by reading rather than by turning a knob.

`ribbon_lift` already lived on the **network** for exactly this reason and said so in its own comment;
the rest simply had not followed it. They do now, as an inspector group `Ribbon`, pushed into every host
by `_configure_host` at bake. The three THRESHOLD settings are also pushed live, without a rebake:
choosing a tier is a mesh swap over meshes that already exist, so a slider can move and the road can
answer next frame. The rest change geometry made at bake and cannot honestly be applied without one.

`RoadNetworkGate` [G] is in two halves, because either alone passes on a broken system: the network must
expose a counterpart for every host setting, *and* `_configure_host` must actually copy it — a network
with the exports and no copy looks identical in the inspector and does nothing. The coverage half walks
the host's own exports, so the next setting added to a host is caught the day it is added.

Turning collision on also exposed a second gap: **junction aprons had no colliders**, so the road's
collision identity had a hole at every junction. A raycast asking "am I on tarmac" answered yes along
the road and no in the middle of the crossroads, which is where a vehicle most needs it. Aprons now
build one from the same `_collider_from` the ribbon uses, at lift zero for the same reason.

**A road collider is invisible in the editor, and that is not a bug in the collider.** Ticking Ribbon
Collision changes nothing you can see: chunk hosts are not owned by the edited scene, so Godot draws no
`CollisionShape3D` gizmo for them, and the viewport is identical whether the shapes exist or not. Turning
a setting on and seeing nothing happen is indistinguishable from the setting doing nothing. So the host
now **counts and reports** its shapes in the build line, and Debug > Visible Collision Shapes shows them
when the game runs.

`RoadNetworkGate` [H] makes the claim [G] does not: [G] proves the checkbox reaches the host, [H] proves
the bake turns it into shapes in the tree, on the ribbon *and* on the aprons, on the road physics layer.
It found two things while being written:

* **`_clear` only queued the old build.** A queued node is still a child, still drawn and still
  colliding until the frame ends, so a rebuild left the old ribbon and the old shapes overlapping the
  new ones — z-fighting on a road that just rebuilt, and a doubled collider to anything raycasting in
  between. It now `remove_child`s first and queues after, which also makes a rebuild's result readable
  the moment it returns. The control asserting that collision OFF removes the shapes was reading shapes
  on their way out.
* **Props were not cleared when props were switched off.** `_place_props` clears the instancer by mesh id
  and was skipped entirely when disabled, leaving a verge full of props that no setting claimed. It is
  now always called, with nothing to place.

**There is no P3.** The reorder moved the ribbon mesh from P3 to P5 and the junction split kept the
P4a/P4b names it already had, which briefly left the mesh listed twice. The gap is deliberate rather
than a missing row: renumbering the junction phases would break every reference to them in §6 and
above, for nothing.

**Why the mesh waits (settled 2026-08-31).** Junction geometry constrains the mesher, not the other
way round: a mesher built for a single-spline ribbon has to be reworked once a footprint can merge
with another, stop at a trim-back line and share vertices across a junction. Building it first means
building it twice. And junctions are *visible without it* — trim-back, the merged corridor and
priority-driven elevation all reach the heightmap through P2's grader. What a mesh would not show
either is the lane graph, because connectors and stop lines are curves and data by design; those get
an editor gizmo, which is the right tool for them whenever the mesh lands.

**Closed by the junction gizmo (2026-08-31).** The risk below was that nothing draws a junction until
P5. The editor now draws the resolved footprint, each approach's trimmed end and the major road, which is
what a mesher would consume — so a wrong trim-back is visible rather than arithmetic in the inspector.

**One risk this accepts:** P4a resolves junction footprints without anything having tried to mesh
one, so it could settle on geometry that triangulates badly — a trim-back leaving a sliver, say. The
mitigation is a gate criterion rather than a phase: `RoadJunctionGate` asserts the SHAPE properties a
mesher will need (no gap and no overlap at the trim-back, the merged footprint is one connected
region), not merely that the stored resolution is numerically right.

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
5. **Far-distance roads are terrain, not meshes** (§10). Committing to control-map paint in P5, rather than
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
