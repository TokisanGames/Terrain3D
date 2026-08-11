---
title: Relief Materials & Selectors — Setup and Tuning Guide
aliases: [Relief Guide, Plow Materials, ReliefSelector]
tags: [pasture3d, terrain, plow, relief, authoring-guide]
updated: 2026-08-08
---

# Relief Materials & Selectors

How to set up a [[#The Plow|Pasture3DPlow]] with a relief material, what every knob actually does, and how
to tell a badly-tuned material from a broken one.

> [!info] Related
> [[PASTURE3D_PLOW_RELIEF_MATERIAL_SPEC]] — the design + implementation spec (why things work this way).
> [[PASTURE3D_LAYERS_GUIDE]] — the layer stack, which decides what a Selector can see.
> [[PASTURE3D_PLOW_BRUSH_SPEC]] — the original Plow brush.

---

## 1. The mental model

Four things multiply together to produce the height change at any point:

```
height change = Height Scale  ×  material output  ×  loop mask  ×  Strength
                  (metres)        (−1 … +1)         (0 … 1)      (0 … 4)
```

- **Height Scale** lives on the Plow. It is the only setting in metres.
- **Material output** is what the relief material computes, always roughly `−1 … +1`. Negative digs.
- **Loop mask** is the spline falloff: `1` in the middle of your loop, easing to `0` at the edge.
- **Strength** is a per-material multiplier so a saved `.tres` can carry its own intensity.

> [!tip] The one number to remember
> A material at full output with `Height Scale = 8` moves the ground **±8 m**. If you want gentler relief,
> lower Height Scale first — it is the honest global control. Amplitude knobs inside materials are for
> balancing layers *against each other*.

A **Selector** multiplies the material output by an extra `0 … 1` based on what the ground was already
doing there — its steepness, height, or concavity.

---

## 2. Setup: from nothing to visible relief

1. **Place the brush.** Use the Pasture3D toolbar's **Plow** button and click on the terrain. Brushes
   placed this way arrive with `Source = Relief` already set and a starter square loop.
   > [!warning] Add Child Node does not do this
   > A Plow created through Godot's own *Add Child Node* dialog arrives with `Source = Noise` and **no
   > spline**. Set the source yourself and press **Add Spline**. This is a known limitation — the toolbar
   > is the intended route.
2. **Check the loop.** You need at least 3 points. Drag the `Area1` child's points in the viewport.
3. **Assign a material.** In the Inspector, click the **Relief** slot → **Quick Load** → pick one from
   `demo/data/relief/` (see [[#9. Shipped presets]]), or **New Pasture3DReliefFractal** to start fresh.
4. **Set Height Scale.** Start at `8`. You should see relief immediately.
5. **Set the Mask.** `Falloff Width` (default `10 m`) is how far in from the loop edge the relief fades
   up from nothing.

> [!warning] Falloff wider than your loop
> If `Falloff Width` is larger than the loop's half-width, the mask never reaches `1` anywhere — even the
> centre gets partial relief, and a small loop can look like it is doing almost nothing. Keep
> `Falloff Width` well under half the loop's smallest dimension.

---

## 3. The Plow

Only the settings that change what a relief material does. Everything else is inherited brush plumbing.

| Setting | Default | What it does |
|---|---|---|
| **Source** | `Relief` (new nodes) | Which displacement source. `Relief` is the material system this guide covers. `Noise`/`Texture`/`Material` are the older, simpler sources. |
| **Relief** | *empty* | The material. Shown only when Source is `Relief`. |
| **Mapping** | `Tile` | How the material is laid across the loop. See [[#5. Mapping]]. |
| **Height Scale** | `8.0` | Metres of relief at full material output and full mask. **Your master volume.** |
| **Relative to Terrain** | `on` | `on` = stamp on top of existing ground. `off` = build relative to the node's Y plane (a deliberate flat pad). |
| **Blend Mode** | `Add` | How the layer composites. `Add` layers relief on top; `Max`/`Min` are raise-only / lower-only; `Replace` is an absolute pad. |
| **Falloff Width** | `10.0` | Metres from the loop edge over which relief fades in. |
| **Falloff Curve** | *empty* | Optional custom fade shape (default is smoothstep). |
| **Edge Offset** | `0.0` | Grow (+) or shrink (−) the masked area off the spline, in metres. |
| **Smooth Passes** | `0` | Post-blur of the stamped relief. `1–2` softens; `3+` will visibly eat fine detail. |

> [!note] Height Offset and Tile Size disappear under Relief
> That is deliberate. Relief materials output a signed value already (no mid-grey convention), and their
> feature sizes are set per-op in metres, so a global metres-per-repeat means nothing.

---

## 4. Settings every material shares

| Setting | What it does | When to touch it |
|---|---|---|
| **Strength** | Multiplier on this material's whole output. | Balancing a stack layer, or dialling one saved preset down without editing its internals. |
| **Blend** | How this material enters the accumulator **when it is a layer in a [[#8. Stacks\|Stack]]**. | Ignored when assigned directly on a brush. |
| **Output Curve** | Remaps the finished signed output. Curve X and Y both span `−1 … +1` as `0 … 1`. | Flattening valleys, exaggerating peaks, clipping one side. |
| **Selector** | Terrain-aware gate. See [[#6. Selectors]]. | Confining a material to steep ground, an altitude band, or hollows. |

> [!warning] Output Curve inside a Stack
> An Output Curve is a *profile* operation — it remaps the **whole accumulator**, not just its own layer.
> On a Stack layer it therefore shapes everything accumulated up to and including that layer. Useful once
> you know it; surprising if you don't.

---

## 5. Mapping

| Mode | What it does | Use for |
|---|---|---|
| **Tile** | Material is evaluated in world space, continuously — no repeat, no seams. | Craggy sections, strata, dunes, furrows. **The default and usually right.** |
| **Fit** | Material is mapped **once** onto the loop's oriented bounding rectangle. | A **single** crater, mesa, or stamped heightmap. The loop's rotation and aspect now matter. |
| **Scatter** | N jittered instances placed inside the loop. | Crater *fields*, boulder fields. Relief only. |

> [!bug] Craters under Tile
> A crater is sized by the loop, so under `Tile` you get one crater **per tile** — a grid of them. The
> brush raises a configuration warning if it spots this. Set `Mapping = Fit`.

### Scatter settings

| Setting | Default | Notes |
|---|---|---|
| Scatter Count | `12` | Instances to place. |
| Scatter Seed | `0` | Placement is fully deterministic from this. Change it to reroll the layout. |
| Radius Min / Max | `8` / `24` | Instance size in metres. |
| Rotation Jitter | `1.0` | `0` = all instances share the material's orientation; `1` = free rotation. |
| Scale Jitter | `0.25` | ± variation in each instance's strength. |
| Scatter Overlap | `0.0` | `0` = instances may not touch; `1` = overlap freely. |
| Scatter Blend | `Strongest` | How overlaps combine. `Strongest` keeps whichever is furthest from flat — the *deeper* crater, the *taller* mound. `Max` would keep the shallower crater, which is why it is not the default. |

> [!tip] "Scatter placed only N of M"
> A configuration warning when low `Overlap` + high `Count` + big radii cannot fit. Raise Overlap, shrink
> the radii, or lower the Count.

---

## 6. Selectors

A `Pasture3DReliefSelector` gates a material by what the ground is **already** doing.

| Setting | Units by Filter Type | What it does |
|---|---|---|
| **Filter Type** | — | `Slope` (degrees, 0–90) · `Altitude` (world metres) · `Curvature` (**metres** this cell sits below its surroundings: **+** = hollow, **−** = ridge, `0` = straight slope) · plus four that read a Pasture3DSim's output — `Flow`, `Erosion`, `Deposition`, `Wetness` |
| **Range Min / Max** | deg / m / m² | The band that **passes**. |
| **Falloff Low** | same units | How far *below* Range Min the gate fades in. `0` = hard cut, which shows as a visible contour line. |
| **Falloff High** | same units | How far *above* Range Max the gate fades out. |
| **Invert** | — | Pass everything *outside* the band. |
| **Strength** | `0 … 1` | How hard the gate bites. `1` = material only inside the band. `0` = **no gating at all**. |
| **Measure Radius** | metres | Over what distance `Slope` and `Curvature` are measured. `0` = one cell, which is fine for texture-scale detail. Raise it to ask about **landform**: "steep over 20 m" rather than "steep between two adjacent vertices", which is what you want on noisy or eroded ground. Ignored by the other Filter Types. |

> [!tip] Changing the Filter Type re-defaults the band — unless you have edited it
> The units change completely between Filter Types (degrees, metres, square metres of catchment), so a
> band that means "steep" means nothing at all on `Flow`. Switching Filter Type therefore moves Range
> Min/Max and the falloffs to sensible defaults for the new one. **The moment you type your own number
> into any of them, that stops happening** and your band survives every later switch. `Altitude` is the
> one Filter Type with no useful default — it depends entirely on how tall your terrain is — so it keeps
> whatever is there and expects you to set it by hand.

> [!warning] Range Min above Range Max passes **nothing**, anywhere
> Not "almost nothing" — the gate is zero on every cell, on every Filter Type, and the material simply
> never appears. The brush raises a configuration warning saying so; if a material has silently stopped
> showing up, check the band is the right way round first.

### What a Selector reads — and why it matters

> [!important] It reads the layers *below* the Plow's own layer, not the finished terrain
> This is not a detail; it is the whole reason the feature is safe. If a Selector read the final surface,
> the relief it just wrote would change the slope it reads next time, and your bake would creep every
> refresh. Reading the below-layer composite means a Plow can never gate on its own output.
>
> **Practical consequence:** if you want scree on a Mound's flanks, the **Mound must be on a layer below
> the Plow** in the Pasture3D Layers dock. A Mound on the *same or a higher* layer is invisible to the
> Selector, and it will gate against flat ground and produce nothing.

### Proving a Selector is working

This is the fastest self-test, and it is exactly how the automated gate checks it:

1. Set the Selector's **Strength to `0`**. The material should now cover the **whole loop** evenly.
2. Set Strength back to **`1`**. Relief should vanish from everything outside the band.

If step 1 does not fill the loop, the problem is the material, not the Selector. If step 2 changes
nothing, the problem is the band or the terrain — see the next section.

> [!tip] Sane starting bands
> **Slope:** `Range Min 25`, `Max 90`, `Falloff Low 10`, `Falloff High 0`. Slopes above ~25° are what
> most people mean by "the steep bits".
> **Altitude:** open one end (`Max 10000`) and use `Falloff Low` for a soft treeline.
> **Curvature:** start narrow, e.g. `Min 0.02`, `Max 1.0`, `Falloff Low 0.05`. Curvature magnitude scales
> with the terrain's Vertex Spacing, so there is no universally right number — read the value off a
> test bake rather than guessing.

---

## 7. The materials

All amplitude-ish values are fractions of **Height Scale**, not metres.

### Pasture3DReliefFractal — *the workhorse*
Rolling hills, craggy rock, lumpy ground.

| Setting | Default | Tuning |
|---|---|---|
| Style | `Craggy` | `Hills` = smooth fBm. `Craggy` = ridged multifractal, sharp ridges + smooth valleys. `Lumpy` = billow. |
| Amplitude | `1.0` | Leave at 1 when used alone; drop it when layering. |
| Feature Size | `64 m` | Size of the **largest** feature. The main shape control. |
| Octaves | `5` | Detail levels. Past ~5 the extra octaves fall under the vertex spacing and only cost time. |
| Lacunarity / Gain | `2.0` / `0.5` | Size ratio and height ratio between octaves. Raise Gain for rougher. |
| Sharpness | `1.0` | Craggy only. `>1` knife-edges the ridges. |
| Warp Amount | `0.0` | **Turn this on.** 10–25 m of domain warp is the difference between "noise" and "terrain". |
| Warp Size | `96 m` | Size of the warping swirls. Usually a bit larger than Feature Size. |

**Tune in this order:** Feature Size → Warp Amount → Octaves → Sharpness.

### Pasture3DReliefCrater — *needs Mapping = Fit or Scatter*

| Setting | Default | Tuning |
|---|---|---|
| Floor Depth | `0.7` | Bowl depth at the centre. |
| Rim Height | `0.15` | Real rims are far shallower than the bowl is deep — 0.1–0.25 × Floor Depth reads right. |
| Rim Width | `0.25` | Fraction of the loop radius given over to rim + ejecta. `0.25` puts the crest at 75% out. |
| Ejecta Falloff | `2.0` | How fast the blanket dies past the rim. Higher = tighter. |
| Floor Flatness | `0.35` | `0` = parabolic bowl; higher flattens the floor and steepens the walls. |
| Terrace Steps | `0` | Concentric slump benches. |
| Roughness | `0.0` | Fractal break-up over the whole crater so the rim isn't glassy. |

### Pasture3DReliefStrata — *tilted, broken rock layers*

| Setting | Default | Tuning |
|---|---|---|
| Layers | `14` | Bands across the relief range. |
| Hardness | `0.75` | `0` = no banding at all. `1` = sheer cliffs between flat shelves. |
| Dip | `0.25` | Geological tilt, in relief units per 100 m. `0` = dead horizontal bedding. |
| Dip Direction Degrees | `45` | Compass direction the beds tilt towards. |
| Break Amount | `0.12` | **The one that matters.** Wanders the boundaries so beds become local plates. Without it you get corduroy, not rock. |
| Break Size | `45 m` | Size of those plates. |
| Base Relief → Base Amount | `1.0` | See the callout below. |

### Pasture3DReliefTerraces — *stepped benches*

| Setting | Default | Tuning |
|---|---|---|
| Steps | `8` | Benches across the relief range. |
| Hardness | `0.8` | `0` = untouched, `1` = flat benches with vertical risers. |
| Step Jitter | `0.08` | Uneven bench spacing. This is what separates "eroded" from "staircase". |
| Jitter Size | `80 m` | Length scale of that unevenness. |
| Base Relief → Base Amount | `1.0` | See below. |

> [!important] Base Relief on Strata and Terraces
> These two materials work by **remapping relief that already exists** — on their own they would have
> nothing to band. So they each carry a built-in fractal (`Base Amount`, on by default) to make them
> useful standalone.
>
> **Set `Base Amount = 0` when the material sits above another layer in a Stack.** Then it stratifies or
> terraces *that layer's* output instead of adding a competing shape of its own. This is the single most
> common mistake with these two.

### Pasture3DReliefDunes

| Setting | Default | Tuning |
|---|---|---|
| Amplitude | `1.0` | |
| Wavelength | `40 m` | Crest to crest. |
| Direction Degrees | `0` | Dunes march this way; crests run perpendicular. |
| Asymmetry | `0.7` | `0.5` = symmetric. Lower gives the long windward slope + abrupt slip face. |
| Crest Sharpness | `1.4` | `>1` broadens troughs and narrows crests. |
| Wander Amount / Size | `12 m` / `120 m` | Sideways drift so crests aren't dead straight. |

### Pasture3DReliefFurrows — *ridge-and-furrow, rills, gullies*

| Setting | Default | Tuning |
|---|---|---|
| Amplitude | `0.35` | |
| Spacing | `15 m` | Crest to crest. **See the scale warning below.** |
| Direction Degrees | `0` | |
| Profile | `U` | `V` = sharp cut, `U` = weathered, `Square` = flat-topped beds. |
| Wobble Amount / Size | `2 m` / `70 m` | Waver along each row. |

> [!bug] This is not for plough rows
> Real plough rows are ~0.5 m apart and **cannot be represented in a 1 m height map at any setting** —
> they belong in the surface shader. What this material does represent is the landform: medieval
> ridge-and-furrow runs 5–20 m crest to crest.
>
> The defaults used to be 4 m and were effectively invisible for this reason. If you set Spacing below
> about **4 × the terrain's Vertex Spacing**, the brush now warns you.

### Pasture3DReliefScree — *talus, gully fill*
The first material that reads the terrain. Ships with its own slope gate.

| Setting | Default | Tuning |
|---|---|---|
| Amplitude | `0.12` | Scree is a thin skin — keep it small. |
| Grain Size | `6 m` | Rubble clump size. Under ~4 m it stops resolving. |
| Downslope Streak | `4 m` | Smears the grain downhill so it reads as material that has *travelled*. |
| Toe Deposition | `0.35` | Piles material into concavities. This is what makes a talus fan look deposited. |
| Slope Gate → Min Slope Degrees | `22` | Below this, no scree — flat ground sheds nothing. |
| Slope Gate → Slope Falloff Degrees | `12` | Softness of that cut-off. A hard cut leaves a contour line across the hill. |

---

## 8. Stacks

`Pasture3DReliefStack` evaluates its layers in order; each enters using **its own Blend** property. There
is no per-layer overhead — a stack costs exactly what its layers cost.

> [!example] Weathered cliff
> 1. `Pasture3DReliefStrata` — the rock. Give it a **Slope** selector (`Min 28`, `Falloff Low 14`).
> 2. `Pasture3DReliefScree`, Blend `Add` — talus. Its own slope gate handles placement.
>
> Shipped as `demo/data/relief/weathered_cliff.tres`.

> [!example] Terraced hillside
> 1. `Pasture3DReliefFractal`, Style `Hills`, Warp Amount `20`.
> 2. `Pasture3DReliefTerraces` with **`Base Amount = 0`** — terraces layer 1 instead of adding its own.

---

## 9. Shipped presets

In `demo/data/relief/`. Load one, then tune — they are meant as starting points.

| Preset | Material | Notes |
|---|---|---|
| `craggy_rock` | Fractal | Ridged + warp. The general-purpose "make this rocky". |
| `rolling_hills` | Fractal | Smooth, heavily warped. |
| `impact_crater` | Crater | **Set Mapping = Fit.** |
| `cratered_badlands` | Stack | Terraced crater + fine roughness. Fit or Scatter. |
| `dune_field` | Dunes | |
| `plowed_field` | Furrows | Ridge-and-furrow at 16 m. |
| `layered_rock` | Strata | |
| `terraced_hillside` | Terraces | |
| `talus_slope` | Scree | Slope-gated already. |
| `weathered_cliff` | Stack | Slope-gated strata + talus. |

---

## 10. Is it working, or is it bugged?

| Symptom | Most likely cause |
|---|---|
| **Nothing at all happens** | `Source` is not `Relief`; no material in the Relief slot; loop has <3 points; `Terrain` not assigned. Check the node's warning triangle first — hover it. |
| **Nothing happens, everything looks right** | Material `Strength` or `Amplitude` is `0`. Or a Selector is excluding the whole area — set its **Strength to 0** to confirm. |
| **Very faint relief** | `Height Scale` too low; `Falloff Width` wider than half your loop, so the mask never reaches 1; `Smooth Passes` ≥ 3. |
| **Furrows / dunes invisible** | Spacing or wavelength too fine for the terrain's Vertex Spacing. The brush warns below 4×. |
| **Craters in a repeating grid** | `Mapping = Tile`. Set it to `Fit`. |
| **A crater ignores the loop's rotation** | You are on `Tile`. Only `Fit` and `Scatter` use the loop's oriented frame. |
| **Strata / Terraces look like a flat staircase** | `Break Amount` (Strata) or `Step Jitter` (Terraces) is `0`. |
| **Strata / Terraces add a shape you didn't want in a Stack** | `Base Amount` is still `1.0`. Set it to `0`. |
| **Selector does nothing** | Wrong units (Slope is **degrees**); the ground below genuinely is not in that band; the Mound/shape you want to gate against is **not on a lower layer**. |
| **Selector excludes everything** | `Range Min` too high for the actual terrain. Drop it to `0` and raise it until relief starts disappearing. |
| **Relief grows every time it re-bakes** | Should be impossible — bakes are idempotent and verified so. Report it. |

> [!done] Fixed 2026-08-08 — you may have hit this
> Selectors originally gated only *shape-generating* operations, not *remapping* ones. A gated
> `Strata` or `Terraces` correctly zeroed its fractal base and then ran its banding on that zero — which
> is **not** zero. Fully excluded ground still came out stepped, by up to `0.43 × Height Scale`
> (≈3.4 m at the default). Selectors now gate every operation, blending smoothly between un-remapped and
> remapped. If you saw stepped relief on ground a Slope selector should have excluded, that was this.

### Reading the warning triangle

The Plow surfaces these; hover the triangle in the Scene dock:

- *"no Relief Material is assigned"*
- *"contains a Crater … set Mapping = Fit"*
- *"repeating feature every N m, but the terrain samples height every M m"*
- *"Scatter placed only N of M instances"*
- *"Mapping = Scatter only applies to Source = Relief"*
- *"Add at least one spline"*
- *"These splines share a Curve3D with another spline"* — a duplicated brush shares its curve by
  reference; use **Make Unique**.

---

## 11. Scale limits

The Plow writes into the **height map**, sampled at the terrain's `Vertex Spacing` (1 m by default).

| Feature size | Result |
|---|---|
| < 2 m | Cannot be represented. Surface-shader territory. |
| 2–4 m | Aliases badly. Periodic materials produce nothing usable; the brush warns. |
| 4–10 m | Resolves, but softly. Fine for grain and rubble. |
| > 10 m | Clean. |

Fractal materials are exempt from the warning on purpose: their fine octaves are *meant* to run past the
vertex spacing and quietly stop contributing. A periodic material set too fine produces nothing at all,
which reads as broken — hence the warning on those only.

---

## 12. Verifying a build

If you suspect the system rather than your settings:

```bash
"G:/LaughingRooster/GodotVersions/Godot_v4.7-stable_win64/Godot_v4.7-stable_win64_console.exe" --headless --path project bench/PlowReliefCheck.tscn
```

14 gates, each with a control that fails if the test is measuring nothing. A clean run ends
`=== PLOW RELIEF PASS (0 failures) ===`.
