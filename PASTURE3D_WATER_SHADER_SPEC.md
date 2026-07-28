# Pasture3D Water — Replacement Shader Spec

Status: **all six phases implemented and measured, 2026-07-27 to 2026-07-28, on desktop only — results
in §8.1-§8.6. Five of the six goals in §1 are met and verified. G1 is NOT: no Steam Deck, and no
lower-spec GPU either, was ever available, so every Deck figure in this document is extrapolated from
one desktop part and none of it is validated (§11 q7). Phase 3 changed two design decisions and
retired one target (§8.4); Phase 4 corrected §4.3 (§8.5); Phase 5 found two shading defects that had
been shipping since Phase 3 (§8.6).**
Replaces the example ocean shader (now retired to
[bench/legacy/ocean_shader.gdshader](project/bench/legacy/ocean_shader.gdshader)) with a water
system that is (a) fast enough that a Steam Deck renders full-screen water without breaking frame, (b)
versatile enough to cover ocean, lake and pond from one code base, (c) memory-frugal, and (d) queryable
from C++ so gameplay can float things on it.

The existing shader is kept on disk as `ocean_shader_legacy.gdshader` for A/B comparison during
development and is deleted at the end of Phase 5.

## Decisions (from the design interview, 2026-07-27)

| Question | Decision | Consequence for this spec |
|---|---|---|
| Water body geometry | **Decouple from the clipmap** | The shader must run on any `MeshInstance3D`. The clipmap geomorph block moves behind `#ifdef WATER_CLIPMAP`. Ocean uses the Pasture3D ocean mesher; lakes/ponds are plain meshes the user places at any altitude. |
| CPU height queries | **Required** (buoyancy, boats, swimming) | The wave function must be exactly reproducible in C++. Locks in analytic Gerstner with a small fixed wave table; rules out texture-driven vertex displacement. The **C++ side owns the wave table** so parity is structural, not a maintenance chore (§4.3). |
| Renderer targets | **Forward+ only** | Free to use `hint_depth_texture`, `hint_screen_texture`, reflection probes. No Mobile/Compatibility variant required, so no need to hedge around `hint_normal_roughness_texture` being Forward+-only. |
| Detail source | **Hybrid: analytic waves + one small tiling texture** | Vertex stage does 4–8 Gerstner waves with analytic derivatives; fragment stage does **zero procedural noise** — fine detail comes from a mipmapped tiling derivative map. Costs ~400 KB VRAM (up from 0) to buy roughly a 10× fragment ALU reduction. |

---

## 0. Why the current shader is slow (the baseline we are beating)

Measured by inspection of [ocean_shader.gdshader:167](project/bench/legacy/ocean_shader.gdshader:167).
Per **fragment**:

| Work | Count | Source |
|---|---|---|
| `hash()` calls → 32-bit integer multiplies | 72 → **216** | `ocean_height()` called 3× (value + 2 finite-difference taps), `ITERATIONS_FRAGMENT = 3`, 2 `octave()` per iteration, 4 `hash()` per `octave()` |
| `sin()` | 36 | 2 per `octave()` × 18 |
| `inversesqrt()` | 18 | 1 per `octave()` |
| `pow()` | ~6 | fresnel, depth curve, 3× in scattering |
| `mat4 × vec4` | 4 | depth→world reconstruction, done twice |
| texture fetches | 4 | 2× depth, 1× screen, 1× foam |

At 1280×800 with water filling the frame that is roughly **220 M integer multiplies and 37 M `sin` per
frame**. Steam Deck has 1.6 TFLOPs FP32 against 56 GT/s texture fill — it is **ALU-poor and
texture-rich**, which is precisely the wrong shape for an all-procedural shader. 32-bit integer multiply
is quarter-rate or worse on much of the hardware in scope.

**Phase 0 confirmed this empirically** (§8.1): the shader costs **0.392 ms at 1280×800 on an RTX 3070**
with water filling the frame, of which ~98% is per-pixel work and ~0% is geometry. Cost scales with
covered pixels, not triangles — the most expensive camera angle is the one with the *fewest* draw calls.

Three structural causes, all fixed by this spec:

1. **Finite-difference normals.** Three full evaluations of the wave function per pixel to get one normal.
   Analytic derivatives give the same normal from one evaluation (§3.2).
2. **No band-limiting.** `ITERATIONS_FRAGMENT` is a `const int`, so a horizon pixel covering a kilometre of
   water runs the same 3 octaves as one at your feet — full cost *and* full aliasing. Mipmapped textures
   solve both for free (§3.3).
3. **All detail in the fragment stage.** Nothing is amortised over vertices, and nothing is precomputed.

Secondary defects carried over as fix-list items (§9).

---

## 1. Goals / non-goals

**Goals**

- **G1.** ⚠️ *UNVERIFIED — the one goal still open after Phase 5.* ≤ **1.0 ms** GPU for full-screen water
  at 1280×800 on Steam Deck (LCD, 15 W TDP), high tier; ≤ **0.6 ms** low tier. Legacy shader is the A/B
  baseline. **No Steam Deck was ever available**, and no lower-spec GPU either, so this has been
  extrapolated from a single desktop part throughout. Desktop, RTX 3070, water filling the frame:
  **0.295 ms high / 0.235 ms low, against 0.452 ms for the legacy shader** (§8.6). Do not quote a Deck
  number from this document — see §11 q7.
- **G2.** ✅ *met, Phase 5.* One code base serves ocean, lake and pond, differing only by preset uniforms
  and which thin `.gdshader` wrapper is used. Four wrappers over four shared includes, four presets
  (§6). The low tiers are separate shaders rather than the same shader turned down, so their cut work
  is not branched over at runtime: measured 0.235 ms against 0.295 (§8.6).
- **G3.** ✅ *met, Phase 3.* ≤ **512 KB** total VRAM for all water textures, all bodies, at any count of
  water bodies. Measured **384 KB** (§8.4).
- **G4.** ✅ *met, Phase 4.* `Pasture3D::get_water_height(Vector2 xz)` in C++ agrees with the GPU surface to
  within **1 cm** at any world position, at any time. Measured: 0 of 384 probes differ by even **1 mm**,
  at a 12 km domain origin and a 300 m sea level, at six instants (§8.5).
- **G5.** ✅ *met, Phase 3.* No shimmer. Water at 500 m must be stable under camera motion without relying
  on TAA. Measured 30× less speckle than legacy (§8.4). Note the Phase 5 correction to
  `detail_strength` (§8.6 finding 3) moved this further in the right direction, not the wrong one:
  the old value was also inflating distance roughness.
- **G6.** ✅ *met, Phase 5.* Drops onto an arbitrary `MeshInstance3D` with no plugin involvement and no
  clipmap uniforms set. Gate B renders `M_water_lake` and `M_water_pond` on a bare mesh with no
  `Pasture3D` in the scene at all (§8.6). One caveat, now documented rather than assumed: such a scene
  has nothing driving the `water_time` global and must write it itself. A `Pasture3D` anywhere in the
  scene does it, whether or not its ocean is enabled — which was **not** true until Phase 5 fixed it.

**Non-goals**

- FFT / Tessendorf spectra. Rejected: needs per-frame compute dispatches plus cascade textures (8 MB+),
  explicitly does not scale to the low end, and cannot be cheaply mirrored on the CPU for G4.
- Screen-space reflections. Godot excludes transparent surfaces from SSR; reflections come from the sky
  radiance map and reflection probes. Documented limitation, not a bug.
- Underwater volumetrics, caustics, wet-sand shoreline darkening. Separate systems, may reuse the wave
  table later.
- Mobile / Compatibility renderer support (per decision table).
- Flow maps / river currents. The trough connector may want these later; §11 notes the hook.

---

## 2. Architecture

### 2.1 File layout

```
project/addons/pasture_3d/extras/shaders/water/
  water_waves.gdshaderinc      # Gerstner evaluation. THE parity contract with C++.
  water_surface.gdshaderinc    # detail sampling, normals, foam
  water_shading.gdshaderinc    # absorption, fresnel, scattering, final write
  water_ocean.gdshader         # #define WATER_CLIPMAP, WATER_TIER_HIGH
  water_ocean_low.gdshader     # #define WATER_CLIPMAP, WATER_TIER_LOW
  water_body.gdshader          # finite mesh, WATER_TIER_HIGH
  water_body_low.gdshader      # finite mesh, WATER_TIER_LOW
  M_ocean.tres  M_lake.tres  M_pond.tres
  T_water_deriv.png            # BC5, 512², tiling, mipmapped
  T_water_foam.png             # BC4, 256², tiling, mipmapped
```

Godot 4's shader preprocessor supports `#define` / `#ifdef` / `#include` of `.gdshaderinc` files. This is
the mechanism for **static variants**: a pond does not merely skip the ocean code at runtime, it never
compiles it. Every `.gdshader` wrapper is ~10 lines — defines plus three includes.

Feature defines, all resolved at compile time:

| Define | Effect |
|---|---|
| `WATER_CLIPMAP` | Compiles in the clipmap geomorph + `_target_pos`/`_mesh_size`/`_subdiv` uniforms. Off = plain mesh. |
| `WATER_WAVE_COUNT` | 8 (ocean high), 4 (ocean low / lake), 2 (pond). Loop bound; must be a literal for unrolling. |
| `WATER_REFRACTION` | Screen-texture refraction. **Off by default** — this is the only feature that forces a backbuffer copy. |
| `WATER_DEPTH_FADE` | Depth-texture absorption + soft edges. On for everything except a fully opaque stylised tier. |
| `WATER_FOAM_CREST` | Jacobian-driven whitecaps. Ocean only. |
| `WATER_FOAM_SHORE` | Depth-driven shore foam. All tiers. |
| `WATER_SCATTER` | Backlight/subsurface term. High tier only. |
| `WATER_RECEIVE_SHADOWS` | Absent ⇒ `shadows_disabled`. Low tier drops it. |

### 2.2 Render modes

```glsl
render_mode cull_disabled, depth_draw_never, diffuse_lambert, specular_schlick_ggx, skip_vertex_transform;
```

Changes from the legacy shader and why:

- `cull_back` → **`cull_disabled`**. The legacy shader vanishes when viewed from below, yet
  [line 223](project/bench/legacy/ocean_shader.gdshader:223) tests for the player's
  head being underwater — the two disagree. `cull_disabled` costs nothing here (no overdraw, the surface
  is a single layer) and gives a correct underwater view. Flip `NORMAL` on `!FRONT_FACING`.
- `depth_draw_always` → **`depth_draw_never`**. A transparent surface writing depth occludes transparent
  objects behind it; the demo scene has a `Pasture3DParticles` node that will pop. Water does not need to
  write depth.
- `diffuse_burley` → **`diffuse_lambert`**. Water has essentially no diffuse lobe; Burley is strictly
  wasted here.
- `shadows_disabled` becomes tier-dependent rather than unconditional. Receiving shadows makes water sit
  in the scene properly; the high tier can afford it at 1280×800.

### 2.3 Data flow

```
C++ (Pasture3D)                     GPU
───────────────                     ───
wave generator ──► wave table ────► uniform vec4 _waves[N]   (vertex only)
   (from art knobs)      │
                         └────────► get_water_height() on CPU
water clock ────────────────────► global uniform water_time
   (loop period) ───────────────► global uniform water_time_period   (added in Phase 3)
sun (DirectionalLight3D) ───────► global uniform water_sun_dir / water_sun_color
```

`water_time_period` was added in Phase 3 (§8.4): the clock alone is not enough, because anything advancing
on `water_time` — the scrolling detail texture — has to land on a whole number of its own cycles at the wrap
or it reintroduces the seam the wave quantisation removed. It is written change-detected, defaults to 120.0
so a bare `MeshInstance3D` still loops (G6), and is divided by in the fragment stage every pixel, so a stale
value is worse than a redundant write is cheap.

