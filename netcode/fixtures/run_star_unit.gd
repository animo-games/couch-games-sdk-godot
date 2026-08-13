## Headless PURE UNIT gate for the star's codec and identity primitives -- gate
## G7.
##
##   godot --headless --script res://addons/couch-games-sdk/netcode/fixtures/run_star_unit.gd
##
## What is under test: CouchEnvelope's binary codec (to_bytes/from_bytes) and its
## taxonomy parity with the JSON codec (to_json_frame/from_json_frame), plus
## CouchStarTransport's two pure statics -- derive_net_id() and lane_for_kind().
## NO WebRTC implementation is required or touched: this file never constructs a
## WebRTCPeerConnection or a CouchStarTransport instance, only calls its static
## functions. That is why this gate also runs in the SDK-only scratch project,
## which installs neither `lobby/` nor `webrtc/`. The two-peer establishment path
## (real WebRTCPeerConnections, real signaling round trips) is G8's job
## (run_star_link.gd), not this file's.
##
## Engine ERROR lines reading "Not enough bytes for decoding bytes, or invalid
## format." are EXPECTED here and are not failures -- bytes_to_var writes one for
## every malformed input, which is precisely what the malformed-frame assertions
## below feed it.
##
## Exit codes: 0 = every assertion passed, 1 = at least one failed.
extends SceneTree

var _failures := 0


func _initialize() -> void:
	print("== Couch star transport unit gate (G7) ==")

	_check_envelope_round_trip()
	_check_godot_types_survive()
	_check_to_bytes_strips_extras()
	_check_to_bytes_fills_defaults()
	_check_rejection_taxonomy()
	_check_size_cap_precedes_decoding()
	_check_cap_boundary_is_strict()
	_check_check_ordering()
	_check_taxonomy_parity_with_json()
	_check_cap_identity()
	_check_net_id_conformance()
	_check_net_id_invariants()
	_check_collision_fixture_is_real()
	_check_lane_table()
	_check_classify_generation()
	_check_object_payloads_are_refused()

	print("")
	print("total assertions: %d failed" % _failures)
	if _failures == 0:
		print("COUCH_STAR_UNIT_OK")
	else:
		printerr("COUCH_STAR_UNIT_FAILED: %d check(s)" % _failures)
	quit(_failures)
	return


func _check(condition: bool, message: String) -> void:
	if condition:
		print("  PASS: " + message)
	else:
		_failures += 1
		printerr("  FAIL: " + message)


# --- 1. Round trip, all six CouchEnvelope.KINDS -----------------------------


func _check_envelope_round_trip() -> void:
	for kind in CouchEnvelope.KINDS:
		var original: Dictionary = CouchEnvelope.make(kind, 1754996411123, 17, {"a": 1})
		var result := CouchEnvelope.from_bytes(CouchEnvelope.to_bytes(original))
		_check(str(result.get("error", "")) == "", "round trip: kind=%s decodes with no error" % kind)
		_check(result.get("envelope", {}) == original, "round trip: kind=%s decoded envelope == the original" % kind)


# --- 2. Godot types survive (three separate assertions) --------------------


func _check_godot_types_survive() -> void:
	var typed_body := {
		"v2": Vector2(1.5, -2.25),
		"arr": [1, null, "x"],
		"nested": {"p": PackedByteArray([1, 2, 3])},
	}
	var typed_env: Dictionary = CouchEnvelope.make(CouchEnvelope.KIND_SNAPSHOT, 1, 1, typed_body)
	var result := CouchEnvelope.from_bytes(CouchEnvelope.to_bytes(typed_env))
	var decoded_envelope: Dictionary = result.get("envelope", {})
	var decoded_body: Dictionary = decoded_envelope.get(CouchEnvelope.KEY_BODY, {})
	_check(decoded_body.get("v2") == Vector2(1.5, -2.25), "Godot types survive: Vector2 round-trips identical")
	_check(decoded_body.get("arr") == [1, null, "x"], "Godot types survive: Array with null round-trips identical")
	_check(
		decoded_body.get("nested") == {"p": PackedByteArray([1, 2, 3])},
		"Godot types survive: nested Dictionary with a PackedByteArray round-trips identical"
	)


