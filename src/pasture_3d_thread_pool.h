// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#pragma once

#include <algorithm>
#include <functional>
#include <thread>
#include <vector>

namespace godot {

class Pasture3DThreadPool {
public:
	template <typename F>
	static inline void parallel_for_rows(int p_gh, int p_min_rows_per_chunk, F &&p_func) {
		const unsigned int num_threads = std::max(1u, std::thread::hardware_concurrency());
		if (p_gh < 128 || num_threads <= 1 || p_gh < p_min_rows_per_chunk * 2) {
			p_func(0, p_gh);
			return;
		}

		const int num_chunks = std::min((int)num_threads, (p_gh + p_min_rows_per_chunk - 1) / p_min_rows_per_chunk);
		if (num_chunks <= 1) {
			p_func(0, p_gh);
			return;
		}

		const int rows_per_chunk = (p_gh + num_chunks - 1) / num_chunks;
		std::vector<std::thread> workers;
		workers.reserve(num_chunks - 1);

		for (int c = 1; c < num_chunks; c++) {
			const int z0 = c * rows_per_chunk;
			const int z1 = std::min(z0 + rows_per_chunk, p_gh);
			if (z0 < p_gh) {
				workers.emplace_back([z0, z1, &p_func]() {
					p_func(z0, z1);
				});
			}
		}

		// Main thread executes chunk 0
		const int z0_main = 0;
		const int z1_main = std::min(rows_per_chunk, p_gh);
		p_func(z0_main, z1_main);

		for (auto &t : workers) {
			if (t.joinable()) {
				t.join();
			}
		}
	}

	template <typename F>
	static inline void parallel_for_elements(int p_total_count, int p_min_elements_per_chunk, F &&p_func) {
		const unsigned int num_threads = std::max(1u, std::thread::hardware_concurrency());
		if (p_total_count < 16384 || num_threads <= 1 || p_total_count < p_min_elements_per_chunk * 2) {
			p_func(0, p_total_count);
			return;
		}

		const int num_chunks = std::min((int)num_threads, (p_total_count + p_min_elements_per_chunk - 1) / p_min_elements_per_chunk);
		if (num_chunks <= 1) {
			p_func(0, p_total_count);
			return;
		}

		const int chunk_size = (p_total_count + num_chunks - 1) / num_chunks;
		std::vector<std::thread> workers;
		workers.reserve(num_chunks - 1);

		for (int c = 1; c < num_chunks; c++) {
			const int i0 = c * chunk_size;
			const int i1 = std::min(i0 + chunk_size, p_total_count);
			if (i0 < p_total_count) {
				workers.emplace_back([i0, i1, &p_func]() {
					p_func(i0, i1);
				});
			}
		}

		// Main thread executes chunk 0
		const int i0_main = 0;
		const int i1_main = std::min(chunk_size, p_total_count);
		p_func(i0_main, i1_main);

		for (auto &t : workers) {
			if (t.joinable()) {
				t.join();
			}
		}
	}
};

} // namespace godot
