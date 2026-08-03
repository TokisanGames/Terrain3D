# Pasture3D Water — user guide

Water in Pasture3D is one shader family and four nodes:

- **`Pasture3DPoolManager`** — one per scene. Owns the clock, the sun, and the named wave profiles
  every body selects from. Nothing moves without it.
- **`Pasture3DOcean`** — an endless sea on a camera-following clipmap. Its Y is the sea level.
- **`Pasture3DPool`** — still water filling a **closed** outline: a lake, a pond, a reservoir.
- **`Pasture3DStream`** — running water along an **open** channel: a river, a creek, a canal.

The last two are normally created by pressing one button on the landscape brush that carved the
ground, and which of them you get is decided by the curve — you do not choose. They share a base
class, `Pasture3DWaterBody`, so buoys (§5) and the query API (§6) work the same on both, and so do
the material, underwater and level controls in §4.

Waves are analytic Gerstner waves generated from a small table, plus one tiling derivative texture
for the detail below the shortest wave. Total texture cost is ~384 KB, shared by every water body in
the scene.

Design rationale, measurements and the phase history live in
[PASTURE3D_WATER_SHADER_SPEC.md](PASTURE3D_WATER_SHADER_SPEC.md) and
[PASTURE3D_WATER_BODIES_SPEC.md](PASTURE3D_WATER_BODIES_SPEC.md). This file is how to use it.

> **Upgrading from a scene made before 2026-07-29?** The ocean used to live on the `Pasture3D` node
> as `ocean_*` properties. Those are gone; §9 maps every one of them to where it went, and your old
> scene keeps its settings and offers a one-press **Migrate Ocean** button until you convert it.
>
> **Upgrading a scene with rivers in it?** Rivers used to be `Pasture3DPool` nodes that noticed their
> curve was open and meshed themselves as a ribbon. They are `Pasture3DStream` now. An old river
> pool draws nothing, says so in its configuration warning, and grows a **Convert to Stream**
> button that swaps it in place, keeping its name, its transform and every setting. One press per
> river, undoable. Lakes are unaffected.

---

## 1. Quick start

### A lake or a pond

1. Carve a basin with a landscape brush — a `Pasture3DMound` with `blend_mode` set to `MIN`, or a
   `Pasture3DTrough`.
2. Press **Add Water** on the brush.

That is the whole setup. The button fills the brush's loop with a `Pasture3DPool` named
`<Brush>Water`, seats it on the spline, picks a wave profile from the loop's size, and creates a
`Pasture3DPoolManager` if the scene does not have one. Undo removes all of it in one step.

If the brush *raises* terrain, the button asks first — water inside a landform is water you cannot
see. "Add Anyway" is a real option; the resulting pool keeps a warning saying why.

Quicker still: a **`Pasture3DPond`** is a brush that carves its basin and presses the button
itself. Drop one in and you have a pond.

### A river

The same button. An **open** spline gives you a `Pasture3DStream` named `<Brush>Stream` instead of a
pool: it follows the channel downhill, takes its surface level from the banks, and flows its texture
along the run. Nothing else to set — the fallback width comes from a `Pasture3DTrough`'s
`bed_half_width`, and the river preset is applied for you.

**The curve picks the node.** Closed is a pool, open is a stream, decided once when the button is
pressed. If you later open a lake's loop, or close a river's channel, the water does not change kind
on its own — the node tells you what is wrong and, on a pool, offers **Convert to Stream**. That is
deliberate: a shape edit silently rewriting what a node *is* was the old behaviour, and it meant a
misplaced click could turn a lake into a river with nothing in the scene to say so.

### An ocean

1. Add a **`Pasture3DPoolManager`** to the scene and set its **`sun_light`** to your
   `DirectionalLight3D`.
2. Add a **`Pasture3DOcean`**. Move it in Y to set the sea level.

`sun_light` is not decoration — it is how the plugin learns the sun's direction and colour, which it
publishes to the global uniforms every water body reads. Without it the water is lit by Godot's light
loop but its own sun-dependent terms (specular tint, scattering) sit at their defaults.

### Water on a bare mesh, with no plugin nodes at all

