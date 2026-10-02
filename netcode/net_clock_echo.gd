## HOST-side bookkeeping of the newest input tick received from each peer, and
## the echo the host puts in its snapshot body so the client can measure RTT
## without the input buffer's hold time polluting it.
##
## CONTRACT. note_input() is called for every input the host receives. Only an
## input_tick > the peer's recorded recv_tick updates anything (duplicates and
## older ticks are ignored: recv_tick, hold base and margin stay as they were).
## margin = input_tick - next_host_tick (>= 0 on time, < 0 late); the receive
## time now_ms is stored. late_count(peer) counts accepted-newest inputs whose
## margin was < 0. echo_for() returns {} for an unknown peer, else
## {recv_tick, hold_ms = max(0, now_ms - recv_ms), margin}. forget() drops one
## peer (player_left); reset() drops all (new epoch). Time is always passed in.
##
## Why the echo carries recv_tick + hold_ms rather than the snapshot's ack_tick:
## an input waits in the host's buffer (~ the client's input lead) until its tick
## is simulated, so `now - send(ack_tick)` includes that hold, and the lead is
## itself derived from RTT -- a feedback loop that ratchets the lead upward. The
## newest RECEIVED tick plus the time it was held lets the client subtract the
## hold out (NTP style) and recover the true link RTT.
class_name CouchNetClockEcho
extends RefCounted

const KEY_RECV_TICK := "recv_tick"
const KEY_HOLD_MS := "hold_ms"
const KEY_MARGIN := "margin"


## peer_id -> {"tick": int, "recv_ms": int, "margin": int}
var _peers: Dictionary = {}
var _late: Dictionary = {}


func note_input(peer_id: String, input_tick: int, next_host_tick: int, now_ms: int) -> void:
	var margin: int = input_tick - next_host_tick
	if _peers.has(peer_id) and input_tick <= int(_peers[peer_id]["tick"]):
		return
	_peers[peer_id] = {"tick": input_tick, "recv_ms": now_ms, "margin": margin}
	if margin < 0:
		_late[peer_id] = int(_late.get(peer_id, 0)) + 1


func echo_for(peer_id: String, now_ms: int) -> Dictionary:
	if not _peers.has(peer_id):
		return {}
	var rec: Dictionary = _peers[peer_id]
	return {
		KEY_RECV_TICK: int(rec["tick"]),
		KEY_HOLD_MS: maxi(0, now_ms - int(rec["recv_ms"])),
		KEY_MARGIN: int(rec["margin"]),
	}


func late_count(peer_id: String) -> int:
	return int(_late.get(peer_id, 0))


func forget(peer_id: String) -> void:
	_peers.erase(peer_id)
	_late.erase(peer_id)


func reset() -> void:
	_peers.clear()
	_late.clear()
