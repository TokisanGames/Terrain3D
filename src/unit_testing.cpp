// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#include <cmath>

#include <godot_cpp/classes/dir_access.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/resource_loader.hpp>

#include "unit_testing.h"
#include "pasture_3d_data.h"
#include "pasture_3d_layer.h"
#include "pasture_3d_layer_stack.h"
#include "pasture_3d_region.h"
#include "pasture_3d_util.h"
#include "water_waves.h"

void test_differs() {
	UtilityFunctions::print("=== Testing differs function ===");

	// Helper to log differs result with expected and PASS/FAIL
	auto log_differs = [](const auto &a, const auto &b, const String &desc, bool expected) {
		bool d = differs(a, b);
		String result = (d == expected) ? "PASSED" : "FAILED";
		UtilityFunctions::print(desc, ": differs(", a, ", ", b, ") = ", d, " - ", result);
	};

	// 1. Scalars: int, float (should use ==, differs if values differ)
	{
		int i1 = 42;
		int i2 = 42; // Same
		int i3 = 43; // Diff
		log_differs(i1, i2, "int same", false);
		log_differs(i1, i3, "int diff", true);

		double f1 = 3.14;
		double f2 = 3.14; // Same
		double f3 = 3.14159; // Diff
		log_differs(f1, f2, "float same", false);
		log_differs(f1, f3, "float diff", true);
	}

	// 2. Vectors: Vector2, Vector2i, Vector3, Vector3i (should use ==)
	{
		Vector2 v2_1(1.0, 2.0);
		Vector2 v2_2(1.0, 2.0); // Same
		Vector2 v2_3(1.0, 3.0); // Diff
		log_differs(v2_1, v2_2, "Vector2 same", false);
		log_differs(v2_1, v2_3, "Vector2 diff", true);

		Vector2i v2i_1(1, 2);
		Vector2i v2i_2(1, 2); // Same
		Vector2i v2i_3(1, 3); // Diff
		log_differs(v2i_1, v2i_2, "Vector2i same", false);
		log_differs(v2i_1, v2i_3, "Vector2i diff", true);

		Vector3 v3_1(1.0, 2.0, 3.0);
		Vector3 v3_2(1.0, 2.0, 3.0); // Same
		Vector3 v3_3(1.0, 2.0, 4.0); // Diff
		log_differs(v3_1, v3_2, "Vector3 same", false);
		log_differs(v3_1, v3_3, "Vector3 diff", true);

		Vector3i v3i_1(1, 2, 3);
		Vector3i v3i_2(1, 2, 3); // Same
		Vector3i v3i_3(1, 2, 4); // Diff
		log_differs(v3i_1, v3i_2, "Vector3i same", false);
		log_differs(v3i_1, v3i_3, "Vector3i diff", true);
	}

	// 3. String: Share (COW), same value diff ptr, diff value
	{
		String s1 = "test";
		String s2 = s1; // Shared (COW)
		String s3("test"); // Separate alloc, same value
		String s4 = "diff";
		log_differs(String(), String(), "String() vs String()", false);
		log_differs(String(), String("a"), "String() vs String('a')", true);
		log_differs(s1, s2, "String shared", false);
		log_differs(s1, s3, "String same value diff ptr", false); // Length match + == true
		log_differs(s1, s4, "String diff value", true); // Length may match, but == false
	}

	// 4. StringName: Similar to String (uses ==, but test sharing if applicable)
	{
		StringName sn1 = "test";
		StringName sn2 = sn1; // Shared
		StringName sn3("test"); // Separate, same value
		StringName sn4 = "diff";
		log_differs(sn1, sn2, "StringName shared", false);
		log_differs(sn1, sn3, "StringName same value diff ptr", false); // == handles
		log_differs(sn1, sn4, "StringName diff value", true);
	}

	// 5. Array: Share vs mutate
	{
		Array arr1;
		arr1.push_back(42);
		Array arr2 = arr1; // Shared
		Array arr3; // Empty diff
		arr3.push_back(42); // Same content, but separate (differs=true, conservative)
		Array empty_arr; // Explicit empty for size diff
		log_differs(arr1, arr2, "Array shared", false); // Same self ptr
		log_differs(arr1, arr3, "Array same content diff ptr", true); // Diff self ptr (no fallback for Array)
		log_differs(arr1, empty_arr, "Array size diff", true); // Size mismatch
	}

	// 6. TypedArray: e.g., TypedArray<int>
	{
		TypedArray<int> ta1;
		ta1.push_back(42);
		TypedArray<int> ta2 = ta1; // Shared
		TypedArray<int> ta3; // Empty
		ta3.push_back(42); // Separate
		TypedArray<int> empty_ta; // Explicit empty
		log_differs(ta1, ta2, "TypedArray shared", false); // Via Array base
		log_differs(ta1, ta3, "TypedArray same content diff ptr", true); // Diff self
		log_differs(ta1, empty_ta, "TypedArray size diff", true); // Size mismatch
	}

	// 7. Dictionary: Share vs mutate
	{
		Dictionary dict1;
		dict1["key"] = 42;
		Dictionary dict2 = dict1; // Shared
		Dictionary dict3; // Empty
		dict3["key"] = 42; // Separate
		Dictionary empty_dict; // Explicit empty
		log_differs(dict1, dict2, "Dictionary shared", false);
		log_differs(dict1, dict3, "Dictionary same content diff ptr", true); // Diff self
		log_differs(dict1, empty_dict, "Dictionary size diff", true); // Size mismatch
	}

	// 8. Variant types: Wrap above (falls to ==)
	{
		Variant v_int1 = 42;
		Variant v_int2 = 42; // Same
		Variant v_int3 = 43; // Diff
		log_differs(v_int1, v_int2, "Variant int same", false);
		log_differs(v_int1, v_int3, "Variant int diff", true);

		Variant v_float1 = 3.14;
		Variant v_float2 = 3.14;
		Variant v_float3 = 3.14159;
		log_differs(v_float1, v_float2, "Variant float same", false);
		log_differs(v_float1, v_float3, "Variant float diff", true);

		Variant v_str1 = String("test");
		Variant v_str2 = String("test");
		Variant v_str3 = String("diff");
		log_differs(v_str1, v_str2, "Variant String same", false);
		log_differs(v_str1, v_str3, "Variant String diff", true);

		// Variant Object (use RefCounted for ref support)
		Ref<RefCounted> rc1 = memnew(RefCounted);
		Ref<RefCounted> rc2 = rc1; // Same ref
		Ref<RefCounted> rc3 = memnew(RefCounted); // Diff
		Variant v_rc1 = rc1;
		Variant v_rc2 = rc2;
		Variant v_rc3 = rc3;
		log_differs(v_rc1, v_rc2, "Variant RefCounted same ref", false); // Ref == true
		log_differs(v_rc1, v_rc3, "Variant RefCounted diff ref", true);

		// Variant Array
		Array arr_var1;
		arr_var1.push_back(42);
		Variant v_arr1 = arr_var1;
		Array arr_var2 = arr_var1;
		Variant v_arr2 = arr_var2;
		log_differs(v_arr1, v_arr2, "Variant Array shared", false); // Variant == checks inner

		// Variant Dictionary
		Dictionary dict_var1;
		dict_var1["key"] = 42;
		Variant v_dict1 = dict_var1;
		Dictionary dict_var2 = dict_var1;
		Variant v_dict2 = dict_var2;
		log_differs(v_dict1, v_dict2, "Variant Dictionary shared", false);
	}

	UtilityFunctions::print("=== End differs tests ===");
}

// Phase 2 acceptance test (PASTURE3D_LAYERS_GUIDE.md §10.2): with only the synthesized Base layer
// present, compositing must be an identity — the region height map is byte-identical afterwards.
// Also sanity-checks an ADD layer to confirm covered pixels blend and uncovered ones pass through.
void test_layer_compositing() {
	UtilityFunctions::print("=== Testing layer compositing ===");

	const int region_size = 64; // Smallest valid region size; keeps the test fast.
	const Vector2i loc(0, 0);

	// Build a standalone Pasture3DData with one region. add_region(..., false) skips the GPU/terrain
	// path, so no Pasture3D node or RenderingServer is needed.
	Pasture3DData *data = memnew(Pasture3DData);
	Ref<Pasture3DRegion> region;
	region.instantiate();
	region->set_region_size(region_size);
	region->set_location(loc);
	data->add_region(region, false);

	Ref<Image> height_map = region->get_height_map();
	const bool have_map = height_map.is_valid() && height_map->get_format() == Image::FORMAT_RF;
	EXPECT_TRUE(have_map);
	if (!have_map) {
		memdelete(data);
		return;
	}

	// Fill with a deterministic, varied pattern so an identity result is meaningful.
	for (int y = 0; y < region_size; y++) {
		for (int x = 0; x < region_size; x++) {
			real_t h = real_t(x) * 0.5f - real_t(y) * 0.25f + real_t((x * 7 + y * 13) % 17);
			height_map->set_pixel(x, y, Color(h, 0.f, 0.f, 1.f));
		}
	}
	PackedByteArray original = height_map->get_data();

	// Synthesize a Base-only stack whose dense Base layer aliases the region height map, exactly as
	// Pasture3DData::_synthesize_base_layer does on load.
	Ref<Pasture3DLayerStack> stack;
	stack.instantiate();
	Ref<Pasture3DLayer> base;
	base.instantiate();
	base->set_map_type(TYPE_HEIGHT);
	base->set_tile_size(region_size);
	base->set_blend_mode(Pasture3DLayer::REPLACE);
	base->set_region_image(loc, height_map);
	stack->add_layer_ref(base);
	data->set_layer_stack(stack);

	// Acceptance: Base-only composite is byte-identical to the input height map.
	data->composite_region(loc, Rect2i(), false);
	PackedByteArray composited = height_map->get_data();
	EXPECT_TRUE(composited == original);

	// Sanity: an ADD layer raises a covered pixel by its value and leaves an uncovered pixel alone.
	Ref<Pasture3DLayer> detail;
	detail.instantiate();
	detail->set_map_type(TYPE_HEIGHT);
	detail->set_tile_size(region_size);
	detail->set_blend_mode(Pasture3DLayer::ADD);
	const Vector2i covered(10, 10);
	const Vector2i uncovered(20, 20);
	detail->set_sample(loc, covered, 5.f, 1.f);
	stack->add_layer_ref(detail);
	const real_t base_h = height_map->get_pixelv(covered).r;
	const real_t base_u = height_map->get_pixelv(uncovered).r;
	data->composite_region(loc, Rect2i(), false);
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(covered).r, base_h + 5.f));
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(uncovered).r, base_u));

	memdelete(data);
	UtilityFunctions::print("=== End layer compositing tests ===");
}

