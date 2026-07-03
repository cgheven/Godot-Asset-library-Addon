@tool
extends RefCounted
class_name CghDownloads
## Cross-addon "downloaded" state — matches the After Effects / Premiere / DaVinci
## addons, which all share ONE manifest file: ~/.cgheven_cg_dl_v2.json
##
## Detection is by ASSET ID (each record is {id, fp, fmt, res, title, cat, at}); an
## asset counts as downloaded if the manifest has a record for its id whose file is
## still on disk. We append a record whenever this addon finishes a download, so a
## file grabbed in Godot shows the ✓ in AE/Premiere/DaVinci too, and vice-versa.
##
## We ALSO keep a cheap filename scan of the shared download folders as a secondary
## signal (this catches the Blender addon, which uses its own ~/Documents/CGHEVEN +
## a separate prefs file and isn't part of the v2 manifest).

const MANIFEST_NAME := ".cgheven_cg_dl_v2.json"
const MAX_RECORDS := 200

static var _names := {}          # lower-case filename -> true (folder scan)
static var _ids := {}            # asset-id string -> true (manifest, file-exists verified)
static var _id_res := {}         # "id|res" -> true (per-resolution, cross-addon)
static var _scanned := false

# Normalize an id so "3535.0" (an old float-string id) matches "3535".
static func _norm_id(v) -> String:
	var s := str(v)
	if s.ends_with(".0"):
		s = s.substr(0, s.length() - 2)
	return s

static func _manifest_path() -> String:
	var home := CghConfig.os_home()
	if home == "":
		return ""
	return home.path_join(MANIFEST_NAME)

static func _read_manifest() -> Array:
	var p := _manifest_path()
	if p == "" or not FileAccess.file_exists(p):
		return []
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return []
	var txt := f.get_as_text()
	f.close()
	var d = JSON.parse_string(txt)
	return d if d is Array else []

static func _write_manifest(arr: Array) -> void:
	var p := _manifest_path()
	if p == "":
		return
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(arr))
		f.close()

static func rescan() -> void:
	_names.clear()
	_ids.clear()
	_id_res.clear()
	# 1) shared manifest (AE / Premiere / DaVinci) — verify each file still exists
	for r in _read_manifest():
		if not (r is Dictionary):
			continue
		var fp := str(r.get("fp", ""))
		if fp != "" and FileAccess.file_exists(fp):
			var rid := _norm_id(r.get("id", ""))
			_ids[rid] = true
			_id_res["%s|%s" % [rid, str(r.get("res", ""))]] = true
	# 2) folder filename scan (Blender + this addon's own folder)
	for dir in CghConfig.shared_download_dirs():
		_scan_dir(dir)
	_scanned = true

static func _scan_dir(abs_dir: String) -> void:
	var da := DirAccess.open(abs_dir)
	if da == null:
		return
	da.list_dir_begin()
	var fn := da.get_next()
	while fn != "":
		if not da.current_is_dir() and not fn.ends_with(".cghpart"):
			_names[fn.to_lower()] = true
		fn = da.get_next()
	da.list_dir_end()

static func _ensure() -> void:
	if not _scanned:
		rescan()

## True if this asset is already downloaded by ANY CGHEVEN addon.
static func is_downloaded(asset: Dictionary) -> bool:
	_ensure()
	# id match via the shared manifest (the AE/Premiere/DaVinci scheme; cross-addon)
	if _ids.has(_norm_id(CghAsset.id(asset))):
		return true
	# fallback: any of this asset's files present on disk by name
	for e in CghAsset.file_entries(asset):
		if e["locked"]:
			continue
		var nm: String = CghConfig.safe_download_name(e["filename"]).to_lower()
		if _names.has(nm):
			return true
	return false

## True if a SPECIFIC resolution of this asset was downloaded by any addon.
static func is_res_downloaded(asset_id: String, res: String) -> bool:
	_ensure()
	return _id_res.has("%s|%s" % [_norm_id(asset_id), res])

## True if THIS specific file (by name) is already on disk in a shared folder —
## used to switch a per-resolution menu row from "Download" to "Import".
static func has_file(filename: String) -> bool:
	_ensure()
	return _names.has(CghConfig.safe_download_name(filename).to_lower())

