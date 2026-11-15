@tool
extends EditorPlugin
## CGHEVEN Asset Library — Godot editor plugin entry point.
## Adds an After-Effects-styled dock that browses/downloads/imports CGHEVEN
## assets from api.cgheven.com, reusing the existing backend and gating.

var _dock: CghMainDock
var _api: CghApiClient
var _auth: CghAuth
var _downloader: CghDownloader
var _analytics: CghAnalytics
var _updater: CghUpdater
var _theme: Theme
var _heartbeat: Timer
var _export_filter: EditorExportPlugin

func _enter_tree() -> void:
	# Keep download baggage (video, archives, optional source copies) out of exported games.
	_export_filter = preload("res://addons/cgheven/core/export_filter.gd").new()
	add_export_plugin(_export_filter)
	_theme = CghTheme.build()

	# core services (must be in the editor tree for HTTPRequest to work)
	_api = CghApiClient.new()
	_auth = CghAuth.new()
	_downloader = CghDownloader.new()
	_analytics = CghAnalytics.new()
	_updater = CghUpdater.new()

	_dock = CghMainDock.new()
	_dock.name = "CGHEVEN"
	_dock.theme = _theme
	_dock.api = _api
	_dock.auth = _auth
	_dock.downloader = _downloader
	_dock.analytics = _analytics
	_dock.updater = _updater

	# services live under the dock so they are inside the tree
	_dock.add_child(_api)
	_dock.add_child(_auth)
	_dock.add_child(_downloader)
	_dock.add_child(_analytics)
	_dock.add_child(_updater)

	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)

	# defer boot one frame so all children are ready
	_dock.call_deferred("boot")

	# heartbeat: live plan refresh (Free -> Pro without re-login)
	_heartbeat = Timer.new()
	_heartbeat.wait_time = 120.0
	_heartbeat.autostart = true
	_heartbeat.timeout.connect(func():
		if _auth and _auth.is_logged_in():
			_auth.heartbeat())
	_dock.add_child(_heartbeat)

func _exit_tree() -> void:
	if _export_filter:
		remove_export_plugin(_export_filter)
		_export_filter = null
	CghAnalytics.session_ended()   # one best-effort event: session length + error count
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null

func _has_main_screen() -> bool:
	return false

func _get_plugin_name() -> String:
	return "CGHEVEN Asset Library"