// Phase 3 acceptance tests (PASTURE3D_LAYERS_GUIDE.md §10 phase 3 / PASTURE3D_LAYERS_PHASE3.md):
//   1. Runtime files unchanged — the saved region image is byte-identical regardless of the stack.
//   2. Stack round-trip — save, clear, load; layer count, metadata, and sampled (value, weight)
//      survive, and the Base layer is re-aliased onto the loaded region image (not a stale copy).
//   3. No-layer-files — a plain (Base-only) terrain writes no pasture3d_layers* files, and load_layers
//      reports nothing to load so the caller synthesizes a single Base layer as before.
// Like test_layer_compositing, this avoids a Pasture3D node by driving save_layers/load_layers and
// region->save directly; it never calls save_directory/load_directory (which require _terrain).
void test_layer_persistence() {
	UtilityFunctions::print("=== Testing layer persistence ===");

	const int region_size = 64;
	const Vector2i loc(0, 0);
	const Vector2i covered(10, 10);
	const Vector2i covered2(40, 33);
	const Vector2i uncovered(20, 20);

	// A clean temp directory under user:// for the round-trip.
	const String dir = "user://p3d_layer_test";
	Ref<DirAccess> da = DirAccess::open("user://");
	if (da.is_valid()) {
		da->make_dir_recursive("p3d_layer_test");
	}
	const String region_path = dir + String("/") + Util::location_to_filename(loc);
	const String manifest_path = dir + String("/") + Util::LAYER_MANIFEST_FILENAME;
	const String slice_path = dir + String("/") + Util::location_to_layer_filename(loc);
	Ref<DirAccess> dda = DirAccess::open(dir);
	if (dda.is_valid()) {
		for (const String &f : Array::make(Util::location_to_filename(loc), String(Util::LAYER_MANIFEST_FILENAME), Util::location_to_layer_filename(loc))) {
			if (dda->file_exists(f)) {
				dda->remove(f);
			}
		}
	}

	// Build a region with a deterministic height pattern and a Base + ADD "Detail" stack.
	Pasture3DData *data = memnew(Pasture3DData);
	Ref<Pasture3DRegion> region;
	region.instantiate();
	region->set_region_size(region_size);
	region->set_location(loc);
	data->add_region(region, false);
	Ref<Image> height_map = region->get_height_map();
	EXPECT_TRUE(height_map.is_valid() && height_map->get_format() == Image::FORMAT_RF);
	if (height_map.is_null()) {
		memdelete(data);
		return;
	}
	for (int y = 0; y < region_size; y++) {
		for (int x = 0; x < region_size; x++) {
			real_t h = real_t(x) * 0.5f - real_t(y) * 0.25f + real_t((x * 7 + y * 13) % 17);
			height_map->set_pixel(x, y, Color(h, 0.f, 0.f, 1.f));
		}
	}
	region->set_modified(true);
	PackedByteArray original = height_map->get_data();

	Ref<Pasture3DLayerStack> stack;
	stack.instantiate();
	Ref<Pasture3DLayer> base;
	base.instantiate();
	base->set_layer_name("Base");
	base->set_map_type(TYPE_HEIGHT);
	base->set_tile_size(region_size);
	base->set_blend_mode(Pasture3DLayer::REPLACE);
	base->set_region_image(loc, height_map);
	stack->add_layer_ref(base);

	Ref<Pasture3DLayer> detail;
	detail.instantiate();
	detail->set_layer_name("Detail");
	detail->set_map_type(TYPE_HEIGHT);
	detail->set_tile_size(region_size);
	detail->set_blend_mode(Pasture3DLayer::ADD);
	detail->set_opacity(0.5f);
	detail->set_sample(loc, covered, 5.f, 0.75f);
	detail->set_sample(loc, covered2, -3.f, 1.f);
	stack->add_layer_ref(detail);
	data->set_layer_stack(stack);

	// Save the runtime region file and the layer stack.
	region->save(region_path, false);
	data->save_layers(dir);
	EXPECT_TRUE(FileAccess::file_exists(manifest_path));
	EXPECT_TRUE(FileAccess::file_exists(slice_path));

	// (1) Runtime data unchanged: save_layers must not touch the region image.
	EXPECT_TRUE(height_map->get_data() == original);

	// Reload region from disk into a fresh data, then load the layer stack on top.
	Pasture3DData *data2 = memnew(Pasture3DData);
	Ref<Pasture3DRegion> region2 = ResourceLoader::get_singleton()->load(region_path, "Pasture3DRegion", ResourceLoader::CACHE_MODE_IGNORE);
	EXPECT_TRUE(region2.is_valid());
	if (region2.is_null()) {
		memdelete(data);
		memdelete(data2);
		return;
	}
	region2->set_location(loc);
	data2->add_region(region2, false);
	Ref<Image> height_map2 = region2->get_height_map();

	// (1 cont.) The loaded runtime image matches the saved one byte-for-byte.
	EXPECT_TRUE(height_map2->get_data() == original);

	const bool loaded = data2->load_layers(dir);
	EXPECT_TRUE(loaded);

	// (2) Stack round-trip: count, metadata, and sampled (value, weight) survive.
	Ref<Pasture3DLayerStack> stack2 = data2->get_layer_stack();
	EXPECT_TRUE(stack2.is_valid());
	EXPECT_TRUE(data2->has_layer_stack());
	EXPECT_TRUE(stack2->get_layer_count() == 2);
	Ref<Pasture3DLayer> detail2 = stack2->get_layer(1);
	EXPECT_TRUE(detail2.is_valid());
	EXPECT_TRUE(detail2->get_layer_name() == String("Detail"));
	EXPECT_TRUE(detail2->get_blend_mode() == Pasture3DLayer::ADD);
	EXPECT_TRUE(Math::is_equal_approx(detail2->get_opacity(), 0.5f));
	EXPECT_TRUE(Math::is_equal_approx(detail2->get_value(loc, covered), 5.f));
	EXPECT_TRUE(Math::is_equal_approx(detail2->get_weight(loc, covered), 0.75f));
	EXPECT_TRUE(Math::is_equal_approx(detail2->get_value(loc, covered2), -3.f));
	EXPECT_TRUE(Math::is_equal_approx(detail2->get_weight(loc, covered2), 1.f));
	// Uncovered pixels round-trip as uncovered: weight 0 (the signal compositing checks). With one
	// region-sized tile the whole region is allocated, so the value is the zero fill, not NaN.
	EXPECT_TRUE(detail2->get_weight(loc, uncovered) == 0.f);
	EXPECT_TRUE(detail2->get_value(loc, uncovered) == 0.f);

	// (2 cont.) The Base layer aliases the loaded region image, so editing the image is visible
	// through the layer — proving it was re-aliased, not restored from a stale copy.
	Ref<Pasture3DLayer> base2 = stack2->get_layer(0);
	EXPECT_TRUE(base2.is_valid());
	height_map2->set_pixel(5, 5, Color(123.f, 0.f, 0.f, 1.f));
	EXPECT_TRUE(Math::is_equal_approx(base2->get_value(loc, Vector2i(5, 5)), 123.f));

	// (3) No-layer-files: a Base-only stack writes nothing and is removed if stale; load reports none.
	const String plain_dir = "user://p3d_layer_test_plain";
	if (da.is_valid()) {
		da->make_dir_recursive("p3d_layer_test_plain");
	}
	Ref<DirAccess> pda = DirAccess::open(plain_dir);
	if (pda.is_valid() && pda->file_exists(Util::LAYER_MANIFEST_FILENAME)) {
		pda->remove(Util::LAYER_MANIFEST_FILENAME);
	}
	Pasture3DData *data3 = memnew(Pasture3DData);
	Ref<Pasture3DRegion> region3;
	region3.instantiate();
	region3->set_region_size(region_size);
	region3->set_location(loc);
	data3->add_region(region3, false);
	Ref<Pasture3DLayerStack> base_only;
	base_only.instantiate();
	Ref<Pasture3DLayer> b3;
	b3.instantiate();
	b3->set_layer_name("Base");
	b3->set_tile_size(region_size);
	b3->set_blend_mode(Pasture3DLayer::REPLACE);
	b3->set_region_image(loc, region3->get_height_map());
	base_only->add_layer_ref(b3);
	data3->set_layer_stack(base_only);
	data3->save_layers(plain_dir);
	EXPECT_FALSE(FileAccess::file_exists(plain_dir + String("/") + Util::LAYER_MANIFEST_FILENAME));
	EXPECT_FALSE(data3->load_layers(plain_dir));

	memdelete(data);
	memdelete(data2);
	memdelete(data3);
	UtilityFunctions::print("=== End layer persistence tests ===");
}

// Phase 4 regression guard (PASTURE3D_LAYERS_GUIDE.md §5.1, fact 1): with the Base un-aliased, N
// repeated composites of a stack containing an ADD layer must be idempotent — the delta applies
// exactly once, never drifting. Before the un-alias fix this would read an already-composited Base
// and re-accumulate every pass. Also checks is_layer_routing flips off->on across the un-alias.
void test_layer_idempotent_composite() {
	UtilityFunctions::print("=== Testing idempotent composite (un-alias regression guard) ===");

	const int region_size = 64;
	const Vector2i loc(0, 0);
	const Vector2i covered(10, 10);

	Pasture3DData *data = memnew(Pasture3DData);
	Ref<Pasture3DRegion> region;
	region.instantiate();
	region->set_region_size(region_size);
	region->set_location(loc);
	data->add_region(region, false);
	Ref<Image> height_map = region->get_height_map();
	EXPECT_TRUE(height_map.is_valid() && height_map->get_format() == Image::FORMAT_RF);
	if (height_map.is_null()) {
		memdelete(data);
		return;
	}
	for (int y = 0; y < region_size; y++) {
		for (int x = 0; x < region_size; x++) {
			real_t h = real_t(x) * 0.5f - real_t(y) * 0.25f + real_t((x * 7 + y * 13) % 17);
			height_map->set_pixel(x, y, Color(h, 0.f, 0.f, 1.f));
		}
	}

	// Base aliased onto the region image, exactly as _synthesize_base_layer / load do.
	Ref<Pasture3DLayerStack> stack;
	stack.instantiate();
	Ref<Pasture3DLayer> base;
	base.instantiate();
	base->set_layer_name("Base");
	base->set_map_type(TYPE_HEIGHT);
	base->set_tile_size(region_size);
	base->set_blend_mode(Pasture3DLayer::REPLACE);
	base->set_region_image(loc, height_map);
	stack->add_layer_ref(base);
	data->set_layer_stack(stack);

	// Aliased Base => routing off (plain-terrain behaviour unchanged).
	EXPECT_FALSE(data->is_layer_routing());

	// Adding the first non-Base layer must un-alias the Base and enable routing.
	int didx = data->layer_add("Detail", Pasture3DLayer::ADD);
	EXPECT_TRUE(didx == 1);
	EXPECT_TRUE(data->is_layer_routing());

	const real_t base_h = height_map->get_pixelv(covered).r; // Region unchanged by un-alias.
	Ref<Pasture3DLayer> detail = data->get_layer_stack()->get_layer(1);
	detail->set_sample(loc, covered, 5.f, 1.f);

	// Composite repeatedly: the ADD delta must land exactly once.
	for (int i = 0; i < 5; i++) {
		data->composite_region(loc, Rect2i(), false);
	}
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(covered).r, base_h + 5.f));

	memdelete(data);
	UtilityFunctions::print("=== End idempotent composite tests ===");
}

// Phase 4: the undo/redo tile-snapshot primitives (duplicate_region_tiles / restore_region_tiles)
// must deep-copy, so restoring a pre-stroke snapshot fully reverts the layer source (including back
// to "uncovered" when the region had no tile), and a snapshot is immune to later edits.
void test_layer_undo_restore() {
	UtilityFunctions::print("=== Testing layer undo tile restore ===");

	const int region_size = 64;
	const Vector2i loc(0, 0);
	const Vector2i px(12, 9);

	Ref<Pasture3DLayer> layer;
	layer.instantiate();
	layer->set_map_type(TYPE_HEIGHT);
	layer->set_tile_size(region_size);
	layer->set_blend_mode(Pasture3DLayer::ADD);

	// Pre-stroke snapshot of an untouched region is empty (no tile yet).
	Dictionary pre = layer->duplicate_region_tiles(loc);
	EXPECT_TRUE(pre.is_empty());

	// Stroke writes a sample; the snapshot taken earlier must NOT see it (deep copy).
	layer->set_sample(loc, px, 9.f, 1.f);
	EXPECT_TRUE(Math::is_equal_approx(layer->get_value(loc, px), 9.f));
	EXPECT_TRUE(Math::is_equal_approx(layer->get_weight(loc, px), 1.f));
	EXPECT_TRUE(pre.is_empty());

	// Capture post-stroke (for redo), then undo by restoring the empty pre-snapshot.
	Dictionary post = layer->duplicate_region_tiles(loc);
	EXPECT_FALSE(post.is_empty());
	layer->restore_region_tiles(loc, pre);
	EXPECT_FALSE(layer->has_region(loc)); // Region erased => back to uncovered.
	EXPECT_TRUE(layer->get_weight(loc, px) == 0.f);

	// Redo by restoring the post-snapshot; the sample comes back.
	layer->restore_region_tiles(loc, post);
	EXPECT_TRUE(Math::is_equal_approx(layer->get_value(loc, px), 9.f));
	EXPECT_TRUE(Math::is_equal_approx(layer->get_weight(loc, px), 1.f));

	UtilityFunctions::print("=== End layer undo tile restore tests ===");
}

