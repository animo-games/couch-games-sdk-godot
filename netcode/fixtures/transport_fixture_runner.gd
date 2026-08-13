## Runs the transport/session fixture corpus (schema
## couch.transport.session.fixtures/v1, couch-netcode-fixtures/transport/)
## against this addon's CouchTransport / CouchEnvelope / CouchSession. Mirrors
## CouchFixtureRunner's discipline exactly:
##
##   1. FAIL on unknown actions and unknown keys, never skip. Every step and
##      every expectSends/expectSignals entry is checked against an allowlist
##      before anything runs.
##   2. Compare expectSends / expectSignals IN ORDER, every field present in
##      each declared entry, not just length.
##   3. Report tier, so a re-decided seed-2-policy case is distinguishable from
##      a broken core-invariant one.
##
## Unlike CouchFixtureRunner there is no Status.UNIMPLEMENTED here: this corpus
## is authored against a fully shipped CouchSession/CouchTransport/CouchEnvelope,
## not a staged port, so every declared action is always drivable.
##
## Each case drives exactly ONE CouchSession -- the `local` player -- against a
## CouchScriptedTransport and a CouchScriptedRoster seeded from the case's
## `roster`. A step's expectSends/expectSignals compares only what happened
## DURING that step: both logs are cleared before the step runs, the step is
## driven, then compared.
##
## Body encoding convention (couch-netcode-fixtures/transport/README.md):
##   - `recv`'s `body` is always a Dictionary; this runner real-encodes it
##     exactly as the shipped codec would (var_to_bytes + base64) via
##     CouchEnvelope.to_json_frame, then round-trips the header through
##     JSON.stringify/JSON.parse_string so the real float-coercion every
##     backend performs on the wire is actually exercised, not shortcut.
##   - `recv-frame`'s `frame.body`: a Dictionary is real-encoded the same way;
##     a String is passed through onto the wire literally, unencoded -- this
##     is how the corpus constructs not-valid-base64 / oversized / wrong-type
##     bodies without needing a precomputed valid encoding.
##
## Two runner-side invariants beyond what this JSON schema can declare (see
## couch-netcode-fixtures/transport/README.md, "Two known gaps in this case
## list" -- flagged there for the runner author):
##   - Every session-started signal's epoch is recorded for the whole case; if
##     a second one fires, its epoch must differ from the previous one. This
##     is what actually proves restart-after-a-stop-mints-a-different-epoch's
##     claim (epoch A != epoch B), which the JSON itself cannot express since
##     the schema has no cross-step value-capture syntax.
##   - For every step EXCEPT recv/recv-frame -- the only actions through which
##     a guest can silently adopt a new epoch from an accepted envelope
##     without a session-started re-announcement, see couch_session.gd's
##     _on_envelope_received comment ("a guest can learn a new epoch from ANY
##     accepted kind, not only hello") -- if neither session-started nor
##     session-stopped fired during the step, CouchSession.epoch must be
##     unchanged. This is what actually proves
##     transport-gap-surfaces-without-changing-the-epoch's claim. Checked
##     against every OTHER case in the corpus before being added: it is safe
##     precisely because it excludes recv/recv-frame, where a same-step silent
##     epoch adoption is legitimate, documented behaviour.
## Both are always-on and apply to every case, not name-gated to the two cases
## that motivated them.
##
## epoch-is-unix-milliseconds (also flagged as a runner-side obligation, since
## a fixture cannot encode "the wall clock at the moment this runs") is
## likewise checked here: whenever a HOST's session-started fires, the minted
## epoch must be within ONE_HOUR_MS of the runner's own wall clock. Never
## checked on a guest, whose session-started epoch in this corpus is
## fixture-fabricated, not wall-clock-minted.
class_name CouchTransportFixtureRunner
extends RefCounted

const EXPECTED_SCHEMA := "couch.transport.session.fixtures/v1"

enum Status { PASSED, FAILED }

const COMMON_KEYS := ["action", "at"]
const CASE_KEYS := ["name", "tier", "description", "local", "roster", "steps"]
const TIER_LABELS := ["core-invariant", "seed-2-policy"]
const ROSTER_PLAYER_KEYS := ["userId", "username", "role", "controllerSlot"]
const EXPECT_SEND_KEYS := ["to", "kind", "seq", "epoch", "body"]

## Per-signal field allowlist, keyed by the corpus's kebab-case signal name.
## Mirrors CouchSession's actual signal argument lists 1:1.
const SIGNAL_FIELDS := {
	"session-started": ["epoch", "isHost", "localSlot", "peerId", "peerName"],
	"session-stopped": ["reason"],
	"hello-received": ["from"],
	"intent-received": ["body", "from"],
	"input-received": ["body", "from"],
	"snapshot-received": ["body"],
	"sequence-gap": ["kind", "from", "missing"],
	"transport-gap": ["peerId", "reason"],
	"rejected": ["reason", "from"],
}

