# Pasture3D Water — user guide

> ⚠️ **PARTLY OUT OF DATE as of 2026-07-29.** Phase 2 of
> [PASTURE3D_WATER_BODIES_SPEC.md](PASTURE3D_WATER_BODIES_SPEC.md) moved the ocean off the `Pasture3D`
> node onto its own **`Ocean3D`**, and the clock, sun and wave tables onto a **`Pool3DManager`**. So:
>
> - **§1, §3 and §5 describe an API that no longer exists.** There is no `ocean_enabled`,
>   `ocean_material`, `ocean_light_target` or `ocean_wave_*` on `Pasture3D`. Add an `Ocean3D` and a
>   `Pool3DManager` instead; a scene saved before the change keeps its settings and offers a
>   **Migrate Ocean to Ocean3D** button on the terrain.
> - **§2, §4, §6, §7 and §8 are still accurate**, except that `get_water_height()` and friends are on
>   `Ocean3D` rather than on `Pasture3D`, and `sea_level` is the `Ocean3D` node's Y rather than a
>   material uniform.
>
> The full rewrite is Phase 8 of that spec. This notice exists so nobody follows §1 in the meantime.

Water in Pasture3D comes in two forms that share one shader family:

- an **ocean**, drawn on the terrain's clipmap so it follows the camera to the horizon, driven by the
  `Pasture3D` node;
- **lakes and ponds**, which are ordinary `MeshInstance3D`s with a water material on them and need no
  plugin involvement at all.

Both use analytic Gerstner waves generated from a small table, plus one tiling derivative texture for the
detail below the shortest wave. Total texture cost is ~384 KB, shared by every water body in the scene.

Design rationale, measurements and the phase history live in
[PASTURE3D_WATER_SHADER_SPEC.md](PASTURE3D_WATER_SHADER_SPEC.md). This file is how to use it.

---

## 1. Quick start

### An ocean

1. Select your `Pasture3D` node.
2. Tick **`ocean_enabled`**.
3. Set **`ocean_light_target`** to your `DirectionalLight3D`.

That is the whole setup. `ocean_material` defaults to
`addons/pasture_3d/extras/shaders/water/M_water_ocean.tres`.

`ocean_light_target` is not optional decoration — it is how the plugin learns the sun's direction and
colour, which it publishes to the global uniforms every water body reads. Without it the water is lit by
Godot's light loop but its own sun-dependent terms (specular tint, scattering) sit at their defaults.

### A lake or a pond

1. Add a `MeshInstance3D` with a `PlaneMesh`.
2. Give the plane some subdivisions — 100×100 over a 200 m plane is a reasonable start. The waves are a
   **vertex** effect, so a two-triangle plane will not move.
3. Set **`material_override`** to `M_water_lake.tres` or `M_water_pond.tres`.

There is no step 4. No `Pasture3D` node has to exist. Move the mesh to set the water's height.

---

## 2. The presets

All four live in `addons/pasture_3d/extras/shaders/water/`.

| Preset | Shader | Waves | Crest foam | Shore foam | Scattering | Receives shadows |
|---|---|---|---|---|---|---|
| `M_water_ocean.tres` | `water_ocean` | 8 | yes | yes | yes | yes |
| `M_water_ocean_low.tres` | `water_ocean_low` | 4 | no | yes | no | no |
| `M_water_lake.tres` | `water_body` | 4 | no | yes | yes | yes |
| `M_water_pond.tres` | `water_body_low` | 2 | no | yes | no | no |

**The low tiers are different shaders, not the same shader turned down.** The features they drop are
`#define`-d out at compile time, so they are not branched over at runtime. A pond is genuinely cheaper.

To ship a lower-cost ocean, assign `M_water_ocean_low.tres` to `ocean_material`. Measured at 1280×800 with
the ocean filling the frame: high tier 0.295 ms, low tier 0.235 ms, against 0.452 ms for the shader these
replaced.

**Duplicate a preset before editing it.** They are plugin files and a plugin update will overwrite them.

---

## 3. Shaping the waves

### For an ocean — on the node, not on the material

The `ocean_wave_*` properties on `Pasture3D` generate the wave table:

