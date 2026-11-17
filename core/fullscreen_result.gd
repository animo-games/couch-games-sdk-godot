extends CouchGamesSDKResponse
class_name CouchGamesFullscreenResult

# What request_fullscreen() and exit_fullscreen() answer with.

## Whether the game is fullscreen after the call.
var fullscreen: bool = false


static func from_dict(response: Dictionary) -> CouchGamesFullscreenResult:
	var res := CouchGamesFullscreenResult.new()
	res._read(response)
	return res


func _read(response: Dictionary) -> void:
	super(response)
	fullscreen = _as_bool(response.get("fullscreen"), false)