`water_time`, `water_sun_dir` and `water_sun_color` become **global shader uniforms**, registered by the
plugin at init via `RenderingServer::global_shader_parameter_add`. This replaces the current per-frame
per-material `set_shader_parameter` calls at [pasture_3d.cpp:134](src/pasture_3d.cpp:134) — one write
drives every water body in the scene, at zero cost per material.

#### Registration — resolved in Phase 1 (measured, see §8.2)

Two probes (`project/bench/GlobalUniformProbe*.tscn`) settled how these get registered. The findings
were not what the pre-measurement caveat assumed:

- `RenderingServer.global_shader_parameter_add()` at runtime **works**, and values propagate exactly.
  Registering *after* a referencing shader has already compiled also recovers (the material recompiles),
  but it spams `used global parameter … was removed at some point` warnings in between. Register early.
- Runtime registration is **runtime-only**. It does not persist to `project.godot`.
- Writing `ProjectSettings["shader_globals/*"]` at runtime does **not** register with RenderingServer —
  it errors with `Condition "!global_shader_uniforms.variables.has(p_name)" is true`. The RS global table
  is populated from `project.godot` at engine startup and only then.
- `global_shader_parameter_get_list()` and `global_shader_parameter_get()` are **editor-only** and error
  out in a game build. Never call them at runtime. Use `ProjectSettings.has_setting("shader_globals/<n>")`
  as the runtime-safe existence check.

So the design is **both paths, not one**:

1. **Primary — persisted.** The editor plugin writes the three `shader_globals/*` entries to
   `project.godot` once at plugin-enable. This is what makes them exist at startup, which is what makes
   them work in exported builds and in the editor without a warning window.
2. **Fallback — runtime.** On init, for each global, `if not ProjectSettings.has_setting(...)` then
   `global_shader_parameter_add(...)`. This covers the first run after enabling the plugin (before the
   project is reloaded) and any project where the settings were hand-stripped.

`godot#77988` did not reproduce on 4.7. The ordinary-uniform fallback is **dropped** — it is not needed.

---

## 3. The shader

### 3.1 Wave model — Gerstner, from GPU Gems ch. 1

Y-up, XZ-horizontal (GPU Gems is Z-up; transposed here).

For wave `i` with direction `D` (unit, XZ), amplitude `A`, wavelength `L`, steepness `Q`:

```
w      = 2π / L                       angular wavenumber
speed  = sqrt(g * L / 2π)             deep-water dispersion, g = 9.81
φ      = speed * w                    phase constant
θ      = w * dot(D, pos.xz) + φ * t
```

```
P.xz  +=  Q * A * D * cos(θ)
P.y   +=      A     * sin(θ)
```

Analytic normal, accumulated in the **same loop**, no extra trig:

```
WA = w * A
S  = sin(θ)        C = cos(θ)

N.x -= D.x * WA * C
N.z -= D.z * WA * C
N.y -= Q   * WA * S        (N.y starts at 1.0)
```

`sin` and `cos` of the same angle are one `sincos` on every GPU in scope, so a wave costs **one
transcendental pair plus ~12 MAD** and yields position *and* exact normal. This is the single biggest win
in the spec: the legacy shader spent 36 `sin` and 216 integer multiplies per **fragment** to approximate
what 8 waves compute exactly per **vertex**.

**Steepness constraint.** `Σ(Q_i · w_i · A_i) ≤ 1`, else the surface self-intersects (visible as pinched,
looping crests). A single `steepness` knob in [0,1] is distributed across the waves so the sum can never
exceed it.

> **Revised in Phase 2.** This section originally specified GPU Gems' `Q_i = steepness / (w_i · A_i · N)`,
> which makes `Q_i·w_i·A_i` the same constant for every wave. That satisfies the bound, but the horizontal
> term `Q_i·A_i = steepness / (w_i·N)` then carries **no amplitude dependence at all** — so a zero-amplitude
> wave, which is what an unused table slot is, still shears the surface horizontally and still tilts the
> normal. Since `WATER_MAX_WAVES` is fixed at 8 and lower tiers leave slots empty, that is not a corner case.
>
> The implementation distributes the budget **in proportion to amplitude** instead:
> `Q_i·w_i·A_i = steepness · A_i / ΣA`. The weights sum to 1 by construction so the bound is unchanged,
> empty slots become genuinely inert, and the larger waves get the sharper crests — which is also what the
> ocean does. `Q` is never formed explicitly; the shader carries `Q·w·A` and `Q·A = (Q·w·A)/w`, because
> dividing by amplitude to get `Q` and multiplying it straight back out would blow up on an empty slot.

**Jacobian / crest signal.** `J = Σ(Q_i · w_i · A_i · S)` is already summed as part of `N.y`. It is
exactly "how close is this crest to breaking", so whitecap foam comes out **free** — no extra evaluation,
and physically motivated rather than the legacy `wave_height * 0.5 - foam_height` threshold. Pass as a
varying.

**Wavelength floor: 10 m.** Below that the phase argument `w · dot(D, pos.xz)` loses float precision at
clipmap-scale coordinates (±32 km). At `L = 10 m`, `w ≈ 0.63`, so `θ` reaches ~20,000 rad — 15 mantissa
bits consumed, ~9 left, ≈ 0.002 rad resolution. Acceptable. At `L = 1 m` it is not. **All detail below
10 m comes from the tiling texture**, which is sampled in a wrapped local domain and has no such problem.
This constraint is the technical reason the hybrid split exists, not merely a performance preference.

**Domain origin.** The wave domain is `pos.xz - _water_domain_origin`. Ocean leaves it at zero; a pond at
(10000, 0, 10000) sets it to its own origin, keeping `θ` small and precise. The C++ query applies the same
offset.

### 3.2 Time — bounded, looping, CPU-shared

`TIME` is not used. The plugin owns a `water_time` global uniform, advanced each frame and **wrapped to a
loop period `T`** (default 120 s).

Wave frequencies are **quantised to the loop**: for each wave, `k = round(φ·T / 2π)` then
`φ = 2π·k / T`. Every wave then completes a whole number of cycles in `T`, so wrapping `water_time` at `T`
is seamless — no pop, and the phase argument never grows without bound.

> **Refined in Phase 2.** The quantisation is applied to the **wavelength**, not to `φ` as written above:
> after solving for `φ`, the generator inverts the dispersion relation (`w = φ²/g`, `L = 2π/w`) and stores
> the corrected `L` in the table. Quantising `φ` directly would require uploading it as a fifth per-wave
> value, or leave the shader deriving an *un*-quantised `φ` from a wavelength that no longer matches it.
> Storing the wavelength keeps the table at one `vec4` per wave and keeps `φ = sqrt(g·w)` the single
> definition on both sides — which is the §4.3 parity contract. Measured residual: worst 1.0e-06 cycles
> over 8 waves in a 120 s loop.

This fixes a latent bug in the legacy shader: `TIME * time_scale` with `time_scale = 8.0` reaches ~28,800
by Godot's default 3600 s rollover, at which point `fract()` in the noise quantises and the waves visibly
step. It also gives the CPU query an exact, shareable clock, which `TIME` could never provide.

### 3.3 Detail — one texture, two scrolls, derivative domain

Fine ripples come from **`T_water_deriv`**: a seamless, mipmapped **BC5** 512² texture storing
`(∂h/∂x, ∂h/∂z)` — *not* a normal map.

Derivative maps are the right choice because **derivatives compose by addition**. Two scrolled layers plus
the Gerstner normal combine with two adds; normal maps would need whiteout blending or a TBN per layer.
And there is no TBN at all: the Gerstner normal and the detail derivatives are both already in world
space.

```glsl
vec2 d  = texture(deriv_tex, uv * s0 + water_time * dir0).rg * 2.0 - 1.0;
     d += texture(deriv_tex, uv * s1 + water_time * dir1).rg * 2.0 - 1.0;
     d *= detail_strength * detail_fade;

// Gerstner normal (varying) → derivative domain, add detail, rebuild
vec2 g  = -v_normal.xz / max(v_normal.y, 1e-3);
NORMAL  = normalize(vec3(-(g.x + d.x), 1.0, -(g.y + d.y)));
```

Two fetches from **one** texture (good cache locality — same texture, two mip chains), one divide, one
normalize. No cross products, no `TANGENT`/`BINORMAL` writes. The legacy shader computed both and used
neither.

**`WATER_DETAIL_LAYERS`** (default 2, low tiers 1) and **`WATER_DETAIL_TRILINEAR`** were added after Phase 3
priced this block at 0.109 ms — 42% of the whole shader, of which only 0.018 ms is the fetching (§8.4
finding 4). The second layer is 0.041 ms and the first thing to go on a tight budget; the scroll offsets go
through `water_scroll()` rather than raw `water_time`, so both layers stay on the clock's loop.

**Mipmapping is the anti-aliasing.** This is why the hybrid beats pure procedural on quality as well as
speed: hardware trilinear/aniso filtering is a *correct* prefilter, whereas the legacy `dv` trick at
[line 171](project/bench/legacy/ocean_shader.gdshader:171) only widened the
finite-difference stencil — it band-limited the *derivative* while `wave_height` (which drives foam and
scattering) stayed full-frequency and aliasing.

`detail_fade` ramps detail amplitude to zero over `detail_fade_start → detail_fade_end` (default
200 → 800 m) so distant water settles onto the smooth swell normal. This is the IQ band-limiting idea
— attenuate content that oscillates faster than a pixel rather than trying to filter it — applied to a
distance ramp instead of `fwidth`, because the ramp is cheaper and, unlike `fwidth`, does not
misbehave across the clipmap's LOD seams.

### 3.4 Specular anti-aliasing

`ROUGHNESS = 0.02` over a high-frequency normal is a firefly generator. Instead:

```glsl
float variance  = detail_strength * (1.0 - detail_fade);   // normal energy we just filtered away
ROUGHNESS = clamp(base_roughness + variance * variance_to_roughness, 0.02, 0.35);
```

This is Toksvig/vMF in spirit: normal detail removed by mip filtering is **converted into roughness**
rather than discarded, so the specular lobe widens exactly as the geometry it represented is smoothed away.
Cheap (two MADs) and it is what actually stops the shimmer — lowering roughness makes it worse, not better.

### 3.5 Depth, absorption, refraction

**Cheap linear depth.** Replace the two full `INV_PROJECTION_MATRIX × vec4` chains
([lines 195–198](project/bench/legacy/ocean_shader.gdshader:195) and
[217–220](project/bench/legacy/ocean_shader.gdshader:217)) with a scalar
reconstruction. Only view-space `z` is needed, and for a perspective projection that is four scalars from
the inverse projection matrix:

```glsl
float raw = textureLod(depth_texture, SCREEN_UV, 0.0).r;
float vz  = (INV_PROJECTION_MATRIX[2][2] * raw + INV_PROJECTION_MATRIX[3][2])
          / (INV_PROJECTION_MATRIX[2][3] * raw + INV_PROJECTION_MATRIX[3][3]);
```

2 mul, 2 add, 1 divide, versus 2× (16 mul + 12 add) plus 2 perspective divides.

**✅ Validated in Phase 2** under Godot 4.7 reversed-Z, Forward+: 186,624 sampled pixels, **zero**
disagreements at 1e-4 relative, worst observed difference 0.0000. The probe
(`project/bench/water_depth_probe.gdshader`) also reports the normalised depth of both paths in separate
channels, and the depth spanned 0.188–1.000 across the frame, so the agreement is not the vacuous one of
two methods agreeing on a cleared buffer. The two mat4 chains can go.

The "is the pixel above water" test also moves to view space (compare `vz` against `VERTEX.z`), removing
the second world-space reconstruction entirely.