| Property | Meaning |
|---|---|
| `ocean_wave_count` | 1–8. How many Gerstner waves. |
| `ocean_wave_direction` | Degrees. Where the sea is running. |
| `ocean_wave_spread` | Degrees. How far the individual waves fan out around that heading. 0 gives a corduroy sea. |
| `ocean_wave_amplitude` | Metres — **of the longest wave only.** See the warning below. |
| `ocean_wave_length_max` | Metres. The longest wavelength; the rest follow a geometric series down from it. |
| `ocean_wave_steepness` | 0–1. How peaked the crests are. Also drives whitecap coverage and scattering. |
| `ocean_wave_loop_period` | Seconds. The surface repeats exactly on this period. |

> ⚠️ **`ocean_wave_amplitude` is not the wave height.** It is the amplitude of the *longest* wave, and the
> geometric series adds all the others on top. At the defaults the knob reads 1.6 m and the surface
> actually reaches **4.9 m**. If you are sizing a cull margin, a boat's clearance, or a camera height,
> that is the number you want — read it off the table, or use `get_water_height()` and let it tell you.

Do **not** set `_waves` on the ocean material. The plugin regenerates and re-uploads it whenever a knob
changes, so anything you write there is overwritten, and until it is, the CPU height query and the drawn
surface disagree.

### For a lake or pond — on the material

Those materials carry their own `_waves` table, because nothing runs in C++ for a bare mesh. The shipped
tables were produced by the same C++ generator (`bench/WavePresetTables.gd`), so they are shapes the
plugin would itself produce. Edit `wave_steepness` freely; to change the table, run that script with your
numbers rather than hand-editing 32 floats.

### The 10 m floor

The generator will not put a wavelength below 10 m into a large body. Shorter waves lose too much float
precision once you are kilometres from the world origin, and detail at that scale is the texture's job.

The exception is small bodies: below `length_max` 20 m the series continues to `length_max / 2`, so the
pond preset legitimately has a 6 m wave. A pond sits near its own origin and is not in the precision
regime the floor describes — but if you place one kilometres out, set `_water_domain_origin` on its
material to the mesh's position.

---

## 4. Querying the water from code

```gdscript
var h: float = terrain.get_water_height(Vector2(pos.x, pos.z))
var n: Vector3 = terrain.get_water_normal(Vector2(pos.x, pos.z))
boat.position.y = h
```

`get_water_height()` agrees with the drawn surface to within 1 cm anywhere, at any time — that is a gate
the build is tested against, not an aspiration. It is not a cheap function: Gerstner waves displace
sideways as well as up, so the surface is not a heightfield and the query solves that inversion
iteratively (4 steps on calm water, 8 at the ocean defaults). Fine for a few dozen floating objects per
frame; do not call it per particle.

| Method | Returns |
|---|---|
| `get_water_height(global_xz)` | Surface height in world space, at that world XZ. |
| `get_water_normal(global_xz)` | Surface normal in world space. |
| `get_water_surface_point(domain_xz)` | The displaced point for a *domain* parameter — the raw Gerstner evaluation, before the inversion. Mostly of interest to tests. |
| `get_water_time()` | The wrapped clock both CPU and GPU use. Not `Time.get_ticks_msec()`, and not Godot's `TIME`. |

These read the **ocean's** wave table. There is no equivalent for a lake or pond material — those bodies
have no node to ask.

> If `ocean_wave_count` is higher than the wave count its material's variant compiles, the extra waves are
> invisible on screen but present in the query, and the two disagree. The node raises a configuration
> warning when that happens. Lower the count or move to a higher tier.

---

## 5. Global uniforms

Water reads its clock and sun from project-wide shader globals, so one write drives every body in the
scene. The editor plugin registers them in `project.godot` on first run:

| Global | Written by | Purpose |
|---|---|---|
| `water_time` | `Pasture3D`, every physics frame | The wrapped wave clock. |
| `water_time_period` | `Pasture3D`, on change | Loop length; keeps the clock from growing without bound. |
| `water_sun_direction` | `Pasture3D`, from `ocean_light_target` | Sun vector. |
| `water_sun_color` | as above | Sun colour × energy. |