# --- 3. to_bytes strips extras ----------------------------------------------


func _check_to_bytes_strips_extras() -> void:
	var base_env: Dictionary = CouchEnvelope.make(CouchEnvelope.KIND_HELLO, 1, 1, {"x": 1})
	var extra_env := base_env.duplicate(true)
	extra_env["from"] = "impostor"
	var base_bytes := CouchEnvelope.to_bytes(base_env)
	var extra_bytes := CouchEnvelope.to_bytes(extra_env)
	_check(
		base_bytes == extra_bytes,
		"to_bytes strips extras: to_bytes() output is byte-identical with and without an extra top-level key"
	)
	var extra_decoded: Dictionary = CouchEnvelope.from_bytes(extra_bytes).get("envelope", {})
	_check(
		extra_decoded.size() == 5
			and extra_decoded.has(CouchEnvelope.KEY_VERSION)
			and extra_decoded.has(CouchEnvelope.KEY_EPOCH)
			and extra_decoded.has(CouchEnvelope.KEY_KIND)
			and extra_decoded.has(CouchEnvelope.KEY_SEQ)
			and extra_decoded.has(CouchEnvelope.KEY_BODY)
			and not extra_decoded.has("from"),
		"to_bytes strips extras: decode of the extra-key envelope has exactly the five KEY_* keys and no \"from\""
	)


# --- 4. to_bytes fills defaults ---------------------------------------------


func _check_to_bytes_fills_defaults() -> void:
	# kind default: to_bytes({}) leaves EVERY field at its default; kind defaults
	# to "" which decodes to unknown-kind. This is the ORIGINAL assertion and it
	# only ever observes the kind default -- a mutated epoch/seq/body/v default
	# would decode to "unknown-kind" here too and stay invisible. Kept as-is; the
	# four assertions below are what actually cover the other four fields, each
	# in isolation.
	var result := CouchEnvelope.from_bytes(CouchEnvelope.to_bytes({}))
	_check(
		str(result.get("error", "")) == "unknown-kind",
		"to_bytes fills defaults: to_bytes({}) decodes to \"unknown-kind\" (kind defaulted to \"\")"
	)

	# Each assertion below supplies a VALID value for every field EXCEPT the one
	# under test, so a mutated default on any ONE field is independently
	# observable and cannot hide behind another field's (also wrong) default.

	# epoch default -> UNKNOWN_EPOCH (0). M26 mutates this to 1.
	var epoch_default: Dictionary = CouchEnvelope.from_bytes(CouchEnvelope.to_bytes({
		CouchEnvelope.KEY_VERSION: CouchEnvelope.PROTOCOL_VERSION,
		CouchEnvelope.KEY_KIND: CouchEnvelope.KIND_HELLO,
		CouchEnvelope.KEY_SEQ: 1,
		CouchEnvelope.KEY_BODY: {},
	}))
	_check(
		str(epoch_default.get("error", "")) == ""
			and (epoch_default.get("envelope", {}) as Dictionary).get(CouchEnvelope.KEY_EPOCH, -1) == CouchEnvelope.UNKNOWN_EPOCH,
		"to_bytes fills defaults: epoch omitted (all other fields valid) defaults to UNKNOWN_EPOCH (0)"
	)

	# seq default -> 0, which from_bytes rejects as bad-seq (valid range is
	# [1, MAX_SAFE_INT]). M27 mutates the default to 1, which is a VALID seq and
	# would decode cleanly instead.
	var seq_default: Dictionary = CouchEnvelope.from_bytes(CouchEnvelope.to_bytes({
		CouchEnvelope.KEY_VERSION: CouchEnvelope.PROTOCOL_VERSION,
		CouchEnvelope.KEY_EPOCH: 0,
		CouchEnvelope.KEY_KIND: CouchEnvelope.KIND_HELLO,
		CouchEnvelope.KEY_BODY: {},
	}))
	_check(
		str(seq_default.get("error", "")) == "bad-seq",
		"to_bytes fills defaults: seq omitted (all other fields valid) defaults to 0, rejected as bad-seq"
	)

	# body default -> {}. M28 mutates this to {"x": 1}.
	var body_default: Dictionary = CouchEnvelope.from_bytes(CouchEnvelope.to_bytes({
		CouchEnvelope.KEY_VERSION: CouchEnvelope.PROTOCOL_VERSION,
		CouchEnvelope.KEY_EPOCH: 0,
		CouchEnvelope.KEY_KIND: CouchEnvelope.KIND_HELLO,
		CouchEnvelope.KEY_SEQ: 1,
	}))
	_check(
		str(body_default.get("error", "")) == ""
			and (body_default.get("envelope", {}) as Dictionary).get(CouchEnvelope.KEY_BODY, {"x": 1}) == {},
		"to_bytes fills defaults: body omitted (all other fields valid) defaults to {}"
	)

	# v default -> PROTOCOL_VERSION. M29 mutates this to 2, which from_bytes
	# would then reject as bad-version instead of accepting.
	var v_default: Dictionary = CouchEnvelope.from_bytes(CouchEnvelope.to_bytes({
		CouchEnvelope.KEY_EPOCH: 0,
		CouchEnvelope.KEY_KIND: CouchEnvelope.KIND_HELLO,
		CouchEnvelope.KEY_SEQ: 1,
		CouchEnvelope.KEY_BODY: {},
	}))
	_check(
		str(v_default.get("error", "")) == ""
			and (v_default.get("envelope", {}) as Dictionary).get(CouchEnvelope.KEY_VERSION, -1) == CouchEnvelope.PROTOCOL_VERSION,
		"to_bytes fills defaults: v omitted (all other fields valid) defaults to PROTOCOL_VERSION"
	)


