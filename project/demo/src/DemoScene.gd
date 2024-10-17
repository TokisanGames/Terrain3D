@tool
extends Node

@export var dump_tree: bool = false :
	set(value):
		print_tree()


func _ready():
	if not Engine.is_editor_hint() and has_node("UI"):
		$UI.player = $Player

