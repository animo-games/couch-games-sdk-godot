## Headless test for CouchWebRTCProbe, the preflight "can this machine reach
## anything beyond itself over WebRTC" check.
##
##   godot --headless --path Project -s res://addons/couch-games-sdk/tests/webrtc_probe_test.gd
##
## Real under test: the pure helpers (candidate_type, classify, describe) and
## the async probe() against REAL WebRTCPeerConnections. Nothing is doubled.
## The "unreachable servers" case points STUN and TURN at 127.0.0.1:9 (the
## discard port, nothing listens), which is what a network that drops WebRTC
## looks like from here: host candidates appear, nothing else ever does.
##
## The real-PC cases need a concrete WebRTC implementation. Without one they
## are reported as FAILs, not skipped, matching the netcode gates -- except the
## one assertion that is only true WITHOUT an implementation (probe() answering
## "webrtc-unavailable"), which is the honest branch of a project that never
## installed webrtc_native.
extends SceneTree

const UNREACHABLE := [{
	"urls": ["stun:127.0.0.1:9", "turn:127.0.0.1:9?transport=udp"],
	"username": "u",
	"credential": "c",
}]

var _failed := false


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== CouchWebRTCProbe ==")
	var available := CouchStarTransport.is_webrtc_available()
	print("is_webrtc_available() = %s" % available)

	_check_candidate_type()
	_check_classify()
	_check_describe()
	_check_has_turn()
	if available:
		await _check_no_servers()
		await _check_unreachable_servers()
	else:
		var res: Dictionary = await CouchWebRTCProbe.probe([])
		_expect(res.ok, false, "no implementation: probe([]) is not ok")
		_expect(res.reason, CouchWebRTCProbe.REASON_UNAVAILABLE, "no implementation: probe([]) reason == webrtc-unavailable")
		_expect(false, true, "real-PC probe cases need a WebRTC implementation (FAIL, not skip)")

	print("")
	if _failed:
		printerr("WEBRTC_PROBE_TEST_FAILED")
		quit(1)
	else:
		print("WEBRTC_PROBE_TEST_OK")
		quit(0)
	return


# ---------------------------------------------------------------------------


func _check_candidate_type() -> void:
	_expect(CouchWebRTCProbe.candidate_type("candidate:842163049 1 udp 1677729535 192.168.1.5 54321 typ host generation 0"), "host", "candidate_type: host (candidate: prefix)")
	_expect(CouchWebRTCProbe.candidate_type("a=candidate:842163049 1 udp 1677729535 203.0.113.9 54321 typ srflx raddr 192.168.1.5 rport 54321 generation 0"), "srflx", "candidate_type: srflx (a=candidate: prefix)")
	_expect(CouchWebRTCProbe.candidate_type("842163049 1 udp 41885439 198.51.100.7 61000 typ relay raddr 0.0.0.0 rport 0"), "relay", "candidate_type: relay (no prefix)")
	_expect(CouchWebRTCProbe.candidate_type("candidate:1 1 udp 1 10.0.0.1 9 typ prflx raddr 10.0.0.2 rport 9"), "prflx", "candidate_type: prflx")
	_expect(CouchWebRTCProbe.candidate_type("garbage"), "", "candidate_type: garbage -> empty")
	_expect(CouchWebRTCProbe.candidate_type(""), "", "candidate_type: empty -> empty")
	_expect(CouchWebRTCProbe.candidate_type("candidate:1 1 udp 1 10.0.0.1 9 typ"), "", "candidate_type: truncated after typ -> empty")
	_expect(CouchWebRTCProbe.candidate_type("candidate:1 1 udp 1 10.0.0.1 9 atyp host"), "", "candidate_type: 'typ' inside another token is not the type marker")


