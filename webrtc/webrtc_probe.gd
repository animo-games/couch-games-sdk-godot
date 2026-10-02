## Preflight: can THIS machine open a WebRTC peer connection and reach the
## configured STUN/TURN servers?
##
## It opens a throwaway WebRTCPeerConnection with a negotiated data channel
## (an offer with no m-line gathers nothing), creates an offer, and watches
## which ICE candidate TYPES gather before a deadline:
##   host   -- a local interface address. Proves the peer connection works.
##   srflx  -- the STUN server answered: UDP to the outside world works.
##   relay  -- a TURN allocation SUCCEEDED. The best evidence there is.
##
## What a pass proves: this machine can create a peer connection and, when
## ICE servers are configured, reach at least one of them.
## What it does NOT prove: that the remote peer is reachable, or that a TURN
## allocation that succeeds also carries data through deep-packet-inspection
## (rare). A pass is "not obviously blocked", not "will connect".
##
## Why it exists: CouchStarTransport.start() only joins SIGNALING, so it
## succeeds for a player whose browser or network blocks WebRTC so thoroughly
## that even TURN fails -- and that player's links then time out silently.
## CouchSessionTransport.pick() runs this probe so such a player is refused
## early and clearly, as a per-machine refusal like every other (never a
## fallback to the lobby tunnel; see that file's header).
##
## Web exports: CouchStarTransport.is_webrtc_available() reflects Godot's
## browser-backed class, not whether this browser permits RTCPeerConnection.
## It is believed true regardless of browser support (NOT yet verified on a web
## build), and this probe is what catches a browser with WebRTC disabled.
##
## Lives in webrtc/ and so must not depend on netcode/: the availability check
## below is an inline copy of CouchStarTransport.is_webrtc_available().
class_name CouchWebRTCProbe
extends RefCounted

const DEFAULT_TIMEOUT_MS := 5000

## No implementation, or a peer connection that could not be built / produce an
## offer before the deadline.
const REASON_UNAVAILABLE := "webrtc-unavailable"
## Not a single ICE candidate of any type gathered.
const REASON_NO_CANDIDATES := "no-candidates"
## ICE servers were configured and neither a srflx nor a relay candidate
## appeared: nothing beyond the local network was reached.
const REASON_NO_ROUTE := "no-route"
const REASON_OK := ""

static var _candidate_re: RegEx = null


## The token after " typ " in an ICE candidate line ("host", "srflx", "prflx",
## "relay"), or "" when absent. Accepts the line with or without a leading
## "a=" / "candidate:" prefix.
static func candidate_type(candidate: String) -> String:
	if _candidate_re == null:
		_candidate_re = RegEx.new()
		_candidate_re.compile("\\styp\\s+([A-Za-z]+)")
	var m := _candidate_re.search(candidate)
	if m == null:
		return ""
	return m.get_string(1)


## Verdict for what was seen. `seen` has bool keys host, srflx, relay. srflx
## without relay is OK: TURN is unreachable but UDP/STUN works and a direct
## path may still form (the probe result exposes `relay` for a stricter game).
static func classify(servers_configured: bool, seen: Dictionary) -> String:
	var host := bool(seen.get("host", false))
	var srflx := bool(seen.get("srflx", false))
	var relay := bool(seen.get("relay", false))
	if not host and not srflx and not relay:
		return REASON_NO_CANDIDATES
	if servers_configured and not srflx and not relay:
		return REASON_NO_ROUTE
	return REASON_OK


## A short player-facing sentence for a failure reason; "" for REASON_OK.
static func describe(reason: String) -> String:
	match reason:
		REASON_UNAVAILABLE:
			return "Your browser has real-time connections (WebRTC) turned off, so you can't join this game. Try another browser or turn off extensions that block WebRTC."
		REASON_NO_ROUTE:
			return "Your network is blocking the connection to the game. Try a different network, such as mobile data instead of a work or school network."
		REASON_NO_CANDIDATES:
			return "Your device couldn't set up a real-time connection to the game. Try a different network or browser."
		_:
			return ""