// Bugfix regression guard: the editor builds an undo/redo payload from per-region tile snapshots in
// _store_undo, then stop_operation() clears its live snapshot members. The payload MUST own its tile
// data (Pasture3DLayer::clone_tile_snapshot) so the clear can't empty it — otherwise undo restores the
// composite but not the layer source ("undo clears the layer"). This drives the full snapshot ->
// clone-into-payload -> clear-sources -> restore -> recomposite path that test_layer_undo_restore (a
// pure-primitive test) never exercised, across two sub-tiles and two regions, and confirms a co-located
// earlier stroke survives undo of a later one.
void test_layer_stroke_undo_integration() {
	UtilityFunctions::print("=== Testing per-stroke undo integration ===");

	const int region_size = 128; // > overlay tile_size (64) so a region holds a 2x2 grid of sub-tiles
	const real_t base_h = 3.f;
	const Vector2i loc0(0, 0);
	const Vector2i loc1(1, 0);
	const Vector2i px_a(10, 10); // region (0,0) sub-tile (0,0): an earlier stroke that must survive
	const Vector2i px_b1(70, 70); // region (0,0) sub-tile (1,1): the tested stroke, a 2nd sub-tile
	const Vector2i px_b2(20, 20); // region (1,0): the tested stroke spans a 2nd region

	Pasture3DData *data = memnew(Pasture3DData);
	Ref<Pasture3DLayerStack> stack;
	stack.instantiate();
	Ref<Pasture3DLayer> base;
	base.instantiate();
	base->set_layer_name("Base");
	base->set_map_type(TYPE_HEIGHT);
	base->set_tile_size(region_size);
	base->set_blend_mode(Pasture3DLayer::REPLACE);
	for (const Vector2i &loc : Array::make(loc0, loc1)) {
		Ref<Pasture3DRegion> region;
		region.instantiate();
		region->set_region_size(region_size);
		region->set_location(loc);
		data->add_region(region, false);
		Ref<Image> hm = region->get_height_map();
		if (hm.is_null()) {
			memdelete(data);
			return;
		}
		hm->fill(Color(base_h, 0.f, 0.f, 1.f));
		base->set_region_image(loc, hm); // Base aliases the region height maps (un-aliased by layer_add)
	}
	stack->add_layer_ref(base);
	data->set_layer_stack(stack);

	// Add a REPLACE overlay and make it active; this un-aliases the Base across both regions so a
	// recomposite always derives from the Base buffer, not a stale region map.
	int oidx = data->layer_add("Overlay", Pasture3DLayer::REPLACE);
	EXPECT_TRUE(oidx == 1 && data->is_layer_routing());
	Ref<Pasture3DLayer> overlay = data->get_layer_stack()->get_layer(oidx);

	Ref<Image> hm0 = data->get_region(loc0)->get_height_map();
	Ref<Image> hm1 = data->get_region(loc1)->get_height_map();

	// Earlier stroke A (region 0, sub-tile (0,0)).
	overlay->set_sample(loc0, px_a, 11.f, 1.f);
	data->composite_region(loc0, Rect2i(), false);
	EXPECT_TRUE(Math::is_equal_approx(hm0->get_pixelv(px_a).r, 11.f));

	// --- Tested stroke B: pre-snapshot the touched regions (as _backup_layer_tile does on first touch). ---
	Dictionary undo_tiles; // region_loc -> {tile_coord -> Image}, the editor's _layer_undo_tiles
	undo_tiles[loc0] = overlay->duplicate_region_tiles(loc0); // non-empty: already holds stroke A
	undo_tiles[loc1] = overlay->duplicate_region_tiles(loc1); // empty: region had no tile before B
	EXPECT_FALSE(Dictionary(undo_tiles[loc0]).is_empty());
	EXPECT_TRUE(Dictionary(undo_tiles[loc1]).is_empty());

	// Apply stroke B across a 2nd sub-tile of region 0 and into region 1, then recomposite.
	overlay->set_sample(loc0, px_b1, 22.f, 1.f);
	overlay->set_sample(loc1, px_b2, 33.f, 1.f);
	data->composite_region(loc0, Rect2i(), false);
	data->composite_region(loc1, Rect2i(), false);
	EXPECT_TRUE(Math::is_equal_approx(hm0->get_pixelv(px_b1).r, 22.f));
	EXPECT_TRUE(Math::is_equal_approx(hm0->get_pixelv(px_a).r, 11.f)); // stroke A still present
	EXPECT_TRUE(Math::is_equal_approx(hm1->get_pixelv(px_b2).r, 33.f));

	// Post-snapshot for redo (as stop_operation does), then build the committed payloads via the
	// production clone helper.
	Dictionary redo_tiles;
	redo_tiles[loc0] = overlay->duplicate_region_tiles(loc0);
	redo_tiles[loc1] = overlay->duplicate_region_tiles(loc1);
	Dictionary undo_payload = Pasture3DLayer::clone_tile_snapshot(undo_tiles);
	Dictionary redo_payload = Pasture3DLayer::clone_tile_snapshot(redo_tiles);

	// Emulate the hazard: stop_operation() clears the live snapshot members right after committing.
	undo_tiles.clear();
	redo_tiles.clear();

	// REGRESSION GUARD: the committed payloads must be unaffected by the clear above. Before the fix
	// (payload aliased the members) these would be empty here.
	EXPECT_TRUE(undo_payload.size() == 2); // both region keys survive
	EXPECT_TRUE(redo_payload.size() == 2);
	EXPECT_FALSE(Dictionary(redo_payload[loc1]).is_empty()); // region 1's painted tile survived
	EXPECT_FALSE(Dictionary(undo_payload[loc0]).is_empty()); // region 0's pre-stroke (stroke A) tile survived

	// --- Undo stroke B: restore the layer source from the undo payload, then recomposite. ---
	Array ulocs = undo_payload.keys();
	for (const Vector2i &loc : ulocs) {
		overlay->restore_region_tiles(loc, undo_payload[loc]);
	}
	data->composite_region(loc0, Rect2i(), false);
	data->composite_region(loc1, Rect2i(), false);
	// Stroke B reverted (back to base); stroke A preserved; region 1's tile erased (was empty pre-B).
	EXPECT_TRUE(Math::is_equal_approx(hm0->get_pixelv(px_b1).r, base_h));
	EXPECT_TRUE(Math::is_equal_approx(hm0->get_pixelv(px_a).r, 11.f));
	EXPECT_TRUE(Math::is_equal_approx(hm1->get_pixelv(px_b2).r, base_h));
	EXPECT_TRUE(overlay->get_weight(loc0, px_b1) == 0.f);
	EXPECT_FALSE(overlay->has_region(loc1));
	EXPECT_TRUE(Math::is_equal_approx(overlay->get_value(loc0, px_a), 11.f)); // source kept stroke A

	// --- Redo stroke B: restore from the redo payload, recomposite, expect the full stroke back. ---
	Array rlocs = redo_payload.keys();
	for (const Vector2i &loc : rlocs) {
		overlay->restore_region_tiles(loc, redo_payload[loc]);
	}
	data->composite_region(loc0, Rect2i(), false);
	data->composite_region(loc1, Rect2i(), false);
	EXPECT_TRUE(Math::is_equal_approx(hm0->get_pixelv(px_b1).r, 22.f));
	EXPECT_TRUE(Math::is_equal_approx(hm0->get_pixelv(px_a).r, 11.f));
	EXPECT_TRUE(Math::is_equal_approx(hm1->get_pixelv(px_b2).r, 33.f));

	memdelete(data);
	UtilityFunctions::print("=== End per-stroke undo integration tests ===");
}

// Phase 4: once the Base is un-aliased it holds true base heights that the flattened region map no
// longer carries, so save_layers must persist them. On load the Base loads its own buffer (routing
// stays on) and a fresh composite reproduces the flattened runtime image byte-for-byte.
void test_layer_base_persistence() {
	UtilityFunctions::print("=== Testing un-aliased Base persistence ===");

	const int region_size = 64;
	const Vector2i loc(0, 0);
	const Vector2i covered(10, 10);
	const Vector2i base_px(3, 3);

	const String dir = "user://p3d_layer_phase4";
	Ref<DirAccess> da = DirAccess::open("user://");
	if (da.is_valid()) {
		da->make_dir_recursive("p3d_layer_phase4");
	}
	const String region_path = dir + String("/") + Util::location_to_filename(loc);
	Ref<DirAccess> dda = DirAccess::open(dir);
	if (dda.is_valid()) {
		for (const String &f : Array::make(Util::location_to_filename(loc), String(Util::LAYER_MANIFEST_FILENAME), Util::location_to_layer_filename(loc))) {
			if (dda->file_exists(f)) {
				dda->remove(f);
			}
		}
	}

	Pasture3DData *data = memnew(Pasture3DData);
	Ref<Pasture3DRegion> region;
	region.instantiate();
	region->set_region_size(region_size);
	region->set_location(loc);
	data->add_region(region, false);
	Ref<Image> height_map = region->get_height_map();
	if (height_map.is_null()) {
		memdelete(data);
		return;
	}
	for (int y = 0; y < region_size; y++) {
		for (int x = 0; x < region_size; x++) {
			real_t h = real_t(x) * 0.5f - real_t(y) * 0.25f + real_t((x * 7 + y * 13) % 17);
			height_map->set_pixel(x, y, Color(h, 0.f, 0.f, 1.f));
		}
	}

	Ref<Pasture3DLayerStack> stack;
	stack.instantiate();
	Ref<Pasture3DLayer> base;
	base.instantiate();
	base->set_layer_name("Base");
	base->set_map_type(TYPE_HEIGHT);
	base->set_tile_size(region_size);
	base->set_blend_mode(Pasture3DLayer::REPLACE);
	base->set_region_image(loc, height_map);
	stack->add_layer_ref(base);
	data->set_layer_stack(stack);

	// Add a detail layer (un-aliases the Base), then author distinct values into BOTH the base and
	// the detail so the base buffer and the flattened region map genuinely differ.
	int didx = data->layer_add("Detail", Pasture3DLayer::ADD);
	EXPECT_TRUE(didx == 1 && data->is_layer_routing());
	Ref<Pasture3DLayer> base_u = data->get_layer_stack()->get_layer(0);
	Ref<Pasture3DLayer> detail = data->get_layer_stack()->get_layer(1);
	base_u->set_sample(loc, base_px, 99.f, 1.f);
	detail->set_sample(loc, covered, 5.f, 1.f);
	const real_t orig_covered = height_map->get_pixelv(covered).r;
	data->composite_region(loc, Rect2i(), false);
	PackedByteArray flattened = height_map->get_data();
	// Sanity: the flatten reflects both edits.
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(base_px).r, 99.f));
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(covered).r, orig_covered + 5.f));

	region->save(region_path, false);
	data->save_layers(dir);

	// Reload into a fresh data and load the stack on top.
	Pasture3DData *data2 = memnew(Pasture3DData);
	Ref<Pasture3DRegion> region2 = ResourceLoader::get_singleton()->load(region_path, "Pasture3DRegion", ResourceLoader::CACHE_MODE_IGNORE);
	EXPECT_TRUE(region2.is_valid());
	if (region2.is_null()) {
		memdelete(data);
		memdelete(data2);
		return;
	}
	region2->set_location(loc);
	data2->add_region(region2, false);
	Ref<Image> height_map2 = region2->get_height_map();
	EXPECT_TRUE(height_map2->get_data() == flattened); // Runtime image round-trips unchanged.

	EXPECT_TRUE(data2->load_layers(dir));
	// Base loaded its own heights => still un-aliased => routing stays on.
	EXPECT_TRUE(data2->is_layer_routing());
	Ref<Pasture3DLayer> base2 = data2->get_layer_stack()->get_layer(0);
	EXPECT_TRUE(Math::is_equal_approx(base2->get_value(loc, base_px), 99.f));
	// The base buffer is NOT the flattened map: at `covered` it holds the original height, not +5.
	EXPECT_TRUE(Math::is_equal_approx(base2->get_value(loc, covered), orig_covered));

	// A fresh composite after load reproduces the flattened runtime image exactly (no drift).
	data2->composite_region(loc, Rect2i(), false);
	EXPECT_TRUE(height_map2->get_data() == flattened);

	memdelete(data);
	memdelete(data2);
	UtilityFunctions::print("=== End un-aliased Base persistence tests ===");
}

