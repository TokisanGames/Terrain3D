// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef UNIT_TESTING_H
#define UNIT_TESTING_H

#define EXPECT_FALSE(cond) \
	do { \
		if (cond) { \
			UtilityFunctions::print("FAILED: ", #cond); \
		} else { \
			UtilityFunctions::print("PASSED: ", #cond); \
		} \
	} while (0)

#define EXPECT_TRUE(cond) \
	do { \
		if (cond) { \
			UtilityFunctions::print("PASSED: ", #cond); \
		} else { \
			UtilityFunctions::print("FAILED: ", #cond); \
		} \
	} while (0)

void test_differs();
void test_layer_compositing();
void test_layer_persistence();
void test_layer_idempotent_composite();
void test_layer_undo_restore();
void test_layer_stroke_undo_integration();
void test_layer_base_persistence();
void test_layer_road_connector();
void test_layer_subtiling();
void test_layer_control_color();
void test_layer_region_size_change();
void test_water_waves();

#endif // UNIT_TESTING_H
