@tool
extends VBoxContainer
class_name CghCollectionsPage
## The Collections page of the CGHEVEN dock.
##
## Shows every Live collection. A collection the user bought on cgheven.com (or claimed with the Studio
## plan) is unlocked here: its assets can be downloaded one by one or all at once. Other collections show
## as locked, with a Buy button that opens the website (and a Claim button for a Studio owner).
## The server decides who owns what (GET/POST /api/addon-collections*, Bearer = the add-on's session
## token). This file only draws what the server says.

signal notify(message: String, ok: bool)   # the dock shows it as a toast

const STALE_MSEC := 300000
const MAX_PARALLEL := 3
const IMPORTABLE := ["png", "jpg", "jpeg", "webp", "exr", "hdr"]

var auth: CghAuth

var _items: Array = []
var _meta := {}
var _loading := false
var _error := ""
var _loaded_at := 0
var _as_user := ""
var _open := ""
var _files := {}          # slug -> Dictionary | "loading" | "error"
var _fmt := {}            # slug -> "MP4|1K"
var _busy := {}           # slug -> true while a claim is in flight
var _active := {}         # "slug|effect" -> {pct, req, dest, name, fmt, import}
var _queue: Array = []    # pending "download all" jobs
var _status := ""
var _scroll: ScrollContainer
var _body: VBoxContainer
var _cols := 2
var _last_w := 0.0
var _tex := {}            # url -> ImageTexture
var _tex_rects := {}      # url -> Array of TextureRect
var _tex_asked := {}
var _thumb_pending: Array = []
var _thumb_busy := 0
var _bars := {}           # key -> ProgressBar

func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 8)
	_scroll.add_child(_body)
	resized.connect(_on_resized)

func enter() -> void:
	_cols = clampi(int(size.x / 165.0), 1, 6)
	_last_w = size.x
	_render()
	_load(false)

func invalidate() -> void:
	_loaded_at = 0
	_files.clear()

func _on_resized() -> void:
	var cols := clampi(int(size.x / 165.0), 1, 6)
	# Re-render when the column count changes or the width moved enough that the cards would no longer fill the row.
	if cols != _cols or absf(size.x - _last_w) > 24.0:
		_cols = cols
		_last_w = size.x
		_render()

func _process(_dt: float) -> void:
	if _active.is_empty():
		return
	for key in _active.keys():
		var job: Dictionary = _active[key]
		var req: HTTPRequest = job["req"]
		if not is_instance_valid(req):
			continue
		var total := req.get_body_size()
		if total > 0:
			var pct := int(float(req.get_downloaded_bytes()) / float(total) * 100.0)
			job["pct"] = pct
			var bar: ProgressBar = _bars.get(key)
			if bar != null and is_instance_valid(bar):
				bar.value = pct

# ----------------------------------------------------------------- network
func _token() -> String:
	return auth.session_token if auth != null and auth.is_logged_in() else ""

func _call(method: int, path: String, body := {}, token := "") -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 20.0
	add_child(req)
	var headers := PackedStringArray(["Accept: application/json", "User-Agent: CGHEVEN-Godot/%s" % CghConfig.ADDON_VERSION])
	if token != "":
		headers.append("Authorization: Bearer " + token)
	var payload := ""
	if method == HTTPClient.METHOD_POST:
		headers.append("Content-Type: application/json")
		payload = JSON.stringify(body)
	var err := req.request(CghConfig.api_base() + path, headers, method, payload)
	if err != OK:
		req.queue_free()
		return {"status": 0, "json": {}}
	var res: Array = await req.request_completed
	req.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"status": 0, "json": {}}
	var parsed = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	return {"status": int(res[1]), "json": parsed if typeof(parsed) == TYPE_DICTIONARY else {}}

func _problem(res: Dictionary, fallback: String) -> String:
	var err = res.get("json", {}).get("error", {})
	if typeof(err) == TYPE_DICTIONARY and str(err.get("message", "")) != "":
		return str(err["message"])
	var st := int(res.get("status", 0))
	if st == 0:
		return "No connection. Check your internet and try again."
	if st == 401 or st == 403:
		return "Please sign in again (Login button)."
	return fallback

