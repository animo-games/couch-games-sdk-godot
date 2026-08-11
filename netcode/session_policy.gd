## Tunable seed-1 drain and recovery policy.
class_name CouchSessionPolicy
extends RefCounted

var stuck_head_ms: int = 2000
var base_backoff_ms: int = 1000
var max_backoff_ms: int = 8000
var backoff_shift_cap: int = 3
var max_attempts: int = 6
var no_baseline_ms: int = 1000


static func default_policy() -> CouchSessionPolicy:
	return CouchSessionPolicy.new()


## Preserves seed 1's intentional first-gap off-by-one: attempt 1 waits 2x base.
func backoff_ms_for(attempts: int) -> int:
	var shift := attempts if attempts < backoff_shift_cap else backoff_shift_cap
	return mini(base_backoff_ms << shift, max_backoff_ms)


func is_structurally_unapplicable(
	head: CouchSessionTypes.HeadDescriptor, current_level: int
) -> bool:
	return head.kind == CouchPredictionTypes.OpKind.MOVE and head.level != current_level