Put `M_water_lake.tres` or `M_water_pond.tres` on any `MeshInstance3D`. Give the mesh subdivisions —
the waves are a **vertex** effect, so a two-triangle plane will not move. This path needs no manager
and no terrain, but nothing drives its clock either; see §6.

---

## 2. The presets

All five live in `addons/pasture_3d/extras/shaders/water/`.

| Preset | Shader | Waves | Crest foam | Shore foam | Scattering | Flow | Receives shadows |
|---|---|---|---|---|---|---|---|
| `M_water_ocean.tres` | `water_ocean` | 8 | yes | yes | yes | no | yes |
| `M_water_ocean_low.tres` | `water_ocean_low` | 4 | no | yes | no | no | no |
| `M_water_lake.tres` | `water_body` | 4 | no | yes | yes | no | yes |
| `M_water_pond.tres` | `water_body_low` | 2 | no | yes | no | no | no |
| `M_water_river.tres` | `water_river` | 3 | no | yes | no | **yes** | no |

**The low tiers are different shaders, not the same shader turned down.** The features they drop are
`#define`-d out at compile time, so they are not branched over at runtime. A pond is genuinely
cheaper.

**`M_water_river.tres` is the one preset that is not drop-anywhere.** It needs three things only a
`Pasture3DStream` mesh writes: the flow direction and speed in `ARRAY_COLOR.rgb`, the distance to the
bank in `ARRAY_COLOR.a`, and the flow travel time in `UV2.x`. On a bare `MeshInstance3D` the vertex
colours read white and `UV2` reads zero — a full-speed diagonal with every vertex at the same phase,
so the whole surface bobs in unison. On a `Pasture3DPool` it is harmless but inert: pools write a
neutral colour that decodes to no flow at all.

Measured at 1280×800 with the water filling the frame: ocean high tier 0.295 ms, low tier 0.235 ms,
against 0.452 ms for the shader these replaced. River costs **+7%** over lake (0.155 vs 0.145 ms) for
the two extra texture fetches its flow cross-fade needs.

**Press "Make Unique" before editing a preset.** They are plugin files and a plugin update will
overwrite them. The button is on every water body; "Save Unique Material" then writes your version out
as a project asset. Editing a preset in place also loses its documentation header, because the Godot
editor strips `.tres` comments when it re-saves.

---

## 3. Wave profiles

Every body selects a **profile by name** from the scene's `Pasture3DPoolManager`. A fresh manager
ships four:

| Profile | Waves | Longest | Amplitude sum | Intended for |
|---|---|---|---|---|
| `ocean_default` | 8 | 137 m | 4.88 m | `Pasture3DOcean` |
| `lake_calm` | 4 | 25 m | 0.669 m | Lakes over ~40 m across |
| `pond_still` | 2 | 12 m | 0.076 m | Ponds under ~40 m across |
| `river_flow` | 3 | 10 m | 0.134 m | Nothing, since the stream ripples landed — see §4 |

`lake_calm` and `pond_still` generate exactly the tables inside `M_water_lake.tres` and
`M_water_pond.tres` — the build checks that every run, so a profile and the preset named after it
cannot drift into being two different lakes.

### The knobs, on `Pasture3DWaveProfile`

| Property | Meaning |
|---|---|
| `profile_name` | The selection key. Bodies name it in `wave_profile`. |
| `wave_count` | 1–8. How many Gerstner waves. |
| `direction_deg` | Where the sea is running. |
| `spread_deg` | How far the individual waves fan out around that heading. 0 gives a corduroy sea. |
| `amplitude` | Metres — **of the longest wave only.** See the warning below. |
| `length_max` | Metres. The longest wavelength; the rest follow a geometric series down from it. |
| `steepness` | 0–1. How peaked the crests are. Also drives whitecap coverage and scattering. |

The loop period is **not** on the profile. It is `loop_period` on the manager, because the frequency
quantisation that makes the clock wrap seamless is computed against a single period for the whole
scene.

> ⚠️ **`amplitude` is not the wave height.** It is the amplitude of the *longest* wave, and the
> geometric series adds all the others on top. At the ocean defaults the knob reads 1.6 m and the
> surface actually reaches **4.9 m**. If you are sizing a cull margin, a boat's clearance, or a
> camera height, that is the number you want — `get_amplitude_sum()` on the profile reports it.

