@tool
extends RefCounted
class_name CghMaterialImport
## Builds a StandardMaterial3D from a PBR texture set and assigns it to the
## selected MeshInstance3D. NOTE: Blender procedural node-graphs do NOT import;
## only the baked-PBR subset is reproduced here.

static func build_pbr(tex_paths: Dictionary) -> StandardMaterial3D:
	# tex_paths keys: albedo, normal, roughness, metallic, emission, ao
	var m := StandardMaterial3D.new()
	if tex_paths.has("albedo"):
		m.albedo_texture = _load(tex_paths["albedo"])
	if tex_paths.has("normal"):
		m.normal_enabled = true
		m.normal_texture = _load(tex_paths["normal"])
	if tex_paths.has("roughness"):
		m.roughness_texture = _load(tex_paths["roughness"])
	if tex_paths.has("metallic"):
		m.metallic = 1.0
		m.metallic_texture = _load(tex_paths["metallic"])
	if tex_paths.has("ao"):
		m.ao_enabled = true
		m.ao_texture = _load(tex_paths["ao"])
	if tex_paths.has("emission"):
		m.emission_enabled = true
		m.emission_texture = _load(tex_paths["emission"])
	return m

static func _load(path: String) -> Texture2D:
	var img := Image.new()
	if img.load(path) != OK:
		return null
	return ImageTexture.create_from_image(img)

static func assign_to_selection(mat: Material) -> bool:
	var sel := EditorInterface.get_selection().get_selected_nodes()
	for n in sel:
		if n is MeshInstance3D:
			n.material_override = mat
			return true
	push_warning("[CGHEVEN] Select a MeshInstance3D to apply the material.")
	return false
