@tool
extends RefCounted
class_name CghConfig
## Central config + exact After-Effects-addon color palette.
## All colors copied 1:1 from the AE/PPRO addon spec so the Godot panel looks identical.

# ---------------------------------------------------------------------------
# Backend endpoints (override via OS env for dev, like the desktop addons)
# ---------------------------------------------------------------------------
const ADDON_SLUG := "godot"
const ADDON_VERSION := "1.0.0"

static func api_base() -> String:
	var e := OS.get_environment("CGHEVEN_API_BASE")
	return e if e != "" else "https://api.cgheven.com"

static func web_base() -> String:
	var e := OS.get_environment("CGHEVEN_WEB_BASE")
	return e if e != "" else "https://cgheven.com"

# Asset listing goes through the same gating proxy the other addons use.
static func public_assets_url() -> String:
	return api_base() + "/api/proxy/public/assets"   # guest browsing
static func authed_assets_url() -> String:
	return api_base() + "/api/proxy/assets"          # logged-in (Bearer)
# Category tree (top categories + subcategories) — same proxy, for the live
# subcategory dropdown.
static func public_categories_url() -> String:
	return api_base() + "/api/proxy/public/categories"
static func authed_categories_url() -> String:
	return api_base() + "/api/proxy/categories"
# BlenderKit-exact broker: the addon opens our website's /addon-login page, which logs
# the user in and redirects to the loopback with a short ?code=. addon.start_login()
# builds the full URL (it has the port/state/machine). Loopback path mirrors Blender.
static func login_base_url() -> String:
	return web_base() + "/addon-login"
static func loopback_redirect(port: int) -> String:
	return "http://127.0.0.1:%d/consumer/exchange/" % port
# Same endpoint the Blender/AE addons redeem their handoff code at.
static func addon_exchange_url() -> String:
	return api_base() + "/api/logto/addon-exchange"
static func addon_activate_url() -> String:
	return api_base() + "/api/addon-license/activate"
static func heartbeat_url() -> String:
	return api_base() + "/api/addon-updates/heartbeat"
# Analytics goes through the backend (same as every desktop addon) so the PostHog
# key stays server-side — the addon never ships a key.
static func analytics_track_url() -> String:
	return api_base() + "/api/analytics/track"
static func check_update_url() -> String:
	return api_base() + "/api/addon-updates/check"
static func pricing_url() -> String:
	return web_base() + "/pricing"
static func discord_url() -> String:
	return "https://discord.gg/cgheven"

# PostHog (analytics) — same project as the desktop addons.
static func posthog_host() -> String:
	return "https://us.i.posthog.com"
static func posthog_key() -> String:
	var e := OS.get_environment("CGHEVEN_POSTHOG_KEY")
	return e if e != "" else ""   # filled at build/ship time

# Loopback OAuth ports (avoid 62485 = BlenderKit, like the Blender addon)
const LOOPBACK_PORTS := [62490, 62491, 62492]

# Locked-file marker the backend sends instead of a real CDN url.
const LOCK_PREFIX := "CGHLOCKED::"

# Local data lives under user:// (cross-project, per-user, always writable).
const DATA_DIR := "user://cgheven"
const CACHE_DIR := "user://cgheven/cache"
const THUMB_DIR := "user://cgheven/thumbs"
const DOWNLOAD_DIR := "user://cgheven/downloads"
const PREFS_FILE := "user://cgheven/prefs.json"

