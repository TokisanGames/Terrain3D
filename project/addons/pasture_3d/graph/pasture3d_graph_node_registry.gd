# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DGraphNodeRegistry — the one list of node types the graph editor's Add menu builds from, and the
# factory that turns an op tag into a fresh node. Adding a node type to the palette is a single entry
# here. Static only; never instanced.
@tool
class_name Pasture3DGraphNodeRegistry
extends RefCounted

# --- Production Node Scripts ---
const InputScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_input.gd")
const NoiseScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_noise.gd")
const NoiseJordanScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_noise_jordan.gd")
const NoiseSwissScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_noise_swiss.gd")
const WarpScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_warp.gd")
const ConstScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_const.gd")
const ConstIntScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_const_int.gd")
const ConstVectorScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_const_vector.gd")
const ConstColorScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_const_color.gd")
const ConstCurveScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_const_curve.gd")
const ConstBoolScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_const_bool.gd")
const FurrowsScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_furrows.gd")
const DunesScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dunes.gd")
const CraterScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_crater.gd")
const GeologicalPrimitiveScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_geological_primitive.gd")
const MountainConeScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_mountain_cone.gd")
const MountainInselbergScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_mountain_inselberg.gd")
const MountainRangeRadialScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_mountain_range_radial.gd")
const MountainTibestiScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_mountain_tibesti.gd")
const MountainStumpScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_mountain_stump.gd")
const ShatteredPeakScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_shattered_peak.gd")
const CalderaScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_caldera.gd")
const TransformScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_transform.gd")
const FalloffScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_falloff.gd")
const ContrastScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_contrast.gd")
const DistanceTransformScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_distance_transform.gd")
const ExpandShrinkScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_expand_shrink.gd")
const RelativeElevationScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_relative_elevation.gd")
const SmoothFillScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_smooth_fill.gd")
const GavoronoiseScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_gavoronoise.gd")
const WarpDownslopeScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_warp_downslope.gd")
const FloodingUniformLevelScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_flooding_uniform_level.gd")
const WaterMaskScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_water_mask.gd")
const MudslideScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_mudslide.gd")
const RecastCliffScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_recast_cliff.gd")
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
const HydraulicParticleScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_hydraulic_particle.gd")
const HydraulicStreamLogScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_hydraulic_stream_log.gd")
const HydraulicSaleveScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_hydraulic_saleve.gd")
const ErosionThermalScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_erosion_thermal.gd")
const ScreeScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_scree.gd")
const ErosionScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_erosion.gd")
const DLAScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dla.gd")
const RerouteScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_reroute.gd")
const OutputScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_output.gd")
const TerrainBusMergeScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_terrain_bus_merge.gd")
const TerrainBusSplitScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_terrain_bus_split.gd")

# --- Developer / Reference [Dev/GD] Node Scripts ---
const DevErosionHydraulicScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_erosion_hydraulic.gd")
const DevHydraulicParticleScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_hydraulic_particle.gd")
const DevHydraulicStreamLogScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_hydraulic_stream_log.gd")
const DevHydraulicSaleveScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_hydraulic_saleve.gd")
const DevErosionThermalScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_erosion_thermal.gd")
const DevDepressionFillingScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_depression_filling.gd")
const DevLakeFloodingScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_lake_flooding.gd")
const DevStreamExtractionScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_stream_extraction.gd")
const DevSpectralEqualizerScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_spectral_equalizer.gd")
const DevTalusProjectionScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_talus_projection.gd")
const DevCurvatureScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_curvature.gd")
const DevWarpScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_warp.gd")
const DevErosionScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_erosion.gd")
const DevDLAScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_dla.gd")
const DevMountainConeScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_mountain_cone.gd")
const DevMountainInselbergScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_mountain_inselberg.gd")
const DevMountainRangeRadialScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_mountain_range_radial.gd")
const DevMountainTibestiScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_mountain_tibesti.gd")
const DevMountainStumpScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_mountain_stump.gd")
const DevShatteredPeakScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_shattered_peak.gd")
const DevCalderaScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_caldera.gd")
const DevTransformScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_transform.gd")
const DevDistanceTransformScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_distance_transform.gd")
const DevExpandShrinkScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_expand_shrink.gd")
const DevGavoronoiseScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_gavoronoise.gd")
const DevWarpDownslopeScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_warp_downslope.gd")
const DevFloodingUniformLevelScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_flooding_uniform_level.gd")
const DevWaterMaskScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_water_mask.gd")
const DevMudslideScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_mudslide.gd")
const DevTerrainMetricsScript = preload("res://addons/pasture_3d/graph/pasture3d_graph_node_dev_terrain_metrics.gd")


