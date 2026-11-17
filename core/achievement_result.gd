extends CouchGamesSDKResponse
class_name CouchGamesAchievementResult

# What unlock_achievement() answers with.

## True when the player already had it.
var already_unlocked: bool = false


static func from_dict(response: Dictionary) -> CouchGamesAchievementResult:
	var res := CouchGamesAchievementResult.new()
	res._read(response)
	return res


func _read(response: Dictionary) -> void:
	super(response)
	already_unlocked = _as_bool(response.get("alreadyUnlocked"), false)
