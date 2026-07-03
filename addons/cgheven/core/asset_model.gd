@tool
extends RefCounted
class_name CghAsset
## Helpers to read a Strapi asset dict and turn its files[] / green_screen[]
## into structured, Godot-relevant download entries.

# Flip to true to trace thumbnail decode + poster-rescue in the Godot Output panel
# (see main_dock._on_thumb and asset_card._static_poster).
const THUMB_DEBUG := false

static func attrs(asset: Dictionary) -> Dictionary:
	return asset.get("attributes", asset)

static func title(asset: Dictionary) -> String:
	return attrs(asset).get("Title", "Untitled")

static func id(asset: Dictionary) -> String:
	var raw = asset.get("id", null)
	if raw == null:
		raw = attrs(asset).get("assets_slug", title(asset))
	# JSON parses numeric ids as float -> str(2139.0) = "2139.0", which breaks the
	# /assets/<id> URL and the cross-addon manifest. Always render whole ids as ints.
	if raw is float:
		return str(int(raw))
	if raw is int:
		return str(raw)
	return str(raw)

## Thumbnail URL — mirrors AE's AU.thumb() + Blender's _normalize_media_url():
## accepts a plain string OR a Strapi media relation, and prepends the CDN base
## only for host-relative ("/uploads/…") URLs.
static func thumbnail(asset: Dictionary) -> String:
	var t = attrs(asset).get("thumbnail", "")
	var url := ""
	if t is String:
		url = t
	elif t is Dictionary:
		var d = t.get("data", null)
		if d is Dictionary:
			var da = d.get("attributes", d)
			if da is Dictionary:
				url = str(da.get("url", ""))
		elif t.has("url"):
			url = str(t.get("url", ""))
	return _normalize_media_url(url)

static func _normalize_media_url(url: String) -> String:
	var raw := url.strip_edges()
	if raw == "":
		return ""
	if raw.begins_with("//"):
		return "https:" + raw
	if raw.begins_with("/"):
		return "https://cdn.cgheven.com" + raw
	return raw

## Category slug — flat-first, exactly like the AE/Blender/DaVinci addons:
## the proxy returns a flat `categorie.Slug`, but tolerate nested `data.attributes`.
static func _cat_attrs(asset: Dictionary) -> Dictionary:
	var c = attrs(asset).get("categorie", {})
	if not (c is Dictionary):
		return {}
	var d = c.get("data", c)              # nested Strapi shape -> unwrap, else flat
	if d is Dictionary:
		var da = d.get("attributes", d)
		if da is Dictionary:
			return da
	return {}

static func category_slug(asset: Dictionary) -> String:
	var da := _cat_attrs(asset)
	return str(da.get("Slug", da.get("slug", "")))

## Human-readable asset slug, like the Blender addon (assets_slug, fallbacks).
static func assets_slug(asset: Dictionary) -> String:
	var a := attrs(asset)
	var s = a.get("assets_slug", a.get("Assets_slug", a.get("asset_slug", a.get("slug", ""))))
	return str(s).strip_edges()

## Canonical website URL — matches Blender: https://cgheven.com/assets/<assets_slug>.
## Falls back to the numeric id only if there's no usable slug.
static func web_url(asset: Dictionary) -> String:
	var slug := assets_slug(asset).split("/")[0].split("?")[0].strip_edges().to_lower()
	var rx := RegEx.new()
	rx.compile("^[a-z0-9_-]+$")
	if slug != "" and rx.search(slug) != null:
		return CghConfig.web_base() + "/assets/" + slug
	return CghConfig.web_base() + "/assets/" + id(asset)

static func category_title(asset: Dictionary) -> String:
	var da := _cat_attrs(asset)
	var t := str(da.get("Title", da.get("Name", "")))
	return t if t != "" else "Asset"

## Hover-preview image URLs (additional_images[] + previews). Godot can't play
## the mp4/webm preview VIDEO, so we cycle these stills as a slideshow instead.
static func preview_images(asset: Dictionary) -> Array:
	var a := attrs(asset)
	var out := []
	var add = a.get("additional_images", [])
	if add is Array:
		for u in add:
			if u is String and u != "":
				out.append(u)
	var prev = a.get("previews", "")
	if prev is String and prev != "" and not prev.to_lower().ends_with(".mp4") \
			and not prev.to_lower().ends_with(".webm") and not prev.to_lower().ends_with(".mov"):
		out.append(prev)
	return out