## True if any server lists a turn:/turns: URL (case-insensitive). `urls` may be
## a String or an Array of Strings; the legacy `url` key is accepted too. When
## false, no relay candidate can ever appear, so the probe need not wait for one.
static func has_turn(ice_servers: Array) -> bool:
	for server in ice_servers:
		if not (server is Dictionary):
			continue
		for key in ["urls", "url"]:
			var urls: Variant = server.get(key, [])
			var list: Array = urls if urls is Array else [urls]
			for u in list:
				var lower := str(u).strip_edges().to_lower()
				if lower.begins_with("turn:") or lower.begins_with("turns:"):
					return true
	return false


## Run the probe. Always `await` it. Returns
## {"ok", "reason", "host", "srflx", "relay", "servers", "elapsed_ms"} on every
## path. `ice_servers` is in WebRTCPeerConnection.initialize() "iceServers"
## format (CouchWebRTC.ice_servers already is).
static func probe(ice_servers: Array, timeout_ms: int = DEFAULT_TIMEOUT_MS) -> Dictionary:
	var started := Time.get_ticks_msec()
	# Everything mutated inside a lambda lives in this Dictionary: a lambda
	# captures primitive locals BY VALUE, so a plain bool would never change.
	var state := {"host": false, "srflx": false, "relay": false, "offered": false, "any": false}
	var servers := ice_servers.size()

	# Inline copy of CouchStarTransport.is_webrtc_available() -- webrtc/ must
	# not depend on netcode/. Keep the two in step.
	var pc := WebRTCPeerConnection.new()
	if pc.get_class() == "WebRTCPeerConnectionExtension":
		return _result(REASON_UNAVAILABLE, state, servers, started)

	if pc.initialize({"iceServers": ice_servers}) != OK \
			or pc.create_data_channel("probe", {"negotiated": true, "id": 0}) == null:
		pc.close()
		return _result(REASON_UNAVAILABLE, state, servers, started)

	var on_desc := func(type: String, sdp: String) -> void:
		state["offered"] = true
		pc.set_local_description(type, sdp)
	var on_cand := func(_media: String, _index: int, name: String) -> void:
		state["any"] = true
		var t := candidate_type(name)
		if t == "prflx":
			t = "srflx"
		if t == "host" or t == "srflx" or t == "relay":
			state[t] = true
	pc.session_description_created.connect(on_desc)
	pc.ice_candidate_created.connect(on_cand)

	if pc.create_offer() != OK:
		_release(pc, on_desc, on_cand)
		return _result(REASON_UNAVAILABLE, state, servers, started)

	var tree := Engine.get_main_loop() as SceneTree
	var turn_possible := has_turn(ice_servers)
	var deadline := started + maxi(timeout_ms, 0)
	while Time.get_ticks_msec() < deadline:
		await tree.process_frame
		pc.poll()
		# Best evidence: a TURN allocation succeeded. With no servers there is
		# nothing further to wait for once anything has gathered. srflx alone
		# does not exit early when a TURN URL is configured: give TURN the
		# chance to answer so `relay` is reported truthfully. With NO TURN URL
		# nothing better than srflx can arrive, so srflx ends the wait.
		if servers > 0 and state["relay"]:
			break
		if servers > 0 and not turn_possible and state["srflx"]:
			break
		if servers == 0 and state["any"]:
			break

	_release(pc, on_desc, on_cand)
	if not state["offered"]:
		return _result(REASON_UNAVAILABLE, state, servers, started)
	return _result(classify(servers > 0, state), state, servers, started)


## The lambdas capture `pc` and `pc` holds them: break the cycle or the
## connection leaks.
static func _release(pc: WebRTCPeerConnection, on_desc: Callable, on_cand: Callable) -> void:
	pc.session_description_created.disconnect(on_desc)
	pc.ice_candidate_created.disconnect(on_cand)
	pc.close()


static func _result(reason: String, state: Dictionary, servers: int, started: int) -> Dictionary:
	var res := {
		"ok": reason == REASON_OK,
		"reason": reason,
		"host": bool(state["host"]),
		"srflx": bool(state["srflx"]),
		"relay": bool(state["relay"]),
		"servers": servers,
		"elapsed_ms": Time.get_ticks_msec() - started,
	}
	var line := "CouchWebRTCProbe: %s host=%s srflx=%s relay=%s servers=%d in %dms" % [
		"ok" if res.ok else "FAILED (%s)" % reason, res.host, res.srflx, res.relay, servers, res.elapsed_ms]
	if res.ok and servers > 0 and not res.relay:
		push_warning(line + " -- TURN unreachable; direct paths only")
	else:
		print(line)
	return res
