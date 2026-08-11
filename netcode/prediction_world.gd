## The engine seam. Ints and bools only -- no engine types cross this boundary.
##
## GDScript has no interfaces, so this is a duck-typed contract checked at runtime,
## following the same pattern the rollback signaling adapter established in this
## addon: name the members in one place, check them in one place, and fail loudly
## with a list of what is missing rather than crashing later on a null call.
##
## Every member here is CORE-INVARIANT: the core's correctness depends on these
## exact contracts holding. A game implements this against its own world; the
## fixture harness implements it with a scripted fake.
##
## Required members (see couch-netcode-fixtures/README.md for the full spec):
##
##   can_reconcile() -> bool
##       Is rewinding and replaying safe right now?
##
##   rewind_budget() -> int
##       How many times rewind_one() may still be called.
##
##   world_epoch() -> int
##       Bumped whenever the snapshot stack is mutated non-linearly (restart, level
##       load, stack fixup). A change invalidates all rollback accounting the core holds.
##
##   world_generation() -> int
##       Bumped when the rollback base is DESTROYED, as opposed to reshaped. A change
##       means no previously-recorded authoritative state can be restored, so
##       reconciliation must stop rather than proceed against a base that is gone.
##       Always a strict subset of world_epoch()'s bump sites.
##
##   rewind_one() -> bool
##       Undo exactly one recorded state change, SILENTLY -- no undo sound, no
##       "player has undone" statistic. False if it could not.
##
##   can_apply_pending_remote() -> bool
##       Only valid inside the core's authoritative-operation handling: may the op
##       being reconciled be applied right now? Must not mutate anything.
##
##   apply_pending_remote() -> bool
##       Only valid in the same window: apply it. False on refusal.
##
##   apply_move(player_slot: int, dx: int, dy: int, silent: bool) -> MoveOutcome
##       Run one local move. `silent` is true for replays (suppress all effects); a
##       genuinely new remote event must never be silenced.
##
## THE OBLIGATION THIS CONTRACT DOES NOT DISCHARGE: passing the fixture corpus
## proves the core is right, not that your world obeys this. In the reference
## implementation the load-bearing bug was an engine path that destroyed the
## rollback base BEFORE the core was ever consulted, found by reading engine code
## rather than by any test. Audit your own world against these members.
class_name CouchPredictionWorld
extends RefCounted

const REQUIRED_METHODS := [
	"can_reconcile",
	"rewind_budget",
	"world_epoch",
	"world_generation",
	"rewind_one",
	"can_apply_pending_remote",
	"apply_pending_remote",
	"apply_move",
]


## Every required method this candidate is missing, in contract order. Empty means
## it satisfies the contract shape.
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


## Raises a descriptive error naming every missing member. Call this once, where the
## world is handed to the core -- not per frame.
static func assert_implements(candidate: Object, role: String = "prediction world") -> bool:
	var missing := missing_methods(candidate)
	if missing.is_empty():
		return true
	push_error(
		"%s does not satisfy CouchPredictionWorld: missing %s" % [role, ", ".join(missing)]
	)
	return false
