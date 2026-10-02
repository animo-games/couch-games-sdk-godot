## Picks the transport a CouchSession rides on -- ONCE, at boot -- and builds
## it. This is the seam between the SDK's composed pieces (CouchGames.lobby,
## CouchGames.webrtc) and the netcode package, which by design names neither:
## nothing in netcode/ may reference lobby/ or webrtc/, so the one place that
## can hold all three is here, in core/.
##
##   var picked: Dictionary = await CouchSessionTransport.pick(CouchGames.lobby, CouchGames.webrtc)
##   if picked.transport == null:
##       push_error(picked.error)     # refused -- see below; do NOT retry with the other kind
##       if picked.error.begins_with(CouchSessionTransport.ERROR_WEBRTC_BLOCKED):
##           show_message(CouchWebRTCProbe.describe(picked.probe.reason))
##       return
##   var session := CouchSession.new(CouchGames.lobby, picked.transport)
##   ...
##   func _process(_delta):        # every frame, in THIS order
##       picked.transport.poll(Time.get_ticks_msec())
##       session.poll(Time.get_ticks_msec())
##
## THE RULE: every participant must resolve the SAME kind, and the decision is
## never revisited. Two peers on different wires both stay engaged, each sending
## frames the other has no link for, and the session is dead with no error
## anywhere (measured in tower-defense before its adapter learned to refuse).
## So the kind is a function of BUILD-LEVEL facts only -- the preference the
## game passes in, and whether this build has a WebRTC implementation at all
## (CouchStarTransport.is_webrtc_available(), a property of the installed
## addons, identical on every machine running the same build). Nothing that can
## differ between two peers of one lobby -- signaling reachability, a roster
## that has not settled, an ICE failure -- ever changes the kind. Those are
## REFUSALS: a loud push_error, `transport` null, `kind` "none", the reason in
## `error`. The caller may retry pick() with the same preference; it must never
## "try the other one".
##
## The preflight probe is one more refusal, not a fallback. start() only joins
## signaling, so a player whose browser or network blocks WebRTC so thoroughly
## that even TURN fails would otherwise get a star whose links silently time
## out. After start() succeeds, pick() runs CouchWebRTCProbe against the ICE
## servers signaling handed back; if this machine reaches none of them it
## refuses with "webrtc-blocked:<reason>" and the probe result in `probe`. It
## is per-machine, so it can differ between peers of one lobby -- which is
## exactly why it may only refuse: the others resolved the star, and this
## player switching to the tunnel would be the split THE RULE forbids.
##
## PREFER_AUTO is the sensible default: the star when this build can run one,
## the lobby tunnel otherwise. A project that never installs webrtc_native
## (or another WebRTCPeerConnection implementation) lands on the tunnel with
## no configuration and no error. Ship every build of a game with the same
## addons: a web export (whose browser supplies WebRTC) and a desktop export
## without webrtc_native would resolve differently, and that is a split.
##
## Not in netcode/ on purpose, and not on the CouchGames autoload either: a
## static function that takes the lobby and the signaling node as arguments
## can be exercised headless against doubles (tests/session_transport_test.gd),
## which a method reading autoload state could not.
class_name CouchSessionTransport
extends RefCounted

const PREFER_AUTO := "auto"
const PREFER_STAR := "star"
const PREFER_LOBBY := "lobby"

const KIND_STAR := "star"
const KIND_LOBBY := "lobby"
const KIND_NONE := "none"

## Refusal reasons this file mints itself. A star whose start() fails is refused
## with the star's OWN error string ("peer-id-mismatch", the signaling connect
## reason, ...), passed through verbatim.
const ERROR_NO_WEBRTC := "no-webrtc-implementation"
const ERROR_SIGNALING_UNAVAILABLE := "signaling-unavailable"
const ERROR_UNKNOWN_PREFERENCE := "unknown-preference"
## The preflight probe found this machine cannot reach the ICE servers (or
## cannot do WebRTC at all). The refusal error is "webrtc-blocked:<reason>",
## <reason> being a CouchWebRTCProbe REASON_* string; picked.probe has the
## full probe result and CouchWebRTCProbe.describe(reason) a player-facing line.
const ERROR_WEBRTC_BLOCKED := "webrtc-blocked"


