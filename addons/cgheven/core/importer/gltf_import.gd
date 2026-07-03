@tool
extends RefCounted
class_name CghGltfImport
## Imports a downloaded .glb/.gltf into the currently edited scene.

static func import_into_scene(glb_path: String) -> Node:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(glb_path, state)
	if err != OK:
		push_error("[CGHEVEN] glTF parse failed: %d" % err)
		return null
	var scene_root := doc.generate_scene(state)
	if scene_root == null:
		push_error("[CGHEVEN] glTF generate_scene returned null")
		return null
	var edited := EditorInterface.get_edited_scene_root()
	if edited == null:
		push_warning("[CGHEVEN] No open scene to import into.")
		return scene_root
	edited.add_child(scene_root)
	# own the node so it saves with the scene
	scene_root.owner = edited
	for c in scene_root.find_children("*", "", true, false):
		c.owner = edited
	return scene_root
