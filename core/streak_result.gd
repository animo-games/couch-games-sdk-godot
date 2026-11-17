extends CouchGamesSDKResponse
class_name CouchGamesStreakResult

# What list_experiences() and gameplay_completed() answer with.

## The player's current streak in this game as an int, or null when the
## platform did not send one (an older platform build). 0 for a guest and for a
## refused completion, and also when the streak could not be read just then:
## 0 is not proof it broke.
var streak: Variant = null


static func from_dict(response: Dictionary) -> CouchGamesStreakResult:
	var res := CouchGamesStreakResult.new()
	res._read(response)
	return res


func _read(response: Dictionary) -> void:
	super(response)
	streak = _as_nullable_int(response.get("streak"))