func _load(force: bool) -> void:
	var token := _token()
	var fresh := Time.get_ticks_msec() - _loaded_at < STALE_MSEC and _as_user == token and _loaded_at > 0
	if _loading or (fresh and not force):
		return
	_loading = true
	_error = ""
	_render()
	var used := token
	var res := {"status": 0, "json": {}}
	if token != "":
		res = await _call(HTTPClient.METHOD_GET, "/api/addon-collections", {}, token)
	if token == "" or int(res["status"]) == 401 or int(res["status"]) == 403:
		res = await _call(HTTPClient.METHOD_GET, "/api/collections")
		used = ""
	_loading = false
	var data = res["json"].get("data", null)
	if int(res["status"]) != 200 or typeof(data) != TYPE_ARRAY:
		_error = _problem(res, "Collections could not be loaded. Try again in a moment.")
		_render()
		return
	_items.clear()
	for c in data:
		if typeof(c) != TYPE_DICTIONARY or str(c.get("slug", "")) == "":
			continue
		if used == "" and c.has("status") and str(c["status"]) != "live":
			continue   # guests see only collections that are on sale
		var effects: Array = []
		for e in c.get("effects", []):
			if typeof(e) == TYPE_DICTIONARY and e.get("id", null) != null:
				effects.append(e)
		_items.append({
			"slug": str(c["slug"]), "title": str(c.get("title", "Collection")), "cover": str(c.get("cover", "") if c.get("cover", null) != null else ""),
			"price": c.get("price", null), "effectCount": int(c.get("effectCount", 0)),
			"owned": bool(c.get("owned", false)), "claimedWithStudio": bool(c.get("claimedWithStudio", false)),
			"effects": effects,
		})
	_meta = res["json"].get("meta", {}) if typeof(res["json"].get("meta", {})) == TYPE_DICTIONARY else {}
	_loaded_at = Time.get_ticks_msec()
	_as_user = used
	_render()

func _load_files(slug: String) -> void:
	if _files.has(slug):
		return
	_files[slug] = "loading"
	var res := await _call(HTTPClient.METHOD_POST, "/api/addon-collections/files", {"collection": slug}, _token())
	var d = res["json"].get("data", null)
	if int(res["status"]) == 200 and typeof(d) == TYPE_DICTIONARY:
		_files[slug] = d
		if not _fmt.has(slug):
			_fmt[slug] = _default_fmt(d)
	else:
		_files[slug] = "error"
		_say("✗ " + _problem(res, "The files could not be loaded."), false)
	_render()

func _default_fmt(d: Dictionary) -> String:
	var choices: Array = d.get("downloadAll", [])
	for key in ["MP4|1K", "MP4|2K", "PNG|1K"]:
		for c in choices:
			if str(c.get("key", "")) == key:
				return key
	return str(choices[0].get("key", "")) if not choices.is_empty() else ""

# ----------------------------------------------------------------- helpers
func _say(text: String, ok: bool) -> void:
	_status = text
	notify.emit(text, ok)

func _price_text(item: Dictionary) -> String:
	var p = item.get("price", null)
	if p == null:
		return ""
	return "$%s" % str(snappedf(float(p), 0.01)).trim_suffix(".0")

func _can_claim(item: Dictionary) -> bool:
	if not bool(_meta.get("can_claim", false)) or item.get("price", null) == null:
		return false
	return float(item["price"]) <= float(_meta.get("claim_max_price", 0))

func _choice_label(c: Dictionary) -> String:
	var parts: Array = [str(c.get("format", ""))]
	var res = c.get("resolution", null)
	if res != null and str(res) != "":
		parts.append(str(res))
	var text := " ".join(parts)
	var sz = c.get("size", null)
	if sz != null and str(sz) != "":
		text += "  ·  " + str(sz)
	return text

