## Headless fault-injection acceptance test for defect 2 (gap detection) --
## run directly, no fixture corpus.
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_transport_faults.gd
##
## What is REAL (shipped) code under test: CouchLobbyTransport (including its
## fault injector), CouchEnvelope, and CouchSession -- the actual classes a
## game links against. Only CouchLobby is doubled, by CouchScriptedLobby in
## this directory; the real CouchLobby is exercised instead by the two-process
## LocalBackend parity run (G5), which this file does not replace.
##
## The gap-detection assertions below drive ONLY the deterministic
## `fault_drop_next()` lever. The probabilistic `fault_drop_permille` lever is
## the one the brief actually specifies ("drops a fraction of outgoing
## envelopes"), so it is exercised too, but ONLY at its two deterministic
## bounds -- permille=1000 (must drop every eligible send) and permille=0
## (must drop nothing) -- plus a check that `fault_kinds` actually restricts
## which kind is eligible. No assertion anywhere in this file depends on an
## RNG sequence a future Godot build could legitimately change: a mid-range
## permille would require asserting a statistical distribution, and a flaky
## acceptance test for a loss-detection feature is worse than none.
##
## The injector is gated on OS.is_debug_build(). A headless --script run is
## expected to satisfy that, but this file checks rather than assumes it: if
## the gate were somehow false, every fault_drop_next() call below would be
## inert and the drop-count assertion (not the gap assertions alone) is what
## catches a run that would otherwise pass vacuously.
##
## Exit codes: 0 = every assertion passed, 1 = at least one failed.
extends SceneTree

var _failures := 0


