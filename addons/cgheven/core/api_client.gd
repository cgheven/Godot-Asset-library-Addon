@tool
extends Node
class_name CghApiClient
## Thin wrapper over HTTPRequest for the Strapi proxy endpoints.
## Must live in the editor tree (added as a child of the dock) or HTTPRequest
## returns ERR_UNCONFIGURED.

signal assets_loaded(assets: Array, meta: Dictionary)
signal categories_loaded(cats: Array)
signal request_failed(message: String)

var _http: HTTPRequest
var _cat_http: HTTPRequest
var _session_token := ""

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
func fetch_assets(page: int, page_size: int, category_slug: String, search: String, sort := "createdAt:desc", subcat := "") -> void:
	var base := CghConfig.authed_assets_url() if _session_token != "" else CghConfig.public_assets_url()
	var q := "?addonSlug=%s&pagination[page]=%d&pagination[pageSize]=%d&populate=*" % [
		CghConfig.ADDON_SLUG, page, page_size]
	if sort != "":
		q += "&sort=" + sort.uri_encode()
	# Blender-exact: one slug, matched against EITHER the top-level category OR a
	# subcategory ($or). So "props" (a 3d-models subcategory) is found correctly.
	var sel := subcat if subcat != "" else category_slug
	if sel != "":
		var es := sel.uri_encode()
		q += "&filters[$or][0][categorie][Slug][$eq]=" + es
		q += "&filters[$or][1][subcategories][Slug][$eq]=" + es
	else:
		# "All" tab — the Godot-usable categories only (3d-models / hdri / flipbooks + their
		# subcategories). Match EITHER the top-level categorie OR the subcategories relation for
		# EACH usable slug, exactly like the individual tabs do (those work reliably). The old
		# `categorie.Slug $in [...]` form matched only the top level and behaved inconsistently on
		# the authenticated proxy, so "All" showed only a handful of assets.
		var slugs: Array = []
		var usable := {}
		for cat in CghConfig.CATEGORIES:
			if cat["slug"] != "":
				usable[cat["slug"]] = true
				slugs.append(cat["slug"])
		for parent in CghConfig.SUBCATEGORIES.keys():
			if not usable.has(parent):
				continue
			for s in CghConfig.SUBCATEGORIES[parent]:
				slugs.append(s["slug"])
		var oi := 0
		for cs in slugs:
			var es := str(cs).uri_encode()
			q += "&filters[$or][%d][categorie][Slug][$eq]=%s" % [oi, es]; oi += 1
			q += "&filters[$or][%d][subcategories][Slug][$eq]=%s" % [oi, es]; oi += 1
	if search.strip_edges() != "":
		q += "&filters[Title][$containsi]=" + search.strip_edges().uri_encode()
	# Drop any stale/in-flight request first, otherwise a previous (slow) request
	# leaves the node busy and this one fails with ERR_BUSY (44).
	_http.cancel_request()
	var err := _http.request(base + q, _headers(), HTTPClient.METHOD_GET)
	if err != OK:
		request_failed.emit("Request could not start (err %d)" % err)

func _on_completed(result: int, code: int, _headers_in: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		request_failed.emit("Network error (result %d)" % result)
		return
	if code < 200 or code >= 300:
		request_failed.emit("Server returned HTTP %d" % code)
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		request_failed.emit("Bad JSON from server")
		return
	var data = parsed.get("data", [])
	var meta = parsed.get("meta", {})
	assets_loaded.emit(data if data is Array else [], meta if meta is Dictionary else {})

## Fetch the category tree so the UI can build an accurate subcategory dropdown from the
## live backend (like the Blender addon), not a hardcoded list. Non-fatal on failure.
func fetch_categories() -> void:
	var base := CghConfig.authed_categories_url() if _session_token != "" else CghConfig.public_categories_url()
	var q := "?addonSlug=%s&pagination[pageSize]=200&populate=*" % CghConfig.ADDON_SLUG
	_cat_http.cancel_request()
	var err := _cat_http.request(base + q, _headers(), HTTPClient.METHOD_GET)
	if err != OK:
		return   # keep the hardcoded subcategory fallback

func _on_cat_completed(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data = parsed.get("data", [])
	categories_loaded.emit(data if data is Array else [])
