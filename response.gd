extends RefCounted
class_name CouchGamesSDKResponse

var success: bool = false
var error: String = ""
var payload: Dictionary = {}
var metadata: Dictionary = {}

static func from_dict(response: Dictionary) -> CouchGamesSDKResponse:
	var res = new()
	res.success = response.get("success", false)
	res.error = response.get("error", "Unknown error")
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

	return res
