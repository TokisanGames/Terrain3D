# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
#
# Pasture3DRoadType — a shared road specification: "Country Lane", "Gravel Track", "Motorway". One
# resource is used by forty stretches of road, so changing the lane width of every country lane in the
# world is one edit. See PASTURE3D_ROAD_SYSTEM_PROPOSAL.md §4.3.
#
# A type is the LAST link in the resolve chain (§5.3): where Segment / Brush / Group / Network all
# decline to have an opinion, the type answers. That is why the fields here are plain values with real
# defaults rather than the sentinels Pasture3DRoadOverrides uses — a type always has an opinion.
#
# WHAT IS AND IS NOT HERE. The cross-section, the earthworks and the alignment constraints are here
# because they are properties of a KIND of road. What a particular stretch does — this bit is a bridge,
# this bit turns to gravel — belongs on a Pasture3DRoadSegment override, not on a new type.
@tool
class_name Pasture3DRoadType
extends Resource

## Painted line down the middle. Cosmetic in P0; drives the marking pass in P5.
enum DividerType { NONE, SINGLE_DASHED, SINGLE_SOLID, DOUBLE_SOLID, DASHED_SOLID }

@export_group("Identity")
## Shown in pickers and in the RoadNetwork catalogue. Distinct from `resource_name` only in that it is
## meant to be read by a designer choosing a road, not by the inspector labelling a row.
@export var type_name: String = "Road":
	set(v):
		type_name = v
		resource_name = v
		emit_changed()

## Which type wins where two roads meet. Higher takes precedence, and it decides THREE things, not one
## (§5.2): the road type an intersection adopts, whose terrain paint survives where two footprints
## overlap, and — the one that most affects how a junction reads — which road keeps its solved vertical
## alignment through the junction while the other bends to meet it. A paved road outranks a dirt track.
@export var priority: int = 0:
	set(v):
		priority = v
		emit_changed()

@export_group("Cross-section")
## Width of ONE lane, metres. The carriageway is `lane_count * lane_width`.
@export var lane_width: float = 3.5:
	set(v):
		lane_width = maxf(v, 0.5)
		emit_changed()

## Default lanes, used where no level of the hierarchy overrides `lane_count`.
@export var lane_count: int = 2:
	set(v):
		lane_count = maxi(v, 1)
		emit_changed()

## Sealed strip outside the outermost lane, each side, metres.
@export var shoulder_width: float = 0.5:
	set(v):
		shoulder_width = maxf(v, 0.0)
		emit_changed()

## Centre camber: how much higher the crown sits than the carriageway edge, metres. Sheds water, and is
## the reason a road reads as built rather than extruded.
@export var crown: float = 0.05:
	set(v):
		crown = maxf(v, 0.0)
		emit_changed()

@export var divider_type: DividerType = DividerType.SINGLE_DASHED:
	set(v):
		divider_type = v
		emit_changed()

@export_group("Verge props")
## Mesh asset id in the terrain's asset list, placed repeatedly along both verges (§10, P5c). -1 means
## this road has no verge props — the same "-1 is not an index, it is a refusal" convention `surface_layer_id`
## uses, and for the same reason: an id field with no off value forces every road to place SOMETHING.
@export var prop_mesh_id: int = -1:
	set(v):
		prop_mesh_id = maxi(v, -1)
		emit_changed()

## Metres between props along the road. Absolute arc length, so chunking cannot move them.
@export var prop_spacing: float = 25.0:
	set(v):
		prop_spacing = maxf(v, 0.25)
		emit_changed()

## Where the props stand, as distance from the road CENTRE in metres. Measured from the centre rather
## than from the edge so it does not silently move when the lane count is overridden part way along a
## road — a marker post does not step outwards where a climbing lane starts.
@export var prop_offset: float = 5.0:
	set(v):
		prop_offset = maxf(v, 0.0)
		emit_changed()

## Place them on both verges. Off puts them only on the driver's right.
@export var prop_both_sides: bool = true:
	set(v):
		prop_both_sides = v
		emit_changed()


@export_group("Alignment")
## The HARD constraint on the P1 vertical solver: the steepest gradient this kind of road will accept,
## as a rise/run ratio. A dirt track climbs what a motorway will not, and this one number is most of
## what makes the two route differently across the same hill.
@export_range(0.005, 0.5, 0.005) var max_grade: float = 0.08:
	set(v):
		max_grade = clampf(v, 0.005, 0.5)
		emit_changed()

## Ceiling on banking through a corner, as a rise/run ratio across the carriageway. ~0.06 is a public
## road; a banked oval runs several times that.
@export_range(0.0, 0.5, 0.005) var max_superelevation: float = 0.06:
	set(v):
		max_superelevation = clampf(v, 0.0, 0.5)
		emit_changed()

## Speed the banking is computed FOR, m/s (bank = v²·κ/g). Not a speed limit — it is the design
## assumption baked into the geometry, and a road banked for 30 m/s stays banked for 30 whatever the
## signs say. `Pasture3DRoadOverrides.speed_limit` is the signposted number.
@export var design_speed: float = 25.0:
	set(v):
		design_speed = maxf(v, 1.0)
		emit_changed()

@export_group("Earthworks")
## Slope of the batter where the road CUTS into rising ground, rise/run. Steeper than fill: cut faces
## stand in material that is already consolidated.
@export var cut_batter: float = 1.0:
	set(v):
		cut_batter = maxf(v, 0.05)
		emit_changed()

## Slope of the embankment where the road FILLS a dip, rise/run. Shallower than cut — loose material
## will not hold a steep face.
@export var fill_batter: float = 0.6:
	set(v):
		fill_batter = maxf(v, 0.05)
		emit_changed()

## Metres over which the earthworks blend back into untouched terrain. Also the outer bound of the
## corridor a rally stage counts as "still on the road" (§9.3).
@export var verge_width: float = 4.0:
	set(v):
		verge_width = maxf(v, 0.0)
		emit_changed()

@export_group("Surface")
## Physics surface published to consumers: &"tarmac", &"gravel", &"snow", &"dirt". A StringName rather
## than an enum so a project can add its own without editing the addon.
@export var surface_id: StringName = &"tarmac":
	set(v):
		surface_id = v
		emit_changed()

## Terrain texture layer the carriageway paints into at bake (P5). -1 = do not paint.
@export var surface_layer_id: int = -1:
	set(v):
		surface_layer_id = v
		emit_changed()

## Material for the ribbon mesh (P5).
@export var surface_material: Material = null:
	set(v):
		surface_material = v
		emit_changed()


## Half the sealed width, metres — carriageway plus both shoulders, halved. The figure the grader and
## the mesher both start from.
func half_width(p_lane_count: int = -1) -> float:
	var lanes := p_lane_count if p_lane_count > 0 else lane_count
	return (float(lanes) * lane_width) * 0.5 + shoulder_width


## Total width the road disturbs, metres: the sealed surface plus a verge each side. The footprint a
## brush has to reserve, and the outer edge of the rally corridor.
func disturbed_width(p_lane_count: int = -1) -> float:
	return (half_width(p_lane_count) + shoulder_width + verge_width) * 2.0
