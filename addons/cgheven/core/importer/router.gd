@tool
extends RefCounted
class_name CghImportRouter
## Routes a downloaded file to the right importer. CRITICAL: it routes by the
## asset's CATEGORY first, not just the extension — an `.exr` can be EITHER an
## HDRI panorama (hdri category) OR a flipbook sprite-sheet (flipbooks category),
## so extension alone is ambiguous and used to send flipbook .exr sheets to the
## HDRI importer (sky), which is why flipbooks "imported but never played".
##
## After a successful live-instance into the open scene, the source file is ALSO
## copied into res://CGHEVEN/<category>/ so it shows up in the FileSystem dock and
## the user can find / reuse it (Godot only imports files that live under res://).

const RES_ROOT := "res://CGHEVEN"

# Model formats Godot's EDITOR can import (into a PackedScene, or a Mesh for .obj) — far
# more than the runtime GLTFDocument path, which only handles glTF. Order = most reliable
# first (used to pick the best model inside a zip, like the Blender addon's priority).
const EDITOR_MODEL_PRIORITY := ["glb", "gltf", "fbx", "dae", "obj"]

static func import_file(path: String, category_slug: String) -> String:
	var ext := path.get_extension().to_lower()

	# unpack archives first, then re-route on the inner importable file
	if ext == "zip":
		var inner := _extract_zip(path)
		if inner == "":
			return "Extracted zip, but found no importable file inside."
		return import_file(inner, category_slug)

	var cat := category_slug.to_lower()
	var msg := ""
	# Category decides intent. Fall back to extension when the category is unknown.
	if cat == "flipbooks":
		msg = _do_flipbook(path)
	elif cat == "hdri":
		msg = _do_hdri(path)
	elif cat == "3d-models":
		msg = _do_3d(path)
	elif ext in CghConfig.EXT_3D:
		msg = _do_3d(path)
	elif ext in CghConfig.EXT_HDRI:
		msg = _do_hdri(path)
	elif ext in CghConfig.EXT_IMAGE:
		msg = _do_flipbook(path)
	else:
		# Not auto-importable — still drop it in the project so the user has it.
		var rp0 := copy_into_project(path, cat)
		return "Saved to %s (no auto-import for .%s)." % [rp0, ext] if rp0 != "" else \
			"Downloaded to %s (no auto-import for .%s)." % [path, ext]

	# Copy a reusable source into the project (FileSystem dock) and tell the user.
	var rp := copy_into_project(path, cat)
	if rp != "":
		msg += " Saved in %s/" % rp.get_base_dir()
	return msg

# ---------------- per-type importers ----------------
static func _do_flipbook(path: String) -> String:
	var hv := _flipbook_grid(path)
	var spr := CghFlipbookImport.from_sheet(path, hv.x, hv.y)
	if spr == null:
		if path.get_extension().to_lower() == "exr":
			return "Flipbook import failed — this .exr uses a compression Godot can't read. Pick the PNG version from the ▾ menu."
		return "Flipbook import failed."
	if hv == Vector2i(1, 1):
		return "Flipbook added (single frame — grid NxM not in filename, can't auto-play)."
	return "Flipbook added & playing (%dx%d grid)." % [hv.x, hv.y]

static func _do_hdri(path: String) -> String:
	var we := CghHdriImport.apply_as_world(path)
	return "HDRI applied as the scene's world/sky." if we else \
		"HDRI import failed — this .exr uses a compression Godot can't read (e.g. DWAA/PXR24). Try another HDRI."

static func _do_3d(path: String) -> String:
	var ext := path.get_extension().to_lower()
	var n: Node = _import_fbx(path) if ext == "fbx" else CghGltfImport.import_into_scene(path)
	return "3D model added to the scene." if n else "3D import failed (open a scene first?)."

static func _import_fbx(path: String) -> Node:
	# ufbx (4.3+) — FBXDocument mirrors GLTFDocument
	var doc := FBXDocument.new()
	var state := FBXState.new()
	if doc.append_from_file(path, state) != OK:
		return null
	var root := doc.generate_scene(state)
	var edited := EditorInterface.get_edited_scene_root()
	if edited and root:
		edited.add_child(root)
		root.owner = edited
		for c in root.find_children("*", "", true, false):
			c.owner = edited
	return root

# ---------------- project copy (FileSystem dock) ----------------
# Copy the downloaded source into res://CGHEVEN/<category>/<filename> so Godot
# imports it and it appears in the FileSystem dock (only files under res:// are
# importable/usable). Returns the res:// path, or "" on failure.
static func copy_into_project(path: String, category_slug: String) -> String:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return ""
	var sub := category_slug if category_slug != "" else "assets"
	var dir := RES_ROOT.path_join(sub)
	DirAccess.make_dir_recursive_absolute(dir)
	var dest := dir.path_join(CghConfig.safe_download_name(path.get_file()))
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer(bytes)
	f.close()
	# Make the editor pick up + import the new file so it shows in the dock.
	if Engine.is_editor_hint():
		var efs := EditorInterface.get_resource_filesystem()
		if efs and not efs.is_scanning():
			efs.scan()
	return dest

