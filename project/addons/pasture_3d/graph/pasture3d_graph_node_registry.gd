# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeRegistry — the one list of node types the graph editor's Add menu builds from, and the
# factory that turns an op tag into a fresh node. Adding a node type to the palette is a single entry
# here. Static only; never instanced.
@tool
class_name Pasture3DGraphNodeRegistry
extends RefCounted


## Palette entries, in menu order. `title` is the menu/label text; `role` groups them (the same three
## Pasture3DGraphNode.Role names); `script` is the GDScript class to instance; `tags` supports fuzzy search.
static func entries() -> Array[Dictionary]:
	return [
		{"op": &"input", "title": "Input", "role": "Source", "script": Pasture3DGraphNodeInput, "tags": ["surface", "incoming", "host", "read"], "description": "Reads the incoming terrain surface handed to the graph."},
		{"op": &"noise", "title": "Noise", "role": "Generator", "script": Pasture3DGraphNodeNoise, "tags": ["perlin", "simplex", "fractal", "fbm", "height"], "description": "Coherent multi-octave FastNoiseLite terrain generator."},
		{"op": &"const", "title": "Const", "role": "Generator", "script": Pasture3DGraphNodeConst, "tags": ["constant", "flat", "height", "value", "bias"], "description": "Generates a uniform flat height offset."},
		{"op": &"furrows", "title": "Furrows", "role": "Generator", "script": Pasture3DGraphNodeFurrows, "tags": ["ridges", "grooves", "stripes", "waves", "corrugation"], "description": "Directional corrugated ridge and furrow waves."},
		{"op": &"dunes", "title": "Dunes", "role": "Generator", "script": Pasture3DGraphNodeDunes, "tags": ["sand", "wind", "waves", "desert"], "description": "Asymmetric sand dune wave patterns."},
		{"op": &"crater", "title": "Crater", "role": "Generator", "script": Pasture3DGraphNodeCrater, "tags": ["meteor", "hole", "impact", "ring", "caldera"], "description": "Impact crater with raised rim and central cavity."},
		{"op": &"blend", "title": "Blend", "role": "Combiner", "script": Pasture3DGraphNodeBlend, "tags": ["math", "add", "sub", "mul", "max", "min", "combine", "mix"], "description": "Combines two input heightfields with math blend modes."},
		{"op": &"smooth", "title": "Smooth", "role": "Filter", "script": Pasture3DGraphNodeSmooth, "tags": ["blur", "gaussian", "average", "filter", "soften"], "description": "Smooths / blurs terrain height variations."},
		{"op": &"terrace", "title": "Terrace", "role": "Filter", "script": Pasture3DGraphNodeTerrace, "tags": ["steps", "bands", "quantize", "contour", "ledges"], "description": "Quantizes elevation into stepped terraces."},
		{"op": &"strata", "title": "Strata", "role": "Filter", "script": Pasture3DGraphNodeStrata, "tags": ["layers", "geology", "bands", "sediment"], "description": "Applies geological sedimentary layering to slopes."},
		{"op": &"curve", "title": "Curve", "role": "Filter", "script": Pasture3DGraphNodeCurve, "tags": ["remap", "ramp", "profile", "transfer", "shaping"], "description": "Remaps input heights through a custom Curve resource."},
		{"op": &"mask", "title": "Mask", "role": "Filter", "script": Pasture3DGraphNodeMask, "tags": ["selector", "slope", "altitude", "weight", "gate"], "description": "Gates height by slope, elevation, or curvature masks."},
		{"op": &"output", "title": "Output", "role": "Sink", "script": Pasture3DGraphNodeOutput, "tags": ["sink", "result", "final", "surface"], "description": "The destination sink representing the graph's output surface."},
	]


## A fresh node for `p_op`, or null if the op is unknown.
static func create(p_op: StringName) -> Pasture3DGraphNode:
	for e in entries():
		if e["op"] == p_op:
			return (e["script"] as GDScript).new()
	return null


## Searches palette entries matching `p_query` by title, op, role, or tags.
static func search(p_query: String) -> Array[Dictionary]:
	var q := p_query.strip_edges().to_lower()
	if q.is_empty():
		return entries()
	
	var exact_matches: Array[Dictionary] = []
	var partial_matches: Array[Dictionary] = []
	var tag_matches: Array[Dictionary] = []
	
	for e in entries():
		var title: String = String(e.get("title", "")).to_lower()
		var op_str: String = String(e.get("op", "")).to_lower()
		var role_str: String = String(e.get("role", "")).to_lower()
		var tags: Array = e.get("tags", [])
		
		if title == q or op_str == q:
			exact_matches.append(e)
		elif title.begins_with(q) or op_str.begins_with(q):
			partial_matches.append(e)
		elif title.contains(q) or op_str.contains(q) or role_str.contains(q):
			partial_matches.append(e)
		else:
			for tag in tags:
				if String(tag).to_lower().contains(q):
					tag_matches.append(e)
					break
					
	var result: Array[Dictionary] = []
	result.append_array(exact_matches)
	for m in partial_matches:
		if not result.has(m):
			result.append(m)
	for m in tag_matches:
		if not result.has(m):
			result.append(m)
	return result