## The kind THIS BUILD selects for `prefer`. Pure: a function of the preference
## and of CouchStarTransport.is_webrtc_available(), and nothing else -- see the
## header for why nothing else may enter. KIND_NONE means pick() would refuse
## before building anything.
static func resolve_kind(prefer: String = PREFER_AUTO) -> String:
	match prefer:
		PREFER_LOBBY:
			return KIND_LOBBY
		PREFER_STAR:
			return KIND_STAR if CouchStarTransport.is_webrtc_available() else KIND_NONE
		PREFER_AUTO:
			return KIND_STAR if CouchStarTransport.is_webrtc_available() else KIND_LOBBY
		_:
			return KIND_NONE


## Build the transport resolve_kind() names and, for the star, start it. Always
## `await` this: the star's start() joins signaling and costs real frames, and
## a coroutine returns the same shape on every path.
##
## Returns {"transport": Object|null, "kind": String, "error": String,
## "probe": Dictionary}. `probe` is CouchWebRTCProbe.probe()'s result when the
## star path ran it, and {} on every other path (lobby tunnel, an earlier
## refusal, probe disabled).
## `transport` is ready to hand to CouchSession.new() -- a lobby tunnel needs
## no start; a star has already been started and its is_host/local_net_id are
## latched. On refusal `transport` is null, `kind` is KIND_NONE and `error`
## names why; anything the refused attempt joined has been released
## (star.close() closes the signaling it opened).
##
## `lobby` is duck-typed exactly as the transports and the session type it:
## CouchGames.lobby in a game, a double in a test. `webrtc` is the SDK's
## signaling node (CouchGames.webrtc); it is only touched on the star path.
##
## `probe_timeout_ms` bounds the star's preflight probe; <= 0 skips it.
static func pick(lobby: Object, webrtc: CouchWebRTC, prefer: String = PREFER_AUTO, probe_timeout_ms: int = CouchWebRTCProbe.DEFAULT_TIMEOUT_MS) -> Dictionary:
	var kind := resolve_kind(prefer)
	match kind:
		KIND_LOBBY:
			return _picked(CouchLobbyTransport.new(lobby), KIND_LOBBY)
		KIND_STAR:
			if webrtc == null or not webrtc.is_available:
				# Environment, not build: the backend has no signaling. Every
				# peer of one lobby shares a backend, so this would in fact
				# resolve the same everywhere -- but it is not a BUILD fact,
				# and the rule is one gate, not two. Refuse.
				return _refuse(ERROR_SIGNALING_UNAVAILABLE)
			var source := CouchWebRTCSignalingSource.new(webrtc)
			var star := CouchStarTransport.new(source, lobby)
			var res: Dictionary = await star.start()
			if not bool(res.get("success", false)):
				# start() has already released whatever it joined on its own
				# failure paths (_abort_start); close() on top is idempotent and
				# makes the transport terminal so a stray reference cannot be
				# started later.
				star.close()
				return _refuse(str(res.get("error", "start-failed")))
			var probe: Dictionary = {}
			if probe_timeout_ms > 0:
				# AFTER start(): the ICE servers arrive with the signaling join.
				# close() tears down the star's pre-built guest PC and releases
				# signaling. This refusal is per-machine and NOT a reason to try
				# the lobby tunnel -- the rest of the lobby resolved the star,
				# and this player switching would be the split the header
				# forbids.
				probe = await CouchWebRTCProbe.probe(webrtc.ice_servers, probe_timeout_ms)
				if not bool(probe.get("ok", false)):
					star.close()
					return _refuse("%s:%s" % [ERROR_WEBRTC_BLOCKED, probe.get("reason", "")], probe)
			return _picked(star, KIND_STAR, probe)
		_:
			if prefer == PREFER_STAR:
				return _refuse(ERROR_NO_WEBRTC)
			return _refuse("%s:%s" % [ERROR_UNKNOWN_PREFERENCE, prefer])


static func _picked(transport: Object, kind: String, probe: Dictionary = {}) -> Dictionary:
	return {"transport": transport, "kind": kind, "error": "", "probe": probe}


static func _refuse(error: String, probe: Dictionary = {}) -> Dictionary:
	push_error("CouchSessionTransport: refused (%s) -- no transport constructed" % error)
	return {"transport": null, "kind": KIND_NONE, "error": error, "probe": probe}
