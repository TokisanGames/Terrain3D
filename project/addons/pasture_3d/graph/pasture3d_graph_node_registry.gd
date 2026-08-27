# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeRegistry — the one list of node types the graph editor's Add menu builds from, and the
# factory that turns an op tag into a fresh node. Adding a node type to the palette is a single entry
# here. Static only; never instanced.
@tool
class_name Pasture3DGraphNodeRegistry
extends RefCounted

const InputScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_input.gd")
const NoiseScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_noise.gd")
const NoiseJordanScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_noise_jordan.gd")
const NoiseSwissScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_noise_swiss.gd")
const WarpScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_warp.gd")
const ConstScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_const.gd")
const FurrowsScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_furrows.gd")
const DunesScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dunes.gd")
const CraterScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_crater.gd")
const GeologicalPrimitiveScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_geological_primitive.gd")
const BlendScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_blend.gd")
const SmoothScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_smooth.gd")
const TalusProjectionScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_talus_projection.gd")
const SpectralEqualizerScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_spectral_equalizer.gd")
const DepressionFillingScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_depression_filling.gd")
const TerraceScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_terrace.gd")
const StrataScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_strata.gd")
const CurveScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_curve.gd")
const RemapScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_remap.gd")
const MaskScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_mask.gd")
const CurvatureScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_curvature.gd")
const LakeFloodingScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_lake_flooding.gd")
const StreamExtractionScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_stream_extraction.gd")
const ErosionHydraulicScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_erosion_hydraulic.gd")
const ErosionThermalScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_erosion_thermal.gd")
const ScreeScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_scree.gd")
const ErosionScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_erosion.gd")
const DLAScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dla.gd")
const RerouteScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_reroute.gd")
const OutputScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_output.gd")


