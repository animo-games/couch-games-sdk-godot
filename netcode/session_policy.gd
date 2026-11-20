## Tunable seed-1 drain and recovery policy.
class_name CouchSessionPolicy
extends RefCounted

var stuck_head_ms: int = 2000
var base_backoff_ms: int = 1000
var max_backoff_ms: int = 8000
var backoff_shift_cap: int = 3
var max_attempts: int = 6
var no_baseline_ms: int = 1000
## The number of GUESTS that may hold an input slot. The host is always slot 0
## and is not counted; 1 = today's single pinned guest (legacy behaviour).
## CouchSession reads this once at construction (floored at 1).
var max_input_players: int = 1
## How long a guest holds an intent it cannot send: its link is down, or it is
## waiting for the snapshot that follows a link reset. Held intents go out in
## order right after that snapshot; one held longer than this is dropped
## instead (held_intents_dropped, "expired"), because an action from a long
## outage would surprise everyone when it finally lands. Covers a short blip,
## not an away player. 0 turns holding off completely.
var intent_hold_ms: int = 3000
## How many intents a guest holds at most. A full hold refuses the next intent
## (send_intent returns false). 0 also turns holding off.
var intent_hold_limit: int = 256


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
