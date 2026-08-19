# Pasture3D — Ridge / Trough Flank Redesign Spec

Status: **drafted, not implemented** (interview complete 2026-06-21).
Scope: `Pasture3DRidge` ([pasture3d_ridge.gd](project/addons/pasture_3d/connectors/pasture3d_ridge.gd)),
`Pasture3DTrough` ([pasture3d_trough.gd](project/addons/pasture_3d/connectors/pasture3d_trough.gd)), and the native
rasterisers `stamp_ridge_line` / `stamp_trough_line` in
[pasture_3d_brush_raster.cpp:600](src/pasture_3d_brush_raster.cpp:600). GDScript reference paths in the
two connectors must stay byte-equivalent to the C++ (A/B oracle via `force_gdscript_raster`).

Builds on [[pasture3d-landscape-tools]]. Requires an engine rebuild (`python -m SCons`) because the
rasterisers change.

---

## 1. Problem

Both brushes drive the whole cross-section off **one anchor reference per cell** — `by` (ridge) /
`top_y` (trough). In Follow-Spline-Height mode that anchor is the spline's Y at the nearest crest
point, and the flank is `painted = anchor + crest_height * profile(lat)`:

- crest (profile 1) → `spline_Y + crest_height`
- skirt edge (profile 0) → `spline_Y`

So the flank descends to a **flat horizontal plane at the spline height**, not to the terrain. With
MAX blend that leaves a flat shelf where the ground is lower and makes the ridge vanish where the
ground is higher — the "sharp cut-off from the spline down." `slope_tilt` only fixes this by dragging
the anchor (and thus the crest) down to the ground, defeating Follow-Spline-Height.

**Root flaw:** a single reference cannot hold the crest at the spline *and* land the skirt on the
terrain. `taper_ends` inherits the same flaw (it eases `amp` to 0, so a tapered end on a sloped spline
floats at one end and buries at the other — the reported "tapers one side, cuts off the other").

---

## 2. New cross-section model (two references)

Per cell, interpolate between the **ground beneath this layer** and the **crest top**:

```
ground   = base_below[cell]                     # composite of layers below this brush's; get_height() fallback
crest_top = (follow ? spline_Y : ground) + crest_height
painted   = lerp(ground, crest_top, profile(lat / W_eff))      # lat in [0, W_eff]
          = ground                                              # lat  > W_eff (already at terrain)
```

- **Follow on:** `crest_top = spline_Y + crest_height`. The crest sits exactly on the spline you
  authored in 3D; the flank drapes down to the real terrain at every point. (Decision: spline Y *is*
  the crest, `crest_height` is an optional extra lift, **default 0**.)
- **Follow off:** `crest_top = ground + crest_height` → `painted = ground + crest_height*profile`, a
  uniform-height feature draped on terrain (the skirt already meets ground). No centreline-ground
  channel needed — only Follow-on needs the decoupled reference.
- Skirt always meets the ground exactly (profile 0 → `painted = ground`). No flat shelf, no vanishing.

`base_below` must now be passed **always** (today it is only built when `not follow or slope_tilt>0`).

### 2.1 `slope_tilt` is removed

The new model always drapes the flank to the ground, which is what `slope_tilt=1` approximated. Remove
the `slope_tilt` export and all its rasteriser branches. (Scene files that stored it simply drop the
value — harmless.)

### 2.2 Blend clamping (unchanged intent)

Respect blend mode: ridge default **MAX** never lowers existing terrain (skirt vanishes where ground
sits above the flank); trough default **MIN** never raises. The `lerp(ground, crest_top, …)` result is
clamped by the existing per-pixel blend in `_stamp_write` / `_apply_stamp_block` — no new clamp logic.

---

## 3. Flank shaping modes

New export `flank_mode: enum { FIXED_WIDTH, SLOPE_ANGLE }`, default **FIXED_WIDTH**.

Let `W = width * width_curve(t)` (the along-spline taper, §4) be the per-cell base half-width.

- **FIXED_WIDTH** — `W_eff = W`. Flank spreads over `W` regardless of how high the crest is; the slope
  steepens as the crest rises above ground. `falloff` feathers the non-zero profile edge beyond `W`
  exactly as today.
