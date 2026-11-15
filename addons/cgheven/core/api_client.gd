@tool
extends Node
class_name CghApiClient
## Thin wrapper over HTTPRequest for the Strapi proxy endpoints.
## Must live in the editor tree (added as a child of the dock) or HTTPRequest
## returns ERR_UNCONFIGURED.

signal assets_loaded(assets: Array, meta: Dictionary)
signal categories_loaded(cats: Array)
signal request_failed(message: String)
signal auth_rejected(code: int, message: String)   # 401/402/403 while logged in -> session is dead

var _http: HTTPRequest
var _cat_http: HTTPRequest
var _session_token := ""
var _last_url := ""      # last asset-list URL (for error tracking: path only is ever reported)
var _cat_url := ""
var _t0 := 0              # ticks when the asset-list request started (api_call_performance)
var _cat_t0 := 0
var _last_cat := ""

func _ready() -> void:
	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.timeout = 20.0          # never hang forever (a stuck request blocks all later ones -> ERR_BUSY 44)
	add_child(_http)
	_http.request_completed.connect(_on_completed)
	# Separate request node for the category tree so it never cancels an asset fetch.
	_cat_http = HTTPRequest.new()
	_cat_http.use_threads = true
	_cat_http.timeout = 20.0
	add_child(_cat_http)
	_cat_http.request_completed.connect(_on_cat_completed)

func set_session_token(tok: String) -> void:
	_session_token = tok

func _headers() -> PackedStringArray:
	var h := PackedStringArray(["Content-Type: application/json"])
	if _session_token != "":
		h.append("Authorization: Bearer " + _session_token)
	return h

## page is 1-based. category_slug "" = all. subcat is a SUBcategory slug (e.g. "props")
## which lives on the asset's `subcategories[]` relation, NOT `categorie` — so it needs
## a different Strapi filter. sort = Strapi sort param.
func fetch_assets(page: int, page_size: int, category_slug: String, search: String, sort := "createdAt:desc", subcat := "", slugs: Array = []) -> void:
	var base := CghConfig.authed_assets_url() if _session_token != "" else CghConfig.public_assets_url()
	var q := "?addonSlug=%s&pagination[page]=%d&pagination[pageSize]=%d&populate=*" % [
		CghConfig.ADDON_SLUG, page, page_size]
	if sort != "":
		q += "&sort=" + sort.uri_encode()
	# Which categories to match (each one against BOTH the top-level category and the subcategories
	# relation, so an asset filed directly under a subcategory is still found):
	#   - a chosen subcategory wins;
	#   - else the tab's slug list = the tab itself PLUS its subcategories (many assets are filed
	#     straight under a subcategory such as "explosions-vfx", so the parent slug alone misses them);
	#   - else the single tab slug;
	#   - "All" (nothing selected) sends NO category filter. It used to be a hard-coded whitelist of 3
	#     categories, which hid ~80% of the library (Explosions, Smoke, VFX, VDBs ...).
	var sels: Array = []
	if subcat != "":
		sels = [subcat]
	elif not slugs.is_empty():
		sels = slugs.slice(0, 20)      # keep the $in list short (the query-string parser caps arrays at 20)
	elif category_slug != "":
		sels = [category_slug]
	var oi := 0
	var slug_list: Array = []
	var name_list: Array = []
	for sel in sels:
		var val := str(sel)
		if val.begins_with("name:"):    # a category whose Slug is blank in the CMS: match it by Name instead
			name_list.append(val.substr(5))
		else:
			slug_list.append(val)
	# ONE $in list per relation instead of one $or clause per slug (a long $or list makes the server answer HTTP 500).
	if not slug_list.is_empty():
		for rel in ["categorie", "subcategories"]:
			for i in slug_list.size():
				q += "&filters[$or][%d][%s][Slug][$in][%d]=%s" % [oi, rel, i, str(slug_list[i]).uri_encode()]
			oi += 1
	for nm in name_list:
		q += "&filters[$or][%d][categorie][Name][$eq]=%s" % [oi, str(nm).uri_encode()]; oi += 1
		q += "&filters[$or][%d][subcategories][Name][$eq]=%s" % [oi, str(nm).uri_encode()]; oi += 1
	# Some flipbooks are filed under VFX in the CMS (all of them have "Flipbook" in the title). Without this
	# the Flipbooks tab and All would miss them, and the VFX category itself is video that Godot can't play.
	if subcat == "" and slug_list.has("flipbooks"):
		q += "&filters[$or][%d][Title][$containsi]=flipbook" % oi
		oi += 1
	if search.strip_edges() != "":
		q += "&filters[Title][$containsi]=" + search.strip_edges().uri_encode()
	# Drop any stale/in-flight request first, otherwise a previous (slow) request
	# leaves the node busy and this one fails with ERR_BUSY (44).
	_http.cancel_request()
	_last_url = base
	_t0 = Time.get_ticks_msec()
	_last_cat = subcat if subcat != "" else category_slug
	var err := _http.request(base + q, _headers(), HTTPClient.METHOD_GET)
	if err != OK:
		CghAnalytics.api_error(base, 0, "Request could not start (err %d)" % err)
		request_failed.emit("Request could not start (err %d)" % err)

