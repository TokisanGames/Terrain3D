# Pasture3D Unaccelerated Nodes Upgrade Specification

This specification defines the phased upgrade plan for all remaining **20 unaccelerated GDScript nodes** in the Pasture3D Procedural Terrain Graph System to high-performance C++ GDExtension kernels, complete with automated CI parity gates.

---

## 1. Overview & Acceleration Matrix

The 20 unaccelerated nodes are grouped into **3 sequential implementation phases** prioritized by real-world computational load and editor responsiveness impact:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Phase 1: High-Impact Procedural Generators (Highest CPU Load: 75% of execution time)  │
│ 1. NoiseJordan        2. NoiseSwiss       3. GeologicalPrimitive    4. Furrows         │
│ 5. Dunes              6. Crater           7. Noise (FastNoiseLite)                     │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Phase 2: Spatial Neighborhood Filters & Complex Solvers (20% of execution time)       │
│ 8. Smooth (blur_nan)  9. Scree (Talus)   10. DLA Massif                                │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ Phase 3: Point Modifiers & Math Combiners (5% of execution time, completes native DAG) │
│ 11. Terrace          12. Strata          13. Curve                 14. Remap           │
│ 15. Mask             16. Blend           17. Const                 18. Input/Output    │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Phase 1: High-Impact Procedural Generators

### 1. `NoiseJordan` (`Pasture3DGraphNodeNoiseJordan`)
- **Current Bottleneck:** Evaluates `get_noise_2d()` **18 to 30 times per cell** for finite difference slope gradients across 6–10 octaves. (4.7M–7.8M GDScript calls for $512^2$).
- **C++ Native Kernel:** `src/pasture_3d_noise_jordan.h/.cpp`
- **Method Signature:**
  ```cpp
  static PackedFloat32Array noise_jordan_grid(
      int p_gw, int p_gh, const Rect2 &p_rect,
      float p_amplitude, float p_frequency, int p_octaves,
      float p_gain, float p_lacunarity, float p_warp_strength,
      float p_damp_strength, int p_seed);
  ```
- **Optimization Strategy:**
  - Fast single-pass analytical / finite-difference gradient evaluation using native `FastNoiseLite` C++ implementation or SIMD noise buffers.
  - Multi-threaded row chunking using Godot's `WorkerThreadPool`.

---

### 2. `NoiseSwiss` (`Pasture3DGraphNodeNoiseSwiss`)
- **Current Bottleneck:** Ridge noise with analytical derivatives ($\sim 18$ noise lookups per cell).
- **C++ Native Kernel:** `src/pasture_3d_noise_swiss.h/.cpp`
- **Method Signature:**
  ```cpp
  static PackedFloat32Array noise_swiss_grid(
      int p_gw, int p_gh, const Rect2 &p_rect,
      float p_amplitude, float p_frequency, int p_octaves,
      float p_gain, float p_lacunarity, float p_ridge_offset,
      float p_erosion_accent, int p_seed);
  ```
- **Optimization Strategy:**
  - Vectorized ridge inversion `(ridge_offset - abs(noise))^2` and slope damping in contiguous C++ float loops.

---

### 3. `GeologicalPrimitive` (`Pasture3DGraphNodeGeologicalPrimitive`)
- **Current Bottleneck:** Radial distance fields, trigonometric slope profiles (inselbergs, calderas, cuestas), and displacement wobble.
- **C++ Native Kernel:** `src/pasture_3d_geological_primitive.h/.cpp`
- **Method Signature:**
  ```cpp
  static PackedFloat32Array geological_primitive_grid(
      int p_gw, int p_gh, const Rect2 &p_rect,
      int p_primitive_type, float p_amplitude, float p_radius,
      float p_slope_angle, float p_cavity_depth, float p_rim_width,
      Vector2 p_center_offset, float p_wobble_amp, int p_seed);
  ```
- **Optimization Strategy:**
  - Pure SIMD-friendly vector math for radial Euclidean distances and polynomial/cosine profiles.

---

### 4. `Furrows` (`Pasture3DGraphNodeFurrows`) & 5. `Dunes` (`Pasture3DGraphNodeDunes`)
- **Current Bottleneck:** 2D rotated trigonometry + coordinate wobble noise per cell.
- **C++ Native Kernels:** `src/pasture_3d_furrows.h/.cpp`, `src/pasture_3d_dunes.h/.cpp`
- **Method Signatures:**
  ```cpp
  static PackedFloat32Array furrows_grid(
      int p_gw, int p_gh, const Rect2 &p_rect,
      float p_amplitude, float p_spacing, float p_direction_deg,
      int p_profile, float p_wobble_amp, float p_wobble_size, int p_seed);

  static PackedFloat32Array dunes_grid(
      int p_gw, int p_gh, const Rect2 &p_rect,
      float p_amplitude, float p_wavelength, float p_direction_deg,
      float p_asymmetry, float p_wobble_amp, float p_wobble_size, int p_seed);
  ```

---