// Phase 5 acceptance tests (PASTURE3D_LAYERS_GUIDE.md §8): the tool API a generator node (the
// RoadPastureConnector) uses to draw non-destructively into its own reserved layer.
//   1. create_owned_layer is idempotent by owner_id — the same owner re-uses its layer, never piling
//      up duplicates; the layer is reserved and routing turns on (Base un-aliased).
//   2. set_height_on_layer + dirty-scoped composite places the road on top (REPLACE, weight 1) and
//      feathers a shoulder (weight 0.5); clearing the layer's area drops the old pose, and an
//      identical repaint reproduces the same composite (re-running roads is idempotent).
//   3. A hand-sculpt authored on the Base UNDER the road survives a clear + road re-run (the connector
//      only ever touches its own layer).
//   4. Backward-compat: with no stack / an invalid layer id, set_height_on_layer falls back to a direct
//      Base write so plain terrains keep working.
// Like the other layer tests this is standalone (no Pasture3D node); it sets the descale fields via the
// friend declaration in pasture_3d_data.h since the tool API maps global positions to region pixels.
void test_layer_road_connector() {
	UtilityFunctions::print("=== Testing tool API + road connector layer ===");

	const int region_size = 64;
	const Vector2i loc(0, 0);
	const Vector2i road_px(10, 10);
	const Vector2i feather_px(12, 10);
	const Vector2i sculpt_px(40, 40);
	const Vector3 road_pos(10, 0, 10);
	const Vector3 feather_pos(12, 0, 10);
	const Vector3 sculpt_pos(40, 0, 40);

	Pasture3DData *data = memnew(Pasture3DData);
	// Configure the global->region descale math the tool API relies on (normally set by a Pasture3D node).
	data->_region_size = region_size;
	data->_region_sizev = V2I(region_size);
	data->_vertex_spacing = 1.f;

	Ref<Pasture3DRegion> region;
	region.instantiate();
	region->set_region_size(region_size);
	region->set_location(loc);
	data->add_region(region, false);
	Ref<Image> height_map = region->get_height_map();
	EXPECT_TRUE(height_map.is_valid() && height_map->get_format() == Image::FORMAT_RF);
	if (height_map.is_null()) {
		memdelete(data);
		return;
	}
	for (int y = 0; y < region_size; y++) {
		for (int x = 0; x < region_size; x++) {
			real_t h = real_t(x) * 0.5f - real_t(y) * 0.25f + real_t((x * 7 + y * 13) % 17);
			height_map->set_pixel(x, y, Color(h, 0.f, 0.f, 1.f));
		}
	}

	// Base-only stack aliasing the region map, exactly as load / _synthesize_base_layer do.
	Ref<Pasture3DLayerStack> stack;
	stack.instantiate();
	Ref<Pasture3DLayer> base;
	base.instantiate();
	base->set_layer_name("Base");
	base->set_map_type(TYPE_HEIGHT);
	base->set_tile_size(region_size);
	base->set_blend_mode(Pasture3DLayer::REPLACE);
	base->set_region_image(loc, height_map);
	stack->add_layer_ref(base);
	data->set_layer_stack(stack);

	// (1) create_owned_layer is idempotent by owner_id.
	const String owner = "/root/RoadConnector#42";
	int lyr = data->create_owned_layer(owner, "Roads", Pasture3DLayer::REPLACE);
	EXPECT_TRUE(lyr == 1);
	int lyr_again = data->create_owned_layer(owner, "Roads", Pasture3DLayer::REPLACE);
	EXPECT_TRUE(lyr_again == lyr); // Same layer reused, not a duplicate.
	EXPECT_TRUE(data->get_layer_stack_size() == 2); // Base + Roads only.
	EXPECT_TRUE(data->find_layer_by_owner(owner) == lyr);
	Ref<Pasture3DLayer> roads = data->get_layer_stack()->get_layer(lyr);
	EXPECT_TRUE(roads.is_valid() && roads->is_reserved());
	EXPECT_TRUE(roads->get_blend_mode() == Pasture3DLayer::REPLACE);
	EXPECT_TRUE(data->is_layer_routing()); // First non-Base layer un-aliased the Base.

	// (3 setup) Hand-sculpt the Base under where the road network sits (simulates editor routing into
	// the Base/active layer). Routes onto layer 0 via the same tool-API write.
	Ref<Pasture3DLayer> base_u = data->get_layer_stack()->get_layer(0);
	data->set_height_on_layer(0, sculpt_pos, 50.f, 1.f);
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(sculpt_px).r, 50.f));
	EXPECT_TRUE(Math::is_equal_approx(base_u->get_value(loc, sculpt_px), 50.f));

	// (2) Paint the road into the reserved layer. Capture the underlying terrain first so we can prove
	// the clear restores it and the feather blends against it.
	const real_t below_road = height_map->get_pixelv(road_px).r;
	const real_t below_feather = height_map->get_pixelv(feather_px).r;
	data->set_height_on_layer(lyr, road_pos, 99.f, 1.f); // On the road: full coverage => sits on top.
	data->set_height_on_layer(lyr, feather_pos, 99.f, 0.5f); // Shoulder: half coverage => lerp.
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(road_px).r, 99.f));
	const real_t expect_feather = below_feather + (99.f - below_feather) * 0.5f;
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(feather_px).r, expect_feather));
	EXPECT_TRUE(Math::is_equal_approx(data->get_layer_height(lyr, road_pos), 99.f));

	// (2 cont.) Clear the road layer's footprint: the old pose drops back to what is underneath.
	AABB area(Vector3(0, 0, 0), Vector3(region_size, 1, region_size)); // Covers region (0,0).
	data->clear_layer_in_area(lyr, area);
	EXPECT_FALSE(roads->has_region(loc)); // Road layer tiles erased in this region.
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(road_px).r, below_road)); // Road gone.
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(feather_px).r, below_feather));
	// (3) The Base hand-sculpt survived the road clear (it lives on the Base layer, untouched).
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(sculpt_px).r, 50.f));
	EXPECT_TRUE(Math::is_equal_approx(base_u->get_value(loc, sculpt_px), 50.f));

	// (2 cont.) Repaint identically — re-running the road is idempotent.
	data->set_height_on_layer(lyr, road_pos, 99.f, 1.f);
	data->set_height_on_layer(lyr, feather_pos, 99.f, 0.5f);
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(road_px).r, 99.f));
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(feather_px).r, expect_feather));
	// (3) Base sculpt still intact after the full clear+repaint cycle.
	EXPECT_TRUE(Math::is_equal_approx(height_map->get_pixelv(sculpt_px).r, 50.f));

	// (4) Backward-compat: no stack / invalid layer id => set_height_on_layer writes the Base directly.
	Pasture3DData *plain = memnew(Pasture3DData);
	plain->_region_size = region_size;
	plain->_region_sizev = V2I(region_size);
	plain->_vertex_spacing = 1.f;
	Ref<Pasture3DRegion> preg;
	preg.instantiate();
	preg->set_region_size(region_size);
	preg->set_location(loc);
	plain->add_region(preg, false);
	plain->set_height_on_layer(5, Vector3(7, 0, 7), 33.f, 1.f); // No stack => fall back to set_height.
	EXPECT_TRUE(Math::is_equal_approx(preg->get_height_map()->get_pixelv(Vector2i(7, 7)).r, 33.f));
	memdelete(plain);

	memdelete(data);
	UtilityFunctions::print("=== End tool API + road connector tests ===");
}

