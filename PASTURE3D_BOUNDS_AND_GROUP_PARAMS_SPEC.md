# Pasture3D Region Bounds & Shader Group Params Spec

Authored 2026-08-06, from two defects found while porting upstream Terrain3D changes
(`ae300c0`, `ad96f23`) rather than from a failing gate. Both predate the port and both survive on
`main` at `df99e02`.

The two are unrelated to each other. They share a document because they share a cause: a value that
is *nearly* right in the common case, so nothing ever looked at it.

> **Status: both phases implemented and verified 2026-08-06.** The §2.4 open question is resolved
> in §2.4.1. Every criterion below was run twice — once against the fix, and once against the
> defect deliberately reinstated, to confirm it can actually fail. §5 records what each run showed.

---

## 1. Goal

Two pieces of derived state are wrong in ways that no current gate can see, because both are
correct on the demo terrain. Fix each, and in both cases add the criterion that would have caught
it — on a fixture that can actually express the failure, which the demo terrain cannot.

### 1.1 Goals

- The region bounding box is the box that contains the regions. Nothing else.
- There is **one** implementation of it. Today there are two copies that must agree, and the
  correctness of sliced export depends on them agreeing.
- `_shader_parameters` contains shader parameters. Group markers are inspector layout, not state,
  and do not belong on disk or in the public parameter API.
- Existing materials heal themselves. No manual `.tres` editing, no migration tool.

### 1.2 Non-goals

- Reworking the `//INSERT:` group scheme. §3 changes what is *recorded*, not how groups are
  declared or rendered.
- Changing export file formats, naming, or the 16384 px slice ceiling. §2 changes only the rect
  those decisions are computed from.
- Upstreaming either fix. Terrain3D has both; whether to send patches is a separate call.
- Deleted-region semantics. §2.4 flags an inconsistency but deliberately does not resolve it.

### 1.3 The defects

| # | Defect | Why nothing caught it | Phase |
|---|---|---|---|
| 1 | Region bounds always contain the world origin | Demo regions are `(0,0) (0,-1) (0,-2)` — they *do* contain the origin, so the buggy and correct answers are identical | **2** |
| 2 | Same bounds computed twice, in two functions that must agree | They agree today because one was copy-pasted from the other | **2** |
| 3 | r16 height scale is computed over background fill | Only bites when bounds are inflated, i.e. only alongside #1 | **2** |
| 4 | Shader group markers are stored as shader parameters | `ExportModeCheck` and friends assert render output; nothing asserts what is *serialised* | **3** |

---

## 2. Phase 2 — the bounding box stops including the origin

### 2.1 The defect

[`pasture_3d_data.cpp:2361`](src/pasture_3d_data.cpp:2361) and
[`pasture_3d_data.cpp:2498`](src/pasture_3d_data.cpp:2498) both run this loop:

```cpp
Vector2i top_left = V2I_ZERO;          // (a) seeded at the origin, not at a region
Vector2i bottom_right = V2I_ZERO;
for (const Vector2i &region_loc : _region_locations) {
    if (region_loc.x < top_left.x) {
        top_left.x = region_loc.x;
    } else if (region_loc.x > bottom_right.x) {   // (b) else-if: one region updates at most one end
        bottom_right.x = region_loc.x;
    }
    // ... same for y
}
```

Two errors, one symptom. `(a)` seeds both corners at `(0,0)`, so the origin is always inside the
result. `(b)` means a region that lowers `top_left` can never also raise `bottom_right` — which
matters when every region is on one side of the origin, because then the other corner never moves
off zero at all.

### 2.2 What it is *not*

Worth stating precisely, because it bounds the severity and I checked it rather than assuming:

> **The computed box always contains the true box. It never crops.**

Per axis, `top_left` converges to `min(0, true_min)`: the `<` branch fires whenever a smaller value
appears. And `bottom_right ≥ max(0, true_max)`: if the true max `M ≥ 0` then when `M` is processed
`M < top_left` is false (since `top_left ≤ 0`), so the `else if` runs and raises `bottom_right` to
at least `M`; if `M < 0` then every region is negative, `bottom_right` stays `0 > M`. Either way
the true extent is enclosed.

So **no terrain data is ever lost or misplaced within the image.** This is an inflation bug.

### 2.3 What it costs

Take regions at `(3,3)` and `(4,4)`, `region_size` 1024:

| | computed | correct |
|---|---|---|
| `top_left` → `bottom_right` | `(0,0)` → `(4,4)` | `(3,3)` → `(4,4)` |
| image | 5120 × 5120 px | 2048 × 2048 px |
| origin | `(0, 0)` | `(3072, 3072)` |

