# phase1_ref — reference captures for the Phase 2 gate

Read by `bench/WaterBodiesPhase2Gate.gd` (criterion A). The gate's header carries the full
reasoning; this is the short version for anyone who opened the directory first.

## What is in here

| File | Origin | Last changed |
| --- | --- | --- |
| `phase0_baseline.json` | Original Phase 1 reference, from `WaterBodiesPhase0Baseline` | unchanged |
| `phase0_terrain_clipmap.png` | Original Phase 1 reference | unchanged |
| `phase0_ocean_{high,low}_pitch{4,20,60}.png` | Re-captured from the live gate | **2026-08-04** |

It is a mixed record on purpose. The JSON drives the frame-time comparison and the terrain
capture still matches at `0.000000`, so neither had anything to re-baseline; re-recording the
JSON would have meant benchmarking on a machine that is not reliably idle and baking that in.

The files are named `phase0_*` for historical reasons — they are the Phase 1 reference, not the
Phase 0 one. `phase1_ref/` began as a byte-identical copy of `phase0/` because Phase 1 changed
the ocean's frame time (~1.7%) but not its image.

## Why the ocean captures were refreshed

Commit `6967bdd` (2026-08-02, *"Water presets: OceanDetail and HeightOceanFoam become the
defaults"*) swapped, on `M_water_ocean.tres`:

- `detail_deriv`: `T_water_deriv.png` → `OceanDetail.png`
- `foam_tex`: `T_water_foam.png` → `HeightOceanFoam.png`

That changes the rendered ocean by construction (the commit measured the detail map's rms at
0.4001 → 0.3854 and its peak at 1.4142 → 0.8835). The baselines were not refreshed at the time,
so from that commit the gate failed all six ocean captures — deltas 0.0103 to 0.0241 against a
0.002 tolerance — while printing *"the extracted ocean does not draw what the reference drew"*.

That message reads as a Phase 2 refactor bug. It was not one, and this was established rather
than assumed: reverting **only** `M_water_ocean.tres` and `M_water_ocean_low.tres` to
`6967bdd~1` dropped all six deltas to `0.000000` and passed the gate.

## What this cost

Criterion A can no longer prove the Phase 2 refactor was pixel-neutral; it proves nothing has
moved since the last refresh. The original proof is preserved in `baselines/phase2/`, which is
byte-identical to `baselines/phase0/` — the record that the refactor was neutral when graded.

## Refreshing again

The next intended art change to an ocean preset will fail this gate the same way. **That is the
gate working.** Before refreshing:

1. Confirm the cause is art, by reverting the material files as above and re-running.
2. Refresh only once every delta is explained.
3. Add the reason to the gate header and to the table above.

To capture without benchmarking (this box runs another engine — do not benchmark unasked):

```bash
BENCH_OUT=<dir> SKIP_TIMING=1 Godot_v4.7-stable_win64_console.exe --path project bench/WaterBodiesPhase2Gate.tscn
```

Then copy `<dir>/phase2_ocean_*.png` over the matching `phase0_ocean_*.png`. Run it **windowed** —
the gate awaits `RenderingServer.frame_post_draw`, which never fires under `--headless`.
