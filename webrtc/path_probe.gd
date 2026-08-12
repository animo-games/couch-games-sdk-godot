# Iframe-realm probe for WebRTC candidate-pair state. Web exports only.
#
# Godot's WebRTCPeerConnection has no get_stats(), and the platform has no
# handle on the game's peer connections, which the engine's web glue creates
# inside the game iframe. So this installs a JS wrapper around
# window.RTCPeerConnection BEFORE any connection exists, keeps a WeakRef
# registry, and refreshes a plain-object cache from getStats() on a 1s timer so
# GDScript can read path state synchronously.
#
# Reads go through JavaScriptBridge.eval returning a JSON string, not through
# get_interface()/JavaScriptObject, which shadows Godot Object members
# (disconnect/connect/free/call).
extends RefCounted

static var _installed := false

const _PROBE_JS := """
(function () {
  if (window.__couchPathProbe) { return "already"; }
  var Native = window.RTCPeerConnection;
  if (!Native) { return "no-rtcpeerconnection"; }
  var refs = [];
  var cache = [];
  var generation = 0;
  var publishedGen = 0;
  var events = [];
  var EVENT_CAP = 64;

  // Reflect.construct with new.target keeps derived-class semantics intact
  // (`class Foo extends RTCPeerConnection {}` -> `new Foo() instanceof Foo`);
  // setPrototypeOf inherits static members. Plain `new RTCPeerConnection()`
  // still lands on Native.prototype, because Wrapped.prototype IS it.
  // Connection-state transitions are recorded here rather than sampled from the
  // 1s cache because the cache cannot answer the question they exist for. A
  // connection that dies is dropped from it entirely (see refresh()), so a poll
  // taken afterwards reports "no path" and nothing about how it ended; and the
  // states that matter are transient by definition -- "disconnected" is
  // recoverable per spec, "failed" is not, and telling those apart after the
  // fact is the whole diagnosis. Both are logged: RTCPeerConnection.
  // connectionState is what Godot's WebRTCMultiplayerPeer acts on, while
  // iceConnectionState is what distinguishes a blip from a hard ICE failure.
  //
  // Deliberately NOT gated behind __couchNetPathDebug, unlike the periodic
  // NETPATH line. Transitions are a handful per session, and the reason this
  // exists is a session that died on a build where nobody had thought to turn a
  // debug flag on beforehand.
  function ufragOfDesc(pc) {
    try {
      var d = pc.localDescription;
      if (d && d.sdp) {
        var m = /^a=ice-ufrag:(\\S+)/m.exec(d.sdp);
        if (m) { return m[1]; }
      }
    } catch (e) {}
    return "";
  }

  function recordState(pc, kind) {
    var state = "";
    try {
      state = (kind === "ice" ? pc.iceConnectionState : pc.connectionState) || "";
    } catch (e) { return; }
    var e = {
      ms: Math.round(performance.now()),
      kind: kind, state: state, ufrag: ufragOfDesc(pc)
    };
    events.push(e);
    if (events.length > EVENT_CAP) { events.shift(); }
    try {
      console.log("NETPATH STATE " + kind + "=" + state +
        " ufrag=" + (e.ufrag || "?") + " t=" + e.ms + "ms");
    } catch (err) {}
  }

  function Wrapped(config, constraints) {
    var pc = Reflect.construct(Native, arguments, new.target || Wrapped);
    refs.push(new WeakRef(pc));
    // The shell connection Godot abandons at .new() never leaves "new", so it
    // fires nothing and adds no noise here.
    try {
      pc.addEventListener("connectionstatechange", function () { recordState(pc, "pc"); });
      pc.addEventListener("iceconnectionstatechange", function () { recordState(pc, "ice"); });
    } catch (e) {}
    return pc;
  }
  Wrapped.prototype = Native.prototype;
  Object.setPrototypeOf(Wrapped, Native);
  if (Native.generateCertificate) {
    Wrapped.generateCertificate = Native.generateCertificate.bind(Native);
  }
  window.RTCPeerConnection = Wrapped;
  window.webkitRTCPeerConnection = Wrapped;

  function ufragOf(pc, stats) {
    var fromDesc = ufragOfDesc(pc);
    if (fromDesc) { return fromDesc; }
    var found = "";
    stats.forEach(function (r) {
      if (!found && r.type === "transport" && r.iceLocalUsernameFragment) {
        found = r.iceLocalUsernameFragment;
      }
    });
    return found;
  }

  // transport.selectedCandidatePairId is authoritative per the stats spec and
  // wins outright. The succeeded+nominated scan is only a fallback for reports
  // that have no transport record (or a dangling id): after ICE renomination
  // several pairs can still read succeeded+nominated, and the first one found
  // may be the obsolete one.
  function selectedPair(stats) {
    var transportSel = null;
    stats.forEach(function (r) {
      if (r.type === "transport" && r.selectedCandidatePairId) {
        transportSel = r.selectedCandidatePairId;
      }
    });
    if (transportSel) {
      var sel = null;
      try { sel = stats.get(transportSel); } catch (e) { sel = null; }
      if (sel && sel.type === "candidate-pair") { return sel; }
    }
    var pair = null;
    stats.forEach(function (r) {
      if (pair || r.type !== "candidate-pair") { return; }
      if (r.state === "succeeded" && (r.nominated || r.selected)) { pair = r; }
    });
    return pair;
  }

  function entryFor(pc, stats) {
    var e = {
      ufrag: ufragOf(pc, stats), state: pc.connectionState || "",
      selected: false, protocol: "", relay_protocol: "",
      local_type: "", remote_type: "", is_datagram: false
    };
    var pair = selectedPair(stats);
    if (pair) {
      e.selected = true;
      var lc = stats.get(pair.localCandidateId);
      var rc = stats.get(pair.remoteCandidateId);
      if (lc) {
        e.protocol = lc.protocol || "";
        e.relay_protocol = lc.relayProtocol || "";
        e.local_type = lc.candidateType || "";
        if (!e.ufrag && lc.usernameFragment) { e.ufrag = lc.usernameFragment; }
      }
      if (rc) { e.remote_type = rc.candidateType || ""; }
      e.is_datagram = (e.protocol === "udp") &&
        (e.relay_protocol === "" || e.relay_protocol === "udp");
    }
    return e;
  }

  function refresh() {
    // Generation guard: getStats() batches can resolve out of order, and one
    // batch can outlive the refreshes that follow it, so a batch publishes
    // only if its generation beats the last PUBLISHED one. Comparing against
    // the newest STARTED generation would starve the cache whenever batches
    // outlive the interval, since every batch would find a newer refresh
    // already begun and drop its result. Either way the cache is swapped
    // whole, once per publishing generation, never partially.
    var gen = ++generation;
    var live = [];
    for (var i = 0; i < refs.length; i++) {
      if (refs[i].deref()) { live.push(refs[i]); }
    }
    refs = live;
    // Godot's web glue creates TWO native RTCPeerConnections per Godot
    // WebRTCPeerConnection (one at .new(), one at .initialize()); the
    // abandoned shell stays connectionState "new" with a null
    // localDescription forever and is never GC'd. Drop those and closed ones.
    var next = [];
    for (var j = 0; j < refs.length; j++) {
      var p = refs[j].deref();
      if (!p || p.connectionState === "closed") { continue; }
      if (p.localDescription == null && p.remoteDescription == null) { continue; }
      next.push(p);
    }
    // Synchronous, so gen outranks every generation published so far and this
    // publish is unconditional. Recording it is what stops an older in-flight
    // batch from resurrecting stale entries over the empty cache.
    if (next.length === 0) { publishedGen = gen; cache = []; return; }
    var acc = [];
    var pending = next.length;
    next.forEach(function (pc) {
      pc.getStats().then(function (stats) {
        acc.push(entryFor(pc, stats));
      }).catch(function () {}).then(function () {
        pending -= 1;
        if (pending === 0 && gen > publishedGen) {
          publishedGen = gen;
          cache = acc;
        }
      });
    });
  }

  window.__couchPathProbe = {
    pathsJson: function () { return JSON.stringify(cache); },
    // Survives the connection it describes, which pathsJson() does not.
    statesJson: function () { return JSON.stringify(events); }
  };
  setInterval(refresh, 1000);
  refresh();
  return "installed";
})();
"""