## Per-action key allowlist. A step carrying anything not listed for its action
## is a failure: it means the fixture is asserting something this runner does
## not read. Matches couch-netcode-fixtures/README.md's step-action table.
const ACTION_KEYS := {
	"evaluate": ["expectSends", "expectSignals"],
	"poll": ["expectSends", "expectSignals"],
	"roster": ["players", "expectSends", "expectSignals"],
	"stop": ["reason", "expectSignals"],
	"peer-ready": ["peerId", "expectSends", "expectSignals"],
	"peer-lost": ["peerId", "expectSends", "expectSignals"],
	"transport-gap": ["peerId", "reason", "expectSignals"],
	"recv": ["from", "kind", "epoch", "seq", "body", "expectAccepted", "expectSends", "expectSignals"],
	"recv-frame": ["from", "frame", "expectAccepted", "expectError", "expectSignals"],
	"send-intent": ["body", "expectResult", "expectSends"],
	"send-input": ["body", "expectResult", "expectSends"],
	"send-snapshot": ["body", "expectResult", "expectSends"],
	"assert":
	[
		"active", "epoch", "epochIsNot", "isHost", "localSlot", "authorizedPeer", "hostId",
		"gapCount", "rejectedCount",
	],
}

## "$other" (a recv step's fabricated foreign epoch) must differ from whatever
## the driven session's live epoch is. Both candidates are impossible unix-ms
## magnitudes (a real minted epoch is ~1.7e12 today), so a collision with a
## genuine host-minted epoch cannot happen in practice; picking whichever of
## the two differs from the live epoch makes it categorically impossible.
const OTHER_EPOCH_PRIMARY := 1
const OTHER_EPOCH_FALLBACK := 2

## Wide tolerance for the epoch-is-unix-milliseconds runner-side check --
## the point is "this is a wall-clock value", not a tight bound.
const ONE_HOUR_MS := 3600000

const SKIP_MARKER := "@runner-skip"

var results: Array = []


class CaseResult extends RefCounted:
	var name: String = ""
	var tier: String = ""
	var status: int = CouchTransportFixtureRunner.Status.PASSED
	var message: String = ""


## Loads every corpus file in `data_dir`, verifying it against `manifest.json`
## beside it. Returns {"cases": Array, "error": String}. Same drift-guard
## discipline as CouchFixtureRunner.load_corpus.
static func load_corpus(data_dir: String) -> Dictionary:
	var dir_path := data_dir.trim_suffix("/")
	var manifest_path := dir_path.get_base_dir().path_join("manifest.json")

	# The manifest is REQUIRED and it is the completeness authority, not a
	# best-effort hash check over whatever files happen to be lying around. A
	# corpus that is merely INCOMPLETE still produces a green run -- deleting
	# transport-session-core.json used to yield a cheerful 6/6 policy-only pass
	# -- so absence, omission and addition all have to be hard errors here, at
	# the only point that can see them.
	if not FileAccess.file_exists(manifest_path):
		return {"cases": [], "error": "manifest.json not found at %s" % manifest_path}
	var manifest_text := FileAccess.get_file_as_string(manifest_path)
	var manifest_parsed: Variant = JSON.parse_string(manifest_text)
	if not (manifest_parsed is Dictionary):
		return {"cases": [], "error": "%s is not a JSON object" % manifest_path}
	var manifest: Dictionary = manifest_parsed
	if not manifest.has("files") or not (manifest["files"] is Array):
		return {"cases": [], "error": "%s has missing or non-array field 'files'" % manifest_path}
	if not manifest.has("totalCases") or not _is_number(manifest["totalCases"]):
		return {
			"cases": [],
			"error": "%s has missing or non-numeric field 'totalCases'" % manifest_path,
		}
	var expected: Dictionary = {}
	for entry in manifest["files"]:
		expected[entry["file"]] = entry

	var listing := DirAccess.get_files_at(dir_path)
	if listing.is_empty():
		return {"cases": [], "error": "no fixture files found at %s" % dir_path}

	var cases: Array = []
	var names: Array = []
	var seen_files: Dictionary = {}
	for file_name in listing:
		if not file_name.ends_with(".json"):
			continue
		if not expected.has(file_name):
			return {
				"cases": [],
				"error":
				(
					"%s is not listed in manifest.json -- an unlisted corpus file would run "
					+ "unverified, with no sha256 pin and no declared case count."
				) % file_name,
			}
		seen_files[file_name] = true
		# `.get`, never `expected[file_name]`: a hard index would turn a future
		# regression in the unlisted-file guard above into an engine-level
		# SCRIPT ERROR instead of a reported corpus error.
		var entry: Dictionary = expected.get(file_name, {})
		var expected_sha := str(entry.get("sha256", ""))
		var path := dir_path.path_join(file_name)
		var bytes := FileAccess.get_file_as_bytes(path)
		var actual_sha := _sha256_hex(bytes)
		if actual_sha != expected_sha:
			return {
				"cases": [],
				"error":
				(
					"%s does not match manifest.json (sha256 %s, expected %s). "
					+ "The corpus has drifted -- resolve that before trusting any result."
				) % [file_name, actual_sha, expected_sha],
			}
		var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
		if not parsed is Dictionary:
			return {"cases": [], "error": "%s is not a JSON object" % file_name}
		var root_unknown := _unknown_keys_for(parsed, ["schema", "cases"])
		if not root_unknown.is_empty():
			return {
				"cases": [],
				"error": "%s has unknown root key(s): %s" % [file_name, ", ".join(root_unknown)],
			}
		if not parsed.has("schema") or not parsed["schema"] is String:
			return {"cases": [], "error": "%s has missing or non-string field 'schema'" % file_name}
		if parsed["schema"] != EXPECTED_SCHEMA:
			return {
				"cases": [],
				"error":
				"%s declares schema %s, expected %s" % [file_name, parsed["schema"], EXPECTED_SCHEMA],
			}
		if not parsed.has("cases") or not parsed["cases"] is Array:
			return {"cases": [], "error": "%s has missing or non-array field 'cases'" % file_name}
		for case_index in range(parsed["cases"].size()):
			var case_data: Variant = parsed["cases"][case_index]
			if not case_data is Dictionary:
				return {
					"cases": [],
					"error": "%s: cases[%d] is not a JSON object" % [file_name, case_index],
				}
			var case_name: Variant = case_data.get("name", "")
			if case_name in names:
				return {"cases": [], "error": "duplicate case name %s" % case_name}
			names.append(case_name)
			cases.append(case_data)

	for file_name in expected:
		if not seen_files.has(file_name):
			return {
				"cases": [],
				"error":
				(
					"%s is listed in manifest.json but was not found in %s -- the corpus is "
					+ "incomplete, and an incomplete corpus still runs green."
				) % [file_name, dir_path],
			}

	var total_cases := int(manifest["totalCases"])
	if cases.size() != total_cases:
		return {
			"cases": [],
			"error":
			"loaded %d cases but manifest.json declares totalCases %d" % [cases.size(), total_cases],
		}

	return {"cases": cases, "error": ""}