## Palette entries, in menu order. `title` is the menu/label text; `role` groups them (the same three
## Pasture3DGraphNode.Role names); `script` is the GDScript class to instance; `tags` supports fuzzy search.
static func entries() -> Array[Dictionary]:
	return [
		{"op": &"input", "title": "Input", "role": "Source", "script": InputScript, "tags": ["surface", "incoming", "host", "read"], "description": "Reads the incoming terrain surface handed to the graph."},
		{"op": &"noise", "title": "Noise", "role": "Generator", "script": NoiseScript, "tags": ["perlin", "simplex", "fractal", "fbm", "height"], "description": "Coherent multi-octave FastNoiseLite terrain generator."},
		{"op": &"noise_jordan", "title": "Jordan Noise", "role": "Generator", "script": NoiseJordanScript, "tags": ["jordan", "derivative", "gradient", "fbm", "fluting", "warp", "ridges", "mountain"], "description": "Derivative-feedback fractal noise with slope-attenuated octave warping for natural mountain fluting."},
		{"op": &"noise_swiss", "title": "Swiss Noise", "role": "Generator", "script": NoiseSwissScript, "tags": ["swiss", "ridge", "alps", "cirque", "arete", "glacial", "mountain", "trough"], "description": "Swiss Alps ridge fractal noise with slope-dependent erosion modulation and sharp arêtes."},
		{"op": &"warp", "title": "Domain Warp", "role": "Generator", "script": WarpScript, "tags": ["warp", "distortion", "coordinate", "vector", "noise", "swirl", "meander", "folds", "glacier", "strata"], "description": "Warps coordinates with vector noise fields for swirling striations and meanders."},
		{"op": &"const", "title": "Const", "role": "Generator", "script": ConstScript, "tags": ["constant", "flat", "height", "value", "bias"], "description": "Generates a uniform flat height offset."},
		{"op": &"furrows", "title": "Furrows", "role": "Generator", "script": FurrowsScript, "tags": ["ridges", "grooves", "stripes", "waves", "corrugation"], "description": "Directional corrugated ridge and furrow waves."},
		{"op": &"dunes", "title": "Dunes", "role": "Generator", "script": DunesScript, "tags": ["sand", "wind", "waves", "desert"], "description": "Asymmetric sand dune wave patterns."},
		{"op": &"crater", "title": "Crater", "role": "Generator", "script": CraterScript, "tags": ["meteor", "hole", "impact", "ring", "caldera"], "description": "Impact crater with raised rim and central cavity."},
		{"op": &"geological_primitive", "title": "Geological Primitive", "role": "Generator", "script": GeologicalPrimitiveScript, "tags": ["inselberg", "monadnock", "bornhardt", "caldera", "volcano", "dome", "cuesta", "badlands", "primitive", "landform", "macro"], "description": "Parametric macro geological landforms: solitary inselberg domes, volcanic calderas, and cuesta badland ridges."},
		{"op": &"blend", "title": "Blend", "role": "Combiner", "script": BlendScript, "tags": ["math", "add", "sub", "mul", "max", "min", "combine", "mix"], "description": "Combines two input heightfields with math blend modes."},
		{"op": &"smooth", "title": "Smooth", "role": "Filter", "script": SmoothScript, "tags": ["blur", "gaussian", "average", "filter", "soften"], "description": "Smooths / blurs terrain height variations."},
		{"op": &"talus_projection", "title": "Talus Projection", "role": "Filter", "script": TalusProjectionScript, "tags": ["talus", "scree", "repose", "cliff", "relaxation", "slope", "angle", "apron", "rubble"], "description": "Relaxes slopes exceeding a critical angle of repose to deposit natural scree aprons."},
		{"op": &"spectral_equalizer", "title": "Spectral Equalizer", "role": "Filter", "script": SpectralEqualizerScript, "tags": ["spectral", "equalizer", "frequency", "macro", "meso", "micro", "laplacian", "pyramid", "filter", "detail"], "description": "3-band spatial frequency equalizer for macro mountain mass, meso ridges, and micro crags."},
		{"op": &"depression_filling", "title": "Depression Filling", "role": "Filter", "script": DepressionFillingScript, "tags": ["depression", "filling", "sink", "pit", "spillway", "planchon", "darboux", "priority", "flood", "hydrology"], "description": "Fills enclosed pits and sinks up to their spillway elevation for monotonic drainage routing."},
		{"op": &"terrace", "title": "Terrace", "role": "Filter", "script": TerraceScript, "tags": ["steps", "bands", "quantize", "contour", "ledges"], "description": "Quantizes elevation into stepped terraces."},
		{"op": &"strata", "title": "Strata", "role": "Filter", "script": StrataScript, "tags": ["layers", "geology", "bands", "sediment", "dip", "strike", "cliff"], "description": "Applies tilted geological sedimentary layering to slopes."},
		{"op": &"curve", "title": "Curve", "role": "Filter", "script": CurveScript, "tags": ["remap", "ramp", "profile", "transfer", "shaping", "spline"], "description": "Remaps input heights through a custom Curve resource."},
		{"op": &"remap", "title": "Remap", "role": "Filter", "script": RemapScript, "tags": ["remap", "range", "clamp", "softknee", "invert", "scale", "normalize", "shaping"], "description": "Linearly remaps elevation ranges with soft-knee clamping and inversion."},
		{"op": &"mask", "title": "Mask", "role": "Filter", "script": MaskScript, "tags": ["selector", "slope", "altitude", "weight", "gate"], "description": "Gates height by slope, elevation, or curvature masks."},
		{"op": &"curvature", "title": "Curvature Mask", "role": "Filter", "script": CurvatureScript, "tags": ["curvature", "convexity", "concavity", "ridge", "valley", "basin", "laplacian", "hessian", "mask", "crests"], "description": "Calculates local terrain convexity/concavity to mask mountain ridges vs valley basins."},
		{"op": &"lake_flooding", "title": "Lake Flooding", "role": "Solver", "script": LakeFloodingScript, "tags": ["lake", "pond", "water", "basin", "flood", "spillway", "depth", "shoreline", "pool", "hydrology"], "description": "Floods closed basins or fills water levels; outputs lake surface + water depth + shoreline masks and spawns Pasture3DPond bodies."},
		{"op": &"stream_extraction", "title": "Stream Extraction", "role": "Solver", "script": StreamExtractionScript, "tags": ["stream", "river", "thalweg", "drainage", "catchment", "flow", "runoff", "channel", "carve", "hydrology"], "description": "Calculates surface runoff drainage accumulation, carves riverbeds, and spawns Pasture3DStream splines."},
		{"op": &"erosion_hydraulic", "title": "Hydraulic Erosion", "role": "Solver", "script": ErosionHydraulicScript, "tags": ["hydraulic", "erosion", "rain", "fluvial", "water", "flow", "sediment", "deposition", "channel", "meander"], "description": "Simulates continuous rainfall, water routing, sediment pickup, transport, and deposition."},
		{"op": &"erosion_thermal", "title": "Thermal Erosion", "role": "Solver", "script": ErosionThermalScript, "tags": ["thermal", "erosion", "talus", "scree", "weathering", "cliff", "repose", "slippage", "rock"], "description": "Simulates rock weathering and gravitational talus scree accumulation along steep slopes."},
		{"op": &"scree", "title": "Scree", "role": "Solver", "script": ScreeScript, "tags": ["talus", "rubble", "rock", "slope", "erosion", "deposition"], "description": "Sheds loose rock off steep ground; outputs height + a shed mask."},
		{"op": &"erosion", "title": "Erosion", "role": "Solver", "script": ErosionScript, "tags": ["river", "fluvial", "stream", "hydraulic", "water", "valley", "channel", "sediment"], "description": "Stream-power fluvial erosion; outputs eroded height + flow / erosion / deposition / wetness channels."},
		{"op": &"dla", "title": "DLA", "role": "Solver", "script": DLAScript, "tags": ["mountain", "ridge", "massif", "aggregation", "diffusion", "branch", "peak", "range"], "description": "Diffusion-limited-aggregation mountain; grows a branching ridge massif, outputs height + a footprint mask."},
		{"op": &"reroute", "title": "Reroute", "role": "Utility", "script": RerouteScript, "tags": ["dot", "relay", "wire", "route", "passthrough", "clean"], "description": "1-in / 1-out transparent wire routing dot."},
		{"op": &"output", "title": "Output", "role": "Sink", "script": OutputScript, "tags": ["sink", "result", "final", "surface"], "description": "The destination sink representing the graph's output surface."},
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