# --- Shared malformed-frame builders (binary + JSON) ------------------------


func _valid_frame_dict() -> Dictionary:
	return {
		CouchEnvelope.KEY_VERSION: CouchEnvelope.PROTOCOL_VERSION,
		CouchEnvelope.KEY_EPOCH: 0,
		CouchEnvelope.KEY_KIND: CouchEnvelope.KIND_HELLO,
		CouchEnvelope.KEY_SEQ: 1,
		CouchEnvelope.KEY_BODY: {},
	}


func _frame_missing(key: String) -> PackedByteArray:
	var d := _valid_frame_dict()
	d.erase(key)
	return var_to_bytes(d)


func _frame_with(key: String, value: Variant) -> PackedByteArray:
	var d := _valid_frame_dict()
	d[key] = value
	return var_to_bytes(d)


func _frame_with2(key_a: String, value_a: Variant, key_b: String, value_b: Variant) -> PackedByteArray:
	var d := _valid_frame_dict()
	d[key_a] = value_a
	d[key_b] = value_b
	return var_to_bytes(d)


func _from_bytes_error(bytes: PackedByteArray) -> String:
	return str(CouchEnvelope.from_bytes(bytes).get("error", ""))


func _valid_json_frame_dict() -> Dictionary:
	return {
		CouchEnvelope.KEY_VERSION: CouchEnvelope.PROTOCOL_VERSION,
		CouchEnvelope.KEY_EPOCH: 0,
		CouchEnvelope.KEY_KIND: CouchEnvelope.KIND_HELLO,
		CouchEnvelope.KEY_SEQ: 1,
		CouchEnvelope.KEY_BODY: Marshalls.raw_to_base64(var_to_bytes({})),
	}


func _json_frame_with(key: String, value: Variant) -> Dictionary:
	var d := _valid_json_frame_dict()
	d[key] = value
	return d


func _from_json_frame_error(frame: Dictionary) -> String:
	return str(CouchEnvelope.from_json_frame(frame).get("error", ""))


# --- 5. Rejection taxonomy, exact strings -----------------------------------