func _split_key(key: String) -> Array:
	var i := key.find("|")
	return [key, ""] if i < 0 else [key.substr(0, i), key.substr(i + 1)]

func _file_for(effect: Dictionary, key: String) -> Dictionary:
	var kv := _split_key(key)
	for f in effect.get("files", []):
		if str(f.get("format", "")) == kv[0] and str(f.get("resolution", "") if f.get("resolution", null) != null else "") == kv[1]:
			return f
	return {}

# ----------------------------------------------------------------- actions
func _show(slug: String) -> void:
	_open = slug
	for it in _items:
		if it["slug"] == slug and it["owned"]:
			_load_files(slug)
	_render()
	_scroll.scroll_vertical = 0

func _back() -> void:
	_open = ""
	_render()
	_scroll.scroll_vertical = 0

func _buy(slug: String) -> void:
	CghConfig.open_url_safe("%s/collections/%s?src=godot" % [CghConfig.web_base(), slug.uri_encode()])

func _claim(slug: String) -> void:
	if _busy.has(slug):
		return
	_busy[slug] = true
	_render()
	var res := await _call(HTTPClient.METHOD_POST, "/api/addon-collections/claim", {"collection": slug}, _token())
	_busy.erase(slug)
	if int(res["status"]) == 200:
		_say("✓ Collection claimed. It is yours now.", true)
		invalidate()
		await _load(true)
		if _open == slug:
			_show(slug)
	else:
		_say("✗ " + _problem(res, "Could not claim this collection."), false)
		_render()

func _dir(slug: String) -> String:
	var d := CghConfig.primary_download_dir().path_join("Collections").path_join(slug.validate_filename())
	DirAccess.make_dir_recursive_absolute(d)
	return d if DirAccess.dir_exists_absolute(d) else ""

# A finished earlier download of this file (so it is imported, not fetched again), or "".
func _have(slug: String, filename: String) -> String:
	if filename == "":
		return ""
	var p := CghConfig.primary_download_dir().path_join("Collections").path_join(slug.validate_filename()).path_join(CghConfig.safe_download_name(filename))
	if FileAccess.file_exists(p):
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null and f.get_length() > 0:
			return p
	return ""

func _download(slug: String, effect_id: String) -> void:
	var d = _files.get(slug)
	if typeof(d) != TYPE_DICTIONARY:
		return
	for e in d.get("effects", []):
		if str(e.get("id", "")) == effect_id:
			var f := _file_for(e, str(_fmt.get(slug, "")))
			if f.is_empty():
				_say("This asset has no file in the chosen format.", false)
				return
			_start(slug, effect_id, str(e.get("name", "Asset")), str(f.get("name", "")), str(f.get("format", "")), true, "")
			return

func _download_all(slug: String) -> void:
	var key := str(_fmt.get(slug, ""))
	var d = _files.get(slug)
	if key == "" or typeof(d) != TYPE_DICTIONARY:
		_say("Choose a format first.", false)
		return
	var res := await _call(HTTPClient.METHOD_POST, "/api/addon-collections/download", {"collection": slug, "all": key}, _token())
	var data = res["json"].get("data", {})
	var files: Array = data.get("files", []) if typeof(data) == TYPE_DICTIONARY else []
	if int(res["status"]) != 200 or files.is_empty():
		_say("✗ " + _problem(res, "The download could not start."), false)
		return
	var by_name := {}
	for e in d.get("effects", []):
		for f in e.get("files", []):
			by_name[str(f.get("name", ""))] = e
	var n := 0
	for f in files:
		var e: Dictionary = by_name.get(str(f.get("fileName", "")), {})
		_queue.append({"slug": slug, "id": str(e.get("id", "all%d" % n)), "name": str(e.get("name", f.get("fileName", ""))),
			"fn": str(f.get("fileName", "")), "url": str(f.get("url", "")), "fmt": str(_split_key(key)[0])})
		n += 1
	_say("Downloading %d files to your downloads folder…" % files.size(), true)
	_pump()
	_render()

