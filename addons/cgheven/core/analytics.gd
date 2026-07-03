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

func track(event: String, props := {}) -> void:
	var properties := {
		"addon_version": CghConfig.ADDON_VERSION,
		"host_app": HOST_APP,
		"os": OS.get_name(),
		"plan": _plan,
		"is_premium": _is_premium(),
		"is_guest": _email == "",
		"account_email": _email,
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
	add_child(h)
	h.request_completed.connect(func(_a, _b, _c, _d): h.queue_free())
	var err := h.request(CghConfig.analytics_track_url(),
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		h.queue_free()
