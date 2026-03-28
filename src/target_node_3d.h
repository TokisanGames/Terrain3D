// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TARGET_NODE3D_CLASS_H
#define TARGET_NODE3D_CLASS_H

#include <godot_cpp/classes/node3d.hpp>

#include "constants.h"

class TargetNode3D {
	CLASS_NAME_STATIC("Terrain3DTargetNode3D");

private:
	uint64_t _instance_id = 0;

public:
	void clear() { _instance_id = 0; }

	void set_target(Node3D *p_node) {
		if (p_node && !p_node->is_queued_for_deletion()) {
			_instance_id = p_node->get_instance_id();
		} else {
			clear();
		}
	}

	Node3D *get_target() const {
		if (_instance_id == 0) {
			return nullptr;
		}
		Object *obj = ObjectDB::get_instance(_instance_id);
		return obj ? Object::cast_to<Node3D>(obj) : nullptr;
	}

	Node3D *ptr() const { return get_target(); }

	bool is_valid() const {
		Node3D *node = get_target();
		return node && node->is_inside_tree() && !node->is_queued_for_deletion();
	}

	bool is_null() const {
		return !is_valid();
	}
};

#endif // TARGET_NODE3D_CLASS_H