func _pump() -> void:
	while not _queue.is_empty() and _active.size() < MAX_PARALLEL:
		var j: Dictionary = _queue.pop_front()
		_start(j["slug"], j["id"], j["name"], j["fn"], j["fmt"], false, j["url"])

func _start(slug: String, effect_id: String, ename: String, filename: String, fmt: String, do_import: bool, known_url: String) -> void:
	var key := "%s|%s" % [slug, effect_id]
	if _active.has(key):
		return
	var req := HTTPRequest.new()
	add_child(req)
	_active[key] = {"pct": 0, "req": req}
	var have := _have(slug, filename)
	if have != "":
		_finish(key, req, true, have, ename, fmt, do_import, "")
		return
	_render()
	var url := known_url
	var fname := filename
	if url == "":
		var res := await _call(HTTPClient.METHOD_POST, "/api/addon-collections/download", {"collection": slug, "effect": effect_id, "file": filename}, _token())
		var data = res["json"].get("data", {})
		if int(res["status"]) != 200 or typeof(data) != TYPE_DICTIONARY or str(data.get("url", "")) == "":
			_finish(key, req, false, "", ename, fmt, do_import, _problem(res, "The download could not start."))
			return
		url = str(data["url"])
		fname = str(data.get("fileName", filename))
	if not CghConfig.is_trusted_url(url):
		_finish(key, req, false, "", ename, fmt, do_import, "Blocked a download link that is not on a CGHEVEN server.")
		return
	var folder := _dir(slug)
	if folder == "":
		_finish(key, req, false, "", ename, fmt, do_import, "Cannot create the downloads folder.")
		return
	var dest := folder.path_join(CghConfig.safe_download_name(fname))
	req.download_file = dest
	req.timeout = 0.0
	var err := req.request(url, PackedStringArray(["User-Agent: CGHEVEN-Godot/%s" % CghConfig.ADDON_VERSION, "Referer: https://cgheven.com/"]))
	if err != OK:
		_finish(key, req, false, dest, ename, fmt, do_import, "Download could not start (err %d)" % err)
		return
	var out: Array = await req.request_completed
	var good: bool = int(out[0]) == HTTPRequest.RESULT_SUCCESS and int(out[1]) >= 200 and int(out[1]) < 300
	_finish(key, req, good, dest, ename, fmt, do_import, "" if good else "Download failed (HTTP %d)" % int(out[1]))

func _finish(key: String, req: HTTPRequest, ok: bool, path: String, ename: String, fmt: String, do_import: bool, err: String) -> void:
	_active.erase(key)
	_bars.erase(key)
	if is_instance_valid(req):
		req.queue_free()
	if not ok:
		if path != "" and FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		_say("✗ " + (err if err != "" else "Download failed."), false)
	else:
		_say("✓ Downloaded " + ename, true)
		if do_import:
			var ext := path.get_extension().to_lower()
			if ext in IMPORTABLE:
				var msg := CghImportRouter.import_file(path, "flipbooks")
				_say(("✓ %s imported" % ename) if not msg.to_lower().contains("failed") else ("✗ " + msg), not msg.to_lower().contains("failed"))
			else:
				_say("Saved to your downloads folder. Godot cannot import this format.", true)
	_pump()
	_render()

# ----------------------------------------------------------------- drawing
func _style(bg: Color, border: Color = Color(0, 0, 0, 0), radius := 8) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1 if border.a > 0.0 else 0)
	s.set_corner_radius_all(radius)
	return s

