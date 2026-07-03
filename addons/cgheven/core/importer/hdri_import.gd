@tool
extends RefCounted
class_name CghHdriImport
## Sets the scene's world environment from an equirectangular HDRI.
## Builds WorldEnvironment → Environment(BG_SKY) → Sky → PanoramaSkyMaterial,
## with ambient + reflections taken from the sky (official Godot sky workflow).
## Reuses an existing WorldEnvironment if the scene already has one (Godot allows
## only one active per scene tree). HDRIs are served as .exr (load_exr_from_buffer).

static func apply_as_world(exr_path: String) -> WorldEnvironment:
	var img := Image.new()
	var ext := exr_path.get_extension().to_lower()
	var ok: int = img.load_exr_from_buffer(FileAccess.get_file_as_bytes(exr_path)) if ext == "exr" \
		else img.load(exr_path)
	if ok != OK:
		push_error("[CGHEVEN] Could not load HDRI: " + exr_path)
		return null
	var tex := ImageTexture.create_from_image(img)

	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = tex
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	var edited := EditorInterface.get_edited_scene_root()
	if edited == null:
		push_warning("[CGHEVEN] No open scene — WorldEnvironment created but not added.")
		var orphan := WorldEnvironment.new()
		orphan.environment = env
		return orphan

	# Reuse an existing WorldEnvironment (only one may be active per scene tree).
	var existing := edited.find_children("*", "WorldEnvironment", true, false)
	var we: WorldEnvironment
	if existing.is_empty():
		we = WorldEnvironment.new()
		we.name = "WorldEnvironment"
		edited.add_child(we)
		we.owner = edited
	else:
		we = existing[0]
	we.environment = env
	return we
