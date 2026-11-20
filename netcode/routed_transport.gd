## A CouchTransport that carries each guest on its own wire: WebRTC (the star)
## or the lobby tunnel, assigned by the host and fixed until the host re-routes
## it between epochs. A guest whose browser or network blocks WebRTC plays over
## the tunnel instead of being refused, and everyone else keeps WebRTC.
## Design: docs/plans/per-link-transport-fallback.md. Gate: G12.
##
## Why it is safe. The star has no guest-to-guest links, so "both ends agree on
## the wire" is a per-link rule, not a per-session one. It holds because ONE
## party (the host) assigns each guest's route, the guest adopts it, and an
## assigned route never changes in place. A frame that arrives on any other wire
## is dropped and reported (`wrong-wire`), so a stray can never double-apply.
##
## The route handshake rides the lobby tunnel, the one wire everyone shares, on
## its own event (ROUTE_EVENT), so CouchSession and the envelope corpus never
## see it:
##   guest -> host  report {v, t:"report", ok, reason}       its probe result
##   host  -> guest query  {v, t:"query"}                     "report again"
##   host  -> guest assign {v, t:"assign", round, route, reason}
##   guest -> host  ack    {v, t:"ack", round, route}
## The tunnel is at-most-once, so the host queries an unreported guest and
## re-sends an unacknowledged assign every RETRY_MS, and a guest answers every
## query. `round` is the host's: minted from `round_seed` (wall-clock ms by
## default) and increased by every assign, so a guest ignores any assign older
## than the one it holds, including one from a host process that has since
## restarted with a newer seed.
##
## How the host picks a guest's route:
##   - `none` under require_datagram when the guest cannot use WebRTC: refused,
##     never tunnelled (a game that cannot live with the tunnel's latency);
##   - `lobby` when the host has no star, the guest's probe failed, or the
##     guest's star link has not come up LINK_DEADLINE after its report;
##   - `star` when the guest's probe passed and its link is up.
##
## Re-routing. A star guest whose link dies for good (`rebuild-exhausted`) is
## queued in pending_reroutes() and announced with reroute_pending; nothing
## moves until the driver calls apply_pending_reroutes() between epochs (stop the
## session, apply, evaluate). Changing a route under a live epoch would be the
## split this file exists to prevent.
##
## Sending. A host sends to each guest on that guest's route only, and only
## once the guest has acknowledged it. Host broadcast() is one send per routed
## guest, never the tunnel's or the star's own broadcast, which would reach
## guests on the other wire. A guest sends only on its own route.
##
## Signals. Envelopes and star facts are forwarded for peers on the matching
## route. Lobby-transport gaps (the away flow's `peer-reconnected`, roster
## rejoins) are forwarded for every peer, because they are facts about the
## player, not the wire: a reloaded star guest must be resynced too.
##
## Duck-typed like the two transports it composes: it names neither lobby/ nor
## webrtc/, and parses in a project that installs neither. `star` may be null
## (no WebRTC in this build, or this machine's probe failed).
class_name CouchRoutedTransport
extends RefCounted

const ROUTE_EVENT := "couch-route"
const PROTOCOL_VERSION := 1
const ROUTE_STAR := "star"
const ROUTE_LOBBY := "lobby"
const ROUTE_NONE := "none"
const ROUTES := [ROUTE_STAR, ROUTE_LOBBY, ROUTE_NONE]
const RETRY_MS := 1000
## How long the host waits for a reported guest's star link before the tunnel.
const DEFAULT_LINK_DEADLINE_MS := 12_000

signal envelope_received(envelope: Dictionary, sender_peer_id: String)
signal peer_ready(peer_id: String)
signal peer_lost(peer_id: String)
signal transport_gap(peer_id: String, reason: String)
## Host: a star guest's link is gone for good and it waits for a re-route.
signal reroute_pending(peer_id: String)
## Guest: the host refused this player (require_datagram and no WebRTC).
signal route_refused(reason: String)

## Guest: the route this player holds ("" until assigned).
var local_route: String:
	get: return _route
## Guest: the host's round for that route (-1 until assigned).
var local_round: int:
	get: return _round
## This machine has a usable star (its build, signaling and probe all allowed it).
var has_star: bool:
	get: return _star != null and _probe_ok
## Why this machine has no star ("" when it has one).
var probe_reason: String:
	get: return _probe_reason

var _lobby: Object
var _tunnel: Object
var _star: Object
var _is_host := false
var _probe_ok := false
var _probe_reason := ""
var _require_datagram := false
var _link_deadline_ms := DEFAULT_LINK_DEADLINE_MS
var _closed := false
var _now_ms := 0

