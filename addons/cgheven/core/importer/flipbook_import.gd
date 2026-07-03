@tool
extends RefCounted
class_name CghFlipbookImport
## Builds a PLAYING flipbook from a sprite-sheet (NxM grid) and adds it to the
## open scene. Uses Sprite3D (hframes/vframes) + an AnimationPlayer that keyframes
## the `frame` property — the official, non-deprecated path that animates BOTH in
## the editor viewport and at runtime (AnimatedTexture is deprecated/broken).
## Handles .exr HDR sheets (load_exr_from_buffer) as well as png/jpg/webp.

static func from_sheet(sheet_path: String, h_frames: int, v_frames: int, fps := 30.0) -> Sprite3D:
	# SNIFF the real format from magic bytes rather than trusting the extension — CDN sheets
	# are sometimes served as webp/jpg but named ".png", and Godot's extension-based img.load()
	# then fails with a misleading "PNG corrupt" (png_driver_common). Sniffing decodes them.
	var img := _decode_sheet(FileAccess.get_file_as_bytes(sheet_path), sheet_path.get_extension().to_lower())
	if img == null:
		push_error("[CGHEVEN] Could not load flipbook sheet: " + sheet_path)
		return null
	var tex := ImageTexture.create_from_image(img)

	var cols: int = max(1, h_frames)
	var rows: int = max(1, v_frames)
	var total: int = cols * rows

	# Sprite3D slices the sheet natively via hframes/vframes; `frame` indexes the grid.
	var spr := Sprite3D.new()
	spr.name = "CghFlipbook"
	spr.texture = tex
	spr.hframes = cols
	spr.vframes = rows
	spr.frame = 0
	spr.billboard = BaseMaterial3D.BILLBOARD_ENABLED           # face the camera (VFX)
	spr.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED            # default = alpha blend

	var edited := EditorInterface.get_edited_scene_root()
	if edited == null:
		push_warning("[CGHEVEN] No open scene — flipbook node created but not added. Open a scene and re-import.")
		return spr

	# A Sprite3D only lives/renders in a 3D world. If the open scene is a UI
	# (Control) or 2D (Node2D) scene, nesting it inside that tree makes it
	# invisible. So guarantee a 3D host: use the root if it is Node3D, else drop
	# the flipbook under a dedicated Node3D wrapper (reused across imports).
	var parent_3d: Node = _ensure_3d_parent(edited)
	parent_3d.add_child(spr)
	spr.owner = edited

	# Single-frame sheet (no NxM in the filename) — nothing to animate.
	if total <= 1:
		return spr

	# Build a discrete, looping animation that steps `frame` 0..total-1.
	var anim := Animation.new()
	var track := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(track, NodePath(".:frame"))
	anim.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
	anim.length = float(total) / fps
	anim.loop_mode = Animation.LOOP_LINEAR
	for i in total:
		anim.track_insert_key(track, float(i) / fps, i)

	var lib := AnimationLibrary.new()
	lib.add_animation("play", anim)

	var ap := AnimationPlayer.new()
	ap.name = "FlipbookPlayer"
	spr.add_child(ap)
	ap.owner = edited
	ap.add_animation_library("", lib)
	ap.autoplay = "play"          # plays automatically when the scene runs
	ap.play("play")               # and starts immediately in the editor viewport
	return spr


## Decode a sprite-sheet from raw bytes, sniffing the real format from magic bytes (the file
## extension often lies). PNG=89 50 4E 47, JPEG=FF D8, WEBP=RIFF....WEBP, EXR=76 2F 31 01.
## Returns null on an unrecognised/corrupt body.
static func _decode_sheet(body: PackedByteArray, ext: String) -> Image:
	if body.size() < 12:
		return null
	var img := Image.new()
	var ok := ERR_INVALID_DATA
	if body[0] == 0x89 and body[1] == 0x50 and body[2] == 0x4E and body[3] == 0x47:
		ok = img.load_png_from_buffer(body)
	elif body[0] == 0xFF and body[1] == 0xD8:
		ok = img.load_jpg_from_buffer(body)
	elif body[0] == 0x52 and body[1] == 0x49 and body[2] == 0x46 and body[3] == 0x46 \
			and body[8] == 0x57 and body[9] == 0x45 and body[10] == 0x42 and body[11] == 0x50:
		ok = img.load_webp_from_buffer(body)
	elif body[0] == 0x76 and body[1] == 0x2F and body[2] == 0x31 and body[3] == 0x01:
		ok = img.load_exr_from_buffer(body)
	elif ext == "exr":
		ok = img.load_exr_from_buffer(body)   # magic missing but named .exr — try anyway
	else:
		return null
	return img if ok == OK else null

## Returns a 3D-capable parent for the flipbook. If the edited scene root is a
## Node3D we use it directly; otherwise (Control / Node2D / plain Node scene) we
## create — or reuse — a "CghevenFlipbooks" Node3D so the sprite always sits in a
## real 3D context and renders in the 3D viewport instead of vanishing into UI.
static func _ensure_3d_parent(edited: Node) -> Node:
	if edited is Node3D:
		return edited
	var existing := edited.get_node_or_null(NodePath("CghevenFlipbooks"))
	if existing != null and existing is Node3D:
		return existing
	var host := Node3D.new()
	host.name = "CghevenFlipbooks"
	edited.add_child(host)
	host.owner = edited
	push_warning("[CGHEVEN] Open scene is not 3D — flipbook placed under a new "
		+ "'CghevenFlipbooks' Node3D. Switch to the 3D viewport (or open a 3D "
		+ "scene) to see it play.")
	return host