# ---------------------------------------------------------------------------
# User prefs (persisted JSON) — e.g. a custom download folder the user picks.
# ---------------------------------------------------------------------------
static func _read_prefs() -> Dictionary:
	if not FileAccess.file_exists(PREFS_FILE):
		return {}
	var f := FileAccess.open(PREFS_FILE, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var d = JSON.parse_string(txt)
	return d if d is Dictionary else {}

static func _write_prefs(d: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(DATA_DIR)
	var f := FileAccess.open(PREFS_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d))
		f.close()

# Where the user chose to save downloads ("" = use the default shared folder).
static func custom_download_dir() -> String:
	return str(_read_prefs().get("download_dir", ""))

static func set_custom_download_dir(p: String) -> void:
	var d := _read_prefs()
	d["download_dir"] = p
	_write_prefs(d)

# ---------------------------------------------------------------------------
# COLORS — exact hex from the After Effects addon (addon-ui-spec)
# ---------------------------------------------------------------------------
const C_BG          := Color("141416")
const C_BG2         := Color("1a1a1f")
const C_CARD        := Color("1e1e24")
const C_CARD_HOVER  := Color("252530")
const C_INPUT       := Color("1a1a20")
const C_NAV         := Color("111114")
const C_ACCENT      := Color("5b7cff")
const C_ACCENT_HOVER:= Color("6e8dff")
const C_ACCENT_DIM  := Color(0.357, 0.486, 1.0, 0.14)   # rgba(91,124,255,.14)
const C_TEXT1       := Color("f0f0f5")
const C_TEXT2       := Color("8a8a9a")
const C_TEXT3       := Color("505060")
const C_BORDER      := Color(1, 1, 1, 0.07)             # rgba(255,255,255,.07)
const C_BORDER_HOVER:= Color(1, 1, 1, 0.13)             # rgba(255,255,255,.13)
const C_DROPDOWN    := Color("1c1c22")                  # popover bg --bgd
const C_OK          := Color("34c759")
const C_ERR         := Color("ff453a")
const C_WARN        := Color("ff9f0a")
# CGHEVEN brand gradient: #f97316 -> #ef4444 (StyleBoxFlat has no gradient,
# so the Upgrade/Login buttons use a solid mid-orange that reads the same).
const C_BRAND_A     := Color("f97316")
const C_BRAND_B     := Color("ef4444")
const C_BRAND       := Color("f4502c")                  # mid of the gradient
const C_BRAND_HOVER := Color("e0431f")
const C_RES_BADGE   := Color(0.039, 0.039, 0.071, 0.82) # rgba(10,10,18,.82)
const C_FOOTER_PILL := Color(0.5, 0.5, 0.5, 0.07)       # rgba(128,128,128,.07)

# Radii / spacing (AE spec)
const RADIUS_SM := 4
const RADIUS_MD := 6
const RADIUS_LG := 8     # card radius
const RADIUS_XL := 10
const GRID_GAP  := 7

# Category pills. Real backend slugs (from the Blender addon):
#   vfx, 3d-models, hdri, flipbooks, vdbs, shaders, tutorials
# Godot can usefully consume only: 3d-models, hdri, flipbooks.
# vdbs / vfx(video) / tutorials / shaders are Blender-only and intentionally NOT listed.
const CATEGORIES := [
	{"label": "All",       "slug": ""},
	{"label": "3D Models", "slug": "3d-models"},
	{"label": "HDRI",      "slug": "hdri"},
	{"label": "Flipbooks", "slug": "flipbooks"},
]

# Subcategories per parent slug (from the Blender addon _PARENT_MAP).
# Each subcategory is itself a backend category Slug; selecting one filters by it.
const SUBCATEGORIES := {
	"3d-models": [
		{"label": "Furniture", "slug": "furniture"},
		{"label": "Props",     "slug": "props"},
		{"label": "Weapons",   "slug": "weapons"},
	],
	"hdri": [
		{"label": "Space",     "slug": "space-hdr"},
	],
	"flipbooks": [
		{"label": "Fire",          "slug": "fire-flipbooks"},
		{"label": "Magic Effects", "slug": "magic-effects-flipbooks"},
		{"label": "Muzzle Flashes","slug": "muzzle-flashes-flipbooks"},
		{"label": "Tornado FX",    "slug": "tornado-fx-flipbooks"},
	],
	"shaders": [],
}

# Sort options (matches AE/Blender)
const SORTS := [
	{"label": "Newest", "param": "createdAt:desc"},
	{"label": "Oldest", "param": "createdAt:asc"},
	{"label": "A -> Z", "param": "Title:asc"},
	{"label": "Z -> A", "param": "Title:desc"},
]

# File extensions Godot can import, grouped by purpose.
const EXT_3D      := ["glb", "gltf", "fbx"]
const EXT_HDRI    := ["exr", "hdr"]
const EXT_IMAGE   := ["png", "jpg", "jpeg", "webp"]   # flipbook sheets / textures
const EXT_ARCHIVE := ["zip"]
# Resolution tokens recognised in filenames (index 0 = lowest = free fallback)
const RES_ORDER := ["1k", "2k", "4k", "8k", "16k"]

# Discord invite (Godot community — placeholder, set real link before ship)
const DISCORD := "https://discord.gg/cgheven"

static func ensure_dirs() -> void:
	for d in [DATA_DIR, CACHE_DIR, THUMB_DIR, DOWNLOAD_DIR]:
		DirAccess.make_dir_recursive_absolute(d)

# ---------------------------------------------------------------------------
# Cross-addon "file scanner" — shared CGHEVEN download folders on the OS.
# A file downloaded by AE (~/Downloads/CGHEVEN), Blender (~/Documents/CGHEVEN)
# or this addon should show the ✓ "downloaded" tick everywhere. We scan all of
# these by filename so the tick is shared across every CGHEVEN addon.
# ---------------------------------------------------------------------------
static func os_home() -> String:
	var h := OS.get_environment("USERPROFILE")        # Windows
	if h == "":
		h = OS.get_environment("HOME")                # macOS / Linux
	return h

static func shared_download_dirs() -> Array:
	var home := os_home()
	var dirs := []
	var custom := custom_download_dir()
	if custom != "":
		dirs.append(custom)                                             # user-chosen folder
	if home != "":
		dirs.append(home.path_join("Downloads").path_join("CGHEVEN"))   # AE / PPRO default
		dirs.append(home.path_join("Documents").path_join("CGHEVEN"))   # Blender default
	dirs.append(ProjectSettings.globalize_path(DOWNLOAD_DIR))           # this addon
	return dirs

# Where THIS addon saves downloads — a user-chosen folder if set, else the shared
# AE folder so the other CGHEVEN addons see the files too.
static func primary_download_dir() -> String:
	var custom := custom_download_dir()
	if custom != "":
		return custom
	var home := os_home()
	if home != "":
		return home.path_join("Downloads").path_join("CGHEVEN")
	return ProjectSettings.globalize_path(DOWNLOAD_DIR)

# Sanitize a CDN filename the same way the Blender addon does (cross-addon match).
static func safe_download_name(filename: String) -> String:
	var f := filename.uri_decode()
	for ch in ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]:
		f = f.replace(ch, "_")
	return f

# ---------------------------------------------------------------------------
# Responsive grid columns — exact AE breakpoints (panel width -> column count).
# ---------------------------------------------------------------------------
static func responsive_columns(width: float) -> int:
	# Default narrow dock shows 2 large AE-style cards; grows on wider panels.
	if width < 520.0: return 2
	if width < 780.0: return 3
	if width < 1040.0: return 4
	if width < 1300.0: return 5
	if width < 1560.0: return 6
	return 7
