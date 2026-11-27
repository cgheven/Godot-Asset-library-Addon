@tool
extends PanelContainer
class_name CghMainDock
## The whole CGHEVEN panel: AE-styled top nav + tabs (Browse/Downloads/Favorites)
## + search + sort + category pills + responsive asset grid + login + settings.
## Guest browsing allowed (no hard gate), matching the current freemium model.

var api: CghApiClient
var auth: CghAuth
var downloader: CghDownloader
var analytics: CghAnalytics
var updater: CghUpdater

var _grid: GridContainer
var _page_bar: HBoxContainer
var _page_count := 1
var _scroll: ScrollContainer
var _search: LineEdit
var _sort: OptionButton
var _free: OptionButton
var _filter_mode := 0   # 0 = all, 1 = free only, 2 = downloaded only
var _manual_check := false
var _banner: PanelContainer
var _campaign: RefCounted = null   # banner + popup, see ui/campaign.gd
const _Campaign := preload("res://addons/cgheven/ui/campaign.gd")
var _status: Label
var _login_btn: Button
var _coll_open := false                # the Collections tab (last category pill) is showing
var _coll_pill: Button
var _coll_page: CghCollectionsPage
var _browse_nodes: Array = []          # hidden while the Collections page is open
var _pill_row: HBoxContainer
var _thumb_http: Array[HTTPRequest] = []
var _settings: CghSettingsModal
var _login_dlg: CghLoginDialog

# Top toast: a prominent colored bar for success/failure feedback (download + import),
# so the user always sees WHAT happened and WHY — not just the small status line.
var _toast: PanelContainer
var _toast_icon: Label
var _toast_msg: Label
var _toast_timer: Timer

var _subcat_dd: MenuButton
var _subcat_items: Array = []   # popup id -> subcategory slug ("" = All)
var _logo: TextureRect

var _page := 1
var _page_size := 16
var _category := ""
var _subcat := ""
var _subcats_by_parent := {}   # parent slug -> [{label, slug}] from the live category API
var _pills: Array = []          # the category tab buttons currently shown
var _pill_flow: HFlowContainer  # wraps the tabs onto extra lines instead of widening the dock
var _top_cats: Array = []       # [{label, slug}] shown as tabs (live from the API, hardcoded fallback)
var _search_text := ""
var _pending_search := ""       # last text typed; applied after a short debounce (live search)
var _search_debounce: Timer     # fires the search ~0.3s after the user stops typing
var _last_total := 0            # total matching assets from the last server response (for the count line)
var _sort_param := "createdAt:desc"
var _loading := false
var _auto_skip := 0   # pages skipped in a row because "Free only" left them empty (capped)
var _spinner_box: CenterContainer   # loading animation, visible while a fetch is in flight
const _Spinner := preload("res://addons/cgheven/ui/spinner.gd")
var _thumb_ctx := {}     # HTTPRequest -> {card, url} | null when that slot is free
var _thumb_queue := []   # pending [{card, url}] (loads 4 at a time)
var _thumb_fail := 0     # consecutive thumbnail download failures (offline detection)

# download queue (single downloader, serial)
var _dl_queue := []          # [{card, asset, entry}]
var _dl_active = null
var _downloaded := []        # session history [{asset, path, msg}]

func _init() -> void:
	add_theme_stylebox_override("panel", CghTheme._box(CghConfig.C_BG, 0))

func boot() -> void:
	# Init sanity check (GDScript can't catch exceptions): a missing core service means the panel
	# can't work at all — report it instead of failing silently on the first null access.
	if api == null or auth == null or downloader == null or analytics == null or updater == null:
		CghAnalytics.addon_open_failed("services_missing", "a core service was not created before boot")
		return
	CghConfig.ensure_dirs()
	CghDownloads.rescan()   # cross-addon file scanner -> shared ✓ ticks
	_build_ui()
	_build_modals()
	# Old "<zip>_unzip" extraction folders pile up (hundreds of MB): sweep them a few seconds after boot.
	get_tree().create_timer(8.0).timeout.connect(_sweep_temp_extractions)
	if _grid == null:
		CghAnalytics.addon_open_failed("build_ui", "asset grid was not created")
	# wire services
	api.assets_loaded.connect(_on_assets_loaded)
	api.categories_loaded.connect(_on_categories_loaded)
	api.request_failed.connect(func(m): _set_status(m, true); _set_loading(false))
	auth.logged_in.connect(_on_logged_in)
	auth.login_failed.connect(func(m): _set_status(m, true))
	auth.plan_refreshed.connect(_on_plan_refreshed)
	auth.session_refreshed.connect(_on_session_refreshed)
	auth.session_expired.connect(_on_session_expired)
	api.auth_rejected.connect(_on_auth_rejected)
	downloader.progress.connect(_on_dl_progress)
	downloader.finished.connect(_on_dl_finished)
	downloader.failed.connect(_on_dl_failed)
	updater.update_available.connect(_on_update_available)
	updater.up_to_date.connect(_on_up_to_date)
	updater.update_ready_to_restart.connect(_on_update_staged)
	# Update failures are silent: the backend may not know the `godot` slug yet,
	# and a red "HTTP 404" must never greet a normal user. Only surface on a
	# manual "Check for Updates" from Settings.
	updater.update_failed.connect(_on_update_failed)
	# thumbnail pool (8 concurrent, with a real queue so all cards load fast)
	for i in 8:
		var h := HTTPRequest.new()
		h.timeout = 20.0          # free a stuck slot instead of blocking all thumbnails forever
		add_child(h)
		h.request_completed.connect(_on_thumb.bind(h))
		_thumb_http.append(h)
		_thumb_ctx[h] = null
	_load_logo()
	# Seed the API client with the persisted session token BEFORE the first fetch.
	# A returning (already logged-in) user restores their token from EditorSettings in
	# auth._load_session(), but api._session_token stays "" until a fresh login. Without
	# this line the first fetch hits the PUBLIC (guest) endpoint, so the backend locks
	# every file (CGHLOCKED::) and the whole grid shows "Upgrade" — even for a paying
	# Studio user whose Account popup correctly reads "Studio" from auth.plan.
	api.set_session_token(auth.session_token)
	# Live plan refresh: heartbeat now + every 5 min re-resolves the user's plan on the
	# server, so a Free->Pro/Studio upgrade (or an expiry) reflects in the grid without a
	# restart or re-login. auth.heartbeat() no-ops when logged out and emits plan_refreshed
	# ONLY when the plan actually changed -> _on_plan_refreshed re-seeds the token,
	# re-fetches the grid, and updates the Account UI.
	auth.heartbeat()
	var hb := Timer.new()
	hb.wait_time = 300.0
	hb.one_shot = false
	hb.timeout.connect(auth.heartbeat)
	add_child(hb)
	hb.start()
	# Load the live category tree so the subcategory dropdown matches the backend
	# (new subcategories appear automatically), like the Blender addon.
	api.fetch_categories()
	_refresh_account_ui()
	analytics.identify(auth.email, auth.plan)
	if auth.startup_notice != "":   # the saved login was already expired at launch
		_set_status(auth.startup_notice, true)
		_show_toast(auth.startup_notice, "error")
		auth.startup_notice = ""
	# addon_installed fires once ever (first run on this machine), like the desktop addons.
	if not bool(CghConfig._read_prefs().get("installed_tracked", false)):
		analytics.track("addon_installed")
		var pr := CghConfig._read_prefs()
		pr["installed_tracked"] = true
		CghConfig._write_prefs(pr)
	analytics.track("session_started")
	analytics.track("addon_opened")
	updater.check()
	# Defer the first load: if it's a cache HIT it renders synchronously, and the
	# thumbnail HTTPRequest pool must be fully inside the tree first (else request()
	# fails to start and the thumbnail is silently dropped -> blank cards on boot).
	call_deferred("_load_first_page")

