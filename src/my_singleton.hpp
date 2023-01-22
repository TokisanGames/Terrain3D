#pragma once

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

class MySingleton : public Object
{
	GDCLASS(MySingleton, Object);

	static MySingleton *singleton;

protected:
	static void _bind_methods();

public:
	static MySingleton *get_singleton();

	MySingleton();
	~MySingleton();

	void hello_singleton();
};
