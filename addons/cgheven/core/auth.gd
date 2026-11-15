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
signal session_refreshed()                  # heartbeat renewed the 24h token (plan unchanged)
signal session_expired(reason: String)      # server rejected the session -> user was signed out

var session_token := ""
var plan := "Free"
var email := ""
var expires_at := ""   # ISO date the plan/session expires (shown in the Account popup)
var _xt0 := 0   # ticks: exchange/activate request start (api_call_performance)
var _hb_t0 := 0
var startup_notice := ""   # set when the saved session was already expired at launch (UI shows it once)
var _login_method := "account"   # for error tracking: "account" (web broker) or "license_key"

var _server: TCPServer
var _port := 0
var _state := ""
var _peers: Array = []            # [{peer, req, frames}] — ALL live loopback connections
var _wait_frames := 0             # global poll ticks since login started (overall timeout)
var _poll_timer: Timer = null     # polls the loopback server (Timers fire reliably in the editor; _process may not)
var _exchange_http: HTTPRequest
var _heartbeat_http: HTTPRequest

func _ready() -> void:
	_exchange_http = HTTPRequest.new(); add_child(_exchange_http)
	_exchange_http.request_completed.connect(_on_exchange_done)
	_heartbeat_http = HTTPRequest.new(); add_child(_heartbeat_http)
	_heartbeat_http.request_completed.connect(_on_heartbeat_done)
	_load_session()
	_drop_if_expired()

# -------- persisted session (EditorSettings, per-user, cross-project) --------
func _load_session() -> void:
	var es := EditorInterface.get_editor_settings()
	if es.has_setting("cgheven/session_token"):
		session_token = es.get_setting("cgheven/session_token")
		plan = es.get_setting("cgheven/plan") if es.has_setting("cgheven/plan") else "Free"
		email = es.get_setting("cgheven/email") if es.has_setting("cgheven/email") else ""
		expires_at = es.get_setting("cgheven/expires_at") if es.has_setting("cgheven/expires_at") else ""

# The session JWT lives 24h and heartbeat can only renew a LIVE token. If the saved one is
# already dead, drop it NOW; otherwise the addon would show "Pro" and then fail every request
# with 401. The user simply has to log in again (same as the Blender addon).
func _drop_if_expired() -> void:
	if session_token == "":
		return
	var token_exp := _jwt_exp(session_token)
	if token_exp > 0 and token_exp < int(Time.get_unix_time_from_system()):
		session_token = ""
		plan = "Free"
		email = ""
		expires_at = ""
		_save_session()
		startup_notice = "Your CGHEVEN login expired. Please log in again to use your Pro plan."