**Beer–Lambert absorption** replaces the legacy depth-fade curve. ⚠️ **The snippet below is wrong and is
kept only because §8.4 explains why**: there is no `background` to read without the backbuffer copy that
`WATER_REFRACTION` exists to avoid, and fixed-function blending has **one scalar destination factor**, not
three, so a per-channel filter of what is behind the water is not expressible here at all.

```glsl
// WRONG -- see §8.4 for what ships and why.
float thickness   = max(0.0, vz - (-VERTEX.z));            // metres of water traversed
vec3  transmit    = exp(-absorption_rgb * thickness);      // per-channel
ALBEDO            = mix(deep_color, background, transmit); // no `background` exists
ALPHA             = 1.0 - transmit_luminance;              // and no fresnel term
```

What ships instead: the scalar alpha comes from the luminance of `transmit`, and the albedo is then solved
so the water's **own** contribution is exact per channel, with fresnel raising opacity because reflected
light did not come from behind the surface:

```glsl
float thickness    = max(0.0, VERTEX.z - scene_vz);
vec3  transmit     = exp(-absorption * thickness);
float absorb_alpha = 1.0 - dot(transmit, WATER_LUMA);
ALBEDO             = min(deep_color * (1.0 - transmit) / max(absorb_alpha, 1e-3), vec3(1.0));
ALPHA              = absorb_alpha + (1.0 - absorb_alpha) * fresnel;
```

Deep water lands on `deep_color` exactly, shallow water lands on the background almost untinted, and the
approximation is confined to mid depths. Measured consequence in §8.4: over a *lit bottom* the hue shift is
small (0.005 at 16 m), because all of it must come from `deep_color`, which is very dark in linear terms.

**This is the versatility mechanism.** Ocean, lake and pond differ mainly in how fast and how selectively
water absorbs light:

| Preset | `absorption_rgb` (per metre) | Reads as |
|---|---|---|
| Ocean | (0.35, 0.08, 0.05) | Deep blue; red gone in ~3 m, blue persists ~20 m |
| Lake | (0.45, 0.22, 0.30) | Green-teal, bottom visible ~4 m |
| Pond | (0.90, 0.60, 0.80) | Murky brown-green, bottom visible < 1 m |

One physically-grounded model, three parameter sets — instead of the legacy `water_color` +
`visible_depth` + `depth_curve` trio, which interacted in ways that made the refraction nearly invisible
(the `max(20., …)` floor at
[line 233](project/bench/legacy/ocean_shader.gdshader:233) combined with
`depth_curve = 0.1` pinned the background contribution to ≤ 22.5%, and to 0% in deep water).

The same line also **double-counts `sea_level`** — `v_vertex.y` already includes it from
[line 157](project/bench/legacy/ocean_shader.gdshader:157). That bug is likely *why*
the `max(20., …)` floor was needed to hide the artifacts. Both go away.

**Refraction (`WATER_REFRACTION`, off by default).** When enabled, offset `SCREEN_UV` by the perturbed
normal and sample `screen_texture`, using the standard "reject the sample if it is in front of the water
surface" guard. This is the **only** feature that forces a full backbuffer copy, so it is opt-in per tier
and per preset. Ponds and lakes — where absorption is high and you see barely a metre down — get almost
nothing from it and should leave it off.

### 3.6 Foam

Three additive sources, each gated by its own define, all sharing one BC4 breakup texture:

| Source | Signal | Cost |
|---|---|---|
| Crest (`WATER_FOAM_CREST`) | Jacobian `J` varying from §3.1 | Free — already summed |
| Shore (`WATER_FOAM_SHORE`) | `thickness` from §3.5 | Free — depth already fetched |
| Breakup | `T_water_foam`, one scrolled fetch | 1 texture fetch |

`foam = saturate(crest_term + shore_term) * breakup_texture`, then
`ALBEDO = mix(ALBEDO, foam_color, foam)` and `ROUGHNESS = mix(ROUGHNESS, 0.8, foam)`. Foam must raise
roughness — legacy foam changed albedo only, leaving mirror-smooth "foam". The roughness clamp of §3.4 has
to be applied *before* this mix, or it destroys the foam's 0.8.

**The crest signal is the raw Jacobian, in fold-limit units** — `sum(Q·w·A·sin θ)`, which reaches 1.0 where
the Gerstner surface would self-intersect and is therefore bounded by `wave_steepness`. An earlier version
divided it by `wave_steepness` so the threshold would hold its place in the distribution whatever the knob;
§8.4 records why that was reverted (it gave a millpond and a gale identical whitecap coverage) and why the
ramp needs `foam_crest_softness` rather than ending at an unreachable 1.0.

### 3.7 Lighting

Set `ALBEDO`, `NORMAL`, `ROUGHNESS`, `SPECULAR`, `ALPHA` and let Godot's PBR do the rest. Reflections come
from the sky radiance map plus any reflection probes.

- **Fresnel:** Schlick with F0 = 0.02, using the `pow5` unrolled form — never `pow()`.
- **Scattering (`WATER_SCATTER`):** one `BACKLIGHT` term driven by `J` (crest thickness) and a single
  `dot(sun_dir, view)`. The legacy version used three `pow()` calls and a full three-term accumulation for
  an effect largely swamped by the specular; one term at a fraction of the cost is enough.
- Replace every `pow(x, 2.0/3.0/4.0)` with multiplies.

---

## 4. C++ side

### 4.1 Decoupling from the clipmap

The ocean mesher stays as-is for the ocean body. The shader gains a non-clipmap path so it drops onto any
`MeshInstance3D`:

- `WATER_CLIPMAP` guards the geomorph block
  ([lines 137–151](project/bench/legacy/ocean_shader.gdshader:137)) and its
  `_target_pos` / `_mesh_size` / `_subdiv` / `_vertex_spacing` uniforms.
- Without it, `vertex()` reduces to: world-space position → Gerstner displace → project. No plugin
  involvement, no uniforms the user must remember to wire (G6).
- `sea_level` becomes meaningful only for the clipmap variant. A lake mesh's own transform sets its
  height; `sea_level` is forced to 0 in `water_body.gdshader`.

### 4.2 Wave table generation

The user does not author 8 waves. C++ generates the table from art knobs, on parameter change only:

| Knob | Range | Meaning |
|---|---|---|
| `wave_direction` | 0–360° | Dominant wind direction |
| `wave_spread` | 0–90° | Directional scatter around it |
| `wave_amplitude` | m | Amplitude of the longest wave |
| `wave_length_max` | ≥ 10 m | Longest wavelength; shorter waves are a geometric series down to the 10 m floor |
| `wave_steepness` | 0–1 | Feeds the `Q` normalisation of §3.1 |

Generation: distribute `N` waves over a geometric wavelength series, scatter directions within
`wave_spread` using a **fixed deterministic sequence** (not `rand()` — the table must be reproducible
across runs and between editor and game), derive speed from dispersion, quantise `φ` to the loop period
(§3.2), normalise `Q`. Push as `uniform vec4 _waves[N]` where each entry is
`(D.x, D.z, amplitude, wavelength)`.

**64 bytes for 4 waves, 128 for 8.** Compare: an FFT cascade set is 8 MB+ and regenerated every frame.

### 4.3 CPU height query — the parity contract — ✅ *implemented Phase 4, item 4 corrected*

```cpp
real_t Pasture3D::get_water_height(const Vector2 &p_xz) const;   // world XZ -> world Y
Vector3 Pasture3D::get_water_normal(const Vector2 &p_xz) const;  // world XZ -> world normal
Vector3 Pasture3D::get_water_surface_point(const Vector2 &p_domain_xz) const; // the parity contract itself
```

The third is new and is the one the gate points at: it takes a **domain** parameter and returns the
displaced point, which is exactly what the vertex shader computes for the same input and therefore the
only call that can be compared against the GPU without a solve in between. The two public queries are
built on it.

Parity is **structural, not disciplinary**: C++ owns the wave table and pushes it to the GPU, so both sides
read identical inputs by construction. What remains is to keep the *evaluation* identical:

1. Use `float`, not `double`, in the C++ loop — matching GPU precision matters more than being "more
   accurate" than the thing you are trying to match.
2. Same operation order as `water_waves.gdshaderinc`. The include file is the reference; the C++ is a
   transcription, and the two are diffed by eye at review time.
3. Same `water_time` value — the plugin owns the clock, so this is automatic.
4. ~~For steepness ≲ 0.5 the error is under a few cm and G4 holds. Above that, callers needing exactness
   must iterate.~~ **Wrong on both counts, corrected in Phase 4.** Gerstner displaces horizontally as well
   as vertically, so the surface is not a heightfield: the point drawn for parameter `u` sits at `u + D(u)`.
   Reading the wave function at a world XZ and calling that the height is wrong by **mean 0.213 m, worst
   1.86 m** at the ocean defaults and steepness 0.35 (§8.5) — 20× to 190× outside G4's 1 cm, not "a few
   centimetres", and at a steepness well inside the range the sentence called safe.

   `get_water_height()` therefore **solves the inverse itself** rather than leaving it to callers.
   `WaterWaves::solve_domain()` is a fixed-point iteration whose contraction factor is bounded by
   `wave_steepness` exactly — the same quantity that bounds self-intersection — so it converges across the
   whole inspector range, costing 4 steps on calm water and 13 at steepness 0.6. At steepness 1.0 the
   surface has vertical tangents, the inverse stops being unique, and the query is ill-posed rather than
   slow; the iteration cap is sized for 0.8 and the degenerate case still lands inside G4 (§8.5).
5. ✅ A unit test in [unit_testing.cpp](src/unit_testing.cpp), run via
   `PASTURE3D_UNIT_TESTS=water` on [bench/UnitTestRunner.tscn](project/bench/UnitTestRunner.tscn) —
   an env-var runner rather than an uncommented call, because a gate is worth nothing if it is not
   reproducible. 31 checks, green (§8.5).
6. **The two loops must cover the same slots.** The shader loops to its variant's `WATER_WAVE_COUNT` and
   has no way to learn `_count`, so the C++ evaluator loops to `WATER_MAX_WAVES` instead. Slots past
   `_count` hold amplitude 0 on both sides, so the two agree whenever the variant reads *at least*
   `_count` waves. The reverse — `ocean_wave_count` above the variant's count — cannot be fixed in the
   evaluator and raises a configuration warning on the node instead.

### 4.4 Fix: ocean shadow and GI settings are ignored — ✅ *fixed Phase 4*

`_ocean_cast_shadows` and `_ocean_gi_mode` ([pasture_3d.h:110](src/pasture_3d.h:110)) are stored, bound and
shown in the inspector ([pasture_3d.cpp:1652](src/pasture_3d.cpp:1652)) — but `Pasture3DMesher::update()`
reads `_terrain->get_cast_shadows()` and `_terrain->get_gi_mode()`
([pasture_3d_mesher.cpp:514](src/pasture_3d_mesher.cpp:514),
[:530](src/pasture_3d_mesher.cpp:530)). The ocean silently inherits the terrain's `ON`/`STATIC` instead of
its own `OFF`/`DISABLED` defaults.

Currently benign (Godot excludes transparent surfaces from shadow casting), but the shader header invites
users to substitute their own — and an opaque one would put the whole clipmap into every shadow split with
no way to switch it off. Fix: pass the values into `Pasture3DMesher::initialize()` and store them on the
mesher rather than reaching back through `_terrain`.

Done: `_cast_shadows` / `_gi_mode` now live on the mesher, set through two new defaulted `initialize()`
parameters and pushed by the four setters. Phase 4 gate D verifies it by rendering, with the terrain always
given the **opposite** setting to the ocean, so the old inherit-from-terrain behaviour would get the wrong
answer both times. Because the shipped water material is alpha-blended and Godot keeps blended surfaces out
of the shadow map entirely, the gate substitutes an opaque material for the measurement — otherwise every
reading is "no shadow" and the test examines nothing. What is under test is the instance flag, which is
material-independent.