## Extract EVERY file from a zip into a sibling temp dir and return the best
## editor-importable MODEL inside (glb/gltf > fbx > dae > obj), or "" if none. Extracts
## the whole tree (not just the model) so .bin/.mtl/textures land next to it and survive
## the import. Mirrors the Blender addon's _pick_best_model_in_tree.
static func extract_model_from_zip(zip_path: String) -> String:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return ""
	var out_dir := zip_path.get_basename() + "_unzip"
	DirAccess.make_dir_recursive_absolute(out_dir)
	var best := ""
	var best_rank := 999
	for entry in reader.get_files():
		if entry.ends_with("/"):
			continue
		var rel := entry.replace("\\", "/")
		var out := out_dir.path_join(rel)
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f:
			f.store_buffer(reader.read_file(entry))
			f.close()
		var rank: int = EDITOR_MODEL_PRIORITY.find(rel.get_extension().to_lower())
		if rank != -1 and rank < best_rank:
			best_rank = rank
			best = out
	reader.close()
	return best

## Copy a model file AND its sibling files (textures / .bin / .mtl in the SAME folder)
## into res://CGHEVEN/<category>/<modelname>/ so the editor import keeps materials. Use
## this for models extracted from a zip (isolated temp dir); for a bare downloaded file
## use copy_into_project (single file). Returns the model's res:// path, or "" on failure.
static func copy_model_into_project(model_path: String, category_slug: String) -> String:
	var src_dir := model_path.get_base_dir()
	var sub := category_slug if category_slug != "" else "assets"
	var stem := CghConfig.safe_download_name(model_path.get_file()).get_basename()
	var dest_dir := RES_ROOT.path_join(sub).path_join(stem)
	DirAccess.make_dir_recursive_absolute(dest_dir)
	var model_dest := ""
	var da := DirAccess.open(src_dir)
	if da:
		da.list_dir_begin()
		var fn := da.get_next()
		while fn != "":
			if not da.current_is_dir():
				var bytes := FileAccess.get_file_as_bytes(src_dir.path_join(fn))
				var d := dest_dir.path_join(CghConfig.safe_download_name(fn))
				var wf := FileAccess.open(d, FileAccess.WRITE)
				if wf:
					wf.store_buffer(bytes)
					wf.close()
					if fn == model_path.get_file():
						model_dest = d
			fn = da.get_next()
		da.list_dir_end()
	if model_dest == "":
		# fallback: copy just the model file (distinct var names — GDScript locals are
		# function-scoped, so re-declaring bytes/wf from the loop above would error).
		var fbytes := FileAccess.get_file_as_bytes(model_path)
		if fbytes.is_empty():
			return ""
		model_dest = dest_dir.path_join(CghConfig.safe_download_name(model_path.get_file()))
		var fwf := FileAccess.open(model_dest, FileAccess.WRITE)
		if fwf == null:
			return ""
		fwf.store_buffer(fbytes)
		fwf.close()
	if Engine.is_editor_hint():
		var efs := EditorInterface.get_resource_filesystem()
		if efs and not efs.is_scanning():
			efs.scan()
	return model_dest

static func _extract_zip(zip_path: String) -> String:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return ""
	var ok := CghConfig.EXT_3D + CghConfig.EXT_HDRI + CghConfig.EXT_IMAGE
	var out_dir := zip_path.get_basename() + "_unzip"
	DirAccess.make_dir_recursive_absolute(out_dir)
	var best := ""
	var best_rank := 99
	for entry in reader.get_files():
		if entry.ends_with("/"):
			continue
		var e_ext := entry.get_extension().to_lower()
		if not (e_ext in ok):
			continue
		var out := out_dir + "/" + entry.get_file()
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f:
			f.store_buffer(reader.read_file(entry))
			f.close()
		# prefer 3D > hdri > image when several importable files exist
		var rank := 0 if e_ext in CghConfig.EXT_3D else (1 if e_ext in CghConfig.EXT_HDRI else 2)
		if rank < best_rank:
			best_rank = rank
			best = out
	reader.close()
	return best

static func _flipbook_grid(path: String) -> Vector2i:
	# look for an NxM token in the filename, e.g. fire_8x8.png / Portal_04_4K_8X8.exr
	var rx := RegEx.new()
	rx.compile("(\\d+)\\s*[xX]\\s*(\\d+)")
	var m := rx.search(path.get_file())
	if m:
		return Vector2i(int(m.get_string(1)), int(m.get_string(2)))
	return Vector2i(1, 1)
