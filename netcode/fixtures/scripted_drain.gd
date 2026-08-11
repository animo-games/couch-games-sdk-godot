## Strict scripted implementation of CouchSessionDrain for fixture cases.
class_name CouchScriptedDrain
extends RefCounted

var can_reach_authority_result: bool = true
var apply_head_unpredicted_results: Array = []
var dequeue_count: int = 0
var head_bound: bool = false
var authority_probe_count: int = 0
var clear_queue_count: int = 0
var call_log: Array
var contract_violation: String = ""


func _init(shared_log: Array) -> void:
	call_log = shared_log


func reset_authority_probe_count() -> void:
	authority_probe_count = 0


func can_reach_authority() -> bool:
	authority_probe_count += 1
	return can_reach_authority_result


func bind_head() -> void:
	if head_bound:
		_violate("bind_head called while already bound")
		return
	head_bound = true
	call_log.append("bind-head")


func unbind_head() -> void:
	if not head_bound:
		_violate("unbind_head called while not bound")
		return
	head_bound = false
	call_log.append("unbind-head")


func apply_head_unpredicted() -> bool:
	call_log.append("apply-head-unpredicted")
	if apply_head_unpredicted_results.is_empty():
		_violate(
			"apply_head_unpredicted called with no queued result; the fixture under-declared it"
		)
		return false
	return apply_head_unpredicted_results.pop_front()


func dequeue_head() -> void:
	dequeue_count += 1
	call_log.append("dequeue-head")


func clear_queue() -> void:
	clear_queue_count += 1
	call_log.append("clear-queue")


func enqueue_synthesised_load_level(level: int) -> void:
	call_log.append("enqueue-synthesised-load-level(level=%d)" % level)


func enqueue_synthesised_pause(paused: bool) -> void:
	# C# bool.ToString() is deliberately capitalized in the reference call log.
	call_log.append("enqueue-synthesised-pause(paused=%s)" % ("True" if paused else "False"))


func enqueue_sync_operation(index: int) -> void:
	call_log.append("enqueue-sync-operation(index=%d)" % index)


func _violate(message: String) -> void:
	if contract_violation.is_empty():
		contract_violation = message