// Phase 6 acceptance tests (PASTURE3D_LAYERS_GUIDE.md §10.6): sub-region tiling.
//   (a) Sparse allocation — a thin diagonal band on a 256² region with tile_size 64 allocates only the
//       sub-tiles it crosses (the 4 diagonal tiles), not all 16.
//   (b) Tile GC — gc_region frees fully-uncovered tiles and drops the region entry when its last tile
//       goes, while keeping a still-covered tile.
//   (c) Sub-tile-precise clear — clearing an AABB over one sub-tile leaves an adjacent sub-tile's
//       samples intact (the Phase 5 partial-refresh regression guard).
//   (d) Composite byte-parity — the same data composited at tile_size 64 vs region_size yields a
//       byte-identical region height map (sub-tiling changed storage, not output).
//   (e) NaN vs weight — a whole absent tile reads NaN; an allocated-but-uncovered pixel reads weight 0
//       with a non-NaN value (§4.3).
//   (f) Round-trip — save/load a multi-sub-tile layer; tile count, (value, weight), and a post-load
//       composite all survive.
void test_layer_subtiling() {
	UtilityFunctions::print("=== Testing sub-region tiling (phase 6) ===");

	const int region_size = 256;
	const int tile_size = 64; // 4x4 = 16 sub-tiles per region.
	const Vector2i loc(0, 0);

	auto fill = [](const Ref<Image> &hm, int rs) {
		for (int y = 0; y < rs; y++) {
			for (int x = 0; x < rs; x++) {
				real_t h = real_t(x) * 0.5f - real_t(y) * 0.25f + real_t((x * 7 + y * 13) % 17);
				hm->set_pixel(x, y, Color(h, 0.f, 0.f, 1.f));
			}
		}
	};

	// ---- (a) Sparse allocation: a diagonal band crosses only the 4 diagonal sub-tiles. ----
	{
		Ref<Pasture3DLayer> road;
		road.instantiate();
		road->set_map_type(TYPE_HEIGHT);
		road->set_tile_size(tile_size);
		road->set_blend_mode(Pasture3DLayer::REPLACE);
		for (int t = 0; t < region_size; t++) {
			road->set_sample(loc, Vector2i(t, t), 10.f, 1.f); // y == x => tiles (0,0)(1,1)(2,2)(3,3)
		}
		EXPECT_TRUE(road->get_region_tile_count(loc) == 4);
		EXPECT_FALSE(road->get_region_tile_count(loc) == 16); // Not the whole region.
	}

	// ---- (b) Tile GC: free fully-uncovered tiles; drop the region entry when the last tile goes. ----
	{
		Ref<Pasture3DLayer> lyr;
		lyr.instantiate();
		lyr->set_tile_size(tile_size);
		lyr->set_blend_mode(Pasture3DLayer::REPLACE);
		const Vector2i a(10, 10); // tile (0,0)
		const Vector2i b(70, 70); // tile (1,1)
		lyr->set_sample(loc, a, 5.f, 1.f);
		lyr->set_sample(loc, b, 6.f, 1.f);
		EXPECT_TRUE(lyr->get_region_tile_count(loc) == 2);
		// Wipe coverage of tile (0,0) only; gc frees it and keeps tile (1,1).
		lyr->set_sample(loc, a, 0.f, 0.f);
		EXPECT_FALSE(lyr->gc_region(loc)); // Region still holds tile (1,1).
		EXPECT_TRUE(lyr->get_region_tile_count(loc) == 1);
		EXPECT_TRUE(lyr->has_region(loc));
		EXPECT_TRUE(Math::is_equal_approx(lyr->get_weight(loc, b), 1.f)); // Survivor intact.
		// Wipe the last tile; gc drops the whole region entry.
		lyr->set_sample(loc, b, 0.f, 0.f);
		EXPECT_TRUE(lyr->gc_region(loc));
		EXPECT_FALSE(lyr->has_region(loc));
	}

	// ---- (c) Sub-tile-precise clear: an adjacent sub-tile's road survives (partial-refresh fix). ----
	{
		Pasture3DData *data = memnew(Pasture3DData);
		data->_region_size = region_size;
		data->_region_sizev = V2I(region_size);
		data->_vertex_spacing = 1.f;
		Ref<Pasture3DRegion> region;
		region.instantiate();
		region->set_region_size(region_size);
		region->set_location(loc);
		data->add_region(region, false);
		Ref<Image> hm = region->get_height_map();
		fill(hm, region_size);

		Ref<Pasture3DLayerStack> stack;
		stack.instantiate();
		Ref<Pasture3DLayer> base;
		base.instantiate();
		base->set_tile_size(region_size);
		base->set_blend_mode(Pasture3DLayer::REPLACE);
		base->set_region_image(loc, hm);
		stack->add_layer_ref(base);
		data->set_layer_stack(stack);

		// Two roads in adjacent sub-tiles of the SAME region: A in tile (0,0), B in tile (1,0).
		int lyr = data->create_owned_layer("/root/RoadA", "Roads", Pasture3DLayer::REPLACE);
		EXPECT_TRUE(lyr == 1);
		const Vector3 a_pos(30, 0, 30); // tile (0,0)
		const Vector3 b_pos(80, 0, 30); // tile (1,0)
		const Vector2i a_px(30, 30), b_px(80, 30);
		data->set_height_on_layer(lyr, a_pos, 99.f, 1.f);
		data->set_height_on_layer(lyr, b_pos, 88.f, 1.f);
		Ref<Pasture3DLayer> roads = data->get_layer_stack()->get_layer(lyr);
		EXPECT_TRUE(roads->get_region_tile_count(loc) == 2);
		EXPECT_TRUE(Math::is_equal_approx(hm->get_pixelv(a_px).r, 99.f));
		EXPECT_TRUE(Math::is_equal_approx(hm->get_pixelv(b_px).r, 88.f));

		// Clear an AABB covering ONLY tile (0,0) (road A's footprint): px [20,38) intersects tile (0,0).
		AABB area(Vector3(20, 0, 20), Vector3(18, 1, 18));
		data->clear_layer_in_area(lyr, area);
		EXPECT_TRUE(roads->get_region_tile_count(loc) == 1); // Only road A's tile dropped.
		EXPECT_TRUE(roads->get_weight(loc, b_px) > 0.f); // Road B's sample survives.
		EXPECT_TRUE(Math::is_equal_approx(hm->get_pixelv(b_px).r, 88.f)); // Road B still composited.
		EXPECT_TRUE(roads->get_weight(loc, a_px) == 0.f); // Road A gone => its tile freed.
		EXPECT_FALSE(Math::is_equal_approx(hm->get_pixelv(a_px).r, 99.f)); // Fell back to base.

		memdelete(data);
	}

	// ---- (d) Composite byte-parity: tile_size 64 vs region_size yields identical output. ----
	{
		auto composite_bytes = [&](int ts) -> PackedByteArray {
			Pasture3DData *d = memnew(Pasture3DData);
			d->_region_size = region_size;
			d->_region_sizev = V2I(region_size);
			d->_vertex_spacing = 1.f;
			Ref<Pasture3DRegion> r;
			r.instantiate();
			r->set_region_size(region_size);
			r->set_location(loc);
			d->add_region(r, false);
			Ref<Image> hm = r->get_height_map();
			fill(hm, region_size);
			Ref<Pasture3DLayerStack> s;
			s.instantiate();
			Ref<Pasture3DLayer> b;
			b.instantiate();
			b->set_tile_size(region_size);
			b->set_blend_mode(Pasture3DLayer::REPLACE);
			b->set_region_image(loc, hm);
			s->add_layer_ref(b);
			Ref<Pasture3DLayer> det;
			det.instantiate();
			det->set_tile_size(ts);
			det->set_blend_mode(Pasture3DLayer::ADD);
			det->set_opacity(0.5f);
			det->set_sample(loc, Vector2i(10, 10), 5.f, 1.f); // scattered across multiple sub-tiles
			det->set_sample(loc, Vector2i(200, 40), -3.f, 0.75f);
			det->set_sample(loc, Vector2i(70, 150), 7.f, 1.f);
			s->add_layer_ref(det);
			d->set_layer_stack(s);
			d->composite_region(loc, Rect2i(), false);
			PackedByteArray out = hm->get_data();
			memdelete(d);
			return out;
		};
		PackedByteArray sub = composite_bytes(tile_size);
		PackedByteArray whole = composite_bytes(region_size);
		EXPECT_TRUE(sub == whole);
	}

	// ---- (e) NaN vs weight at sub-tile granularity (§4.3). ----
	{
		Ref<Pasture3DLayer> lyr;
		lyr.instantiate();
		lyr->set_tile_size(tile_size);
		lyr->set_blend_mode(Pasture3DLayer::REPLACE);
		lyr->set_sample(loc, Vector2i(10, 10), 5.f, 1.f); // Allocates tile (0,0) only.
		// Within the allocated tile, an unwritten pixel is uncovered (weight 0) but has a real value.
		EXPECT_TRUE(lyr->get_weight(loc, Vector2i(20, 20)) == 0.f);
		EXPECT_FALSE(std::isnan(lyr->get_value(loc, Vector2i(20, 20))));
		// A pixel in a whole absent tile reads NaN (and weight 0).
		EXPECT_TRUE(std::isnan(lyr->get_value(loc, Vector2i(200, 200))));
		EXPECT_TRUE(lyr->get_weight(loc, Vector2i(200, 200)) == 0.f);
	}

	// ---- (f) Round-trip a multi-sub-tile layer. ----
	{
		const String dir = "user://p3d_layer_phase6";
		Ref<DirAccess> da = DirAccess::open("user://");
		if (da.is_valid()) {
			da->make_dir_recursive("p3d_layer_phase6");
		}
		const String region_path = dir + String("/") + Util::location_to_filename(loc);
		Ref<DirAccess> dda = DirAccess::open(dir);
		if (dda.is_valid()) {
			for (const String &f : Array::make(Util::location_to_filename(loc), String(Util::LAYER_MANIFEST_FILENAME), Util::location_to_layer_filename(loc))) {
				if (dda->file_exists(f)) {
					dda->remove(f);
				}
			}
		}
		Pasture3DData *data = memnew(Pasture3DData);
		data->_region_size = region_size;
		data->_region_sizev = V2I(region_size);
		data->_vertex_spacing = 1.f;
		Ref<Pasture3DRegion> region;
		region.instantiate();
		region->set_region_size(region_size);
		region->set_location(loc);
		data->add_region(region, false);
		Ref<Image> hm = region->get_height_map();
		fill(hm, region_size);
		region->set_modified(true);

		Ref<Pasture3DLayerStack> stack;
		stack.instantiate();
		Ref<Pasture3DLayer> base;
		base.instantiate();
		base->set_layer_name("Base");
		base->set_tile_size(region_size);
		base->set_blend_mode(Pasture3DLayer::REPLACE);
		base->set_region_image(loc, hm);
		stack->add_layer_ref(base);
		Ref<Pasture3DLayer> det;
		det.instantiate();
		det->set_layer_name("Detail");
		det->set_tile_size(tile_size);
		det->set_blend_mode(Pasture3DLayer::ADD);
		const Vector2i s0(10, 10), s1(200, 40), s2(70, 150); // three distinct sub-tiles
		det->set_sample(loc, s0, 5.f, 1.f);
		det->set_sample(loc, s1, -3.f, 0.75f);
		det->set_sample(loc, s2, 7.f, 1.f);
		stack->add_layer_ref(det);
		data->set_layer_stack(stack);
		EXPECT_TRUE(det->get_region_tile_count(loc) == 3);

		region->save(region_path, false);
		data->save_layers(dir);

		Pasture3DData *data2 = memnew(Pasture3DData);
		data2->_region_size = region_size;
		data2->_region_sizev = V2I(region_size);
		data2->_vertex_spacing = 1.f;
		Ref<Pasture3DRegion> region2 = ResourceLoader::get_singleton()->load(region_path, "Pasture3DRegion", ResourceLoader::CACHE_MODE_IGNORE);
		EXPECT_TRUE(region2.is_valid());
		if (region2.is_null()) {
			memdelete(data);
			memdelete(data2);
			return;
		}
		region2->set_location(loc);
		data2->add_region(region2, false);
		EXPECT_TRUE(data2->load_layers(dir));

		Ref<Pasture3DLayerStack> stack2 = data2->get_layer_stack();
		EXPECT_TRUE(stack2.is_valid() && stack2->get_layer_count() == 2);
		Ref<Pasture3DLayer> det2 = stack2->get_layer(1);
		EXPECT_TRUE(det2.is_valid());
		// Sub-tile structure round-trips: still 3 separate tiles, not collapsed into one.
		EXPECT_TRUE(det2->get_region_tile_count(loc) == 3);
		EXPECT_TRUE(Math::is_equal_approx(det2->get_value(loc, s0), 5.f));
		EXPECT_TRUE(Math::is_equal_approx(det2->get_weight(loc, s1), 0.75f));
		EXPECT_TRUE(Math::is_equal_approx(det2->get_value(loc, s2), 7.f));

		// A post-load composite reproduces the live one byte-for-byte.
		data->composite_region(loc, Rect2i(), false);
		PackedByteArray ref_bytes = hm->get_data();
		Ref<Image> hm2 = region2->get_height_map();
		data2->composite_region(loc, Rect2i(), false);
		EXPECT_TRUE(hm2->get_data() == ref_bytes);

		memdelete(data);
		memdelete(data2);
	}

	UtilityFunctions::print("=== End sub-region tiling tests ===");
}

