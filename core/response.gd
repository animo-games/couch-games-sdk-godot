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
	res.error = str(response.get("error", response.get("message", "Unknown error")))
	var payload = response.get('payload', {})
	if payload is String and (payload as String).length() > 0:
		res.payload = JSON.parse_string(payload)
	elif payload is String:
		res.payload = {}
	elif payload is Dictionary:
		res.payload = payload

	res.metadata = response.get('metadata', {})
	if res.metadata is String and (res.metadata as String).length() > 0:
		res.metadata = JSON.parse_string(res.metadata)
	if res.metadata is not Dictionary:
		res.metadata = {}

	# A missing `persisted` means the platform did not confirm a write, so it
	# must read as false rather than inheriting `success`.
	res.persisted = bool(response.get("persisted", false))
	res.conflict = bool(response.get("conflict", false))
	var revision: Variant = response.get("currentRevision", null)
	# Numbers cross the JS bridge through JSON, so an int arrives as a float.
	res.current_revision = int(revision) if (revision is int or revision is float) else null

	return res
