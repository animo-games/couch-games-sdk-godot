## Pure static codec for the CouchTransport wire envelope, plus a small per-sender
## receive tracker. No transport knowledge except the explicitly-named JSON framing
## helpers -- nothing here may reference anything outside netcode/.
##
## Wire shape:
##   {
##     "v":     1,                # int, envelope protocol version
##     "epoch": 1754996411123,    # int, host-minted session generation (0 = "unknown",
##                                # hello only)
##     "kind":  "snapshot",       # String, one of KINDS
##     "seq":   17,               # int, monotone per (sender, kind) within this epoch,
##                                # from 1
##     "body":  { ... }           # Dictionary, kind-specific payload
##   }
##
## Sender identity is never in the envelope. The lobby stamps `senderUserId` at the
## server (local_backend.gd:214 -- "senderUserId is stamped from the connection, like
## the real server does, so a guest can't impersonate anyone"); WebRTC derives it from
## the connection. A `from` field would be spoofable and redundant, and would let a
## hostile guest impersonate the host. A frame carrying a `from` key is simply ignored.
##
## `seq` is per-(sender, kind), not per sender. A single per-sender counter cannot
## attribute a hole to a kind, so a dropped `input` -- 30 per second -- would surface as
## an `intent` gap, which makes per-kind loss policy meaningless. Known limitation,
## stated plainly: a TRAILING loss of a kind is only detected when that kind next flows.
## There is no second per-sender counter and no elimination rule -- every verb is
## applied host-side only and the 30 Hz full-world snapshot is ground truth, so a
## dropped `intent` costs the player one re-press and cannot desync.
##
## A sender's OUTGOING counters are NOT reset when it adopts a new epoch, even though
## the wire shape above describes `seq` as running "within this epoch". This is
## deliberate and a port must copy it. A receiver's tracker starts every epoch with
## empty per-kind state, so a monotone-forever sender counter is always accepted. The
## frame that CARRIES the adoption costs nothing: ReceiveTracker.observe records its own
## seq as the new epoch's high-water mark for its kind and reports gap 0, so an exact
## replay of it is a duplicate rather than a second application. The whole residual cost
## is one phantom `sequence_gap` of size seq-1 on the first message of each OTHER kind in
## the new epoch, which is diagnostic only. Resetting the sender to 1 instead would WEDGE
## on the documented epoch-churn residual: a guest that bounces old-epoch/new-epoch would
## restart at 1 against a receiver whose _last_seq is already at N, and every message up
## to N would be dropped as a duplicate.
##
## Relation to the Handshakes wire: Handshakes carries a per-sender request sequence
## (guest -> host) and a total-order authority sequence (host -> all). Here both are
## `seq`: for a guest, `seq` on `intent` IS the request sequence; for the host, `seq` on
## `snapshot` IS the total-order authority sequence, because a session has exactly one
## authority. A Unity adoption transcribes one field instead of two.
##
## Every backend round-trips the lobby tunnel through JSON (mock_backend's
## `_round_trip`, local_backend's `JSON.stringify`, web_backend via JavaScriptBridge),
## so every integer on the wire comes back as a float and every number is a double.
## `epoch` and `seq` are `int()`-coerced on decode and must stay under 2^53-1 to survive
## exactly. Godot types (Vector2, null in arrays) do not survive JSON, so on the lobby
## tunnel the body is base64'd uniformly for every kind -- see `to_json_frame`.
class_name CouchEnvelope
extends RefCounted

const PROTOCOL_VERSION := 1

const KIND_HELLO := "hello"
const KIND_INTENT := "intent"
const KIND_INPUT := "input"
const KIND_SNAPSHOT := "snapshot"
const KIND_RESYNC_REQUEST := "resync-request"     # reserved, Phase 0 does not implement
const KIND_RESYNC_RESPONSE := "resync-response"   # reserved, Phase 0 does not implement

const KINDS := [
	KIND_HELLO, KIND_INTENT, KIND_INPUT, KIND_SNAPSHOT,
	KIND_RESYNC_REQUEST, KIND_RESYNC_RESPONSE,
]
const IMPLEMENTED_KINDS := [KIND_HELLO, KIND_INTENT, KIND_INPUT, KIND_SNAPSHOT]

## Loss policy, per kind and explicit. A gap in one of these is ignorable because the
## next message of the same kind supersedes the lost one outright.
const LATEST_WINS_KINDS := [KIND_INPUT, KIND_SNAPSHOT]

## Only the authority may send these; only a participant may send those.
## `hello` is deliberately in neither -- it travels both ways.
const AUTHORITY_KINDS := [KIND_SNAPSHOT, KIND_RESYNC_RESPONSE]
const PARTICIPANT_KINDS := [KIND_INTENT, KIND_INPUT, KIND_RESYNC_REQUEST]

