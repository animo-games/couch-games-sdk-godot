## Duck-typed engine seam for a host-authoritative message transport.
##
## Nothing here may reference anything outside netcode/: an implementation lives
## wherever its link does (lobby tunnel today, a WebRTCMultiplayerPeer star in Phase 1),
## and this file must parse in a project that installs neither.
##
## Required methods
##   send_to_authority(envelope: Dictionary) -> bool
##       Deliver to the session authority. On the authority itself this is a no-op that
##       returns false; the authority never talks to itself over the wire.
##   send_to_peer(peer_id: String, envelope: Dictionary) -> bool
##       Deliver to exactly one peer, addressed by its PLATFORM user id (a String).
##   broadcast(envelope: Dictionary) -> bool
##       Deliver to every other participant. Never echoes to the sender.
##   is_ready() -> bool
##       True when the link can carry traffic at all.
##   close() -> void
##       Release the link. Idempotent.
##
## Every send returns "accepted for send", NOT a delivery receipt. There is no
## acknowledgement anywhere in this contract. Delivery is proven only by the peer's
## `seq` advancing at the other end -- that distinction is the whole reason
## `CouchOnlineSession.send_action` returning `true` was a defect.
##
## Required signals
##   envelope_received(envelope: Dictionary, sender_peer_id: String)
##       sender_peer_id is stamped by the LINK, never read out of the envelope.
##   peer_ready(peer_id: String)
##   peer_lost(peer_id: String)
##   transport_gap(peer_id: String, reason: String)
##       The link to this peer was disrupted; continuity is no longer guaranteed and
##       sequence state may be stale. This is a LINK fact, distinct from the SEQUENCE
##       gaps the session derives from `seq` -- see CouchSessionTypes.RecoveryTrigger.
class_name CouchTransport
extends RefCounted

const REQUIRED_METHODS := [
	"send_to_authority",
	"send_to_peer",
	"broadcast",
	"is_ready",
	"close",
]

const REQUIRED_SIGNALS := [
	"envelope_received",
	"peer_ready",
	"peer_lost",
	"transport_gap",
]


static func missing_methods(candidate: Object) -> Array:
	if candidate == null:
		return REQUIRED_METHODS.duplicate()
	var missing: Array = []
	for method_name in REQUIRED_METHODS:
		if not candidate.has_method(method_name):
			missing.append(method_name)
	return missing


static func missing_signals(candidate: Object) -> Array:
	if candidate == null:
		return REQUIRED_SIGNALS.duplicate()
	var missing: Array = []
	for signal_name in REQUIRED_SIGNALS:
		if not candidate.has_signal(signal_name):
			missing.append(signal_name)
	return missing


static func implements(candidate: Object) -> bool:
	return missing_methods(candidate).is_empty() and missing_signals(candidate).is_empty()


static func assert_implements(candidate: Object, role: String = "transport") -> bool:
	var missing: Array = missing_methods(candidate) + missing_signals(candidate)
	if missing.is_empty():
		return true
	push_error("%s does not satisfy CouchTransport: missing %s" % [role, ", ".join(missing)])
	return false