func _initialize() -> void:
	print("== Couch transport fault injection ==")
	print("OS.is_debug_build() = %s" % OS.is_debug_build())
	if not OS.is_debug_build():
		printerr("  FAIL: OS.is_debug_build() is false -- the fault injector is gated on this and will be inert; nothing below can be trusted")
		_failures += 1

	var host_player := {"user_id": "host", "username": "Host", "controller_slot": 0}
	var guest_player := {"user_id": "g1", "username": "Guest", "controller_slot": 1}
	var players := [host_player, guest_player]

	var host_lobby := CouchScriptedLobby.new("host", true)
	var guest_lobby := CouchScriptedLobby.new("g1", false)
	CouchScriptedLobby.link(host_lobby, guest_lobby)

	var host_transport := CouchLobbyTransport.new(host_lobby)
	var guest_transport := CouchLobbyTransport.new(guest_lobby)

	var host_roster := _FaultRoster.new(host_player, host_player, [guest_player], players, true)
	var guest_roster := _FaultRoster.new(guest_player, host_player, [guest_player], players, false)

	var host_session := CouchSession.new(host_roster, host_transport)
	var guest_session := CouchSession.new(guest_roster, guest_transport)

	var host_gaps: Array = []
	var guest_gaps: Array = []
	var host_intents: Array = []
	var host_inputs: Array = []
	var guest_snapshots: Array = []

	host_session.sequence_gap.connect(
		func(kind: String, sender_id: String, missing: int) -> void:
			host_gaps.append({"kind": kind, "sender_id": sender_id, "missing": missing})
	)
	guest_session.sequence_gap.connect(
		func(kind: String, sender_id: String, missing: int) -> void:
			guest_gaps.append({"kind": kind, "sender_id": sender_id, "missing": missing})
	)
	host_session.intent_received.connect(func(body: Dictionary, _sender_id: String) -> void: host_intents.append(body))
	host_session.input_received.connect(func(body: Dictionary, _sender_id: String) -> void: host_inputs.append(body))
	guest_session.snapshot_received.connect(func(body: Dictionary) -> void: guest_snapshots.append(body))

	# Bootstrap: host evaluates first (it needs no reply to become authoritative
	# and pins its authorized guest from the roster alone), then the guest, whose
	# hello crosses the now-engaged host and whose reply crosses back and clears
	# the guest's ready barrier.
	host_session.evaluate(0)
	guest_session.evaluate(0)

	_check(host_session.active, "host session is active after evaluate")
	_check(guest_session.active, "guest session is active after the host-hello round trip")

	# --- A dropped `intent` surfaces exactly one gap, missing == 1 -----------------
	guest_transport.fault_drop_next(CouchEnvelope.KIND_INTENT, 1)
	guest_session.send_intent({"verb": "A"})
	guest_session.send_intent({"verb": "B"})

	_check(host_gaps.size() == 1, "exactly one sequence_gap after a dropped intent (got %d)" % host_gaps.size())
	if host_gaps.size() == 1:
		var g: Dictionary = host_gaps[0]
		_check(g["kind"] == CouchEnvelope.KIND_INTENT, "the gap is reported for kind=intent (got %s)" % g["kind"])
		_check(g["missing"] == 1, "missing == 1 (got %s)" % g["missing"])
		_check(g["sender_id"] == "g1", "the gap is attributed to the guest (got %s)" % g["sender_id"])
	_check(
		host_intents.size() == 1 and host_intents[0].get("verb") == "B",
		"only intent B reached the host (got %s)" % [host_intents]
	)

	# --- A dropped `input` surfaces NO gap (latest-wins) ----------------------------
	var gaps_before_input := host_gaps.size()
	guest_transport.fault_drop_next(CouchEnvelope.KIND_INPUT, 1)
	guest_session.send_input({"move": "A"})
	guest_session.send_input({"move": "B"})

	_check(
		host_gaps.size() == gaps_before_input,
		"a dropped input produced no sequence_gap (count still %d)" % host_gaps.size()
	)
	_check(
		host_inputs.size() == 1 and host_inputs[0].get("move") == "B",
		"only input B reached the host (got %s)" % [host_inputs]
	)

	# --- A dropped `snapshot` surfaces NO gap (latest-wins) -------------------------
	host_transport.fault_drop_next(CouchEnvelope.KIND_SNAPSHOT, 1)
	host_session.broadcast_snapshot({"tick": 1})
	host_session.broadcast_snapshot({"tick": 2})

	_check(guest_gaps.is_empty(), "a dropped snapshot produced no sequence_gap on the guest (got %s)" % [guest_gaps])
	_check(
		guest_snapshots.size() == 1 and guest_snapshots[0].get("tick") == 2,
		"only snapshot tick=2 reached the guest (got %s)" % [guest_snapshots]
	)

	# --- The injector demonstrably fired (guards against a vacuous green) ----------
	var total_drops := guest_transport.fault_drops + host_transport.fault_drops
	_check(
		total_drops == 3,
		"fault_drops totals 3 across both transports (got %d: guest=%d host=%d)"
		% [total_drops, guest_transport.fault_drops, host_transport.fault_drops]
	)

	# --- Probabilistic lever, permille=1000: drops every eligible send, on ---------
	# --- EVERY kind while fault_kinds is empty (its documented "eligible" default) -
	guest_transport.fault_reset()
	guest_transport.fault_drop_permille = 1000
	var host_intents_before_all_drop := host_intents.size()
	for i in range(10):
		guest_session.send_intent({"permille_probe": i})
	_check(
		host_intents.size() == host_intents_before_all_drop,
		"permille=1000 (fault_kinds empty) drops every intent sent (0 of 10 arrived, got %d new)"
		% (host_intents.size() - host_intents_before_all_drop)
	)
	_check(
		guest_transport.fault_drops == 10,
		"fault_drops counted all 10 permille=1000 drops (got %d)" % guest_transport.fault_drops
	)
	# Empty fault_kinds must mean "every kind is eligible", not just the one
	# already exercised above -- confirm a SECOND kind is dropped too.
	var host_inputs_before_all_drop := host_inputs.size()
	guest_session.send_input({"permille_probe": "kind-check"})
	_check(
		host_inputs.size() == host_inputs_before_all_drop,
		"permille=1000 with empty fault_kinds also drops a different kind (input)"
	)
	_check(
		guest_transport.fault_drops == 11,
		"fault_drops is 11 after the extra empty-fault_kinds input drop (got %d)" % guest_transport.fault_drops
	)

	# --- Probabilistic lever, permille=0: drops nothing -----------------------------
	guest_transport.fault_reset()
	guest_transport.fault_drop_permille = 0
	var host_intents_before_no_drop := host_intents.size()
	for i in range(10):
		guest_session.send_intent({"permille_probe_zero": i})
	_check(
		host_intents.size() == host_intents_before_no_drop + 10,
		"permille=0 drops nothing (all 10 of 10 arrived, got %d new)"
		% (host_intents.size() - host_intents_before_no_drop)
	)
	_check(
		guest_transport.fault_drops == 0,
		"fault_drops stayed 0 at permille=0 (got %d)" % guest_transport.fault_drops
	)

	# --- fault_kinds restricts eligibility: only the named kind is dropped ---------
	guest_transport.fault_reset()
	guest_transport.fault_drop_permille = 1000
	guest_transport.fault_kinds = PackedStringArray([CouchEnvelope.KIND_INTENT])
	var host_intents_before_kinds := host_intents.size()
	var host_inputs_before_kinds := host_inputs.size()
	guest_session.send_intent({"probe": "kinds-intent"})
	guest_session.send_input({"probe": "kinds-input"})
	_check(
		host_intents.size() == host_intents_before_kinds,
		"fault_kinds=['intent'] drops intent even at permille=1000"
	)
	_check(
		host_inputs.size() == host_inputs_before_kinds + 1,
		"fault_kinds=['intent'] leaves a different kind (input) untouched at the same permille"
	)
	_check(
		guest_transport.fault_drops == 1,
		"exactly one drop counted for the fault_kinds-restricted send (got %d)" % guest_transport.fault_drops
	)

	print("")
	print("total assertions: %d failed" % _failures)
	quit(_failures if _failures > 0 else 0)
	return


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  PASS: " + message)
	else:
		_failures += 1
		printerr("  FAIL: " + message)


## Minimal duck-typed roster double, scoped to this file only.
##
## NOTE for the orchestrator: a shared `scripted_roster.gd` is being built in
## parallel (netcode/fixtures/) for the corpus runner (slice 4). This inner
## class intentionally duplicates a slice of that same duck surface so this
## file does not collide with that work-in-progress file. Flagged as known
## duplication to reconcile once both land -- this file could be pointed at
## the shared roster double instead, if its surface ends up compatible.
class _FaultRoster extends RefCounted:
	var is_available: bool = true

	var _me: Dictionary
	var _host: Dictionary
	var _guests: Array
	var _players: Array
	var _am_host: bool


	func _init(me: Dictionary, host: Dictionary, guests: Array, players: Array, am_host: bool) -> void:
		_me = me
		_host = host
		_guests = guests
		_players = players
		_am_host = am_host


	func get_players() -> Array:
		return _players


	func get_me() -> Variant:
		return _me


	func get_host() -> Variant:
		return _host


	func get_guests() -> Array:
		return _guests


	func is_host() -> bool:
		return _am_host