func _button(text: String, kind := "ghost", enabled := true) -> Button:
	var b := Button.new()
	b.text = text
	b.disabled = not enabled
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if enabled else Control.CURSOR_ARROW
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var normal := _style(Color(0.5, 0.5, 0.5, 0.07), CghConfig.C_BORDER, 5)
	var hover := _style(CghConfig.C_ACCENT_DIM, CghConfig.C_ACCENT, 5)
	var font := CghConfig.C_TEXT2
	match kind:
		"cta":
			normal = _style(CghConfig.C_BRAND, Color(0, 0, 0, 0), 5)
			hover = _style(CghConfig.C_BRAND_HOVER, Color(0, 0, 0, 0), 5)
			font = Color.WHITE
		"accent":
			normal = _style(CghConfig.C_ACCENT, Color(0, 0, 0, 0), 5)
			hover = _style(CghConfig.C_ACCENT_HOVER, Color(0, 0, 0, 0), 5)
			font = Color.WHITE
		"claim":
			normal = _style(Color(0, 0, 0, 0), CghConfig.C_ACCENT, 5)
			hover = _style(CghConfig.C_ACCENT_DIM, CghConfig.C_ACCENT, 5)
			font = CghConfig.C_ACCENT
	var off := _style(Color(0.5, 0.5, 0.5, 0.05), CghConfig.C_BORDER, 5)
	for sb in [normal, hover, off]:
		sb.content_margin_left = 10
		sb.content_margin_right = 10
		sb.content_margin_top = 5
		sb.content_margin_bottom = 5
	for st in ["normal", "pressed", "focus"]:
		b.add_theme_stylebox_override(st, normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("disabled", off)
	b.add_theme_color_override("font_color", font)
	b.add_theme_color_override("font_hover_color", Color.WHITE if kind in ["cta", "accent"] else CghConfig.C_ACCENT_HOVER)
	b.add_theme_color_override("font_disabled_color", CghConfig.C_TEXT3)
	b.add_theme_font_size_override("font_size", 11)
	return b

func _label(text: String, color: Color, size := 11, wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l

func _thumb(url: String, w: float) -> TextureRect:
	var r := TextureRect.new()
	r.custom_minimum_size = Vector2(0, w)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	if url == "":
		return r
	if _tex.has(url):
		r.texture = _tex[url]
	else:
		if not _tex_rects.has(url):
			_tex_rects[url] = []
		_tex_rects[url].append(r)
		if not _tex_asked.has(url):
			_tex_asked[url] = true
			_thumb_pending.append(url)
			_pump_thumbs()
	return r

func _pump_thumbs() -> void:
	while _thumb_busy < 4 and not _thumb_pending.is_empty():
		var url: String = _thumb_pending.pop_front()
		_thumb_busy += 1
		_fetch_thumb(url)

func _fetch_thumb(url: String) -> void:
	var req := HTTPRequest.new()
	req.timeout = 20.0
	add_child(req)
	if req.request(url, PackedStringArray(["User-Agent: CGHEVEN-Godot/%s" % CghConfig.ADDON_VERSION, "Referer: https://cgheven.com/"])) != OK:
		req.queue_free()
		_thumb_busy -= 1
		return
	var out: Array = await req.request_completed
	req.queue_free()
	_thumb_busy -= 1
	if int(out[0]) == HTTPRequest.RESULT_SUCCESS and int(out[1]) == 200:
		var img := _decode(out[3])
		if img != null:
			var t := ImageTexture.create_from_image(img)
			_tex[url] = t
			for r in _tex_rects.get(url, []):
				if is_instance_valid(r):
					r.texture = t
			_tex_rects.erase(url)
	_pump_thumbs()

func _decode(body: PackedByteArray) -> Image:
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if body.size() > 12 and body[0] == 0x52 and body[1] == 0x49 and body[8] == 0x57:
		err = img.load_webp_from_buffer(body)
	elif body.size() > 4 and body[0] == 0x89 and body[1] == 0x50:
		err = img.load_png_from_buffer(body)
	elif body.size() > 3 and body[0] == 0xFF and body[1] == 0xD8:
		err = img.load_jpg_from_buffer(body)
	return img if err == OK else null

func _badge(text: String, color: Color) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style(color, Color(0, 0, 0, 0), 3))
	var l := _label(text, Color.WHITE, 9)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 5)
	m.add_theme_constant_override("margin_right", 5)
	m.add_theme_constant_override("margin_top", 1)
	m.add_theme_constant_override("margin_bottom", 1)
	m.add_child(l)
	p.add_child(m)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p

