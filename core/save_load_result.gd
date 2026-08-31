extends RefCounted
class_name CouchGamesSaveLoadResult

# The result of CouchGames.load_save_result() — the awaitable, honest
# counterpart to load_latest_save().
#
# load_latest_save() is a synchronous read of the save the platform handed this
# session at startup. It returns an empty payload for three different reasons —
# this player has no save, the session had not finished starting, or the player
# joined someone else's session and their save was deliberately withheld — and
# it cannot tell you which. A game that reads "empty" as "new player" starts
# from scratch, and its next whole-document save destroys real progress.
#
# load_save_result() separates those cases. Only STATUS_NOT_FOUND means "new
# player"; see is_safe_to_start_fresh().

## A stored save was found and is in `payload`.
const STATUS_FOUND := "found"
## Confirmed by the platform: this player has no save for this experience.
const STATUS_NOT_FOUND := "not_found"
## The save could not be read. Says NOTHING about whether one exists, so a game
## must not treat it as a new player.
const STATUS_UNAVAILABLE := "unavailable"

## One of the STATUS_* constants above. An unrecognised or missing status is
## normalised to STATUS_UNAVAILABLE — the only reading that cannot cause a
## game to overwrite a save it never saw.
var status: String = STATUS_UNAVAILABLE

## The platform's explanation. Empty on a clean read.
var message: String = ""

## The stored save, or empty when there is none to serve.
var payload: Dictionary = {}

## Game metadata that came back with the save. Empty when none was returned.
var metadata: Dictionary = {}

## The revision `payload` was read at, as an int, or null when the platform did
## not report one. Pass it to save_game()'s `expected_revision` to write
## deliberately against the state you actually saw.
var revision: Variant = null

## True while this player is joined to someone else's session.
##
## `payload` is then this player's OWN save, but the HOST owns the shared
## board. Use it as a merge base — read it, merge this session's contributions
## into it, and write that back. Rendering it as the live board would show a
## guest their solo game instead of the host's.
var host_authoritative: bool = false


static func from_dict(result: Dictionary) -> CouchGamesSaveLoadResult:
	var res = new()

	var raw_status := str(result.get("status", ""))
	# Anything unrecognised — an older platform build, a rejected promise, a
	# future status this build predates — degrades to "unavailable" rather than
	# reaching a game as a status it will not match.
	res.status = raw_status if raw_status in [
		STATUS_FOUND, STATUS_NOT_FOUND, STATUS_UNAVAILABLE
	] else STATUS_UNAVAILABLE

	res.message = str(result.get("message", ""))
	if res.status == STATUS_UNAVAILABLE and res.message.is_empty():
		res.message = "Save could not be loaded"

	# `not_found` carries an explicit null payload, and a rejected call carries
	# none at all; both land as an empty Dictionary.
	var payload: Variant = result.get("payload", null)
	if payload is Dictionary:
		res.payload = payload
	elif payload is String and (payload as String).length() > 0:
		var parsed: Variant = JSON.parse_string(payload)
		res.payload = parsed if parsed is Dictionary else {}

	var metadata: Variant = result.get("metadata", null)
	if metadata is Dictionary:
		res.metadata = metadata
	elif metadata is String and (metadata as String).length() > 0:
		var parsed_metadata: Variant = JSON.parse_string(metadata)
		res.metadata = parsed_metadata if parsed_metadata is Dictionary else {}

	var revision: Variant = result.get("revision", null)
	# Numbers cross the JS bridge through JSON, so an int arrives as a float.
	res.revision = int(revision) if (revision is int or revision is float) else null

	res.host_authoritative = bool(result.get("hostAuthoritative", false))

	return res


func is_found() -> bool:
	return status == STATUS_FOUND


func is_new_player() -> bool:
	return status == STATUS_NOT_FOUND


func is_unavailable() -> bool:
	return status == STATUS_UNAVAILABLE


## True only when the platform confirmed this player has no save. This is the
## ONLY condition under which a game may initialise empty state and then save
## it — every other status leaves open the possibility that a save exists, and
## writing a fresh document would destroy it.
##
## On a `found` result you may also write, but only after merging into
## `payload` — and if `host_authoritative` is true, merging is mandatory: you
## are a guest whose solo save is not the board on screen.
func is_safe_to_start_fresh() -> bool:
	return status == STATUS_NOT_FOUND