func _check_classify() -> void:
	var none := {"host": false, "srflx": false, "relay": false}
	var host_only := {"host": true, "srflx": false, "relay": false}
	var srflx := {"host": true, "srflx": true, "relay": false}
	var relay := {"host": true, "srflx": false, "relay": true}
	_expect(CouchWebRTCProbe.classify(true, none), CouchWebRTCProbe.REASON_NO_CANDIDATES, "classify: nothing + servers -> no-candidates")
	_expect(CouchWebRTCProbe.classify(false, none), CouchWebRTCProbe.REASON_NO_CANDIDATES, "classify: nothing + no servers -> no-candidates")
	_expect(CouchWebRTCProbe.classify(true, host_only), CouchWebRTCProbe.REASON_NO_ROUTE, "classify: host only + servers -> no-route")
	_expect(CouchWebRTCProbe.classify(false, host_only), CouchWebRTCProbe.REASON_OK, "classify: host only + no servers -> ok")
	_expect(CouchWebRTCProbe.classify(true, srflx), CouchWebRTCProbe.REASON_OK, "classify: srflx + servers -> ok")
	_expect(CouchWebRTCProbe.classify(true, relay), CouchWebRTCProbe.REASON_OK, "classify: relay + servers -> ok")


func _check_describe() -> void:
	_expect(CouchWebRTCProbe.describe(CouchWebRTCProbe.REASON_OK), "", "describe: ok -> empty")
	for reason in [CouchWebRTCProbe.REASON_UNAVAILABLE, CouchWebRTCProbe.REASON_NO_CANDIDATES, CouchWebRTCProbe.REASON_NO_ROUTE]:
		_expect(CouchWebRTCProbe.describe(reason).is_empty(), false, "describe: '%s' has a player-facing sentence" % reason)


## has_turn is pure. The STUN-only early exit it enables (break on srflx once no
## TURN URL can ever answer) is NOT tested end to end: that needs a reachable
## STUN server, and faking one here would prove nothing about a real network.
func _check_has_turn() -> void:
	_expect(CouchWebRTCProbe.has_turn([{"urls": "turn:t.example.com:3478"}]), true, "has_turn: string urls")
	_expect(CouchWebRTCProbe.has_turn([{"urls": ["stun:s.example.com", "turn:t.example.com"]}]), true, "has_turn: array urls with turn")
	_expect(CouchWebRTCProbe.has_turn([{"urls": ["stun:s.example.com"]}, {"urls": ["turns:t.example.com:443"]}]), true, "has_turn: stun server plus turns server")
	_expect(CouchWebRTCProbe.has_turn([{"urls": ["stun:s.example.com"]}, {"urls": "stun:s2.example.com"}]), false, "has_turn: stun only")
	_expect(CouchWebRTCProbe.has_turn([]), false, "has_turn: empty list")
	_expect(CouchWebRTCProbe.has_turn([{"url": "turn:t.example.com"}]), true, "has_turn: legacy url key")
	_expect(CouchWebRTCProbe.has_turn([{"urls": "TURN:t.example.com"}]), true, "has_turn: uppercase TURN:")
	_expect(CouchWebRTCProbe.has_turn([{"urls": "stun:turn.example.com"}]), false, "has_turn: 'turn' inside a stun host is not a turn url")


func _check_no_servers() -> void:
	var res: Dictionary = await CouchWebRTCProbe.probe([], 3000)
	print("  (no-servers probe: %s)" % [res])
	_expect(res.ok, true, "no servers: ok")
	_expect(res.reason, "", "no servers: reason empty")
	_expect(res.host, true, "no servers: a host candidate appeared")
	_expect(res.relay, false, "no servers: no relay candidate")
	_expect(res.servers, 0, "no servers: servers == 0")
	_expect(int(res.elapsed_ms) < 3000, true, "no servers: exited early on the host candidate (elapsed %d ms < 3000)" % int(res.elapsed_ms))


func _check_unreachable_servers() -> void:
	var res: Dictionary = await CouchWebRTCProbe.probe(UNREACHABLE, 1500)
	print("  (unreachable probe: %s)" % [res])
	_expect(res.ok, false, "unreachable servers: not ok")
	_expect(res.reason, CouchWebRTCProbe.REASON_NO_ROUTE, "unreachable servers: reason == no-route")
	_expect(res.srflx, false, "unreachable servers: no srflx")
	_expect(res.relay, false, "unreachable servers: no relay")
	_expect(res.servers, 1, "unreachable servers: servers == 1")
	_expect(int(res.elapsed_ms) >= 1500, true, "unreachable servers: ran to the deadline (elapsed %d ms >= 1500)" % int(res.elapsed_ms))


func _expect(actual: Variant, expected: Variant, what: String) -> void:
	if actual == expected:
		print("  PASS: " + what)
		return
	_failed = true
	printerr("  FAIL: %s (expected %s, got %s)" % [what, expected, actual])