A `Pasture3D` in the scene drives all four whether or not `ocean_enabled` is set, so a terrain with a lake
mesh on it needs nothing extra — set `ocean_light_target` and leave the ocean off.

A scene with **no `Pasture3D` at all** has nothing driving `water_time`, and the water will sit still.
Drive it yourself:

```gdscript
func _physics_process(_delta: float) -> void:
	RenderingServer.global_shader_parameter_set(
			"water_time", fmod(Time.get_ticks_msec() / 1000.0, 120.0))
```

---

## 6. Tuning

The uniforms are grouped in the inspector. The ones worth reaching for first:

**`absorption`** (per-channel, 1/metres) is what makes water look like a particular body of water. Higher
values absorb faster, so the water goes opaque sooner and takes on the complementary colour. The ocean's
low red absorption is why it is blue; the pond's high values are why it is murky.

**`deep_color`** is what you see once absorption is total.

**`detail_strength`** scales the ripple texture's slope. The shipped values are calibrated — 0.25 on the
ocean applies about 0.10 m/m rms slope. Pushing it much past 0.5 tilts normals far enough that reflections
start finding the ground below the horizon, which reads as coloured speckle.

**`base_roughness`** and **`variance_to_roughness`**. If distant water shimmers, *raise*
`variance_to_roughness`, do not lower roughness. Detail that the distance fade removes is converted into
roughness so the specular lobe widens by as much as the geometry it stood for was smoothed away. Lowering
roughness to sharpen distant water is what causes the shimmer.

**`foam_crest_threshold`** is a fraction of the breaking limit, so it interacts with `wave_steepness` on
purpose: calm water gets no whitecaps and a rough sea gets many, without touching this value.

**Refraction is off**, deliberately. It measured 16–22% of the ocean's cost for an effect capped at 22.5%
opacity. To opt in, duplicate `water_ocean.gdshader` and add `#define WATER_REFRACTION` before the
includes.

---

## 7. Performance notes

- **Geometry is nearly free; fragments are not.** Measured clipmap geometry cost is inside the noise
  floor. If you need the water cheaper, use the low tier or reduce how much screen it covers — do not
  reduce `ocean_mesh_lods`.
- **`ocean_vertex_spacing` and `ocean_mesh_lods` move together.** The clipmap is scale-invariant: halving
  the spacing halves the ocean's reach, and one more LOD buys it back. Half-extent is
  `2 × ocean_mesh_size × ocean_vertex_spacing × 2^(ocean_mesh_lods − 1)` — 8192 m at the defaults.
- **Vertex spacing should be about an eighth of the shortest wavelength.** Below that the drawn surface
  visibly cuts the corners off crests and drifts away from what `get_water_height()` reports. The defaults
  give a ratio of 10 and a 1.7 cm gap.
- **Steam Deck performance is unverified.** Every Deck figure in the spec is extrapolated from a desktop
  measurement; no Deck was available. Measure before relying on it.

---

## 8. Troubleshooting

**The water is flat.** The waves are a vertex effect. A `PlaneMesh` with no subdivisions has four
vertices. Add subdivisions.

**The water does not move.** Nothing is driving `water_time`. Either put a `Pasture3D` in the scene (the
ocean does not have to be enabled) or write the global yourself — see §5.

**Distant water shimmers or crawls.** Raise `variance_to_roughness`. See §6.

**Coloured speckle on the surface.** `detail_strength` is too high for the texture in use; normals are
tilting past the horizon.

**The ocean vanishes when the camera moves.** Its cull volume is sized from `sea_level` and the wave
amplitude sum. If you set `sea_level` from code on the material rather than through the plugin, raise
`ocean_cull_margin`.

**Water disappears at a distance you did not expect.** Check the half-extent formula in §7 — the ocean is
finite, and `ocean_mesh_lods` is what sets how far it goes.

**A boat floats above or below the surface.** `get_water_height()` describes the *analytic* surface; the
drawn mesh chords between vertices and sits slightly below it at cell centres. At the defaults that gap is
1.7 cm. If you have lowered `ocean_mesh_lods` or raised `ocean_vertex_spacing`, it grows as the square of
the spacing.