## Checks if the developer flag for exposing [Dev/GD] reference nodes is enabled.
static func is_dev_nodes_enabled() -> bool:
	if Engine.is_editor_hint():
		if ProjectSettings.has_setting("pasture_3d/developer/enable_gdscript_reference_nodes"):
			return bool(ProjectSettings.get_setting("pasture_3d/developer/enable_gdscript_reference_nodes"))
	return false


## The standard ordered category names for the palette.
static func categories() -> Array[String]:
	return [
		"Generators",
		"Filters & Modifiers",
		"Solvers & Realism",
		"Math & Combiners",
		"Constants",
		"Routing & Structural",
		"Dev / Reference",
	]


## Palette entries, in menu order. `title` is the menu/label text; `role` / `category` groups them;
## `script` is the GDScript class to instance; `tags` supports fuzzy search.
static func entries(p_include_dev: bool = false) -> Array[Dictionary]:
	var list: Array[Dictionary] = [
		{"op": &"input", "title": "Input", "category": "Routing & Structural", "role": "Source", "script": InputScript, "tags": ["surface", "incoming", "host", "read"], "description": "Reads the incoming terrain surface handed to the graph."},
		{"op": &"output", "title": "Output", "category": "Routing & Structural", "role": "Sink", "script": OutputScript, "tags": ["sink", "result", "final", "surface"], "description": "The destination sink representing the graph's output surface."},
		{"op": &"reroute", "title": "Reroute", "category": "Routing & Structural", "role": "Utility", "script": RerouteScript, "tags": ["dot", "relay", "wire", "route", "passthrough", "clean"], "description": "1-in / 1-out transparent wire routing dot."},
		{"op": &"terrain_bus_merge", "title": "Terrain Bus Merge", "category": "Routing & Structural", "role": "Combiner", "script": TerrainBusMergeScript, "tags": ["bus", "merge", "pack", "bundle", "channels", "multichannel"], "description": "Bundles individual height, mask, water_depth, sediment, and flow channels into a single TERRAIN_BUS connection."},
		{"op": &"terrain_bus_split", "title": "Terrain Bus Split", "category": "Routing & Structural", "role": "Filter", "script": TerrainBusSplitScript, "tags": ["bus", "split", "unpack", "unbundle", "channels", "multichannel"], "description": "Unbundles a TERRAIN_BUS wire into separate height, mask, water_depth, sediment, and flow channel outputs."},
		
		{"op": &"noise", "title": "Noise", "category": "Generators", "role": "Generator", "script": NoiseScript, "tags": ["perlin", "simplex", "fractal", "fbm", "height"], "description": "Coherent multi-octave FastNoiseLite terrain generator."},
		{"op": &"noise_jordan", "title": "Jordan Noise", "category": "Generators", "role": "Generator", "script": NoiseJordanScript, "tags": ["jordan", "derivative", "gradient", "fbm", "fluting", "warp", "ridges", "mountain"], "description": "Derivative-feedback fractal noise with slope-attenuated octave warping for natural mountain fluting."},
		{"op": &"noise_swiss", "title": "Swiss Noise", "category": "Generators", "role": "Generator", "script": NoiseSwissScript, "tags": ["swiss", "ridge", "alps", "cirque", "arete", "glacial", "mountain", "trough"], "description": "Swiss Alps ridge fractal noise with slope-dependent erosion modulation and sharp arêtes."},
		{"op": &"warp", "title": "Domain Warp", "category": "Generators", "role": "Generator", "script": WarpScript, "tags": ["warp", "distortion", "coordinate", "vector", "noise", "swirl", "meander", "folds", "glacier", "strata"], "description": "Warps coordinates with vector noise fields for swirling striations and meanders."},
		{"op": &"const", "title": "Const Float", "category": "Constants", "role": "Constant", "script": ConstScript, "tags": ["constant", "flat", "height", "value", "bias", "float"], "description": "Generates a uniform flat float height offset."},
		{"op": &"const_int", "title": "Const Int", "category": "Constants", "role": "Constant", "script": ConstIntScript, "tags": ["constant", "int", "integer", "count", "value"], "description": "Generates a discrete integer constant value."},
		{"op": &"const_vector", "title": "Const Vector", "category": "Constants", "role": "Constant", "script": ConstVectorScript, "tags": ["constant", "vector", "vec2", "direction", "offset"], "description": "Generates a 2D vector / direction constant."},
		{"op": &"const_color", "title": "Const Color", "category": "Constants", "role": "Constant", "script": ConstColorScript, "tags": ["constant", "color", "tint", "rgba", "palette"], "description": "Generates a Color constant value."},
		{"op": &"const_curve", "title": "Const Curve", "category": "Constants", "role": "Constant", "script": ConstCurveScript, "tags": ["constant", "curve", "spline", "ramp", "profile"], "description": "Provides a Curve profile resource constant."},
		{"op": &"const_bool", "title": "Const Bool", "category": "Constants", "role": "Constant", "script": ConstBoolScript, "tags": ["constant", "bool", "boolean", "toggle", "switch", "flag"], "description": "Generates a boolean true/false toggle constant."},
		{"op": &"furrows", "title": "Furrows", "category": "Generators", "role": "Generator", "script": FurrowsScript, "tags": ["ridges", "grooves", "stripes", "waves", "corrugation"], "description": "Directional corrugated ridge and furrow waves."},
		{"op": &"dunes", "title": "Dunes", "category": "Generators", "role": "Generator", "script": DunesScript, "tags": ["sand", "wind", "waves", "desert"], "description": "Asymmetric sand dune wave patterns."},
		{"op": &"crater", "title": "Crater", "category": "Generators", "role": "Generator", "script": CraterScript, "tags": ["meteor", "hole", "impact", "ring", "caldera"], "description": "Impact crater with raised rim and central cavity."},
		{"op": &"geological_primitive", "title": "Geological Primitive", "category": "Generators", "role": "Generator", "script": GeologicalPrimitiveScript, "tags": ["inselberg", "monadnock", "bornhardt", "caldera", "volcano", "dome", "cuesta", "badlands", "primitive", "landform", "macro"], "description": "Parametric macro geological landforms: solitary inselberg domes, volcanic calderas, and cuesta badland ridges."},
		{"op": &"mountain_cone", "title": "Mountain Cone", "category": "Generators", "role": "Generator", "script": MountainConeScript, "tags": ["mountain", "cone", "peak", "ridges", "alpine", "voronoi", "hesiod", "primitive"], "description": "Conical alpine mountain peak with multi-octave cellular Voronoi knife-edge ridges, strike-angle domain warping, and sigmoid envelope."},
		{"op": &"mountain_inselberg", "title": "Mountain Inselberg", "category": "Generators", "role": "Generator", "script": MountainInselbergScript, "tags": ["mountain", "inselberg", "dome", "fracture", "bedrock", "gaussian", "hesiod", "primitive"], "description": "Isolated inselberg mountain dome with Gaussian pulse envelope, fractured bedrock ridges, and bulk envelope prominence."},
		{"op": &"mountain_range_radial", "title": "Mountain Range (Radial)", "category": "Generators", "role": "Generator", "script": MountainRangeRadialScript, "tags": ["mountain", "range", "radial", "ridges", "alpine", "gabor", "hesiod", "primitive"], "description": "Radial branching alpine mountain range with tectonic axis angle spreading, Gabor wave ridgelines, and core smoothing."},
		{"op": &"mountain_tibesti", "title": "Mountain Tibesti", "category": "Generators", "role": "Generator", "script": MountainTibestiScript, "tags": ["mountain", "tibesti", "massif", "plateau", "volcanic", "gabor", "hesiod", "primitive"], "description": "Massive alpine volcanic massif / plateau with multi-octave directional Gabor ridges, simplex envelope displacement, and Gaussian pulse."},
		{"op": &"mountain_stump", "title": "Mountain Stump", "category": "Generators", "role": "Generator", "script": MountainStumpScript, "tags": ["mountain", "stump", "monadnock", "residual", "ancient", "smoothmin", "hesiod", "primitive"], "description": "Ancient eroded residual mountain stump with smooth minimum bounding and cellular knife-edge ridges."},
		{"op": &"shattered_peak", "title": "Shattered Peak", "category": "Generators", "role": "Generator", "script": ShatteredPeakScript, "tags": ["mountain", "peak", "shattered", "fracture", "fault", "fissure", "horn", "hesiod", "primitive"], "description": "Tectonically shattered alpine horn / peak with Voronoi fissure lines and bulk prominence."},
		{"op": &"caldera", "title": "Caldera", "category": "Generators", "role": "Generator", "script": CalderaScript, "tags": ["volcano", "caldera", "crater", "depression", "rim", "magma", "hesiod", "primitive"], "description": "Volcanic collapse caldera with inner exponential floor drop and outer asymptotic flank decay."},
		
		{"op": &"transform", "title": "Transform", "category": "Filters & Modifiers", "role": "Filter", "script": TransformScript, "tags": ["translate", "rotate", "zoom", "scale", "move", "offset", "pivot", "affine", "place", "coordinate", "hesiod"], "description": "Moves, rotates and scales an upstream subgraph in world XZ by resampling it through an affine."},
		{"op": &"falloff", "title": "Falloff", "category": "Filters & Modifiers", "role": "Filter", "script": FalloffScript, "tags": ["falloff", "edge", "island", "coast", "border", "distance", "attenuate", "fade", "vignette", "zeroed", "hesiod"], "description": "Fades the input toward 0 with metric distance from a world centre, for island and coastline edges."},
		{"op": &"contrast", "title": "Contrast", "category": "Filters & Modifiers", "role": "Filter", "script": ContrastScript, "tags": ["gain", "gamma", "contrast", "curve", "bias", "shaping", "punch", "flatten", "hesiod"], "description": "Gain or gamma shaping inside a height window — the input's own range by default, or explicit metres."},
		{"op": &"distance_transform", "title": "Distance Transform", "category": "Filters & Modifiers", "role": "Filter", "script": DistanceTransformScript, "tags": ["distance", "sdf", "signed", "mask", "shoreline", "bank", "verge", "proximity", "euclidean", "jfa", "hesiod"], "description": "Distance in world metres from every cell to the nearest cell of a thresholded mask."},
		{"op": &"expand_shrink", "title": "Expand / Shrink", "category": "Filters & Modifiers", "role": "Filter", "script": ExpandShrinkScript, "tags": ["dilate", "dilation", "morphology", "open", "close", "gradient", "grow", "widen", "narrow", "speckle", "cleanup", "hesiod"], "description": "Grayscale morphology over a metric radius: expand, shrink, open, close, or the morphological gradient."},
		{"op": &"relative_elevation", "title": "Relative Elevation", "category": "Filters & Modifiers", "role": "Filter", "script": RelativeElevationScript, "tags": ["relative", "prominence", "snowline", "treeline", "local", "crest", "basin", "gating", "snow", "vegetation", "hesiod"], "description": "Where a cell sits between its LOCAL basin floor and crest — gates each landform against its own base, unlike Mask (Altitude)."},
		{"op": &"smooth_fill", "title": "Smooth Fill", "category": "Filters & Modifiers", "role": "Filter", "script": SmoothFillScript, "tags": ["fill", "sediment", "valleys", "holes", "pits", "smear", "peaks", "asymmetry", "settle", "deposition", "hesiod"], "description": "Raises concave ground toward a blurred reference and leaves ridges alone, giving fBm the valley/ridge asymmetry real terrain has."},
		{"op": &"gavoronoise", "title": "Gavoronoise", "category": "Generators", "role": "Generator", "script": GavoronoiseScript, "tags": ["voronoi", "cellular", "worley", "gradient", "dendritic", "branching", "ridge", "strike", "noise", "hesiod"], "description": "Gradient-aware Voronoi. FastNoiseLite's cellular mode gives the distance field but no gradient feedback, and the feedback is what turns isotropic cell blobs into branching ridgelines that read as eroded."},
		{"op": &"warp_downslope", "title": "Warp Downslope", "category": "Filters & Modifiers", "role": "Filter", "script": WarpDownslopeScript, "tags": ["warp", "downslope", "gradient", "drag", "smear", "fluvial", "erosion", "transport", "hesiod"], "description": "Drags the surface along its own gradient. Unlike Warp, which distorts with noise in directions unrelated to the terrain, this moves material the way it actually travels — downhill."},
		{"op": &"flooding_uniform_level", "title": "Flooding Uniform Level", "category": "Filters & Modifiers", "role": "Filter", "script": FloodingUniformLevelScript, "tags": ["water", "flood", "sea", "lake", "level", "depth", "shore", "hesiod"], "description": "Floods the surface up to a uniform world-Y level, publishing height, depth and mask. Unlike Lake Flooding it does not solve for basins or spawn a water body — it is a comparison against a plane, and it is cheap."},
		{"op": &"water_mask", "title": "Water Mask", "category": "Masks", "role": "Filter", "script": WaterMaskScript, "tags": ["water", "shore", "beach", "coast", "mask", "distance", "waterline", "hesiod"], "description": "The submerged mask plus a shore band a fixed number of METRES either side of the waterline. Thresholding a depth is one line of Remap; a beach that stays eight metres wide at every bake resolution needs the signed distance transform."},
		{"op": &"mudslide", "title": "Mudslide", "category": "Solvers", "role": "Solver", "script": MudslideScript, "tags": ["mudslide", "landslide", "slump", "scar", "debris", "talus", "mass wasting", "hesiod"], "description": "Moves a finite, maskable depth of material downhill until it is spent. Unlike Talus Projection or Thermal Erosion, which relax slope everywhere with no budget, this is the node for one scar on a hillside you chose."},
		{"op": &"recast_cliff", "title": "Recast Cliff", "category": "Filters & Modifiers", "role": "Filter", "script": RecastCliffScript, "tags": ["cliff", "escarpment", "steep", "face", "talus", "slope", "stepped", "directional", "hesiod"], "description": "Pushes ground steeper than the talus angle into a stepped face. Quantises on SLOPE, where Terrace and Strata quantise on height."},
		{"op": &"smooth", "title": "Smooth", "category": "Filters & Modifiers", "role": "Filter", "script": SmoothScript, "tags": ["blur", "gaussian", "average", "filter", "soften"], "description": "Smooths / blurs terrain height variations."},
		{"op": &"talus_projection", "title": "Talus Projection", "category": "Filters & Modifiers", "role": "Filter", "script": TalusProjectionScript, "tags": ["talus", "scree", "repose", "cliff", "relaxation", "slope", "angle", "apron", "rubble"], "description": "Relaxes slopes exceeding a critical angle of repose to deposit natural scree aprons."},
		{"op": &"spectral_equalizer", "title": "Spectral Equalizer", "category": "Filters & Modifiers", "role": "Filter", "script": SpectralEqualizerScript, "tags": ["spectral", "equalizer", "frequency", "macro", "meso", "micro", "laplacian", "pyramid", "filter", "detail"], "description": "3-band spatial frequency equalizer for macro mountain mass, meso ridges, and micro crags."},
		{"op": &"depression_filling", "title": "Depression Filling", "category": "Filters & Modifiers", "role": "Filter", "script": DepressionFillingScript, "tags": ["depression", "filling", "sink", "pit", "spillway", "planchon", "darboux", "priority", "flood", "hydrology"], "description": "Fills enclosed pits and sinks up to their spillway elevation for monotonic drainage routing."},
		{"op": &"terrace", "title": "Terrace", "category": "Filters & Modifiers", "role": "Filter", "script": TerraceScript, "tags": ["steps", "bands", "quantize", "contour", "ledges"], "description": "Quantizes elevation into stepped terraces."},
		{"op": &"strata", "title": "Strata", "category": "Filters & Modifiers", "role": "Filter", "script": StrataScript, "tags": ["layers", "geology", "bands", "sediment", "dip", "strike", "cliff"], "description": "Applies tilted geological sedimentary layering to slopes."},
		{"op": &"curve", "title": "Curve", "category": "Filters & Modifiers", "role": "Filter", "script": CurveScript, "tags": ["remap", "ramp", "profile", "transfer", "shaping", "spline"], "description": "Remaps input heights through a custom Curve resource."},
		{"op": &"remap", "title": "Remap", "category": "Filters & Modifiers", "role": "Filter", "script": RemapScript, "tags": ["remap", "range", "clamp", "softknee", "invert", "scale", "normalize", "shaping"], "description": "Linearly remaps elevation ranges with soft-knee clamping and inversion."},
		{"op": &"mask", "title": "Mask", "category": "Filters & Modifiers", "role": "Filter", "script": MaskScript, "tags": ["selector", "slope", "altitude", "weight", "gate"], "description": "Gates height by slope, elevation, or curvature masks."},
		{"op": &"curvature", "title": "Curvature Mask", "category": "Filters & Modifiers", "role": "Filter", "script": CurvatureScript, "tags": ["curvature", "convexity", "concavity", "ridge", "valley", "basin", "laplacian", "hessian", "mask", "crests"], "description": "Calculates local terrain convexity/concavity to mask mountain ridges vs valley basins."},
		
		{"op": &"blend", "title": "Blend", "category": "Math & Combiners", "role": "Combiner", "script": BlendScript, "tags": ["math", "add", "sub", "mul", "max", "min", "combine", "mix"], "description": "Combines two input heightfields with math blend modes."},
		
		{"op": &"lake_flooding", "title": "Lake Flooding", "category": "Solvers & Realism", "role": "Solver", "script": LakeFloodingScript, "tags": ["lake", "pond", "water", "basin", "flood", "spillway", "depth", "shoreline", "pool", "hydrology"], "description": "Floods closed basins or fills water levels; outputs lake surface + water depth + shoreline masks and spawns Pasture3DPond bodies."},
		{"op": &"stream_extraction", "title": "Stream Extraction", "category": "Solvers & Realism", "role": "Solver", "script": StreamExtractionScript, "tags": ["stream", "river", "thalweg", "drainage", "catchment", "flow", "runoff", "channel", "carve", "hydrology"], "description": "Calculates surface runoff drainage accumulation, carves riverbeds, and spawns Pasture3DStream splines."},
		{"op": &"erosion_hydraulic", "title": "Hydraulic Erosion", "category": "Solvers & Realism", "role": "Solver", "script": ErosionHydraulicScript, "tags": ["hydraulic", "erosion", "rain", "fluvial", "water", "flow", "sediment", "deposition", "channel", "meander"], "description": "Simulates continuous rainfall, water routing, sediment pickup, transport, and deposition."},
		{"op": &"hydraulic_particle", "title": "Particle Hydraulic Erosion", "category": "Solvers & Realism", "role": "Solver", "script": HydraulicParticleScript, "tags": ["particle", "droplet", "lagrangian", "hydraulic", "erosion", "rain", "sediment", "deposition", "hesiod"], "description": "Eulerian-Lagrangian particle droplet simulation with momentum, velocity, capacity, and sediment transport."},
		{"op": &"hydraulic_stream_log", "title": "Logarithmic Stream Erosion", "category": "Solvers & Realism", "role": "Solver", "script": HydraulicStreamLogScript, "tags": ["stream", "logarithmic", "power", "incision", "river", "channel", "catchment", "fluvial", "hesiod"], "description": "Logarithmic stream-power riverbed incision: E = K * log(1 + A^m * S^n), preventing runaway gorge blowouts."},
		{"op": &"hydraulic_saleve", "title": "Salève Hydraulic Erosion", "category": "Solvers & Realism", "role": "Solver", "script": HydraulicSaleveScript, "tags": ["saleve", "joint", "fracture", "ridge", "curvature", "sediment", "hydraulic", "erosion", "hesiod"], "description": "Salève structural model with joint-aligned runoff, ridge crest curvature preservation, and sediment settling."},
		{"op": &"erosion_thermal", "title": "Thermal Erosion", "category": "Solvers & Realism", "role": "Solver", "script": ErosionThermalScript, "tags": ["thermal", "erosion", "talus", "scree", "weathering", "cliff", "repose", "slippage", "rock"], "description": "Simulates rock weathering and gravitational talus scree accumulation along steep slopes."},
		{"op": &"scree", "title": "Scree", "category": "Solvers & Realism", "role": "Solver", "script": ScreeScript, "tags": ["talus", "rubble", "rock", "slope", "erosion", "deposition"], "description": "Sheds loose rock off steep ground; outputs height + a shed mask."},
		{"op": &"erosion", "title": "Erosion", "category": "Solvers & Realism", "role": "Solver", "script": ErosionScript, "tags": ["river", "fluvial", "stream", "hydraulic", "water", "valley", "channel", "sediment"], "description": "Stream-power fluvial erosion; outputs eroded height + flow / erosion / deposition / wetness channels."},
		{"op": &"dla", "title": "DLA", "category": "Solvers & Realism", "role": "Solver", "script": DLAScript, "tags": ["mountain", "ridge", "massif", "aggregation", "diffusion", "branch", "peak", "range"], "description": "Diffusion-limited-aggregation mountain; grows a branching ridge massif, outputs height + a footprint mask."},
	]

	if p_include_dev or is_dev_nodes_enabled():
		list.append_array(_dev_entries())

	return list


