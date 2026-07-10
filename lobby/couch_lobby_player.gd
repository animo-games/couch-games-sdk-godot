# One entry in the lobby roster, converted from the platform's LobbyPlayer
# shape ({userId, username, role, status, experienceId?, controllerSlot?,
# ping?}) into Godot-idiomatic fields.
class_name CouchLobbyPlayer
extends RefCounted

var user_id: String = ""
var username: String = ""
var role: String = "guest"  # "host" | "guest"
var status: String = "lobby"  # "lobby" | "playing" | "browsing" | "disconnected"
var experience_id: String = ""  # "" when unset
var controller_slot: int = -1  # -1 when unassigned
var ping: int = -1  # -1 when unknown

var is_host: bool:
	get:
		return role == "host"


static func from_dict(d: Dictionary) -> CouchLobbyPlayer:
	var player := CouchLobbyPlayer.new()
	player.user_id = _as_string(d.get("userId"), "")
	player.username = _as_string(d.get("username"), "")
	player.role = _as_string(d.get("role"), "guest")
	player.status = _as_string(d.get("status"), "lobby")
	player.experience_id = _as_string(d.get("experienceId"), "")
	player.controller_slot = _as_int(d.get("controllerSlot"), -1)
	player.ping = _as_int(d.get("ping"), -1)
	return player


func to_dict() -> Dictionary:
	return {
		"userId": user_id,
		"username": username,
		"role": role,
		"status": status,
		"experienceId": experience_id if not experience_id.is_empty() else null,
		"controllerSlot": controller_slot if controller_slot >= 0 else null,
		"ping": ping if ping >= 0 else null,
	}


## Equality for roster-diff purposes. Ping is deliberately excluded so
## heartbeat churn doesn't fire players_changed every update.
func roster_equals(other: CouchLobbyPlayer) -> bool:
	return user_id == other.user_id \
		and username == other.username \
		and role == other.role \
		and status == other.status \
		and experience_id == other.experience_id \
		and controller_slot == other.controller_slot


# JSON payloads carry nulls and float-typed numbers — coerce defensively.
static func _as_string(value: Variant, fallback: String) -> String:
	if value is String or value is StringName:
		return str(value)
	return fallback


static func _as_int(value: Variant, fallback: int) -> int:
	if value is int or value is float:
		return int(value)
	return fallback