### 4.5 Fix: ocean culling AABB ignores sea level — ✅ *fixed Phase 4, and it was worse than described*

`_ocean_mesher->update_aabbs(_ocean_cull_margin, V2_ZERO)`
([pasture_3d.cpp:222](src/pasture_3d.cpp:222)) passes a zero height range, yielding a y-extent of
±`cull_margin` around the **world origin**, not around the water. The demo's `sea_level = 5` fits inside the
default margin of 20 by luck.

Three defects, not one. Fixing the first uncovered the other two:

1. As described. Now `Vector2(sea_level - amplitude_sum, sea_level + amplitude_sum)`, change-detected and
   polled from physics so it tracks a `sea_level` the user moves at runtime.
2. `_update_ocean_aabbs()` was **dead code that would have applied the *terrain's* height range to the
   ocean** had anything called it. Rewritten.
3. `update_aabbs()`'s `(min, max) -> (min, extent)` conversion was `height_range.y += abs(height_range.x)`,
   which is the same number only while `min <= 0`. Harmless for a terrain whose range straddles zero;
   for an ocean at `sea_level = 300` it inflated the y-extent to ~600 m of nothing. Now `y -= x`.

The amplitude used is the **sum of the table's amplitudes**, not the `ocean_wave_amplitude` knob. The knob
is the amplitude of the longest wave and the geometric series adds the rest: at the ocean defaults the knob
reads 1.6 m and the surface reaches 5.24 m. Understating it culls water the player can see.

Gate E measures this by moving the sea and the camera together and requiring the picture not to change,
with the bug reintroduced as the control (physics frozen so the poll cannot run, then `sea_level` moved
behind its back). The control is emphatic: **100% of the frame culled** when the AABB does not follow, and
back to 100% coverage one physics frame after the poll is allowed to run (§8.5).

### 4.6 Geometry budget — *revised after Phase 0*

Ocean clipmap defaults today (`mesh_size 32`, `lods 7`, `vertex_spacing 4`) build ~203,000 triangles across
144 instances. **In practice frustum culling leaves 34–42 draw calls and ~106 k triangles visible** at a
horizon view, and as few as **1 draw call / 12 k triangles** looking down.

> **Phase 0 overturned the pre-measurement assumption here.** The draft claimed reducing triangles was a
> performance win and treated MultiMesh as a promising deferred optimisation. Measured geometry cost is
> **0.02 ms or less — inside the noise floor** (§8.1). Both claims were wrong.

Consequences:

- ✅ **`ocean_mesh_size = 16` is still adopted** (Phase 4), but as a *memory and CPU-snap* tidy-up, not a
  GPU optimisation. Expect no measurable frame-time change. It must not be used to justify the rewrite.
- **MultiMesh batching is dropped, not deferred.** 34–42 draw calls costing ~0.02 ms is not a problem worth
  plugin surgery. Removed from §11.
- The vertex budget in §5 has more room than assumed. If 8 Gerstner waves prove visually insufficient,
  going to 12 or 16 is affordable — the vertex stage is nowhere near being the constraint. This makes
  §11.1 much easier to answer in Phase 3.

> **Phase 4 adds the other half of the geometry question, which nothing before it had asked.** The budget
> above is about *cost*. Density also decides *fidelity*, and the shipped defaults are short there.
> `water_waves.gdshaderinc` states the rule as vertex spacing ≤ L_min / 8; the ocean defaults give
> 4 m spacing against a 10.2 m shortest wavelength, **a ratio of 2.54 — 3.1× short**. Gate C measures what
> that costs: the drawn surface sits up to **22 cm** below the analytic one at a LOD0 cell centre, and
> further at every coarser LOD.
>
> This does **not** affect G4, which is a statement about the analytic surface and is met (§8.5). It
> affects anything that has to agree with what the player sees: a boat floated on `get_water_height()`
> rides up to 22 cm above the water it is drawn on. Since geometry is measurably free (§8.1), the obvious
> answer is to spend some — but LOD0 density is a preset decision and presets are Phase 5, so this is
> recorded as §11 q6 rather than changed here. **Closed in Phase 5: adopted, see §8.6.**

---

## 5. Budget

Target per fragment, high tier, refraction off:

| Work | Legacy | Target |
|---|---|---|
| integer multiplies | 216 | **0** |
| `sin` / `cos` | 36 | **0** (vertex only) |
| `inversesqrt` | 18 | 0 |
| `pow` | ~6 | 1 (Schlick `pow5`, unrolled → 0) |
| `mat4 × vec4` | 4 | **0** |
| texture fetches | 4 | 4 (2 detail, 1 foam, 1 depth) |
| normalize | 3 | 1 |

Vertex, 8 waves: 8 `sincos` + ~100 MAD. Higher than legacy's 2 octaves, and correct — the work moved from
~1 M fragments to ~25 k vertices, a ~40:1 amortisation at 1280×800.

> ⚠️ **This table measured the wrong thing, and Phase 3 proved it.** Every target above was met, and the
> arithmetic it accounts for turns out to be **4%** of what full-screen water costs. 56% is Godot's lit
> transparent path before this shader computes anything, and most of the rest is the light loop reacting to
> a per-pixel normal rather than the two fetches that produce it. Kept as the record of what was eliminated;
> **§8.4 is the explanation of what remains.**

VRAM: `T_water_deriv` BC5 512² + mips ≈ 350 KB; `T_water_foam` BC4 256² + mips ≈ 44 KB. **~400 KB total,
shared across every water body** (G3). Wave tables are 64–128 bytes per material.

---

## 6. Presets — ✅ *shipped Phase 5*

**Four** `.tres` presets, in `addons/pasture_3d/extras/shaders/water/`, one per shader variant —
`M_water_ocean`, `M_water_ocean_low`, `M_water_lake`, `M_water_pond`. The draft said three and left
`water_ocean_low` without a resource to point at, which would have made the ocean's low tier
unreachable from the inspector.

Two things the draft table below does not capture, both decided while authoring them:

- **The ocean presets deliberately ship no wave table.** For the ocean the table is generated in C++
  and re-uploaded on every knob change, because the CPU height query has to read the identical one
  (§4.2, §4.3). A table in the resource would be overwritten on the first update and would disagree
  with the drawn surface until then. Lake and pond do ship one, because nothing runs in C++ for a
  material dropped on a bare mesh (G6) — generated by the real C++ generator via
  [bench/WavePresetTables.gd](project/bench/WavePresetTables.gd), so a preset cannot be a table shape
  `WaterWaves` would never produce.
- **The pond's numbers are not reachable as drafted.** `L_max` 12 m with 2 waves puts the second wave
  at 6 m, below the 10 m floor. That turned out to be intended generator behaviour for small bodies
  and is now documented and tested rather than accidental (§8.6 finding 5).

Draft table, kept for the record:

| | Ocean | Lake | Pond |
|---|---|---|---|
| Shader | `water_ocean.gdshader` | `water_body.gdshader` | `water_body_low.gdshader` |
| Waves | 8, `L_max` 120 m, `A` 1.5 m | 4, `L_max` 25 m, `A` 0.25 m | 2, `L_max` 12 m, `A` 0.05 m |
| Absorption | (0.35, 0.08, 0.05) | (0.45, 0.22, 0.30) | (0.90, 0.60, 0.80) |
| Crest foam | on | off | off |
| Shore foam | on | on | subtle |
| Refraction | off (opt-in) | off | off |
| Scattering | on | on | off |
| Receive shadows | on | on | on |

Note the pond uses the **low** variant: at pond scale nothing in the high tier is visible, so it should not
be compiled. This is the versatility payoff — a pond is genuinely cheaper, not just differently tinted.

---

## 7. Phases

| Phase | Content | Exit gate |
|---|---|---|
| **0** ✅ | Instrument. Capture legacy GPU ms, water filling frame. Record draw calls and triangle count. | **DONE 2026-07-27** — desktop only, results in §8.1. Steam Deck deferred to Phase 5 (hardware unavailable). |
| **1** ✅ | Skeleton: file layout, preprocessor variants, global uniform registration from GDExtension (incl. the §2.3 fallback decision). Flat shaded water, no waves. | **DONE 2026-07-27** — all five gate criteria green, results in §8.2. |
| **2** ✅ | Waves: `water_waves.gdshaderinc`, C++ generator, wave table upload, looping clock. Validate the §3.5 cheap depth reconstruction against the mat4 path. | **DONE 2026-07-27** — all seven gate criteria green, results in §8.3. |
| **3** ✅ | Surface + shading: detail texture authoring, derivative composition, absorption, foam, scattering, roughness AA. | **DONE 2026-07-27** — all eleven gate criteria green, results in §8.4. G5 verified (30× less speckle than legacy at 500 m). The desktop half of "G1 met on desktop" was **retired as a criterion**: §8.4 finding 2 measures Godot's lit transparent floor at 0.144 ms, above the 0.10 ms figure, so it is not a property of this shader. G1 is decided in Phase 5 as written. |
| **4** ✅ | C++ query + parity test; §4.4/§4.5 fixes; new geometry defaults. | **DONE 2026-07-28** — all five gate criteria green, results in §8.5. **G4 met**: zero of 384 probes differ from the GPU surface by even 1 mm, at a 12 km domain origin and a 300 m sea level. Unit test green (31/31). §4.3 item 4 was materially wrong and is corrected. |
| **5** ⚠️ | Presets, docs, Steam Deck validation, delete legacy shader. | **DESKTOP HALF DONE 2026-07-28** — all five gate criteria green, results in §8.6. Presets shipped, legacy retired, q1 and q6 closed. **The Steam Deck half is NOT done and cannot be**: no hardware (§11 q7). Every Deck figure in this document remains extrapolated. |

---

## 8. Testing

**Performance** — Steam Deck (15 W, 1280×800) and a desktop reference, water filling the frame, at three
camera pitches. Note that −60° (looking down) is the true worst case, not the horizon-grazing view: it is
the only pitch where water covers 100% of the frame (§8.1).

| Metric | Legacy | Target | Measured |
|---|---|---|---|
| GPU ms, high tier, desktop 1280×800 | **0.452** | ~~≤ 0.10~~ retired, §8.4 finding 2 | **0.295** as shipped, 0.267 on legacy geometry (§8.6) |
| GPU ms, low tier, desktop 1280×800 | — | — | **0.235** as shipped (§8.6) |
| GPU ms, this shader's own share, desktop | — | ≤ 0.13 (regression bound) | **0.115** |
| GPU ms, high tier, Steam Deck | ~3.1–5.1 _(est.)_ | ≤ 1.0 | ⚠️ **still unverified after Phase 5 — no hardware, §11 q7** |
| GPU ms, low tier, Steam Deck | — | ≤ 0.6 | ⚠️ **still unverified, §11 q7** |
| Draw calls (visible, −4°) | 42 | ≤ 42 | |
| Triangles (visible, −4°) | 106 k | ~30 k | |
| Water VRAM | 0 | ≤ 512 KB | **384 KB** (§8.4) |

### 8.1 Phase 0 results — measured 2026-07-27

**Harness:** [project/bench/OceanBench.gd](project/bench/OceanBench.gd) +
[OceanBench.tscn](project/bench/OceanBench.tscn). Isolated scene — sky, sun, camera and the ocean clipmap
only; the terrain clipmap is pushed to render layer 5 and culled. Per-viewport GPU timing via
`RenderingServer.viewport_set_measure_render_time`, median of 240 frames after 90 warmup frames, vsync off.
Four configs decompose the cost: `OFF` (sky floor) → `FLAT` (same geometry, unshaded flat colour,
[ocean_shader_flat.gdshader](project/bench/ocean_shader_flat.gdshader)) → `NOREFR` (legacy shader with only
the `screen_texture` fetch removed, [ocean_shader_norefract.gdshader](project/bench/ocean_shader_norefract.gdshader))
→ `LEGACY`.

