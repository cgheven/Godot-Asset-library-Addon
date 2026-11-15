@tool
extends EditorExportPlugin
## Keeps CGHEVEN download baggage OUT of exported games.
##
## Files under res://CGHEVEN/ are skipped at export time when they are:
##   1. anything in res://CGHEVEN/_sources/  (optional reference copies the addon makes - never
##      referenced by a scene), or
##   2. a format Godot cannot use at runtime at all (video such as .mp4/.mov, archives, VDB).
##      Older addon versions copied these into the project; they could only ever add weight.
## 3D models, textures and anything else a scene may reference are NEVER skipped, so a game that
## uses a CGHEVEN asset keeps working.

# The editor addon itself is dev-time only: never ship its ~45 scripts inside a player's game.
const ADDON := "res://addons/cgheven/"
const ROOT := "res://CGHEVEN/"
const SOURCES := "res://CGHEVEN/_sources/"
const UNUSABLE_EXT := ["mp4", "mov", "avi", "mkv", "m4v", "mxf", "wmv", "zip", "rar", "7z", "tar", "gz", "vdb"]

func _get_name() -> String:
	return "CGHEVENExportFilter"

func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(ADDON):
		skip()
		return
	if not path.begins_with(ROOT):
		return
	if path.begins_with(SOURCES) or path.get_extension().to_lower() in UNUSABLE_EXT:
		skip()