func _check_rejection_taxonomy() -> void:
	# not-a-dictionary: five ways to fail to even BE a Dictionary.
	_check(_from_bytes_error(PackedByteArray()) == "not-a-dictionary", "rejection: empty PackedByteArray() -> not-a-dictionary")
	_check(_from_bytes_error(PackedByteArray([1, 2, 3, 4])) == "not-a-dictionary", "rejection: 4 junk bytes -> not-a-dictionary")
	_check(_from_bytes_error(var_to_bytes(42)) == "not-a-dictionary", "rejection: var_to_bytes(42) -> not-a-dictionary")
	_check(_from_bytes_error(var_to_bytes("hi")) == "not-a-dictionary", "rejection: var_to_bytes(\"hi\") -> not-a-dictionary")
	_check(_from_bytes_error(var_to_bytes([])) == "not-a-dictionary", "rejection: var_to_bytes([]) -> not-a-dictionary")

	# bad-version
	_check(_from_bytes_error(_frame_missing(CouchEnvelope.KEY_VERSION)) == "bad-version", "rejection: v missing -> bad-version")
	_check(_from_bytes_error(_frame_with(CouchEnvelope.KEY_VERSION, 2)) == "bad-version", "rejection: v=2 -> bad-version")
	_check(_from_bytes_error(_frame_with(CouchEnvelope.KEY_VERSION, "1")) == "bad-version", "rejection: v=\"1\" -> bad-version")

	# unknown-kind
	_check(_from_bytes_error(_frame_missing(CouchEnvelope.KEY_KIND)) == "unknown-kind", "rejection: kind missing -> unknown-kind")
	_check(_from_bytes_error(_frame_with(CouchEnvelope.KEY_KIND, "bogus")) == "unknown-kind", "rejection: kind=\"bogus\" -> unknown-kind")
	_check(_from_bytes_error(_frame_with(CouchEnvelope.KEY_KIND, 7)) == "unknown-kind", "rejection: kind=7 -> unknown-kind")

	# bad-epoch
	_check(_from_bytes_error(_frame_missing(CouchEnvelope.KEY_EPOCH)) == "bad-epoch", "rejection: epoch missing -> bad-epoch")
	_check(_from_bytes_error(_frame_with(CouchEnvelope.KEY_EPOCH, -1)) == "bad-epoch", "rejection: epoch=-1 -> bad-epoch")
	_check(
		_from_bytes_error(_frame_with(CouchEnvelope.KEY_EPOCH, CouchEnvelope.MAX_SAFE_INT + 1)) == "bad-epoch",
		"rejection: epoch=MAX_SAFE_INT+1 -> bad-epoch"
	)
	_check(_from_bytes_error(_frame_with(CouchEnvelope.KEY_EPOCH, "x")) == "bad-epoch", "rejection: epoch=\"x\" -> bad-epoch")

	# bad-seq
	_check(_from_bytes_error(_frame_missing(CouchEnvelope.KEY_SEQ)) == "bad-seq", "rejection: seq missing -> bad-seq")
	_check(_from_bytes_error(_frame_with(CouchEnvelope.KEY_SEQ, 0)) == "bad-seq", "rejection: seq=0 -> bad-seq")
	_check(_from_bytes_error(_frame_with(CouchEnvelope.KEY_SEQ, -1)) == "bad-seq", "rejection: seq=-1 -> bad-seq")
	_check(
		_from_bytes_error(_frame_with(CouchEnvelope.KEY_SEQ, CouchEnvelope.MAX_SAFE_INT + 1)) == "bad-seq",
		"rejection: seq=MAX_SAFE_INT+1 -> bad-seq"
	)

	# bad-body
	_check(_from_bytes_error(_frame_missing(CouchEnvelope.KEY_BODY)) == "bad-body", "rejection: body missing -> bad-body")
	_check(_from_bytes_error(_frame_with(CouchEnvelope.KEY_BODY, "str")) == "bad-body", "rejection: body=\"str\" -> bad-body")
	_check(_from_bytes_error(_frame_with(CouchEnvelope.KEY_BODY, [])) == "bad-body", "rejection: body=[] -> bad-body")
	_check(_from_bytes_error(_frame_with(CouchEnvelope.KEY_BODY, 7)) == "bad-body", "rejection: body=7 -> bad-body")


# --- 6. Size cap precedes decoding ------------------------------------------


