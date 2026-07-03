@tool
extends PanelContainer
class_name CghAssetCard
## One asset card — 1:1 with the After Effects addon card anatomy:
##   square thumbnail (object-fit: cover) + badges (resolution pill / NEW / Premium)
##   + favorite ♥ + cross-addon ✓ downloaded tick + title + "Category / Subcategory"
##   + a .cdl-row footer: [⬇ label | sep | ▾ dropdown]; Upgrade = orange gradient.
## The card background is ALWAYS #1e1e24 (uniform grid); hover only lifts the border.

signal request_download(asset: Dictionary, entry: Dictionary)   # entry={} -> best free
signal request_upgrade(asset: Dictionary)
signal favorite_toggled(asset: Dictionary, is_fav: bool)
signal preview_requested(card, asset)        # hover -> main_dock loads still frames
signal flipbook_sheet_requested(card, asset) # hover on a flipbook -> main_dock fetches the real sprite sheet
signal cancel_requested(card)                # ✕ on the in-flight download
signal delete_requested(asset: Dictionary)   # 🗑 delete the downloaded file(s) -> re-download
signal viewed(asset)                         # user opened the format/options dropdown
signal login_required()                      # guest tried to favourite -> ask them to log in

const CARD_W := 168           # reference width
const MIN_W := 92             # min width so the responsive column count always fits the dock
const HOVER_DELAY := 0.12     # brief debounce before the NETWORK still-preview (flipbooks play instantly)
const PREVIEW_FPS := 0.45     # seconds per still frame

# dropdown special item ids (above any file index)
const ID_FAV  := 9000
const ID_COPY := 9001
const ID_VIEW := 9002
const ID_DEL  := 9003

var asset: Dictionary
var auth: CghAuth                            # set by main_dock; favourites need login
var _locked := false
var _thumb: TextureRect
var _wrap: Control
var _title: Label
var _subtitle: Label
var _action: Button
var _menu_btn: MenuButton
var _sep: ColorRect              # divider between the main button and the ▾ dropdown
var _badge_row: HBoxContainer
var _fav_btn: Button
var _progress: ProgressBar
var _footer: PanelContainer
var _prog_row: HBoxContainer
var _thumb_base: Texture2D
var _preview_frames: Array = []
var _preview_idx := 0
var _preview_loaded := false
var _flipbook_sheet_asked := false   # asked main_dock for this flipbook's real sprite sheet already
var _menu_entries: Array = []   # deduped entries backing the dropdown items
var _delay_timer: Timer
var _preview_timer: Timer

