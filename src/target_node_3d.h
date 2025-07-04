// Copyright © 2025 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TARGET_NODE3D_CLASS_H
#define TARGET_NODE3D_CLASS_H

#include <godot_cpp/classes/node3d.hpp>

using namespace godot;

class TargetNode3D {
	CLASS_NAME_STATIC("Terrain3DTargetNode3D");

private:
	uint64_t _instance_id = 0;
	Node3D *_target = nullptr;

public:
	void clear() {
		_instance_id = 0;
		_target = nullptr;
	}

	void set_target(Node3D *p_node_3d) {
		if (p_node_3d) {
			_target = p_node_3d;
			_instance_id = p_node_3d->get_instance_id();
		} else {
			clear();
		}
	}

	Node3D *ptr() const {
		return _target;
	}

	Node3D *get_target() const {
		return _target;
	}

	bool is_valid() const {
		if (_target && _instance_id > 0) {
			return _target == ObjectDB::get_instance(_instance_id);
		}
		return false;
	}

	bool is_null() const {
		return !is_valid();
	}

	bool is_inside_tree() const {
		return is_valid() && _target->is_inside_tree();
	}
};

#endif // TARGET_NODE3D_CLASS_H