func _card_width() -> float:
	# Page margin is 10 on each side, grid gap 8: the cards share the whole row, so nothing is left over on either side.
	var avail: float = maxf(size.x, 240.0) - 20.0 - float(_cols - 1) * 8.0
	return clampf(floorf(avail / float(_cols)), 120.0, 400.0)

func _card(item: Dictionary, w: float) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(0, 0)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", _style(CghConfig.C_CARD, CghConfig.C_BORDER, 8))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	card.add_child(v)
	var cover := str(item["cover"])
	if cover == "" and not item["effects"].is_empty():
		cover = str(item["effects"][0].get("image", ""))
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(0, w)
	var tr := _thumb(cover, w)
	holder.add_child(tr)
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	var badge := _badge(("✓ Claimed" if item["claimedWithStudio"] else "✓ Unlocked") if item["owned"] else "🔒 Locked", CghConfig.C_OK if item["owned"] else CghConfig.C_RES_BADGE)
	badge.position = Vector2(6, 6)
	holder.add_child(badge)
	holder.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var slug: String = item["slug"]
	holder.gui_input.connect(func(ev: InputEvent): if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT: _show(slug))
	v.add_child(holder)
	var box := MarginContainer.new()
	for s in ["margin_left", "margin_right"]:
		box.add_theme_constant_override(s, 8)
	box.add_theme_constant_override("margin_top", 6)
	box.add_theme_constant_override("margin_bottom", 8)
	v.add_child(box)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	box.add_child(col)
	col.add_child(_label(str(item["title"]), CghConfig.C_TEXT1, 11, true))
	var n := int(item["effectCount"])
	col.add_child(_label("%d asset%s%s" % [n, "" if n == 1 else "s", "" if item["owned"] or _price_text(item) == "" else "  ·  " + _price_text(item)], CghConfig.C_TEXT3, 10))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	if item["owned"]:
		var o := _button("Open", "accent")
		o.pressed.connect(func(): _show(slug))
		row.add_child(o)
	else:
		if _can_claim(item):
			var c := _button("Claim free", "claim", not _busy.has(slug))
			c.pressed.connect(func(): _claim(slug))
			row.add_child(c)
		var b := _button(("Buy " + _price_text(item)).strip_edges(), "cta")
		b.pressed.connect(func(): _buy(slug))
		row.add_child(b)
	col.add_child(row)
	return card

func _grid(parent: Control, cards: Array) -> void:
	var g := GridContainer.new()
	g.columns = _cols
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_theme_constant_override("h_separation", 8)
	g.add_theme_constant_override("v_separation", 8)
	for c in cards:
		g.add_child(c)
	parent.add_child(g)

func _clear() -> void:
	for c in _body.get_children():
		c.queue_free()
	_bars.clear()
	_tex_rects.clear()
	for u in _tex_asked.keys():
		if not _tex.has(u) and not _thumb_pending.has(u):
			pass

func _render() -> void:
	if _body == null:
		return
	_clear()
	var margin := MarginContainer.new()
	for s in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(s, 10)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(col)
	var item := {}
	if _open != "":
		for it in _items:
			if it["slug"] == _open:
				item = it
		if item.is_empty():
			_open = ""
	if item.is_empty():
		_render_list(col)
	else:
		_render_detail(col, item)

func _header(col: VBoxContainer, title: String, back := false) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	if back:
		var b := _button("‹ Back")
		b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		b.pressed.connect(_back)
		row.add_child(b)
	else:
		var t := _label(title, CghConfig.C_TEXT1, 13, true)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(t)
	if back:
		var sp := Control.new()
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(sp)
	var r := _button("↺")
	r.size_flags_horizontal = Control.SIZE_SHRINK_END
	r.tooltip_text = "Refresh"
	r.pressed.connect(func(): invalidate(); _load(true))
	row.add_child(r)
	col.add_child(row)
	if back:
		col.add_child(_label(title, CghConfig.C_TEXT1, 14, true))
	if _status != "":
		col.add_child(_label(_status.left(120), CghConfig.C_TEXT2, 10, true))