func setup(a: Dictionary) -> void:
	asset = a
	custom_minimum_size = Vector2(MIN_W, 0)   # min width; height is content-driven
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_stylebox_override("panel", CghTheme.card_box(false))
	mouse_filter = Control.MOUSE_FILTER_PASS
	mouse_entered.connect(_on_enter)
	mouse_exited.connect(_on_exit)

	# hover-preview timers
	_delay_timer = Timer.new()
	_delay_timer.one_shot = true
	_delay_timer.wait_time = HOVER_DELAY
	_delay_timer.timeout.connect(_start_preview)
	add_child(_delay_timer)
	_preview_timer = Timer.new()
	_preview_timer.wait_time = PREVIEW_FPS
	_preview_timer.timeout.connect(_next_preview_frame)
	add_child(_preview_timer)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	# PASS (not the default STOP) so a hover anywhere over this container — thumbnail,
	# title, subtitle, footer gaps — propagates up to the card and fires mouse_entered.
	# Without this the card only "saw" hovers on the bare label rows, so the preview
	# played only when the pointer was on/below the title (the thumbnail ate the event).
	v.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(v)

	# --- square thumbnail wrap (keeps a 1:1 aspect as the card width changes) ---
	_wrap = Control.new()
	_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wrap.custom_minimum_size = Vector2(0, MIN_W)
	_wrap.clip_contents = true
	_wrap.mouse_filter = Control.MOUSE_FILTER_PASS   # let hover over the thumbnail reach the card
	_wrap.resized.connect(_keep_square)
	v.add_child(_wrap)

	# dark bg behind the (possibly still-loading) thumbnail
	var thumb_bg := ColorRect.new()
	thumb_bg.color = CghConfig.C_NAV
	thumb_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	thumb_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wrap.add_child(thumb_bg)

	_thumb = TextureRect.new()
	_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_thumb.set_anchors_preset(Control.PRESET_FULL_RECT)
	_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wrap.add_child(_thumb)

	# badges top-left
	_badge_row = HBoxContainer.new()
	_badge_row.position = Vector2(5, 5)
	_badge_row.add_theme_constant_override("separation", 3)
	_badge_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wrap.add_child(_badge_row)

	# top-right cluster: favorite ♥
	var topright := HBoxContainer.new()
	topright.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	topright.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	topright.offset_top = 4
	topright.offset_right = -4
	topright.add_theme_constant_override("separation", 2)
	_wrap.add_child(topright)

	_fav_btn = Button.new()
	_fav_btn.flat = true
	_fav_btn.custom_minimum_size = Vector2(22, 22)
	_fav_btn.pressed.connect(_on_fav)
	topright.add_child(_fav_btn)
	_refresh_fav_icon()

	# --- title ---
	_title = Label.new()
	_title.text = CghAsset.title(asset)
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_title.clip_text = true
	_title.add_theme_color_override("font_color", CghConfig.C_TEXT1)
	_title.add_theme_font_size_override("font_size", 12)
	_title.mouse_filter = Control.MOUSE_FILTER_PASS
	v.add_child(_title)

	# --- subtitle: "Category / Subcategory" ---
	_subtitle = Label.new()
	_subtitle.text = _subtitle_text()
	_subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_subtitle.clip_text = true
	_subtitle.add_theme_color_override("font_color", CghConfig.C_TEXT3)
	_subtitle.add_theme_font_size_override("font_size", 10)
	_subtitle.mouse_filter = Control.MOUSE_FILTER_PASS
	v.add_child(_subtitle)

	# --- footer: .cdl-row pill [ main | sep | ▾ ] ---
	_footer = PanelContainer.new()
	_footer.add_theme_stylebox_override("panel", CghTheme.footer_pill_box())
	_footer.custom_minimum_size = Vector2(0, 24)
	_footer.mouse_filter = Control.MOUSE_FILTER_PASS   # gaps around the buttons still hover the card
	v.add_child(_footer)
	var frow := HBoxContainer.new()
	frow.add_theme_constant_override("separation", 0)
	_footer.add_child(frow)

	_action = Button.new()
	_action.flat = true
	_action.custom_minimum_size = Vector2(0, 22)
	_action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_action.add_theme_font_size_override("font_size", 11)
	_action.pressed.connect(_on_action)
	frow.add_child(_action)

	_sep = ColorRect.new()
	_sep.color = CghConfig.C_BORDER
	_sep.custom_minimum_size = Vector2(1, 14)
	_sep.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	frow.add_child(_sep)

	_menu_btn = MenuButton.new()
	_menu_btn.flat = true
	_menu_btn.text = "▾"
	_menu_btn.custom_minimum_size = Vector2(22, 22)
	frow.add_child(_menu_btn)
	_build_format_menu()
	_menu_btn.get_popup().about_to_popup.connect(func(): viewed.emit(asset))

	# --- progress row (hidden until downloading): thin accent bar + ✕ cancel ---
	_prog_row = HBoxContainer.new()
	_prog_row.add_theme_constant_override("separation", 4)
	_prog_row.visible = false
	v.add_child(_prog_row)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size = Vector2(0, 6)
	_progress.show_percentage = false
	_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var pfill := StyleBoxFlat.new()
	pfill.bg_color = CghConfig.C_ACCENT
	pfill.set_corner_radius_all(2)
	_progress.add_theme_stylebox_override("fill", pfill)
	var pbg := StyleBoxFlat.new()
	pbg.bg_color = Color(0.5, 0.5, 0.5, 0.15)
	pbg.set_corner_radius_all(2)
	_progress.add_theme_stylebox_override("background", pbg)
	_prog_row.add_child(_progress)
	var cancel := Button.new()
	cancel.flat = true
	cancel.text = "✕"
	cancel.tooltip_text = "Cancel download"
	cancel.custom_minimum_size = Vector2(18, 18)
	cancel.add_theme_font_size_override("font_size", 10)
	cancel.add_theme_color_override("font_color", CghConfig.C_TEXT3)
	cancel.add_theme_color_override("font_hover_color", CghConfig.C_ERR)
	cancel.pressed.connect(func(): cancel_requested.emit(self))
	_prog_row.add_child(cancel)

	_apply_state()

