extends RefCounted
class_name CouchGamesSDKResponse

var success: bool = false
var error: String = ""
var payload: Dictionary = {}

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

	return res
