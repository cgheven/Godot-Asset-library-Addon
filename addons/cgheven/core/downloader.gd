@tool
extends Node
class_name CghDownloader
## Threaded file download with polled progress (Godot has no progress signal).
## Emits progress every frame while a download is in flight.

signal progress(pct: float, downloaded: int, total: int)
signal finished(path: String)
signal failed(message: String)

var _http: HTTPRequest
var _active := false
var _dest := ""
var _last_got := 0      # bytes seen last frame — to detect a dead/stalled connection
var _stall := 0.0       # seconds with zero new bytes
# Details of the LAST failure (read by the dock for error tracking right after `failed` fires).
var last_stage := ""
var last_status := 0
var last_result := 0
var last_duration_ms := 0   # of the last SUCCESSFUL download (download_performance)
var last_bytes := 0
var _t0_msec := 0
var last_body := ""     # server's error text (first 200 chars, scrubbed) for HTTP >= 400
const STALL_LIMIT := 30.0   # a hung download must not block every later one forever

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.use_threads = true
	add_child(_http)
	_http.request_completed.connect(_on_done)

func download(url: String, filename: String, headers := PackedStringArray()) -> void:
	last_body = ""
	if _active:
		last_stage = "busy"; last_status = 0; last_result = 0
		failed.emit("A download is already in progress.")
		return
	CghConfig.ensure_dirs()
	# Save into the SHARED CGHEVEN folder so AE/Blender/etc. see it too (file scanner).
	var dir := CghConfig.primary_download_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	_dest = dir.path_join(CghConfig.safe_download_name(filename))
	# Clear any orphaned/stuck request first (mirrors api_client) so a previously hung
	# download that left the node "processing" can't block this new one from starting.
	_http.cancel_request()
	_http.download_file = _dest
	var err := _http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		last_stage = "start"; last_status = 0; last_result = 0
		failed.emit("Download could not start (err %d)" % err)
		return
	_active = true
	_t0_msec = Time.get_ticks_msec()
	_last_got = 0
	_stall = 0.0
	set_process(true)

func _process(dt: float) -> void:
	if not _active:
		set_process(false)
		return
	var got := _http.get_downloaded_bytes()
	var total := _http.get_body_size()   # -1 on chunked / no Content-Length
	# Dead-connection guard: if no new bytes arrive for STALL_LIMIT seconds, give up so
	# the download queue isn't blocked forever (a hung request never fires _on_done).
	if got > _last_got:
		_last_got = got
		_stall = 0.0
	else:
		_stall += dt
		if _stall >= STALL_LIMIT:
			_http.cancel_request()
			_active = false
			set_process(false)
			last_stage = "stalled"; last_status = 0; last_result = 0
			failed.emit("Download stalled (no data for %ds) — check your connection and retry." % int(STALL_LIMIT))
			return
	if total > 0:
		progress.emit(float(got) / float(total) * 100.0, got, total)
	else:
		progress.emit(-1.0, got, -1)     # indeterminate -> spinner

func _read_head(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var head := f.get_buffer(2048)
	f.close()
	return head

func cancel() -> void:
	if _active:
		_http.cancel_request()
		_active = false
		set_process(false)

func _on_done(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
	_active = false
	set_process(false)
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		last_stage = "http" if result == HTTPRequest.RESULT_SUCCESS else "network"
		last_status = code
		last_result = result
		# download_file is set, so the error body (if any) was written INTO the file — read its head.
		if code >= 400:
			last_body = CghAnalytics.body_text(_read_head(_dest), code)
		var hint := ""
		if code == 401 or code == 403:
			hint = " — access denied (file link may be expired/invalid on the server)"
		elif code == 404:
			hint = " — file not found on the server"
		elif result != HTTPRequest.RESULT_SUCCESS:
			hint = " — network/connection issue"
		failed.emit("Download failed for %s%s [result %d, HTTP %d]" % [_dest.get_file(), hint, result, code])
		return
	last_duration_ms = Time.get_ticks_msec() - _t0_msec
	last_bytes = 0
	var sf := FileAccess.open(_dest, FileAccess.READ)
	if sf != null:
		last_bytes = int(sf.get_length())
		sf.close()
	CghDownloads.mark_saved(_dest.get_file())
	finished.emit(_dest)
