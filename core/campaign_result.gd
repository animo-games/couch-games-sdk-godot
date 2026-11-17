extends CouchGamesSDKResponse
class_name CouchGamesCampaignResult

# What complete_campaign() answers with.

## True when this player had already finished the campaign, so this call
## recorded nothing new.
var already_completed: bool = false


static func from_dict(response: Dictionary) -> CouchGamesCampaignResult:
	var res := CouchGamesCampaignResult.new()
	res._read(response)
	return res


func _read(response: Dictionary) -> void:
	super(response)
	already_completed = _as_bool(response.get("alreadyCompleted"), false)
