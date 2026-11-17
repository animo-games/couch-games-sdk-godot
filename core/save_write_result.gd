extends CouchGamesSDKResponse
class_name CouchGamesSaveWriteResult

# What save_game() answers with.

## True only when the platform confirmed the blob was stored.
##
## This is the field to branch on after save_game(), NOT `success`. The platform
## reports a refused write as `success: true, persisted: false` by default, so a
## game that trusts `success` alone will believe a save landed when it did not.
## A response that omits the field (an older platform build, or a call the
## platform accepted as a no-op) leaves this false — "did not land" is the
## fail-safe reading.
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


static func from_dict(response: Dictionary) -> CouchGamesSaveWriteResult:
	var res := CouchGamesSaveWriteResult.new()
	res._read(response)
	return res


func _read(response: Dictionary) -> void:
	super(response)
	# A missing `persisted` must read as false rather than inheriting `success`.
	persisted = _as_bool(response.get("persisted"), false)
	conflict = _as_bool(response.get("conflict"), false)
	current_revision = _as_nullable_int(response.get("currentRevision"))
