@tool
extends Node
class_name CghAuth
## Web-broker login (BlenderKit-style), mirroring the Blender addon:
##  1. open system browser -> cgheven.com/addon-login
##  2. run a loopback server, catch the handoff ?code=
##  3. exchange the code with the backend for a session token (JWT)
## Godot has NO HTTP server, only raw TCP, so we hand-parse the request line
## and hand-write the HTTP response. Also supports license-key + machine_hash.

signal logged_in(plan: String)
signal login_failed(message: String)
signal plan_refreshed(plan: String)

var session_token := ""
var plan := "Free"
var email := ""
var expires_at := ""   # ISO date the plan/session expires (shown in the Account popup)

var _server: TCPServer
var _port := 0
var _state := ""
var _peer: StreamPeerTCP = null   # active loopback connection (read across ticks)
var _req := ""                    # accumulated HTTP request bytes
var _wait_frames := 0             # poll ticks spent waiting for the request line
var _poll_timer: Timer = null     # polls the loopback server (Timers fire reliably in the editor; _process may not)
var _exchange_http: HTTPRequest
var _heartbeat_http: HTTPRequest

func _ready() -> void:
	_exchange_http = HTTPRequest.new(); add_child(_exchange_http)
	_exchange_http.request_completed.connect(_on_exchange_done)
	_heartbeat_http = HTTPRequest.new(); add_child(_heartbeat_http)
	_heartbeat_http.request_completed.connect(_on_heartbeat_done)
	_load_session()

# -------- persisted session (EditorSettings, per-user, cross-project) --------
func _load_session() -> void:
	var es := EditorInterface.get_editor_settings()
	if es.has_setting("cgheven/session_token"):
		session_token = es.get_setting("cgheven/session_token")
		plan = es.get_setting("cgheven/plan") if es.has_setting("cgheven/plan") else "Free"
		email = es.get_setting("cgheven/email") if es.has_setting("cgheven/email") else ""
		expires_at = es.get_setting("cgheven/expires_at") if es.has_setting("cgheven/expires_at") else ""

func _save_session() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_setting("cgheven/session_token", session_token)
	es.set_setting("cgheven/plan", plan)
	es.set_setting("cgheven/email", email)
	es.set_setting("cgheven/expires_at", expires_at)

func is_logged_in() -> bool:
	return session_token != ""

func is_premium() -> bool:
	return plan == "Pro" or plan == "Studio" or plan == "Bundle"

func logout() -> void:
	session_token = ""
	plan = "Free"
	email = ""
	expires_at = ""
	_save_session()

# -------------------------- web-broker login --------------------------
func start_login(register := false) -> void:
	_server = TCPServer.new()
	_port = 0
	for p in CghConfig.LOOPBACK_PORTS:
		if _server.listen(p, "127.0.0.1") == OK:
			_port = p
			break
	if _port == 0:
		login_failed.emit("Could not open a local login port. Close other addons and retry.")
		return
	# Build the SAME broker URL the Blender/AE addons use, so the website handles it
	# identically: /addon-login?redirect=<loopback>&state=&addon=godot&machine=&label=
	_state = "%08x%08x" % [randi(), randi()]
	var redirect := CghConfig.loopback_redirect(_port)
	var label := _device_label()
	var url := "%s?redirect=%s&state=%s&addon=%s&machine=%s&label=%s" % [
		CghConfig.login_base_url(),
		redirect.uri_encode(), _state, CghConfig.ADDON_SLUG,
		machine_hash().uri_encode(), label.uri_encode()]
	if register:
		url += "&screen=register"
	OS.shell_open(url)
	_start_poll()       # poll the loopback server on a Timer (reliable in the editor)

func _start_poll() -> void:
	if _poll_timer == null:
		_poll_timer = Timer.new()
		_poll_timer.wait_time = 0.1
		_poll_timer.one_shot = false
		add_child(_poll_timer)
		_poll_timer.timeout.connect(_poll_login)
	_peer = null
	_req = ""
	_wait_frames = 0
	_poll_timer.start()

func _stop_poll() -> void:
	if _poll_timer != null:
		_poll_timer.stop()

func _device_label() -> String:
	var host := OS.get_environment("COMPUTERNAME")   # Windows
	if host == "":
		host = OS.get_environment("HOSTNAME")        # macOS / Linux
	if host == "":
		host = "Godot"
	return "%s (%s)" % [host, OS.get_name()]

func _poll_login() -> void:
	if _server == null or not _server.is_listening():
		_stop_poll()
		return
	# 1) Accept one pending connection, then read it over the NEXT ticks. A single
	#    tight in-tick loop races the OS: the browser's request bytes usually haven't
	#    arrived yet, so we'd read nothing and report "no code". Spreading the read
	#    across ticks lets the bytes actually arrive.
	if _peer == null:
		if not _server.is_connection_available():
			return
		_peer = _server.take_connection()
		_req = ""
		_wait_frames = 0
		return
	# 2) Pump the active connection until we have the request line (GET /...?code=...).
	_peer.poll()
	var st := _peer.get_status()
	if st == StreamPeerTCP.STATUS_CONNECTING:
		return
	if st != StreamPeerTCP.STATUS_CONNECTED:
		_finish_peer("")                 # closed before sending the request
		return
	var avail := _peer.get_available_bytes()
	if avail > 0:
		_req += _peer.get_utf8_string(avail)
	_wait_frames += 1
	if _req.find("\r\n") != -1:
		_finish_peer(_extract_query_param(_req, "code"))
	elif _wait_frames > 300:             # ~30s safety timeout at 0.1s/tick
		_finish_peer("")