# ----------------------------------------------------------------- UI build
func _build_ui() -> void:
	# Tight top area so the asset grid gets the most vertical space possible.
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	add_child(root)
	root.add_child(_build_toast())           # prominent success/failure bar at the very top
	root.add_child(_build_topnav())
	root.add_child(_build_banner())
	var searchrow := _build_searchrow()
	root.add_child(searchrow)
	var pills := _build_pills()
	root.add_child(pills)                   # category pills + inline subcategory dropdown

	# Status line takes no space unless there's actually a message. It MUST wrap +
	# clip — a long one-liner (e.g. an import path) would otherwise grow the dock's
	# minimum width and push the asset grid off the right edge.
	_status = Label.new()
	_status.add_theme_color_override("font_color", CghConfig.C_TEXT2)
	_status.add_theme_font_size_override("font_size", 11)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 0)
	_status.size_flags_horizontal = Control.SIZE_FILL
	_status.clip_text = true
	_status.visible = false
	root.add_child(_status)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_scroll)
	_browse_nodes = [searchrow, _status, _scroll]   # hidden on the Collections tab (the category tabs stay)

	# Collections page (bought / claimed with Studio / locked): replaces the library while its nav button is on.
	_coll_page = CghCollectionsPage.new()
	_coll_page.auth = auth
	_coll_page.visible = false
	_coll_page.notify.connect(func(msg: String, ok: bool): _show_toast(msg, "success" if ok else "error"))
	root.add_child(_coll_page)

	# grid + page numbers live INSIDE the scroll; the page bar sits at the bottom
	# after the cards (1 2 3 … instead of an infinite "Load More").
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 8)
	_scroll.add_child(col)

	# Loading animation: shown while assets are being fetched, hidden as soon as they arrive.
	_spinner_box = CenterContainer.new()
	_spinner_box.custom_minimum_size = Vector2(0, 200)
	_spinner_box.visible = false
	_spinner_box.add_child(_Spinner.new())
	col.add_child(_spinner_box)

	_grid = GridContainer.new()
	_grid.columns = 2
	_grid.add_theme_constant_override("h_separation", CghConfig.GRID_GAP)
	_grid.add_theme_constant_override("v_separation", CghConfig.GRID_GAP)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_grid)

	_page_bar = HBoxContainer.new()
	_page_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	_page_bar.add_theme_constant_override("separation", 3)
	_page_bar.visible = false
	col.add_child(_page_bar)
	resized.connect(_reflow_columns)

func _build_topnav() -> HBoxContainer:
	var nav := HBoxContainer.new()
	nav.add_theme_constant_override("separation", 6)
	# Brand logo (loaded from the CDN, cached) — sits just before the CGHEVEN word
	# so the panel reads like a real product header.
	_logo = TextureRect.new()
	_logo.custom_minimum_size = Vector2(22, 22)
	_logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	nav.add_child(_logo)
	var brand := Label.new()
	brand.text = "CGHEVEN"
	brand.add_theme_color_override("font_color", CghConfig.C_TEXT1)
	brand.add_theme_font_size_override("font_size", 15)
	nav.add_child(brand)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav.add_child(spacer)
	# (Plan label removed from the top nav — the plan is shown in the Account popup.)
	_login_btn = Button.new()
	_login_btn.pressed.connect(_on_login_logout)
	nav.add_child(_login_btn)
	var sync := Button.new()
	sync.text = "⤓"
	sync.tooltip_text = "Sync downloaded assets (scan all CGHEVEN addons)"
	sync.pressed.connect(_sync_downloads)
	nav.add_child(sync)
	var gear := Button.new()
	gear.text = "⚙"
	gear.tooltip_text = "Settings"
	gear.pressed.connect(func(): _settings.open_centered())
	nav.add_child(gear)
	var refresh := Button.new()
	refresh.text = "↺"
	refresh.tooltip_text = "Refresh (re-fetch from server)"
	refresh.pressed.connect(_hard_refresh)
	nav.add_child(refresh)
	return nav

# Login / plan changed: the collections list must be loaded again (right away when the page is open).
func _collections_changed() -> void:
	if _coll_page != null:
		_coll_page.invalidate()
		if _coll_page.visible:
			_coll_page.enter()

# Switch between the asset library and the Collections page.
func _on_collections_pill() -> void:
	for c in _pills:
		c.button_pressed = (c == _coll_pill)
	_set_collections_open(true)

func _set_collections_open(on: bool) -> void:
	_coll_open = on
	for n in _browse_nodes:
		if is_instance_valid(n):
			n.visible = (not on) if n != _status else (not on and _status.text != "")
	if _subcat_dd != null:
		_subcat_dd.visible = not on and not _subcat_items.is_empty()
	if _coll_page != null:
		_coll_page.visible = on
		if on:
			_coll_page.enter()
	if on:
		analytics.track("category_clicked", {"category": "collections"})

# Prominent top toast (auto-hides). Green ✓ = success, red ✗ = failure, accent ℹ = info.
# Lives at the top of the panel so download/import outcomes are impossible to miss.
func _build_toast() -> PanelContainer:
	_toast = PanelContainer.new()
	_toast.visible = false
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_toast.add_child(row)
	_toast_icon = Label.new()
	_toast_icon.add_theme_font_size_override("font_size", 14)
	_toast_icon.add_theme_color_override("font_color", Color.WHITE)
	_toast_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_toast_icon)
	_toast_msg = Label.new()
	_toast_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_msg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toast_msg.add_theme_font_size_override("font_size", 11)
	_toast_msg.add_theme_color_override("font_color", Color.WHITE)
	row.add_child(_toast_msg)
	var x := Button.new()
	x.flat = true
	x.text = "✕"
	x.add_theme_color_override("font_color", Color.WHITE)
	x.add_theme_color_override("font_hover_color", Color.WHITE)
	x.pressed.connect(_hide_toast)
	x.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(x)
	_toast_timer = Timer.new()
	_toast_timer.one_shot = true
	_toast_timer.timeout.connect(_hide_toast)
	_toast.add_child(_toast_timer)
	return _toast

func _show_toast(msg: String, kind := "info") -> void:
	if _toast == null or msg == "":
		return
	var col := CghConfig.C_ACCENT
	var icon := "ℹ"
	if kind == "success":
		col = Color(0.16, 0.62, 0.34); icon = "✓"
	elif kind == "error":
		col = CghConfig.C_ERR; icon = "✗"
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(8.0)
	_toast.add_theme_stylebox_override("panel", sb)
	_toast_icon.text = icon
	_toast_msg.text = msg
	_toast.visible = true
	if _toast_timer:
		_toast_timer.stop()
		_toast_timer.wait_time = 7.0 if kind == "error" else 3.5
		_toast_timer.start()

func _hide_toast() -> void:
	if _toast:
		_toast.visible = false
	if _toast_timer:
		_toast_timer.stop()

# Set the small status line AND flash the top toast for a terminal outcome, and log a
# warning when it failed — so every download/import result is visible + traceable.
func _report(msg: String, ok: bool) -> void:
	_set_status(msg, not ok)
	_show_toast(msg, "success" if ok else "error")
	if not ok:
		push_warning("CGHEVEN: " + msg)

# Admin-controlled announcement banner (server meta.banner) — like AE/Blender.
func _build_banner() -> PanelContainer:
	_banner = PanelContainer.new()
	_banner.add_theme_stylebox_override("panel", CghTheme.banner_box())
	_banner.visible = false
	return _banner

# Banner (one line) and popup are decided in the admin; drawing and rules are in ui/campaign.gd.
func _render_banner(meta: Dictionary) -> void:
	if _banner == null:
		return
	if _campaign == null:
		_campaign = _Campaign.new()
		_campaign.setup(self,
			func(event: String, props: Dictionary): analytics.track(event, props),
			func() -> bool: return _dl_active != null or not _dl_queue.is_empty())
	_campaign.render_banner(_banner, meta)
	_campaign.schedule_popup(meta)

