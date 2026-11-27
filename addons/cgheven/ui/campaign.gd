@tool
extends RefCounted
## CGHEVEN campaign banner and popup. Draws meta.banner and meta.popup from the server, applies
## the show rules and reports shown / clicked / closed to analytics. Everything shown is decided
## in the admin ("Addon Campaigns").

const _PREF := "campaign_state"
const _ORANGE := Color("ff7a2e")
const _INK := Color("1a0d04")
const _TEXT := Color("f3f2ef")
const _MUTED := Color("8a8a90")
const _GOLD := Color("ffb07a")

var _host: Control        # the dock; the popup covers it
var _track: Callable      # (event: String, props: Dictionary)
var _busy: Callable       # () -> bool, true while a download runs
var _shown_this_run := {}
var _pending := {}

func setup(host: Control, track: Callable, busy: Callable) -> void:
	_host = host
	_track = track
	_busy = busy

# ── helpers ────────────────────────────────────────────────────────────
static func _s(d: Dictionary, k: String) -> String:
	var v = d.get(k)
	return "" if v == null else str(v).strip_edges()

static func _name(m: Dictionary) -> String:
	# The old banner setting has no campaign, so its title names it.
	var n := _s(m, "campaign")
	if n == "":
		n = _s(m, "title")
	return n if n != "" else "banner"

static func _key(m: Dictionary) -> String:
	var id = m.get("campaign_id")
	return "c%d" % int(id) if id != null else "t:" + _name(m)

static func _today() -> String:
	return Time.get_date_string_from_system()

static func _read(key: String) -> Dictionary:
	var all = CghConfig._read_prefs().get(_PREF, {})
	if all is Dictionary and all.get(key) is Dictionary:
		return all[key]
	return {}

static func _remember(key: String, change: Dictionary) -> void:
	var prefs := CghConfig._read_prefs()
	var all = prefs.get(_PREF, {})
	if not (all is Dictionary):
		all = {}
	var entry = all.get(key, {})
	if not (entry is Dictionary):
		entry = {}
	entry.merge(change, true)
	all[key] = entry
	prefs[_PREF] = all
	CghConfig._write_prefs(prefs)

func _report(event: String, m: Dictionary, extra := {}) -> void:
	var props := {"campaign": _name(m), "campaign_id": m.get("campaign_id")}
	props.merge(extra, true)
	_track.call(event, props)

static func _ends_in(value: String) -> String:
	if value == "":
		return ""
	var target := Time.get_unix_time_from_datetime_string(value.substr(0, 19))   # UTC
	var secs := int(target - Time.get_unix_time_from_system())
	if secs <= 0:
		return ""
	return "%02dd %02dh %02dm %02ds" % [secs / 86400, secs % 86400 / 3600, secs % 3600 / 60, secs % 60]

