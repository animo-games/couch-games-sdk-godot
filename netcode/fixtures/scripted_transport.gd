## Duck-typed CouchTransport double for the transport/session fixture corpus.
##
## Every send is logged verbatim -- the RAW envelope Dictionary CouchSession
## handed over, BEFORE any wire encoding -- so a case can assert exactly what
## the session tried to send, independent of transport-specific framing.
## `deliver`/`deliver_frame` inject a receive by emitting `envelope_received`
## exactly as a real link would, with the sender id supplied by the CALLER,
## never read out of the envelope -- matching D6 (sender identity is never in
## the envelope). `reset_log()` is called by the runner before every step so
## `expectSends` compares only what happened DURING that step, the same
## per-step-log-clear discipline the prediction corpus's shared_log uses.
##
## This is the corpus's HAPPY-PATH double: it never drops or reorders a send.
## The fault-injecting double is the REAL CouchLobbyTransport driven over
## CouchScriptedLobby (see run_transport_faults.gd, slice 5) -- nothing here
## duplicates that; this file must parse in a project that installs neither
## `lobby/` nor `webrtc/`.
class_name CouchScriptedTransport
extends RefCounted

signal envelope_received(envelope: Dictionary, sender_peer_id: String)
signal peer_ready(peer_id: String)
signal peer_lost(peer_id: String)
signal transport_gap(peer_id: String, reason: String)

## Array[Dictionary]: {"to": "authority"|"broadcast"|"peer:<id>", "kind", "seq",
## "epoch", "body"} -- one entry per send call, in call order.
var sends: Array = []
var closed: bool = false


func send_to_authority(envelope: Dictionary) -> bool:
	_log("authority", envelope)
	return true


func send_to_peer(peer_id: String, envelope: Dictionary) -> bool:
	_log("peer:%s" % peer_id, envelope)
	return true


func broadcast(envelope: Dictionary) -> bool:
	_log("broadcast", envelope)
	return true


func is_ready() -> bool:
	return not closed


func close() -> void:
	closed = true


## Clear the send log. Called by the runner at the start of every step.
func reset_log() -> void:
	sends.clear()


## Inject a receive as if it arrived over the link. `sender_peer_id` is stamped
## by the transport, exactly like a real link stamps it from the connection --
## never read out of `envelope` itself.
func deliver(envelope: Dictionary, sender_peer_id: String) -> void:
	envelope_received.emit(envelope, sender_peer_id)


func emit_peer_ready(peer_id: String) -> void:
	peer_ready.emit(peer_id)


func emit_peer_lost(peer_id: String) -> void:
	peer_lost.emit(peer_id)


func emit_transport_gap(peer_id: String, reason: String) -> void:
	transport_gap.emit(peer_id, reason)


func _log(to: String, envelope: Dictionary) -> void:
	sends.append({
		"to": to,
		"kind": envelope.get(CouchEnvelope.KEY_KIND, ""),
		"seq": envelope.get(CouchEnvelope.KEY_SEQ, 0),
		"epoch": envelope.get(CouchEnvelope.KEY_EPOCH, 0),
		"body": envelope.get(CouchEnvelope.KEY_BODY, {}),
	})