func _studio_banner(col: VBoxContainer) -> void:
	if not bool(_meta.get("studio", false)):
		return
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style(CghConfig.C_ACCENT_DIM, Color(0.357, 0.486, 1.0, 0.3), 8))
	var m := MarginContainer.new()
	for s in ["margin_left", "margin_right"]:
		m.add_theme_constant_override(s, 11)
	for s in ["margin_top", "margin_bottom"]:
		m.add_theme_constant_override(s, 8)
	p.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	m.add_child(v)
	if str(_meta.get("role", "")) == "member":
		v.add_child(_label("Studio  ·  collections your team owner claims are unlocked for you", CghConfig.C_TEXT1, 11, true))
	else:
		v.add_child(_label("Studio  ·  %d of %d free collections left this month" % [int(_meta.get("claims_left", 0)), int(_meta.get("claims_limit", 2))], CghConfig.C_TEXT1, 11, true))
		if _meta.get("claim_max_price", null) != null:
			v.add_child(_label("Free claims cover collections up to $%s" % str(_meta["claim_max_price"]), CghConfig.C_TEXT2, 10))
	col.add_child(p)

func _render_list(col: VBoxContainer) -> void:
	_header(col, "Collections")
	_studio_banner(col)
	if _loading and _items.is_empty():
		col.add_child(_label("Loading collections…", CghConfig.C_TEXT2, 12))
		return
	if _error != "" and _items.is_empty():
		col.add_child(_label(_error, CghConfig.C_TEXT2, 12, true))
		var b := _button("Try again", "accent")
		b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		b.pressed.connect(func(): _load(true))
		col.add_child(b)
		return
	if _items.is_empty():
		col.add_child(_label("No collections yet.", CghConfig.C_TEXT2, 12))
		return
	var owned: Array = _items.filter(func(i): return i["owned"])
	var other: Array = _items.filter(func(i): return not i["owned"])
	var w := _card_width()
	if not owned.is_empty():
		col.add_child(_label(("Your collections (%d)" % owned.size()).to_upper(), CghConfig.C_TEXT3, 10))
		_grid(col, owned.map(func(i): return _card(i, w)))
	if not other.is_empty():
		if not owned.is_empty():
			col.add_child(_label("MORE COLLECTIONS", CghConfig.C_TEXT3, 10))
		_grid(col, other.map(func(i): return _card(i, w)))
	if _as_user == "":
		col.add_child(_label("Sign in (Login button) to unlock the collections you own.", CghConfig.C_TEXT2, 11, true))

func _effect_card(item: Dictionary, e: Dictionary, w: float, d) -> PanelContainer:
	var slug: String = item["slug"]
	var eid := str(e.get("id", ""))
	var key := "%s|%s" % [slug, eid]
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(0, 0)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", _style(CghConfig.C_CARD, CghConfig.C_BORDER, 8))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	card.add_child(v)
	v.add_child(_thumb(str(e.get("image", "")), w))
	var box := MarginContainer.new()
	for s in ["margin_left", "margin_right"]:
		box.add_theme_constant_override(s, 8)
	box.add_theme_constant_override("margin_top", 5)
	box.add_theme_constant_override("margin_bottom", 8)
	v.add_child(box)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	box.add_child(col)
	col.add_child(_label(str(e.get("name", "Asset")), CghConfig.C_TEXT1, 11, true))
	if not item["owned"]:
		col.add_child(_button("🔒 Locked", "ghost", false))
	elif _active.has(key):
		var bar := ProgressBar.new()
		bar.min_value = 0
		bar.max_value = 100
		bar.value = int(_active[key]["pct"])
		bar.custom_minimum_size = Vector2(0, 16)
		col.add_child(bar)
		_bars[key] = bar
	elif typeof(d) == TYPE_DICTIONARY:
		var eff := {}
		for x in d.get("effects", []):
			if str(x.get("id", "")) == eid:
				eff = x
		var ok := not eff.is_empty() and not _file_for(eff, str(_fmt.get(slug, ""))).is_empty()
		var have_it := ok and _have(slug, str(_file_for(eff, str(_fmt.get(slug, ""))).get("name", ""))) != ""
		var b := _button(("Import" if have_it else "Download") if ok else "Not in this format", "ghost", ok)
		b.pressed.connect(func(): _download(slug, eid))
		col.add_child(b)
	else:
		col.add_child(_label("…", CghConfig.C_TEXT3))
	return card