**Hardware:** NVIDIA RTX 3070, Ryzen 5 5600X, Godot 4.7-stable, Vulkan Forward+.
**Steam Deck was not available** — its column is extrapolation only, and Phase 5 remains gated on real
hardware.

Coverage verified with [OceanBenchVerify.gd](project/bench/OceanBenchVerify.gd), which diffs each frame
against the same frame with the ocean off: **−4° = 54.5%**, **−20° = 73.5%**, **−60° = 100%** of frame.

GPU ms, median, cost decomposition:

| Res | Pitch | Geometry | Shader (no refr.) | Refraction | **Ocean total** |
|---|---|---|---|---|---|
| 1280×800 | −4° | 0.025 | 0.241 | 0.052 | **0.318** |
| 1280×800 | −20° | 0.028 | 0.277 | 0.079 | **0.384** |
| 1280×800 | −60° | −0.005 | 0.311 | 0.086 | **0.392** |
| 2560×1440 | −4° | 0.019 | 0.737 | 0.218 | **0.974** |
| 2560×1440 | −20° | 0.004 | 0.939 | 0.240 | **1.183** |
| 2560×1440 | −60° | −0.053 | 1.285 | 0.041 | **1.273** |

Four conclusions:

1. **Fragment-bound, decisively.** At −60° the ocean fills the whole frame from **one draw call and
   12 k triangles** and is simultaneously the *most* expensive pitch. Cost tracks covered pixels, not
   geometry. Scaling 1.02 → 3.69 Mpx (3.6×) raises shader cost 0.311 → 1.285 ms (4.1×) — linear in pixels
   with a little cache falloff on top. **Every optimisation must target per-pixel work.** This is exactly
   what §3 does, so the design direction is confirmed.

2. **Refraction is 16–22% of ocean cost** (0.052–0.086 ms at 1280×800). For an effect §3.5 shows is capped
   at 22.5% opacity and reaches 0% in deep water. Making it opt-in (`WATER_REFRACTION` off by default) is
   confirmed as a real, measurable saving rather than a theoretical one.

3. **Geometry and draw calls cost essentially nothing** — 0.02 ms at best, inside the noise floor at worst
   (the negative figures are measurement noise, not a speedup). See §4.6 for the consequences; this
   overturns two claims in the pre-measurement draft.

4. **Steam Deck estimate: 3.1–5.1 ms**, from the 0.392 ms full-coverage 1280×800 figure. The RTX 3070 is
   ~20.3 TFLOPs FP32 peak against the Deck's 1.6, but Ampere's dual-FP32 rarely realises more than ~60–70%
   of peak on mixed workloads, giving an effective ratio of ~8–13× rather than 12.7×. That is **19–30% of a
   60 fps frame budget spent on water alone**, which is what makes this rewrite worth doing. Treat the
   range as an order-of-magnitude sanity check, not a measurement.

To hit ≤ 1.0 ms on the Deck the replacement needs roughly a **3–5× reduction in per-pixel cost**. §5's
budget (216 integer multiplies → 0, 36 `sin` → 0, 4 `mat4` → 0, same fetch count) targets substantially
more than that, so there is headroom for the design to underdeliver and still pass.

**Correctness**

- G4: unit test sampling `get_water_height` on a grid × time, compared against a reference transcription.
- G5: 10 s camera orbit at 500 m, captured at 60 fps, differenced frame-to-frame. No high-frequency
  specular energy in the delta.
- Underwater: camera below the surface renders the underside correctly (`cull_disabled` + flipped normal).
- Transparent sorting: particles below the surface are no longer occluded (`depth_draw_never`).
- Lake at (10000, 0, 10000) shows no precision artifacts (validates `_water_domain_origin`).
- Loop seam: record `T` seconds and verify frame 0 and frame `T·60` are identical.

**Visual A/B** — legacy vs new at matched art direction, four scenes: open ocean, shoreline, lake, pond.

---

### 8.2 Phase 1 results — measured 2026-07-27

Harness: `project/bench/WaterPhase1Gate.tscn`. RTX 3070, Godot 4.7.stable, Forward+.

| Gate | Criterion | Result |
|---|---|---|
| A | All four `.gdshader` variants compile | **PASS** — 12 uniforms on both `water_ocean*`, 7 on both `water_body*` |
| A | `WATER_CLIPMAP` gating actually gates | **PASS** — `_target_pos` present only on the two ocean variants |
| B | `#include` + `#define` static variants work from a runtime `Shader.code` | **PASS** |
| C | Globals register and reach the fragment shader | **PASS** — monotonic response across three set/render cycles |
| D | `water_body` on a bare `MeshInstance3D`, zero plugin involvement (G6) | **PASS** — 100% coverage |
| E | `water_ocean` on the Pasture3D ocean clipmap | **PASS** — 99.9% coverage |

Gate B is the load-bearing one: it proves the four wrappers are genuinely four different compiled shaders
rather than one shader compiled four times, which is the whole premise of §2.1's variant scheme.

**Engine constraints learned, worth not rediscovering:**

- **Godot's shader language rejects `return` inside `fragment()` / `vertex()`** — "Using 'return' in the
  'fragment' processor function is incorrect". Early-out diagnostics have to be written as `#ifdef … #else
  … #endif` around the whole body. `water_shading.gdshaderinc` does this for `WATER_DEBUG_GLOBALS`.
- Global uniform registration: see the resolved §2.3 above.

**Diagnostics kept:** `WATER_DEBUG_GLOBALS` writes the three globals straight to `ALBEDO`. It is the only
way to test global plumbing before Phase 3 gives the shading path a reason to read them, and it stays
useful as a regression check afterwards.

**Open item carried to Phase 2** — the gate E capture shows a scattering of single-pixel dark specks along
the horizon line on the clipmap that are absent on the plain mesh. Flat water with no wave displacement
should not produce these. Suspect the outermost LOD ring's geomorph or skirt geometry, seen at grazing
angle. Not chased now; Phase 2's "no seams at LOD boundaries" gate is where it belongs, and the wave
displacement will make it either obvious or moot.
→ **Closed in Phase 2, and the suspicion was wrong — see §8.3.**

---

### 8.3 Phase 2 results — measured 2026-07-27

Harness: `project/bench/WaterPhase2Gate.tscn`. RTX 3070, Godot 4.7.stable, Forward+.

| Gate | Criterion | Result |
|---|---|---|
| A | C++ generates a wave table and it reaches the shader | **PASS** — 8 entries, unit directions, L 133.03 → 10.18 m, amp 1.433 → 0.110 m |
| A | Frequencies quantised to the loop period | **PASS** — 13/16/19/23/27/33/39/47 cycles per 120 s, worst deviation 1.0e-06 |
| B | The uploaded table beats the compile-time fallback | **PASS** — zero-amplitude upload gives flat water (mean diff 0.025 vs the generated table) |
| C | The clock advances and stays bounded | **PASS** — monotonic over 6 physics frames, in [0, 120] across a wrap |
| D | The loop is seamless | **PASS** — t=0 vs t=120 max diff 0.0039; control at t=44.4 reads 0.867, a 221× separation |
| E | No seams at LOD boundaries, top-down | **PASS** — 0.0000% gap at steepness 0.35 *and* 0.90; no-water control reads 100% |
| E | No cracks at grazing angle | **PASS** — 0 background pixels below the water silhouette across all 576 sampled columns |
| F | Waves match between clipmap and plain mesh | **PASS** — mean 0.00041, max 0.00784 on the unlit surface readout, against a signal span of 0.345 (840×) |
| G | Cheap scalar depth reconstruction agrees to 1e-4 | **PASS** — see §3.5 |

**The Phase 1 horizon specks were shading, not geometry.** Rendering the clipmap at grazing angle over a
flat background and counting background pixels *below each column's topmost water pixel* — the ocean is a
continuous sheet, so nothing under its own silhouette can legitimately be background — found zero. What
the Phase 1 capture showed is `ALPHA = mix(0.55, 1.0, fresnel)` reaching 1.0 at grazing incidence while
the placeholder shading has no reflection term to put in the sky's place, so the highest-fresnel pixels go
opaque and dark. Physically it is the pixels that should be *brightest*. Phase 3's reflection and
absorption remove the cause; no LOD work is needed.

**Gate F took three wrong answers before it took a right one**, and all three failure modes are worth
recording because they are generic to image-diff gates:

1. **A false pass.** `water_body` compiles with `WATER_WAVE_COUNT 4` and `water_ocean` with 8, so the two
   read different prefixes of the same table — the plain mesh got the swell and none of the medium waves.
   The threshold was loose enough to pass it, and only a visual check of the two captures caught it.
2. **A false fail, then a misleading number.** Water is near-mirror, so a normal difference far too small
   to see lands a saturated specular pixel somewhere slightly different: a shaded diff measures *highlight
   placement*, not geometry. The gate now renders `WATER_DEBUG_SURFACE` — world normal and displaced height
   as unlit colour via `EMISSION` with a black `ALBEDO` — and reports the shaded diff alongside without
   gating on it. On the final run the geometric diff is 0.00041 while the shaded diff's *max* is 0.075,
   two orders of magnitude apart on identical geometry.
3. **A real artefact, of the test.** The generated table's shortest wave is 10 m (the §3.1 floor) and the
   shader's own rule is vertex spacing ≤ L_min/8. At the 4 m spacing the other gates use, that wave is
   sampled 2.5× per period and aliases differently on each topology. Gate F drops to 1 m spacing and looks
   steeply down so the whole frame sits inside LOD0 and well inside the finite plane, rather than comparing
   a clipmap that reaches kilometres against a 2 km grid and calling the extent difference a wave
   difference.

Every criterion that can pass by measuring nothing now carries a control: gate D compares against a
non-period time, gate E against an empty frame, gate F against the signal span within its own readout, and
gate G against the depth spread across the frame. Two of the three wrong answers above were caught by
looking at the captures rather than the numbers, which is the practice worth keeping.

**Engine constraints learned:**

- **Godot rejects default values on uniform arrays** — "Setting default values to uniform arrays is not
  supported". The G6 fallback table (a raw `.gdshader` on a bare mesh must still make waves) is therefore a
  `const vec4 _wave_defaults[N]`, which *can* be initialised, selected with a branch-free `mix()`.
- The fallback sentinel is the first **wavelength**, not the amplitude sum. An amplitude test would read a
  deliberately calm body as "nothing uploaded" and override it, making flat water impossible to author.
- `_waves` is declared at `WATER_MAX_WAVES` (8) in every variant regardless of how many it reads, so the
  C++ side has exactly one upload shape. Godot offers no clean way to read a shader's declared array length
  back, so matching per-variant sizes would be a negotiation with no good answer. Costs 128 bytes.
- Global shader parameters are **process-global**, not per-node: registration is guarded by a
  function-local `static bool`, since a second `Pasture3D` in the scene otherwise errors on every add and
  `global_shader_parameter_get_list()` is editor-only.
- `signal` is a GDScript keyword and cannot be a local variable name; the parse error surfaces only at
  load, and a failed scene load leaves the Godot window spinning rather than exiting. Parse-check bench
  scripts with `--headless --check-only --script <path>` before every run.

**Diagnostics kept:** `WATER_DEBUG_SURFACE` alongside `WATER_DEBUG_GLOBALS`. It is the only way to compare
two tessellations of the same surface without the shading in the way, and it will be needed again in
Phase 4 to check the C++ height query against the GPU.

