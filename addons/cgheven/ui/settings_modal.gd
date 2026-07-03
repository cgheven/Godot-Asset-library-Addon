@tool
extends AcceptDialog
class_name CghSettingsModal
## Compact settings window (AE settings-modal style): App · Downloads ·
## Community. Kept small/dense — all details fit a tight popup. Account details
## live in the panel's Account dialog, not here. Downloads section lets the user
## pick their own save folder.

signal logout_requested()
signal check_updates_requested()
signal download_dir_changed()

var auth: CghAuth
var _path_lbl: Label
var _dir_dialog: FileDialog
var _upgrade_btn: Button   # hidden for premium users (nothing to upgrade to)

func build() -> void:
	title = "CGHEVEN — Settings"
	# Small floor; the dialog auto-sizes to its (now compact) content.
	min_size = Vector2i(320, 0)
	# Wrap the window to its content's minimum size every time it opens — without this
	# the FIRST popup opens huge (content min-size not computed yet) and only the 2nd is
	# correct. wrap_controls makes it size right on the very first open.
	wrap_controls = true
	get_ok_button().text = "Close"

	# outer padding (tight)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 7)
	margin.add_theme_constant_override("margin_bottom", 7)
	add_child(margin)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	v.custom_minimum_size = Vector2(300, 0)
	margin.add_child(v)

	# ---------- App / actions ----------
	# Account details (email/plan) live in the panel's Account dialog now, NOT here.
	_section(v, "App")
	_kv(v, "Version", CghConfig.ADDON_VERSION)
	_action_btn(v, "Check for Updates", func(): check_updates_requested.emit())
	_upgrade_btn = _brand_btn(v, "⚡ Upgrade Plan", func(): OS.shell_open(CghConfig.pricing_url()))
	_gap(v)

	# ---------- Downloads (user can choose the folder) ----------
	_section(v, "Downloads")
	var pathbox := PanelContainer.new()
	pathbox.add_theme_stylebox_override("panel", CghTheme.footer_pill_box())
	_path_lbl = Label.new()
	_path_lbl.text = CghConfig.primary_download_dir()
	_path_lbl.add_theme_color_override("font_color", CghConfig.C_TEXT2)
	_path_lbl.add_theme_font_size_override("font_size", 10)
	_path_lbl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	var pm := MarginContainer.new()
	for s in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pm.add_theme_constant_override(s, 6)
	pm.add_child(_path_lbl)
	pathbox.add_child(pm)
	v.add_child(pathbox)

	# Change / Reset / Open — one tight row
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 4)
	_small_btn(brow, "Change folder…", _pick_folder)
	_small_btn(brow, "Reset", func():
		CghConfig.set_custom_download_dir("")
		_refresh_path()
		download_dir_changed.emit())
	_small_btn(brow, "Open", func():
		var d := CghConfig.primary_download_dir()
		DirAccess.make_dir_recursive_absolute(d)
		OS.shell_open(d))
	v.add_child(brow)

	var note := Label.new()
	note.text = "Shared with all CGHEVEN addons (so downloads show everywhere)."
	note.add_theme_color_override("font_color", CghConfig.C_TEXT3)
	note.add_theme_font_size_override("font_size", 9)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(note)
	_gap(v)

	# ---------- Community ----------
	_section(v, "Community")
	_brand_btn(v, "Join Discord", func(): OS.shell_open(CghConfig.DISCORD))

	# folder picker (native OS dialog)
	_dir_dialog = FileDialog.new()
	_dir_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dir_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dir_dialog.use_native_dialog = true
	_dir_dialog.title = "Choose download folder"
	_dir_dialog.dir_selected.connect(_on_dir_picked)
	add_child(_dir_dialog)

func refresh() -> void:
	_refresh_path()
	# Premium users (Pro/Studio/Bundle) have nothing to upgrade to — hide the button.
	if _upgrade_btn:
		_upgrade_btn.visible = not (auth != null and auth.is_premium())

## Open centered at the CORRECT size on the first click too. AcceptDialog computes its
## content min-size only after it is shown, so the naive reset_size()+popup_centered()
## opened huge the first time. Show → wait one frame (layout runs) → wrap to content →
## re-center. Subsequent opens are already correct.
func open_centered() -> void:
	refresh()
	popup_centered()
	await get_tree().process_frame
	reset_size()
	move_to_center()

func _pick_folder() -> void:
	if _dir_dialog:
		_dir_dialog.current_dir = CghConfig.primary_download_dir()
		_dir_dialog.popup_centered(Vector2i(700, 480))

func _on_dir_picked(dir: String) -> void:
	CghConfig.set_custom_download_dir(dir)
	_refresh_path()
	download_dir_changed.emit()

func _refresh_path() -> void:
	if _path_lbl:
		_path_lbl.text = CghConfig.primary_download_dir()

# ---------------- builders ----------------
func _section(parent: Node, t: String) -> void:
	var l := Label.new()
	l.text = t.to_upper()
	l.add_theme_color_override("font_color", CghConfig.C_ACCENT)
	l.add_theme_font_size_override("font_size", 10)
	parent.add_child(l)
	var sep := HSeparator.new()
	parent.add_child(sep)

func _gap(parent: Node) -> void:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, 1)
	parent.add_child(c)

func _kv(parent: Node, k: String, val: String) -> Label:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	var kl := Label.new()
	kl.text = k
	kl.custom_minimum_size = Vector2(80, 0)
	kl.add_theme_color_override("font_color", CghConfig.C_TEXT2)
	kl.add_theme_font_size_override("font_size", 11)
	var vl := Label.new()
	vl.text = val
	vl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	vl.clip_text = true
	vl.add_theme_color_override("font_color", CghConfig.C_TEXT1)
	vl.add_theme_font_size_override("font_size", 11)
	h.add_child(kl)
	h.add_child(vl)
	parent.add_child(h)
	return vl

func _action_btn(parent: Node, label: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(0, 24)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	parent.add_child(b)

func _small_btn(parent: Node, label: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(0, 22)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 10)
	b.pressed.connect(cb)
	parent.add_child(b)

func _brand_btn(parent: Node, label: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(0, 26)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_stylebox_override("normal", CghTheme.brand_button_box())
	b.add_theme_stylebox_override("hover", CghTheme.brand_button_box(true))
	b.add_theme_stylebox_override("pressed", CghTheme.brand_button_box(true))
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.pressed.connect(cb)
	parent.add_child(b)
	return b
