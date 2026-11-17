extends RefCounted
class_name CouchGamesSDKResponse

# The fields every call answers with. A call that answers with more has its
# own subclass (CouchGamesSaveWriteResult, CouchGamesFullscreenResult, ...)
# that extends _read() with just those fields, so this class does not grow a
# field for every call the platform adds.

var success: bool = false
var error: String = ""
var payload: Dictionary = {}
## Array payloads, including list_experiences(). Keeps payload's existing
## Dictionary type intact for games that infer their own types from it.
var payload_array: Array = []
var metadata: Dictionary = {}


static func from_dict(response: Dictionary) -> CouchGamesSDKResponse:
	var res := CouchGamesSDKResponse.new()
	res._read(response)
	return res


## Fills this response from the platform's answer. A subclass calls super()
## and then reads its own fields with the _as_* helpers below.
##
## Every read has to survive a value the platform never promised. from_dict()
## is the SDK's safety layer, and a runtime error inside it aborts it and hands
## the game a null response object -- which is worse than any degraded value
## it could have returned.
func _read(response: Dictionary) -> void:
	success = response.get("success", false)
	# The platform reports failures in `message`; the mock backend and this
	# SDK's own local failures use `error`. Accept either, or a refusal's
	# explanation would reach games as "Unknown error".
	var error_text: Variant = response.get("error", response.get("message", "Unknown error"))
	error = str(error_text) if error_text != null else "Unknown error"

	var raw_payload: Variant = response.get("payload", {})
	if raw_payload is Array:
		payload_array = raw_payload
	else:
		payload = _as_dict_or_json(raw_payload)
	metadata = _as_dict_or_json(response.get("metadata", {}))


# Field coercion for values that crossed the JS bridge. Each helper type-tests
# before converting: neither bool(x) nor `x == true` is safe on an arbitrary
# Variant (the constructor rejects what it does not recognise, and cross-type
# `==` raises "Invalid operands"), and either would abort from_dict() and hand
# the game a null response. Anything of the wrong type takes the fallback.
static func _as_bool(value: Variant, fallback: bool) -> bool:
	return value if value is bool else fallback


# Numbers cross the bridge through JSON, so an int arrives as a float.
static func _as_int(value: Variant, fallback: int) -> int:
	return int(value) if (value is int or value is float) else fallback


static func _as_nullable_int(value: Variant) -> Variant:
	return int(value) if (value is int or value is float) else null


# A Dictionary, or a non-empty JSON string that parses to one. A blob that is
# valid JSON but not an object (an array, a bare scalar, "null") parses to
# something unassignable, so it degrades to {} rather than throwing.
static func _as_dict_or_json(value: Variant) -> Dictionary:
	if value is Dictionary:
		return value
	if value is String and (value as String).length() > 0:
		var parsed: Variant = JSON.parse_string(value)
		if parsed is Dictionary:
			return parsed
	return {}