// Phase 7 acceptance tests (PASTURE3D_LAYERS_GUIDE.md §10.7): control & color layers.
//   (a) Control composite is topmost-covered-wins — an upper covered control overlay overrides a lower
//       one; a pixel no overlay covers falls through to the hand-authored control base (no float blend).
//   (b) Color composite blends by weight — alpha-over of the overlay albedo onto the hand-authored base
//       color, with the roughness (alpha) channel preserved.
//   (c) Height composite is still byte-identical after control/color layers are added (the height pass
//       is unchanged; the new passes only touch the control/color region maps).
//   (d) A hole authored on a control layer carves the composited control map and survives a clear +
//       repaint (idempotent); the hand-authored control underneath is preserved, and clearing the hole
//       layer entirely restores the hand-authored base (no hole).
//   (e) Save/load round-trips control + color layers (overlays AND their dense bases); a post-load
//       composite reproduces the composited control and color region maps byte-for-byte.
// Standalone like the Phase 5/6 tests; sets the descale fields via the friend declaration in
// pasture_3d_data.h since the tool API maps global positions to region pixels.
void test_layer_control_color() {
	UtilityFunctions::print("=== Testing control & color layers (phase 7) ===");

	const int region_size = 64;
	const Vector2i loc(0, 0);

	// Hand-authored control values (all base ids < 16 so the packed uint32 stays a positive int).
	const uint32_t CTRL_KEEP = enc_base(3) | enc_auto(true); // (5,5)   — no overlay covers it.
	const uint32_t CTRL_OVER = enc_base(7); // (20,20) — both control overlays cover it.
	const uint32_t CTRL_LOW = enc_base(11); // lower overlay value.
	const uint32_t CTRL_HIGH = enc_base(13); // upper overlay value (must win at the shared pixel).
	const uint32_t CTRL_AP = enc_base(9); // (40,40) — hand-authored under the hole layer.

	const Vector2i keep_px(5, 5), over_px(20, 20), low_px(25, 25), ap_px(40, 40), hp_px(42, 42), c_px(33, 33);
	const Vector3 over_pos(20, 0, 20), low_pos(25, 0, 25), ap_pos(40, 0, 40), hp_pos(42, 0, 42), c_pos(33, 0, 33);

	const Color base_col(0.2f, 0.4f, 0.6f);
	const Color over_col(0.9f, 0.1f, 0.1f);
	const real_t col_weight = 0.5f;
	auto approx8 = [](real_t a, real_t b) { return Math::abs(a - b) < 0.02f; }; // 8-bit color tolerance.

	Pasture3DData *data = memnew(Pasture3DData);
	data->_region_size = region_size;
	data->_region_sizev = V2I(region_size);
	data->_vertex_spacing = 1.f;
	Ref<Pasture3DRegion> region;
	region.instantiate();
	region->set_region_size(region_size);
	region->set_location(loc);
	data->add_region(region, false);
	Ref<Image> height_map = region->get_height_map();
	Ref<Image> control_map = region->get_control_map();
	Ref<Image> color_map = region->get_color_map();
	EXPECT_TRUE(height_map.is_valid() && control_map.is_valid() && color_map.is_valid());
	if (height_map.is_null()) {
		memdelete(data);
		return;
	}
	for (int y = 0; y < region_size; y++) {
		for (int x = 0; x < region_size; x++) {
			real_t h = real_t(x) * 0.5f - real_t(y) * 0.25f + real_t((x * 7 + y * 13) % 17);
			height_map->set_pixel(x, y, Color(h, 0.f, 0.f, 1.f));
		}
	}

	// Base-only stack aliasing the region height map (as load / _synthesize_base_layer do).
	Ref<Pasture3DLayerStack> stack;
	stack.instantiate();
	Ref<Pasture3DLayer> base;
	base.instantiate();
	base->set_layer_name("Base");
	base->set_map_type(TYPE_HEIGHT);
	base->set_tile_size(region_size);
	base->set_blend_mode(Pasture3DLayer::REPLACE);
	base->set_base(true);
	base->set_region_image(loc, height_map);
	stack->add_layer_ref(base);
	data->set_layer_stack(stack);

	// Hand-author control + color DIRECTLY into the region maps (simulates the user painting before any
	// tool layer exists). These become the dense bases captured when the first typed layer is created.
	data->set_control(Vector3(5, 0, 5), CTRL_KEEP);
	data->set_control(over_pos, CTRL_OVER);
	data->set_control(ap_pos, CTRL_AP);
	data->set_color(c_pos, base_col); // Roughness stays at the default (0.5).

	// A height detail layer so the height composite is non-trivial; capture its output as the baseline.
	int hdetail = data->layer_add("Detail", Pasture3DLayer::ADD);
	EXPECT_TRUE(hdetail == 1 && data->is_layer_routing());
	data->get_layer_stack()->get_layer(hdetail)->set_sample(loc, Vector2i(10, 10), 5.f, 1.f);
	data->composite_region(loc, Rect2i(), false);
	PackedByteArray height_baseline = height_map->get_data(); // (c) reference.

	// Create the control overlays (lower then upper) and a separate hole control layer, plus a color
	// overlay. Each create_owned_layer_typed lazily snapshots the hand-authored map into a dense base.
	int low_id = data->create_owned_layer_typed("/root/CtrlLow", "Low", Pasture3DLayer::REPLACE, TYPE_CONTROL);
	int high_id = data->create_owned_layer_typed("/root/CtrlHigh", "High", Pasture3DLayer::REPLACE, TYPE_CONTROL);
	int hole_id = data->create_owned_layer_typed("/root/Holes", "Holes", Pasture3DLayer::REPLACE, TYPE_CONTROL);
	int color_id = data->create_owned_layer_typed("/root/Paint", "Paint", Pasture3DLayer::REPLACE, TYPE_COLOR);
	EXPECT_TRUE(low_id > 0 && high_id > low_id && hole_id > high_id && color_id > hole_id);
	// A control base and a color base were created lazily.
	EXPECT_TRUE(data->get_layer_stack()->find_base_layer(TYPE_CONTROL) >= 0);
	EXPECT_TRUE(data->get_layer_stack()->find_base_layer(TYPE_COLOR) >= 0);

	// Author the overlays.
	data->set_control_on_layer(low_id, over_pos, int(CTRL_LOW), 1.f);
	data->set_control_on_layer(high_id, over_pos, int(CTRL_HIGH), 1.f); // Upper => must win at over_px.
	data->set_control_on_layer(low_id, low_pos, int(CTRL_LOW), 1.f); // Only the lower overlay here.
	data->set_hole_on_layer(hole_id, hp_pos, true);
	data->set_color_on_layer(color_id, c_pos, over_col, col_weight);

	// Full recomposite so every pixel is consistent, then capture the composited maps.
	data->composite_region(loc, Rect2i(), false);
	PackedByteArray height_after = height_map->get_data();
	PackedByteArray control_saved = control_map->get_data();
	PackedByteArray color_saved = color_map->get_data();

	// ---- (c) Height composite is byte-identical despite the control/color layers. ----
	EXPECT_TRUE(height_after == height_baseline);

	// ---- (a) Control topmost-covered-wins. ----
	EXPECT_TRUE(data->get_control(over_pos) == CTRL_HIGH); // Upper overlay overrides the lower one.
	EXPECT_TRUE(data->get_control(low_pos) == CTRL_LOW); // Only the lower overlay covers here.
	EXPECT_TRUE(data->get_control(Vector3(5, 0, 5)) == CTRL_KEEP); // No overlay => hand-authored base.

	// ---- (b) Color blends by weight, roughness preserved. ----
	{
		Color composited = color_map->get_pixelv(c_px);
		EXPECT_TRUE(approx8(composited.r, base_col.r + (over_col.r - base_col.r) * col_weight));
		EXPECT_TRUE(approx8(composited.g, base_col.g + (over_col.g - base_col.g) * col_weight));
		EXPECT_TRUE(approx8(composited.b, base_col.b + (over_col.b - base_col.b) * col_weight));
		EXPECT_TRUE(approx8(composited.a, 0.5f)); // Roughness from the base is untouched.
	}

	// ---- (d) Hole carved on the control layer; hand-authored control under it preserved. ----
	EXPECT_TRUE(data->get_control_hole(hp_pos)); // Hole present at the carved pixel.
	EXPECT_TRUE(data->get_control(ap_pos) == CTRL_AP); // Hand-authored control beneath is intact.
	EXPECT_FALSE(data->get_control_hole(ap_pos)); // ...and not itself a hole.

	// Clear the hole layer's footprint and re-carve identically: the result is the same (idempotent).
	AABB hole_area(Vector3(40, 0, 40), Vector3(8, 1, 8)); // Covers hp_px (42,42), not the rest.
	data->clear_layer_in_area(hole_id, hole_area);
	EXPECT_FALSE(data->get_control_hole(hp_pos)); // Cleared => hole gone, base shows through.
	EXPECT_TRUE(data->get_control(ap_pos) == CTRL_AP); // Hand-authored control still preserved.
	data->set_hole_on_layer(hole_id, hp_pos, true);
	EXPECT_TRUE(data->get_control_hole(hp_pos)); // Re-carved => identical result.

	// ---- (e) Save/load round-trip of control + color layers. ----
	{
		const String dir = "user://p3d_layer_phase7";
		Ref<DirAccess> da = DirAccess::open("user://");
		if (da.is_valid()) {
			da->make_dir_recursive("p3d_layer_phase7");
		}
		const String region_path = dir + String("/") + Util::location_to_filename(loc);
		Ref<DirAccess> dda = DirAccess::open(dir);
		if (dda.is_valid()) {
			for (const String &f : Array::make(Util::location_to_filename(loc), String(Util::LAYER_MANIFEST_FILENAME), Util::location_to_layer_filename(loc))) {
				if (dda->file_exists(f)) {
					dda->remove(f);
				}
			}
		}
		// Recompose so the saved region maps are fully consistent, then capture the runtime maps.
		data->composite_region(loc, Rect2i(), false);
		PackedByteArray ctrl_ref = control_map->get_data();
		PackedByteArray color_ref = color_map->get_data();
		region->set_modified(true);
		region->save(region_path, false);
		data->save_layers(dir);

		Pasture3DData *data2 = memnew(Pasture3DData);
		data2->_region_size = region_size;
		data2->_region_sizev = V2I(region_size);
		data2->_vertex_spacing = 1.f;
		Ref<Pasture3DRegion> region2 = ResourceLoader::get_singleton()->load(region_path, "Pasture3DRegion", ResourceLoader::CACHE_MODE_IGNORE);
		EXPECT_TRUE(region2.is_valid());
		if (region2.is_null()) {
			memdelete(data);
			memdelete(data2);
			return;
		}
		region2->set_location(loc);
		data2->add_region(region2, false);
		EXPECT_TRUE(data2->load_layers(dir));

		Ref<Pasture3DLayerStack> stack2 = data2->get_layer_stack();
		EXPECT_TRUE(stack2.is_valid());
		// Both typed bases and all four overlays survived (Base + Detail + Ctrl bases/overlays + Color).
		EXPECT_TRUE(stack2->find_base_layer(TYPE_CONTROL) >= 0);
		EXPECT_TRUE(stack2->find_base_layer(TYPE_COLOR) >= 0);
		int high_id2 = data2->find_layer_by_owner("/root/CtrlHigh");
		int color_id2 = data2->find_layer_by_owner("/root/Paint");
		EXPECT_TRUE(high_id2 >= 0 && color_id2 >= 0);
		// Overlay sample values round-tripped (control bits exact; color albedo + weight within 8-bit).
		EXPECT_TRUE(as_uint(stack2->get_layer_ptr(high_id2)->get_value(loc, over_px)) == CTRL_HIGH);
		{
			Color c = stack2->get_layer_ptr(color_id2)->get_sample(loc, c_px);
			EXPECT_TRUE(approx8(c.r, over_col.r) && approx8(c.b, over_col.b));
			EXPECT_TRUE(approx8(c.a, col_weight)); // Coverage weight stored in alpha.
		}

		// A post-load composite reproduces the composited control & color region maps byte-for-byte.
		Ref<Image> control_map2 = region2->get_control_map();
		Ref<Image> color_map2 = region2->get_color_map();
		data2->composite_region(loc, Rect2i(), false);
		EXPECT_TRUE(control_map2->get_data() == ctrl_ref);
		EXPECT_TRUE(color_map2->get_data() == color_ref);

		memdelete(data2);
	}

	// ---- (d cont.) Clearing the hole layer entirely restores the hand-authored base (no hole). ----
	AABB whole_region(Vector3(0, 0, 0), Vector3(region_size, 1, region_size));
	data->clear_layer_in_area(hole_id, whole_region);
	EXPECT_FALSE(data->get_control_hole(hp_pos)); // Hole fully removed.
	EXPECT_TRUE(data->get_control(ap_pos) == CTRL_AP); // Hand-authored control intact throughout.

	memdelete(data);
	UtilityFunctions::print("=== End control & color layer tests ===");
}

