# Experience files, exposed as `CouchGames.experience`.
#
# An experience is a dated content drop for a game — a level pack, a room, a
# puzzle set — uploaded on the platform and addressed by BASENAME, never by URL.
# The URL embeds an experience id that rotates, so any game keying off it writes
# code that breaks the next day.
#
# Delivery is race-free: the platform retains the bytes, so `await get_file()`
# resolves whether the download finished before or after you asked. There is no
# handshake to wait for and no event to catch at the right moment.
#
# The usual case is one call:
#
#     func _ready() -> void:
#         await CouchGames.init()
#         if await CouchGames.experience.load_pack("level.dlf"):
#             var manifest := load("res://experience/manifest.tres")
#
# Everything here runs AFTER the game has started, which is the point: the
# platform also stages a pack into the engine filesystem before startup, and
# that path has to be timed against engine init. This one cannot be, because by
# the time you can call it the engine is by definition already running.
class_name CouchExperience
extends Node

## Where load_pack() writes bytes before handing them to the engine. Under
## user:// because res:// is read-only in an exported build.
const MOUNT_DIR := "user://couch_experience/"

## What load_all_packs() recognises — the formats load_resource_pack() accepts.
const PACK_EXTENSIONS := ["pck", "zip"]

var _backend: CouchGamesBackend


## Called by the CouchGames autoload during setup.
func setup(backend: CouchGamesBackend) -> void:
	_backend = backend


## Basenames of every file on the current experience. Empty off-platform unless
## a local experience directory is configured (see the mock backend).
func list_files() -> PackedStringArray:
	if not _backend:
		return PackedStringArray()
	return _backend.experience_list_files()


func has_file(file_name: String) -> bool:
	return file_name in list_files()


## Bytes for one file. Empty on failure, with the reason pushed as an error —
## an unknown name, a failed download, or an experience rotation mid-flight.
func get_file(file_name: String) -> PackedByteArray:
	if not _backend:
		push_error("CouchGames: SDK not initialised, call await CouchGames.init()")
		return PackedByteArray()
	var result: Dictionary = await _backend.experience_get_file(file_name)
	if not result.get("success", false):
		push_error("CouchGames: experience file '%s': %s"
			% [file_name, result.get("error", "unknown error")])
		return PackedByteArray()
	return result.get("bytes", PackedByteArray())


func get_file_text(file_name: String) -> String:
	var bytes := await get_file(file_name)
	if bytes.is_empty():
		return ""
	return bytes.get_string_from_utf8()


## Parsed JSON, or null if the file is missing or not valid JSON.
func get_file_json(file_name: String) -> Variant:
	var text := await get_file_text(file_name)
	if text.is_empty():
		return null
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		push_error("CouchGames: experience file '%s' is not valid JSON" % file_name)
	return parsed


## Fetches a .pck/.zip and loads it into the resource system, so its contents
## become available at their res:// paths. Idempotent: mounting the same name
## twice is a no-op returning true, because load_resource_pack replaces files
## and re-running it would silently reshuffle what a scene already resolved.
##
## The mount itself is CouchPackInstaller's job, shared with CouchGames.game so
## that two ways of sourcing a pack cannot become two ways of installing one.
func load_pack(file_name: String) -> bool:
	var mount_path := MOUNT_DIR.path_join(file_name)
	# Checked before the fetch, not just inside install(), so a repeat call
	# costs nothing rather than re-downloading bytes it will then discard.
	if CouchPackInstaller.is_mounted(mount_path):
		return true
	var bytes := await get_file(file_name)
	if bytes.is_empty():
		return false
	return CouchPackInstaller.install(bytes, mount_path, file_name)


## Loads every resource pack on the experience and returns the names it loaded.
##
## This is the call that means you never have to agree a filename with whoever
## uploads the experience: what a pack is CALLED stops mattering, and everything
## structural moves inside it, at res:// paths you chose when you built it.
##
## Loaded in the order the platform lists them, which is upload order. That is
## the order to reason about if two packs carry the same path, because the later
## one wins.
##
## A pack that fails to load is left out of the returned list rather than
## aborting the rest, so compare the length against the pack count if you need
## all-or-nothing.
func load_all_packs() -> PackedStringArray:
	var loaded := PackedStringArray()
	for file_name in list_files():
		if not PACK_EXTENSIONS.has(file_name.get_extension().to_lower()):
			continue
		if await load_pack(file_name):
			loaded.append(file_name)
	return loaded
