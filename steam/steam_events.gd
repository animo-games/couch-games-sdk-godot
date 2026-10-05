## Wire validation independent of the native dependency. 384 KiB includes the
## complete JSON envelope and accommodates CouchEnvelope's 256 KiB base64 body.
extends RefCounted
const WIRE_VERSION := 1
const MAX_BYTES := 393216
const NATIVE_MAX_BYTES := 524288
const _JSONValue := preload("res://addons/couch-games-sdk/core/json_value.gd")
static func json_compatible(value: Variant, depth: int = 0) -> bool:
	return _JSONValue.compatible(value, depth)
static func encode(lobby_id: String, token: String, event: String, data: Variant) -> PackedByteArray:
	return JSON.stringify({"wire_version": WIRE_VERSION, "lobby_id": lobby_id, "session_token": token, "event": event, "data": data}).to_utf8_buffer()
static func decode(bytes: PackedByteArray, lobby_id: String, token: String, max_bytes: int) -> Dictionary:
	if bytes.size() > max_bytes: return {}
	var parser := JSON.new()
	if parser.parse(bytes.get_string_from_utf8()) != OK: return {}
	var value: Variant = parser.data
	if not value is Dictionary: return {}
	if value.get("wire_version") != WIRE_VERSION or value.get("lobby_id") != lobby_id or value.get("session_token") != token: return {}
	if not value.get("event") is String or value.event.is_empty() or not value.has("data"): return {}
	if not json_compatible(value.data): return {}
	return value