**6.25× the pixels**, of which the terrain occupies 16%. Three consequences follow:

1. **Oversized output.** A 25 MP EXR where 4 MP was asked for.
2. **Spurious slicing.** `export_image` slices at 16384 px measured from the inflated origin, and
   suffixes filenames only when `chunks_x == 1 && chunks_y == 1`
   ([`pasture_3d_data.cpp:2436`](src/pasture_3d_data.cpp:2436)). A terrain that fits one tile but
   sits far from the origin gets split into several suffixed files, most of them entirely
   background. The user asked for `height.exr` and got `height_00_00.exr` … `height_02_01.exr`.
3. **Wrecked r16 normalisation.** [`_save_export_image`](src/pasture_3d_data.cpp:2458) derives the
   16-bit scale from `Util::get_min_max()` over the whole tile — including background fill. A
   terrain whose heights span 100–200 m, padded with fill at 0, is normalised across 0–200 and
   loses half its 16-bit precision. This one is silent and permanent: it is baked into the exported
   file.

Consequence 3 is the reason this is worth fixing rather than filing. The other two are visible; a
quietly halved height resolution is not.

### 2.4 The fix

One private helper on `Pasture3DData`, and both call sites use it:

```cpp
// Exact pixel rect covering every region. Empty when there are none.
// Seeded from the first region, and min/max are independent per axis -- a single region must be
// able to set both corners, which is exactly what the old `else if` prevented.
Rect2i _region_bounds_px() const;
```

```cpp
Rect2i Pasture3DData::_region_bounds_px() const {
    if (_region_locations.is_empty()) {
        return Rect2i();
    }
    Vector2i tl = _region_locations[0];
    Vector2i br = tl;
    for (const Vector2i &loc : _region_locations) {
        tl.x = MIN(tl.x, loc.x);  br.x = MAX(br.x, loc.x);
        tl.y = MIN(tl.y, loc.y);  br.y = MAX(br.y, loc.y);
    }
    return Rect2i(tl * _region_size, (br - tl + Vector2i(1, 1)) * _region_size);
}
```

Delete both inline loops. This is the whole of the change: the slicing, naming and blitting
downstream already work off `terrain_origin` / `terrain_size` and need no edits.

### 2.4.1 The deleted-region question, resolved

The question was whether `export_image`'s `region->is_deleted()` check is redundant given that
`_region_locations` has entries removed on delete. **It is not redundant. The helper must filter.**

`remove_region()` ([`pasture_3d_data.cpp:551`](src/pasture_3d_data.cpp:551)) does keep the two in
step — it sets the flag and drops the array entry together, and dirties the region map. But
`set_region_deleted()` ([`pasture_3d_data.cpp:463`](src/pasture_3d_data.cpp:463)) sets the flag
*alone*: no array update, no `_region_map_dirty`. It is bound to GDScript
([`pasture_3d_data.cpp:2608`](src/pasture_3d_data.cpp:2608)), so a script can leave a deleted
region sitting in `_region_locations` indefinitely — nothing will rebuild the array until some
unrelated edit dirties the map.

So the helper filters deleted regions, and `layered_to_image`'s blit loop gains the same check it
was missing — otherwise a deleted region would be drawn into an image whose bounds deliberately
excluded it.

Noted in passing, not fixed: `import_images`
([`pasture_3d_data.cpp:2255`](src/pasture_3d_data.cpp:2255)) revives a deleted region by clearing
and reconfiguring it, but never calls `set_deleted(false)` and never re-adds it to
`_region_locations`. The revived region stays invisible. That is a separate defect and out of
scope here.

### 2.5 The criterion that would have caught it

`ExportModeCheck` passes today and would pass with the bug in place, because it derives its
expectation from `_extent_px()` — a GDScript *copy of the same buggy algorithm*
([`ExportModeCheck.gd:113`](project/bench/ExportModeCheck.gd:113)). A test that reimplements the
code under test asserts nothing. That helper must be deleted, not corrected.

Add to `ExportModeCheck`, building synthetic terrain via `add_region_blank(Vector2i)` so the
fixture is independent of demo data:

- **[D] Bounds are the regions, not the regions plus the origin.** Regions at `(3,3)` and `(4,4)`,
  exported SLICED. Assert the image is exactly `2048 × 2048` and that **one unsuffixed file** is
  written. Expectation is a literal, computed by hand from `region_size`, never from a helper that
  mirrors the implementation.
- **[E] One region sets both corners.** A single region at `(4,4)`. Assert `1024 × 1024`. This is
  the case the `else if` alone gets wrong, isolated from the seeding error, so a partial fix
  cannot pass.