Do **not** set `_waves` on a material driven by a manager. It is regenerated and re-uploaded whenever
a knob changes, so anything written there is overwritten, and until it is, the CPU height query and
the drawn surface disagree. Materials on bare meshes are the exception: they carry their own table
because nothing runs in C++ for them. To regenerate one, run `bench/WavePresetTables.tscn` rather
than hand-editing 32 floats.

### The 10 m floor

The generator will not put a wavelength below 10 m into a large body. Shorter waves lose too much
float precision once you are kilometres from the world origin, and detail at that scale is the
texture's job.

The exception is small bodies: below `length_max` 20 m the series continues to `length_max / 2`, so
`pond_still` legitimately has a 6 m wave and `river_flow` a 5 m one. Those sit near their own origin
and are not in the precision regime the floor describes. Every water body sets `_water_domain_origin`
from its own position, so a pond placed kilometres out is still fine; a **bare mesh** is not, and
needs that instance uniform set by hand.

---

## 4. `Pasture3DPool` and `Pasture3DStream` — the water bodies

The two nodes the Add Water button creates. Both can be added by hand. Everything in this section
down to *Underwater* is shared — it lives on their common base, `Pasture3DWaterBody` — and each has
one section of its own after that.

### Source (both)

| Property | Meaning |
|---|---|
| `source_spline` | A `Path3D` — normally a brush's. Carries the curve **and its transform**, so moving the brush moves the water. |
| `curve` | A raw `Curve3D`, overriding `source_spline`. Read in **this node's** space, so a curve lifted off an offset brush lands offset. For water authored without a brush. |

**The class decides what gets built, not the curve.** A `Pasture3DPool` fills a closed outline; a
`Pasture3DStream` follows an open channel. Give a pool an open curve and it says so and offers
**Convert to Stream**; give a stream a closed one and it runs a channel all the way around the loop,
which is a moat and is occasionally what you want.

### Shape (both)

| Property | Meaning |
|---|---|
| `edge_offset` | Metres the mesh is grown past the curve, so its rim is buried in the bank instead of ending in open air. |
| `fill_offset` | Metres added to the level when **Fit to Curve** runs. Negative sits the water under the rim, which is where a basin's water is. On a stream it is only the fallback — see below. |
| `vertex_spacing` | 0 = automatic, at an eighth of the profile's shortest wavelength. This is correctness, not taste — see §7. |
| `max_vertices` | Ceiling on the generated mesh. Raise it to buy resolution on a large body; lower it to catch a spacing mistake before the editor locks up. The build refuses past it and says what it would have taken. |

**Fit to Curve** seats the node on its spline: XZ onto the spline's origin, Y onto the curve's lowest
point plus `fill_offset`. It is never automatic, because the brushes re-snap their spline points to
the terrain and an automatic fit would move the water level whenever the ground under the rim moved.

Dragging a **pool** in **Y** moves the water level. Dragging it in **XZ** does not move the water —
the spline decides where that is — but it does move `_water_domain_origin`, which is what keeps wave
phase precise far from the world origin. Water driven by a bare `curve` is the exception and travels
with its node in both.

### `Pasture3DStream` only — the channel, the banks and the flow

| Property | Meaning |
|---|---|
| `ribbon_half_width` | **Fallback** half-width, before `edge_offset` is added each side. Used only where the banks cannot be sampled. |
| `bank_height` | Metres below the bank top that the water sits — freeboard. This is the level control; the bed does not set it. |
| `bank_search_width` | How far out to look for the bank top. 0 = automatic, from the `Pasture3DTrough` that carved the channel. |
| `bank_smoothing` | Passes of smoothing over the sampled surface line. Terrain samples are noisy, and a river surface that climbs even by centimetres reads as broken. |
| `flow_speed` | Metres per second the water runs. Drives the texture advection, the ripple crests and the ripple amplitude. It moves the *surface*, not the water body: nothing is simulated and no buoy is pushed downstream by it. |
| `flow_slope_gain` | How much a downhill gradient adds to that speed, so steep reaches read as rapids. |
| `flow_reverse` | Run the flow the other way, for a channel drawn from the mouth up. Flips which way `flow_slope_gain` counts as downhill, and which way the ripples travel. |

