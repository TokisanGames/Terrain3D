// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef UNIT_TESTING_H
#define UNIT_TESTING_H

#define EXPECT_FALSE(cond)                              \
	do {                                                \
		if (cond) {                                     \
			UtilityFunctions::print("FAILED: ", #cond); \
		} else {                                        \
			UtilityFunctions::print("PASSED: ", #cond); \
		}                                               \
	} while (0)

#define EXPECT_TRUE(cond)                               \
	do {                                                \
		if (cond) {                                     \
			UtilityFunctions::print("PASSED: ", #cond); \
		} else {                                        \
			UtilityFunctions::print("FAILED: ", #cond); \
		}                                               \
	} while (0)

void test_differs();

#endif // UNIT_TESTING_H