## Flipbook sprite-sheet grid (cols x rows) parsed from the asset's file names /
## previews / thumbnail (e.g. "..._8x8.png"). Vector2i(0,0) when unknown. Lets the card
## animate the flipbook on hover by slicing its sprite-sheet thumbnail into frames.
static func flipbook_grid(asset: Dictionary) -> Vector2i:
	var rx := RegEx.new()
	rx.compile("(\\d+)\\s*[xX]\\s*(\\d+)")
	var cands := []
	for e in file_entries(asset):
		cands.append(str(e.get("filename", "")))
	var a := attrs(asset)
	cands.append(str(a.get("previews", "")))
	cands.append(thumbnail(asset))
	for c in cands:
		var m := rx.search(str(c))
		if m:
			var cols := int(m.get_string(1))
			var rows := int(m.get_string(2))
			if cols >= 1 and rows >= 1 and cols <= 32 and rows <= 32:
				return Vector2i(cols, rows)
	return Vector2i(0, 0)

static func is_new(asset: Dictionary) -> bool:
	# treat early_access>0 or a releaseDate within ~21 days as "NEW"
	var a := attrs(asset)
	return int(a.get("early_access", 0)) > 0

static func patreon_locked(asset: Dictionary) -> bool:
	return attrs(asset).get("is_patreon_locked", false) == true

## Returns an array of file entries:
##   {url, filename, ext, res, res_rank, format, locked}
## Mirrors AE/Blender/DaVinci parseFiles(): per-file CGHLOCKED:: gating, resolution
## parsed from the filename, and 3D format detected inside .zip archives. Each file
## entry may be a plain URL string OR a Strapi media object {url}.
static func file_entries(asset: Dictionary) -> Array:
	var out := []
	var a := attrs(asset)
	for key in ["files", "green_screen"]:
		var arr = a.get(key, [])
		if not (arr is Array):
			continue
		for raw in arr:
			var u := ""
			if raw is String:
				u = raw
			elif raw is Dictionary:
				u = str(raw.get("url", ""))
			if u == "":
				continue
			var locked: bool = u.begins_with(CghConfig.LOCK_PREFIX)
			var real: String = u.substr(CghConfig.LOCK_PREFIX.length()) if locked else u
			var fname: String = real.get_file()
			var q := fname.find("?")               # strip any query string
			if q != -1:
				fname = fname.substr(0, q)
			var ext: String = fname.get_extension().to_lower()
			var res := detect_res(fname)
			var fmt := ext.to_upper()
			if ext == "zip" or ext == "rar":
				var zf := _archive_format(fname)   # FBX/GLTF/OBJ/BLEND from the archive name
				if zf != "":
					fmt = zf
			if key == "green_screen":
				fmt += " (GS)"
			out.append({
				"url": ("" if locked else real),
				"filename": fname,
				"ext": ext,
				"res": res,
				"res_rank": res_rank(res),
				"format": fmt,
				"locked": locked,
				"preview": false,
			})
	# 3D models ship only as .zip/.rar archives; the directly Godot-importable model is
	# the preview .glb in `previews`. Add it so 3D assets are importable (no "No file"),
	# unless the whole asset is patreon-locked (then it stays Upgrade-only).
	var prev = a.get("previews", "")
	if prev is String and prev != "" and not patreon_locked(asset):
		var pf: String = prev
		var pq2 := pf.find("?")
		if pq2 != -1:
			pf = pf.substr(0, pq2)
		var pext := pf.get_file().get_extension().to_lower()
		if pext in ["glb", "gltf", "fbx"]:
			out.append({
				"url": prev,
				"filename": pf.get_file(),
				"ext": pext,
				"res": "",
				"res_rank": 1,        # above a real full-res file (rank 0) so that's preferred
				"format": pext.to_upper(),
				"locked": false,
				"preview": true,
			})
	return out

## Format encoded in an archive's filename (CGHEVEN names them _Fbx/_Blend/_Gltf/_Obj).
static func _archive_format(fname: String) -> String:
	var fu := fname.to_upper()
	if fu.find("_GLTF") != -1 or fu.find("_GLB") != -1:
		return "GLTF"
	if fu.find("_FBX") != -1:
		return "FBX"
	if fu.find("_OBJ") != -1:
		return "OBJ"
	if fu.find("_BLEND") != -1:   # also matches _BLENDER
		return "BLEND"
	return ""