func _build_searchrow() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_search = LineEdit.new()
	_search.placeholder_text = "Search assets…"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.clear_button_enabled = true    # built-in ✕ to clear the query instantly
	# Live search: fire ~0.3s after the user stops typing — super fast, no Enter needed.
	_search_debounce = Timer.new()
	_search_debounce.one_shot = true
	_search_debounce.wait_time = 0.3
	_search_debounce.timeout.connect(_apply_search)
	add_child(_search_debounce)
	_search.text_changed.connect(func(t):
		_pending_search = t
		_search_debounce.start())          # restart the countdown on every keystroke
	# Enter applies immediately (skips the debounce wait).
	_search.text_submitted.connect(func(t):
		_pending_search = t
		_search_debounce.stop()
		_apply_search())
	row.add_child(_search)
	_sort = OptionButton.new()
	for s in CghConfig.SORTS:
		_sort.add_item(s["label"])
	_sort.item_selected.connect(func(i):
		_sort_param = CghConfig.SORTS[i]["param"]
		_load_first_page())
	row.add_child(_sort)
	# Unified filter: All / Free / Downloaded / Favorites (replaces the old tab bar)
	_free = OptionButton.new()
	_free.add_item("All assets")        # 0
	_free.add_item("✦ Free only")       # 1
	_free.add_item("⬇ Downloaded")      # 2
	_free.add_item("♥ Favorites")       # 3
	_free.item_selected.connect(func(i):
		_filter_mode = i
		# Matches the AE/Premiere "free_filter_toggled" event (on = Free-only mode).
		analytics.track("free_filter_toggled", {"on": i == 1, "category": _category, "sub_category": _subcat})
		if i == 3:
			_render_favorites()
		else:
			_load_first_page())
	row.add_child(_free)
	_update_fav_badge()
	return row

func _build_pills() -> HBoxContainer:
	_pill_row = HBoxContainer.new()
	_pill_row.add_theme_constant_override("separation", 4)
	# Category tabs wrap onto extra lines (HFlowContainer): the library has 7+ top-level categories and
	# one long row would stretch the whole dock wide.
	_pill_flow = HFlowContainer.new()
	_pill_flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pill_flow.add_theme_constant_override("h_separation", 4)
	_pill_flow.add_theme_constant_override("v_separation", 4)
	_pill_row.add_child(_pill_flow)
	_top_cats = CghConfig.CATEGORIES.duplicate()   # fallback until the live list arrives
	_fill_pills()
	# Compact subcategory filter: a small icon button (fixed width) that opens a popup,
	# instead of a wide dropdown whose longest label (e.g. "Muzzle Flashes") stretched
	# the whole dock. Hidden for categories with no subcategories.
	_subcat_dd = MenuButton.new()
	_subcat_dd.text = "▾"
	_subcat_dd.tooltip_text = "Filter by subcategory"
	_subcat_dd.custom_minimum_size = Vector2(30, 0)
	_subcat_dd.flat = false
	_subcat_dd.add_theme_font_size_override("font_size", 13)
	_subcat_dd.get_popup().add_theme_stylebox_override("panel", CghTheme.dropdown_box())
	_subcat_dd.get_popup().id_pressed.connect(_on_subcat_selected)
	_pill_row.add_child(_subcat_dd)
	_populate_subcats("")
	return _pill_row

# (Re)build the category tab buttons from _top_cats, keeping the current selection pressed.
func _fill_pills() -> void:
	for old in _pills:
		if is_instance_valid(old):
			_pill_flow.remove_child(old)
			old.queue_free()
	_pills.clear()
	for cat in _top_cats:
		var p := Button.new()
		p.text = cat["label"]
		p.toggle_mode = true
		p.button_pressed = (cat["slug"] == _category)
		p.add_theme_font_size_override("font_size", 13)
		p.pressed.connect(_on_pill.bind(cat["slug"], p))
		_pill_flow.add_child(p)
		_pills.append(p)
	# Collections is the last tab: bought / claimed / locked collections instead of single assets.
	_coll_pill = Button.new()
	_coll_pill.text = "Collections"
	_coll_pill.toggle_mode = true
	_coll_pill.button_pressed = _coll_open
	_coll_pill.add_theme_font_size_override("font_size", 13)
	_coll_pill.tooltip_text = "Collections you bought, claimed with Studio, or can buy"
	_coll_pill.pressed.connect(_on_collections_pill)
	_pill_flow.add_child(_coll_pill)
	_pills.append(_coll_pill)

func _on_pill(slug: String, btn: Button) -> void:
	for c in _pills:
		c.button_pressed = (c == btn)
	if _coll_open:
		_set_collections_open(false)
	_category = slug
	_subcat = ""
	_populate_subcats(slug)
	analytics.track("category_clicked", {"category": slug})
	# leaving Favorites view? switch the filter back to a browse mode
	if _filter_mode == 3:
		_filter_mode = 0
		if _free:
			_free.select(0)
	_load_first_page()

func _populate_subcats(slug: String) -> void:
	if not _subcat_dd:
		return
	var subs = _subcats_by_parent.get(slug, CghConfig.SUBCATEGORIES.get(slug, []))
	_subcat_dd.visible = subs.size() > 0   # only show when this category has subcategories
	var pm := _subcat_dd.get_popup()
	pm.clear()
	_subcat_items = [""]                    # popup id 0 = "All" (no subcategory filter)
	pm.add_radio_check_item("All", 0)
	var idx := 1
	for s in subs:
		pm.add_radio_check_item(s["label"], idx)
		_subcat_items.append(s["slug"])
		idx += 1
	# tick the active subcategory so the current filter shows when the popup opens
	for i in pm.item_count:
		pm.set_item_checked(i, i < _subcat_items.size() and _subcat_items[i] == _subcat)

# Build the category TABS and the subcategory dropdowns from the LIVE category list, so every
# top-level category the library has shows up (Explosions and Smoke live under VFX and VDBs; the
# old hardcoded list of 3 tabs hid them) and new categories appear automatically. A category's parent
# comes from the API's own parent_category relation, not from a hardcoded slug list. Non-fatal: until
# this arrives (or if it fails) the hardcoded fallback tabs stay.
const _PREFERRED_TABS := ["3d-models", "hdri", "flipbooks", "vfx", "vdbs", "texture", "shaders"]

func _on_categories_loaded(cats: Array) -> void:
	var tops: Array = []
	var kids := {}
	var seen := {}
	for item in cats:
		if not (item is Dictionary):
			continue
		var a = item.get("attributes", item)
		if not (a is Dictionary):
			a = item
		var slug := str(a.get("Slug", a.get("slug", ""))).strip_edges()
		var label := str(a.get("Name", a.get("name", a.get("Title", slug)))).strip_edges()
		var parent := _parent_slug_of(a)
		if parent == "":
			if not CghConfig.GODOT_TABS.has(slug.to_lower()):
				continue                    # Godot can't use this category (video / VDB / Blender-only): never show it
			if slug == "" or seen.has(slug.to_lower()):
				continue                    # a top-level tab needs a slug to filter on
			seen[slug.to_lower()] = true
			tops.append({"label": _tidy_label(label if label != "" else slug), "slug": slug, "ord": tops.size()})
		else:
			if not CghConfig.GODOT_TABS.has(parent.to_lower()):
				continue                    # a child of a category Godot can't use
			if slug == "" and label == "":
				continue
			# A child whose Slug is blank in the CMS can't be matched by slug: use its Name instead.
			var key := slug if slug != "" else "name:" + label
			if not kids.has(parent):
				kids[parent] = []
			kids[parent].append({"label": label if label != "" else slug, "slug": key})
	if tops.is_empty():
		return                         # nothing usable came back: keep the fallback tabs
	tops.sort_custom(_tab_less)
	for k in kids.keys():
		kids[k].sort_custom(func(x, y): return str(x["label"]).naturalnocasecmp_to(str(y["label"])) < 0)
	_subcats_by_parent = kids
	var all_tabs: Array = [{"label": "All", "slug": ""}]
	all_tabs.append_array(tops)
	_top_cats = all_tabs
	var selection_gone := false
	if _category != "":
		selection_gone = true
		for t in tops:
			if str(t["slug"]) == _category:
				selection_gone = false
	if selection_gone:
		_category = ""
		_subcat = ""
	_fill_pills()
	if _subcat_dd:
		_populate_subcats(_category)
	if selection_gone:
		_load_first_page()