- **[F] Negative-only regions.** Regions at `(-5,0)` and `(-3,0)`. Assert `3072 × 1024`, not
  `6144 × 1024`. This is the case where `bottom_right` never leaves zero.
- **[G] CONTROL.** Regions at `(0,0)` and `(1,1)` — a terrain that genuinely touches the origin.
  Assert `2048 × 2048`. If D–F pass by unconditionally subtracting something, G fails.

G matters. D–F all assert "smaller than the buggy answer", which a fix that over-corrects would
also satisfy. G is the case where the old and new answers must agree.

### 2.6 Consequence to accept

Exported images move. A heightmap exported before this change is anchored at
`min(0, min_region)`; after, at `min_region`. Anyone re-importing an old export against a new one
must use the origin the exporter logs
([`pasture_3d_data.cpp:2376`](src/pasture_3d_data.cpp:2376) already prints it in both px and world
units). This affects only terrains that do not touch the origin — which is precisely the set of
terrains that were being exported wrong.

---

## 3. Phase 3 — group markers stop being shader parameters

### 3.1 The defect

[`_get_property_list()`](src/pasture_3d_material.cpp:1223) special-cases group markers to build
their `PropertyInfo`, then falls through to the code that records *parameters*:

```cpp
if (use == PROPERTY_USAGE_GROUP) {
    dict["name"] = split_name[...].capitalize();
    current_group = split_name[0].capitalize();
    dict["usage"] = name.contains("::") ? PROPERTY_USAGE_SUBGROUP : PROPERTY_USAGE_GROUP;
} else {
    ...
}
// ... both paths reach here:
new_active_params.push_back(name);                       // :1253
if (!_shader_params.has(name)) {
    _property_get_revert(name, _shader_params[name]);    // :1261
}
```

`_shader_params` is bound with `PROPERTY_USAGE_STORAGE`, so every group name is written to disk as
a parameter whose value is null.

### 3.2 Verified, not inferred

Probed against `M_terrain.tres` on `df99e02`:

```
=== _shader_parameters keys that are shader GROUP markers ===
  auto_shader = <null>
  dual_scaling = <null>
  general_uniforms = <null>
  macro_variation = <null>
  mipmaps = <null>
  private = <null>
total keys: 39, group markers among them: 6

get_shader_param("general_uniforms") -> <null>   (a group, not a parameter)
```

**6 of 39 keys are not parameters.** Three consequences:

1. **Disk noise that accumulates.** Only 6 of the 10 declared groups appear, because
   `world_background_noise`, `contour_lines`, `debug_heightmap` and `displacement` are behind
   `//INSERT:` gates that are currently off. Enable a feature once and its group name is written
   permanently — the entry survives disabling the feature again, since
   [the prune in `save()`](src/pasture_3d_material.cpp:1145) only removes names absent from the
   *current* shader, and re-enabling is what puts it back.
2. **The public API accepts a group name as a parameter.** `_active_params.has()` is the gate on
   `_set`, `_get`, `_property_can_revert` and `_property_get_revert`, so all four claim to handle
   `"general_uniforms"`. `get_shader_param("general_uniforms")` returns null rather than
   complaining, which is a silent typo trap for anyone driving the material from script.
3. **It made the group rename in `ad96f23` messier than it needed to be.** The stale
   `shader_uniforms/*` keys left in `M_terrain.tres` had to be deleted by hand. They existed only
   because of this defect.

### 3.3 The fix

Group markers go into the property list and nowhere else:

```cpp
if (use == PROPERTY_USAGE_GROUP) {
    dict["name"] = split_name[MAX(split_name.size() - 1, 0)].capitalize();
    current_group = split_name[0].capitalize();
    dict["usage"] = name.contains("::") ? PROPERTY_USAGE_SUBGROUP : PROPERTY_USAGE_GROUP;
    // A group is inspector layout, not state. It is not a parameter, must not be settable
    // through _set/_get, and must not reach the .tres. Heal materials that already recorded
    // one -- this runs on every inspector refresh, so no migration step is needed.
    _shader_params.erase(name);
    group.push_back(dict);        // property list only
    continue;                     // skip new_active_params and the _shader_params write
}
```

`_shader_params` is already `mutable`, so the `erase` is legal from this `const` method.

Self-healing covers every case that matters: keys under the *current* group names are erased here,
and keys under names no longer in the shader — the old `shader_uniforms/*` — are removed by the
existing prune in `save()`. No migration code, no version stamp.

The `continue` needs the loop body restructured slightly so the group branch still lands its
`PropertyInfo` in `grouped_params[current_group]` first. Straightforward, but it is the one place
in this phase where a careless edit silently drops the inspector headings — which is what §3.4
criterion B exists to catch.