---

### 8.4 Phase 3 results — measured 2026-07-27

Harness: `project/bench/WaterPhase3Gate.tscn`. RTX 3070, Godot 4.7.stable, Forward+, 1280×800.
Textures authored by `tools/gen_water_textures.py`.

| Gate | Criterion | Result |
|---|---|---|
| A | Both textures import as BC5 / BC4 with mips, inside the G3 budget | **PASS** — `T_water_deriv` 512² RGTC_RG 341.4 KB, `T_water_foam` 256² RGTC_R 42.7 KB, **384.0 KB of 512 KB** |
| A | `T_water_deriv` tiles seamlessly | **PASS** — mean channel step at the wrap 0.0491, *below* the ordinary interior step of 0.0604, against an uncorrelated control of 0.2195 |
| B | The detail map reaches the surface | **PASS** — `detail_strength` 0 → 1 moves the frame by mean 0.0525 / max 0.937; control (0 twice) 0.00000 |
| C | Absorption darkens monotonically with depth | **PASS** — ocean 0.526 → 0.274 over 0.25–16 m; control (absorption 0) spread 0.0245 |
| C | The composite carries the water's hue | **PASS** — bottomless water reads blue−red **+0.0989** where the control reads **−0.0658**; over a lit bottom the added tint is 0.0000 → 0.0047 |
| C | Absorption is the ocean/lake/pond knob | **PASS** — half-luminance depth **5.27 m ocean vs 1.90 m pond** |
| D | Shore foam is depth-gated | **PASS** — 0.0615 change inside `foam_shore_depth`, **0.0000** at 4 m and deeper |
| D | Crest foam follows the Jacobian | **PASS** — 0.00427 at steepness 0.55, **0.00000** at 0.08 |
| E | The loop is still seamless with a texture scrolling on it | **PASS** — t=0 vs t=120 mean 0.00010; mid-loop control 0.07078; the same pair with the period mis-set to 97.3 s reads 0.06425, a **642×** separation |
| F | **G5** — no shimmer at 500 m under camera motion | **PASS** — speckle 0.00102 vs the legacy shader's 0.03034, **30×** less, at a ~1 px/step orbit |
| G | GPU ms, water filling the frame | **1.6× high tier, 2.2× low tier** — legacy 0.409 ms, high 0.259, low 0.184. §8's 0.10 ms desktop figure **not met**; see below |

**Where the 0.259 ms actually goes.** Each rung is the same geometry and the same includes, differing only
in feature defines, render mode or one uniform; every figure is the sky-floor-subtracted minimum of two
passes, and clean rungs repeated to within 0.001 ms.

| Rung | ms | Share |
|---|---|---|
| Waves + blend, nothing shaded (`WATER_DEBUG_SURFACE`, `unshaded`) | 0.008 | 3% |
| Full shading path, still `unshaded` | 0.011 | 4% |
| **+ Godot's PBR light loop** (no features at all) | **0.144** | **56%** |
| + detail, two layers | 0.253 | 98% |
| + depth fade | 0.235 | 91% |
| High tier, everything | 0.259 | 100% |
| Low tier | 0.184 | 71% |
| Legacy | 0.409 | 158% |

1. **§5's budget measured the wrong thing.** It counted this shader's ALU, and this shader's ALU is
   **4%** of what full-screen water costs. The dominant term is Godot's lit transparent path: an *empty*
   water shader — one that only sums waves and writes `ALPHA` — costs 0.144 ms, of which **0.133 ms is the
   PBR light loop alone** (the same shader `unshaded` costs 0.011). The budget table is kept as a record of
   what was eliminated, not as an explanation of the remaining cost.

2. **§8's 0.10 ms desktop figure is unreachable and has been retired as a Phase 3 criterion.** It was
   derived by scaling G1's Steam Deck budget on the assumption that full-screen water costs what its shader
   computes. The floor above falsifies that assumption: **no water shader on this path, at this resolution
   and coverage, can meet 0.10 ms.** Phase 3 is therefore graded on the shader's own share (0.115 ms) and on
   the speedup against legacy. **G1 itself is unchanged** and is still decided on the hardware it names, in
   Phase 5.

3. **The single biggest remaining lever is not in this shader.** `unshaded` costs 0.011 ms against 0.144
   with the light loop — a factor of 13. A hand-rolled lighting path (one directional specular plus one
   radiance-cubemap sample at a chosen mip) would cut most of the cost of full-screen water, at the price of
   giving up Godot's shadow receive, reflection probes, multiple lights and any future engine improvement to
   them. That is a real trade with real losses, so it is **§11 question 6**, not a decision taken here.

4. **Detail costs 0.109 ms, and only 0.018 of it is the fetching.** Sampling the map with the result
   multiplied by zero costs 0.018 ms; *using* it costs a further **0.091 ms**. The mechanism is the light
   loop reacting to a normal that varies per pixel — reflection vectors that no longer agree between
   neighbours, so the radiance cubemap is sampled incoherently. Consequences:
   - **One layer instead of two saves 0.041 ms** (16% of the high tier). Both `_low` variants now define
     `WATER_DETAIL_LAYERS 1`, which is most of why the low tier improved from 0.227 to 0.184 ms.
   - **Anisotropic vs trilinear filtering measured identically** (0.253 vs 0.254). `WATER_DETAIL_TRILINEAR`
     is kept as a knob anyway: anisotropy on an RDNA2 iGPU is not the same instruction it is here, and
     Phase 5 has a Deck to measure it on.
   - **Roughness is not the mechanism.** Forcing 0.02 and 0.35 on the floor material measured 0.144 both
     ways, which rules out radiance-mip selection as the explanation.
   - The fade range is **not** a lever at this framing, and the rung that tried to prove it is a null test:
     30 m of camera height at −60° puts the whole frame between 30 m and 78 m, inside even a 60/200 fade.

5. **Cost is per covered pixel.** Quartering the pixel count (640×400) takes the high tier to 0.087 ms,
   0.34× the full-resolution cost. Reducing covered pixels — a half-resolution water pass — is a real
   option for the low end and is the other side of finding 3.

6. **`cull_disabled` is free** — `cull_back` measured 0.259 ms against `cull_disabled`'s 0.259. The §10 risk
   is retired without needing an overdraw capture.

7. **One unexplained reading, recorded rather than smoothed over.** Adding `WATER_DEPTH_FADE` measures
   0.018 ms *cheaper* than the same shader without it (0.235 vs 0.253), repeatably, on a harness whose clean
   rungs agree to 0.001. The depth fetch is evidently free; the saving is not accounted for and nothing here
   is built on it.

**Two model corrections, both found by the gate:**

- **The Jacobian is no longer normalised by `wave_steepness`.** §3.1's normalisation made 1.0 mean "every
  wave in the table is cresting", so a foam threshold held its place in the distribution whatever the knob.
  That is wrong for the thing it feeds: it gave a millpond and a gale **identical whitecap coverage**. The
  raw sum is passed instead, in fold-limit units (1.0 = the self-intersection bound), so foam and scattering
  scale with sea state for free. `foam_crest_threshold` defaults to 0.2 and a new `foam_crest_softness`
  (0.1) ends the ramp at a reachable value — against a signal bounded by `wave_steepness` ≈ 0.35, the old
  `smoothstep(threshold, 1.0, J)` could never reach full foam anywhere. This is what "crest foam does
  nothing even on a steep sea" turned out to be.
- **Per-channel Beer–Lambert cannot go through fixed-function alpha blending, and §3.5's snippet was
  wrong about it.** `ALBEDO = mix(deep_color, background, transmit)` has no `background` to read without the
  backbuffer copy that `WATER_REFRACTION` exists to avoid, and the blend hardware has **one scalar
  destination factor**, not three. What ships instead: scalar alpha from the luminance of `transmit`, then
  solve for the albedo that makes the water's *own* contribution exact per channel —
  `albedo = deep_color * (1 - transmit) / absorb_alpha`. Deep water lands on `deep_color` exactly and
  shallow water lands on the background almost untinted; the approximation is confined to mid depths, where
  it reads as a colour blended toward the water rather than a background filtered by it.
  `ALPHA = absorb_alpha + (1 - absorb_alpha) * fresnel` completes it — reflected light did not come from
  behind the surface, so opacity has to rise with fresnel. That is the other half of the Phase 1 horizon
  artefact (§8.3).
  **The measurable consequence:** over a lit bottom the hue shift is small — 0.005 at 16 m, not the 0.04 a
  per-channel filter would give — because all of it has to come from `deep_color`, which `source_color`
  takes to (0.0015, 0.0075, 0.016) in linear. Bottomless water, where α → 1, reads the full +0.099.

**Measurement methodology — every GPU figure is now a minimum of two passes.** Two runs of the
single-pass gate disagreed by **30%** on the legacy baseline (0.436 vs 0.569 ms) while agreeing to 1% on a
material re-measured late in the same run. The pattern was positional, not per-shader: whatever was
measured *first* came out slow, by up to **8×** for the sky floor. It is the GPU arriving at its boost clock
plus first-use pipeline setup, and 60 warm-up frames per config do not cover it. With minimum-of-two the
legacy shader reproduces Phase 0's 0.392 ms to within 5% (0.409), which is what makes the comparison sound.
This first run also produced a **non-monotonic ladder** — adding the detail texture appeared to make the
shader *cheaper* — which sent the investigation after a roughness/radiance-mip hypothesis that did not
exist. Take the minimum before forming a theory.

**Gate-writing lessons, all three from controls that were not controls:**

1. **A helper silently disabled a control.** Gate E's control is a deliberately wrong `water_time_period`,
   written and then immediately overwritten by `_freeze_clock()`, which set the *correct* period as a
   convenience. Both readings came out identical because they were in fact the same test. The period is now
   a parameter of the helper. A control that runs through shared setup can be undone by it.
2. **A comparison that flattered the subject.** Gate F froze the new shader's clock (it reads `water_time`,
   which the gate pins) while the legacy control animated off `TIME`, which nothing can pin — so the control
   got wave motion *and* camera motion and the subject got camera motion only. The gate now steps
   `water_time` by one 60 Hz frame per orbit step. The yaw step also came down from 0.35° to 0.08° (~1 px):
   at 4–5 px per step most of the counted flips were legitimate motion of a moving image, which inflates
   both columns and compresses the ratio between them.
3. **A reference that was not neutral.** Gate C measured blue-minus-red outright and concluded the water
   had no hue. The probe boxes are lit by a sky ambient and are already blue, by more than the water adds.
   Differencing against the same probe at absorption 0 cancels the box, the sun and the sky and leaves only
   the water — and *then* the number needed the second half of the criterion (bottomless water) to be
   meaningful at all, because the model genuinely does not tint much over a bright bottom.

**Texture authoring** (`tools/gen_water_textures.py`, numpy, no PIL in this environment — a 15-line
`zlib`+`struct` PNG writer instead):

- **Spectral synthesis, so tiling is exact by construction** rather than hidden. `k^-1.35` between tapers at
  (3, 7) and (56, 76) cycles per 10 m tile, skewed for non-Gaussian crests, scaled to a stated
  **1.2 cm RMS** so `detail_strength = 1.0` means something physical (0.422 m/m full-scale slope).
  The derivatives are taken **spectrally** (multiply by i·k), which is the exact derivative of the authored
  height field rather than a finite difference of it.
- An earlier `k^-1.8` from k=2 put too much energy at features over 2 m, which survive into the low mips and
  turn the tile repeat into visible plaid. Caught by looking at the PNG, not by a metric.
- Foam is `clusters × breakup`, **multiplied not added**, so the gaps stay exactly zero.

**Godot import constraints for a derivative map:**