- **SLOPE_ANGLE** — new export `slope_angle: degrees` (default 30°). The flank descends at that angle
  until it meets terrain, then stops. Reach where a straight ramp hits ground:
  `lat_meet = (crest_top - ground) / tan(slope_angle)`. **Capped by `width`:**
  `W_eff = clamp(lat_meet, 0, W)`. The `profile` Curve still shapes the cross-section within
  `[0, W_eff]` — the angle sets the *reach*, the profile bends the shoulder/toe (decision). If
  `crest_top <= ground` then `W_eff = 0` and the flank vanishes (blend keeps terrain).

Pass `slope_tan = tan(slope_angle)` precomputed in the params dict; guard `tan ≈ 0`.

`falloff` continues to feather beyond `W_eff` in both modes (reuse the current `edge_val` ramp tail).

---

## 4. Width taper curve along the spline

New export `width_curve: Curve` (null ⇒ constant 1.0). Mapped over the spline arc length:
`t = along[i] / total`, `W = width * width_curve(t)`. Lets a ridge fan wide in the middle and pinch at
the ends. **Width only — crest height is not scaled** (decision).

- Sampled into a fixed-size LUT (e.g. 64 entries) in GDScript and passed to the rasteriser as a
  `PackedFloat32Array width_lut` param, sampled by `t` like the existing profile/ramp LUTs
  (`raster_ramp`). Null curve ⇒ omit the param ⇒ C++ treats `W = width`.
- `along[i]` and `total` already come from `raster_polyline_field`
  ([pasture_3d_brush_raster.cpp:199](src/pasture_3d_brush_raster.cpp:199)). **Verify the chamfer
  `along` propagation is symmetric and `total == max(along)`** before relying on it (this is the field
  that the old buggy `taper_ends` also used — confirm it during implementation rather than assuming).
- **Closed loops:** `t` wraps 0→1 around the perimeter; a small discontinuity at the wrap seam is
  acceptable. Document it.

### 4.1 `taper_ends` is removed

The along-spline `width_curve` replaces `Taper Ends` (decision). Drop the `taper_ends` export and its
`_end_taper` paths in both connectors and the `e`/`taper_ends` branches in both rasterisers. Authors
who want end-easing pull the curve down to 0 at `t=0`/`t=1`.

---

## 5. Trough specifics

Symmetric redesign. Decision: **spline Y = bed floor; `depth` additive, default 0.**

```
ground = base_below[cell]                         # the rim the banks rise to meet
bed_y  = (follow ? spline_Y : ground) - depth     # bed floor (depth default 0 ⇒ bed == spline_Y)
```

Banks rise from `bed_y` up to `ground` (not to a flat `top_y` reference as today). With `flat_bed`:

```
W      = (bed_half_width + bank_width) * width_curve(t)   # taper scales the whole half-span
bed_hw = bed_half_width * width_curve(t)
if lat <= bed_hw:        h = bed_y
elif lat <= W_eff:       h = lerp(bed_y, ground, bank_profile((lat - bed_hw)/(W_eff - bed_hw)))
else:                    h = ground
```

`flat_bed = false` ⇒ single basin: `h = lerp(bed_y, ground, bank_profile(lat / W_eff))`.

- **FIXED_WIDTH:** `W_eff = W`. **SLOPE_ANGLE:** banks rise at `slope_angle` until reaching ground,
  capped at `W`: `lat_meet = bed_hw + (ground - bed_y)/tan(slope_angle)`, `W_eff = clamp(lat_meet, bed_hw, W)`.
- Default blend **MIN** keeps it carve-only (banks never bulge above ground). Bank noise tweak
  (lift toward, never above, `ground`) carries over with `top_y → ground`.
- `width_curve` scales the lateral span (bed + bank together) so the channel pinches; height/depth
  unaffected.

---

## 6. Export summary (after)

**Ridge** — Shape: `crest_height` (default **0**), `width`, `flank_mode`, `slope_angle` (shown when
SLOPE_ANGLE), `blend_mode`, `invert`, `profile`, `width_curve`. Crest line: `closed`,
`follow_spline_height`. Falloff: `falloff`. Noise: `noise`, `noise_strength`. **Removed:** `slope_tilt`,
`taper_ends`.