# Host.
var _next_round := 0
var _peers: Dictionary = {}          # guest id -> {route, round, acked, reported, ok, reason, deadline, next_send}
var _star_up: Dictionary = {}        # guest id -> true while its star link is up
var _pending: Dictionary = {}        # guest id -> route it moves to at apply_pending_reroutes()

# Guest.
var _route := ""
var _round := -1
var _reported := false

var _reported_drops: Dictionary = {} # "peer|reason" -> true, flood control
var _stats := {
	"star": {"sent": 0, "received": 0},
	"lobby": {"sent": 0, "received": 0, "bytes_sent": 0},
	"dropped": 0,
}


## `lobby`: CouchLobby or a double (send_event, event_received, players_changed,
## get_players, get_me, get_host, is_host). `tunnel`: a CouchLobbyTransport over
## that lobby. `star`: a started CouchStarTransport, or null.
## Options: probe_ok (default: star != null), probe_reason, require_datagram,
## link_deadline_ms, round_seed (default: wall-clock ms).
func _init(lobby: Object, tunnel: Object, star: Object = null, options: Dictionary = {}) -> void:
	_lobby = lobby
	_tunnel = tunnel
	_star = star
	_is_host = bool(lobby.is_host())
	_probe_ok = bool(options.get("probe_ok", star != null)) and star != null
	_probe_reason = str(options.get("probe_reason", ""))
	_require_datagram = bool(options.get("require_datagram", false))
	_link_deadline_ms = int(options.get("link_deadline_ms", DEFAULT_LINK_DEADLINE_MS))
	_next_round = int(options.get("round_seed", int(Time.get_unix_time_from_system() * 1000.0)))
	lobby.event_received.connect(_on_lobby_event)
	lobby.players_changed.connect(_on_players)
	tunnel.envelope_received.connect(_on_tunnel_envelope)
	tunnel.peer_lost.connect(func(pid: String) -> void: peer_lost.emit(pid))
	tunnel.transport_gap.connect(func(pid: String, reason: String) -> void: transport_gap.emit(pid, reason))
	if star != null:
		star.envelope_received.connect(_on_star_envelope)
		star.peer_ready.connect(_on_star_ready)
		star.peer_lost.connect(_on_star_lost)
		star.transport_gap.connect(_on_star_gap)
	_on_players(lobby.get_players())


# --- CouchTransport --------------------------------------------------------------

func send_to_authority(envelope: Dictionary) -> bool:
	if _is_host or _closed:
		return false
	return _send_on(_route, "", envelope)


func send_to_peer(peer_id: String, envelope: Dictionary) -> bool:
	if _closed:
		return false
	if not _is_host:
		return send_to_authority(envelope) if peer_id == _host_id() else false
	var p: Dictionary = _peers.get(peer_id, {})
	if p.is_empty() or not p["acked"]:
		return false
	return _send_on(p["route"], peer_id, envelope)


func broadcast(envelope: Dictionary) -> bool:
	if _closed:
		return false
	if not _is_host:
		return send_to_authority(envelope)
	var any := false
	for pid in _peers:
		var p: Dictionary = _peers[pid]
		if p["acked"]:
			any = _send_on(p["route"], pid, envelope) or any
	return any


## Host: every guest in the roster holds an acknowledged route (a refused guest
## counts as settled). Guest: this player holds a usable route.
func is_ready() -> bool:
	if _closed:
		return false
	if not _is_host:
		return _route == ROUTE_STAR or _route == ROUTE_LOBBY
	for pid in _peers:
		if not _peers[pid]["acked"] and _peers[pid]["route"] != ROUTE_NONE:
			return false
	return true


func poll(now_ms: int) -> void:
	_now_ms = now_ms
	if _closed:
		return
	if _star != null:
		_star.poll(now_ms)
	_tunnel.poll(now_ms)
	if _is_host:
		_poll_host()
	elif not _reported:
		_send_report()


func close() -> void:
	if _closed:
		return
	_closed = true
	if _lobby.event_received.is_connected(_on_lobby_event):
		_lobby.event_received.disconnect(_on_lobby_event)
	if _lobby.players_changed.is_connected(_on_players):
		_lobby.players_changed.disconnect(_on_players)
	if _star != null:
		_star.close()
	_tunnel.close()


# --- routes ------------------------------------------------------------------------

## Host: the route assigned to `peer_id` ("" while undecided).
func route_for(peer_id: String) -> String:
	return str(_peers.get(peer_id, {}).get("route", ""))