- `compress/channel_pack = 1` (Optimized) is **mandatory**. `detect_used_channels` requires B == 0 exactly
  for RGTC_RG and G == B == 0 for RGTC_R; sRGB Friendly forces all channels on and the texture falls back to
  DXT5 at twice the size.
- `compress/normal_map` must be **2 (Disable)**. Godot's normal-map path *renormalises mips as normal
  vectors*, which is meaningless for a derivative map. Channel detection via B == 0 gets BC5 anyway.
- `hint_normal` on the sampler is a deliberate lie about the content: it is the only hint whose fallback
  texture is (0.5, 0.5, …), which is exactly neutral for a derivative map. `hint_default_white` would tilt
  every pixel by a full unit of slope on a material nobody gave a texture to — precisely the bare
  `MeshInstance3D` case G6 promises works.

**New global uniform:** `water_time_period` (§2.3), defaulted to 120.0 so a bare `MeshInstance3D` with no
`Pasture3D` in the scene still loops. The clock alone is not enough — anything advancing on `water_time`
must land on a whole number of its own cycles at the wrap, or the seam the wave quantisation removed is one
the scrolling texture reintroduces. `water_scroll()` rounds the *cycle count* over the period and divides it
back out; a layer too slow to complete half a tile per loop rounds to zero and stops, which is the honest
outcome — such a layer cannot both scroll and loop, and frozen is less wrong than jumping.

### 8.5 Phase 4 results — measured 2026-07-28

Two harnesses. [bench/UnitTestRunner.tscn](project/bench/UnitTestRunner.tscn) with
`PASTURE3D_UNIT_TESTS=water` runs the C++ suite; [bench/WaterPhase4Gate.tscn](project/bench/WaterPhase4Gate.tscn)
runs the five GPU criteria. Desktop: RTX 3070, Godot 4.7-stable, Forward+.

**Unit test: 31 passed, 0 failed.** Table determinism and order-independence, inert empty slots, loop
closure, the steepness normalisation, the wavelength floor, the analytic normal, the inverse solve, and
behaviour at clipmap-scale coordinates — each with a control that must fail.

**Gate: all five criteria green.**

| # | Criterion | Result | Control |
|---|---|---|---|
| A | one clock | shader `water_time` within 1e-7 s of `get_water_time()` | CPU time offset by one 60 Hz frame → detected |
| B | **G4** | 0 of 384 probes off by 1 cm; 0 off by **1 mm**; 0 off horizontally | CPU heights offset 5 cm → 64/64 detected |
| C | tessellation | 22 cm sag, reported not graded | — (informational) |
| D | §4.4 shadows | receiver 0.384 casting vs 0.778 not, and "not casting" == "no ocean" exactly | terrain always set opposite |
| E | §4.5 cull AABB | sea level 0 and 300 both 100% coverage | AABB frozen stale → **0%**, recovers to 100% |

**1. §4.3 item 4 was wrong, and the correction is the main result of this phase.** The spec asserted the
naive height was accurate to "a few cm" below steepness ~0.5 and made the inverse solve the caller's
problem. Measured at the ocean defaults and steepness 0.35 — inside the range the sentence called safe —
the naive answer is off by **mean 0.213 m, worst 1.86 m**. G4's budget is 0.01 m. Not a tolerance to widen:
`get_water_height()` now solves the inverse itself.

Convergence, measured, worst case over an 81×81 probe grid:

| `wave_steepness` | steps | horizontal residual | height error bound |
|---|---|---|---|
| 0.05 | 4 | 3.8e-6 m | 2.2e-6 m |
| 0.35 (default) | 8 | 3.1e-5 m | 1.8e-5 m |
| 0.6 | 13 | 6.8e-5 m | 4.0e-5 m |
| 0.8 | 16 | 9.7e-5 m | 5.7e-5 m |
| 1.0 | 16 (capped) | 4.1e-3 m | 2.4e-3 m |

The height error is bounded by the residual times the surface's maximum slope `Σ(w·A)`, which is what has
to fit in G4 — the residual itself is horizontal. `MAX_SOLVE_ITERATIONS` is 16, sized for 0.8. **1.0 is not
a slow case, it is an ill-posed one**: that is the self-intersection limit, the surface has vertical
tangents and the inverse stops being unique. It is reported and not asserted. It happens to land inside G4
anyway.

**2. G4 is met with two decades of headroom, including the two things layered on top of the wave sum.**
The probe shader includes the real `water_waves.gdshaderinc` at the shipped wave count, with the
default-table fallback path left in, and reads its wave table off the ocean material rather than rebuilding
it — so it cannot pass by being configured differently from the water on screen. Zero probes differ by 1 mm
at a domain origin **12 km out** and a **300 m sea level**, at six frozen instants.

The readback is **binary, not a magnitude**, and that is the design rather than a limitation: an 8-bit
render target cannot carry a millimetre through quantisation, but a threshold decided on the GPU in float
and written as 0.0 or 1.0 survives anything. Three decades per pass, one per channel.

**3. There is no runtime read of a global shader parameter.** `RenderingServer.global_shader_parameter_get()`
is editor-only and returns nil in a game, with an error. Criterion A therefore asks the *shader* whether its
clock matches, via a dedicated probe cell. That is the better question in any case: what the global table
holds is not evidence about what reached the draw.

**4. Draw frames are not physics frames, and a gate that confuses them measures a half-built scene.**
With vsync off and `max_fps = 0` this harness renders hundreds of frames per 60 Hz tick, while everything
Pasture3D does for the water — the clock, the AABB poll, the clipmap snap — happens in physics. The first
run settled on draw frames and reported 0% water coverage where there should have been 100%, plus six
"different" instants that were all the same one. Every settle that depends on C++ now awaits
`get_tree().physics_frame`.

**5. A culling test has to be framed so that culling can show.** Gate E's first framing looked *down* at
the water, and a 300 m stale AABB changed the coverage by nothing measurable — a downward frustum contains
almost everything below the camera, so the control failed to fail. Looking *up* from below, a stale AABB is
below the camera and outside the frustum entirely, and the control goes from 100% coverage to 0%. The
lesson generalises: a control that does not fail has not been shown to be a control.

**6. Two latent defects fell out of §4.5 that the spec had not identified** — a dead `_update_ocean_aabbs()`
that would have applied the terrain's height range to the ocean, and an extent conversion that assumed
`min <= 0`. Both are described in §4.5.

---

### 8.6 Phase 5 results — measured 2026-07-28

Three harnesses. [bench/WaterPhase5Gate.tscn](project/bench/WaterPhase5Gate.tscn) runs the five gate
criteria; [bench/WaterPresetCheck.tscn](project/bench/WaterPresetCheck.tscn) checks the presets against
their shaders; [bench/WaterGeometrySweep.tscn](project/bench/WaterGeometrySweep.tscn) is the measurement
q6 was decided on. Desktop: RTX 3070, Godot 4.7-stable, Forward+.

**Gate: all five criteria green. Unit test 34/34** (three new, see finding 5).

| # | Criterion | Result | Control |
|---|---|---|---|
| E | detail slope is physical | rms 0.101 m/m, tail 0.500 | the old default of 1.0 → rms 0.403, tail 2.0, **fails** |
| A | **G1**, desktop | high 0.295 ms, low 0.235 ms vs legacy 0.452 at −60° | sky floor 0.064 must sit below every water row |
| B | the shipped presets render | 87% ocean coverage; lake/pond 62% on a bare mesh | high-vs-low delta 0.028 against a high-vs-high control of 0.000 |
| C | §11 q6 geometry defaults | ratio 10.18, sag 1.7 cm | old defaults → ratio 2.54, sag 21 cm, **fails** |
| D | A/B captures | 9 pitch×material + 4 wave counts | — (reported for sign-off) |

**⚠️ The exit gate is only half met, and the missing half is not a formality.** Phase 5's gate reads "G1
met on Steam Deck". No Deck was available and none is expected, so **every Deck figure in this document is
extrapolated from a desktop measurement and none of it has been validated**. The fallback in §11 q7 was to
measure on the lowest-spec GPU on hand; the only GPU on hand is the RTX 3070 the whole project has been
measured on, so there is not even a second data point. This is stated rather than papered over: the
desktop result is comfortably inside the retired desktop target, which says nothing certain about a 15 W
RDNA2 part. The gate file runs unchanged on a Deck when one appears.

**Cost, 1280×800, ocean filling the frame (−60°), better of two passes:**

| Configuration | GPU ms | vs legacy |
|---|---|---|
| sky floor, no ocean | 0.064 | — |
| legacy shader, legacy geometry | 0.452 | 1.00× |
| legacy shader, new geometry | 0.504 | 1.12× |
| **new high tier, legacy geometry** | 0.267 | **0.59×** |
| **new high tier, as shipped** | 0.295 | **0.65×** |
| **new low tier, as shipped** | 0.235 | **0.52×** |

Both changes are priced separately on purpose. Shader-for-shader on identical geometry the replacement is
**0.59×**; the shipped configuration gives 6% of that back to the denser LOD0 that fixes the 22 cm sag,
landing at 0.65×. Neither number is quoted without the other.

**1. §11 q6 is closed by spending geometry, and the clipmap made it cheap.** The question was how to fix
the 22 cm gap between the drawn and analytic surfaces. What mattered was not which spacing but what
spacing *costs*: a clipmap is scale-invariant, so quartering LOD0's spacing quarters the ocean's reach and
two extra rings buy it back — it is not an N² triangle count. Adopted **`ocean_vertex_spacing` 1.0 m and
`ocean_mesh_lods` 9**, holding the 8192 m half-extent.

| config (mesh_size, spacing, lods) | ratio | sag | GPU ms | primitives |
|---|---|---|---|---|
| shipped before (16, 4.0, 7) | 2.54 | 22.2 cm | 0.231 | 1.00× |
| (16, 2.0, 8) | 5.09 | 5.9 cm | 0.245 | 1.73× |
| **adopted (16, 1.0, 9)** | **10.18** | **1.7 cm** | **0.261** | **2.46×** |
| (32, 1.0, 8) | 10.18 | 1.7 cm | 0.270 | 6.24× |

Sag falls as spacing², and the rings from LOD2 outward are exactly what shipped before — so this is
strictly better at every distance, not a trade of near fidelity for far. Reaching the same ratio through
`mesh_size` 32 costs 6.2× the primitives for the same sag and was rejected.

**2. §11 q1 is closed at 8 waves, and the reason is structural rather than aesthetic.** The captures settle
4 vs 8 easily — at 4 the sea shows obvious corduroy streaking to the horizon, at 8 it does not. The
argument against going further is that **8 waves already span the whole available range**: with `L_max`
137 m and the 10 m precision floor, waves 9 through 16 could only subdivide 137→10.2 more finely, not
extend it, and the sub-10 m band that would actually add richness is the detail texture's job by design
(§3.1). Raising `WATER_MAX_WAVES` is a uniform-array and default-table change with nothing visible
motivating it. **Not doing it.**

**3. `detail_strength` had been 4× too strong since Phase 3, and it took looking at a picture to find
it.** The first A/B captures came back with rust-coloured speckle across the surface and flat grey slabs
along the horizon. One constant caused both.

`gen_water_textures.py` computes a real derivative in m/m, normalises it by its own 99.5th percentile so
the 8-bit range is spent on what is visible, and then **discards the divisor** — it is printed, never
stored. So the decoded value is a *fraction of full scale*, while the shader treated it as slope in m/m
and defaulted `detail_strength` to 1.0 on the belief, stated in its own comment, that 1.0 meant "the
texture as authored". Measured off the shipped PNG: stored rms 0.277 per layer, peak 1.0. Two summed
layers at 1.0 therefore reached **0.39 rms slope with excursions past 2.0** — normals tilted below the
horizon, so the reflection vector found the procedural sky's brown ground hemisphere. The same constant
feeds `variance_to_roughness`, so distant water was simultaneously taking +0.55 roughness and greying out.
One number, wrong at both ends of the distance range.