# Write the browser's "you can close this tab" page, tear down the server, and
# (if we got one) redeem the handoff code.
func _finish_peer(code: String) -> void:
	if _peer != null:
		# Redirect the browser to the branded cgheven.com/addon-login/done page — exactly
		# like the Blender/AE/Premiere addons — so the user lands on our site, NOT a
		# localhost page. The loopback is just the secure handoff; it's never the landing.
		var status := "ok" if code != "" else "error"
		var dest := "%s/addon-login/done?addon=%s&status=%s" % [
			CghConfig.web_base(), CghConfig.ADDON_SLUG, status]
		var resp := "HTTP/1.1 302 Found\r\nLocation: %s\r\nConnection: close\r\nContent-Length: 0\r\n\r\n" % dest
		_peer.put_data(resp.to_utf8_buffer())
		_peer.poll()
		_peer.disconnect_from_host()
		_peer = null
	if _server != null:
		_server.stop()
	_stop_poll()
	if code == "":
		login_failed.emit("No login code received. Please try logging in again.")
		return
	_exchange_code(code)

func _extract_query_param(req: String, key: String) -> String:
	# req first line looks like: GET /callback?code=ABC&... HTTP/1.1
	var line := req.split("\r\n")[0]
	var qpos := line.find("?")
	if qpos == -1:
		return ""
	var path := line.substr(qpos + 1)
	path = path.split(" ")[0]   # strip trailing " HTTP/1.1"
	for pair in path.split("&"):
		var kv := pair.split("=")
		if kv.size() == 2 and kv[0] == key:
			return kv[1].uri_decode()
	return ""

func _exchange_code(code: String) -> void:
	# Redeem the handoff code for the session payload (same as Blender/AE).
	var body := JSON.stringify({"code": code})
	_exchange_http.request(CghConfig.addon_exchange_url(),
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST, body)

func _on_exchange_done(_r: int, code_status: int, _h: PackedStringArray, b: PackedByteArray) -> void:
	if code_status < 200 or code_status >= 300:
		login_failed.emit("Login exchange failed (HTTP %d)" % code_status)
		return
	var d = JSON.parse_string(b.get_string_from_utf8())
	if typeof(d) != TYPE_DICTIONARY or not d.has("session_token"):
		login_failed.emit("Login exchange returned no token.")
		return
	session_token = d["session_token"]
	plan = _plan_name_from(d)
	email = str(d.get("email", ""))
	expires_at = str(d.get("expires_at", ""))
	_save_session()
	logged_in.emit(plan)

# The broker's `plan` field is the BILLING CYCLE ("Yearly"/"Monthly"), not the plan
# name — the real name is in `plan_label` ("Studio (Yearly)"). Derive a clean name
# so is_premium()/gating/analytics recognise paid users.
func _plan_name_from(d: Dictionary) -> String:
	var hay := (str(d.get("plan_label", "")) + " " + str(d.get("plan", ""))).to_lower()
	if hay.contains("studio"):
		return "Studio"
	if hay.contains("pro"):
		return "Pro"
	if hay.contains("bundle"):
		return "Bundle"
	if bool(d.get("is_premium", false)):
		return "Pro"
	return "Free"

# -------------------------- license-key activation --------------------------
func activate_key(key: String) -> void:
	var body := JSON.stringify({
		"license_key": key,
		"machine_hash": machine_hash(),
		"source": "godot",
	})
	# reuse the exchange HTTPRequest; same _on_exchange_done handler shape
	_exchange_http.request(CghConfig.addon_activate_url(),
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST, body)

# -------------------------- heartbeat (live plan refresh) --------------------------
func heartbeat() -> void:
	if session_token == "":
		return
	_heartbeat_http.request(CghConfig.heartbeat_url(),
		PackedStringArray(["Authorization: Bearer " + session_token]),
		HTTPClient.METHOD_GET)

func _on_heartbeat_done(_r: int, code_status: int, _h: PackedStringArray, b: PackedByteArray) -> void:
	if code_status < 200 or code_status >= 300:
		return
	var d = JSON.parse_string(b.get_string_from_utf8())
	if typeof(d) == TYPE_DICTIONARY and d.has("plan"):
		var new_plan := _plan_name_from(d)
		if new_plan != plan:
			plan = new_plan
			_save_session()
			plan_refreshed.emit(plan)

# -------------------------- machine fingerprint (license-key path) --------------------------
static func machine_hash() -> String:
	# NOTE (risk): must match the Blender addon fingerprint or existing keys won't validate.
	return (OS.get_unique_id() + "|" + OS.get_name()).sha256_text()
