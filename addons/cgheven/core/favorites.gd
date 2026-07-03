@tool
extends RefCounted
class_name CghFavorites
## Favorites store (persisted to user://cgheven/favorites.json). Stores the
## whole asset dict so the Favorites tab can render without a re-fetch.

const _PATH := "user://cgheven/favorites.json"

static func _load() -> Dictionary:
	if not FileAccess.file_exists(_PATH):
		return {}
	var f := FileAccess.open(_PATH, FileAccess.READ)
	if not f:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}

static func _save(d: Dictionary) -> void:
	CghConfig.ensure_dirs()
	var f := FileAccess.open(_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(d))
		f.close()

static func is_fav(asset: Dictionary) -> bool:
	return _load().has(CghAsset.id(asset))

static func toggle(asset: Dictionary) -> bool:
	var d := _load()
	var k := CghAsset.id(asset)
	if d.has(k):
		d.erase(k)
		_save(d)
		return false
	d[k] = asset
	_save(d)
	return true

static func all() -> Array:
	return _load().values()

static func count() -> int:
	return _load().size()