func _render_detail(col: VBoxContainer, item: Dictionary) -> void:
	var slug: String = item["slug"]
	_header(col, str(item["title"]), true)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(CghConfig.C_CARD, CghConfig.C_BORDER, 8))
	var m := MarginContainer.new()
	for s in ["margin_left", "margin_right"]:
		m.add_theme_constant_override(s, 10)
	for s in ["margin_top", "margin_bottom"]:
		m.add_theme_constant_override(s, 8)
	panel.add_child(m)
	var flow := VBoxContainer.new()
	flow.add_theme_constant_override("separation", 8)
	m.add_child(flow)
	var d = _files.get(slug) if item["owned"] else null
	if item["owned"]:
		if typeof(d) == TYPE_STRING and d == "error":
			flow.add_child(_label("Could not load the files.", CghConfig.C_TEXT2))
			var b := _button("Try again", "accent")
			b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			b.pressed.connect(func(): _files.erase(slug); _load_files(slug); _render())
			flow.add_child(b)
		elif typeof(d) != TYPE_DICTIONARY:
			flow.add_child(_label("Loading files…", CghConfig.C_TEXT2))
		else:
			var choices: Array = d.get("downloadAll", [])
			var frow := HBoxContainer.new()
			frow.add_theme_constant_override("separation", 8)
			var fl := _label("Format", CghConfig.C_TEXT2, 11)
			fl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			frow.add_child(fl)
			var opt := OptionButton.new()
			opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			opt.add_theme_font_size_override("font_size", 11)
			var sel := 0
			for i in choices.size():
				opt.add_item(_choice_label(choices[i]), i)
				if str(choices[i].get("key", "")) == str(_fmt.get(slug, "")):
					sel = i
			if not choices.is_empty():
				opt.select(sel)
			opt.item_selected.connect(func(idx: int): _fmt[slug] = str(choices[idx].get("key", "")); _render())
			frow.add_child(opt)
			flow.add_child(frow)
			var cnt: int = item["effects"].size()
			if not choices.is_empty():
				cnt = int(choices[sel].get("count", cnt))
			var all := _button("Download all (%d files)" % cnt, "accent", _queue.is_empty())
			all.pressed.connect(func(): _download_all(slug))
			flow.add_child(all)
			if not _queue.is_empty():
				flow.add_child(_label("%d more waiting…" % _queue.size(), CghConfig.C_TEXT3, 10))
			var picked := str(_fmt.get(slug, ""))
			if not choices.is_empty() and not (str(_split_key(picked)[0]).to_lower() in IMPORTABLE):
				flow.add_child(_label("Godot cannot import this format. Files are saved to your CGHEVEN downloads folder.", CghConfig.C_TEXT3, 10, true))
	else:
		flow.add_child(_label("🔒 Locked. Buy it once and it unlocks here and in every CGHEVEN add-on.", CghConfig.C_TEXT2, 11, true))
		if _can_claim(item):
			var c := _button("Claim free with Studio", "claim", not _busy.has(slug))
			c.pressed.connect(func(): _claim(slug))
			flow.add_child(c)
		var b2 := _button(("Buy " + _price_text(item)).strip_edges(), "cta")
		b2.pressed.connect(func(): _buy(slug))
		flow.add_child(b2)
	col.add_child(panel)
	var w: float = _card_width()
	var cards: Array = []
	for e in item["effects"]:
		cards.append(_effect_card(item, e, w, d))
	_grid(col, cards)