// Regression guard for the "changing region size breaks the layer system" bug: the Layers dock
// synthesizes a Base the moment a new node is selected, so by the time the user changes region_size
// in the inspector the stack already exists at the OLD size. change_region_size never migrated it, so
// _adopt_region_into_bases silently skipped every region added afterwards (tile-size mismatch) and
// the stack never covered the terrain. Covers both halves of the fix:
//   (a) The user repro: stack synthesized at 64 -> resize to 128 (no regions) -> add region ->
//       material (control) layer. The Base must cover the region and control painting must land.
//   (b) Data preservation: regions + an un-aliased Base + a painted height overlay survive a resize —
//       region maps keep their bytes, overlay samples keep their global position (including across a
//       negative-location re-key), and a full recomposite reproduces the maps byte-identically (the
//       migrated Base is the hand-authored source, not the composite — no double-applied ADD).
//   (c) Safety net: a stack whose EMPTY Base carries a stale tile size (e.g. saved by an older build)
//       is healed by the next add_region instead of being silently skipped.
void test_layer_region_size_change() {
	UtilityFunctions::print("=== Testing layer stack across change_region_size ===");

	// ---- (a) New-node repro: synthesize at 64, resize to 128, add a region, paint a material. ----
	{
		Pasture3DData *data = memnew(Pasture3DData);
		data->_region_size = 64; // As a fresh node's default before the user touches the inspector.
		data->_region_sizev = V2I(64);
		data->_vertex_spacing = 1.f;
		EXPECT_TRUE(data->ensure_layer_stack()); // The Layers dock does this on node selection.
		Ref<Pasture3DLayer> base = data->get_layer_stack()->get_layer(0);
		EXPECT_TRUE(base.is_valid() && base->get_tile_size() == 64);

		data->change_region_size(128); // Inspector edit, before any region exists.
		EXPECT_TRUE(data->_region_size == 128);

		Ref<Pasture3DRegion> region = data->add_region_blank(Vector2i(0, 0), false);
		EXPECT_TRUE(region.is_valid());
		// The empty Base was re-sized to the new grid and adopted the region (it was silently skipped
		// before the fix, leaving the stack permanently uncovered).
		EXPECT_TRUE(base->get_tile_size() == 128);
		EXPECT_TRUE(base->has_region(Vector2i(0, 0)));

		// Material-brush path: a control overlay (+ its lazily created dense Control Base), then a
		// painted + composited control sample must land on the region control map.
		int cidx = data->create_owned_layer_typed("/root/Mat", "Mat", Pasture3DLayer::REPLACE, TYPE_CONTROL);
		EXPECT_TRUE(cidx > 0);
		EXPECT_TRUE(data->get_layer_stack()->find_base_layer(TYPE_CONTROL) >= 0);
		const uint32_t ctrl = enc_base(3) | enc_overlay(1) | enc_blend(128);
		const Vector3 pos(10.f, 0.f, 7.f);
		data->set_control_on_layer(cidx, pos, int(ctrl), 1.f);
		EXPECT_TRUE(data->get_control(pos) == ctrl);
		memdelete(data);
	}

	// ---- (b) Existing regions + painted layers survive a 64 -> 128 resize. ----
	{
		const int rs_old = 64;
		Pasture3DData *data = memnew(Pasture3DData);
		data->_region_size = rs_old;
		data->_region_sizev = V2I(rs_old);
		data->_vertex_spacing = 1.f;
		// Two regions, one at a negative location so the re-key exercises floor division. Both merge
		// into new 128 regions at (0,0) and (-1,-1).
		for (const Vector2i &loc : { Vector2i(0, 0), Vector2i(-1, -1) }) {
			Ref<Pasture3DRegion> region = data->add_region_blank(loc, false);
			Ref<Image> hm = region->get_height_map();
			for (int y = 0; y < rs_old; y++) {
				for (int x = 0; x < rs_old; x++) {
					real_t h = real_t(loc.x * 100 + x) * 0.5f - real_t(y) * 0.25f + real_t((x * 7 + y * 13) % 17);
					hm->set_pixel(x, y, Color(h, 0.f, 0.f, 1.f));
				}
			}
			region->calc_height_range();
		}
		EXPECT_TRUE(data->ensure_layer_stack()); // Base aliases both region height maps.
		int didx = data->layer_add("Detail", Pasture3DLayer::ADD); // Un-aliases the Base.
		EXPECT_TRUE(didx == 1 && data->is_layer_routing());
		Ref<Pasture3DLayer> detail = data->get_layer_stack()->get_layer(didx);
		detail->set_sample(Vector2i(0, 0), Vector2i(10, 10), 5.f, 1.f);
		detail->set_sample(Vector2i(-1, -1), Vector2i(3, 4), -2.f, 1.f);
		data->composite_region(Vector2i(0, 0), Rect2i(), false);
		data->composite_region(Vector2i(-1, -1), Rect2i(), false);
		const real_t h_a = data->get_region_ptr(Vector2i(0, 0))->get_height_map()->get_pixel(10, 10).r;
		const real_t h_b = data->get_region_ptr(Vector2i(-1, -1))->get_height_map()->get_pixel(3, 4).r;

		data->change_region_size(128);

		// Old region (0,0) fills the top-left quadrant of new region (0,0); old region (-1,-1) fills
		// the bottom-right quadrant of new region (-1,-1) (origin -64,-64 -> local 64,64).
		Pasture3DRegion *r0 = data->get_region_ptr(Vector2i(0, 0));
		Pasture3DRegion *rn = data->get_region_ptr(Vector2i(-1, -1));
		EXPECT_TRUE(r0 && r0->get_region_size() == 128);
		EXPECT_TRUE(rn && rn->get_region_size() == 128);
		// Composited heights preserved by the map blit.
		EXPECT_TRUE(Math::is_equal_approx(r0->get_height_map()->get_pixel(10, 10).r, h_a));
		EXPECT_TRUE(Math::is_equal_approx(rn->get_height_map()->get_pixel(67, 68).r, h_b));
		// Overlay samples migrated with their global positions.
		EXPECT_TRUE(Math::is_equal_approx(detail->get_value(Vector2i(0, 0), Vector2i(10, 10)), 5.f));
		EXPECT_TRUE(Math::is_equal_approx(detail->get_value(Vector2i(-1, -1), Vector2i(67, 68)), -2.f));
		// The migrated Base is the hand-authored source (old composite blitted back over the adopted
		// seed), so a full recomposite is byte-identical — the ADD delta lands exactly once.
		PackedByteArray ref0 = r0->get_height_map()->get_data();
		PackedByteArray refn = rn->get_height_map()->get_data();
		data->composite_region(Vector2i(0, 0), Rect2i(), false);
		data->composite_region(Vector2i(-1, -1), Rect2i(), false);
		EXPECT_TRUE(r0->get_height_map()->get_data() == ref0);
		EXPECT_TRUE(rn->get_height_map()->get_data() == refn);
		memdelete(data);
	}

	// ---- (c) A stale-tile-size EMPTY Base (older save) is healed on the next add_region. ----
	{
		Pasture3DData *data = memnew(Pasture3DData);
		data->_region_size = 128;
		data->_region_sizev = V2I(128);
		data->_vertex_spacing = 1.f;
		Ref<Pasture3DLayerStack> stack;
		stack.instantiate();
		Ref<Pasture3DLayer> base;
		base.instantiate();
		base->set_layer_name("Base");
		base->set_map_type(TYPE_HEIGHT);
		base->set_tile_size(64); // Stale: synthesized/saved at the old region size.
		base->set_blend_mode(Pasture3DLayer::REPLACE);
		base->set_base(true);
		stack->add_layer_ref(base);
		data->set_layer_stack(stack);
		Ref<Pasture3DRegion> region = data->add_region_blank(Vector2i(1, 1), false);
		EXPECT_TRUE(region.is_valid());
		EXPECT_TRUE(base->get_tile_size() == 128);
		EXPECT_TRUE(base->has_region(Vector2i(1, 1)));
		memdelete(data);
	}

	UtilityFunctions::print("=== End layer stack region-size change tests ===");
}
///////////////////////////
// Water waves (spec §4.2, §4.3)
///////////////////////////

/**
 * The CPU side of the water parity contract.
 *
 * This suite cannot test agreement with the GPU -- that needs a rendering
 * context and lives in bench/WaterPhase4Gate.gd. What it can test is everything
 * the CPU evaluator claims on its own: that the table is reproducible, that the
 * loop closes, that the steepness normalisation lands where §3.1 says it does,
 * that empty slots are inert, that the analytic normal agrees with numerical
 * differentiation of the surface it is supposed to describe, and that the
 * Gerstner inverse converges.
 *
 * Several checks are two-sided on purpose: a tolerance nothing could fail is not
 * a test, so where a bound is asserted the counter-case is asserted to breach it.
 */