func _keep_square() -> void:
	if not _wrap:
		return
	var w := _wrap.size.x
	if w > 1.0 and absf(_wrap.custom_minimum_size.y - w) > 0.5:
		_wrap.custom_minimum_size.y = w

func _subtitle_text() -> String:
	var cat := CghAsset.category_title(asset)
	return cat if cat != "" else "Asset"

func _apply_state() -> void:
	# Badges (NEW / Premium / resolution) intentionally removed per design.
	_locked = not CghAsset.has_free_file(asset)

	# footer main button — Upgrade (orange) / Import (downloaded) / <res> / Download
	if _locked:
		_action.text = "Upgrade"
		_action.flat = false
		_action.add_theme_stylebox_override("normal", CghTheme.brand_button_box())
		_action.add_theme_stylebox_override("hover", CghTheme.brand_button_box(true))
		_action.add_theme_stylebox_override("pressed", CghTheme.brand_button_box(true))
		_action.add_theme_color_override("font_color", Color.WHITE)
		_action.add_theme_color_override("font_hover_color", Color.WHITE)
		# A locked (patreon) asset for a non-paying user has nothing to choose/download,
		# so hide the ▾ dropdown + divider — the orange Upgrade fills the whole footer.
		_menu_btn.visible = false
		_sep.visible = false
	else:
		var best := CghAsset.best_free_entry(asset)
		var rl: String = best.get("res", "") if not best.is_empty() else ""
		# Cross-addon: "downloaded" if any CGHEVEN addon grabbed this asset (id match).
		var dl: bool = CghDownloads.is_downloaded(asset)
		if dl:
			_action.text = ("Import %s" % rl).strip_edges() if rl != "" else "Import"
		else:
			_action.text = ("⤓ %s" % rl) if rl != "" else "⤓ Download"
		_action.flat = true
		_action.add_theme_color_override("font_color", CghConfig.C_TEXT2)
		_action.add_theme_color_override("font_hover_color", CghConfig.C_ACCENT)
		_menu_btn.visible = true
		_menu_btn.disabled = false
		_sep.visible = true

## Public: re-evaluate the download state (called after a delete) so the footer flips
## between Download / Import and the dropdown's delete row appears/disappears.
func refresh_state() -> void:
	_apply_state()
	_build_format_menu()

func _top_res_label() -> String:
	var best := -1
	var lbl := ""
	for e in CghAsset.file_entries(asset):
		if e["res"] != "" and e["res_rank"] >= best:
			best = e["res_rank"]; lbl = e["res"]
	return lbl