func _on_completed(result: int, code: int, _headers_in: PackedStringArray, body: PackedByteArray) -> void:
	CghAnalytics.api_call_performance(_last_url, Time.get_ticks_msec() - _t0, result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300, code)
	if result == HTTPRequest.RESULT_SUCCESS and (code == 401 or code == 402 or code == 403) and _session_token != "":
		# Dead / rejected session: do NOT show a red "HTTP 401" and keep a fake Pro state. Let the
		# dock sign the user out and reload as a guest.
		CghAnalytics.api_error(_last_url, code, "Session rejected by server (HTTP %d)" % code, 0, CghAnalytics.body_text(body, code))
		auth_rejected.emit(code, CghAnalytics.body_text(body, code))
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		CghAnalytics.api_error(_last_url, 0, "Network error (result %d)" % result, result)
		request_failed.emit("Network error (result %d)" % result)
		return
	if code < 200 or code >= 300:
		CghAnalytics.api_error(_last_url, code, "Server returned HTTP %d" % code, 0, CghAnalytics.body_text(body, code))
		request_failed.emit("Server returned HTTP %d" % code)
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		CghAnalytics.api_error(_last_url, code, "Bad JSON from server")
		request_failed.emit("Bad JSON from server")
		return
	var data = parsed.get("data", [])
	var meta = parsed.get("meta", {})
	var loaded_n: int = data.size() if data is Array else 0
	CghAnalytics.asset_load_performance(loaded_n, Time.get_ticks_msec() - _t0, _last_cat)
	assets_loaded.emit(data if data is Array else [], meta if meta is Dictionary else {})

## Fetch the category tree so the UI can build an accurate subcategory dropdown from the
## live backend (like the Blender addon), not a hardcoded list. Non-fatal on failure.
func fetch_categories() -> void:
	var base := CghConfig.authed_categories_url() if _session_token != "" else CghConfig.public_categories_url()
	var q := "?addonSlug=%s&pagination[pageSize]=200&populate=*" % CghConfig.ADDON_SLUG
	_cat_http.cancel_request()
	_cat_url = base
	_cat_t0 = Time.get_ticks_msec()
	var err := _cat_http.request(base + q, _headers(), HTTPClient.METHOD_GET)
	if err != OK:
		CghAnalytics.api_error(base, 0, "Category request could not start (err %d)" % err)
		return   # keep the hardcoded subcategory fallback

func _on_cat_completed(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	CghAnalytics.api_call_performance(_cat_url, Time.get_ticks_msec() - _cat_t0, result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300, code)
	if result == HTTPRequest.RESULT_SUCCESS and (code == 401 or code == 402 or code == 403) and _session_token != "":
		auth_rejected.emit(code, CghAnalytics.body_text(body, code))
		return
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		CghAnalytics.api_error(_cat_url, code, "Category request failed (result %d, HTTP %d)" % [result, code], result, CghAnalytics.body_text(body, code))
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		CghAnalytics.api_error(_cat_url, code, "Bad JSON from category endpoint")
		return
	var data = parsed.get("data", [])
	categories_loaded.emit(data if data is Array else [])