func _check_size_cap_precedes_decoding() -> void:
	# All bytes equal to 0xAA, DELIBERATELY not a valid Variant encoding. This is
	# the mutation detector for M1: if the cap check moves to AFTER bytes_to_var,
	# this same input decodes as "not-a-dictionary" instead of "oversized-body".
	var junk := PackedByteArray()
	junk.resize(CouchEnvelope.MAX_BINARY_FRAME_BYTES + 1)
	for i in junk.size():
		junk[i] = 0xAA
	_check(
		_from_bytes_error(junk) == "oversized-body",
		"size cap: a frame of MAX_BINARY_FRAME_BYTES + 1 junk bytes is rejected as oversized-body BEFORE decoding"
	)


# --- 7. Cap boundary is > not >= --------------------------------------------


func _check_cap_boundary_is_strict() -> void:
	var junk := PackedByteArray()
	junk.resize(CouchEnvelope.MAX_BINARY_FRAME_BYTES)
	for i in junk.size():
		junk[i] = 0xAA
	_check(
		_from_bytes_error(junk) == "not-a-dictionary",
		"cap boundary: exactly MAX_BINARY_FRAME_BYTES junk bytes is UNDER the cap and falls through to a decode failure"
	)


# --- 8. Check ordering -------------------------------------------------------


func _check_check_ordering() -> void:
	_check(
		_from_bytes_error(_frame_with2(CouchEnvelope.KEY_VERSION, 2, CouchEnvelope.KEY_KIND, "bogus")) == "bad-version",
		"check ordering: a frame that is both bad-version and unknown-kind reports bad-version"
	)
	_check(
		_from_bytes_error(_frame_with2(CouchEnvelope.KEY_KIND, "bogus", CouchEnvelope.KEY_EPOCH, -1)) == "unknown-kind",
		"check ordering: a frame that is both unknown-kind and bad-epoch reports unknown-kind"
	)
	_check(
		_from_bytes_error(_frame_with2(CouchEnvelope.KEY_EPOCH, -1, CouchEnvelope.KEY_SEQ, 0)) == "bad-epoch",
		"check ordering: a frame that is both bad-epoch and bad-seq reports bad-epoch"
	)
	_check(
		_from_bytes_error(_frame_with2(CouchEnvelope.KEY_SEQ, 0, CouchEnvelope.KEY_BODY, "str")) == "bad-seq",
		"check ordering: a frame that is both bad-seq and bad-body reports bad-seq"
	)


# --- 9. Taxonomy parity with the JSON wire ----------------------------------


func _check_taxonomy_parity_with_json() -> void:
	var defects := [
		{"key": CouchEnvelope.KEY_VERSION, "value": 2, "label": "bad-version"},
		{"key": CouchEnvelope.KEY_KIND, "value": "bogus", "label": "unknown-kind"},
		{"key": CouchEnvelope.KEY_EPOCH, "value": -1, "label": "bad-epoch"},
		{"key": CouchEnvelope.KEY_SEQ, "value": 0, "label": "bad-seq"},
		{"key": CouchEnvelope.KEY_BODY, "value": 7, "label": "bad-body"},
	]
	for defect in defects:
		var key: String = defect["key"]
		var value: Variant = defect["value"]
		var label: String = defect["label"]
		var binary_error := _from_bytes_error(_frame_with(key, value))
		var json_error := _from_json_frame_error(_json_frame_with(key, value))
		_check(
			binary_error == json_error and binary_error == label,
			"taxonomy parity: the same %s defect reports \"%s\" on both from_bytes and from_json_frame" % [label, label]
		)


# --- 10. Cap identity ---------------------------------------------------------


func _check_cap_identity() -> void:
	_check(
		CouchEnvelope.MAX_BINARY_FRAME_BYTES * 4 / 3 == CouchEnvelope.MAX_FRAME_BODY_CHARS,
		"cap identity: MAX_BINARY_FRAME_BYTES * 4 / 3 == MAX_FRAME_BODY_CHARS"
	)
	_check(CouchEnvelope.MIN_BINARY_FRAME_BYTES == 8, "cap identity: MIN_BINARY_FRAME_BYTES == 8")


# --- 11. Net-id conformance ----------------------------------------------------


func _check_net_id_conformance() -> void:
	for vector in CouchNetIdVectors.VECTORS:
		var peer_id: String = vector[0]
		var expected: int = vector[1]
		_check(
			CouchStarTransport.derive_net_id(peer_id) == expected,
			"net-id conformance: derive_net_id(\"%s\") == %d" % [peer_id, expected]
		)


