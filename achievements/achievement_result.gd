class_name CouchAchievementResult
extends RefCounted
var key := ""
var status := "unavailable"
var locally_unlocked := false
var provider_acknowledged := false
var already_unlocked := false
var error_code := ""
var error := ""
static func from_dict(value: Dictionary) -> CouchAchievementResult:
	var result := CouchAchievementResult.new()
	for field in ["key", "status", "locally_unlocked", "provider_acknowledged", "already_unlocked", "error_code", "error"]:
		if value.has(field):
			result.set(field, value[field])
	return result
