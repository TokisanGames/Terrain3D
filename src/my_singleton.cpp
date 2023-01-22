#include "my_singleton.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

MySingleton *MySingleton::singleton = nullptr;

void MySingleton::_bind_methods()
{
	ClassDB::bind_method("hello_singleton", &MySingleton::hello_singleton);
}

MySingleton *MySingleton::get_singleton()
{
	return singleton;
}

MySingleton::MySingleton()
{
	ERR_FAIL_COND(singleton != nullptr);
	singleton = this;
}

MySingleton::~MySingleton()
{
	ERR_FAIL_COND(singleton != this);
	singleton = nullptr;
}

void MySingleton::hello_singleton()
{
	UtilityFunctions::print("Hello GDExtension Singleton!");
}
