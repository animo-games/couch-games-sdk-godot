extends RefCounted
class_name CouchGamesSDKResponse

var success: bool = false
var error: String = ""
var payload: Dictionary = {}

static func from_dict(response: Dictionary) -> CouchGamesSDKResponse:
	var res = new()
	res.success = response.get("success", false)
	res.error = response.get("error", "Unknown error")
	res.payload = response.get("payload", {})
	return res