# AE-style dropdown: grouped by FORMAT, one row per resolution (deduped).
func _build_format_menu() -> void:
	var pm := _menu_btn.get_popup()
	pm.clear()
	pm.add_theme_stylebox_override("panel", CghTheme.dropdown_box())
	_menu_entries = []
	var entries := CghAsset.importable_entries(asset)
	# Hide the low-poly preview .glb from the menu when real files exist (it's only an
	# internal download fallback) — keeps the list clean.
	var non_preview := entries.filter(func(e): return not e.get("preview", false))
	if not non_preview.is_empty():
		entries = non_preview
	var pref := ["GLTF", "GLB", "FBX", "OBJ", "ZIP", "EXR", "HDR", "PNG", "JPG", "JPEG", "WEBP"]
	var verb := "Download"
	if entries.is_empty():
		pm.add_item("No Godot-importable file", -1)
		pm.set_item_disabled(0, true)
	elif _collapse_by_resolution(entries):
		# Like Blender for 3D models / flipbooks: ONE resolution ladder, no format
		# names (gltf/glb/fbx are interchangeable for Godot; png/jpg/webp likewise).
		var by_res := {}     # res -> best entry
		for e in entries:
			var rk: String = e["res"]
			var cur = by_res.get(rk, null)
			if cur == null:
				by_res[rk] = e
			else:
				var better: bool = bool(cur["locked"]) and not bool(e["locked"])
				if not better and bool(cur["locked"]) == bool(e["locked"]):
					var ie: int = pref.find(_base_fmt(e["format"]))
					var ic: int = pref.find(_base_fmt(cur["format"]))
					if ie == -1: ie = 99
					if ic == -1: ic = 99
					better = ie < ic
				if better:
					by_res[rk] = e
		var rows: Array = by_res.values()
		rows.sort_custom(func(a, b): return int(a["res_rank"]) < int(b["res_rank"]))
		for e in rows:
			var v := "Import" if (CghDownloads.has_file(e["filename"]) or CghDownloads.is_res_downloaded(CghAsset.id(asset), e["res"])) else verb
			var label := ("%s (%s)" % [e["res"], v]) if e["res"] != "" else v
			if e["locked"]:
				label += "  🔒"
			_menu_entries.append(e)
			pm.add_item(label, _menu_entries.size() - 1)
			if e["locked"]:
				pm.set_item_disabled(pm.get_item_count() - 1, true)
	else:
		# Mixed media (VFX/HDRI): keep format groups (MP4 vs EXR actually differ).
		var groups := {}     # format -> { res -> entry }
		var order := []      # format first-seen order
		for e in entries:
			var fmt: String = e["format"]
			var rk: String = e["res"]
			if not groups.has(fmt):
				groups[fmt] = {}
				order.append(fmt)
			var g: Dictionary = groups[fmt]
			if not g.has(rk) or (bool(g[rk]["locked"]) and not bool(e["locked"])):
				g[rk] = e
		order.sort_custom(func(a, b):
			var ia: int = pref.find(a); var ib: int = pref.find(b)
			if ia == -1: ia = 99
			if ib == -1: ib = 99
			return ia < ib)
		for fmt in order:
			pm.add_separator(fmt)
			var rows: Array = groups[fmt].values()
			rows.sort_custom(func(a, b): return int(a["res_rank"]) < int(b["res_rank"]))
			for e in rows:
				var v := "Import" if (CghDownloads.has_file(e["filename"]) or CghDownloads.is_res_downloaded(CghAsset.id(asset), e["res"])) else verb
				var label := ("%s (%s)" % [e["res"], v]) if e["res"] != "" else v
				if e["locked"]:
					label += "  🔒"
				_menu_entries.append(e)
				pm.add_item(label, _menu_entries.size() - 1)
				if e["locked"]:
					pm.set_item_disabled(pm.get_item_count() - 1, true)
	# AE dropdown footer items
	pm.add_separator()
	pm.add_item(("♥ Remove from Favorites" if CghFavorites.is_fav(asset) else "♡ Add to Favorites"), ID_FAV)
	pm.add_item("⧉ Copy asset link", ID_COPY)
	pm.add_item("🌐 View online", ID_VIEW)
	# Only offer delete when a copy is actually on disk — lets the user wipe a missing/
	# corrupt download so the footer flips back to Download and they can re-fetch.
	if CghDownloads.is_downloaded(asset):
		pm.add_item("🗑 Delete download", ID_DEL)
	if not pm.id_pressed.is_connected(_on_menu_pick):
		pm.id_pressed.connect(_on_menu_pick)

# True when every importable entry is a 3D model (gltf/glb/fbx/obj/zip) OR every one
# is an image (png/jpg/webp) — those formats are interchangeable for Godot, so we show
# a single resolution list instead of one group per format (matches the Blender addon).
func _collapse_by_resolution(entries: Array) -> bool:
	var model := ["glb", "gltf", "fbx", "obj", "zip"]
	var image := ["png", "jpg", "jpeg", "webp"]
	var all_model := true
	var all_image := true
	for e in entries:
		if not (e["ext"] in model):
			all_model = false
		if not (e["ext"] in image):
			all_image = false
	return all_model or all_image