## Only the entries Godot can actually import:
##  - direct glb/gltf/fbx/exr/hdr/png/jpg/webp (incl. the preview .glb)
##  - a .zip Godot can unpack (ZIPReader) UNLESS it's a Blender-only archive (.blend inside)
##  - never .rar (Godot can't extract it) or a BLEND archive
static func importable_entries(asset: Dictionary) -> Array:
	var direct := CghConfig.EXT_3D + CghConfig.EXT_HDRI + CghConfig.EXT_IMAGE
	var out := []
	for e in file_entries(asset):
		var ext: String = e["ext"]
		if ext in direct:
			out.append(e)
		elif ext == "zip" and e["format"] != "BLEND":
			out.append(e)
	return out

## True if at least one file is unlocked (-> Download, not Upgrade).
## Matches AE's hasFreeFile()/lockedForUser(): lock is purely server-driven via the
## CGHLOCKED:: marker, so we only trust per-file `locked`. The backend already frees
## the lowest available resolution (e.g. 4K is free on a 4K/8K-only asset).
static func has_free_file(asset: Dictionary) -> bool:
	for e in file_entries(asset):
		if not e["locked"]:
			return true
	return false

## Best free entry: lowest-resolution unlocked importable file. For flipbooks, prefer a
## PNG/JPG/WebP sheet over EXR — Godot's EXR loader (tinyexr) can't read some compressions,
## so an EXR flipbook fails to import while the PNG version always works.
static func best_free_entry(asset: Dictionary) -> Dictionary:
	var cands := importable_entries(asset).filter(func(e): return not e["locked"])
	if cands.is_empty():
		return {}
	if category_slug(asset) == "flipbooks":
		var imgs := cands.filter(func(e): return e["ext"] in ["png", "jpg", "jpeg", "webp"])
		if not imgs.is_empty():
			cands = imgs
	cands.sort_custom(func(a, b): return a["res_rank"] < b["res_rank"])
	return cands[0]

## Lowest-resolution UNLOCKED file of ANY format (even ones Godot can't auto-import,
## e.g. .rar). Fallback so a card whose only free file is non-importable still DOWNLOADS
## it to the shared folder (user can extract/use it) instead of the click doing nothing.
static func best_free_any(asset: Dictionary) -> Dictionary:
	var cands := file_entries(asset).filter(func(e): return not e["locked"] and e["url"] != "")
	if cands.is_empty():
		return {}
	cands.sort_custom(func(a, b): return a["res_rank"] < b["res_rank"])
	return cands[0]

# Resolution detection — ported from the desktop addons (RES_PATTERNS). Dimension
# patterns first (most specific), then word/number tokens. First match wins.
const _RES_DEFS := [
	["7680\\s*[x×]\\s*4320", "8K"],
	["(4096|3840)\\s*[x×]\\s*2160", "4K"],
	["(2560\\s*[x×]\\s*1440|2048\\s*[x×]\\s*1080)", "2K"],
	["1920\\s*[x×]\\s*1080", "1080p"],
	["(?<![a-z0-9])8\\s*k(?![a-z0-9])|8192", "8K"],
	["(?<![a-z0-9])4\\s*k(?![a-z0-9])|4096|uhd", "4K"],
	["(?<![a-z0-9])2\\s*k(?![a-z0-9])|2048", "2K"],
	["(?<![a-z0-9])1\\s*k(?![a-z0-9])|1024", "1K"],
	["2160", "4K"],
	["1080", "1080p"],
	["720", "720p"],
	["(?<![a-z0-9])hd(?![a-z0-9])", "HD"],
]
# Low-first rank used to pick the "best free entry" (1K before 4K), like the addons.
const _RES_RANK := {
	"": 0, "PREVIEW": 1, "480P": 2, "720P": 3, "HD": 3,
	"1080P": 4, "1K": 5, "2K": 6, "4K": 7, "5K": 8, "8K": 9, "16K": 10,
}
static var _res_rx := []   # [{rx, label}] compiled lazily

static func _ensure_res_rx() -> void:
	if not _res_rx.is_empty():
		return
	for d in _RES_DEFS:
		var rx := RegEx.new()
		rx.compile("(?i)" + d[0])   # case-insensitive
		_res_rx.append({"rx": rx, "label": d[1]})

static func detect_res(fname: String) -> String:
	_ensure_res_rx()
	for e in _res_rx:
		if e["rx"].search(fname) != null:
			return e["label"]
	return ""

static func res_rank(label: String) -> int:
	return int(_RES_RANK.get(label.to_upper(), 0))