`wave_profile` is greyed out on a stream, and that is the interesting part.

**A river does not use the Gerstner wave table at all.** A wave in that table carries one
world-space heading; a river bends; so on every reach that heads against it, the crests travel
*upstream*. There is no amplitude, steepness or direction that fixes it — the model has one
direction and a river has many — and the only setting that hides it is amplitude 0, which is what
this plugin's own demo scene had to ship before this was solved.

So a stream's surface motion comes from four **material** uniforms instead, on
`M_water_river.tres`:

| Uniform | Meaning |
|---|---|
| `ripple_amplitude` | Crest-to-trough height at full speed, in metres, before the bank fade. Centimetres, not metres: this is chop on a channel, not swell on a sea. |
| `ripple_frequency` | How often the surface bobs at a fixed point, in Hz. **Not** a wavelength — see below. |
| `ripple_speed_ref` | The flow speed at which ripples reach full amplitude. Below it they scale down, so a river slowing into a pool goes glassy by itself. |
| `ripple_bank_fade` | Where across the half-width the ripples start fading out, so no crest stands proud of the dry bank. |

They are on the material and not on the node because everything that differs *between reaches* —
how fast the water is running, how steep, how near the bank — is already carried per-vertex by the
mesh. The material only has to say how much ripple a given speed earns.

**Why frequency and not wavelength.** The mesh carries, per vertex, the *flow travel time* from the
head of the channel, and the ripples are a function of it. That one substitution is what makes
crests run downstream on every reach — travel time increases along the channel by construction, so
there is no reach on which the phase can turn around. It also makes crests move at the **local**
flow speed for free, with the wavelength stretching through fast reaches and packing together in
slow ones, which is what real water does. Frequency is the thing that stays constant in steady
flow, so frequency is the knob.

**`ripple_frequency` is quietly expensive.** Wavelength is speed ÷ frequency and the mesh has to
resolve it, so doubling the frequency halves the vertex spacing a stream picks and roughly
quadruples its vertex count. The shipped 0.3 Hz is about a 5 m undulation at 1.5 m/s. Anything
finer than that belongs to the detail normal map, which already flows along the same channel and
costs nothing extra.

**A stream's surface comes from its banks, not its spline.** A `Pasture3DTrough`'s spline is the bed
*floor*, so offsetting it downward — which is what `fill_offset` means on a pool — buries the water
under its own channel. Instead each row measures the terrain on both sides, takes the **lower**
crest (water cannot stand higher than the side it would spill over) and sits `bank_height` below it.

Two things follow for free. **Depth varies**: a reach where the bed rises toward the surface becomes
a ford the player can wade, with nothing authored. And **width varies**: the waterline is found the
same way, per side, so the strip widens through a shallow reach, narrows in a gorge, and sits
off-centre where the channel is cut into a slope.

With no `Pasture3D` in the scene there is nothing to sample, and the surface falls back to bed +
`fill_offset` at a constant width — which is why `fill_offset` greys out on a stream over terrain
and comes back when there is none.

If a river fills to somewhere absurd partway up a hillside, `bank_search_width` is the knob: the
search has to reach the bank crest and stop, and pushed out onto the slope above it will find its
"bank" up there and fill to it.

### Underwater

| Property | Meaning |
|---|---|
| `underwater_enabled` | Build the submersion volume at all. |
| `volume_depth` | How far below the surface "in this water" reaches. |
| `underwater_fog` | Spawn a `FogVolume` tinted from the water material. |
| `underwater_overlay` | Spawn the screen effect when the camera goes under. Runtime only. |
| `overlay_transition` | Seconds to ramp that effect in and out across the crossing. |

Signals: `body_submerged(body)`, `body_surfaced(body)`, `camera_submerged(bool)`.

> **`body_submerged` will not fire for a `StaticBody3D`.** Godot 4.4+ defaults 3D physics to Jolt,
> whose areas do not report static bodies unless
> `physics/jolt_physics_3d/simulation/areas_detect_static_bodies` is enabled. Rigid, character and
> kinematic bodies are reported normally. `is_point_underwater()` has no such limit — it is geometry,
> not physics, so anything at all can be asked about it directly.

### Selecting one