# The API returns each category's parent as a relation; "" = it is a top-level category.
func _parent_slug_of(a: Dictionary) -> String:
	var pc = a.get("parent_category", null)
	if pc is Dictionary:
		var d = pc.get("data", pc)      # Strapi 5 returns the object itself; Strapi 4 nests it under data
		if d is Dictionary:
			var da = d.get("attributes", d)
			if da is Dictionary:
				return str(da.get("Slug", da.get("slug", ""))).strip_edges()
	return ""

# Tab order: the known categories first (in a fixed order), anything new after them in API order.
func _tab_rank(slug: String) -> int:
	var i := _PREFERRED_TABS.find(slug.to_lower())
	return i if i >= 0 else 100

func _tab_less(x: Dictionary, y: Dictionary) -> bool:
	var rx := _tab_rank(str(x["slug"]))
	var ry := _tab_rank(str(y["slug"]))
	if rx != ry:
		return rx < ry
	return int(x["ord"]) < int(y["ord"])

# "texture" -> "Texture"; leave already-styled names ("3D Models", "HDRI") alone.
func _tidy_label(s: String) -> String:
	if s == s.to_lower() and s.length() > 0:
		return s.substr(0, 1).to_upper() + s.substr(1)
	return s

func _on_subcat_selected(id: int) -> void:
	_subcat = str(_subcat_items[id]) if id >= 0 and id < _subcat_items.size() else ""
	var pm := _subcat_dd.get_popup()
	for i in pm.item_count:
		pm.set_item_checked(i, i == id)
	analytics.track("category_clicked", {"category": _category, "sub_category": _subcat})
	_load_first_page()

func _build_modals() -> void:
	_settings = CghSettingsModal.new()
	_settings.auth = auth
	_settings.analytics = analytics
	add_child(_settings)
	_settings.build()
	_settings.logout_requested.connect(_do_logout)
	_settings.check_updates_requested.connect(func(): _manual_check = true; updater.check())
	_settings.download_dir_changed.connect(func():
		CghDownloads.rescan()
		_set_status("Download folder updated.", false))

	_login_dlg = CghLoginDialog.new()
	_login_dlg.auth = auth
	_login_dlg.analytics = analytics
	add_child(_login_dlg)
	_login_dlg.build()
	# Account details (email/plan) now live in this dialog's profile view, with the
	# Logout button — Settings no longer carries account info.
	_login_dlg.logout_requested.connect(_do_logout)

# ----------------------------------------------------------------- data
# Apply the pending (typed) query — only refetches if it actually changed, so caret
# moves / no-op keystrokes never spam the server.
func _apply_search() -> void:
	var q := _pending_search.strip_edges()
	if q == _search_text:
		return
	_search_text = q
	if q != "":
		CghAnalytics.note_action("search")
		analytics.track("search_performed", {"query": q})
	_load_first_page()

func _load_first_page(force := false) -> void:
	_auto_skip = 0
	_page = 1
	_page_count = 1        # reset so a stale multi-page bar never lingers over the new results
	_thumb_fail = 0
	_clear_grid()
	_fetch(force)

# Manual ↺ — force a fresh server fetch (ignores cache, but keeps it if the network
# fails so the old page still works offline).
func _hard_refresh() -> void:
	_load_first_page(true)

# ⤓ Sync — re-scan the shared cross-addon download manifest/folders, then rebuild
# the grid so the ✓/downloaded state reflects every CGHEVEN addon.
func _sync_downloads() -> void:
	CghDownloads.rescan()
	_load_first_page()
	var recs := CghDownloads.synced_records()
	_set_status("Synced %d downloaded asset%s across CGHEVEN addons." % [
		recs.size(), "" if recs.size() == 1 else "s"], false)
	_show_sync_dialog(recs)

