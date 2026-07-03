@tool
extends AcceptDialog
class_name CghLoginDialog
## Sign-in / Account dialog. Renders TWO views from the same window:
##   • Guest    → "Sign in to CGHEVEN" + [ Login ][ Sign up ] brand buttons.
##   • Logged in → account card (email · plan · version) + [ Logout ].
## The top-nav button opens this for both states, so account details live HERE
## (the Settings popup no longer carries them).

signal logout_requested()

var auth: CghAuth
var _content: VBoxContainer
var _msg: Label

func build() -> void:
	title = "CGHEVEN — Account"
	min_size = Vector2i(380, 0)
	get_ok_button().visible = false   # custom buttons below

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 10)
	_content.custom_minimum_size = Vector2(360, 0)
	add_child(_content)

	auth.login_failed.connect(func(m): _set_msg(m))
	auth.logged_in.connect(func(_p): _render(); hide())
	_render()

## Open the dialog showing the right view for the current auth state.
func open() -> void:
	_render()
	reset_size()
	popup_centered()

## Re-render in place (called when auth state changes while open).
func refresh() -> void:
	if _content:
		_render()

func _render() -> void:
	if _content == null:
		return
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	if auth.is_logged_in():
		_build_profile()
	else:
		_build_login()

# ---------------- logged-in: account card ----------------
func _build_profile() -> void:
	title = "CGHEVEN — Account"
	var h := Label.new()
	h.text = "Your account"
	h.add_theme_color_override("font_color", CghConfig.C_TEXT1)
	h.add_theme_font_size_override("font_size", 16)
	_content.add_child(h)

	_kv("Account", auth.email if auth.email != "" else "Logged in")
	_kv("Plan", auth.plan)
	if auth.expires_at != "":
		_kv("Expires", _fmt_date(auth.expires_at))
	_kv("Version", CghConfig.ADDON_VERSION)

	# Premium users (Pro/Studio/Bundle) have nothing to upgrade to — hide the button.
	if not auth.is_premium():
		var up := _brand_btn("⚡ Upgrade Plan", func(): OS.shell_open(CghConfig.pricing_url()))
		_content.add_child(up)

	var lo := Button.new()
	lo.text = "Logout"
	lo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lo.custom_minimum_size = Vector2(0, 30)
	lo.pressed.connect(func(): logout_requested.emit(); hide())
	_content.add_child(lo)

# ---------------- guest: login / sign up ----------------
func _build_login() -> void:
	title = "CGHEVEN — Sign in"
	var h := Label.new()
	h.text = "Sign in to CGHEVEN"
	h.add_theme_color_override("font_color", CghConfig.C_TEXT1)
	h.add_theme_font_size_override("font_size", 16)
	_content.add_child(h)

	var sub := Label.new()
	sub.text = "Log in to download assets for your plan."
	sub.add_theme_color_override("font_color", CghConfig.C_TEXT2)
	sub.add_theme_font_size_override("font_size", 11)
	_content.add_child(sub)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_content.add_child(row)
	row.add_child(_brand_btn("Login", func(): _start(false)))
	row.add_child(_brand_btn("Sign up", func(): _start(true)))

	_msg = Label.new()
	_msg.add_theme_color_override("font_color", CghConfig.C_TEXT2)
	_msg.add_theme_font_size_override("font_size", 11)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content.add_child(_msg)

# Format an ISO date ("2027-06-20T12:06:39.945Z") as "20 Jun 2027" for display.
func _fmt_date(iso: String) -> String:
	if iso == "":
		return ""
	var date := iso.split("T")[0]
	var parts := date.split("-")
	if parts.size() != 3:
		return date
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	var mi := int(parts[1]) - 1
	var mon: String = months[mi] if mi >= 0 and mi < 12 else parts[1]
	return "%s %s %s" % [parts[2], mon, parts[0]]

# ---------------- builders ----------------
func _kv(k: String, val: String) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	var kl := Label.new()
	kl.text = k
	kl.custom_minimum_size = Vector2(80, 0)
	kl.add_theme_color_override("font_color", CghConfig.C_TEXT2)
	kl.add_theme_font_size_override("font_size", 12)
	var vl := Label.new()
	vl.text = val
	vl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	vl.clip_text = true
	vl.add_theme_color_override("font_color", CghConfig.C_TEXT1)
	vl.add_theme_font_size_override("font_size", 12)
	h.add_child(kl)
	h.add_child(vl)
	_content.add_child(h)

func _brand_btn(label: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 34)
	b.add_theme_stylebox_override("normal", CghTheme.brand_button_box())
	b.add_theme_stylebox_override("hover", CghTheme.brand_button_box(true))
	b.add_theme_stylebox_override("pressed", CghTheme.brand_button_box(true))
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.pressed.connect(cb)
	return b

func _start(register: bool) -> void:
	_set_msg("A browser window has opened — log in there, then come back.")
	auth.start_login(register)

func _set_msg(m: String) -> void:
	if _msg:
		_msg.text = m