## Dedicated developer / reference oracle entries.
static func _dev_entries() -> Array[Dictionary]:
	return [
		{"op": &"dev_erosion_hydraulic", "title": "[Dev/GD] Hydraulic Erosion", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevErosionHydraulicScript, "tags": ["dev", "gdscript", "oracle", "hydraulic", "erosion"], "description": "Pure GDScript reference oracle for hydraulic erosion simulation."},
		{"op": &"dev_hydraulic_particle", "title": "[Dev/GD] Particle Hydraulic Erosion", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevHydraulicParticleScript, "tags": ["dev", "gdscript", "oracle", "particle", "droplet", "hydraulic", "erosion"], "description": "Pure GDScript reference oracle for particle hydraulic droplet erosion."},
		{"op": &"dev_hydraulic_stream_log", "title": "[Dev/GD] Logarithmic Stream Erosion", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevHydraulicStreamLogScript, "tags": ["dev", "gdscript", "oracle", "stream", "logarithmic", "power", "incision"], "description": "Pure GDScript reference oracle for logarithmic stream-power erosion."},
		{"op": &"dev_hydraulic_saleve", "title": "[Dev/GD] Salève Hydraulic Erosion", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevHydraulicSaleveScript, "tags": ["dev", "gdscript", "oracle", "saleve", "joint", "ridge", "hydraulic", "erosion"], "description": "Pure GDScript reference oracle for Salève structural hydraulic erosion."},
		{"op": &"dev_erosion_thermal", "title": "[Dev/GD] Thermal Erosion", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevErosionThermalScript, "tags": ["dev", "gdscript", "oracle", "thermal", "erosion", "talus"], "description": "Pure GDScript reference oracle for thermal weathering & talus scree erosion."},
		{"op": &"dev_depression_filling", "title": "[Dev/GD] Depression Filling", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevDepressionFillingScript, "tags": ["dev", "gdscript", "oracle", "depression", "sink", "priority", "flood"], "description": "Pure GDScript reference oracle for Priority-Flood depression filling."},
		{"op": &"dev_lake_flooding", "title": "[Dev/GD] Lake Flooding", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevLakeFloodingScript, "tags": ["dev", "gdscript", "oracle", "lake", "pond", "water", "flood"], "description": "Pure GDScript reference oracle for lake flooding and shoreline extraction."},
		{"op": &"dev_stream_extraction", "title": "[Dev/GD] Stream Extraction", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevStreamExtractionScript, "tags": ["dev", "gdscript", "oracle", "stream", "river", "thalweg", "flow"], "description": "Pure GDScript reference oracle for stream extraction and thalweg routing."},
		{"op": &"dev_spectral_equalizer", "title": "[Dev/GD] Spectral Equalizer", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevSpectralEqualizerScript, "tags": ["dev", "gdscript", "oracle", "spectral", "equalizer", "frequency", "blur"], "description": "Pure GDScript reference oracle for 3-band spatial spectral equalizer."},
		{"op": &"dev_transform", "title": "[Dev/GD] Transform", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevTransformScript, "tags": ["dev", "gdscript", "oracle", "transform", "affine", "bilinear", "resample"], "description": "Pure GDScript reference oracle for the Transform affine resample."},
		{"op": &"dev_distance_transform", "title": "[Dev/GD] Distance Transform", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevDistanceTransformScript, "tags": ["dev", "gdscript", "oracle", "distance", "jfa", "jump", "flooding"], "description": "Pure GDScript reference oracle for the distance transform. Runs jump flooding, matching the native kernel rather than being exact."},
		{"op": &"dev_expand_shrink", "title": "[Dev/GD] Expand / Shrink", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevExpandShrinkScript, "tags": ["dev", "gdscript", "oracle", "morphology", "dilate", "erode"], "description": "Pure GDScript reference oracle for grayscale morphology. The naive O(r^2) gather, on purpose."},
		{"op": &"dev_gavoronoise", "title": "[Dev/GD] Gavoronoise", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevGavoronoiseScript, "tags": ["dev", "gdscript", "oracle", "voronoi", "gavoronoise"], "description": "Pure GDScript reference oracle for Gavoronoise. A generator with derivative feedback has no closed form to check against, so the specification is written out a second time and compared."},
		{"op": &"dev_warp_downslope", "title": "[Dev/GD] Warp Downslope", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevWarpDownslopeScript, "tags": ["dev", "gdscript", "oracle", "warp", "downslope", "gradient"], "description": "Pure GDScript reference oracle for Warp Downslope. Reuses the Phase 3 oracle's box mean so the blur the gradient is read from cannot drift."},
		{"op": &"dev_flooding_uniform_level", "title": "[Dev/GD] Flooding Uniform Level", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevFloodingUniformLevelScript, "tags": ["dev", "gdscript", "oracle", "water", "flood"], "description": "Pure GDScript reference oracle for Flooding Uniform Level. The arithmetic is trivial; what it pins is that a NaN cell stays absent in the height, the depth and the mask alike."},
		{"op": &"dev_water_mask", "title": "[Dev/GD] Water Mask", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevWaterMaskScript, "tags": ["dev", "gdscript", "oracle", "water", "shore"], "description": "Pure GDScript reference oracle for Water Mask. Reuses the Phase 2 distance-transform oracle so the two cannot disagree about what a metre is."},
		{"op": &"dev_mudslide", "title": "[Dev/GD] Mudslide", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevMudslideScript, "tags": ["dev", "gdscript", "oracle", "mudslide", "landslide"], "description": "Pure GDScript reference oracle for Mudslide. Delta-accumulated like the kernel: an in-place scatter would have been shorter and would have been a different, order-dependent algorithm."},
		{"op": &"dev_terrain_metrics", "title": "[Dev/GD] Terrain Metrics", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevTerrainMetricsScript, "tags": ["dev", "gdscript", "oracle", "relative", "elevation", "smooth", "fill", "cliff", "recast"], "description": "Pure GDScript reference oracle for all three Phase 3 nodes. One file, so the shared box mean and metre-to-cell conversion cannot drift between them."},
		{"op": &"dev_talus_projection", "title": "[Dev/GD] Talus Projection", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevTalusProjectionScript, "tags": ["dev", "gdscript", "oracle", "talus", "scree", "repose"], "description": "Pure GDScript reference oracle for talus projection slope relaxation."},
		{"op": &"dev_curvature", "title": "[Dev/GD] Curvature Mask", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevCurvatureScript, "tags": ["dev", "gdscript", "oracle", "curvature", "convexity", "concavity", "ridge"], "description": "Pure GDScript reference oracle for discrete Laplacian curvature."},
		{"op": &"dev_warp", "title": "[Dev/GD] Domain Warp", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevWarpScript, "tags": ["dev", "gdscript", "oracle", "warp", "distortion", "noise"], "description": "Pure GDScript reference oracle for domain warp coordinate distortion."},
		{"op": &"dev_erosion", "title": "[Dev/GD] Erosion", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevErosionScript, "tags": ["dev", "gdscript", "oracle", "erosion", "river", "fluvial"], "description": "Reference dev erosion node."},
		{"op": &"dev_dla", "title": "[Dev/GD] DLA", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevDLAScript, "tags": ["dev", "gdscript", "oracle", "dla", "mountain", "massif"], "description": "Pure GDScript reference oracle for DLA massif generation."},
		{"op": &"dev_mountain_cone", "title": "[Dev/GD] Mountain Cone", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevMountainConeScript, "tags": ["dev", "gdscript", "oracle", "mountain", "cone", "alpine", "ridges"], "description": "Pure GDScript reference oracle for MountainCone primitive."},
		{"op": &"dev_mountain_inselberg", "title": "[Dev/GD] Mountain Inselberg", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevMountainInselbergScript, "tags": ["dev", "gdscript", "oracle", "mountain", "inselberg", "dome"], "description": "Pure GDScript reference oracle for MountainInselberg primitive."},
		{"op": &"dev_mountain_range_radial", "title": "[Dev/GD] Mountain Range (Radial)", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevMountainRangeRadialScript, "tags": ["dev", "gdscript", "oracle", "mountain", "range", "radial", "gabor"], "description": "Pure GDScript reference oracle for MountainRangeRadial primitive."},
		{"op": &"dev_mountain_tibesti", "title": "[Dev/GD] Mountain Tibesti", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevMountainTibestiScript, "tags": ["dev", "gdscript", "oracle", "mountain", "tibesti", "massif", "volcanic"], "description": "Pure GDScript reference oracle for MountainTibesti primitive."},
		{"op": &"dev_mountain_stump", "title": "[Dev/GD] Mountain Stump", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevMountainStumpScript, "tags": ["dev", "gdscript", "oracle", "mountain", "stump", "residual"], "description": "Pure GDScript reference oracle for MountainStump primitive."},
		{"op": &"dev_shattered_peak", "title": "[Dev/GD] Shattered Peak", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevShatteredPeakScript, "tags": ["dev", "gdscript", "oracle", "mountain", "peak", "shattered", "fracture"], "description": "Pure GDScript reference oracle for ShatteredPeak primitive."},
		{"op": &"dev_caldera", "title": "[Dev/GD] Caldera", "category": "Dev / Reference", "role": "Dev / Reference", "script": DevCalderaScript, "tags": ["dev", "gdscript", "oracle", "volcano", "caldera", "crater", "depression"], "description": "Pure GDScript reference oracle for Caldera primitive."},
	]