# Reads the `exp` (unix seconds) claim of a JWT without verifying it. 0 = unknown/unreadable.
static func _jwt_exp(token: String) -> int:
	var parts := token.split(".")
	if parts.size() != 3:
		return 0
	var seg: String = parts[1].replace("-", "+").replace("_", "/")
	while seg.length() % 4 != 0:
		seg += "="
	var d = JSON.parse_string(Marshalls.base64_to_utf8(seg))
	if typeof(d) != TYPE_DICTIONARY:
		return 0
	return int(d.get("exp", 0))

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
		CghAnalytics.login_failed("Could not open a local login port", 0, "account")
		login_failed.emit("Could not open a local login port. Close other addons and retry.")
		return
	# Build the SAME broker URL the Blender/AE addons use, so the website handles it
	# identically: /addon-login?redirect=<loopback>&state=&addon=godot&machine=&label=
	_state = Crypto.new().generate_random_bytes(16).hex_encode()   # unguessable (was randi())
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
		_poll_timer.wait_time = 0.05        # tick fast so we answer the browser's GET promptly
		_poll_timer.one_shot = false
		add_child(_poll_timer)
		_poll_timer.timeout.connect(_poll_login)
	_peers = []
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
	_wait_frames += 1
	# Accept EVERY pending connection this tick, not just one. Chrome/Edge open a speculative
	# "preconnect" socket alongside the real request; the old code latched onto ONE socket, so
	# if it grabbed the empty preconnect it blocked there while the real GET (carrying ?code=)
	# sat unanswered in the backlog — the browser then just spun on the localhost URL until a
	# 30s timeout. We now track them all and answer whichever one actually delivers the code.
	while _server.is_connection_available():
		var np := _server.take_connection()
		if np != null:
			_peers.append({"peer": np, "req": "", "frames": 0})
	var i := _peers.size() - 1
	while i >= 0:
		var slot: Dictionary = _peers[i]
		var peer: StreamPeerTCP = slot["peer"]
		peer.poll()
		var st := peer.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTING:
			slot["frames"] = int(slot["frames"]) + 1
			i -= 1
			continue
		if st != StreamPeerTCP.STATUS_CONNECTED:
			_peers.remove_at(i)            # closed/errored (usually the idle preconnect) — drop it
			i -= 1
			continue
		var avail := peer.get_available_bytes()
		if avail > 0:
			slot["req"] = str(slot["req"]) + peer.get_utf8_string(avail)
		slot["frames"] = int(slot["frames"]) + 1
		var req: String = str(slot["req"])
		if req.find("\r\n") != -1:
			var code := _extract_query_param(req, "code")
			var got_state := _extract_query_param(req, "state")
			if code != "" and got_state != "" and got_state != _state:
				# A callback that carries a different login state is not ours (forged / stale): ignore it,
				# never sign the user in with it. (A missing state is tolerated for older broker pages.)
				_answer_and_close(peer, "")
				_peers.remove_at(i)
				i -= 1
				continue
			if code != "":
				_answer_and_close(peer, code)   # 302 -> branded cgheven.com/addon-login/done page
				_peers.remove_at(i)
				_finish_login(code)
				return
			# Complete request line but no ?code= (favicon, bare hit) — send it to the error
			# page and drop it; another peer may still carry the real code.
			_answer_and_close(peer, "")
			_peers.remove_at(i)
			i -= 1
			continue
		# Idle socket that never sends a request line — retire it after ~4s. This NEVER fails
		# the login; only the global timeout below can.
		if int(slot["frames"]) > 80:
			peer.disconnect_from_host()
			_peers.remove_at(i)
		i -= 1
	if _wait_frames > 1200:                 # ~60s overall safety timeout at 0.05s/tick
		_finish_login("")

# Write the browser's 302 redirect to the branded cgheven.com/addon-login/done page — exactly
# like the Blender/AE/Premiere addons — so the user lands on our site, NOT a localhost page.
# The loopback is only the secure handoff; it's never the landing.
func _answer_and_close(peer: StreamPeerTCP, code: String) -> void:
	var status := "ok" if code != "" else "error"
	var dest := "%s/addon-login/done?addon=%s&status=%s" % [
		CghConfig.web_base(), CghConfig.ADDON_SLUG, status]
	var resp := "HTTP/1.1 302 Found\r\nLocation: %s\r\nConnection: close\r\nContent-Length: 0\r\n\r\n" % dest
	peer.put_data(resp.to_utf8_buffer())
	peer.poll()
	peer.disconnect_from_host()

# Tear down the loopback (close any stragglers + stop the server) and, if we caught a code,
# redeem it for the session token.
func _finish_login(code: String) -> void:
	for slot in _peers:
		var p: StreamPeerTCP = slot["peer"]
		if p != null:
			p.disconnect_from_host()
	_peers = []
	if _server != null:
		_server.stop()
	_stop_poll()
	if code == "":
		CghAnalytics.login_failed("No login code received", 0, "account")
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
		# Split on the FIRST '=' only — the value is a JWT/base64 handoff code that itself
		# contains '=' padding, so a plain split("=") would break into 3+ parts and drop it.
		var eq := pair.find("=")
		if eq == -1:
			continue
		if pair.substr(0, eq) == key:
			return pair.substr(eq + 1).uri_decode()
	return ""

func _exchange_code(code: String) -> void:
	_login_method = "account"
	_xt0 = Time.get_ticks_msec()
	# Redeem the handoff code for the session payload (same as Blender/AE).
	var body := JSON.stringify({"code": code})
	_exchange_http.request(CghConfig.addon_exchange_url(),
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST, body)