# --- load_corpus completeness self-test ------------------------------------------

const SELF_TEST_ROOT := "user://transport-corpus-selftest"
const SELF_TEST_FILES := ["a.json", "b.json"]


## Exercises every completeness guard in load_corpus against deliberately-broken
## corpora built under user://, plus one well-formed positive control so the
## self-test cannot pass by rejecting everything. Returns an Array of failure
## descriptions; empty means every guard fired exactly as intended.
##
## This lives here rather than in the corpus because a corpus case cannot test
## the loader: the loader runs first, and the failure mode being guarded against
## is precisely "the corpus loaded green while being incomplete".
static func self_test_load_corpus() -> Array:
	var failures: Array = []
	var one_case := {
		"name": "self-test-case",
		"tier": "core-invariant",
		"description": "self-test",
		"local": "h",
		"roster": [],
		"steps": [],
	}
	var body_text := JSON.stringify({"schema": EXPECTED_SCHEMA, "cases": [one_case]})
	var sha := _sha256_hex(body_text.to_utf8_buffer())
	var entry_a := {"file": "a.json", "sha256": sha, "cases": 1, "tiers": {"core-invariant": 1}}
	var entry_b := {"file": "b.json", "sha256": sha, "cases": 1, "tiers": {"core-invariant": 1}}

	# Positive control FIRST: a well-formed corpus must load cleanly.
	var dir := _self_test_build(
		"well-formed", {"a.json": body_text}, {"schema": EXPECTED_SCHEMA, "totalCases": 1, "files": [entry_a]}
	)
	var loaded := load_corpus(dir)
	if not str(loaded["error"]).is_empty():
		failures.append("well-formed control: expected a clean load, got %s" % loaded["error"])
	elif (loaded["cases"] as Array).size() != 1:
		failures.append("well-formed control: expected 1 case, got %d" % (loaded["cases"] as Array).size())

	failures.append_array(_self_test_expect(
		"no-manifest", {"a.json": body_text}, null, "manifest.json not found"
	))
	failures.append_array(_self_test_expect(
		"missing-file",
		{"a.json": body_text},
		{"schema": EXPECTED_SCHEMA, "totalCases": 2, "files": [entry_a, entry_b]},
		"listed in manifest.json but was not found"
	))
	failures.append_array(_self_test_expect(
		"unlisted-file",
		{"a.json": body_text, "b.json": body_text},
		{"schema": EXPECTED_SCHEMA, "totalCases": 1, "files": [entry_a]},
		"is not listed in manifest.json"
	))
	failures.append_array(_self_test_expect(
		"total-mismatch",
		{"a.json": body_text},
		{"schema": EXPECTED_SCHEMA, "totalCases": 99, "files": [entry_a]},
		"declares totalCases 99"
	))
	return failures


static func _self_test_expect(
	name: String, files: Dictionary, manifest: Variant, expected_fragment: String
) -> Array:
	var dir := _self_test_build(name, files, manifest)
	var loaded := load_corpus(dir)
	var error := str(loaded["error"])
	if error.is_empty():
		return ["%s: load_corpus accepted a corpus it must reject (expected an error containing %s)" % [name, expected_fragment]]
	if not error.contains(expected_fragment):
		return ["%s: expected an error containing %s, got %s" % [name, expected_fragment, error]]
	return []


## Builds (or rebuilds from scratch) one self-test corpus and returns its data
## dir. Every known file is erased first so a previous run's leftovers in
## user:// can never make a later run pass or fail spuriously.
static func _self_test_build(name: String, files: Dictionary, manifest: Variant) -> String:
	var root := SELF_TEST_ROOT.path_join(name)
	var data_dir := root.path_join("data")
	DirAccess.make_dir_recursive_absolute(data_dir)
	DirAccess.remove_absolute(root.path_join("manifest.json"))
	for file_name in SELF_TEST_FILES:
		DirAccess.remove_absolute(data_dir.path_join(file_name))
	if manifest != null:
		_self_test_write(root.path_join("manifest.json"), JSON.stringify(manifest))
	for file_name in files:
		_self_test_write(data_dir.path_join(file_name), str(files[file_name]))
	return data_dir