# --- 12. Net-id invariants (aggregated over 10 000 generated ids) -------------


## Rewritten from the iteration-1 version, which was tautological: it assigned
## `net_id := derive_net_id(id)` and then compared `derive_net_id(id) != net_id`
## in the SAME loop body, so a `derive_net_id` that always returns a constant
## still passed every check it ran (all_in_range/none_zero/none_one would fail
## for a badly chosen constant, but nothing here forced ONE). Two INDEPENDENT
## passes over the same 10 000 ids, compared afterwards, is what "determinism"
## actually means; a distinctness check is what actually rules out a constant
## return, since two independent passes of a CONSTANT function are still
## trivially equal to each other. M31 (derive_net_id returns a constant) is
## caught by the distinctness assertion, not the determinism one.
func _check_net_id_invariants() -> void:
	var pass_one: Array = []
	var pass_two: Array = []
	for i in range(10000):
		pass_one.append(CouchStarTransport.derive_net_id("u%d" % i))
	for i in range(10000):
		pass_two.append(CouchStarTransport.derive_net_id("u%d" % i))

	var all_in_range := true
	var none_zero := true
	var none_one := true
	for net_id in pass_one:
		if net_id < CouchNetIdVectors.NET_ID_MIN or net_id > CouchNetIdVectors.NET_ID_MAX:
			all_in_range = false
		if net_id == 0:
			none_zero = false
		if net_id == 1:
			none_one = false
	_check(all_in_range, "net-id invariants: all 10000 generated ids fall in [NET_ID_MIN, NET_ID_MAX]")
	_check(none_zero, "net-id invariants: none of the 10000 generated ids is 0")
	_check(none_one, "net-id invariants: none of the 10000 generated ids is 1")

	_check(
		pass_one == pass_two,
		"net-id invariants: derive_net_id(x) == derive_net_id(x) across two INDEPENDENT passes over the same 10000 ids"
	)

	var distinct := {}
	for net_id in pass_one:
		distinct[net_id] = true
	_check(
		distinct.size() >= 9990,
		"net-id invariants: the 10000 generated ids fold to at least 9990 DISTINCT net ids (rare birthday collisions are expected; a CONSTANT return is not)"
	)


# --- 13. Collision fixture is real ---------------------------------------------


func _check_collision_fixture_is_real() -> void:
	var a: String = CouchNetIdVectors.COLLIDING_PAIR[0]
	var b: String = CouchNetIdVectors.COLLIDING_PAIR[1]
	_check(
		CouchStarTransport.derive_net_id(a) == CouchNetIdVectors.COLLIDING_NET_ID
			and CouchStarTransport.derive_net_id(b) == CouchNetIdVectors.COLLIDING_NET_ID,
		"collision fixture: both COLLIDING_PAIR entries derive to COLLIDING_NET_ID"
	)
	_check(a != b, "collision fixture: the two colliding peer ids are themselves distinct strings")


# --- 14. Lane table -------------------------------------------------------------


func _check_lane_table() -> void:
	var lane_cases := [
		[CouchEnvelope.KIND_HELLO, MultiplayerPeer.TRANSFER_MODE_RELIABLE],
		[CouchEnvelope.KIND_INTENT, MultiplayerPeer.TRANSFER_MODE_RELIABLE],
		[CouchEnvelope.KIND_INPUT, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE],
		[CouchEnvelope.KIND_SNAPSHOT, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED],
		[CouchEnvelope.KIND_RESYNC_REQUEST, MultiplayerPeer.TRANSFER_MODE_RELIABLE],
		[CouchEnvelope.KIND_RESYNC_RESPONSE, MultiplayerPeer.TRANSFER_MODE_RELIABLE],
		["bogus-unrecognised-kind", MultiplayerPeer.TRANSFER_MODE_RELIABLE],
	]
	for entry in lane_cases:
		var kind: String = entry[0]
		var expected_mode: int = entry[1]
		_check(
			CouchStarTransport.lane_for_kind(kind) == expected_mode,
			"lane table: lane_for_kind(\"%s\") matches its documented lane" % kind
		)