Default is now **0.25** (~0.10 m/m rms over both layers). Reproducing the authored slope exactly would be
0.422, the discarded divisor.

**The lesson is about the shape of the Phase 3 gate, not about the constant.** Phase 3 had eleven criteria
covering this texture — tiling delta, mip presence, speckle ratio, cost in ms — and every one of them
measured a *quantity*. None asked whether the composed normal was physically possible, so all eleven
passed on a surface that was reflecting the ground. Gate criterion E now asserts exactly that, needs no
rendering at all, and uses the old default as a control that must fail.

**4. A second shading defect, found only because the first one was fixed.** With the speckle gone, dark
dashes remained scattered across the mid-distance at grazing pitches. They survived disabling detail,
foam, scattering and the new geometry — and vanished under `cull_back`.

The water is `depth_draw_never`, so it does not occlude itself, and `cull_disabled` therefore rasterises
the far side of every wave crest: fragments a solid surface would have hidden. Those are `!FRONT_FACING`
while the viewer is plainly above the water, and the two-sided flip gave them a downward normal. **Which
side of the surface the viewer is on is a property of the camera and cannot be read off one triangle.** A
new varying carries the undisplaced sheet height — `sea_level`, or the mesh's own y — so the test also
works for a plain `MeshInstance3D` with no `sea_level` uniform. `cull_disabled` stays, and the Phase 4
gate's underwater criterion still passes.

**5. Two defects surfaced by authoring, not by testing.** Writing a pond preset asked for `length_max`
12 m, which revealed that `update()` runs the series down to `min(MIN_WAVELENGTH, length_max/2)` — so it
deliberately goes *below* the 10 m floor for small bodies, while the header declared 10 m as "the shortest
wavelength the generator will produce". The behaviour is right (a pond sits near its own origin, not in
the precision regime the floor describes); the contract and the test were wrong. Sub-test (e) could never
have caught it, because the ocean config it uses cannot enter the branch. New sub-test (e2) pins it, with
a large-body control.

Writing the *user guide* found the second: `_update_water_clock()` and the sun global write were both
inside `if (_ocean_enabled)`, so a terrain with a lake mesh and no ocean had its water frozen at t=0.
Those are globals serving every water body in the scene (G6). Hoisted out.

**6. Coverage is the wrong question for "are these two presets different".** Criterion B first reported
the high and low ocean presets at an identical 86.9%, and lake and pond at an identical 62.2%. That is the
correct answer to what coverage asks — both draw water over the same silhouette — but it means the
criterion would have passed unchanged if `M_water_ocean_low.tres` silently loaded the high shader. It now
differences each pair, with a same-preset re-render as the control that must come out at zero.

Two failures of the same kind, both now closed in the gate: `_screenshot()` printed "written" for all nine
A/B captures while every save had failed on a missing directory *and the gate still reported PASS*; and
after the legacy shader moved, a stale uid made `load()` return null, the ocean drew nothing, "LEGACY"
measured exactly the sky floor, and the new shader appeared **four times more expensive** than the thing
it replaces — reported as data. A gate that cannot tell "measured nothing" from "measured a good result"
is not a gate.

**7. The legacy shader is retired but not destroyed.** `ocean_shader.gdshader` and `M_ocean.tres` moved to
[bench/legacy/](project/bench/legacy/) rather than being deleted: every performance claim in this document
is stated against that material, and Phase 0's baseline, Phase 3's ablation ladder and Phase 5's own A/B
all have to stay re-runnable. It is out of the addon, which is what ships. The writes only it read —
`_light_color`, `_light_direction`, and the never-read `_vertex_density` (§9 item 5) — are gone.
[Demo.tscn](project/demo/Demo.tscn) now uses the new ocean preset, so the demo shows what ships.

---

## 9. Carried-over fix list

Defects found in the legacy shader that must not survive into the replacement.
**All resolved as of Phase 5**: items 2 and 8 were fixed in the replacement during Phase 3; the rest
were properties of the legacy shader itself, which is no longer in the addon (§8.6 finding 7). Items 5
and 6 also had C++ halves, and those are gone: `_vertex_density` is no longer written, and the sun is
published once to a global rather than pushed per-material every frame.

1. `sea_level` double-counted in `water_depth` ([line 233](project/bench/legacy/ocean_shader.gdshader:233)).
2. ✅ **Fixed, Phase 3.** `T_water_foam`'s predecessor has `generate_mipmaps = false`
   ([M_ocean.tres:14](project/bench/legacy/M_ocean.tres:14)) while sampled in world
   space over kilometres. Both new textures ship with mips, asserted by gate A on the imported `Image`
   rather than trusted from the `.import` file (§8.4).
3. `shore_mask` at [line 201](project/bench/legacy/ocean_shader.gdshader:201) —
   `1.0 - clamp(1.0 - smoothstep(a,b,x), 0, 1)` reduces exactly to `smoothstep(a,b,x)`.
4. `TANGENT` / `BINORMAL` computed (2 cross + 2 normalize per pixel) and never used.
5. `_vertex_density` uniform written by C++ ([pasture_3d.cpp:228](src/pasture_3d.cpp:228)), never read.
6. `_target_pos` written to the ocean material every frame unconditionally
   ([pasture_3d_mesher.cpp:402](src/pasture_3d_mesher.cpp:402)) while the terrain path change-detects.
7. Unbounded `TIME` precision decay (§3.2).
8. ✅ **Fixed, Phase 3.** `ROUGHNESS = 0.02` with no variance compensation (§3.4). Gate F measures the
   result at 30× less speckle than legacy at 500 m (§8.4).

---

## 10. Risks

| Risk | Mitigation |
|---|---|
| ~~Global shader uniform registration from GDExtension is unreliable~~ | **Retired.** Phase 1 gate C: globals register and reach the fragment shader. The per-material fallback was dropped (§2.3). |
| ~~Cheap depth reconstruction wrong under reversed-Z~~ | **Retired.** Phase 2 gate G: exact agreement over 186k pixels (§3.5). |
| 8 Gerstner waves look too regular vs. the legacy noise | Directional spread + the detail texture are the intended answer. If insufficient, add a third detail scroll before adding waves — fragment texture fetches are cheaper here than vertex trig. |
| ~~Steepness > 0.5 breaks the CPU query's heightfield assumption~~ | **Retired, and it was never a steepness-0.5 problem.** Phase 4 measured the heightfield assumption failing by 1.86 m at steepness **0.35** (§8.5). The query now solves the Gerstner inverse itself at every steepness, so there is nothing left to clamp or expose. |
| ~~`cull_disabled` doubles fragment cost if any overdraw exists~~ | **Retired.** Phase 3 gate G: `cull_back` and `cull_disabled` measure the same 0.259 ms (§8.4 finding 6). No overdraw capture needed. |
| Full-screen water may be unaffordable on the Deck **whatever** the shader does | Phase 3 measured Godot's lit transparent floor at 0.144 ms of the 0.259 ms total on a 3070 (§8.4). If that floor scales like the rest, the Deck's floor alone is ~1.1–1.9 ms against G1's 1.0 ms budget. The two levers, both costly, are §11 q5 (hand-rolled lighting) and a half-resolution water pass (§8.4 finding 5). Do not commit to either before the hardware measurement. |

---

## 11. Open questions

1. ~~**Wave count for the ocean high tier: 8, 12 or 16?**~~ — **CLOSED at 8, Phase 5 (§8.6 finding
   2).** The captures settle 4 vs 8 easily. Against 12/16 the argument is structural: with `L_max`
   137 m and the 10 m floor, 8 waves already span the entire available range, so more waves can only
   subdivide it, not extend it — and the sub-10 m band is the detail texture's job by design.
   Original text: Spec says 8. Phase 0 showed the vertex stage is
   nowhere near the constraint (§4.6), and Phase 3 measured the whole wave sum plus blend at 0.008 ms (3% of
   the shader), so cost is not the objection to any of the three. Purely a visual call, for the Phase 5 A/B.
2. **Should `water_time` be pausable/scrubbable?** Trivial to add (the plugin owns the clock) and useful
   for cinematics, but adds a public surface. Defer until asked.
3. **Flow maps for the trough connector.** [trough.gd:7](project/addons/pasture_3d/connectors/trough.gd:7)
   describes water flow. A `WATER_FLOWMAP` define distorting the detail UVs would slot in cleanly. Out of
   scope here; noted so the detail-sampling code is not written in a way that forecloses it.
4. ~~MultiMesh for the ocean draws~~ — **closed by Phase 0.** Draw calls cost ~0.02 ms (§4.6). Not doing it.
5. **Should the water light itself instead of using Godot's PBR light loop?** ⚠️ **The biggest open
   question in this spec, opened by Phase 3's measurement.** The same shader `unshaded` costs 0.011 ms
   against 0.144 ms with the light loop (§8.4 finding 3) — a factor of 13, and the single largest term in
   full-screen water by a wide margin. Water is a special case where hand-rolling is genuinely tractable:
   one directional specular, one radiance-cubemap sample at a chosen mip, and the absorption term the shader
   already computes. **What it costs:** shadow receive, reflection probes, more than one light, `BACKLIGHT`
   and every future engine improvement to any of them — for a plugin whose users will reasonably expect
   their scene's lighting to apply to its water. A middle path is a `WATER_UNSHADED` tier flag, defaulting
   off, so the trade is the project's to make rather than the plugin's. **Do not decide this before the
   Steam Deck measurement** — if G1 is met with the light loop in place, none of it needs spending.

6. ~~**How dense should LOD0 be?**~~ — **CLOSED, Phase 5: `vertex_spacing` 1.0 m, `mesh_lods` 9**
   (§8.6 finding 1). Sag 22 cm → 1.7 cm, ratio 2.54 → 10.18, same 8192 m reach, +0.03 ms. The two
   defaults must move together; see the comment on `_ocean_mesh_lods` in `pasture_3d.h`.
   *Original text, opened by Phase 4:* The ocean defaults put 4 m vertex spacing against a
   10.2 m shortest wavelength — a ratio of 2.54 where `water_waves.gdshaderinc` asks for 8 — and the drawn
   surface consequently sits up to **22 cm** below the analytic one at a cell centre (§8.5, §4.6). G4 is
   unaffected; what is affected is anything that has to agree with what the player sees, which is the whole
   point of having a CPU query. Geometry is measurably free (§8.1), so the cost of fixing it is close to
   nothing; the reason it is still open is that the fix is a number per preset and the presets are Phase 5.
   The three levers are LOD0 spacing, `ocean_wave_length_max` (which sets the whole geometric series and
   therefore L_min), and the wavelength floor itself. Decide with the Phase 5 A/B screenshots in hand.

7. **Steam Deck validation — ⚠️ STILL OPEN after Phase 5, and now the only thing between this work and
   done.** The hardware was confirmed unavailable at the start of Phase 5, and the fallback (validate
   on the lowest-spec GPU on hand) could not be taken either: the only GPU available is the RTX 3070
   every measurement in this document was taken on. **So every Deck figure here is extrapolated and
   none of it is validated — including G1 itself.** What is known: the high tier costs 0.295 ms and
   the low tier 0.235 ms at 1280×800 with water filling the frame, on a 3070, and 0.064 ms of that is
   the sky floor. What is not known is how that scales to a 15 W RDNA2 part, and §8.4's finding that
   56% of the cost is Godot's lit transparent path rather than this shader is the reason not to guess.
   [bench/WaterPhase5Gate.tscn](project/bench/WaterPhase5Gate.tscn) runs unchanged on a Deck; criterion
   A is the measurement. Until it is run, do not quote a Deck number from this document.