A pool draws only an internal-child mesh, so there is nothing in the viewport to click. An **orange
octahedron** floats above the water, the same marker the brushes use in purple; click it to select
the pool. While it is selected the underwater volume's box is outlined too.

---

## 5. Floating things — `Pasture3DBuoy`

One buoy is one **sample point**, not one boat. Three or four on a hull give pitch and roll for free,
because each computes its own submersion at its own position and pushes at its own offset. One gives
a bobbing barrel.

Put them as children of a `RigidBody3D`. They find the hull themselves, and they find the water
themselves — a boat crossing from a lake into the ocean does not need telling.

| Property | Meaning |
|---|---|
| `displacement` | Cubic metres **this buoy** displaces at full submersion. |
| `full_depth` | Metres of submersion for full force. |
| `linear_drag` | Newtons per m/s at full submersion. |
| `angular_drag` | Per second at full submersion. Applied once per **body**, not once per buoy. |
| `sample_interval` | Evaluate the wave height every N ticks and hold it between. For crowds; leave at 1 on a hero boat. |
| `water_body` | Optional override. Empty = ask the manager. |

**The arithmetic that decides whether it floats**, and the reason `displacement` is in cubic metres
rather than some tuning unit:

```
sum(displacement) over the body's buoys  must exceed  mass / 1000
equilibrium submersion  f = (mass / 1000) / sum(displacement)
it settles at  f × full_depth  below the surface
```

The node reports both numbers in its configuration warning, so "why does my boat sink" is a sentence
rather than a puzzle.

Budget: **64 buoys inside 0.5 ms per physics tick**, measured. `sample_interval` is the knob if you
need more than that.

---

## 6. Querying the water from code

```gdscript
var body := manager.body_at(global_position)      # the pool or ocean at a point, or null
if body:
    var h: float = body.get_water_height(Vector2(global_position.x, global_position.z))
    var n: Vector3 = body.get_water_normal(Vector2(global_position.x, global_position.z))
```

`Pasture3DOcean`, `Pasture3DPool` and `Pasture3DStream` all answer these, so code does not need to
know which kind of water it is standing in.

| Method | On | Returns |
|---|---|---|
| `get_water_height(global_xz)` | ocean, pool, stream | Surface height in world space. On a stream, the height of the reach you are over. |
| `get_water_normal(global_xz)` | ocean, pool, stream | Surface normal in world space. |
| `contains_point(global_pos)` | ocean, pool | Is this point in this body's water? A polygon test, not a bounding box. |
| `is_point_underwater(global_pos)` | pool | The same question under the name the underwater feature asks it by. |
| `body_at(global_pos)` | manager | The innermost body containing a point. Finite bodies first, ocean as the fallback. |
| `get_water_time()` | manager | The wrapped clock both CPU and GPU use. Not `Time.get_ticks_msec()`, and not Godot's `TIME`. |
| `evaluate_height(profile, domain_xz)` | manager | Raw Gerstner evaluation for a named profile, before the inversion. Mostly of interest to tests. |

`get_water_height()` agrees with the drawn surface to within 1 cm anywhere, at any time — that is a
gate the build is tested against, not an aspiration. It is not a cheap function: Gerstner waves
displace sideways as well as up, so the surface is not a heightfield and the query solves that
inversion iteratively (4 steps on calm water, 8 at the ocean defaults). Fine for a few dozen floating
objects per frame; do not call it per particle.

Containment is cheap, though — it reads the mesher's own inside mask, so it is a bounds check and an
array lookup for all but the cells the shoreline crosses.

---

## 7. Global uniforms

Water reads its clock and sun from project-wide shader globals, so one write drives every body in the
scene. The editor plugin registers them in `project.godot` on first run.

| Global | Written by | Purpose |
|---|---|---|
| `water_time` | `Pasture3DPoolManager`, every physics frame | The wrapped wave clock. |
| `water_time_period` | `Pasture3DPoolManager`, on change | Loop length; keeps the clock from growing without bound. |
| `water_sun_direction` | `Pasture3DPoolManager`, from `sun_light` | Sun vector. |
| `water_sun_color` | as above | Sun colour × energy. |

A scene with **no `Pasture3DPoolManager`** has nothing driving `water_time`, and the water will sit
still. That is the normal case for the bare-mesh path in §1. Drive it yourself:

```gdscript
func _physics_process(_delta: float) -> void:
    RenderingServer.global_shader_parameter_set(
            "water_time", fmod(Time.get_ticks_msec() / 1000.0, 120.0))
```

---

## 8. Tuning

The uniforms are grouped in the inspector. The ones worth reaching for first:

**`absorption`** (per-channel, 1/metres) is what makes water look like a particular body of water.
Higher values absorb faster, so the water goes opaque sooner and takes on the complementary colour.
The ocean's low red absorption is why it is blue; the pond's high values are why it is murky. It also
drives the underwater fog and the underwater screen tint, so those follow the surface automatically.

**`deep_color`** is what you see once absorption is total.

**`detail_strength`** scales the ripple texture's slope. The shipped values are calibrated — 0.25 on
the ocean applies about 0.10 m/m rms slope. Pushing it much past 0.5 tilts normals far enough that
reflections start finding the ground below the horizon, which reads as coloured speckle.

**`base_roughness`** and **`variance_to_roughness`**. If distant water shimmers, *raise*
`variance_to_roughness`, do not lower roughness. Detail that the distance fade removes is converted
into roughness so the specular lobe widens by as much as the geometry it stood for was smoothed away.
Lowering roughness to sharpen distant water is what causes the shimmer.

**`foam_crest_threshold`** is a fraction of the breaking limit, so it interacts with `steepness` on
purpose: calm water gets no whitecaps and a rough sea gets many, without touching this value.

**`flow_period`** (river only) is how long the surface texture advects before the cross-fade hands
over to a fresh copy. Longer is more coherent motion but more visible smearing at the end of each
cycle. It is quantised against `loop_period` so the hand-over cannot be caught mid-way when the clock
wraps; `flow_quantise` turns that off, and exists so the seam can be demonstrated.

**Refraction is off**, deliberately. It measured 16–22% of the ocean's cost for an effect capped at
22.5% opacity. To opt in, duplicate `water_ocean.gdshader` and add `#define WATER_REFRACTION` before
the includes.

---

## 9. Upgrading from the `ocean_*` properties

Before 2026-07-29 the ocean lived on the `Pasture3D` node. It now lives on `Pasture3DOcean` and
`Pasture3DPoolManager`. **A scene saved before the change keeps its settings**: they are held on the
terrain, reported in a configuration warning, and converted by a **Migrate Ocean** button that
creates both nodes and transfers everything in one undoable step. They are not re-serialised, so
re-saving without migrating loses them — migrate first.

| Old property on `Pasture3D` | Now |
|---|---|
| `ocean_enabled` | `Pasture3DOcean.enabled`, or just delete the node |
| `ocean_material` | `Pasture3DOcean.material` |
| `ocean_light_target` | `Pasture3DPoolManager.sun_light` |
| `ocean_mesh_lods` | `Pasture3DOcean.mesh_lods` |
| `ocean_mesh_size` | `Pasture3DOcean.mesh_size` |
| `ocean_tessellation_level` | `Pasture3DOcean.tessellation_level` |
| `ocean_vertex_spacing` | `Pasture3DOcean.vertex_spacing` |
| `ocean_cull_margin` | `Pasture3DOcean.cull_margin` |
| `ocean_cast_shadows` | `Pasture3DOcean.cast_shadows` |
| `ocean_gi_mode` | `Pasture3DOcean.gi_mode` |
| `ocean_render_layers` | `Pasture3DOcean.render_layers` |
| `ocean_domain_origin` | `Pasture3DOcean.domain_origin` |
| `ocean_wave_count` | `Pasture3DWaveProfile.wave_count`, on the manager's profile |
| `ocean_wave_direction` | `Pasture3DWaveProfile.direction_deg` |
| `ocean_wave_spread` | `Pasture3DWaveProfile.spread_deg` |
| `ocean_wave_amplitude` | `Pasture3DWaveProfile.amplitude` |
| `ocean_wave_length_max` | `Pasture3DWaveProfile.length_max` |
| `ocean_wave_steepness` | `Pasture3DWaveProfile.steepness` |
| `ocean_wave_loop_period` | `Pasture3DPoolManager.loop_period` |

Two things moved rather than being renamed:

- **Sea level.** There was never an `ocean_sea_level` property — it was the material's `sea_level`
  uniform. It is now the **`Pasture3DOcean` node's Y**. Move the node.
- **`get_water_height()` and friends** were on `Pasture3D`. They are on the bodies now, and
  `Pasture3DPoolManager.body_at()` is how you find the right one. See §6.

---

## 10. Performance notes

- **Geometry is nearly free; fragments are not.** Measured clipmap geometry cost is inside the noise
  floor. If you need the water cheaper, use the low tier or reduce how much screen it covers — do not
  reduce `mesh_lods`.
- **`vertex_spacing` and `mesh_lods` move together** on the ocean. The clipmap is scale-invariant:
  halving the spacing halves the ocean's reach, and one more LOD buys it back. Half-extent is
  `2 × mesh_size × vertex_spacing × 2^(mesh_lods − 1)` — 8192 m at the defaults.
- **Vertex spacing should be about an eighth of the shortest wavelength.** Below that the drawn
  surface visibly cuts the corners off crests and drifts away from what `get_water_height()` reports.
  The pool and the stream do this for you when `vertex_spacing` is 0.
- **Water-body rebuilds are debounced and off the interaction path.** A 500 m lake at automatic spacing is
  169 k vertices in about 120 ms. Rebuilds happen when the curve changes, when the brush moves, or on
  demand.
- **The underwater overlay** costs 0.043 ms per megapixel — about 0.09 ms at 1080p.
- **Steam Deck performance is unverified.** Every Deck figure in the spec is extrapolated from a
  desktop measurement; no Deck was available. Measure before relying on it.

---

## 11. Troubleshooting

**The water is flat.** The waves are a vertex effect. A `PlaneMesh` with no subdivisions has four
vertices. Add subdivisions. (`Pasture3DPool` and `Pasture3DStream` never have this problem — they
tessellate themselves.)

**The water does not move.** Nothing is driving `water_time`. Add a `Pasture3DPoolManager`, or write
the global yourself — see §7.

**The Add Water button says my brush raises terrain.** It does, and water inside a landform is hidden
by it. Set the brush's `blend_mode` to `MIN` to carve a basin, or press "Add Anyway" if you meant a
raised pool on a plateau.

**A pool warns about `volumetric_fog_enabled`.** A `FogVolume` renders nothing at all unless the
scene's `Environment` has volumetric fog switched on — no error, just no fog. Enable it on the
`WorldEnvironment`, or turn off `underwater_fog`.

**The river's texture slides diagonally, or the whole surface bobs in unison.** `M_water_river.tres`
is on a mesh that is not a `Pasture3DStream`. With no vertex colours it reads white — a diagonal at
full speed — and with no `UV2` every vertex shares one phase. Put it on a stream.

**My river is flat.** Check `flow_speed`. Ripple amplitude scales with it and reaches full size at
`ripple_speed_ref` (2 m/s by default), so a river authored at 0.1 m/s is *correctly* glassy. Also
check `wave_profile` is not what you are trying to tune: it does nothing to a stream's surface (§4).

**My river costs more vertices than I expected.** `ripple_frequency`. Wavelength is speed ÷
frequency and the mesh resolves it, so the knob that looks like a style choice is really the
density dial. Set `vertex_spacing` explicitly if you want to decide it yourself.

**The pool's water did not move when I moved the brush.** It should — check `source_spline` is set
rather than `curve`. A raw `Curve3D` carries no transform and does not track anything.

**Distant water shimmers or crawls.** Raise `variance_to_roughness`. See §8.

**Coloured speckle on the surface.** `detail_strength` is too high for the texture in use; normals
are tilting past the horizon.

**The ocean vanishes when the camera moves.** Its cull volume is sized from the node's Y and the wave
amplitude sum. Raise `cull_margin`.

**Water disappears at a distance you did not expect.** Check the half-extent formula in §10 — the
ocean is finite, and `mesh_lods` is what sets how far it goes.

**A boat floats above or below the surface.** `get_water_height()` describes the *analytic* surface;
the drawn mesh chords between vertices and sits slightly below it at cell centres. At the defaults
that gap is 1.7 cm.

**A boat sinks.** Read the buoy's configuration warning: it quotes the displacement the body has and
the displacement it needs. See §5.