# --- 15. classify_generation, all three branches --------------------------------
#
# CouchStarTransport.classify_generation(local_gen, incoming_gen) -> GenAction is
# the pure, static, three-valued classification that replaces the iteration-1
# `!=` rule (delta plan iteration 2, section 1). It is the whole of the fix for
# Codex's delayed-stale-packet wedge, and it lives entirely in these branches,
# so it is unit-tested directly rather than only indirectly through G11's fault
# scenarios.


func _check_classify_generation() -> void:
	_check(
		CouchStarTransport.classify_generation(1, 1) == CouchStarTransport.GenAction.PROCESS,
		"classify_generation(1, 1): same generation -> PROCESS"
	)
	# M19's exact named detector (delta plan section 6): a DROP_STALE branch
	# rewritten to return ADOPT must turn this assertion red.
	_check(
		CouchStarTransport.classify_generation(1, 0) == CouchStarTransport.GenAction.DROP_STALE,
		"classify_generation(1, 0): an older incoming generation -> DROP_STALE"
	)
	_check(
		CouchStarTransport.classify_generation(0, 1) == CouchStarTransport.GenAction.ADOPT,
		"classify_generation(0, 1): a newer incoming generation -> ADOPT"
	)
	# A second DROP_STALE case at different magnitudes than (1, 0), so a mutation
	# that special-cases the exact (1, 0) pair cannot hide behind the assertion
	# above.
	_check(
		CouchStarTransport.classify_generation(5, 2) == CouchStarTransport.GenAction.DROP_STALE,
		"classify_generation(5, 2): a generation two behind the local one -> DROP_STALE"
	)
	_check(
		CouchStarTransport.classify_generation(0, 0) == CouchStarTransport.GenAction.PROCESS,
		"classify_generation(0, 0): generation zero on both sides -> PROCESS"
	)


# --- 16. Object payloads are refused ---------------------------------------------
#
# THE mutation detector for "from_bytes switched to bytes_to_var_with_objects".
# var_to_bytes_with_objects appears in exactly one place in this whole package:
# HERE, in a test, building the hostile frame the production decoder must
# refuse. See envelope.gd's from_bytes/to_bytes docstrings -- bytes_to_var() is
# named there as "the single most security-critical line in the package", and
# until this assertion existed nothing would go red if that line changed.


func _check_object_payloads_are_refused() -> void:
	var hostile := {
		CouchEnvelope.KEY_VERSION: CouchEnvelope.PROTOCOL_VERSION,
		CouchEnvelope.KEY_EPOCH: 0,
		CouchEnvelope.KEY_KIND: CouchEnvelope.KIND_SNAPSHOT,
		CouchEnvelope.KEY_SEQ: 1,
		CouchEnvelope.KEY_BODY: {"payload": RefCounted.new()},
	}
	var result := CouchEnvelope.from_bytes(var_to_bytes_with_objects(hostile))
	_check(str(result.get("error", "")) != "",
		"object frame: a var_to_bytes_with_objects frame carrying an Object in `body` is REJECTED")
	_check((result.get("envelope", {}) as Dictionary).is_empty(),
		"object frame: the rejected result carries an EMPTY envelope, never a partially-decoded one")
	_check(not _contains_object(result.get("envelope", {})),
		"object frame: no Object instance appears anywhere in the decoded envelope")
	# Same shape one level deeper, so a decoder that only refused a TOP-level
	# object would still go red.
	var nested := hostile.duplicate(true)
	nested[CouchEnvelope.KEY_BODY] = {"deep": {"list": [1, RefCounted.new(), 3]}}
	_check(str(CouchEnvelope.from_bytes(var_to_bytes_with_objects(nested)).get("error", "")) != "",
		"object frame: an Object nested inside an Array inside a Dictionary is also REJECTED")


## Recursively walk Dictionaries and Arrays looking for a live Object instance.
func _contains_object(v: Variant) -> bool:
	if v is Object:
		return true
	if v is Dictionary:
		for value in (v as Dictionary).values():
			if _contains_object(value):
				return true
		return false
	if v is Array:
		for item in (v as Array):
			if _contains_object(item):
				return true
		return false
	return false
