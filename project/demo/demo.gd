extends Node

func _ready() -> void:
	print("Hello GDScript!")
	$MyNode.hello_node()
	MySingleton.hello_singleton()