const KEY_VERSION := "v"
const KEY_EPOCH := "epoch"
const KEY_KIND := "kind"
const KEY_SEQ := "seq"
const KEY_BODY := "body"

const UNKNOWN_EPOCH := 0
## 2^53-1. Every backend round-trips through JSON (and through JS doubles on web), so a
## larger integer would not survive the trip exactly.
const MAX_SAFE_INT := 9007199254740991
## Hard ceiling on an encoded body. The platform tunnel has NO size bound
## (signaling-object.ts lobby-tunnel-event), so the client is the only place this can be
## enforced, and it is enforced BEFORE base64 decoding so a hostile frame cannot force a
## large allocation.
const MAX_FRAME_BODY_CHARS := 262144


static func make(kind: String, epoch: int, seq: int, body: Dictionary) -> Dictionary:
	return {
		KEY_VERSION: PROTOCOL_VERSION,
		KEY_EPOCH: epoch,
		KEY_KIND: kind,
		KEY_SEQ: seq,
		KEY_BODY: body,
	}


static func gap_is_ignorable(kind: String) -> bool:
	return kind in LATEST_WINS_KINDS


static func is_authority_kind(kind: String) -> bool:
	return kind in AUTHORITY_KINDS


static func is_participant_kind(kind: String) -> bool:
	return kind in PARTICIPANT_KINDS


static func is_implemented(kind: String) -> bool:
	return kind in IMPLEMENTED_KINDS


## Frame an envelope for a JSON-only tunnel. Transport-specific ON PURPOSE -- the name
## says so. A binary transport (Phase 1) calls var_to_bytes(envelope) instead and pays
## neither the base64 nor the JSON tax.
##
## Body is base64'd uniformly for every kind. Rationale: a snapshot body carries
## Vector2s and nulls, which JSON destroys; branching per kind would create a class of
## "this kind quietly lost its Vector2" bugs. The cost on the hot path is the *existing*
## cost -- today's snapshot is already var_to_bytes -> base64 -- and on an `input` it is
## about +20 bytes on a ~60-byte message. The header stays JSON-plain so a wire dump is
## readable and the receiver validates the header before decoding anything.
static func to_json_frame(envelope: Dictionary) -> Dictionary:
	return {
		KEY_VERSION: envelope.get(KEY_VERSION, PROTOCOL_VERSION),
		KEY_EPOCH: envelope.get(KEY_EPOCH, UNKNOWN_EPOCH),
		KEY_KIND: envelope.get(KEY_KIND, ""),
		KEY_SEQ: envelope.get(KEY_SEQ, 0),
		KEY_BODY: Marshalls.raw_to_base64(var_to_bytes(envelope.get(KEY_BODY, {}))),
	}


