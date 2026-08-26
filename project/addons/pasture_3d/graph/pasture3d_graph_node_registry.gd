# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeRegistry — the one list of node types the graph editor's Add menu builds from, and the
# factory that turns an op tag into a fresh node. Adding a node type to the palette is a single entry
# here. Static only; never instanced.
@tool
class_name Pasture3DGraphNodeRegistry
extends RefCounted


## Palette entries, in menu order. `title` is the menu/label text; `role` groups them (the same three
## Pasture3DGraphNode.Role names); `script` is the GDScript class to instance.
static func entries() -> Array[Dictionary]:
	return [
		{"op": &"input", "title": "Input", "role": "Source", "script": Pasture3DGraphNodeInput},
		{"op": &"noise", "title": "Noise", "role": "Generator", "script": Pasture3DGraphNodeNoise},
		{"op": &"const", "title": "Const", "role": "Generator", "script": Pasture3DGraphNodeConst},
		{"op": &"furrows", "title": "Furrows", "role": "Generator", "script": Pasture3DGraphNodeFurrows},
		{"op": &"dunes", "title": "Dunes", "role": "Generator", "script": Pasture3DGraphNodeDunes},
		{"op": &"crater", "title": "Crater", "role": "Generator", "script": Pasture3DGraphNodeCrater},
		{"op": &"blend", "title": "Blend", "role": "Combiner", "script": Pasture3DGraphNodeBlend},
		{"op": &"smooth", "title": "Smooth", "role": "Filter", "script": Pasture3DGraphNodeSmooth},
		{"op": &"terrace", "title": "Terrace", "role": "Filter", "script": Pasture3DGraphNodeTerrace},
		{"op": &"strata", "title": "Strata", "role": "Filter", "script": Pasture3DGraphNodeStrata},
		{"op": &"curve", "title": "Curve", "role": "Filter", "script": Pasture3DGraphNodeCurve},
		{"op": &"output", "title": "Output", "role": "Sink", "script": Pasture3DGraphNodeOutput},
	]


## A fresh node for `p_op`, or null if the op is unknown.
static func create(p_op: StringName) -> Pasture3DGraphNode:
	for e in entries():
		if e["op"] == p_op:
			return (e["script"] as GDScript).new()
	return null
