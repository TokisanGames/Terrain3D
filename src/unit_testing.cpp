// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#include "unit_testing.h"
#include "terrain_3d_util.h"

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
		log_differs(s1, s2, "String shared", false); // Same ptr
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