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
var _thumb_base: Texture2D              # full thumbnail (the whole sprite-sheet for flipbooks)
var _thumb_poster: Texture2D            # what the card shows at REST (bright poster cell for dark sheets)
var _thumb_bg: ColorRect                # dark tile behind the thumbnail (lifted for placeholder)
var _preview_frames: Array = []
var _preview_idx := 0
var _preview_loaded := false
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
	add_child(v)

	# --- square thumbnail wrap (keeps a 1:1 aspect as the card width changes) ---
	_wrap = Control.new()
	_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_wrap.custom_minimum_size = Vector2(0, MIN_W)
	_wrap.clip_contents = true
	_wrap.resized.connect(_keep_square)
	v.add_child(_wrap)

	# dark bg behind the (possibly still-loading) thumbnail
	_thumb_bg = ColorRect.new()
	_thumb_bg.color = CghConfig.C_NAV
	_thumb_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_thumb_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wrap.add_child(_thumb_bg)

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
	v.add_child(_title)

	# --- subtitle: "Category / Subcategory" ---
	_subtitle = Label.new()
	_subtitle.text = _subtitle_text()
	_subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_subtitle.clip_text = true
	_subtitle.add_theme_color_override("font_color", CghConfig.C_TEXT3)
	_subtitle.add_theme_font_size_override("font_size", 10)
	v.add_child(_subtitle)

	# --- footer: .cdl-row pill [ main | sep | ▾ ] ---
	_footer = PanelContainer.new()
	_footer.add_theme_stylebox_override("panel", CghTheme.footer_pill_box())
	_footer.custom_minimum_size = Vector2(0, 24)
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
	if not (tex and _thumb):
		return
	_thumb_base = tex                       # full sheet — kept so hover can still slice all frames
	_thumb_poster = _static_poster(tex)     # what the card shows at rest (bright poster, not a dark grid)
	_thumb.texture = _thumb_poster

# Many flipbook thumbnails ARE the full sprite-sheet (e.g. a 5x5 grid) where the bright flash
# occupies only 1-3 of the NxM cells — so ~97% of the image is black and the card reads as a
# solid black tile (this is exactly why the Muzzle-Flashes category looked broken while Fire,
# whose thumbnails happen to be bright single-frame posters, looked fine). For a dark tiled
# sheet, pick the BRIGHTEST cell and show it as a static poster. _thumb_base stays the full
# sheet so the hover animation still slices every frame. Non-flipbooks, unknown grids, and
# already-bright single-frame posters are returned unchanged.
func _static_poster(tex: Texture2D) -> Texture2D:
	if asset == null or CghAsset.category_slug(asset) != "flipbooks":
		return tex
	var grid := CghAsset.flipbook_grid(asset)
	var cols: int = maxi(1, grid.x)
	var rows: int = maxi(1, grid.y)
	if cols * rows <= 1:
		return tex
	var img := tex.get_image()
	if img == null:
		return tex
	if img.is_compressed():
		img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	if w < cols or h < rows:
		return tex
	# Cheap brightness probe on a 24x24 copy — leave already-bright single-frame posters alone,
	# only rescue dark tiled sheets.
	var probe: Image = img.duplicate()
	probe.resize(24, 24, Image.INTERPOLATE_BILINEAR)
	var mean := 0.0
	for y in 24:
		for x in 24:
			var c := probe.get_pixel(x, y)
			mean += maxf(c.r, maxf(c.g, c.b))
	if mean / 576.0 > 0.16:                  # bright enough already -> use the thumbnail as-is
		return tex
	# Find the brightest cell of the sheet and show just that cell.
	var cw := int(w / cols)
	var ch := int(h / rows)
	if cw < 1 or ch < 1:
		return tex
	var best := Rect2(0, 0, cw, ch)
	var best_score := -1.0
	for r in rows:
		for c in cols:
			var cell := img.get_region(Rect2i(c * cw, r * ch, cw, ch))
			cell.resize(12, 12, Image.INTERPOLATE_BILINEAR)
			var s := 0.0
			for yy in 12:
				for xx in 12:
					var p := cell.get_pixel(xx, yy)
					s += maxf(p.r, maxf(p.g, p.b))
			if s > best_score:
				best_score = s
				best = Rect2(c * cw, r * ch, cw, ch)
	if CghAsset.THUMB_DEBUG:
		print("[CGHEVEN thumb] poster rescue '%s' grid=%dx%d mean=%.3f -> cell=%s" % [
			CghAsset.title(asset), cols, rows, mean / 576.0, str(best)])
	var at := AtlasTexture.new()
	at.atlas = tex
	at.region = best
	return at

