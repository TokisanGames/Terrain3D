// Copyright © 2024 Lorenz Wildberg

#include "chunk_manager.h"
#include "terrain_3d_storage.h"

void ChunkManager::move(Vector3 p_camera_position) {
    Vector2i pos_snapped = _snap_position(p_camera_position);
    Vector2i snapped_delta = pos_snapped - _old_snapped_pos;

	Array new_array = Array();
	new_array.resize(_chunk_count);
	new_array.fill(nullptr);

    // iterate old array and fill new array
	for (int i = 0; i < _chunks_width; i++) {
		for (int j = 0; j < _chunks_width; j++) {
		    int index = i * _chunks_width + j;

            // offset to the old camera position
			Vector2i old_array_position = Vector2i(i, j) + snapped_delta;

			// index for the current chunk in the new array in the old array
			int old_index = old_array_position.x * _chunks_width + old_array_position.y;

			if (Object::cast_to<BaseChunk>(_active_chunks[old_index]) == nullptr) {
			    continue;
			}

			bool position_still_exists_in_old =
			    _chunk_count > old_array_position.x && old_array_position.x >= 0 &&
			    _chunk_count > old_array_position.y && old_array_position.y >= 0;

			// in world coordinates
			Vector2i chunk_location = pos_snapped + Vector2i((i - _chunk_count * 0.5) * _chunk_size, (j - _chunk_count * 0.5) * _chunk_size);

			bool too_far = Vector2(chunk_location).distance_to(Vector2(p_camera_position.x, p_camera_position.z)) > _distance;

			if (position_still_exists_in_old && !too_far) {
			    // move chunk to new location but don't refill
			    new_array[index] = _active_chunks[old_index];
			    Object::cast_to<BaseChunk>(new_array[index])->set_position(chunk_location);
			    _active_chunks[old_index] = nullptr;
			} else if (!position_still_exists_in_old || too_far) {
			    // disable chunk
			    Object::cast_to<BaseChunk>(_active_chunks[old_index])->set_enabled(false);
			    _inactive_chunks.push_back(_active_chunks[old_index]);
			    _active_chunks[old_index] = nullptr;

			    if (!too_far) {
			        // create new chunk from inactive
			        BaseChunk* new_chunk = Object::cast_to<BaseChunk>(_inactive_chunks.pop_back());
			        new_chunk->set_position(chunk_location);
			        new_chunk->set_enabled(true);
			        new_array[index] = new_chunk;
			    }
			}
		}
	}

	_active_chunks = new_array;
}

Vector2i ChunkManager::_snap_position(Vector3 p_position) {
    Vector2 camera_position = Vector2(p_position.x, p_position.z);
	Vector2i pos_snapped;
	float positive_camera_position_x = (camera_position.x < 0.0) ? -camera_position.x : camera_position.x;
    if (Math::fract(positive_camera_position_x / _chunk_size) >= 0.5) {
        if (camera_position.x < 0.0) {
            pos_snapped.x = Math::floor(camera_position.x / _chunk_size) * _chunk_size;
        } else {
            pos_snapped.x = Math::ceil(camera_position.x / _chunk_size) * _chunk_size;
        }
    } else {
        if (camera_position.x < 0.0) {
            pos_snapped.x = Math::floor(camera_position.x / _chunk_size) * _chunk_size;
        } else {
            pos_snapped.x = Math::floor(camera_position.x / _chunk_size) * _chunk_size;
        }
    }
    float positive_camera_position_y = (camera_position.y < 0.0) ? -camera_position.y : camera_position.y;
    if (Math::fract(positive_camera_position_y / _chunk_size) >= 0.5) {
        if (camera_position.y < 0.0) {
            pos_snapped.y = Math::floor(camera_position.y / _chunk_size) * _chunk_size;
        } else {
            pos_snapped.y = Math::ceil(camera_position.y / _chunk_size) * _chunk_size;
        }
    } else {
        if (camera_position.y < 0.0) {
            pos_snapped.y = Math::ceil(camera_position.y / _chunk_size) * _chunk_size;
        } else {
            pos_snapped.y = Math::floor(camera_position.y / _chunk_size) * _chunk_size;
        }
    }
    return pos_snapped;
}

void ChunkManager::_build() {
    _destroy();
    _active_chunks.resize(_chunk_count);
    _inactive_chunks.resize(_chunk_count);
    for (int i = 0; i < _chunk_count; i++) {
        _inactive_chunks[i] = create_chunk();
        _active_chunks[i] = nullptr;
    }
}

void ChunkManager::_destroy() {
    _active_chunks.clear();
    _inactive_chunks.clear();
}

void ChunkManager::set_distance(float p_distance) {
    _distance = p_distance;

    _chunks_width = ceil((_distance + 1.0) / _chunk_size) * 2.0;
    _chunk_count = _chunks_width * _chunks_width;

    _build();
}

void ChunkManager::set_chunk_size(float p_size) {
    _chunk_size = p_size;
    _build();
}
