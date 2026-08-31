extends RefCounted
class_name CouchGamesSDKResponse

var success: bool = false
var error: String = ""
var payload: Dictionary = {}
var metadata: Dictionary = {}

## Save writes only. True only when the platform confirmed the blob was stored.
##
## This is the field to branch on after save_game(), NOT `success`. The platform
## reports a refused write as `success: true, persisted: false` by default, so a
## game that trusts `success` alone will believe a save landed when it did not.
## A response that omits the field (an older platform build, or a call the
## platform accepted as a no-op) leaves this false — "did not land" is the
## fail-safe reading.
##
## Meaningless on any verb other than save_game(); it is false there because
## those responses say nothing about a save.
var persisted: bool = false

## True when a save was refused because this session has never read the stored
## save it would have replaced — a joined guest that has not called
## load_save_result(), or a game that booted on an empty save cache that filled
## moments later.
##
## The way out is the same in both cases: call load_save_result(), merge into
## what it returns, and write that back.
var conflict: bool = false

## The stored save's revision as an int, or null when the platform did not
## report one.
##
## Present on a successful save (the revision the write produced, ready to pass
## as `expected_revision` on the next one) and on a refusal the SERVER made. A
## refusal the platform made client-side cannot know a revision, so this stays
## null there — never require it to recover from a conflict.
var current_revision: Variant = null

static func from_dict(response: Dictionary) -> CouchGamesSDKResponse:
	var res = new()
	res.success = response.get("success", false)
	# The platform reports failures in `message`; the mock backend and this
	# SDK's own local failures use `error`. Accept either, or a refusal's
	# explanation would reach games as "Unknown error".
	var error_text: Variant = response.get("error", response.get("message", "Unknown error"))
	res.error = str(error_text) if error_text != null else "Unknown error"

	# Every branch below has to survive a value the platform never promised.
	# This function is the SDK's safety layer, and a runtime error inside a
	# static function aborts it and hands the game a null response object --
	# which is worse than any degraded value it could have returned.
	var payload: Variant = response.get('payload', {})
	if payload is Dictionary:
		res.payload = payload
	elif payload is String and (payload as String).length() > 0:
		# A save blob that is valid JSON but not an object (an array, a bare
		# scalar, "null") parses to something unassignable. Degrade rather than
		# throw.
		var parsed: Variant = JSON.parse_string(payload)
		res.payload = parsed if parsed is Dictionary else {}

	var metadata: Variant = response.get('metadata', {})
	if metadata is Dictionary:
		res.metadata = metadata
	elif metadata is String and (metadata as String).length() > 0:
		var parsed_metadata: Variant = JSON.parse_string(metadata)
		res.metadata = parsed_metadata if parsed_metadata is Dictionary else {}

	# A missing `persisted` means the platform did not confirm a write, so it
	# must read as false rather than inheriting `success`.
	# Type-test before use, the way the revision fields below do. Neither
	# bool(x) nor `x == true` is safe on an arbitrary Variant: the constructor
	# rejects what it does not recognise and cross-type `==` raises "Invalid
	# operands", and either would abort this function and hand the game a null
	# response. A non-boolean here can only mean a response shape the SDK does
	# not understand, and the fail-safe reading of that is "did not land".
	var persisted: Variant = response.get("persisted", false)
	res.persisted = persisted if persisted is bool else false
	var conflict: Variant = response.get("conflict", false)
	res.conflict = conflict if conflict is bool else false
	var revision: Variant = response.get("currentRevision", null)
	# Numbers cross the JS bridge through JSON, so an int arrives as a float.
	res.current_revision = int(revision) if (revision is int or revision is float) else null

	return res