void test_water_waves() {
	UtilityFunctions::print("=== Testing water wave table and CPU evaluator (spec §4.3) ===");

	int passed = 0;
	int failed = 0;
	auto expect = [&passed, &failed](const bool p_cond, const String &p_desc) {
		if (p_cond) {
			passed++;
			UtilityFunctions::print("PASSED: ", p_desc);
		} else {
			failed++;
			UtilityFunctions::print("FAILED: ", p_desc);
		}
	};

	// The ocean preset (spec §6), which is the configuration every figure quoted
	// in §4.3 and §8.5 refers to.
	auto make_ocean = [](WaterWaves &r_waves) {
		r_waves.set_count(8);
		r_waves.set_direction_deg(20.f);
		r_waves.set_spread_deg(28.f);
		r_waves.set_amplitude(1.6f);
		r_waves.set_length_max(137.f);
		r_waves.set_steepness(0.35f);
		r_waves.set_loop_period(120.f);
		r_waves.update();
	};

	WaterWaves ocean;
	make_ocean(ocean);

	// ---- (a) The table is a pure function of the knobs. ----
	// The CPU query and the GPU surface agree only because both read the same
	// table, so a table that depends on anything else -- rand(), assignment order,
	// how many times update() ran -- breaks parity everywhere at once.
	{
		WaterWaves again;
		make_ocean(again);
		expect(ocean.get_shader_table() == again.get_shader_table(),
				"table is identical for identical knobs");

		// Same values, opposite assignment order, plus a redundant update().
		WaterWaves reordered;
		reordered.set_loop_period(120.f);
		reordered.set_steepness(0.35f);
		reordered.update();
		reordered.set_length_max(137.f);
		reordered.set_amplitude(1.6f);
		reordered.set_spread_deg(28.f);
		reordered.set_direction_deg(20.f);
		reordered.set_count(8);
		reordered.update();
		reordered.update();
		expect(ocean.get_shader_table() == reordered.get_shader_table(),
				"table is independent of knob assignment order");

		// The control: the table has to respond to a knob at all, or the two checks
		// above pass on a constant.
		WaterWaves different;
		make_ocean(different);
		different.set_direction_deg(21.f);
		different.update();
		expect(ocean.get_shader_table() != different.get_shader_table(),
				"CONTROL: one degree of wind direction changes the table");
	}

	// ---- (b) Unused slots are inert. ----
	// The evaluator sums all WATER_MAX_WAVES slots so it agrees with a variant
	// reading more waves than the table fills. That is only sound if the surplus
	// slots contribute nothing.
	{
		WaterWaves four;
		make_ocean(four);
		four.set_count(4);
		four.update();
		PackedVector4Array table = four.get_shader_table();
		bool tail_inert = table.size() == WATER_MAX_WAVES;
		for (int i = 4; i < table.size(); i++) {
			tail_inert = tail_inert && table[i].z == 0.f && table[i].w > 0.f;
		}
		expect(tail_inert, "slots past the wave count carry zero amplitude and a nonzero wavelength");

		float amp_sum = four.get_amplitude_sum();
		float table_sum = 0.f;
		for (int i = 0; i < table.size(); i++) {
			table_sum += (float)table[i].z;
		}
		expect(Math::is_equal_approx(amp_sum, table_sum),
				"get_amplitude_sum() matches the uploaded table");
		expect(amp_sum > four.get_amplitude(),
				"the amplitude sum exceeds the amplitude knob, which is only the longest wave's");
		Vector3 p = four.get_position(Vector2(123.f, -45.f), 3.7f);
		expect(std::isfinite(p.x) && std::isfinite(p.y) && std::isfinite(p.z),
				"a partly empty table evaluates finite");
	}

	// ---- (c) The loop closes (spec §3.2). ----
	{
		const Vector2 u(311.f, -207.f);
		const float period = ocean.get_loop_period();
		float wrap = (ocean.get_position(u, period) - ocean.get_position(u, 0.f)).length();

		WaterWaves unquantised;
		make_ocean(unquantised);
		unquantised.set_loop_period(0.f); // no quantisation at all
		unquantised.update();
		float wrap_control = (unquantised.get_position(u, period) -
				unquantised.get_position(u, 0.f))
									 .length();

		UtilityFunctions::print("  wrap displacement: quantised ", wrap,
				" m, unquantised control ", wrap_control, " m");
		expect(wrap < 0.001f, "the surface at t=period is the surface at t=0");
		expect(wrap_control > 0.1f, "CONTROL: without frequency quantisation the wrap jumps");
	}

	// ---- (d) The steepness normalisation is exact (spec §3.1). ----
	// sum(Q*w*A) is both the jacobian's ceiling and the self-intersection bound,
	// and the shader's amplitude weighting is supposed to make it equal the
	// steepness knob exactly. Foam thresholds are stated as fractions of it
	// (§3.6), so a normalisation that were merely close would put whitecaps in the
	// wrong place at every setting but the one it was tuned at.
	{
		const float steepnesses[] = { 0.05f, 0.35f, 0.6f, 1.0f };
		for (float steepness : steepnesses) {
			WaterWaves waves;
			make_ocean(waves);
			waves.set_steepness(steepness);
			waves.update();
			PackedVector4Array table = waves.get_shader_table();
			float sum_amp = waves.get_amplitude_sum();
			float sum_qwa = 0.f;
			for (int i = 0; i < table.size(); i++) {
				sum_qwa += (steepness / sum_amp) * (float)table[i].z;
			}
			expect(std::abs(sum_qwa - steepness) < 1e-6f,
					"sum(Q*w*A) equals wave_steepness at " + String::num(steepness, 2));
		}
	}

	// ---- (e) Wavelengths respect the precision floor. ----
	// §3.1 puts the floor at 10 m because a shorter wave's phase argument loses too
	// many mantissa bits at clipmap-scale coordinates. Quantising to the loop period
	// moves every wavelength, and nothing so far stopped it moving one below.
	{
		PackedVector4Array table = ocean.get_shader_table();
		double shortest = 1e9;
		for (int i = 0; i < ocean.get_count(); i++) {
			shortest = MIN(shortest, (double)table[i].w);
		}
		UtilityFunctions::print("  shortest wavelength after quantisation: ", shortest, " m");
		expect(shortest > (double)WaterWaves::MIN_WAVELENGTH * 0.9,
				"quantisation does not push a wavelength materially below the 10 m floor");
	}

	// ---- (f) The analytic normal describes the surface it is drawn on. ----
	// GPU Gems' Gerstner normal drops the cross terms of the exact tangent cross
	// product, so it is an approximation whose error grows with steepness. That is
	// fine, and worth knowing the size of: every lighting term in the shader is
	// built on this normal.
	//
	// Differenced near the origin on purpose. The surface is evaluated in float, so
	// at clipmap-scale coordinates a finite difference measures mantissa loss
	// rather than curvature.
	{
		const float du = 0.05f;
		const float t = 11.25f;
		double worst_deg = 0.0;
		for (int i = -6; i <= 6; i++) {
			for (int j = -6; j <= 6; j++) {
				Vector2 u(float(i) * 7.f, float(j) * 7.f);
				Vector3 px1 = ocean.get_position(u + Vector2(du, 0.f), t);
				Vector3 px0 = ocean.get_position(u - Vector2(du, 0.f), t);
				Vector3 pz1 = ocean.get_position(u + Vector2(0.f, du), t);
				Vector3 pz0 = ocean.get_position(u - Vector2(0.f, du), t);
				Vector3 numeric = (pz1 - pz0).cross(px1 - px0).normalized();
				Vector3 analytic = ocean.get_normal(u, t);
				double dot = CLAMP((double)numeric.dot(analytic), -1.0, 1.0);
				worst_deg = MAX(worst_deg, Math::rad_to_deg(std::acos(dot)));
			}
		}
		UtilityFunctions::print("  analytic vs numerically differentiated normal: worst ",
				worst_deg, " deg over 169 samples at steepness 0.35");
		expect(worst_deg < 3.0, "the analytic normal is within 3 degrees of the true surface normal");
		expect(worst_deg > 1e-4, "CONTROL: the two are computed differently and do not agree exactly");
	}

	// ---- (g) The Gerstner inverse converges, and matters. ----
	// This is the check G4 rests on. get_water_height() answers "how high is the
	// water above this XZ", but the wave function answers "where does parameter u
	// go", and the two differ by the horizontal displacement -- which at the ocean
	// defaults reaches metres. §4.3 asserted a few centimetres and left the solve to
	// the caller; the naive figure printed below is what that would have cost.
	{
		const float t = 6.5f;
		double worst_residual = 0.0;
		double worst_naive = 0.0;
		double naive_total = 0.0;
		int worst_iterations = 0;
		int n = 0;
		for (int i = -40; i <= 40; i++) {
			for (int j = -40; j <= 40; j++) {
				Vector2 target(float(i) * 13.7f, float(j) * 11.3f);
				int iterations = 0;
				Vector2 u = ocean.solve_domain(target, t, &iterations);
				Vector3 p = ocean.get_position(u, t);
				// Did the solve land where it was asked to?
				worst_residual = MAX(worst_residual,
						(double)Vector2(p.x - target.x, p.z - target.y).length());
				worst_iterations = MAX(worst_iterations, iterations);
				// What the answer would have been without solving.
				double err = std::abs((double)ocean.get_height(target, t) - (double)p.y);
				worst_naive = MAX(worst_naive, err);
				naive_total += err;
				n++;
			}
		}
		UtilityFunctions::print("  inverse solve: worst residual ", worst_residual,
				" m in at most ", worst_iterations, " iterations (bound ",
				WaterWaves::MAX_SOLVE_ITERATIONS, ")");
		UtilityFunctions::print("  without the solve: mean error ", naive_total / double(n),
				" m, worst ", worst_naive, " m -- against a G4 budget of 0.01 m");
		expect(worst_residual < 0.001, "the solve lands on the requested XZ to within a millimetre");
		expect(worst_iterations <= WaterWaves::MAX_SOLVE_ITERATIONS,
				"the solve converges inside its iteration bound");
		expect(worst_naive > 0.01,
				"CONTROL: skipping the solve breaks G4, so the solve is load-bearing");
	}

	// ---- (h) Calm water is cheap and steep water still meets G4. ----
	// The contraction factor is bounded by the steepness knob, so the iteration
	// count needed grows as the knob approaches 1 -- and at exactly 1, the
	// self-intersection limit, the surface has vertical tangents, the inverse stops
	// being unique and no iteration count is enough. 1.0 is therefore reported and
	// not asserted: the query is ill-posed there, not merely slow.
	//
	// What is asserted is G4 itself rather than the residual, because the residual
	// is horizontal and G4 is vertical. A solve that lands `r` metres from the
	// requested XZ returns the height of a point `r` away, so the height error is at
	// most the surface's maximum slope sum(w*A) times r. That bound is what has to
	// fit in 1 cm.
	{
		const float steepnesses[] = { 0.05f, 0.35f, 0.6f, 0.8f, 1.0f };
		for (float steepness : steepnesses) {
			WaterWaves waves;
			make_ocean(waves);
			waves.set_steepness(steepness);
			waves.update();

			PackedVector4Array table = waves.get_shader_table();
			double max_slope = 0.0;
			for (int i = 0; i < table.size(); i++) {
				max_slope += (double)(WaterWaves::TAU / (float)table[i].w) * (double)table[i].z;
			}

			double worst_residual = 0.0;
			int worst_iterations = 0;
			for (int i = -20; i <= 20; i++) {
				Vector2 target(float(i) * 29.3f, float(i) * -17.1f);
				int iterations = 0;
				Vector2 u = waves.solve_domain(target, 2.25f, &iterations);
				Vector3 p = waves.get_position(u, 2.25f);
				worst_residual = MAX(worst_residual,
						(double)Vector2(p.x - target.x, p.z - target.y).length());
				worst_iterations = MAX(worst_iterations, iterations);
			}
			double height_error = worst_residual * max_slope;
			UtilityFunctions::print("  steepness ", steepness, ": residual ", worst_residual,
					" m in ", worst_iterations, " iterations -> height error <= ", height_error,
					" m");
			if (steepness < 1.0f) {
				expect(height_error < 0.01,
						"G4 holds at steepness " + String::num(steepness, 2));
				expect(worst_iterations <= WaterWaves::MAX_SOLVE_ITERATIONS,
						"the solve stays inside its iteration bound at steepness " +
								String::num(steepness, 2));
			}
		}
	}

	// ---- (i) Clipmap-scale coordinates. ----
	// The ocean clipmap follows the camera, so a world 20 km across evaluates the
	// wave function 20 km from the domain origin, in float, on both sides. §3.1 says
	// this is what the 10 m wavelength floor and the domain origin uniform exist
	// for; this measures how far out it holds.
	{
		const float t = 47.5f;
		const float distances[] = { 100.f, 1000.f, 10000.f, 100000.f };
		for (float distance : distances) {
			Vector2 target(distance * 0.7071f, distance * -0.7071f);
			int iterations = 0;
			Vector2 u = ocean.solve_domain(target, t, &iterations);
			Vector3 p = ocean.get_position(u, t);
			double residual = (double)Vector2(p.x - target.x, p.z - target.y).length();
			bool sane = std::isfinite(p.y) &&
					std::abs((double)p.y) <= (double)ocean.get_amplitude_sum() + 1e-3;
			UtilityFunctions::print("  at ", distance, " m: residual ", residual,
					" m, height ", p.y, " m, ", iterations, " iterations");
			expect(sane, "the surface stays finite and inside the amplitude sum at " +
							String::num(distance, 0) + " m");
		}
	}

	UtilityFunctions::print("=== WATER PARITY UNIT TEST: ", passed, " passed, ", failed,
			" failed ===");
}
