@tool
extends Node
class_name CghAnalytics
## Analytics — identical model to the AE/Blender/DaVinci/Premiere addons.
## Posts to the BACKEND (/api/analytics/track) which holds the PostHog key, so the
## addon never ships a key (the old direct-to-PostHog path was a silent no-op
## because the key shipped empty). Body shape matches the desktop addons exactly:
##   { event, license_key: <distinct_id>, addon_name, properties{...} }
## distinct_id = account email -> guest_<machine_hash> -> anonymous (never a token).

const ADDON_NAME := "godot-asset-library"
const HOST_APP := "godot"

var _email := ""
var _plan := "Free"

func identify(email: String, plan: String) -> void:
	_email = email
	_plan = plan if plan != "" else "Free"

func _distinct_id() -> String:
	if _email != "":
		return _email
	var fp := CghAuth.machine_hash()
	return ("guest_" + fp) if fp != "" else "anonymous"

func _is_premium() -> bool:
	return _plan == "Pro" or _plan == "Studio" or _plan == "Bundle"

func track(event: String, props := {}, host: Node = null) -> void:
	if not props.has("fingerprint"):   # error events log themselves in _emit_error
		note_log("event:" + event)
	var properties := {
		"addon_version": CghConfig.ADDON_VERSION,
		"host_app": HOST_APP,
		"os": OS.get_name(),
		"plan": _plan,
		"is_premium": _is_premium(),
		"is_guest": _email == "",
		"account_email": _email,
		"install_source": CghConfig.install_source(),
	}
	for k in props:
		properties[k] = props[k]
	var payload := {
		"event": event,
		"license_key": _distinct_id(),
		"addon_name": ADDON_NAME,
		"properties": properties,
	}
	# Fire-and-forget on a one-off request node so bursts (session_started +
	# addon_opened on boot) never drop and the editor never blocks.
	var h := HTTPRequest.new()
	h.timeout = 5.0
	# `host` lets session_ended() parent the request to something that outlives the dock.
	var parent_node: Node = host if host != null else self
	parent_node.add_child(h)
	h.request_completed.connect(func(_a, _b, _c, _d): h.queue_free())
	var err := h.request(CghConfig.analytics_track_url(),
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		h.queue_free()


# ===========================================================================
# ERROR TRACKING
# ---------------------------------------------------------------------------
# One schema for every addon (same event + property names as Maya/AE/Premiere):
#   addon_error | addon_open_failed | api_error | login_failed | update_failed |
#   session_ended, plus download_failed / import_failed enriched with
#   where/stage/error_kind/message/fingerprint/...
#
# GDScript has NO try/catch and engine errors / push_error() output cannot be
# intercepted, so this hooks the failure RETURN paths instead (HTTPRequest
# result != OK, HTTP code >= 400, failed import branches, ...). Everything here
# is static so any script can call CghAnalytics.api_error(...) without a node
# reference. Fire-and-forget: a failure to report is silently dropped.
#
# Rules: same fingerprint at most once per 60 s (suppressed repeats are counted
# into repeats_suppressed), hard cap of 40 error events per session, and all
# free text is scrubbed (home paths, user names, tokens, emails, license keys).
# ===========================================================================
const ERR_MAX_PER_SESSION := 40
const ERR_DEDUPE_MSEC := 60000

static var _inst: CghAnalytics = null
static var _err_seen := {}            # fingerprint -> [first_msec, suppressed_count]
static var _err_total := 0            # events actually allowed through (cap)
static var _err_count := 0            # events actually sent (session_error_count)
static var _last_action := ""
static var _session_t0_msec := 0
static var _session_sent := false
static var _log := PackedStringArray()   # ring buffer of breadcrumbs (max LOG_MAX) -> recent_log
const LOG_MAX := 20
const LOG_EVENTS := ["addon_error", "addon_open_failed", "import_failed", "download_failed"]

func _init() -> void:
	_inst = self
	if _session_t0_msec == 0:
		_session_t0_msec = Time.get_ticks_msec()

# NOTE: _inst is deliberately NOT cleared on _exit_tree: the plugin's own _exit_tree may run
# after this node left the tree and must still be able to send session_ended. A freed node is
# handled by is_instance_valid().

## Cheap breadcrumb ("search", "download", "import"...) so the next error says
## what the user was doing.
static func note_action(action_name: String) -> void:
	_last_action = action_name.substr(0, 40)
	note_log("action:" + _last_action)

## Ring buffer of recent addon activity. GDScript cannot intercept print()/push_warning(), and the
## addon has no central log helper, so this is fed with breadcrumbs: note_action(), every track()
## event and every error event ("event:<name>" / "err:<event> <stage> <message>").
static func note_log(line: String) -> void:
	_log.append(line.substr(0, 400))
	while _log.size() > LOG_MAX:
		_log.remove_at(0)

## Last 10 lines, each scrubbed <=160 chars, newline-joined, total <=1200 (newest kept).
static func recent_log() -> String:
	var out := PackedStringArray()
	var total := 0
	var i := _log.size() - 1
	var taken := 0
	while i >= 0 and taken < 10:
		var l := scrub(_log[i], 160)
		var add := l.length() + (1 if out.size() > 0 else 0)
		if total + add > 1200:
			break
		total += add
		out.insert(0, l)
		taken += 1
		i -= 1
	return "\n".join(out)

## The server's own error text from a response body (only for HTTP >= 400): {"error":{"message":..}}
## or {"message":..} -> that string, else the raw text. Reads at most 2KB, scrubbed, <=200 chars.
static func body_text(body: PackedByteArray, code: int) -> String:
	if code < 400 or body.is_empty():
		return ""
	var t := body.slice(0, 2048).get_string_from_utf8().strip_edges()
	if t.begins_with("{"):
		var parsed = JSON.parse_string(t)
		if typeof(parsed) == TYPE_DICTIONARY:
			var m := ""
			var err_v = parsed.get("error", null)
			if typeof(err_v) == TYPE_DICTIONARY:
				m = str(err_v.get("message", ""))
			elif typeof(err_v) == TYPE_STRING:
				m = str(err_v)
			if m == "":
				m = str(parsed.get("message", parsed.get("detail", "")))
			if m != "":
				t = m
	return scrub(t, 200)

static func _sub(text: String, pattern: String, repl: String) -> String:
	var re := RegEx.new()
	if re.compile(pattern) != OK:
		return text
	return re.sub(text, repl, true)

## Strip user names / home paths / tokens / emails / license keys, then truncate.
static func scrub(text: String, limit := 300) -> String:
	var t := text
	for env in ["USERPROFILE", "HOME"]:
		var home: String = OS.get_environment(env)
		if home.length() > 3:
			t = t.replace(home, "~").replace(home.replace("\\", "/"), "~")
	t = _sub(t, r"(?i)([A-Za-z]:)?[\\/](Users|home)[\\/][^\\/\x22':*?<>|]+", "~")
	t = _sub(t, r"(?i)(bearer\s+|token=|key=|api_key=|password=)[^\s&\x22']+", "$1***")
	t = _sub(t, r"(?i)(\x22(?:session_token|access_token|token|jwt|password|api_key|license_key|key)\x22\s*:\s*\x22)[^\x22]*\x22", "$1***\"")
	t = _sub(t, r"CGHV-[A-Z0-9]{8}-[A-Z0-9]{8}-[A-Z0-9]{8}", "CGHV-***")
	t = _sub(t, r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}", "***@***")
	return t.substr(0, limit)

## Bucket an error into a small filterable set. `result` is the HTTPRequest.Result
## code (0 = success / not applicable).
static func classify_error(status := 0, message := "", result := 0) -> String:
	if status == 401:
		return "unauthorized"
	if status == 402:
		return "payment_required"
	if status == 403:
		return "forbidden"
	if status == 404:
		return "not_found"
	if status == 429:
		return "rate_limited"
	if status >= 500 and status < 600:
		return "server_error"
	if status >= 400 and status < 500:
		return "client_error"
	if result != 0:
		match result:
			2, 4, 6, 9:   # CANT_CONNECT, CONNECTION_ERROR, NO_RESPONSE, REQUEST_FAILED
				return "network"
			3:            # CANT_RESOLVE
				return "dns"
			5:            # TLS_HANDSHAKE_ERROR
				return "ssl"
			7, 8:         # BODY_SIZE_LIMIT_EXCEEDED, BODY_DECOMPRESS_FAILED
				return "bad_response"
			10:           # DOWNLOAD_FILE_CANT_OPEN
				return "permission"
			11:           # DOWNLOAD_FILE_WRITE_ERROR
				return "disk_full"
			13:           # TIMEOUT
				return "timeout"
	var m := message.to_lower()
	if m.contains("timed out") or m.contains("timeout") or m.contains("stalled"):
		return "timeout"
	if m.contains("ssl") or m.contains("certificate") or m.contains("tls"):
		return "ssl"
	if m.contains("getaddrinfo") or m.contains("name or service") or m.contains("dns"):
		return "dns"
	if m.contains("refused") or m.contains("unreachable") or m.contains("network"):
		return "network"
	if m.contains("permission") or m.contains("access is denied") or m.contains("read-only"):
		return "permission"
	if m.contains("no space") or m.contains("disk full"):
		return "disk_full"
	if m.contains("bad json") or m.contains("decode") or m.contains("bad update response"):
		return "bad_response"
	return "other" if m != "" else "unknown"

## Stable hash of where|error_type|digits-normalised message (same algorithm as
## the Python / JS addons; Godot's hash() is not stable so it is hand-rolled).
static func fingerprint(where: String, error_type: String, message: String) -> String:
	var norm := _sub(message, r"\d+", "#")
	var base := "%s|%s|%s" % [where, error_type, norm.substr(0, 80)]
	var h := 0
	for i in base.length():
		h = (h * 31 + base.unicode_at(i)) % 10000000019
	return str(h)

## Rate-limit + dedupe. Returns [allowed: bool, repeats_suppressed_so_far: int].
static func _err_allowed(fp: String) -> Array:
	if _err_total >= ERR_MAX_PER_SESSION:
		return [false, 0]
	var now := Time.get_ticks_msec()
	if _err_seen.has(fp):
		var prev: Array = _err_seen[fp]
		if now - int(prev[0]) < ERR_DEDUPE_MSEC:
			prev[1] = int(prev[1]) + 1
			_err_seen[fp] = prev
			return [false, int(prev[1])]
		var repeats := int(prev[1])
		_err_seen[fp] = [now, 0]
		_err_total += 1
		return [true, repeats]
	_err_seen[fp] = [now, 0]
	_err_total += 1
	return [true, 0]

## Call-site stack (only populated in debug/editor builds, which is where this
## addon runs). Skips this file's own frames.
static func _stack_text() -> String:
	var lines := PackedStringArray()
	for fr in get_stack():
		var src := str(fr.get("source", ""))
		if src.ends_with("analytics.gd"):
			continue
		lines.append("%s:%d %s" % [src.get_file(), int(fr.get("line", 0)), str(fr.get("function", ""))])
		if lines.size() >= 8:
			break
	return scrub("\n".join(lines), 1500)

static func _error_props(where: String, stage: String, message: String, status := 0, result := 0, fatal := false, error_type := "", extra := {}) -> Dictionary:
	var msg := scrub(message, 300)
	var props := {
		"where": where if where != "" else "unknown",
		"stage": stage,
		"error_type": error_type,
		"error_kind": classify_error(status, msg, result),
		"message": msg,
		"fatal": fatal,
		"last_action": _last_action,
		"session_age_s": int((Time.get_ticks_msec() - _session_t0_msec) / 1000.0),
		"session_error_count": _err_count,
	}
	if status != 0:
		props["http_status"] = status
	if result != 0:
		props["http_result"] = result
	var st := _stack_text()
	if st != "":
		props["stack"] = st
	for k in extra:
		props[k] = extra[k]
	props["fingerprint"] = fingerprint(str(props["where"]), error_type, msg)
	return props

static func _emit_error(event: String, props: Dictionary) -> void:
	var a := _err_allowed(str(props["fingerprint"]))
	if not bool(a[0]):
		return
	if int(a[1]) > 0:
		props["repeats_suppressed"] = int(a[1])
	if event in LOG_EVENTS:
		var rl := recent_log()
		if rl != "":
			props["recent_log"] = rl
	note_log("err:%s %s %s" % [event, str(props.get("stage", "")), str(props.get("message", "")).substr(0, 60)])
	_err_count += 1
	if is_instance_valid(_inst):
		_inst.track(event, props)

## Path only, ids replaced with :id (never the host, query string or tokens).
static func _endpoint(url: String) -> String:
	var ep := url.get_slice("?", 0)
	ep = _sub(ep, r"^https?://[^/]+", "")
	ep = _sub(ep, r"/[0-9a-fA-F-]{8,}", "/:id")
	ep = _sub(ep, r"/\d+(?=/|$)", "/:id")
	return ep.substr(0, 120)

## Catch-all. Call from any failure branch worth knowing about.
static func addon_error(where: String, message: String, stage := "", fatal := false, extra := {}) -> void:
	_emit_error("addon_error", _error_props(where, stage, message, 0, 0, fatal, "", extra))

## The addon failed while starting up / opening its panel.
static func addon_open_failed(stage: String, message := "") -> void:
	_emit_error("addon_open_failed", _error_props("open", stage, message, 0, 0, true))

## A backend / CDN request failed. `url` may be a full URL (reduced to the path).
## status = HTTP code (0 if none), result = HTTPRequest.Result (0 = n/a).
static func api_error(url: String, status := 0, message := "", result := 0, response_body := "") -> void:
	var ep := _endpoint(url)
	var ex := {"endpoint": ep}
	if response_body != "":
		ex["response_body"] = scrub(response_body, 200)
	var p := _error_props("api", ep, message, status, result, false, "HTTPRequest", ex)
	p["fingerprint"] = fingerprint("api", ep, "%d|%s" % [status, str(p["error_kind"])])
	_emit_error("api_error", p)

static func login_failed(reason := "", status := 0, method := "account", response_body := "") -> void:
	var ex := {"method": method}
	if response_body != "":
		ex["response_body"] = scrub(response_body, 200)   # e.g. the server's "device limit reached"
	_emit_error("login_failed", _error_props("login", method, reason, status, 0, false, "", ex))

static func update_failed(stage := "", reason := "", from_version := "", to_version := "") -> void:
	_emit_error("update_failed", _error_props("update", stage, reason, 0, 0, false, "",
		{"from_version": from_version, "to_version": to_version}))

## `extra` carries the usual asset properties (asset_id, asset_name, category...).
static func download_failed(stage: String, reason: String, status := 0, result := 0, extra := {}, response_body := "") -> void:
	var ex := extra.duplicate()
	ex["reason"] = scrub(reason, 300)
	if response_body != "":
		ex["response_body"] = scrub(response_body, 200)
	_emit_error("download_failed", _error_props("download", stage, reason, status, result, false, "", ex))

static func import_failed(stage: String, reason: String, extra := {}) -> void:
	var ex := extra.duplicate()
	ex["reason"] = scrub(reason, 300)
	_emit_error("import_failed", _error_props("import", stage, reason, 0, 0, false, "", ex))

## Send once on shutdown (plugin _exit_tree): session length + how many errors.
## The request is parented to the editor base control (not the dock that is
## about to be freed) so it has a chance to go out; best-effort.
static func session_ended() -> void:
	if _session_sent or not is_instance_valid(_inst):
		return
	_session_sent = true
	var parent: Node = null
	if Engine.is_editor_hint():
		parent = EditorInterface.get_base_control()
	_inst.track("session_ended", {
		"duration_seconds": int((Time.get_ticks_msec() - _session_t0_msec) / 1000.0),
		"error_count": _err_count,
	}, parent)

# ---------------------------------------------------------------------------
# Non-error performance / usage events (same names + props as Maya/Blender). These go straight
# through track(), NOT through the error dedupe/cap.
# ---------------------------------------------------------------------------
const PERF_MIN_GAP_MSEC := 30000   # at most 1 api_call_performance per endpoint per 30 s
const PERF_MAX := 60               # hard cap per session
static var _perf_last := {}        # endpoint -> last sent ticks (msec)
static var _perf_total := 0

## One backend request finished (success OR failure). `url` may be a full URL (reduced to path).
static func api_call_performance(url: String, duration_ms: int, success: bool, status := 0) -> void:
	if _perf_total >= PERF_MAX or not is_instance_valid(_inst):
		return
	var ep := _endpoint(url)
	var now := Time.get_ticks_msec()
	if _perf_last.has(ep) and now - int(_perf_last[ep]) < PERF_MIN_GAP_MSEC:
		return
	_perf_last[ep] = now
	_perf_total += 1
	_inst.track("api_call_performance", {
		"endpoint": ep,
		"duration_ms": duration_ms,
		"success": success,
		"http_status": status,
	})

## An asset-list request finished successfully. (Key `results_count` matches Maya.)
static func asset_load_performance(count: int, duration_ms: int, category := "") -> void:
	if is_instance_valid(_inst):
		_inst.track("asset_load_performance", {
			"results_count": count,
			"duration_ms": duration_ms,
			"category": category,
		})

## A download finished successfully. `asset_props` = the usual asset_id/asset_name/category/sub_category.
static func download_performance(asset_props: Dictionary, duration_ms: int, size_bytes: int, fmt := "", res := "") -> void:
	if not is_instance_valid(_inst):
		return
	var p := asset_props.duplicate()
	p["duration_ms"] = duration_ms
	p["bytes"] = size_bytes
	p["format"] = fmt
	p["resolution"] = res
	if duration_ms > 0 and size_bytes > 0:
		p["avg_speed_kbps"] = int(float(size_bytes) * 8.0 / 1000.0 / (float(duration_ms) / 1000.0))
	_inst.track("download_performance", p)

## Blender parity. NOTE: Godot has no "import all / import multiple" UI action yet, so nothing calls this.
static func batch_import(count: int) -> void:
	if is_instance_valid(_inst):
		_inst.track("batch_import", {"count": count})