## Host: {peer_id: route} for every routed guest.
func routes() -> Dictionary:
	var out := {}
	for pid in _peers:
		if not str(_peers[pid]["route"]).is_empty():
			out[pid] = _peers[pid]["route"]
	return out


func pending_reroutes() -> Array:
	return _pending.keys()


## Host, between epochs only: move every pending guest to its new route under a
## new round. Returns the guests moved. Stop the session before calling it and
## evaluate after, so the new epoch starts on the new routes.
func apply_pending_reroutes() -> Array:
	var moved: Array = []
	for pid in _pending.keys():
		if _peers.has(pid):
			_assign(pid, _pending[pid], "rebuild-exhausted")
			moved.append(pid)
	_pending.clear()
	return moved


## Frames and tunnel bytes per route, for measuring what the tunnel costs.
func stats() -> Dictionary:
	return _stats.duplicate(true)


# --- host --------------------------------------------------------------------------

func _poll_host() -> void:
	for pid in _peers:
		var p: Dictionary = _peers[pid]
		if not p["reported"]:
			if _now_ms >= int(p["next_send"]):
				_send_route(pid, {"t": "query"})
				p["next_send"] = _now_ms + RETRY_MS
			continue
		if str(p["route"]).is_empty():
			var route := _decide(pid, p)
			if not route.is_empty():
				_assign(pid, route, _route_reason(p))
			continue
		if not p["acked"] and _now_ms >= int(p["next_send"]):
			_send_assign(pid)


func _decide(pid: String, p: Dictionary) -> String:
	var can_star := _star != null and _probe_ok and bool(p["ok"])
	if can_star and _star_up.has(pid):
		return ROUTE_STAR
	if can_star and _now_ms < int(p["deadline"]):
		return ""
	return ROUTE_NONE if _require_datagram else ROUTE_LOBBY


func _route_reason(p: Dictionary) -> String:
	if _star == null or not _probe_ok:
		return "host:" + (_probe_reason if not _probe_reason.is_empty() else "no-webrtc")
	if not bool(p["ok"]):
		return str(p["reason"]) if not str(p["reason"]).is_empty() else "guest-probe-failed"
	return "link-deadline"


func _assign(pid: String, route: String, reason: String) -> void:
	var p: Dictionary = _peers[pid]
	_next_round += 1
	p["route"] = route
	p["round"] = _next_round
	p["acked"] = false
	p["reason"] = reason
	_forget_drops(pid)
	_send_assign(pid)


func _send_assign(pid: String) -> void:
	var p: Dictionary = _peers[pid]
	_send_route(pid, {"t": "assign", "round": p["round"], "route": p["route"], "reason": p["reason"]})
	p["next_send"] = _now_ms + RETRY_MS


func _on_report(pid: String, d: Dictionary) -> void:
	if not _peers.has(pid) or not (d.get("ok") is bool):
		return
	var p: Dictionary = _peers[pid]
	if not str(p["route"]).is_empty():
		# A guest that restarted, or lost our assign: tell it again.
		_send_assign(pid)
		return
	p["reported"] = true
	p["ok"] = d["ok"]
	p["reason"] = str(d.get("reason", ""))
	p["deadline"] = _now_ms + _link_deadline_ms


func _on_ack(pid: String, d: Dictionary) -> void:
	var p: Dictionary = _peers.get(pid, {})
	if p.is_empty() or not _is_whole(d.get("round")) or int(d["round"]) != int(p["round"]) or str(d.get("route")) != p["route"]:
		return
	if p["acked"]:
		return
	p["acked"] = true
	if p["route"] != ROUTE_NONE:
		peer_ready.emit(pid)


func _on_players(rows: Array) -> void:
	if not _is_host or _closed:
		return
	var my_id := _field(_lobby.get_me(), "user_id")
	var present := {}
	for row in rows:
		var pid := _field(row, "user_id")
		if pid.is_empty() or pid == my_id:
			continue
		present[pid] = true
		if not _peers.has(pid):
			_peers[pid] = {"route": "", "round": -1, "acked": false, "reported": false, "ok": false, "reason": "", "deadline": 0, "next_send": 0}
	for pid in _peers.keys():
		if not present.has(pid):
			_peers.erase(pid)
			_pending.erase(pid)
			_forget_drops(pid)


func _on_star_ready(pid: String) -> void:
	if _is_host:
		_star_up[pid] = true
	if _star_route_for(pid):
		peer_ready.emit(pid)


func _on_star_lost(pid: String) -> void:
	_star_up.erase(pid)
	if _star_route_for(pid):
		peer_lost.emit(pid)