# Popup listing every asset that's downloaded in ANY CGHEVEN addon (cross-addon sync).
func _show_sync_dialog(recs: Array) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "CGHEVEN — Synced Downloads"
	dlg.min_size = Vector2i(380, 0)
	dlg.wrap_controls = false   # fixed ~30% window; the list scrolls inside
	var margin := MarginContainer.new()
	for s in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(s, 10)
	dlg.add_child(margin)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	v.custom_minimum_size = Vector2(360, 0)
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(v)
	if recs.is_empty():
		var none := Label.new()
		none.text = "No downloaded assets found yet.\nDownload something here or in any other CGHEVEN addon."
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		none.add_theme_color_override("font_color", CghConfig.C_TEXT2)
		none.add_theme_font_size_override("font_size", 11)
		v.add_child(none)
	else:
		var head := Label.new()
		head.text = "%d asset%s downloaded (shared across all CGHEVEN addons):" % [
			recs.size(), "" if recs.size() == 1 else "s"]
		head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		head.add_theme_color_override("font_color", CghConfig.C_ACCENT)
		head.add_theme_font_size_override("font_size", 11)
		v.add_child(head)
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(0, min(280, 8 + recs.size() * 20))
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		v.add_child(scroll)
		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", 2)
		scroll.add_child(list)
		for r in recs:
			var row := Label.new()
			var res_arr: Array = r.get("res", [])
			var res_txt: String = ("  [" + ", ".join(res_arr) + "]") if not res_arr.is_empty() else ""
			row.text = "•  %s%s" % [str(r.get("title", "Untitled")), res_txt]
			row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			row.clip_text = true
			row.add_theme_color_override("font_color", CghConfig.C_TEXT1)
			row.add_theme_font_size_override("font_size", 11)
			list.add_child(row)
	add_child(dlg)
	dlg.confirmed.connect(func(): dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	# Professional size: ~30% of the editor window, centered — the list scrolls inside
	# instead of the dialog stretching to full height.
	var win := DisplayServer.window_get_size()
	dlg.popup_centered(Vector2i(maxi(380, int(win.x * 0.3)), maxi(320, int(win.y * 0.42))))

func _goto_page(p: int) -> void:
	if p == _page or _loading or _filter_mode == 3:
		return
	_auto_skip = 0
	_page = p
	_clear_grid()
	if _scroll:
		_scroll.scroll_vertical = 0
	_fetch()

# The tab itself PLUS its subcategories: many assets are filed straight under a subcategory
# (e.g. "explosions-vfx"), so matching only the parent slug would miss them. [] = the All tab.
func _tab_slugs() -> Array:
	if _category == "":
		# All = every tab Godot supports + their subcategories (never the video / VDB / Blender-only ones).
		var all_slugs: Array = []
		for t in _top_cats:
			var ts := str(t["slug"])
			if ts == "":
				continue
			all_slugs.append(ts)
			for sc in _subcats_by_parent.get(ts, CghConfig.SUBCATEGORIES.get(ts, [])):
				all_slugs.append(str(sc["slug"]))
		return all_slugs
	var out: Array = [_category]
	for sc in _subcats_by_parent.get(_category, CghConfig.SUBCATEGORIES.get(_category, [])):
		out.append(str(sc["slug"]))
	return out

# Cache key per (plan is handled by the cache) category/subcat/page/sort/search.
func _cache_key() -> String:
	return "%s|%s|%d|%s|%s" % [_category, _subcat, _page, _sort_param, _search_text]

# Cache-FIRST: a page seen once renders instantly from disk and never re-fetches
# (unless `force`, e.g. the manual Refresh, which always pulls from the server).
func _fetch(force := false) -> void:
	if not force:
		var page := CghCache.load_page(auth.plan, _cache_key())
		var cached_assets = page.get("assets", [])
		if cached_assets is Array and not cached_assets.is_empty():
			_set_loading(false)
			_render_assets(cached_assets, page.get("meta", {}))
			return
	_set_loading(true)
	_set_status(("Searching “%s”…" % _search_text.strip_edges()) if _search_text.strip_edges() != "" else "Loading…", false)
	# Pass category + subcategory separately: a subcategory filters the `subcategories`
	# relation, a category filters `categorie` (different Strapi filters).
	api.fetch_assets(_page, _page_size, _category, _search_text, _sort_param, _subcat, _tab_slugs())

# _loading + the spinner always change together.
func _set_loading(on: bool) -> void:
	_loading = on
	if _spinner_box != null:
		_spinner_box.visible = on

func _on_assets_loaded(assets: Array, meta: Dictionary) -> void:
	_set_loading(false)
	if _filter_mode == 3:   # Favorites view doesn't use fetched results
		return
	CghCache.save_assets(auth.plan, _cache_key(), assets, meta)
	_render_assets(assets, meta)

func _render_assets(assets: Array, meta: Dictionary) -> void:
	if _filter_mode == 3:
		return
	for a in assets:
		if CghAsset.importable_entries(a).is_empty():
			continue   # nothing Godot can import in this asset (rar / video / blend only): don't offer it
		if _filter_mode == 1 and not CghAsset.has_free_importable(a):
			continue
		if _filter_mode == 2 and not CghDownloads.is_downloaded(a):
			continue
		_add_card(a)
	var pg = meta.get("pagination", {})
	_page_count = int(pg.get("pageCount", 1)) if pg is Dictionary else 1
	_last_total = int(pg.get("total", _grid.get_child_count())) if pg is Dictionary else _grid.get_child_count()
	var q := _search_text.strip_edges()
	var shown := _grid.get_child_count()
	if shown == 0 and _filter_mode == 1 and _page < _page_count and _auto_skip < 10:
		# "Free only" filters the page the server sent. When that whole page is locked, don't leave the user
		# on an empty screen: quietly move on to the next page until something free shows up.
		_auto_skip += 1
		_page += 1
		_clear_grid()
		_fetch()
		return
	if shown == 0:
		var empty := "No results found."
		if q != "":
			empty = "No results for “%s”." % q
		elif _filter_mode == 1: empty = "No free assets on this page."
		elif _filter_mode == 2: empty = "No downloaded assets on this page."
		_set_status(empty, false)
	else:
		# Count line so the user always knows what happened (e.g. "12 results for “fire”").
		var cnt := _last_total if _filter_mode == 0 else shown
		var suffix := "" if cnt == 1 else "s"
		if q != "":
			_set_status("%d result%s for “%s”" % [cnt, suffix, q], false)
		elif _page_count > 1:
			_set_status("%d asset%s • page %d of %d" % [cnt, suffix, _page, _page_count], false)
		else:
			_set_status("%d asset%s" % [cnt, suffix], false)
	_render_banner(meta)
	_render_page_bar()

# Numbered pagination: 1 2 3 … last (windowed around the current page).
func _render_page_bar() -> void:
	if _page_bar == null:
		return
	for c in _page_bar.get_children():
		_page_bar.remove_child(c)
		c.queue_free()
	# Only show pages when there are actually cards below them — never float a "1 2 3 …"
	# bar over an empty/short result (this is what made pages seem to sit "at the top").
	if _filter_mode == 3 or _page_count <= 1 or (_grid.get_child_count() == 0 and _filter_mode != 1):
		_page_bar.visible = false
		return
	_page_bar.visible = true
	for p in _page_list(_page, _page_count):
		if p == -1:
			var dots := Label.new()
			dots.text = "…"
			dots.add_theme_color_override("font_color", CghConfig.C_TEXT3)
			_page_bar.add_child(dots)
		else:
			var b := Button.new()
			b.text = str(p)
			b.toggle_mode = true
			b.button_pressed = (p == _page)
			b.custom_minimum_size = Vector2(30, 26)
			b.pressed.connect(_goto_page.bind(p))
			_page_bar.add_child(b)

func _page_list(cur: int, total: int) -> Array:
	var out := []
	if total <= 7:
		for i in range(1, total + 1):
			out.append(i)
		return out
	out.append(1)
	var lo: int = max(2, cur - 1)
	var hi: int = min(total - 1, cur + 1)
	if lo > 2:
		out.append(-1)
	for i in range(lo, hi + 1):
		out.append(i)
	if hi < total - 1:
		out.append(-1)
	out.append(total)
	return out

func _add_card(asset: Dictionary) -> CghAssetCard:
	var card := CghAssetCard.new()
	card.auth = auth                       # favourites need login
	_grid.add_child(card)
	card.setup(asset)
	card.login_required.connect(_on_fav_login_required)
	card.request_download.connect(_on_card_download)
	card.request_upgrade.connect(_on_card_upgrade)
	card.favorite_toggled.connect(_on_favorite_toggled)
	card.preview_requested.connect(_on_preview_requested)
	card.flipbook_sheet_requested.connect(_on_flipbook_sheet_requested)
	card.cancel_requested.connect(_on_card_cancel)
	card.delete_requested.connect(_on_card_delete)
	card.viewed.connect(func(a): analytics.track("asset_viewed", _asset_props(a)))
	var url := card.get_thumb_url()
	if url != "":
		_load_thumb(url, card)
	return card

# Brand logo: cache-first, then a one-off HTTPRequest. Failure is silent (the
# CGHEVEN word still shows), so a CDN hiccup never leaves a broken-image box.
func _load_logo() -> void:
	if _logo == null:
		return
	var url := "https://api.cgheven.com/uploads/logo_a88f3d6d46.png"
	var cached := CghCache.load_thumb(url)
	if cached:
		_logo.texture = cached
		return
	var h := HTTPRequest.new()
	h.timeout = 20.0
	add_child(h)
	h.request_completed.connect(func(r, code, _hh, body):
		if r == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300:
			var img := _decode_image(body, url)
			if img != null and is_instance_valid(_logo):
				_logo.texture = ImageTexture.create_from_image(img)
				CghCache.save_thumb(url, img)
		h.queue_free())
	h.request(url)

# ----------------------------------------------------------------- thumbnails
func _load_thumb(url: String, card: CghAssetCard) -> void:
	var cached := CghCache.load_thumb(url)
	if cached:
		card.set_thumbnail(cached)
		return
	_thumb_queue.append({"card": card, "url": url})
	_pump_thumbs()

func _pump_thumbs() -> void:
	for h in _thumb_http:
		if _thumb_queue.is_empty():
			return
		if _thumb_ctx.get(h) != null:
			continue                      # this slot is busy
		var job = _thumb_queue.pop_front()
		if not is_instance_valid(job["card"]):
			continue                      # card was freed before we got to it
		_thumb_ctx[h] = job
		var err := h.request(job["url"])
		if err != OK:
			# Couldn't start (node not ready yet / busy) — DON'T drop it: re-queue and
			# retry on a later frame, so thumbnails still load once the tree settles.
			_thumb_ctx[h] = null
			job["retries"] = int(job.get("retries", 0)) + 1
			if job["retries"] <= 8:
				_thumb_queue.push_back(job)
				call_deferred("_pump_thumbs")
			else:
				push_warning("CGHEVEN: thumb request couldn't start (err %d) %s" % [err, str(job["url"])])
			return

func _on_thumb(result: int, code: int, _h: PackedStringArray, body: PackedByteArray, req: HTTPRequest) -> void:
	var ctx = _thumb_ctx.get(req, null)
	_thumb_ctx[req] = null                 # free this slot regardless of outcome
	if ctx != null:
		var img: Image = null
		if result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300:
			img = _decode_image(body, ctx["url"])
			if img != null and maxi(img.get_width(), img.get_height()) > 512:
				# cards are ~160px wide: a 1024px texture only costs GPU memory and PNG-save time
				var k := 512.0 / float(maxi(img.get_width(), img.get_height()))
				img.resize(maxi(1, int(img.get_width() * k)), maxi(1, int(img.get_height() * k)), Image.INTERPOLATE_BILINEAR)
		if img != null:
			_thumb_fail = 0
			if is_instance_valid(ctx["card"]):
				ctx["card"].set_thumbnail(ImageTexture.create_from_image(img))
			CghCache.save_thumb(ctx["url"], img)
		else:
			# The light variant failed: retry ONCE with the normal thumbnail before reporting anything.
			var fcard = ctx.get("card", null)
			if is_instance_valid(fcard) and not bool(ctx.get("fallback", false)):
				var full: String = CghAsset.thumbnail(fcard.asset)
				if full != "" and full != str(ctx.get("url", "")):
					_thumb_queue.push_back({"card": fcard, "url": full, "fallback": true})
					_pump_thumbs()
					return
			# Network/decoder failure — surface the exact result/http in the panel
			# (result=4 connection/offline, http=403/404 CDN, http=200 = decode issue).
			_thumb_fail += 1
			# One collapsed endpoint ("cdn:thumbnail") so a bad CDN day dedupes to ONE event, not one per image.
			var thumb_ok_http := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
			CghAnalytics.api_error("cdn:thumbnail", 0 if thumb_ok_http else code, "thumbnail decode failed" if thumb_ok_http else "thumbnail request failed (result %d)" % result, 0 if thumb_ok_http else result)
			# (no on-screen message: a missing thumbnail must not overwrite the asset count line; it is logged + tracked)
			push_warning("CGHEVEN: thumbnail failed (result=%d http=%d) %s" % [result, code, str(ctx.get("url", ""))])
	_pump_thumbs()                         # start the next queued thumbnail

# Decode a thumbnail from raw bytes. CGHEVEN thumbnails are usually .webp, but the URL
# extension often lies (a .webp link can serve png/jpg) — so SNIFF the real format from
# the magic bytes and call exactly ONE decoder. This makes mislabeled thumbnails load
# AND stops the console spam that came from blind-trying every wrong decoder. Returns
# null on failure (non-image body / corrupt file). PNG=89 50 4E 47, JPEG=FF D8,
# WEBP=RIFF....WEBP.
func _decode_image(body: PackedByteArray, _url: String) -> Image:
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
	else:
		return null   # not a recognisable image body (e.g. an HTML error page) — no decoder, no spam
	return img if ok == OK else null

# ----------------------------------------------------------------- download + import
func _on_card_download(asset: Dictionary, entry: Dictionary) -> void:
	CghAnalytics.note_action("download")
	var e := entry if not entry.is_empty() else CghAsset.best_free_entry(asset)
	if e.is_empty():
		e = CghAsset.best_free_any(asset)   # nothing auto-importable, but still fetch the free file
	if e.is_empty():
		# Paid users unlock every file, so an empty entry here means the asset genuinely
		# ships no free file for this plan — say so plainly instead of the click doing nothing.
		var why := "No downloadable file for your plan on this asset." if not auth.is_logged_in() \
			else "This asset has no file you can download right now."
		_report(why, false)
		return
	# Already downloaded by any CGHEVEN addon -> import the local file, skip re-download.
	var local := CghDownloads.local_path(e["filename"])
	if local != "":
		_route_import(local, asset)        # fires asset_imported / import_failed itself
		return
	# find the card that owns this asset (the one currently visible)
	var card := _find_card(asset)
	_dl_queue.append({"card": card, "asset": asset, "entry": e})
	analytics.track("asset_downloaded", _asset_props(asset, {
		"format": e.get("format", ""), "resolution": e.get("res", "")}))
	_pump_queue()

func _pump_queue() -> void:
	if _dl_active != null or _dl_queue.is_empty():
		return
	_dl_active = _dl_queue.pop_front()
	var e: Dictionary = _dl_active["entry"]
	# Match the AE/Blender addons: the file URL is a PUBLIC cdn.cgheven.com GET — send ONLY
	# User-Agent + Referer, NEVER Authorization. A stray "Bearer" to the CDN/B2 origin makes it
	# reject the request with 401 ("access denied") — exactly the failure seen on patreon assets
	# even for a Pro user. The bearer belongs only on api.cgheven.com calls (the listing already
	# sends it), so attach it only if the file URL is actually on our API host.
	var url: String = str(e.get("url", ""))
	if not CghConfig.is_trusted_url(url):
		# a file link that is not https on a CGHEVEN host (CMS typo or tampered data): never fetch it
		downloader.last_stage = "blocked_url"
		downloader.last_status = 0
		downloader.last_result = 0
		_on_dl_failed("Blocked a download link that is not on a CGHEVEN server (this asset's link looks broken).")
		return
	var headers := PackedStringArray([
		"User-Agent: CGHEVEN-Godot/%s" % CghConfig.ADDON_VERSION,
		"Referer: https://cgheven.com/",
	])
	if auth.is_logged_in() and url.begins_with(CghConfig.api_base() + "/"):
		headers.append("Authorization: Bearer " + auth.session_token)
	_set_status("Downloading %s…" % e["filename"], false)
	_show_toast("Downloading %s…" % e["filename"], "info")   # confirm the click actually started a download
	push_warning("CGHEVEN: download start %s <- %s" % [e["filename"], str(e.get("url", ""))])
	downloader.download(e["url"], e["filename"], headers)

func _on_dl_progress(pct: float, _got: int, _total: int) -> void:
	if _dl_active and is_instance_valid(_dl_active["card"]):
		_dl_active["card"].set_progress(pct)

func _on_dl_finished(path: String) -> void:
	if _dl_active == null:
		return   # defensive: a stray finished signal with no active job
	var asset: Dictionary = _dl_active["asset"]
	var entry: Dictionary = _dl_active.get("entry", {})
	var fmt := str(entry.get("format", ""))
	var res := str(entry.get("res", ""))
	# Record into the shared cross-addon manifest so AE/Premiere/DaVinci show the ✓ too.
	CghDownloads.record(asset, path, fmt, res)
	CghAnalytics.download_performance(_asset_props(asset), downloader.last_duration_ms, downloader.last_bytes, fmt, res)
	if _dl_active and is_instance_valid(_dl_active["card"]):
		_dl_active["card"].set_download_done(true)
		# Re-evaluate the footer so it flips "Download" -> "Import" (and the ▾ rows update)
		# live, right now — previously it only refreshed on a full grid rebuild / re-open.
		_dl_active["card"].refresh_state()
	_downloaded.append({"asset": asset, "path": path, "msg": ""})
	_route_import(path, asset)             # fires asset_imported / import_failed itself
	_dl_active = null
	_pump_queue()

func _on_dl_failed(message: String) -> void:
	var asset: Dictionary = _dl_active.get("asset", {}) if _dl_active else {}
	if _dl_active and is_instance_valid(_dl_active["card"]):
		_dl_active["card"].set_download_done(false)
	_report(message, false)
	CghAnalytics.download_failed(downloader.last_stage, message, downloader.last_status, downloader.last_result, _asset_props(asset), downloader.last_body)
	_dl_active = null
	_pump_queue()

# Route a finished/already-local file to the right importer. 3D models take the
# official res:// path (copy into project -> editor imports a proper PackedScene
# with materials -> instance + select), which renders reliably; HDRI/flipbook use
# the synchronous router (live-instanced into the open scene).
func _route_import(path: String, asset: Dictionary) -> void:
	CghAnalytics.note_action("import")
	var cat := CghAsset.category_slug(asset)
	var ext := path.get_extension().to_lower()
	# 3D models arrive as a direct model file OR (usually) a .zip. Route BOTH through the
	# editor-import path so Godot imports fbx/obj/dae too — the runtime path does only glTF.
	var is_3d: bool = cat == "3d-models" or ext in CghImportRouter.EDITOR_MODEL_PRIORITY
	if is_3d:
		if ext in CghImportRouter.EDITOR_MODEL_PRIORITY:
			_import_3d(path, asset, false)   # coroutine — sets status + fires its own analytics
			return
		if ext == "zip":
			var model := CghImportRouter.extract_model_from_zip(path)
			if model != "":
				_import_3d(model, asset, true)
				return
			# no editor-importable model inside — fall through to the runtime router
	var msg := CghImportRouter.import_file(path, cat)
	var ok := not msg.to_lower().contains("failed")
	# EXR flipbook sheets fail in Godot (its tinyexr can't read DWAA/DWAB/PXR24/B44 compression).
	# Auto-fall back to a PNG/JPG/WebP version of the SAME flipbook when the asset ships one, so
	# the user gets a playing flipbook instead of a dead error toast.
	if not ok and CghAsset.is_flipbook(asset) and ext == "exr":
		var alt := _flipbook_image_alternative(asset)
		if not alt.is_empty():
			_show_toast("EXR flipbook can't load in Godot — fetching the PNG version instead…", "info")
			push_warning("CGHEVEN: EXR flipbook import failed, auto-retrying with %s" % str(alt.get("filename", "")))
			_on_card_download(asset, alt)   # queues the PNG download, then imports it
			return
		msg = "This flipbook only ships as an EXR compression Godot can't read yet — please try another flipbook (we're re-encoding these)."
	# HDRI EXRs at high resolution are often DWAA/DWAB compressed (Godot's tinyexr can't read
	# those); the lowest resolution is usually uncompressed and loads fine. On failure, auto-fall
	# back to the lowest-res EXR of the SAME HDRI so the user still gets a working sky.
	if not ok and cat.contains("hdr") and ext in ["exr", "hdr"]:
		var halt := _hdri_loadable_alternative(asset, path)
		if not halt.is_empty():
			_show_toast("This HDRI resolution can't load in Godot — fetching a lower resolution instead…", "info")
			push_warning("CGHEVEN: HDRI import failed, auto-retrying with %s" % str(halt.get("filename", "")))
			_on_card_download(asset, halt)   # queues the lower-res EXR, then imports it
			return
		msg = "This HDRI only ships in a compression Godot can't read yet — please try another HDRI (we're re-encoding these)."
	_report(msg, ok)
	_track_import_result(asset, ext, ok, "router_" + cat, msg)

# Lowest-res unlocked PNG/JPG/WebP entry for a flipbook — the fallback when its EXR sheet
# won't load in Godot. Returns {} when the asset is EXR-only (no image variant to use).
func _flipbook_image_alternative(asset: Dictionary) -> Dictionary:
	var imgs := CghAsset.importable_entries(asset).filter(func(e):
		return not e.get("locked", false) and str(e.get("ext", "")) in ["png", "jpg", "jpeg", "webp"])
	if imgs.is_empty():
		return {}
	imgs.sort_custom(func(a, b): return int(a["res_rank"]) < int(b["res_rank"]))
	return imgs[0]

# Lowest-res unlocked EXR/HDR entry for an HDRI — the fallback when a higher-res EXR won't load
# (DWAA/DWAB). Returns {} when there's no lower alternative than the file that just failed.
func _hdri_loadable_alternative(asset: Dictionary, failed_path: String) -> Dictionary:
	var exrs := CghAsset.importable_entries(asset).filter(func(e):
		return not e.get("locked", false) and str(e.get("ext", "")) in ["exr", "hdr"])
	if exrs.is_empty():
		return {}
	exrs.sort_custom(func(a, b): return int(a["res_rank"]) < int(b["res_rank"]))
	var lowest: Dictionary = exrs[0]
	# Don't retry the exact file we just failed on (avoids a loop if even the lowest fails).
	if str(lowest.get("filename", "")) == failed_path.get_file():
		return {}
	return lowest

# asset_imported on success / import_failed on failure — matches the AE/Premiere
# events (the import path used to always report success, even when it failed).
func _track_import_result(asset: Dictionary, fmt: String, ok: bool, stage := "", reason := "") -> void:
	if ok:
		analytics.track("asset_imported", _asset_props(asset, {"format": fmt, "success": true}))
	else:
		CghAnalytics.import_failed(stage if stage != "" else "import", reason if reason != "" else "import reported failure",
			_asset_props(asset, {"format": fmt, "success": false}))

# Copy the model under res://, let the editor import it, then instance the
# PackedScene into the open scene and select it so the user can frame it (F).
func _import_3d(path: String, asset: Dictionary, from_extract := false) -> void:
	var category := CghAsset.category_slug(asset)
	var ext := path.get_extension().to_lower()
	# Copy into res:// (with sibling textures/.bin/.mtl when it came from a zip) and let
	# Godot's EDITOR import it — that path handles glTF/FBX/OBJ/DAE, unlike the runtime one.
	var res_path := ""
	if from_extract:
		res_path = CghImportRouter.copy_model_into_project(path, category)
	else:
		res_path = CghImportRouter.copy_into_project(path, category)
	if res_path == "":
		_report("Couldn't copy the model into the project (check disk space / write permission).", false)
		_track_import_result(asset, ext, false, "copy_to_project", "Couldn't copy the model into the project (disk space / write permission)")
		return
	_set_status("Importing 3D model…", false)
	var efs := EditorInterface.get_resource_filesystem()
	if efs:
		efs.scan()
		while efs.is_scanning():
			await get_tree().process_frame
	# Wait for the async import worker. If the file exists but load() keeps returning
	# null it's a failed/corrupt import — cap the attempts so ONE bad file doesn't flood
	# the console (each failed load() logs several engine errors).
	var imported_res = null
	var load_tries := 0
	for _i in 120:
		if ResourceLoader.exists(res_path) and _i % 12 == 0:
			imported_res = load(res_path)
			if imported_res != null:
				break
			load_tries += 1
			if load_tries >= 4:
				break
		await get_tree().process_frame
	# glTF/FBX/DAE import as a PackedScene; OBJ imports as a Mesh — handle both.
	var node = null
	if imported_res is PackedScene:
		node = imported_res.instantiate()
	elif imported_res is Mesh:
		var mi := MeshInstance3D.new()
		mi.mesh = imported_res
		mi.name = res_path.get_file().get_basename()
		node = mi
	if node == null:
		if imported_res == null:
			# File exists in the project but never loaded — a failed/corrupt import.
			_report("Couldn't import %s — the model file looks corrupt or uses an unsupported glTF feature. Delete the download and try another resolution." % res_path.get_file(), false)
			_track_import_result(asset, ext, false, "editor_import", "model failed to load after editor import (corrupt file or unsupported glTF feature)")
		else:
			# Imported, but not an auto-instanceable scene/mesh — leave it in the dock.
			_report("Model saved to %s — drag it from FileSystem into your scene." % res_path, true)
			_track_import_result(asset, ext, true)
		return
	var root := CghImportRouter.ensure_scene_root()
	if root == null:
		_report("Model imported to %s — open a 3D scene, then drag it in." % res_path, true)
		_track_import_result(asset, ext, true)
		return
	root.add_child(node)
	node.owner = root
	for c in node.find_children("*", "", true, false):
		c.owner = root
	var sel := EditorInterface.get_selection()
	if sel:
		sel.clear()
		sel.add_node(node)
	_report("3D model added — press F in the viewport to frame it.", true)
	_track_import_result(asset, ext, true)

func _on_card_upgrade(asset: Dictionary) -> void:
	# The card shows "Upgrade" only for a locked asset, so this is also the locked-asset click.
	analytics.track("locked_asset_clicked", _asset_props(asset, {"reason": "locked"}))
	analytics.track("upgrade_clicked", _asset_props(asset, {"source": "card", "src": CghConfig.ADDON_SLUG}))   # parity with AE/Premiere/Blender
	OS.shell_open(CghConfig.pricing_url())

# 🗑 Delete this asset's downloaded file(s) from disk, then flip the card back to
# "Download" so a missing / corrupt file can be re-fetched cleanly.
func _on_card_delete(asset: Dictionary) -> void:
	var n := CghDownloads.delete(asset)
	var card := _find_card(asset)
	if is_instance_valid(card):
		card.refresh_state()
	if n > 0:
		_set_status("Deleted %d file%s — you can download it again." % [n, "" if n == 1 else "s"], false)
	else:
		_set_status("Nothing on disk to delete — you can download it again.", false)

func _on_card_cancel(card) -> void:
	# cancel the in-flight download, or drop it from the queue if not started yet
	if _dl_active != null and _dl_active.get("card") == card:
		downloader.cancel()
		_dl_active = null
		if is_instance_valid(card):
			card.reset_after_cancel()
		_set_status("Download cancelled.", false)
		_pump_queue()
	else:
		for i in _dl_queue.size():
			if _dl_queue[i].get("card") == card:
				_dl_queue.remove_at(i)
				break
		if is_instance_valid(card):
			card.reset_after_cancel()

func _find_card(asset: Dictionary) -> CghAssetCard:
	for c in _grid.get_children():
		if c is CghAssetCard:
			if CghAsset.id(c.asset) == CghAsset.id(asset):
				return c
	return null

# ----------------------------------------------------------------- hover preview
func _on_preview_requested(card, asset: Dictionary) -> void:
	var urls = CghAsset.preview_images(asset)
	if urls.is_empty():
		return
	urls = urls.slice(0, 3)
	var frames := []
	var pending := {"n": urls.size()}
	for u in urls:
		var cached := CghCache.load_thumb(u)
		if cached:
			frames.append(cached)
			pending["n"] -= 1
			if pending["n"] <= 0 and is_instance_valid(card):
				card.set_preview_frames(frames)
			continue
		var h := HTTPRequest.new()
		add_child(h)
		h.request_completed.connect(func(r, code, _hh, body):
			if r == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300:
				var img := _decode_image(body, u)
				if img != null:
					frames.append(ImageTexture.create_from_image(img))
					CghCache.save_thumb(u, img)
			pending["n"] -= 1
			if pending["n"] <= 0 and is_instance_valid(card):
				card.set_preview_frames(frames)
			h.queue_free())
		h.request(u)

# Flipbook hover preview: download the REAL low-res sprite sheet (its filename declares the
# grid AND the image genuinely IS that grid) and hand it to the card to slice + play. This
# replaces slicing the card thumbnail, whose layout doesn't always match the sheet's NxM —
# e.g. muzzle-flashes use a single-frame thumbnail, so slicing it 5x5 showed garbage frames.
func _on_flipbook_sheet_requested(card, asset: Dictionary) -> void:
	var grid := CghAsset.flipbook_grid(asset)
	if grid.x * grid.y <= 1:
		return
	var e := _flipbook_image_alternative(asset)   # lowest-res unlocked png/jpg/webp sheet
	if e.is_empty():
		return
	var url: String = str(e.get("url", ""))
	if url == "":
		return
	var cached := CghCache.load_thumb(url)
	if cached:
		if is_instance_valid(card):
			card.set_flipbook_sheet(cached, grid)
		return
	var h := HTTPRequest.new()
	add_child(h)
	h.request_completed.connect(func(r, code, _hh, body):
		if r == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300:
			var img := _decode_image(body, url)
			if img != null:
				CghCache.save_thumb(url, img)
				if is_instance_valid(card):
					card.set_flipbook_sheet(ImageTexture.create_from_image(img), grid)
		h.queue_free())
	h.request(url)

# ----------------------------------------------------------------- favorites view
func _render_favorites() -> void:
	_clear_grid()
	if _page_bar:
		_page_bar.visible = false
	var favs := CghFavorites.all()
	_set_status("" if favs.size() > 0 else "No favorites yet. Tap ♡ on a card.", false)
	for a in favs:
		if a is Dictionary:
			_add_card(a)

func _on_fav_login_required() -> void:
	_set_status("Please login first to add favourites.", true)
	var dlg := ConfirmationDialog.new()
	dlg.title = "Login required"
	dlg.dialog_text = "Please login to save favourites.\n\nDo you want to login now?"
	dlg.ok_button_text = "Login"
	add_child(dlg)
	dlg.confirmed.connect(func(): _login_dlg.open())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.confirmed.connect(func(): dlg.queue_free())
	dlg.popup_centered()

func _on_favorite_toggled(asset: Dictionary, is_fav: bool) -> void:
	_update_fav_badge()
	if _filter_mode == 3:
		_render_favorites()
	if is_fav:   # the desktop addons only track the add, not the remove
		analytics.track("favourite_added", _asset_props(asset))

func _update_fav_badge() -> void:
	if _free and _free.item_count > 3:
		var n := CghFavorites.count()
		_free.set_item_text(3, "♥ Favorites (%d)" % n if n > 0 else "♥ Favorites")

# ----------------------------------------------------------------- account
# The top-nav button doubles as Login (guest) and Account/Profile (logged in) —
# both just open the dialog, which renders the right view (login buttons vs the
# profile card with Logout) for the current state.
func _on_login_logout() -> void:
	_login_dlg.open()

func _do_logout() -> void:
	auth.logout()
	api.set_session_token("")
	analytics.identify("", "Free")
	_refresh_account_ui()
	_load_first_page(true)   # force: the grid is cached per-plan, so a plan change must refetch

func _on_logged_in(plan: String) -> void:
	_collections_changed()
	api.set_session_token(auth.session_token)
	analytics.identify(auth.email, plan)
	analytics.track("account_login")
	_refresh_account_ui()
	# FORCE a fresh fetch (bypass cache): the page cache is keyed per plan, and a stale
	# page cached before login (or from an older query) must not be served to the logged-in
	# user — that's what made "All" show only a couple of assets right after login.
	_load_first_page(true)

func _on_plan_refreshed(plan: String) -> void:
	_collections_changed()
	api.set_session_token(auth.session_token)
	_refresh_account_ui()
	_set_status("Plan updated: %s" % plan, false)
	_load_first_page(true)   # force: access changed -> re-fetch instead of serving a stale page

# Server said the session is dead (401/402/403 on assets/categories): sign out, then explain.
func _on_auth_rejected(code: int, message: String) -> void:
	auth.end_session(code, message)

# Heartbeat renewed the 24h token: just hand the fresh token to the API client.
func _on_session_refreshed() -> void:
	api.set_session_token(auth.session_token)

# The user was signed out by the server (expired / revoked / used on another device).
# Say why, then reload as a guest so the grid is usable instead of stuck on errors.
func _on_session_expired(reason: String) -> void:
	_collections_changed()
	api.set_session_token("")
	analytics.identify("", "Free")
	_refresh_account_ui()
	_set_status(reason, true)
	_show_toast(reason, "error")
	api.fetch_categories()
	_load_first_page(true)

func _sweep_temp_extractions() -> void:
	CghDownloads.clean_temp_extractions()

func _refresh_account_ui() -> void:
	_login_btn.text = "👤 Account" if auth.is_logged_in() else "Login"
	if _login_dlg:
		_login_dlg.refresh()

# ----------------------------------------------------------------- updates
func _on_update_available(version: String, notes: String, url: String) -> void:
	analytics.track("update_prompt_shown", {"from_version": CghConfig.ADDON_VERSION, "to_version": version})
	var dlg := ConfirmationDialog.new()
	dlg.title = "Update available — v%s" % version
	dlg.dialog_text = (notes if notes != "" else "A new version is available.") + "\n\nDownload now? (editor restart required to apply)"
	add_child(dlg)
	dlg.confirmed.connect(func():
		_set_status("Downloading update…", false)
		updater.download_and_stage(url))
	dlg.popup_centered()

func _on_up_to_date() -> void:
	if _manual_check:
		_set_status("You're on the latest version.", false)
	_manual_check = false

func _on_update_failed(message: String) -> void:
	# Silent on the automatic boot check; only show if the user asked explicitly.
	if _manual_check:
		_set_status("Couldn't check for updates right now.", false)
	_manual_check = false

func _on_update_staged() -> void:
	analytics.track("update_completed")
	var dlg := ConfirmationDialog.new()
	dlg.title = "Update ready"
	dlg.dialog_text = "Update installed. Restart the editor to apply it now?"
	add_child(dlg)
	dlg.confirmed.connect(func(): EditorInterface.restart_editor(true))
	dlg.popup_centered()

# ----------------------------------------------------------------- helpers
func _clear_grid() -> void:
	if _page_bar:
		_page_bar.visible = false   # never leave a stale "1 2 3 …" bar floating over an empty grid
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	# drop pending thumbnail work + cancel in-flight (cards are gone now)
	_thumb_queue.clear()
	for h in _thumb_http:
		if _thumb_ctx.get(h) != null:
			h.cancel_request()
			_thumb_ctx[h] = null

func _reflow_columns() -> void:
	# AE-exact responsive breakpoints (2→7 columns by panel width).
	if _grid:
		_grid.columns = CghConfig.responsive_columns(size.x)

## Standard asset properties for analytics events (matches the desktop addons).
func _asset_props(asset: Dictionary, extra := {}) -> Dictionary:
	var p := {
		"asset_id": CghAsset.id(asset),
		"asset_name": CghAsset.title(asset),
		"category": CghAsset.category_slug(asset),
		"sub_category": _subcat,
	}
	for k in extra:
		p[k] = extra[k]
	return p

func _set_status(msg: String, is_err: bool) -> void:
	if _status:
		_status.text = msg
		_status.visible = msg != ""   # reserve no vertical space when there's nothing to say
		_status.add_theme_color_override("font_color", CghConfig.C_ERR if is_err else CghConfig.C_TEXT2)