## Absolute path of this file in ANY shared CGHEVEN folder, or "" if not on disk.
static func local_path(filename: String) -> String:
	var safe := CghConfig.safe_download_name(filename)
	for d in CghConfig.shared_download_dirs():
		var p: String = d.path_join(safe)
		if FileAccess.file_exists(p):
			return p
	return ""

## Record a finished download into BOTH the in-memory caches and the shared manifest
## so every other CGHEVEN addon sees it immediately.
static func record(asset: Dictionary, fp: String, fmt: String, res: String) -> void:
	var id := _norm_id(CghAsset.id(asset))
	_ids[id] = true
	_id_res["%s|%s" % [id, res]] = true
	_names[CghConfig.safe_download_name(fp.get_file()).to_lower()] = true
	var arr := _read_manifest()
	# drop any prior record for the same id+fmt+res, then prepend the new one
	var kept := []
	for r in arr:
		if not (r is Dictionary):
			continue
		if _norm_id(r.get("id", "")) == id and str(r.get("fmt", "")) == fmt and str(r.get("res", "")) == res:
			continue
		kept.append(r)
	kept.insert(0, {
		"id": id,
		"fp": fp,
		"fmt": fmt,
		"res": res,
		"title": CghAsset.title(asset),
		"cat": CghAsset.category_slug(asset),
		"at": int(Time.get_unix_time_from_system() * 1000.0),
	})
	if kept.size() > MAX_RECORDS:
		kept = kept.slice(0, MAX_RECORDS)
	_write_manifest(kept)

## Delete every downloaded copy of this asset from the shared folders and drop its
## manifest records, so the card flips back to "Download". Use it to re-fetch a file
## that went missing or imported corrupt. Returns how many files were removed.
static func delete(asset: Dictionary) -> int:
	_ensure()
	var id := _norm_id(CghAsset.id(asset))
	var names := {}
	for e in CghAsset.file_entries(asset):
		names[CghConfig.safe_download_name(e["filename"]).to_lower()] = true
	var removed := 0
	# Drop this asset's manifest records, deleting the files they point at first.
	var kept := []
	for r in _read_manifest():
		if not (r is Dictionary):
			continue
		if _norm_id(r.get("id", "")) == id:
			var fp := str(r.get("fp", ""))
			if fp != "":
				names[fp.get_file().to_lower()] = true
				if FileAccess.file_exists(fp) and DirAccess.remove_absolute(fp) == OK:
					removed += 1
			continue
		kept.append(r)
	_write_manifest(kept)
	# Delete any remaining copies by filename across every shared CGHEVEN folder.
	for d in CghConfig.shared_download_dirs():
		for nm in names.keys():
			var p: String = d.path_join(nm)
			if FileAccess.file_exists(p) and DirAccess.remove_absolute(p) == OK:
				removed += 1
	# Clear the in-memory caches so is_downloaded()/has_file() update immediately.
	_ids.erase(id)
	for k in _id_res.keys():
		if str(k).begins_with(id + "|"):
			_id_res.erase(k)
	for nm in names.keys():
		_names.erase(nm)
	return removed

## Back-compat shim — older callers just marked a filename saved.
static func mark_saved(filename: String) -> void:
	_names[CghConfig.safe_download_name(filename).to_lower()] = true

## Titles (+ resolutions) of assets present in the shared cross-addon manifest whose
## file is still on disk — used by the ⤓ Sync button to show "what synced". One row
## per asset (resolutions merged), newest first.
static func synced_records() -> Array:
	var by_id := {}          # id -> {title, cat, res:[...]}
	var order := []          # id first-seen order (manifest is newest-first)
	for r in _read_manifest():
		if not (r is Dictionary):
			continue
		var fp := str(r.get("fp", ""))
		if fp == "" or not FileAccess.file_exists(fp):
			continue
		var id := _norm_id(r.get("id", ""))
		if not by_id.has(id):
			by_id[id] = {"title": str(r.get("title", "")), "cat": str(r.get("cat", "")), "res": []}
			order.append(id)
		var res := str(r.get("res", ""))
		if res != "" and not (res in by_id[id]["res"]):
			by_id[id]["res"].append(res)
	var out := []
	for id in order:
		out.append(by_id[id])
	return out