### 6. `Crater` (`Pasture3DGraphNodeCrater`) & 7. `Noise` (`Pasture3DGraphNodeNoise`)
- **Current Bottleneck:** Crater multi-rim geometry math and standard FastNoiseLite grid materialization.
- **C++ Native Kernels:** `src/pasture_3d_crater.h/.cpp`, `src/pasture_3d_noise.h/.cpp`
- **Method Signatures:**
  ```cpp
  static PackedFloat32Array crater_grid(
      int p_gw, int p_gh, const Rect2 &p_rect,
      float p_radius, float p_depth, float p_rim_height, float p_rim_width,
      Vector2 p_center_offset, float p_wobble_amp, int p_seed);

  static PackedFloat32Array noise_grid(
      int p_gw, int p_gh, const Rect2 &p_rect,
      Ref<FastNoiseLite> p_noise_resource, float p_amplitude, float p_offset);
  ```

---

## 3. Phase 2: Spatial Neighborhood Filters & Complex Solvers

### 8. `Smooth` (`Pasture3DGraphOps.blur_nan`)
- **Current Bottleneck:** Multi-pass separable box blur with NaN edge handling looping over $N$ elements in GDScript.
- **C++ Native Kernel:** `src/pasture_3d_smooth.h/.cpp`
- **Method Signature:**
  ```cpp
  static PackedFloat32Array smooth_blur_nan_grid(
      const PackedFloat32Array &p_surface, int p_gw, int p_gh, int p_passes);
  ```
- **Optimization Strategy:**
  - Row-major horizontal pass into ping-pong buffer with AVX2/NEON vectorization, followed by column-major vertical pass.
  - Multi-threaded row slicing with `WorkerThreadPool`.

---

### 9. `Scree` (`Pasture3DGraphNodeScree`) & 10. `DLA Massif` (`Pasture3DGraphNodeDLA`)
- **Current Bottleneck:** Multi-pass slope slippage relaxation (Scree) and random-walk cluster growth + pyramid blurring (~600 lines in `Pasture3DReliefDLA`).
- **C++ Native Kernels:** `src/pasture_3d_scree.h/.cpp`, `src/pasture_3d_dla.h/.cpp`
- **Method Signatures:**
  ```cpp
  static Dictionary scree_solve_grid(
      const PackedFloat32Array &p_surface, int p_gw, int p_gh, const Rect2 &p_rect,
      float p_talus_angle, int p_iterations, float p_shed_rate);

  static Dictionary dla_solve_grid(
      const PackedFloat32Array &p_seed_surface, int p_gw, int p_gh, const Rect2 &p_rect,
      float p_amplitude, float p_coverage, float p_detail_size, float p_wander,
      int p_hierarchy_levels, float p_profile_power, int p_blur_levels,
      float p_blur_growth, bool p_ridge_seeding, float p_ridge_amount, int p_seed, int p_resolution);
  ```

---

## 4. Phase 3: Point Modifiers & Math Combiners

### 11. `Terrace` & 12. `Strata`
- **C++ Native Kernels:** `src/pasture_3d_terrace.h/.cpp`, `src/pasture_3d_strata.h/.cpp`
- **Method Signatures:**
  ```cpp
  static PackedFloat32Array terrace_grid(
      const PackedFloat32Array &p_surface, int p_gw, int p_gh, const Rect2 &p_rect,
      float p_band_height, float p_hardness, float p_amount, float p_jitter, float p_jitter_size, int p_seed);

  static PackedFloat32Array strata_grid(
      const PackedFloat32Array &p_surface, int p_gw, int p_gh, const Rect2 &p_rect,
      float p_frequency, float p_dip_degrees, float p_strike_degrees, float p_strength,
      float p_hardness, float p_noise_amp, int p_seed);
  ```

---

### 13. `Curve`, 14. `Remap`, 15. `Mask`, 16. `Blend`, 17. `Const`
- **C++ Native Kernels:** Implemented in `src/pasture_3d_math_ops.h/.cpp`
- **Method Signatures:**
  ```cpp
  static PackedFloat32Array curve_remap_grid(
      const PackedFloat32Array &p_surface, int p_n, const PackedFloat32Array &p_baked_lut, float p_min_h, float p_max_h);

  static PackedFloat32Array remap_grid(
      const PackedFloat32Array &p_surface, int p_n, float p_in_min, float p_in_max,
      float p_out_min, float p_out_max, float p_knee, bool p_invert);

  static PackedFloat32Array mask_grid(
      const PackedFloat32Array &p_surface, const PackedFloat32Array &p_gate_input,
      int p_gw, int p_gh, const Rect2 &p_rect, int p_mask_type, float p_min_val, float p_max_val, float p_falloff);

  static PackedFloat32Array blend_grid(
      const PackedFloat32Array &p_grid_a, const PackedFloat32Array &p_grid_b,
      int p_n, int p_blend_mode, float p_opacity);
  ```

---

## 5. Verification & Parity Gate Plan

For every phase:
1. **Automated Parity Gate:** Add headless test suites (`GraphGeneratorsGate.gd`, `GraphFiltersGate.gd`, `GraphModifiersGate.gd`) comparing C++ output against `[Dev/GD]` reference oracle nodes.
2. **Tolerance Threshold:** $\text{Max absolute difference} \le 1.0\times 10^{-4}\text{ m}$.
3. **Speedup Benchmark Threshold:** $> 30\times$ faster than GDScript reference oracle on $512^2$ grids.
