## Two-sided fake CouchLobby, used ONLY by the fault-injection acceptance test
## (netcode/fixtures/run_transport_faults.gd). It exists so that test can put a
## REAL CouchLobbyTransport on a real send path -- testing the transport's
## fault injector against a fake transport would prove nothing about the real
## lobby path.
##
## Presents exactly the duck contract CouchLobbyTransport requires:
##   send_event(event: String, data: Variant, target: Dictionary) -> void
##   signal event_received(event: String, data: Variant, sender_user_id: String)
##   signal players_changed(players: Array)
##   an `is_available` property, read via `.get("is_available")`
##
## Two real-server behaviours are reproduced deliberately, because they are
## exactly what this test needs to exercise honestly:
##   - a sender never receives its own event back. Every real backend relays
##     to OTHER participants only (mock_backend, local_backend, web_backend
##     all exclude the sender).
##   - every payload crosses a REAL JSON round trip
##     (JSON.parse_string(JSON.stringify(data))), because every real backend
##     does exactly that on the wire (mock_backend's `_round_trip`,
##     local_backend's `JSON.stringify` over the loopback socket, web_backend
##     across JavaScriptBridge). This is what turns an int into a float on
##     the way across -- the exact class of bug CouchEnvelope's int()
##     coercion on `epoch`/`seq` exists to survive. A double that skipped the
##     round trip would hide that class of bug rather than exercise it.
##
## Not a general N-party lobby double: link() cross-wires exactly two
## instances, each standing in for one participant's tunnel endpoint. Target
## filtering ({"role": "host"}, {"user_id": "<id>"}, or {} for broadcast) is
## the real rule, just with only one possible recipient on the other end of
## the link.
##
## No class from outside netcode/ is referenced here (rule: nothing outside
## netcode/ is nameable at parse time from inside it).
class_name CouchScriptedLobby
extends RefCounted

signal event_received(event: String, data: Variant, sender_user_id: String)
signal players_changed(players: Array)

var is_available: bool = true

var user_id: String = ""
var is_host_role: bool = false

var _other: CouchScriptedLobby = null


func _init(p_user_id: String, p_is_host_role: bool) -> void:
	user_id = p_user_id
	is_host_role = p_is_host_role


## Cross-wire two lobby doubles so each one's send_event reaches the other's
## event_received (and only the other's -- a sender never hears its own
## event).
static func link(a: CouchScriptedLobby, b: CouchScriptedLobby) -> void:
	a._other = b
	b._other = a


## Part of CouchLobbyTransport.REQUIRED_LOBBY_METHODS -- the real CouchLobby
## exposes is_host() the same way, and the transport reads it to satisfy
## send_to_authority's authority-side no-op contract.
func is_host() -> bool:
	return is_host_role


func send_event(event: String, data: Variant, target: Dictionary) -> void:
	if _other == null or not is_available:
		return
	if not _target_matches(target, _other):
		return
	# Real JSON round trip, exactly like mock/local/web backends. This is what
	# turns an int into a float on the wire.
	var wire: Variant = JSON.parse_string(JSON.stringify(data))
	_other.event_received.emit(event, wire, user_id)


func _target_matches(target: Dictionary, recipient: CouchScriptedLobby) -> bool:
	if target.is_empty():
		return true
	if target.has("role"):
		if str(target["role"]) == "host":
			return recipient.is_host_role
		return false
	if target.has("user_id"):
		return str(target["user_id"]) == recipient.user_id
	return true