func _on_star_gap(pid: String, reason: String) -> void:
	if not _star_route_for(pid):
		return
	if _is_host and reason == "rebuild-exhausted" and not _pending.has(pid):
		_pending[pid] = ROUTE_NONE if _require_datagram else ROUTE_LOBBY
		reroute_pending.emit(pid)
	transport_gap.emit(pid, reason)


# --- guest -------------------------------------------------------------------------

func _send_report() -> void:
	_reported = true
	_send_route("", {"t": "report", "ok": _probe_ok, "reason": _probe_reason})


func _on_assign(d: Dictionary) -> void:
	var raw_round: Variant = d.get("round")
	var route := str(d.get("route", ""))
	if not _is_whole(raw_round) or not (route in ROUTES):
		return
	var r := int(raw_round)
	if r < _round:
		return
	var changed := r != _round or route != _route
	_round = r
	_route = route
	_send_route("", {"t": "ack", "round": r, "route": route})
	if not changed:
		return
	_forget_drops(_host_id())
	if route != ROUTE_STAR and _star != null:
		_star.close()
	if route == ROUTE_NONE:
		route_refused.emit(str(d.get("reason", "")))
	else:
		peer_ready.emit(_host_id())


# --- wire --------------------------------------------------------------------------

func _on_lobby_event(event: String, data: Variant, sender: String) -> void:
	if event != ROUTE_EVENT or _closed or not (data is Dictionary):
		return
	var d: Dictionary = data
	if not _is_whole(d.get("v")) or int(d["v"]) != PROTOCOL_VERSION:
		return
	var t := str(d.get("t", ""))
	if _is_host:
		match t:
			"report": _on_report(sender, d)
			"ack": _on_ack(sender, d)
		return
	if sender != _host_id():
		return
	match t:
		"query": _send_report()
		"assign": _on_assign(d)


func _send_route(pid: String, body: Dictionary) -> void:
	body["v"] = PROTOCOL_VERSION
	var target := {"user_id": pid} if _is_host else {"role": "host"}
	if _lobby.has_method("try_send_event"):
		_lobby.try_send_event(ROUTE_EVENT, body, target)
	else:
		_lobby.send_event(ROUTE_EVENT, body, target)


func _send_on(route: String, pid: String, envelope: Dictionary) -> bool:
	var ok := false
	match route:
		ROUTE_STAR:
			if _star == null:
				return false
			ok = _star.send_to_peer(pid, envelope) if _is_host else _star.send_to_authority(envelope)
			if ok:
				_stats["star"]["sent"] += 1
		ROUTE_LOBBY:
			ok = _tunnel.send_to_peer(pid, envelope) if _is_host else _tunnel.send_to_authority(envelope)
			if ok:
				_stats["lobby"]["sent"] += 1
				_stats["lobby"]["bytes_sent"] += JSON.stringify(CouchEnvelope.to_json_frame(envelope)).length()
	return ok


func _on_star_envelope(envelope: Dictionary, sender: String) -> void:
	_accept(envelope, sender, ROUTE_STAR)


func _on_tunnel_envelope(envelope: Dictionary, sender: String) -> void:
	_accept(envelope, sender, ROUTE_LOBBY)


func _accept(envelope: Dictionary, sender: String, wire: String) -> void:
	if _closed:
		return
	var assigned := ""
	if _is_host:
		assigned = route_for(sender)
	elif sender == _host_id():
		assigned = _route
	if assigned == wire:
		_stats[wire]["received"] += 1
		envelope_received.emit(envelope, sender)
		return
	_stats["dropped"] += 1
	var reason := "unrouted" if assigned.is_empty() else "wrong-wire"
	var key := sender + "|" + reason
	if not _reported_drops.has(key):
		_reported_drops[key] = true
		transport_gap.emit(sender, reason)


func _star_route_for(pid: String) -> bool:
	if _is_host:
		return route_for(pid) == ROUTE_STAR
	return _route == ROUTE_STAR and pid == _host_id()


func _forget_drops(pid: String) -> void:
	for key in _reported_drops.keys():
		if str(key).begins_with(pid + "|"):
			_reported_drops.erase(key)


func _host_id() -> String:
	return _field(_lobby.get_host(), "user_id")


static func _is_whole(value: Variant) -> bool:
	return (value is int) or (value is float and is_finite(value) and value == floor(value))


static func _field(row: Variant, key: String) -> String:
	if row is Dictionary:
		var d: Dictionary = row
		var value: Variant = d.get(key, d.get("userId") if key == "user_id" else null)
		return "" if value == null else str(value)
	if row is Object:
		var value: Variant = row.get(key)
		return "" if value == null else str(value)
	return ""
