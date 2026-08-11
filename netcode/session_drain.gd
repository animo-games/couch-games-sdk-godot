## Duck-typed engine seam for the authoritative operation queue.
class_name CouchSessionDrain
extends RefCounted

const REQUIRED_METHODS := [
	"bind_head",
	"unbind_head",
	"apply_head_unpredicted",
	"dequeue_head",
	"can_reach_authority",
	"clear_queue",
	"enqueue_synthesised_load_level",
	"enqueue_synthesised_pause",
	"enqueue_sync_operation",
]


static func missing_methods(candidate: Object) -> Array:
	var missing: Array = []
	if candidate == null:
		return REQUIRED_METHODS.duplicate()
	for method_name in REQUIRED_METHODS:
		if not candidate.has_method(method_name):
			missing.append(method_name)
	return missing


static func implements(candidate: Object) -> bool:
	return missing_methods(candidate).is_empty()


static func assert_implements(candidate: Object, role: String = "session drain") -> bool:
	var missing := missing_methods(candidate)
	if missing.is_empty():
		return true
	push_error("%s does not satisfy CouchSessionDrain: missing %s" % [role, ", ".join(missing)])
	return false
