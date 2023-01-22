#include "my_node.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void MyNode::_bind_methods()
{
	ClassDB::bind_method("hello_node", &MyNode::hello_node);
}

MyNode::MyNode()
{
}

MyNode::~MyNode()
{
}

// Override built-in methods with your own logic. Make sure to declare them in the header as well!

void MyNode::_ready()
{
}

void MyNode::_process(double delta)
{
}

void MyNode::hello_node()
{
	UtilityFunctions::print("Hello GDExtension Node!");
}