func _base_fmt(fmt: String) -> String:
	return fmt.replace(" (GS)", "").to_upper()

func _on_menu_pick(idx: int) -> void:
	match idx:
		ID_FAV:
			_on_fav()
		ID_COPY:
			DisplayServer.clipboard_set(_asset_url())
		ID_VIEW:
			OS.shell_open(_asset_url())
		ID_DEL:
			delete_requested.emit(asset)
		_:
			if idx >= 0 and idx < _menu_entries.size():
				request_download.emit(asset, _menu_entries[idx])

func _asset_url() -> String:
	return CghAsset.web_url(asset)   # https://cgheven.com/assets/<assets_slug>, like Blender

func _on_action() -> void:
	if _locked:
		request_upgrade.emit(asset)
	else:
		request_download.emit(asset, {})   # {} -> caller uses best free entry

func _on_fav() -> void:
	# Favourites require login — a guest gets a "please login" prompt instead.
	if auth == null or not auth.is_logged_in():
		login_required.emit()
		return
	var now := CghFavorites.toggle(asset)
	_refresh_fav_icon()
	_build_format_menu()
	favorite_toggled.emit(asset, now)

func _refresh_fav_icon() -> void:
	var fav := CghFavorites.is_fav(asset)
	_fav_btn.text = "♥" if fav else "♡"
	_fav_btn.add_theme_color_override("font_color", CghConfig.C_ERR if fav else CghConfig.C_TEXT1)

func _add_res_badge(text: String) -> void:
	var b := Label.new()
	b.text = text
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_font_size_override("font_size", 9)
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", CghTheme.res_badge_box())
	p.add_child(b)
	_badge_row.add_child(p)

func _add_badge(text: String, col: Color) -> void:
	var b := Label.new()
	b.text = text
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_font_size_override("font_size", 9)
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", CghTheme.badge_box(col))
	p.add_child(b)
	_badge_row.add_child(p)

# ---- called by main_dock during this card's download ----
func set_progress(pct: float) -> void:
	_prog_row.visible = true
	_footer.visible = false
	if pct < 0:
		_progress.indeterminate = true
	else:
		_progress.indeterminate = false
		_progress.value = pct

func set_download_done(_ok: bool) -> void:
	_prog_row.visible = false
	_footer.visible = true

## Download cancelled — restore the footer to its pre-download state.
func reset_after_cancel() -> void:
	_prog_row.visible = false
	_footer.visible = true
	_apply_state()

func set_thumbnail(tex: Texture2D) -> void:
	if tex and _thumb:
		_thumb.texture = tex
		_thumb_base = tex

func get_thumb_url() -> String:
	return CghAsset.thumbnail(asset)

# ---------------- hover preview (image slideshow; Godot can't play mp4) ----------------
func _on_enter() -> void:
	add_theme_stylebox_override("panel", CghTheme.card_box(true))
	if _preview_loaded:
		if _preview_frames.size() > 1:
			_preview_timer.start()
		return
	if CghAsset.is_flipbook(asset):
		# Flipbooks: play the REAL sprite sheet, not the card thumbnail. Ask main_dock to fetch
		# the low-res sheet once; it calls set_flipbook_sheet() when ready. (Slicing the card
		# thumbnail was unreliable — some categories, e.g. muzzle-flashes, use a single-frame
		# thumbnail whose layout doesn't match the sheet's NxM, so slicing it showed garbage.)
		if not _flipbook_sheet_asked:
			_flipbook_sheet_asked = true
			flipbook_sheet_requested.emit(self, asset)
		return
	# Non-flipbooks: brief debounce, then load still frames over the network.
	_delay_timer.start()