## Decode and VALIDATE a frame off a JSON-only tunnel.
## Returns {"envelope": Dictionary, "error": String}. `error` empty means accepted.
## Never raises; never returns a partially-populated envelope alongside an error.
##
## Rejects, in order, each with a distinct `error` string:
##   1. `frame` is not a Dictionary                                   -> "not-a-dictionary"
##   2. `v` missing / not int-or-float / int(v) != PROTOCOL_VERSION   -> "bad-version"
##   3. `kind` missing / not a String / not in KINDS                  -> "unknown-kind"
##   4. `epoch` missing / not int-or-float / out of [0, MAX_SAFE_INT] -> "bad-epoch"
##   5. `seq` missing / not int-or-float / out of [1, MAX_SAFE_INT]   -> "bad-seq"
##   6. `body` not a String                                           -> "bad-body"
##   7. body.length() > MAX_FRAME_BODY_CHARS (checked before decoding) -> "oversized-body"
##   8. Marshalls.base64_to_raw(body) empty while body non-empty      -> "undecodable-body"
##   9. bytes_to_var(bytes) not a Dictionary                          -> "bad-body"
##
## Unknown *extra* top-level keys are ignored, not rejected: `v` already gates
## compatibility, and rejecting extras would only turn an additive change into a hard
## failure without catching anything `v` does not.
##
## bytes_to_var() is the object-disallowing decoder; its with-objects variant (the
## sibling API that deserialises encoded Objects) is intentionally never used here, and
## its name deliberately does not appear anywhere in this package. This is the single
## most security-critical line in the package.
static func from_json_frame(frame: Variant) -> Dictionary:
	if not (frame is Dictionary):
		return {"envelope": {}, "error": "not-a-dictionary"}
	var f: Dictionary = frame

	var v: Variant = f.get(KEY_VERSION)
	if not _is_number(v) or int(v) != PROTOCOL_VERSION:
		return {"envelope": {}, "error": "bad-version"}

	var kind: Variant = f.get(KEY_KIND)
	if not (kind is String) or not (kind in KINDS):
		return {"envelope": {}, "error": "unknown-kind"}

	var epoch_v: Variant = f.get(KEY_EPOCH)
	if not _is_number(epoch_v):
		return {"envelope": {}, "error": "bad-epoch"}
	var epoch: int = int(epoch_v)
	if epoch < 0 or epoch > MAX_SAFE_INT:
		return {"envelope": {}, "error": "bad-epoch"}

	var seq_v: Variant = f.get(KEY_SEQ)
	if not _is_number(seq_v):
		return {"envelope": {}, "error": "bad-seq"}
	var seq: int = int(seq_v)
	if seq < 1 or seq > MAX_SAFE_INT:
		return {"envelope": {}, "error": "bad-seq"}

	var body_v: Variant = f.get(KEY_BODY)
	if not (body_v is String):
		return {"envelope": {}, "error": "bad-body"}
	var body_str: String = body_v

	if body_str.length() > MAX_FRAME_BODY_CHARS:
		return {"envelope": {}, "error": "oversized-body"}

	var raw := Marshalls.base64_to_raw(body_str)
	if raw.is_empty() and not body_str.is_empty():
		return {"envelope": {}, "error": "undecodable-body"}

	var decoded: Variant = bytes_to_var(raw)
	if not (decoded is Dictionary):
		return {"envelope": {}, "error": "bad-body"}

	var envelope := {
		KEY_VERSION: PROTOCOL_VERSION,
		KEY_EPOCH: epoch,
		KEY_KIND: (kind as String),
		KEY_SEQ: seq,
		KEY_BODY: decoded,
	}
	return {"envelope": envelope, "error": ""}


static func _is_number(value: Variant) -> bool:
	return value is int or value is float


## One per remote sender. Owns the epoch and the per-kind sequence counters.
class ReceiveTracker extends RefCounted:
	var epoch: int = CouchEnvelope.UNKNOWN_EPOCH
	var _last_seq: Dictionary = {}   # kind -> int


	func reset(new_epoch: int) -> void:
		epoch = new_epoch
		_last_seq.clear()


	func forget() -> void:
		epoch = CouchEnvelope.UNKNOWN_EPOCH
		_last_seq.clear()


	## Classify one decoded envelope.
	## `adopt_new_epoch` is the ROLE policy:
	##   guest -> true  : the host is the sole epoch authority, so any epoch different
	##                    from the tracked one is adopted and resets ALL sequence state.
	##   host  -> false : guests must echo the session epoch; a mismatch is rejected,
	##                    which also cheaply evicts a guest left over from a dead session.
	## Returns {"accept": bool, "reset": bool, "duplicate": bool, "gap": int,
	##          "reason": String}
	func observe(envelope: Dictionary, adopt_new_epoch: bool) -> Dictionary:
		var env_epoch: int = int(envelope.get(CouchEnvelope.KEY_EPOCH, CouchEnvelope.UNKNOWN_EPOCH))
		var kind: String = str(envelope.get(CouchEnvelope.KEY_KIND, ""))
		var seq: int = int(envelope.get(CouchEnvelope.KEY_SEQ, 0))

		if env_epoch != epoch:
			if adopt_new_epoch:
				reset(env_epoch)
				# Record this frame's seq as the new epoch's high-water mark for
				# its kind. Without it the tracker stays at 0 for that kind and
				# an exact REPLAY of this very frame is accepted a second time
				# (and, for seq > 1, reported as a phantom gap of seq-1); only a
				# third copy is finally rejected as a duplicate. gap stays 0: the
				# epoch is new, so there is no hole behind this frame.
				_last_seq[kind] = seq
				return {"accept": true, "reset": true, "duplicate": false, "gap": 0, "reason": ""}
			return {"accept": false, "reset": false, "duplicate": false, "gap": 0, "reason": "epoch-mismatch"}

		var last: int = int(_last_seq.get(kind, 0))
		if seq <= last:
			return {"accept": false, "reset": false, "duplicate": true, "gap": 0, "reason": "duplicate"}

		# Covers both "seq == last + 1" (gap 0) and "seq > last + 1" (a real hole) --
		# the session decides whether to surface a nonzero gap, via gap_is_ignorable(kind).
		var gap: int = seq - last - 1
		_last_seq[kind] = seq
		return {"accept": true, "reset": false, "duplicate": false, "gap": gap, "reason": ""}
