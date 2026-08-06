// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TARGET_NODE3D_CLASS_H
#define TARGET_NODE3D_CLASS_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/node3d.hpp>

#include "constants.h"

/**
 * A node reference held by instance id, so a freed node cannot be resurrected through it.
 *
 * Templated on the node type rather than duplicated. TargetNode3D is the original and every user of
 * it is unchanged; TargetNode exists because Pasture3DBuoy points at a water body, and a water body
 * is duck-typed by method rather than by class (§5.5) -- the property is declared as Node so a
 * GDScript Pasture3DPool and a C++ Pasture3DOcean can both be one.
 */
template <typename T>
class TargetNodeT {
	CLASS_NAME_STATIC("Pasture3DTargetNode");

private:
	uint64_t _instance_id = 0;

public:
	void clear() { _instance_id = 0; }

	void set_target(T *p_node) {
		if (p_node && !p_node->is_queued_for_deletion()) {
			_instance_id = p_node->get_instance_id();
		} else {
			clear();
		}
	}

	// Has a target been ASSIGNED, whatever became of it since?
	//
	// Distinct from is_valid() and the distinction matters: "the user set this and the node has
	// since left the tree" is not the same state as "the user set nothing", and a caller that
	// falls back to a default in the second case must not fall back in the first.
	bool is_set() const { return _instance_id != 0; }

	T *get_target() const {
		if (_instance_id == 0) {
			return nullptr;
		}
		Object *obj = ObjectDB::get_instance(_instance_id);
		return obj ? Object::cast_to<T>(obj) : nullptr;
	}

	T *ptr() const { return get_target(); }

	bool is_valid() const {
		T *node = get_target();
		return node && node->is_inside_tree() && !node->is_queued_for_deletion();
	}

	bool is_null() const {
		return !is_valid();
	}
};

using TargetNode3D = TargetNodeT<Node3D>;
using TargetNode = TargetNodeT<Node>;

#endif // TARGET_NODE3D_CLASS_H