static func _label(text: String, color: Color, size: int, centered := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	if centered:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

static func _box(color: Color, radius: int, pad_x := 8, pad_y := 3, border := Color.TRANSPARENT) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	if border.a > 0.0:
		sb.border_color = border
		sb.set_border_width_all(1)
	return sb

static func _badge(text: String) -> Label:
	var l := _label(text.to_upper(), _INK, 9)
	l.add_theme_stylebox_override("normal", _box(_ORANGE, 8, 7, 1))
	l.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l

static func _button(text: String, bg: Color, fg: Color, size := 11) -> Button:
	var b := Button.new()
	b.text = text
	var sb := _box(bg, 7, 10, 4)
	for state in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(state, sb)
	for name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(name, fg)
	b.add_theme_font_size_override("font_size", size)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return b

# ── banner: always one line ────────────────────────────────────────────
func render_banner(panel: PanelContainer, meta: Dictionary) -> void:
	for c in panel.get_children():
		panel.remove_child(c)
		c.queue_free()
	panel.visible = false
	var b = meta.get("banner")
	if not (b is Dictionary) or not b.get("enabled", false):
		return
	var key := _key(b)
	if str(_read(key).get("bannerClosed", "")) == _today():
		return
	panel.add_theme_stylebox_override("panel", _box(Color("1b1009"), 6, 10, 6, Color("4a2a14")))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var parts := {}
	if _s(b, "badge") != "":
		parts["badge"] = _badge(_s(b, "badge"))
		row.add_child(parts["badge"])
	for item in [["title", _TEXT, 12], ["message", Color("b9b6b0"), 11]]:
		if _s(b, item[0]) != "":
			var l := _label(_s(b, item[0]), item[1], item[2])
			l.clip_text = true
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			l.tooltip_text = l.text
			l.mouse_filter = Control.MOUSE_FILTER_PASS
			parts[item[0]] = l
			row.add_child(l)
	if not parts.has("title") and not parts.has("message"):
		var space := Control.new()
		space.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(space)

	var until := _s(b, "countdown_until")
	if b.get("show_countdown", false) and _ends_in(until) != "":
		var ends := _label("", _GOLD, 11)
		parts["ends"] = ends
		row.add_child(ends)
		var timer := Timer.new()
		timer.wait_time = 1.0
		timer.autostart = true
		timer.timeout.connect(func():
			var left := _ends_in(until)
			ends.text = (("Ends in " if row.size.x >= 430 else "") + left) if left != "" else "")
		row.add_child(timer)
		ends.text = _ends_in(until)

	var button_label := _s(b, "button_label")
	var url := _s(b, "button_url")
	if button_label != "" and url != "":
		var cta := _button(button_label, _ORANGE, _INK)
		cta.pressed.connect(func():
			_report("addon_banner_clicked", b, {"button": button_label})
			CghConfig.open_url_safe(url))
		row.add_child(cta)
	var x := _button("✕", Color.TRANSPARENT, Color("c9c9ce"))
	x.pressed.connect(func():
		_remember(key, {"bannerClosed": _today()})
		_report("addon_banner_closed", b)
		panel.visible = false)
	row.add_child(x)

	row.resized.connect(_fit.bind(row, parts))
	panel.add_child(row)
	panel.visible = true
	# "shown" is counted once a day per event, however often the grid reloads.
	if str(_read(key).get("bannerSeen", "")) != _today():
		_remember(key, {"bannerSeen": _today()})
		_report("addon_banner_shown", b)

## Narrow docks drop the least important parts first.
func _fit(row: HBoxContainer, parts: Dictionary) -> void:
	var width := row.size.x
	if parts.has("badge"):
		parts["badge"].visible = width >= 340
	if parts.has("message"):
		parts["message"].visible = width >= 640
	if parts.has("title"):
		var title: Label = parts["title"]
		if parts.has("message") and width >= 640:
			# The title takes its own width, the message the free space.
			var natural := title.get_theme_font("font").get_string_size(title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
			title.size_flags_horizontal = Control.SIZE_FILL
			title.custom_minimum_size.x = minf(natural + 4.0, width / 3.0)
		else:
			title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			title.custom_minimum_size.x = 0.0

# ── popup ──────────────────────────────────────────────────────────────
func _may_show(p: Dictionary) -> bool:
	# Not after its button was clicked, not after max_dismiss closes, at most per_day a day.
	var entry := _read(_key(p))
	var rules = p.get("rules", {})
	if not (rules is Dictionary):
		rules = {}
	if entry.get("clicked", false):
		return false
	if int(entry.get("closes", 0)) >= int(rules.get("max_dismiss", 3)):
		return false
	return not (str(entry.get("day", "")) == _today() and int(entry.get("shown", 0)) >= int(rules.get("per_day", 1)))

## Shows the popup a few seconds after the library has loaded, if the rules allow it.
func schedule_popup(meta: Dictionary) -> void:
	var p = meta.get("popup")
	if not (p is Dictionary) or not p.get("enabled", false) or not _host.is_inside_tree():
		return
	var key := _key(p)
	if _shown_this_run.has(key) or _pending.has(key) or not _may_show(p):
		return
	_pending[key] = true
	var rules = p.get("rules", {})
	var delay := float(rules.get("delay_seconds", 5)) if rules is Dictionary else 5.0
	_host.get_tree().create_timer(maxf(delay, 0.1)).timeout.connect(_attempt.bind(p, key))

func _attempt(p: Dictionary, key: String) -> void:
	if not is_instance_valid(_host) or not _host.is_inside_tree():
		return
	# Never interrupt a download or a hidden dock; try again later.
	if not _host.is_visible_in_tree() or _busy.call():
		_host.get_tree().create_timer(30.0).timeout.connect(_attempt.bind(p, key))
		return
	_pending.erase(key)
	if _shown_this_run.has(key) or not _may_show(p):
		return
	_shown_this_run[key] = true
	var entry := _read(key)
	var shown := int(entry.get("shown", 0)) if str(entry.get("day", "")) == _today() else 0
	_remember(key, {"day": _today(), "shown": shown + 1})
	_open_popup(p, key)
	_report("addon_popup_shown", p)

func _open_popup(p: Dictionary, key: String) -> void:
	var veil := PanelContainer.new()
	veil.add_theme_stylebox_override("panel", _box(Color(0, 0, 0, 0.76), 0, 12, 12))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	veil.add_child(scroll)
	var centre := CenterContainer.new()
	centre.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	centre.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(centre)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _box(Color("0b0b0c"), 14, 14, 10, Color("2a2a30")))
	card.custom_minimum_size.x = clampf(_host.size.x - 48.0, 200.0, 360.0)
	centre.add_child(card)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	card.add_child(body)

	var shut := func(how: String):
		veil.queue_free()
		_remember(key, {"closes": int(_read(key).get("closes", 0)) + 1})
		_report("addon_popup_closed", p, {"how": how})

	var x := _button("✕", Color.TRANSPARENT, Color("c9c9ce"), 13)
	x.size_flags_horizontal = Control.SIZE_SHRINK_END
	x.pressed.connect(func(): shut.call("x"))
	body.add_child(x)
	var image_url := _s(p, "image")
	var picture: TextureRect = null
	if image_url != "" and CghConfig.is_trusted_url(image_url):
		picture = TextureRect.new()
		# A small header, so the offer stays the biggest thing (same as the Blender popup).
		picture.custom_minimum_size = Vector2(200, 44)
		picture.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		picture.visible = false
		body.add_child(picture)
	if _s(p, "badge") != "":
		body.add_child(_badge(_s(p, "badge")))
	if _s(p, "title") != "":
		body.add_child(_label(_s(p, "title"), _TEXT, 19, true))
	if _s(p, "message") != "":
		body.add_child(_label(_s(p, "message"), Color("a1a1a8"), 12, true))
	var until := _s(p, "countdown_until")
	if p.get("show_countdown", false) and _ends_in(until) != "":
		var count := _label("Ends in " + _ends_in(until), _GOLD, 13, true)
		body.add_child(count)
		var timer := Timer.new()
		timer.wait_time = 1.0
		timer.autostart = true
		timer.timeout.connect(func():
			var left := _ends_in(until)
			count.text = ("Ends in " + left) if left != "" else "")
		count.add_child(timer)

	var offers = p.get("offers", [])
	if offers is Array:
		for o in offers:
			if o is Dictionary:
				body.add_child(_offer(o))

	var button_label := _s(p, "button_label")
	var url := _s(p, "button_url")
	if button_label != "" and url != "":
		var cta := _button(button_label, _ORANGE, _INK, 13)
		cta.pressed.connect(func():
			veil.queue_free()
			_remember(key, {"clicked": true})
			_report("addon_popup_clicked", p, {"button": button_label})
			CghConfig.open_url_safe(url))
		body.add_child(cta)
	var dismiss := _s(p, "dismiss_label")
	var no := _button(dismiss if dismiss != "" else "No thanks", Color.TRANSPARENT, _MUTED)
	no.pressed.connect(func(): shut.call("no_thanks"))
	body.add_child(no)

	_host.add_child(veil)
	if picture != null:
		_load_picture(picture, image_url)

func _offer(o: Dictionary) -> PanelContainer:
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", _box(Color("1a0f08"), 10, 12, 8, Color("4a2a14")))
	var row := HBoxContainer.new()
	box.add_child(row)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left)
	var title := _label(_s(o, "title"), _TEXT, 13)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(title)
	if _s(o, "line") != "":
		var line := _label(_s(o, "line"), _MUTED, 11)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		left.add_child(line)
	if _s(o, "price") != "":
		var right := VBoxContainer.new()
		row.add_child(right)
		if _s(o, "old_price") != "":
			right.add_child(_label("was " + _s(o, "old_price"), Color("6e6e74"), 11))
		right.add_child(_label(_s(o, "price"), _TEXT, 16))
	return box

func _load_picture(picture: TextureRect, url: String) -> void:
	var http := HTTPRequest.new()
	http.timeout = 20.0
	picture.add_child(http)
	http.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, data: PackedByteArray):
		if result != HTTPRequest.RESULT_SUCCESS or code != 200 or data.size() < 12:
			return
		var img := Image.new()
		var err := ERR_INVALID_DATA
		if data[0] == 0x89:
			err = img.load_png_from_buffer(data)
		elif data[0] == 0xFF:
			err = img.load_jpg_from_buffer(data)
		elif data[0] == 0x52:
			err = img.load_webp_from_buffer(data)
		if err == OK:
			picture.texture = ImageTexture.create_from_image(img)
			picture.visible = true
		http.queue_free())
	http.request(url)
