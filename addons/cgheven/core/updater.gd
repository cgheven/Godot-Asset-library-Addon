@tool
extends Node
class_name CghUpdater
## Checks the public update endpoint; if a newer semver exists, downloads the
## addon zip and extracts it over res://addons/cgheven, then asks for an editor
## restart (Godot has no silent plugin hot-reload).

signal update_available(version: String, notes: String, url: String)
signal up_to_date()
signal update_ready_to_restart()
signal update_failed(message: String)

var _check_http: HTTPRequest
var _dl: CghDownloader

func _ready() -> void:
	_check_http = HTTPRequest.new(); add_child(_check_http)
	_check_http.request_completed.connect(_on_check)
	_dl = CghDownloader.new(); add_child(_dl)
	_dl.finished.connect(_on_zip_downloaded)
	_dl.failed.connect(func(m): update_failed.emit(m))

func check() -> void:
	# Backend contract: POST /api/addon-updates/check with body {addon_slug,
	# current_version}; public, no auth (matches autoupdate-public-popup). Response:
	# {update_available, latest_version, changelog, download_url}.
	var body := JSON.stringify({
		"addon_slug": CghConfig.ADDON_SLUG,
		"current_version": CghConfig.ADDON_VERSION,
	})
	_check_http.request(CghConfig.check_update_url(),
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST, body)

func _on_check(_r: int, code: int, _h: PackedStringArray, b: PackedByteArray) -> void:
	if code < 200 or code >= 300:
		update_failed.emit("Update check failed (HTTP %d)" % code)
		return
	var d = JSON.parse_string(b.get_string_from_utf8())
	if typeof(d) != TYPE_DICTIONARY:
		update_failed.emit("Bad update response")
		return
	if d.get("update_available", false):
		var ver := str(d.get("latest_version", "?"))
		var notes_v = d.get("changelog", "")
		var notes := str(notes_v) if notes_v != null else ""
		var url_v = d.get("download_url", "")
		var url := str(url_v) if url_v != null else ""
		if url == "":
			# Update exists but no ZIP uploaded to the release yet — don't prompt a
			# download that can't complete; surface only on a manual check.
			update_failed.emit("Update %s available, but no download is published yet." % ver)
			return
		update_available.emit(ver, notes, url)
	else:
		up_to_date.emit()

func download_and_stage(url: String) -> void:
	_dl.download(url, "cgheven_update.zip")

func _on_zip_downloaded(zip_path: String) -> void:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		update_failed.emit("Could not open update zip")
		return
	var base := "res://addons/cgheven/"
	for entry in reader.get_files():
		if entry.ends_with("/"):
			continue
		# entries are expected under addons/cgheven/... ; strip leading path to map onto base
		var rel := entry
		var idx := rel.find("addons/cgheven/")
		if idx != -1:
			rel = rel.substr(idx + "addons/cgheven/".length())
		var out_path := base + rel
		DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
		var f := FileAccess.open(out_path, FileAccess.WRITE)
		if f:
			f.store_buffer(reader.read_file(entry))
			f.close()
	reader.close()
	update_ready_to_restart.emit()   # caller shows "Restart editor?" dialog -> EditorInterface.restart_editor()
