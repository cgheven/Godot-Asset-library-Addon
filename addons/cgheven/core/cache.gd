@tool
extends RefCounted
class_name CghCache
## Local JSON cache + thumbnail cache under user://cgheven (cross-project).
## Plan-keyed so a Free->Pro upgrade re-fetches instead of serving stale gated data.

# Bump this when the asset query changes shape (e.g. the "All" tab now excludes
# vfx/vdbs) — old cache files have a different prefix and are simply ignored.
const ASSET_CACHE_VERSION := "v2"

static func _asset_cache_path(plan: String, key: String) -> String:
	return "%s/assets_%s_%s_%s.json" % [CghConfig.CACHE_DIR, ASSET_CACHE_VERSION, plan, key.sha256_text().substr(0, 12)]

## Store the page envelope {assets, meta} so pagination (pageCount) survives too.
static func save_assets(plan: String, key: String, assets: Array, meta := {}) -> void:
	CghConfig.ensure_dirs()
	var f := FileAccess.open(_asset_cache_path(plan, key), FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"assets": assets, "meta": meta}))
		f.close()

## Returns {"assets":[...], "meta":{...}} or {} on a miss. Instant (disk read) —
## a page that was loaded once is served from here forever (no re-fetch).
static func load_page(plan: String, key: String) -> Dictionary:
	var p := _asset_cache_path(plan, key)
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if not f:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary and parsed.has("assets"):
		return parsed
	if parsed is Array:   # back-compat with the old (array-only) cache format
		return {"assets": parsed, "meta": {}}
	return {}

## Wipe only the asset-list cache (keeps thumbnails) — used by the manual Refresh.
static func clear_assets() -> void:
	var d := DirAccess.open(CghConfig.CACHE_DIR)
	if d:
		for file in d.get_files():
			d.remove(file)

# --- Thumbnails: store the ALREADY-DECODED image as PNG, rebuild on load. ---
# (Source thumbnails are .webp; we must re-encode to PNG, not dump raw webp into a
#  .png file — otherwise Image.load() picks the decoder by extension and fails.)
static func _thumb_path(url: String) -> String:
	return "%s/%s.png" % [CghConfig.THUMB_DIR, url.sha256_text().substr(0, 16)]

static func has_thumb(url: String) -> bool:
	return FileAccess.file_exists(_thumb_path(url))

static func save_thumb(url: String, img: Image) -> void:
	if img == null:
		return
	CghConfig.ensure_dirs()
	img.save_png(_thumb_path(url))

static func load_thumb(url: String) -> Texture2D:
	var p := _thumb_path(url)
	if not FileAccess.file_exists(p):
		return null
	var img := Image.new()
	if img.load(p) != OK:
		return null
	return ImageTexture.create_from_image(img)

static func clear() -> void:
	for dir in [CghConfig.CACHE_DIR, CghConfig.THUMB_DIR]:
		var d := DirAccess.open(dir)
		if d:
			for file in d.get_files():
				d.remove(file)