## Install the wrapper. Called once from the CouchGames autoload's _ready(),
## before any game code can create a peer connection. No-op off web.
static func install() -> void:
	if _installed or not OS.has_feature("web"):
		return
	var r: Variant = JavaScriptBridge.eval(_PROBE_JS, true)
	_installed = str(r) in ["installed", "already"]

static func is_available() -> bool:
	return _installed

## Snapshot of live peer connections. Reads a ~1s-stale JS cache; cheap but not
## free (a JSON round-trip), so call at diagnostics rate, never per frame.
static func paths() -> Array:
	if not _installed:
		return []
	var raw: Variant = JavaScriptBridge.eval(
		"window.__couchPathProbe ? window.__couchPathProbe.pathsJson() : \"[]\"", true)
	if raw == null:
		return []
	var parsed: Variant = JSON.parse_string(str(raw))
	return parsed if parsed is Array else []


## Connection-state transitions in order, oldest first, capped at the last 64.
## Each entry: ms (performance.now at the transition), kind ("pc"|"ice"), state,
## ufrag (peer-correlation key, "" before a local description exists). Unlike
## paths(), entries outlive the connection they describe — which is the point,
## since a dead connection leaves paths() empty.
static func state_events() -> Array:
	if not _installed:
		return []
	var raw: Variant = JavaScriptBridge.eval(
		"window.__couchPathProbe ? window.__couchPathProbe.statesJson() : \"[]\"", true)
	if raw == null:
		return []
	var parsed: Variant = JSON.parse_string(str(raw))
	return parsed if parsed is Array else []