func _on_exchange_done(r: int, code_status: int, _h: PackedStringArray, b: PackedByteArray) -> void:
	var ep := CghConfig.addon_activate_url() if _login_method == "license_key" else CghConfig.addon_exchange_url()
	CghAnalytics.api_call_performance(ep, Time.get_ticks_msec() - _xt0, code_status >= 200 and code_status < 300, code_status)
	if code_status < 200 or code_status >= 300:
		CghAnalytics.api_error(ep, code_status, "Login exchange failed (HTTP %d, result %d)" % [code_status, r], r, CghAnalytics.body_text(b, code_status))
		CghAnalytics.login_failed("Login exchange failed (HTTP %d, result %d)" % [code_status, r], code_status, _login_method, CghAnalytics.body_text(b, code_status))
		login_failed.emit("Login exchange failed (HTTP %d)" % code_status)
		return
	var d = JSON.parse_string(b.get_string_from_utf8())
	if typeof(d) != TYPE_DICTIONARY or not d.has("session_token"):
		CghAnalytics.login_failed("Login exchange returned no token", code_status, _login_method)
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
	_login_method = "license_key"
	_xt0 = Time.get_ticks_msec()
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
	_hb_t0 = Time.get_ticks_msec()
	# POST: the backend route only exists as POST /api/addon-license/heartbeat (a GET is a 404/405).
	_heartbeat_http.request(CghConfig.heartbeat_url(),
		PackedStringArray(["Content-Type: application/json", "Authorization: Bearer " + session_token]),
		HTTPClient.METHOD_POST, JSON.stringify({"machine_hash": machine_hash()}))

func _on_heartbeat_done(r: int, code_status: int, _h: PackedStringArray, b: PackedByteArray) -> void:
	CghAnalytics.api_call_performance(CghConfig.heartbeat_url(), Time.get_ticks_msec() - _hb_t0, code_status >= 200 and code_status < 300, code_status)
	if code_status == 401 or code_status == 402 or code_status == 403:
		# The server rejected this session (expired / revoked / license used on another device).
		end_session(code_status, CghAnalytics.body_text(b, code_status))
		return
	if code_status < 200 or code_status >= 300:
		if code_status >= 400:   # server-side failures only (an offline user would otherwise eat the event cap)
			CghAnalytics.api_error(CghConfig.heartbeat_url(), code_status, "Heartbeat failed (HTTP %d, result %d)" % [code_status, r], r, CghAnalytics.body_text(b, code_status))
		return   # 5xx / offline: keep the saved session
	var d = JSON.parse_string(b.get_string_from_utf8())
	if typeof(d) != TYPE_DICTIONARY:
		return
	var dirty := false
	var token_changed := false
	# Every heartbeat answer carries a fresh 24h token. SAVE it: this is the only token renewal
	# there is, so a token we never store is a login that dies after 24 hours.
	var tok := str(d.get("session_token", ""))
	if tok != "" and tok != session_token:
		session_token = tok
		token_changed = true
		dirty = true
	var plan_changed := false
	if d.has("plan"):
		var new_plan := _plan_name_from(d)
		if new_plan != plan:
			plan = new_plan
			plan_changed = true
			dirty = true
	if d.has("expires_at"):
		var ea = d.get("expires_at")
		var new_exp := "" if ea == null else str(ea)
		if new_exp != expires_at:
			expires_at = new_exp
			dirty = true
	if dirty:
		_save_session()
	if plan_changed:
		plan_refreshed.emit(plan)
	elif token_changed:
		session_refreshed.emit()

## Called when the server rejects the saved session (heartbeat, or an asset/category request that
## answered 401/402/403). Signs the user out cleanly and tells the UI why, so the addon never sits
## there showing "Pro" while every request fails. Calling it twice is harmless (2nd call no-ops).
func end_session(code: int, server_text := "") -> void:
	if session_token == "":
		return
	var reason := "Your CGHEVEN login expired. Please log in again."
	if (code == 402 or code == 403) and server_text.strip_edges() != "":
		reason = server_text.strip_edges()   # e.g. "license is active on another device"
	CghAnalytics.login_failed(reason, code, "session_rejected", server_text)
	logout()
	session_expired.emit(reason)

# -------------------------- machine fingerprint (license-key path) --------------------------
static func machine_hash() -> String:
	# NOTE (risk): must match the Blender addon fingerprint or existing keys won't validate.
	return (OS.get_unique_id() + "|" + OS.get_name()).sha256_text()
