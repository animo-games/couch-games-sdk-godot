## Strict shared JSON boundary. Reject Godot objects/types rather than stringify
## them into a platform-dependent representation. Limits recursive input depth.
extends RefCounted
static func compatible(value: Variant, depth: int = 0) -> bool:
	if depth > 32: return false
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING: return true
		TYPE_FLOAT: return is_finite(value)
		TYPE_ARRAY:
			for child in value:
				if not compatible(child, depth + 1): return false
			return true
		TYPE_DICTIONARY:
			for key in value:
				if not key is String or not compatible(value[key], depth + 1): return false
			return true
	return false