func _on_exit() -> void:
	# Moving the pointer onto a child button (Download / ▾ / ♥) fires mouse_exited on the
	# card even though the pointer is still INSIDE it. Ignore those spurious exits so the
	# preview keeps playing across the whole card — only stop when truly leaving the card.
	# (If the pointer then leaves the card VIA that child button, the card gets NO second
	# mouse_exited — the watchdog in _next_preview_frame catches that case and stops.)
	if is_visible_in_tree() and get_global_rect().has_point(get_global_mouse_position()):
		return
	_stop_preview()

# Stop the hover preview and restore the card to its resting look.
func _stop_preview() -> void:
	add_theme_stylebox_override("panel", CghTheme.card_box(false))
	_delay_timer.stop()
	_preview_timer.stop()
	# If the flipbook sheet never actually loaded (download failed / not a flipbook), allow a
	# fresh attempt on the next hover instead of being stuck forever.
	if not _preview_loaded:
		_flipbook_sheet_asked = false
	if _thumb_base:
		_thumb.texture = _thumb_base   # revert to thumbnail

func _start_preview() -> void:
	if _preview_loaded:
		return
	# Non-flipbooks: ask main_dock for still frames (flipbooks are handled in _on_enter via the
	# real sprite-sheet download).
	preview_requested.emit(self, asset)

# main_dock delivers the REAL low-res sprite sheet (as a texture) + its grid; slice it into
# per-cell AtlasTexture frames and play. Using the actual sheet (not the card thumbnail)
# guarantees the grid matches the image — this fixes categories like muzzle-flashes whose card
# thumbnail is a single frame, not a contact sheet, so slicing it NxM produced garbage.
func set_flipbook_sheet(tex: Texture2D, grid: Vector2i) -> void:
	if tex == null:
		return
	var cols: int = maxi(1, grid.x)
	var rows: int = maxi(1, grid.y)
	if cols * rows <= 1:
		return
	var tw := tex.get_width()
	var th := tex.get_height()
	if tw < cols or th < rows:
		return
	# INTEGER cell size (float-divide then floor) so regions land on exact pixel boundaries —
	# fractional regions sample slivers of the neighbouring cell and make the playback shimmer.
	# The last column/row absorbs any remainder pixels so we never read past the sheet edge.
	var cw := int(float(tw) / float(cols))
	var ch := int(float(th) / float(rows))
	if cw < 1 or ch < 1:
		return
	var frames := []
	for r in rows:
		for c in cols:
			var w := cw if c < cols - 1 else tw - cw * (cols - 1)
			var h := ch if r < rows - 1 else th - ch * (rows - 1)
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = Rect2(c * cw, r * ch, w, h)
			frames.append(at)
	if frames.size() <= 1:
		return
	_preview_frames = frames
	_preview_loaded = true
	_preview_idx = 0
	_preview_timer.wait_time = 0.04        # ~25 fps flipbook playback, smooth (stills use PREVIEW_FPS)
	# Only start playing if the pointer is still over this card (the sheet may have finished
	# downloading after the user moved on).
	if is_visible_in_tree() and get_global_rect().has_point(get_global_mouse_position()):
		_thumb.texture = frames[0]
		_preview_timer.start()

func set_preview_frames(frames: Array) -> void:
	_preview_frames = frames
	_preview_loaded = true
	if _preview_frames.size() >= 1 and is_visible_in_tree():
		if get_global_rect().has_point(get_global_mouse_position()):
			_preview_idx = 0
			_thumb.texture = _preview_frames[0]
			if _preview_frames.size() > 1:
				_preview_timer.start()

func _next_preview_frame() -> void:
	# Watchdog: when the pointer leaves the card VIA a child button, the card never gets a
	# second mouse_exited, so the preview would otherwise play forever. This frame timer only
	# runs while previewing, so re-check the pointer each tick and stop once it's truly gone.
	if not is_visible_in_tree() or not get_global_rect().has_point(get_global_mouse_position()):
		_stop_preview()
		return
	if _preview_frames.is_empty():
		return
	_preview_idx = (_preview_idx + 1) % _preview_frames.size()
	_thumb.texture = _preview_frames[_preview_idx]
