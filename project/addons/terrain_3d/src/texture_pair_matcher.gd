# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Matches albedo texture files to their normal map sibling by filename convention
extends RefCounted
class_name Terrain3DTexturePairMatcher

# Role tokens are matched as whole underscore-delimited segments, wherever they occur in the
# filename -- e.g. both "rock_albedo.png" (role at the end) and "rock_packed_albedo_height.png"
# (role in the middle, followed by extra channel info) are recognized.
const ALBEDO_KEYWORDS: PackedStringArray = [
	"albedo", "basecolor", "diffuse", "diff", "color", "col",
]
const NORMAL_KEYWORDS: PackedStringArray = [ "normal", "nrm", "norm", "n", "nml" ]

# Matches the extensions accepted by channel_packer_dragdrop.gd
const IMAGE_EXTENSIONS: PackedStringArray = [
	"png", "bmp", "exr", "hdr", "jpg", "jpeg", "tga", "svg", "webp", "ktx", "dds",
]


# Splits a filename stem into lowercase underscore-delimited segments, normalizing the
# two-segment "base_color" spelling to the single token "basecolor" first.
static func _segments(p_stem: String) -> PackedStringArray:
	var normalized: String = p_stem.to_lower().replace("base_color", "basecolor")
	return normalized.split("_")


# Returns the index of the first segment matching a keyword in p_keywords, or -1.
static func _find_role_index(p_segments: PackedStringArray, p_keywords: PackedStringArray) -> int:
	for i in p_segments.size():
		if p_keywords.has(p_segments[i]):
			return i
	return -1


# Returns true if any segment of p_path's filename matches a keyword in p_keywords.
static func _has_role(p_path: String, p_keywords: PackedStringArray) -> bool:
	return _find_role_index(_segments(p_path.get_file().get_basename()), p_keywords) != -1


# Returns a directory+prefix key with the role token and everything after it stripped, so that
# "dir/rock_packed_albedo_height" and "dir/rock_packed_normal_roughness" both normalize to
# "dir/rock_packed". Files with no recognized role token return their full stem unchanged.
static func _base_key(p_path: String) -> String:
	var dir: String = p_path.get_base_dir()
	var segments: PackedStringArray = _segments(p_path.get_file().get_basename())
	var role_index: int = _find_role_index(segments, ALBEDO_KEYWORDS)
	if role_index == -1:
		role_index = _find_role_index(segments, NORMAL_KEYWORDS)
	if role_index == -1:
		return dir.path_join("_".join(segments))
	return dir.path_join("_".join(segments.slice(0, role_index)))


# Given an absolute/res:// path to an albedo image, looks in the same directory for a sibling
# file that shares its base key and carries a normal-map role token. Returns the sibling path,
# or "" if none is found.
static func find_normal_sibling(p_albedo_path: String) -> String:
	var dir_path: String = p_albedo_path.get_base_dir()
	var dir: DirAccess = DirAccess.open(dir_path)
	if not dir:
		return ""

	var target_key: String = _base_key(p_albedo_path)
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and IMAGE_EXTENSIONS.has(file_name.get_extension().to_lower()):
			var candidate_path: String = dir_path.path_join(file_name)
			if candidate_path != p_albedo_path \
					and _base_key(candidate_path) == target_key \
					and _has_role(candidate_path, NORMAL_KEYWORDS):
				dir.list_dir_end()
				return candidate_path
		file_name = dir.get_next()
	dir.list_dir_end()
	return ""


# Given the albedo-column and normal-column file lists from the pair import dialog, pairs them
# up by matching base key. Unlike find_normal_sibling(), the column a file was dropped into is
# always authoritative for its role -- filenames are only used to decide which albedo/normal go
# together, never to reclassify a file dropped into the "wrong" column.
# Returns Array[Dictionary], each {"albedo": String, "normal": String} (either may be "").
static func pair_lists(p_albedo_files: PackedStringArray, p_normal_files: PackedStringArray) -> Array[Dictionary]:
	var normal_by_key: Dictionary = {} # base_key -> normal file path
	for file in p_normal_files:
		normal_by_key[_base_key(file)] = file

	var pairs: Array[Dictionary] = []
	var consumed_keys: Dictionary = {}
	for file in p_albedo_files:
		var key: String = _base_key(file)
		var normal_path: String = ""
		if normal_by_key.has(key):
			normal_path = normal_by_key[key]
			consumed_keys[key] = true
		pairs.push_back({ "albedo": file, "normal": normal_path })

	for file in p_normal_files:
		if not consumed_keys.has(_base_key(file)):
			pairs.push_back({ "albedo": "", "normal": file })

	return pairs