## Card had NO decodable thumbnail (network/format failure) — show a faint placeholder tile
## instead of a pure-black void. The title/subtitle labels below already name the asset.
func set_thumbnail_placeholder() -> void:
	_thumb_base = null
	_thumb_poster = null
	if _thumb:
		_thumb.texture = null
	if _thumb_bg:
		_thumb_bg.color = CghConfig.C_CARD_HOVER

func get_thumb_url() -> String:
	return CghAsset.thumbnail(asset)

# ---------------- hover preview (image slideshow; Godot can't play mp4) ----------------
func _on_enter() -> void:
	add_theme_stylebox_override("panel", CghTheme.card_box(true))
	if _preview_loaded:
		if _preview_frames.size() > 1:
			_preview_timer.start()
	elif not _try_build_flipbook_frames():
		# Flipbooks play INSTANTLY (local sprite-sheet slice, above). Everything else waits
		# a brief debounce before hitting the network for still frames.
		_delay_timer.start()

func _on_exit() -> void:
	add_theme_stylebox_override("panel", CghTheme.card_box(false))
	_delay_timer.stop()
	_preview_timer.stop()
	# Revert to the resting POSTER (bright cell), not the raw dark sheet — otherwise a flipbook
	# card would turn black again after the first hover.
	if _thumb_poster:
		_thumb.texture = _thumb_poster
	elif _thumb_base:
		_thumb.texture = _thumb_base

func _start_preview() -> void:
	if _preview_loaded:
		return
	# Flipbooks: slice the sprite-sheet thumbnail into frames and PLAY it locally on hover
	# (no network) — an actual flipbook animation. Other categories fall back to the
	# still-image slideshow loaded by main_dock.
	if _try_build_flipbook_frames():
		return
	preview_requested.emit(self, asset)

# Build AtlasTexture frames from the flipbook's sprite-sheet thumbnail and start playing.
# Returns false (→ still-image fallback) when this isn't a flipbook, the grid is unknown,
# or the thumbnail hasn't loaded yet.
func _try_build_flipbook_frames() -> bool:
	if CghAsset.category_slug(asset) != "flipbooks" or _thumb_base == null:
		return false
	var grid := CghAsset.flipbook_grid(asset)
	if grid.x <= 1 and grid.y <= 1:
		return false
	var cols: int = maxi(1, grid.x)
	var rows: int = maxi(1, grid.y)
	var tw := _thumb_base.get_width()
	var th := _thumb_base.get_height()
	if tw <= 0 or th <= 0 or cols * rows <= 1:
		return false
	var cw := float(tw) / float(cols)
	var ch := float(th) / float(rows)
	var frames := []
	for r in rows:
		for c in cols:
			var at := AtlasTexture.new()
			at.atlas = _thumb_base
			at.region = Rect2(c * cw, r * ch, cw, ch)
			frames.append(at)
	if frames.size() <= 1:
		return false
	_preview_frames = frames
	_preview_loaded = true
	_preview_idx = 0
	_preview_timer.wait_time = 0.05        # ~20 fps flipbook playback (stills use PREVIEW_FPS)
	_thumb.texture = frames[0]
	_preview_timer.start()
	return true

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
	if _preview_frames.is_empty():
		return
	_preview_idx = (_preview_idx + 1) % _preview_frames.size()
	_thumb.texture = _preview_frames[_preview_idx]
