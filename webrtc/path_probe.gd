# Iframe-realm probe for WebRTC candidate-pair state. Web exports only.
#
# Godot's WebRTCPeerConnection has no get_stats(), and the platform has no
# handle on the game's peer connections (they're created by the engine's web
# glue inside the game iframe). This installs a JS wrapper around
# window.RTCPeerConnection BEFORE any connection is created, keeps a WeakRef
# registry, and refreshes a plain-object cache from getStats() on a 1s timer
# so GDScript can read path state synchronously.
#
# Read via JavaScriptBridge.eval returning a JSON string — deliberately NOT
# via get_interface()/JavaScriptObject, which shadows Godot Object members
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

  // Reflect.construct with new.target keeps derived-class semantics intact
  // (`class Foo extends RTCPeerConnection {}` -> `new Foo() instanceof Foo`);
  // setPrototypeOf inherits static members. Plain `new RTCPeerConnection()`
  // still lands on Native.prototype because Wrapped.prototype IS it.
  function Wrapped(config, constraints) {
    var pc = Reflect.construct(Native, arguments, new.target || Wrapped);
    refs.push(new WeakRef(pc));
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
    try {
      var d = pc.localDescription;
      if (d && d.sdp) {
        var m = /^a=ice-ufrag:(\\S+)/m.exec(d.sdp);
        if (m) { return m[1]; }
      }
    } catch (e) {}
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
    // Generation guard: getStats() batches can resolve out of order, and a
    // batch can outlive the refreshes that follow it, so a batch publishes
    // only when its generation is newer than the last PUBLISHED one.
    // Comparing against the newest STARTED generation instead would starve
    // the cache whenever batches outlive the interval: each batch would find
    // a newer refresh already begun and drop its result, forever. The cache
    // is still swapped whole, exactly once per publishing generation, never
    // partially.
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

  window.__couchPathProbe = { pathsJson: function () { return JSON.stringify(cache); } };
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

## Snapshot of live peer connections. Reads a ~1s-stale JS cache; cheap but
## not free (a JSON round-trip) — call at diagnostics rate, never per frame.
static func paths() -> Array:
	if not _installed:
		return []
	var raw: Variant = JavaScriptBridge.eval(
		"window.__couchPathProbe ? window.__couchPathProbe.pathsJson() : \"[]\"", true)
	if raw == null:
		return []
	var parsed: Variant = JSON.parse_string(str(raw))
	return parsed if parsed is Array else []