## Returns a Dictionary mapping category name (String) to Array[Dictionary] of entries.
static func entries_by_category(p_include_dev: bool = false) -> Dictionary:
	var result: Dictionary = {}
	for cat in categories():
		result[cat] = []
	for e in entries(p_include_dev):
		var cat: String = e.get("category", "Generators")
		if not result.has(cat):
			result[cat] = []
		(result[cat] as Array).append(e)
	return result


## A fresh node for `p_op`, or null if the op is unknown.
## Searches both standard and dev entries so saved graphs or test harnesses can instantiate by op.
static func create(p_op: StringName) -> Pasture3DGraphNode:
	for e in entries(true):
		if e["op"] == p_op:
			return (e["script"] as GDScript).new()
	return null


## Searches palette entries matching `p_query` by title, op, role, category, or tags.
static func search(p_query: String, p_include_dev: bool = false) -> Array[Dictionary]:
	var q := p_query.strip_edges().to_lower()
	var all_entries := entries(p_include_dev)
	if q.is_empty():
		return all_entries

	var exact_matches: Array[Dictionary] = []
	var partial_matches: Array[Dictionary] = []
	var tag_matches: Array[Dictionary] = []

	for e in all_entries:
		var title: String = String(e.get("title", "")).to_lower()
		var op_str: String = String(e.get("op", "")).to_lower()
		var role_str: String = String(e.get("role", "")).to_lower()
		var cat_str: String = String(e.get("category", "")).to_lower()
		var tags: Array = e.get("tags", [])

		if title == q or op_str == q:
			exact_matches.append(e)
		elif title.begins_with(q) or op_str.begins_with(q):
			partial_matches.append(e)
		elif title.contains(q) or op_str.contains(q) or role_str.contains(q) or cat_str.contains(q):
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