static func _self_test_write(path: String, text: String) -> void:
	var handle := FileAccess.open(path, FileAccess.WRITE)
	if handle == null:
		return
	handle.store_string(text)
	handle.close()


static func _sha256_hex(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


func run_all(cases: Array) -> Array:
	results.clear()
	for case_data in cases:
		results.append(run_case(case_data))
	return results


func run_case(case_data: Dictionary) -> CaseResult:
	var result := CaseResult.new()
	result.name = case_data.get("name", "<unnamed>")
	result.tier = case_data.get("tier", "<untiered>")

	var schema_failure := _validate_case_schema(case_data)
	if not schema_failure.is_empty():
		result.status = Status.FAILED
		result.message = schema_failure
		return result

	var local_id: String = case_data["local"]
	var roster := CouchScriptedRoster.new(local_id, case_data["roster"])
	var transport := CouchScriptedTransport.new()
	var session := CouchSession.new(roster, transport)

	var step_signals: Array = []
	var session_started_epochs: Array = []
	_connect_signals(session, step_signals, session_started_epochs)

	var steps: Array = case_data["steps"]
	for step_index in range(steps.size()):
		var step: Dictionary = steps[step_index]
		var action: String = step["action"]
		transport.reset_log()
		step_signals.clear()

		var epoch_before := session.epoch
		var failure := _drive(action, step, session, roster, transport, step_signals)
		if not failure.is_empty():
			result.status = Status.FAILED
			result.message = "step %d (%s): %s" % [step_index, action, failure]
			return result

		# Runner-side invariant #1 -- see this file's header. recv/recv-frame
		# are exempt: a guest legitimately adopts a new epoch mid-step from an
		# accepted envelope of ANY kind, with no session-started re-announce.
		if action != "recv" and action != "recv-frame":
			var lifecycle_fired := (
				_contains_signal(step_signals, "session-started")
				or _contains_signal(step_signals, "session-stopped")
			)
			if not lifecycle_fired and session.epoch != epoch_before:
				result.status = Status.FAILED
				result.message = (
					(
						"step %d (%s): epoch changed from %d to %d with neither session-started "
						+ "nor session-stopped firing -- see the runner-side invariant in this "
						+ "file's header"
					) % [step_index, action, epoch_before, session.epoch]
				)
				return result

		# epoch-is-unix-milliseconds -- see this file's header. Host-only.
		for sig in step_signals:
			if str(sig.get("signal", "")) == "session-started" and bool(sig.get("isHost", false)):
				var epoch: int = int(sig["epoch"])
				var now_ms := int(Time.get_unix_time_from_system() * 1000.0)
				if absi(epoch - now_ms) > ONE_HOUR_MS:
					result.status = Status.FAILED
					result.message = (
						(
							"step %d (%s): epoch-is-unix-milliseconds: minted epoch %d is not "
							+ "within %d ms of the runner's wall clock (%d)"
						) % [step_index, action, epoch, ONE_HOUR_MS, now_ms]
					)
					return result

		failure = _compare_sends(step, transport.sends, session)
		if not failure.is_empty():
			result.status = Status.FAILED
			result.message = "step %d (%s): %s" % [step_index, action, failure]
			return result

		failure = _compare_signals(step, step_signals, session)
		if not failure.is_empty():
			result.status = Status.FAILED
			result.message = "step %d (%s): %s" % [step_index, action, failure]
			return result

	# Runner-side invariant #2 -- see this file's header. Checked once, over
	# the full per-case history, after every step has run.
	for i in range(1, session_started_epochs.size()):
		if session_started_epochs[i] == session_started_epochs[i - 1]:
			result.status = Status.FAILED
			result.message = (
				(
					"session-started fired twice with the SAME epoch (%d) -- a restart must "
					+ "mint a new epoch, see the runner-side invariant in this file's header"
				) % session_started_epochs[i]
			)
			return result

	return result


func _connect_signals(
	session: CouchSession, step_signals: Array, session_started_epochs: Array
) -> void:
	session.session_started.connect(func(epoch, is_host, local_slot, peer_id, peer_name):
		session_started_epochs.append(epoch)
		step_signals.append({
			"signal": "session-started",
			"epoch": epoch,
			"isHost": is_host,
			"localSlot": local_slot,
			"peerId": peer_id,
			"peerName": peer_name,
		})
	)
	session.session_stopped.connect(func(reason):
		step_signals.append({"signal": "session-stopped", "reason": reason})
	)
	session.hello_received.connect(func(sender_id):
		step_signals.append({"signal": "hello-received", "from": sender_id})
	)
	session.intent_received.connect(func(body, sender_id):
		step_signals.append({"signal": "intent-received", "body": body, "from": sender_id})
	)
	session.input_received.connect(func(body, sender_id):
		step_signals.append({"signal": "input-received", "body": body, "from": sender_id})
	)
	session.snapshot_received.connect(func(body):
		step_signals.append({"signal": "snapshot-received", "body": body})
	)
	session.sequence_gap.connect(func(kind, sender_id, missing):
		step_signals.append(
			{"signal": "sequence-gap", "kind": kind, "from": sender_id, "missing": missing}
		)
	)
	session.transport_gap.connect(func(peer_id, reason):
		step_signals.append({"signal": "transport-gap", "peerId": peer_id, "reason": reason})
	)
	session.rejected.connect(func(reason, sender_id):
		step_signals.append({"signal": "rejected", "reason": reason, "from": sender_id})
	)


## Drives one step. Returns "" on success or a failure description. Also
## performs the action-specific expect* checks that need data only available
## mid-drive (expectAccepted/expectError against the codec decode result,
## expectResult against a send's boolean return) -- expectSends/expectSignals
## are checked uniformly afterwards by the caller.
func _drive(
	action: String,
	step: Dictionary,
	session: CouchSession,
	roster: CouchScriptedRoster,
	transport: CouchScriptedTransport,
	step_signals: Array
) -> String:
	match action:
		"evaluate":
			session.evaluate(int(step.get("at", 0)))
			return ""
		"poll":
			session.poll(int(step.get("at", 0)))
			return ""
		"roster":
			roster.set_players(step.get("players", []))
			session.evaluate(int(step.get("at", 0)))
			return ""
		"stop":
			session.stop(str(step.get("reason", "")))
			return ""
		"peer-ready":
			transport.emit_peer_ready(str(step.get("peerId", "")))
			return ""
		"peer-lost":
			transport.emit_peer_lost(str(step.get("peerId", "")))
			return ""
		"transport-gap":
			transport.emit_transport_gap(str(step.get("peerId", "")), str(step.get("reason", "")))
			return ""
		"recv":
			# CouchSession has no _process and no now_ms parameter on its receive
			# path (_on_envelope_received is a signal callback) -- it relies
			# entirely on the game calling poll(now_ms) every frame to keep its
			# internal clock fresh (see couch_session.gd's D12 header comment).
			# A fixture step's `at` models exactly that: "the game polled with
			# this now_ms, and then this message arrived." Without this, e.g.
			# the host's per-sender hello-reply rate limit would compare
			# against a clock stuck at whatever the last evaluate()/poll() step
			# set it to, not the time this message actually arrives at.
			session.poll(int(step.get("at", 0)))
			var kind := str(step.get("kind", ""))
			var epoch := _resolve_recv_epoch(step.get("epoch", 0), session)
			var seq := int(step.get("seq", 0))
			var body: Dictionary = step.get("body", {})
			var envelope := CouchEnvelope.make(kind, epoch, seq, body)
			var wire := _round_trip(CouchEnvelope.to_json_frame(envelope))
			return _deliver_and_check(wire, str(step.get("from", "")), step, transport, step_signals)
		"recv-frame":
			session.poll(int(step.get("at", 0)))   # see the "recv" branch above
			var encoded := _encode_frame_body(step.get("frame"))
			var wire := _round_trip(encoded)
			return _deliver_and_check(wire, str(step.get("from", "")), step, transport, step_signals)
		"send-intent":
			var body: Dictionary = step.get("body", {})
			var sent := session.send_intent(body)
			if step.has("expectResult") and sent != bool(step["expectResult"]):
				return "expectResult expected %s, got %s" % [bool(step["expectResult"]), sent]
			return ""
		"send-input":
			var body: Dictionary = step.get("body", {})
			var sent := session.send_input(body)
			if step.has("expectResult") and sent != bool(step["expectResult"]):
				return "expectResult expected %s, got %s" % [bool(step["expectResult"]), sent]
			return ""
		"send-snapshot":
			var body: Dictionary = step.get("body", {})
			var sent := session.broadcast_snapshot(body)
			if step.has("expectResult") and sent != bool(step["expectResult"]):
				return "expectResult expected %s, got %s" % [bool(step["expectResult"]), sent]
			return ""
		"assert":
			return _check_assert(step, session)
	return "unhandled action %s" % action


## Common tail of `recv` and `recv-frame`: decode the wire frame exactly as a
## real transport would, check expectError if the codec rejected it, deliver
## to the session if it didn't, then check expectAccepted -- which means "the
## codec accepted it AND the session did not emit `rejected`" uniformly for
## both actions.
func _deliver_and_check(
	wire_frame: Variant,
	from_id: String,
	step: Dictionary,
	transport: CouchScriptedTransport,
	step_signals: Array
) -> String:
	var decoded := CouchEnvelope.from_json_frame(wire_frame)
	var error := str(decoded.get("error", ""))

	if step.has("expectError") and error != str(step["expectError"]):
		return "expectError expected %s, got %s" % [step["expectError"], error]

	var accepted: bool
	if not error.is_empty():
		# Codec-level rejection: the envelope never reaches the session -- a
		# real CouchLobbyTransport swallows it after one push_warning (see
		# lobby_transport.gd _on_lobby_event). No session signal fires.
		accepted = false
	else:
		transport.deliver(decoded["envelope"], from_id)
		accepted = not _contains_signal(step_signals, "rejected")

	if step.has("expectAccepted") and accepted != bool(step["expectAccepted"]):
		return "expectAccepted expected %s, got %s" % [bool(step["expectAccepted"]), accepted]
	return ""


## Simulates the real wire: JSON.stringify then JSON.parse_string, which is
## exactly what every backend's tunnel does (mock_backend's _round_trip,
## local_backend's JSON.stringify) and is what actually coerces every number
## to a double -- not a shortcut in-process call.
func _round_trip(frame: Variant) -> Variant:
	return JSON.parse_string(JSON.stringify(frame))


## Body encoding convention for recv-frame (see this file's header): a
## Dictionary body is real-encoded exactly like the shipped codec would; any
## other type (String, int, missing) is passed through onto the wire
## unencoded, which is how the corpus constructs malformed bodies.
func _encode_frame_body(raw_frame: Variant) -> Variant:
	if not (raw_frame is Dictionary):
		return raw_frame
	var frame: Dictionary = (raw_frame as Dictionary).duplicate(true)
	if frame.has("body") and frame["body"] is Dictionary:
		frame["body"] = Marshalls.raw_to_base64(var_to_bytes(frame["body"]))
	return frame


func _resolve_recv_epoch(value: Variant, session: CouchSession) -> int:
	if value is String:
		if value == "$session":
			return session.epoch
		if value == "$other":
			return (
				OTHER_EPOCH_FALLBACK if session.epoch == OTHER_EPOCH_PRIMARY else OTHER_EPOCH_PRIMARY
			)
	return int(value)


static func _contains_signal(signals: Array, name: String) -> bool:
	for sig in signals:
		if str(sig.get("signal", "")) == name:
			return true
	return false


## Resolves a declared expected scalar into either SKIP_MARKER ("$any", matches
## anything) or a concrete value ("$session" resolves to the driven session's
## LIVE epoch at comparison time; anything else passes through unchanged).
func _resolve_field(expected: Variant, session: CouchSession) -> Variant:
	if expected is String:
		if expected == "$any":
			return SKIP_MARKER
		if expected == "$session":
			return session.epoch
	return expected


func _values_match(expected_raw: Variant, actual: Variant, session: CouchSession) -> bool:
	var expected: Variant = _resolve_field(expected_raw, session)
	if expected is String and expected == SKIP_MARKER:
		return true
	if _is_number(expected) and _is_number(actual):
		return int(expected) == int(actual)
	return expected == actual


## Recursive structural equality with int/float coercion at every leaf.
##
## Godot's native Dictionary/Array `==` does NOT coerce int vs float inside
## nested structures (0 == 0.0 is true as a bare scalar comparison, but a
## Dictionary containing 0 is NOT engine-equal to one containing 0.0) -- and
## every number in a fixture-declared `body` is a float (JSON.parse_string
## always produces float for JSON numbers), while a body that has round-tripped
## through this runner's own to_json_frame/var_to_bytes path may carry ints
## (session-internal Dictionaries such as the hello `slots` map are built with
## real int values). Both sides are semantically identical; only a coercing
## comparison sees that.
func _deep_equal(a: Variant, b: Variant) -> bool:
	if _is_number(a) and _is_number(b):
		return float(a) == float(b)
	if a is Dictionary and b is Dictionary:
		var ad: Dictionary = a
		var bd: Dictionary = b
		if ad.size() != bd.size():
			return false
		for key in ad:
			if not bd.has(key) or not _deep_equal(ad[key], bd[key]):
				return false
		return true
	if a is Array and b is Array:
		var aa: Array = a
		var ba: Array = b
		if aa.size() != ba.size():
			return false
		for i in range(aa.size()):
			if not _deep_equal(aa[i], ba[i]):
				return false
		return true
	return a == b


func _compare_sends(step: Dictionary, sends: Array, session: CouchSession) -> String:
	if not step.has("expectSends"):
		return ""
	var expected: Array = step["expectSends"]
	if expected.size() != sends.size():
		return "expected %d send(s) %s, got %d %s" % [expected.size(), expected, sends.size(), sends]
	for i in range(expected.size()):
		var exp: Dictionary = expected[i]
		var act: Dictionary = sends[i]
		if not _values_match(exp.get("to"), act.get("to"), session):
			return "send[%d].to expected %s, got %s" % [i, exp.get("to"), act.get("to")]
		if not _values_match(exp.get("kind"), act.get("kind"), session):
			return "send[%d].kind expected %s, got %s" % [i, exp.get("kind"), act.get("kind")]
		if exp.has("seq") and not _values_match(exp["seq"], act.get("seq"), session):
			return "send[%d].seq expected %s, got %s" % [i, exp["seq"], act.get("seq")]
		if exp.has("epoch") and not _values_match(exp["epoch"], act.get("epoch"), session):
			return "send[%d].epoch expected %s, got %s" % [i, exp["epoch"], act.get("epoch")]
		if exp.has("body") and not _deep_equal(exp["body"], act.get("body")):
			return "send[%d].body expected %s, got %s" % [i, exp["body"], act.get("body")]
	return ""


func _compare_signals(step: Dictionary, signals: Array, session: CouchSession) -> String:
	if not step.has("expectSignals"):
		return ""
	var expected: Array = step["expectSignals"]
	if expected.size() != signals.size():
		return (
			"expected %d signal(s) %s, got %d %s"
			% [expected.size(), _describe(expected), signals.size(), _describe(signals)]
		)
	for i in range(expected.size()):
		var exp: Dictionary = expected[i]
		var act: Dictionary = signals[i]
		var name: String = str(exp.get("signal", ""))
		if name != str(act.get("signal", "")):
			return "signal[%d] expected %s, got %s" % [i, name, act.get("signal")]
		for field in SIGNAL_FIELDS.get(name, []):
			if not exp.has(field):
				continue
			if field == "body":
				if not _deep_equal(exp["body"], act.get("body")):
					return "signal[%d].body expected %s, got %s" % [i, exp["body"], act.get("body")]
			elif not _values_match(exp[field], act.get(field), session):
				return (
					"signal[%d].%s expected %s, got %s" % [i, field, exp[field], act.get(field)]
				)
	return ""


func _describe(entries: Array) -> String:
	var labels: Array[String] = []
	for entry in entries:
		labels.append(str(entry))
	return "[%s]" % ", ".join(labels)


func _check_assert(step: Dictionary, session: CouchSession) -> String:
	if step.has("active") and session.active != bool(step["active"]):
		return "active expected %s, got %s" % [bool(step["active"]), session.active]
	if step.has("epoch") and session.epoch != int(step["epoch"]):
		return "epoch expected %d, got %d" % [int(step["epoch"]), session.epoch]
	if step.has("epochIsNot") and session.epoch == int(step["epochIsNot"]):
		return "epoch expected to NOT be %d, but it is" % int(step["epochIsNot"])
	if step.has("isHost") and session.is_host != bool(step["isHost"]):
		return "isHost expected %s, got %s" % [bool(step["isHost"]), session.is_host]
	if step.has("localSlot") and session.local_slot != int(step["localSlot"]):
		return "localSlot expected %d, got %d" % [int(step["localSlot"]), session.local_slot]
	if step.has("authorizedPeer") and session.authorized_peer_id != str(step["authorizedPeer"]):
		return (
			"authorizedPeer expected %s, got %s"
			% [step["authorizedPeer"], session.authorized_peer_id]
		)
	if step.has("hostId") and session.host_id != str(step["hostId"]):
		return "hostId expected %s, got %s" % [step["hostId"], session.host_id]
	if step.has("gapCount") and session.gap_count != int(step["gapCount"]):
		return "gapCount expected %d, got %d" % [int(step["gapCount"]), session.gap_count]
	if step.has("rejectedCount") and session.rejected_count != int(step["rejectedCount"]):
		return (
			"rejectedCount expected %d, got %d" % [int(step["rejectedCount"]), session.rejected_count]
		)
	return ""


# --- Schema validation ------------------------------------------------------


func _unknown_keys(step: Dictionary, action: String) -> Array:
	var allowed: Array = COMMON_KEYS + ACTION_KEYS[action]
	return _unknown_keys_for(step, allowed)


static func _unknown_keys_for(data: Dictionary, allowed: Array) -> Array:
	var unknown: Array = []
	for key in data:
		if not key in allowed:
			unknown.append(str(key))
	return unknown


static func _is_number(value: Variant) -> bool:
	return value is int or value is float


func _validate_case_schema(case_data: Dictionary) -> String:
	var unknown := _unknown_keys_for(case_data, CASE_KEYS)
	if not unknown.is_empty():
		return "case keys this runner does not read: %s" % ", ".join(unknown)
	if not case_data.has("name") or not case_data["name"] is String:
		return "case has missing or non-string field 'name'"
	if not case_data.has("tier") or not case_data["tier"] is String:
		return "case has missing or non-string field 'tier'"
	if not case_data["tier"] in TIER_LABELS:
		return "case has unknown tier '%s'" % case_data["tier"]
	if case_data.has("description") and not case_data["description"] is String:
		return "description must be a string"
	if not case_data.has("local") or not case_data["local"] is String:
		return "case has missing or non-string field 'local'"

	if not case_data.has("roster") or not case_data["roster"] is Array:
		return "case has missing or non-array field 'roster'"
	var roster: Array = case_data["roster"]
	for i in range(roster.size()):
		var roster_failure := _validate_roster_entry(roster[i], i)
		if not roster_failure.is_empty():
			return roster_failure
	if not (case_data["local"] as String) in _roster_user_ids(roster):
		return "local player '%s' is not present in roster" % case_data["local"]

	if not case_data.has("steps") or not case_data["steps"] is Array:
		return "case has missing or non-array field 'steps'"
	var steps: Array = case_data["steps"]
	for step_index in range(steps.size()):
		if not steps[step_index] is Dictionary:
			return "step %d must be an object" % step_index
		var step: Dictionary = steps[step_index]
		if not step.has("action") or not step["action"] is String:
			return "step %d: missing or non-string field 'action'" % step_index
		var action: String = step["action"]
		if not ACTION_KEYS.has(action):
			return "step %d: unknown action %s" % [step_index, action]
		unknown = _unknown_keys(step, action)
		if not unknown.is_empty():
			return (
				"step %d (%s): keys this runner does not read: %s -- the fixture asserts something untested"
				% [step_index, action, ", ".join(unknown)]
			)
		var nested_failure := _validate_step_schema(step, step_index, action)
		if not nested_failure.is_empty():
			return nested_failure
	return ""


func _validate_roster_entry(entry: Variant, index: int) -> String:
	if not entry is Dictionary:
		return "roster[%d] must be an object" % index
	var d: Dictionary = entry
	var unknown := _unknown_keys_for(d, ROSTER_PLAYER_KEYS)
	if not unknown.is_empty():
		return "roster[%d] has unknown key(s): %s" % [index, ", ".join(unknown)]
	if not d.has("userId") or not d["userId"] is String:
		return "roster[%d] has missing or non-string field 'userId'" % index
	if not d.has("role") or not (d["role"] in ["host", "guest"]):
		return "roster[%d] has missing or unknown field 'role'" % index
	if d.has("username") and not d["username"] is String:
		return "roster[%d].username must be a string" % index
	if d.has("controllerSlot") and not _is_number(d["controllerSlot"]):
		return "roster[%d].controllerSlot must be numeric" % index
	return ""


static func _roster_user_ids(roster: Array) -> Array:
	var ids: Array = []
	for entry in roster:
		ids.append(entry.get("userId", ""))
	return ids


func _validate_step_schema(step: Dictionary, step_index: int, action: String) -> String:
	var context := "step %d (%s)" % [step_index, action]
	if step.has("at") and not _is_number(step["at"]):
		return "%s: at must be numeric" % context

	match action:
		"recv":
			for field in ["from", "kind", "seq", "epoch"]:
				if not step.has(field):
					return "%s: action requires '%s'" % [context, field]
			if not step["from"] is String:
				return "%s: from must be a string" % context
			if not step["kind"] is String:
				return "%s: kind must be a string" % context
			if not _is_number(step["seq"]):
				return "%s: seq must be numeric" % context
			if step.has("body") and not step["body"] is Dictionary:
				return "%s: body must be an object" % context
		"recv-frame":
			for field in ["from", "frame"]:
				if not step.has(field):
					return "%s: action requires '%s'" % [context, field]
			if not step["from"] is String:
				return "%s: from must be a string" % context
			if step.has("expectError") and not step["expectError"] is String:
				return "%s: expectError must be a string" % context
		"roster":
			if not step.has("players") or not step["players"] is Array:
				return "%s: action requires array field 'players'" % context
			for i in range(step["players"].size()):
				var failure := _validate_roster_entry(step["players"][i], i)
				if not failure.is_empty():
					return "%s: players[%d]: %s" % [context, i, failure]
		"stop":
			if not step.has("reason") or not step["reason"] is String:
				return "%s: action requires string field 'reason'" % context
		"peer-ready", "peer-lost":
			if not step.has("peerId") or not step["peerId"] is String:
				return "%s: action requires string field 'peerId'" % context
		"transport-gap":
			if not step.has("peerId") or not step["peerId"] is String:
				return "%s: action requires string field 'peerId'" % context
			if not step.has("reason") or not step["reason"] is String:
				return "%s: action requires string field 'reason'" % context
		"send-intent", "send-input", "send-snapshot":
			if step.has("body") and not step["body"] is Dictionary:
				return "%s: body must be an object" % context
			if step.has("expectResult") and not step["expectResult"] is bool:
				return "%s: expectResult must be a bool" % context

	if step.has("expectAccepted") and not step["expectAccepted"] is bool:
		return "%s: expectAccepted must be a bool" % context

	if step.has("expectSends"):
		if not step["expectSends"] is Array:
			return "%s: expectSends must be an array" % context
		for i in range(step["expectSends"].size()):
			var entry: Variant = step["expectSends"][i]
			if not entry is Dictionary:
				return "%s: expectSends[%d] must be an object" % [context, i]
			var unknown := _unknown_keys_for(entry, EXPECT_SEND_KEYS)
			if not unknown.is_empty():
				return "%s: expectSends[%d] has unknown key(s): %s" % [context, i, ", ".join(unknown)]
			if not entry.has("to") or not entry["to"] is String:
				return "%s: expectSends[%d] has missing or non-string field 'to'" % [context, i]
			if not entry.has("kind") or not entry["kind"] is String:
				return "%s: expectSends[%d] has missing or non-string field 'kind'" % [context, i]

	if step.has("expectSignals"):
		if not step["expectSignals"] is Array:
			return "%s: expectSignals must be an array" % context
		for i in range(step["expectSignals"].size()):
			var entry: Variant = step["expectSignals"][i]
			if not entry is Dictionary:
				return "%s: expectSignals[%d] must be an object" % [context, i]
			if not entry.has("signal") or not entry["signal"] is String:
				return "%s: expectSignals[%d] has missing or non-string field 'signal'" % [context, i]
			var signal_name: String = entry["signal"]
			if not SIGNAL_FIELDS.has(signal_name):
				return "%s: expectSignals[%d] has unknown signal '%s'" % [context, i, signal_name]
			var unknown := _unknown_keys_for(entry, ["signal"] + SIGNAL_FIELDS[signal_name])
			if not unknown.is_empty():
				return (
					"%s: expectSignals[%d] has unknown key(s) for signal '%s': %s"
					% [context, i, signal_name, ", ".join(unknown)]
				)
	return ""


## Aggregate counts by tier and status, for the summary line.
static func summarize(case_results: Array) -> Dictionary:
	var summary := {}
	for result in case_results:
		if not summary.has(result.tier):
			summary[result.tier] = {"passed": 0, "failed": 0}
		match result.status:
			Status.PASSED:
				summary[result.tier]["passed"] += 1
			Status.FAILED:
				summary[result.tier]["failed"] += 1
	return summary