**Trough** — Channel: `depth` (default **0**), `bed_half_width`, `flat_bed`, `flank_mode`,
`slope_angle`, `blend_mode`. Banks: `bank_width`, `bank_profile`, `falloff`, `width_curve`. Bed line:
`closed`, `follow_spline_height`. Noise: `noise`, `noise_strength`. **Removed:** `slope_tilt`,
`taper_ends`. Keep `Make Descend`.

All shape exports keep their `_schedule_refresh()` setters where they have them; `flank_mode`,
`slope_angle`, `width_curve`, `crest_height`/`depth`, `width` should get setters too so edits re-bake
live (today only `blend_mode`/`closed`/`slope_tilt` do). `width_curve` setter must (dis)connect the
curve's `changed` signal like `plow_material` does in [pasture3d_plow.gd](project/addons/pasture_3d/connectors/pasture3d_plow.gd).

---

## 7. Rasteriser changes (C++)

`stamp_ridge_line` / `stamp_trough_line`:

1. Read new params: `flank_mode` (int), `slope_tan` (double), optional `width_lut` (PackedFloat32Array).
2. Remove `slope_tilt` / `taper_ends` reads and their per-cell branches.
3. Require `base_below` always; keep the `get_height(pos)` NaN fallback.
4. Per cell:
   - `ground = base_below[i]` (fallback get_height).
   - `crest_top = (follow ? base_yf[i] : ground) + crest_height`  (ridge) /
     `bed_y = (follow ? base_yf[i] : ground) - depth` (trough).
   - `W = width * (width_lut ? raster_ramp(width_lut, along[i]/total) : 1.0)`.
   - `W_eff`: FIXED_WIDTH ⇒ `W`; SLOPE_ANGLE ⇒ clamp((crest_top-ground)/slope_tan, 0, W) (ridge) /
     clamp(bed_hw + (ground-bed_y)/slope_tan, bed_hw, W) (trough). Guard `slope_tan` tiny / `W_eff<=0`.
   - `p = raster_ramp(profile_lut, lat / max(W_eff, eps))` for `lat <= W_eff`; feather over `falloff`
     beyond; `painted = ground + (crest_top - ground) * p` (ridge) / bank lerp toward `ground` (trough).
   - ADD blend writes `painted - ground`; others write `painted` absolute (matches current `add` path).
5. Reach test becomes `if (lat > W_eff + falloff) continue;` using the per-cell `W` (or a conservative
   `width + falloff` early-out, then the precise test inside, to keep the AABB/footprint padding —
   `_padding()` already returns `width + falloff + 2`).

Mirror every change in the GDScript reference block of each connector so the oracle still matches.

---

## 8. Migration / compatibility

- Demo scenes (`project/demo/data/SculptingDemo/*`) carry baked ridge/trough layers. The redesign
  changes shape output; a Refresh re-bakes them. The currently-modified `.res` files in git status are
  test bakes — re-baking after the change is expected, not a regression.
- `crest_height`/`depth` defaults drop 30→0 / 8→0. Existing scenes keep their stored values, so they
  still lift/carve `+30`/`-8` on top of the spline until the author zeroes them. New nodes start at 0
  (spline = crest/bed).
- Dropped exports (`slope_tilt`, `taper_ends`) are silently discarded from old scenes.

---

## 9. Testing

Headless smoke (pattern from [[pasture3d-landscape-tools]] — call `_refresh_owner(owner,false,[])`
directly; `refresh()` no-ops outside the editor):

1. **Drape-to-terrain (the fix):** flat region at y=0 with a tilted spline (ends at different Y),
   follow on, crest_height 0. Assert crest cells == spline Y and skirt cells == 0 (terrain), no flat
   shelf at spline Y, no vanishing.
2. **Slope-angle reach:** SLOPE_ANGLE, known crest_top above flat ground; assert flank meets ground at
   `≈ (crest_top-ground)/tan(angle)` and is clamped at `width` when the angle would overshoot.
3. **Width curve:** triangular `width_curve` (0 at ends, 1 mid); assert footprint half-width tracks the
   curve along the spline.
4. **Trough:** symmetric — bed == spline_Y (depth 0), banks rise to terrain, blend MIN never raises.
5. **A/B oracle:** `force_gdscript_raster` path matches native within chamfer tolerance for 1–4.
6. **Regression:** Mound/Plow/Splat outputs unchanged.

Then user-verify in-editor on the SculptingDemo scene.