### 3.4 The criterion that would have caught it

New `MaterialParamsCheck.gd`. Nothing today asserts anything about what a material *stores*, only
about what it renders — which is why a defect this visible in a text file went unnoticed.

- **[A] No group name is stored or claimed as a parameter.** Read `_shader_parameters` and assert
  no key matches a `group_uniforms` name declared in the generated shader. Group names are scraped
  from `RenderingServer.shader_get_code()` rather than hardcoded, so adding a group later cannot
  quietly escape the check.
- **[B] CONTROL — the inspector still has its headings.** Assert `get_property_list()` still
  contains `PROPERTY_USAGE_GROUP` entries, one per declared group. Without this, "no groups
  anywhere" passes A perfectly, and deleting the group handling entirely would look like a fix.
- **[C] Real parameters are untouched.** Assert a known public uniform (`blend_sharpness`) is still
  present in `_shader_parameters`, still settable through `set_shader_param`, and still reads back.
  Guards against a fix that filters too broadly.
- **[D] Toggling a feature does not leave a key behind.** Enable `world_background = NOISE`, force
  a property-list refresh, disable it, refresh again. Assert `world_background_noise` never appears
  in `_shader_parameters`. This is consequence 1 from §3.2, which is the one that accumulates over
  a project's life.

---

## 4. Order and cost

Independent — either phase can land alone, in either order.

| Phase | Files | Risk |
|---|---|---|
| **2** bounds | `pasture_3d_data.{h,cpp}`, `ExportModeCheck.gd` | Low. One helper, two call sites deleted. Changed export origin is the only behaviour change (§2.6). |
| **3** group params | `pasture_3d_material.cpp`, new `MaterialParamsCheck.gd` | Low-moderate. The restructure around `continue` can drop inspector headings; §3.4 B is the guard. |

Phase 2's open question is resolved in §2.4.1.

Both need the standard sweep before merge: `MaxRegionsCheck`, `LightTargetCheck`,
`ExportModeCheck`, `MaterialParamsCheck`, `WaterBodiesPhase1Gate`, `WaterBodiesPhase6Gate`,
`WaterPresetCheck`, `PASTURE3D_UNIT_TESTS=water`.

---

## 5. What the criteria showed

Each gate was run against the fix and against the defect deliberately reinstated. A criterion that
has not been seen to fail is not evidence.

### 5.1 Phase 2 — `ExportModeCheck` [D-G]

With the old algorithm restored (`V2I_ZERO` seed, `else if` chaining), region size 256:

| | with defect | correct | verdict |
|---|---|---|---|
| D regions at (3,3),(4,4) | 1280×1280 (5×5 regions) | 512×512 | **FAIL** |
| E single region at (4,4) | 1280×1280 (5×5) | 256×256 | **FAIL** |
| F regions at (-5,0),(-3,0) | 1536×256 (6×1) | 768×256 | **FAIL** |
| G CONTROL, (0,0),(1,1) | 512×512 | 512×512 | **pass** |

D, E and F reproduce §2.3's hand-computed predictions exactly. G passing under the defect is the
point of it: that is the case where the old and new answers genuinely agree, so a fix that
over-corrected would be caught there and nowhere else.

### 5.2 Phase 3 — `MaterialParamsCheck`

With group markers allowed to fall through again:

- **[A] FAIL.** 39 stored keys, 6 of them group names. And `set_shader_param("private", 0.5)` read
  back `0.5` — the group was not merely stored, it was *settable*, which is §3.2 consequence 2
  demonstrated rather than argued.
- **[C] pass.** Real parameters unaffected, as intended — C is scoped to catch an over-broad fix,
  not this defect.
- **[D] FAIL**, and specifically `after=true`: enabling `world_background = NOISE` wrote
  `world_background_noise` into the store, and disabling it again did **not** remove it. That is
  the accumulation in §3.2 consequence 1, observed.
- **[B] FAIL** — but for the wrong reason, and worth recording. The crude revert also dropped the
  group's `PropertyInfo`, so all six headings vanished, which is not what the original defect did
  (it kept them). B did its job as a control, but this run is not a faithful reproduction of the
  original bug for B specifically.

After the fix: 33 stored keys, down exactly the 6 group markers, all nine inspector headings
present.

### 5.3 Still not covered by any gate

Phase 3 touches the material's property system. Headings present ([B]) and values readable and
settable ([C]) are asserted, but **revert arrows** — `_property_can_revert` /
`_property_get_revert`, which now fall through to `Resource::` for group names — are not, and
nothing here substitutes for opening the material in the inspector and looking at it.
