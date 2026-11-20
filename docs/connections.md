# Connections: drops, away and restarts

How a Couch game should behave when a player's connection drops, when a player
reloads, and when players come and go mid-game. It covers what the platform does
for you, what the SDK does for you, and what your game still has to do.

This guide grows as the standard connection work lands. Each section says what
works today. "Coming" notes mark the parts the SDK will take over later, so you
know which code of yours is temporary.

## What players see on Couch

The platform owns the running game (platform decision 0078):

- **Away is not leaving.** A locked phone, a reload or a network drop makes a
  player *away*. Pressing Leave, or going to another page, is leaving.
- **Away for 60 seconds is leaving the room.** The same limit applies to host and guest.
- **The host away:** after 10 quiet seconds the platform covers the guest's game
  with "<host>'s away" and a Leave button, and lifts the cover when the host is back.
- **A guest away:** the host keeps playing. After 10 seconds the host sees a
  "<name>'s away" notice.
- **Someone leaves:** a game ends for everyone when a player it needs has left.
  The host is always needed. A guest is needed unless your game handles guest
  departures (see [Your game's settings](#your-games-settings)). The platform
  then returns the frame to its start and shows "<name> left the game". Your game
  doesn't end the session itself, and there is no SDK call for it.
- **Your own connection drops:** the platform shows "Reconnecting…". That word
  only ever means your own connection.

Lobby events (everything sent with `CouchGames.lobby.send_event`, including the
`CouchLobbyTransport` session traffic) are held through a drop and delivered in
order when the player is back. Two exceptions: a reload loses the reloading
tab's own unsent events, and a queue past 256 events or about 48,000 characters
is dropped. The platform doesn't hold messages over WebRTC. For a guest's
intents the SDK does that itself (see
[Intents sent during a drop](#intents-sent-during-a-drop)).

## Your game's settings

Two switches in the developer portal decide what a mid-game change means for
your game:

| Setting | Off (default) | On |
|---|---|---|
| **Handles a guest leaving** (`handles_guest_departure`) | A guest leaving ends the game for everyone | A guest leaving ends nothing; the roster change is all your game is told |
| **Takes mid-game arrivals** (`takes_mid_game_arrivals`) | An arrival waits ("<host> is mid-game…") until the host presses **Start together**, which restarts the game with both | An arrival launches straight into the host's running game; your game learns of it from the roster |

Both on is **drop-in, drop-out**. An arrival includes a player who left the game,
stayed in the room and asked back in.

The SDK can't read these settings. If you turn them on, your game must handle
what they allow: a guest disappearing mid-match, and a new guest joining a
running world. See [Drop-in, drop-out](#drop-in-drop-out).

## What the SDK does for you

With `CouchSession` (see [Sessions](../README.md#sessions)):

- **A player who is away keeps their place.** An away guest stays in the roster
  with the status `"disconnected"`, so it keeps its input slot for the platform's
  60 seconds. After that the player has left, and a multi-slot session frees the
  slot (`player_left`).
- **A reconnect is resynced.** When a guest comes back, the host asks it to hello
  again and sends it a fresh baseline. The guest's session emits
  `session_stopped("link-reset")`, then `session_started`, and sends no gameplay
  until the next snapshot arrives. Other players are not affected.
- **A guest's intents survive a short drop.** An intent your guest sends while
  its link is down, or while it waits for the resync snapshot, is held for up to
  3 seconds and sent in order right after that snapshot. See
  [Intents sent during a drop](#intents-sent-during-a-drop).
- **A restarted guest is heard.** A guest whose game reloaded comes back with its
  message counters at 1. The resync makes the host accept them instead of
  rejecting them as duplicates.
- **One reconnect, one resync.** The SDK listens for the platform's reserved
  events `couchgames:peer-reconnected` and `couchgames:reconnected`, and for a
  roster row coming back from `"disconnected"`. One reconnect raises one
  `transport_gap(peer_id, "peer-reconnected")`, even when both report it.

## CouchLobbySession: the standard driver

For a host-authoritative game (the host runs the world, guests send intents or
input and get snapshots), `CouchLobbySession` does all of the wiring in this
guide for you. It picks the transport, runs the session, binds a
`CouchConnection`, re-routes a guest whose WebRTC link dies, and can keep a
drop-in host's world or pause the game while a player is missing.

```gdscript
var _net := CouchLobbySession.new()


func _ready() -> void:
    await CouchGames.init()
    _net.snapshot_provider = func() -> Dictionary: return _world.to_snapshot()
    _net.policy = CouchSessionPolicy.new()
    _net.policy.max_input_players = 3          # more than one guest plays
    _net.drop_in = true                        # only if both portal settings are on
    add_child(_net)
    _net.snapshot_received.connect(_world.apply_snapshot)
    _net.intent_received.connect(_on_intent)   # host: check, apply, then send_snapshot
    _net.transport_refused.connect(_on_refused)
    await _net.start()                         # CouchGames.lobby by default
    _net.connection.state_changed.connect(_on_connection_state)
```

What it does for you:

- **Picks the transport once, at start.** `prefer` is
  `CouchSessionTransport.PREFER_ROUTED` by default: WebRTC per guest, and the
  lobby tunnel for a guest who can't use it (see
  [Routing](#routing-webrtc-where-it-works-the-tunnel-where-it-doesnt)). On
  Steam it is always the lobby wire, Steam's own networking. `transport` and
  `transport_kind` tell you what it picked.
- **Waits for routes before the session starts.** The first `evaluate()` is
  held until every guest has its route, or `ready_timeout_ms` (5 s), because a
  guest that misses the start still gets in through its hello retry.
- **Answers every guest hello with a full snapshot** from `snapshot_provider`,
  and publishes one when the host's session starts.
- **Re-routes a dead WebRTC link.** When a guest's link can't be rebuilt, the
  host ends the session with `"reroute"`, moves that guest to the tunnel and
  starts a new epoch in its next frame. Every guest resyncs once, and the
  host's connection stays `live`.
- **Binds a `CouchConnection`**, as `connection`, and polls it. Read states
  and player states from it as in the next section. Its overlay runs too.
- **Forwards the session's signals**: `session_started`, `session_stopped`,
  `snapshot_received`, `intent_received`, `input_received`, `hello_received`,
  `player_joined`, `player_left`, `local_slot_changed`,
  `held_intents_dropped`, `rejected`, `transport_gap`. `session` is the
  `CouchSession` underneath if you need more.

Set these before `start()`:

| Setting | Default | What it does |
|---|---|---|
| `prefer` | `PREFER_ROUTED` | The transport preference. Every player in a lobby must use the same one |
| `require_datagram` | `false` | Never use the tunnel: a player who can't use WebRTC gets `transport_refused` instead. For fast action games |
| `drop_in` | `false` | A host whose last guest leaves keeps its session and world. See [Drop-in, drop-out](#drop-in-drop-out) |
| `pause_on_drop` | `false` | Emit `pause_changed` while a needed player is missing. See below |
| `policy` | defaults | A `CouchSessionPolicy`: `max_input_players`, `intent_hold_ms`, ... |
| `ready_timeout_ms` | `5000` | How long the first `evaluate()` waits for routes |

**`transport_refused(error)`** means this player can't play: `require_datagram`
is on and WebRTC doesn't work here, either found at `start()` or by the host.
For an error that starts with `webrtc-blocked:`,
`CouchWebRTCProbe.describe(<the rest>)` is a line you can show the player.

`stop()` ends the session and closes the transport. The connection ends with
`left` and stays readable until the next `start()`. Leaving the tree calls
`stop()` for you.

### Pausing when a player drops

By default the host keeps playing when a guest is away, the way the platform
expects. A game that can't go on without every player sets
`pause_on_drop = true` and applies `pause_changed(paused, reason)` itself:

```gdscript
_net.pause_on_drop = true
_net.pause_changed.connect(func(paused: bool, _reason: String) -> void:
    get_tree().paused = paused)
```

- **The host** pauses while a guest with an input slot is `away`, which
  happens after the platform's 10 quiet seconds, or while its own connection
  is `reconnecting`. The reason is `player-away` or `reconnecting`.
- **A guest** pauses while its own connection is `reconnecting`, which
  includes the host being away. It doesn't pause for other guests: the host's
  world is paused, so the snapshots stop changing anyway.
- `paused` and `pause_reason` give the current value. `stop()` and the end of
  the connection lift the pause.

Spectators don't count, and a player who is `gone` frees their slot, which
lifts the pause too. Pausing the tree is fine: the driver and its connection
run with `PROCESS_MODE_ALWAYS`, so they see the player come back.

### Trying the driver in the editor

The local relay has no WebRTC, so every guest is routed to the tunnel, which
is the path a blocked player takes. To see `pause_on_drop`, run the mock
commands in [Trying it in the editor](#trying-it-in-the-editor) and wait
10 seconds after marking the guest `"disconnected"`. Every case is played
headless by `netcode/fixtures/run_lobby_driver.gd`.

`PREFER_AUTO` hasn't changed: a game wired by hand keeps its wire until it
moves to the driver.

## CouchConnection: one state for the whole connection

`CouchConnection` reads your session and the lobby and tells you, in one place,
what is happening to the connection and to each player. It never sends anything,
so it works over the lobby tunnel, WebRTC and Steam alike. `CouchLobbySession`
makes one for you (`connection`). With a `CouchSession` you wired yourself,
add one next to it and bind it:

```gdscript
var _connection := CouchConnection.new()


func _start_session() -> void:
    # ... create _session (a CouchSession) as usual ...
    add_child(_connection)
    _connection.bind(_session, CouchGames.lobby)
    _connection.state_changed.connect(_on_connection_state)
    _connection.player_state_changed.connect(_on_player_state)


func _on_connection_state(state: String, reason: String) -> void:
    match state:
        CouchConnection.STATE_SYNCING:
            _world.discard_prediction()     # a snapshot is on its way
        CouchConnection.STATE_LIVE:
            _hud.show_playing()
        CouchConnection.STATE_RECONNECTING:
            pass                            # keep the world; see the reason below
        CouchConnection.STATE_ENDED:
            _end_match(CouchConnection.describe_end(_connection.end_reason, _host_name))


func _on_player_state(user_id: String, state: String) -> void:
    _hud.set_player_marker(user_id, state)  # connected, away or gone
```

A `CouchSession` started without a `CouchConnection` logs one warning per run,
pointing here. `CouchLobbySession` doesn't warn, because it's already a
standard driver.

### Connection states

| State | Meaning |
|---|---|
| `connecting` | Bound, no session yet |
| `syncing` | Guest: the session started and is waiting for the host's snapshot |
| `live` | Playing. A host is live from its session start and stays live while guests come and go, because its world runs on |
| `reconnecting` | The link or the session is being rebuilt. `reason` says why: a session stop reason (`link-reset`, `host-restarted`, `steam-link-gap`, `role-changed`), `host-away`, or `own-connection` |
| `ended` | Over. `end_reason` is one of `host-left`, `connection-lost`, `reconnect-timed-out`, `left` |

`reconnecting` lasts at most `hold_ms`, then ends with `reconnect-timed-out`.
The default follows the platform: 65 s on the web (the 60 s away limit, plus time
for the platform's own end to arrive), 120 s on Steam (its recovery window),
60 s elsewhere. Set `hold_ms` before `bind()` to change it.

### Player states

For every other player: `connected`, `away` or `gone`. Like the platform,
`away` only shows after 10 quiet seconds (`AWAY_QUIET_MS`), so a short drop
reports nothing. The local player is never reported. Read them at any time
with `get_player_state(user_id)` or `get_players_state()`.

### The host away on the web

While the host is away, the platform leaves it out of the roster, and a guest's
session stops with `"host-left"`. On the web a host who really left ends the
room, and the platform unloads your game, so a game still running was left by
a host who is only away. `CouchConnection` reports that as `reconnecting` with
reason `host-away`, and the host's player state as `away` after the quiet
stretch. Keep the world. When the host is back, the session starts again:
`syncing`, then `live`. Off the web, `"host-left"` ends with `host-left`.

### The overlay

Off the web, `CouchConnection` shows a small notice at the top of the screen.
It shows "Reconnecting…" once a resync has lasted a second, "<name>'s away"
for an away player, and the end text when the connection ends. It runs while
the game is paused. On the web it draws nothing, because the platform draws
these notices itself.

To draw your own, set `overlay_enabled = false` before adding the connection
to the tree, and use the same pieces the built-in overlay uses:
`overlay_lines()` (the lines to show now), `describe_end(reason, host_name)`
and the two signals.

### Logging

Each state change prints one line, such as
`CouchConnection: live -> reconnecting (link-reset)`, and so does each player
state change. Set `log_enabled = false` to silence it.

## Routing: WebRTC where it works, the tunnel where it doesn't

Some players can't use WebRTC at all: it's switched off in their browser, or
their school or office network blocks it even through TURN. With
`PREFER_STAR` they are refused. With `PREFER_ROUTED` they play over the lobby
tunnel, and everyone else keeps WebRTC:

```gdscript
var picked: Dictionary = await CouchSessionTransport.pick(
    CouchGames.lobby, CouchGames.webrtc, CouchSessionTransport.PREFER_ROUTED)
_transport = picked.transport          # a CouchRoutedTransport; never refused for WebRTC
_session = CouchSession.new(CouchGames.lobby, _transport)
```

Every player in a lobby must use the same preference, so ship it in the build.

How it works:

- Each guest tells the host whether WebRTC works on its machine. The host
  assigns that guest a route: `star` (WebRTC) once its link is up, or `lobby`
  (the tunnel) when the guest or the host can't use WebRTC, or when the link
  hasn't come up 12 seconds after the guest's report.
- The route is fixed. A guest's frames travel only on its route, and a frame
  that arrives on the other wire is dropped and reported as a
  `transport_gap(peer, "wrong-wire")`.
- Until a guest has its route its session waits, then starts as usual.
  `is_ready()` is true once every guest in the roster has acknowledged its
  route. If you want a clean start, wait for it before your first `evaluate()`.
- A guest that restarts, or a host that restarts, routes again on its own.

**`require_datagram`.** Pass `true` as `pick()`'s fifth argument for a game that
can't live with the tunnel's latency. That's typically a fast action game, and
always a rollback one. A player who can't use WebRTC is then refused at
`pick()`, or by the host, which emits `route_refused(reason)` on that guest's
transport. Nobody is put on the tunnel.

**A WebRTC link that dies for good.** When a star guest's link can't be rebuilt
(`transport_gap(peer, "rebuild-exhausted")`), the transport doesn't move it in
place, because changing a wire under a running session is what breaks it. It
emits `reroute_pending(peer)` instead, and the move happens between sessions:

```gdscript
_transport.reroute_pending.connect(func(_peer: String) -> void:
    _session.stop("reroute")               # ends this epoch
    _transport.apply_pending_reroutes()    # the guest moves to the tunnel
    _session.evaluate(Time.get_ticks_msec()))   # a new epoch on the new routes
```

Every guest then resyncs once (`syncing`, then `live` in `CouchConnection`).
Under `require_datagram` the guest is refused instead.
`CouchLobbySession` uses the routed transport and does this for you.

### What the tunnel costs

Every frame to or from a tunnel guest goes through the platform's room, a
Cloudflare Durable Object. There's no per-message limit there today, so the
cost is volume. Each frame is one incoming WebSocket message to the room:
per tunnel guest, that's your snapshot rate (the host sends that guest its own
copy) plus the guest's input or intent rate. A 20 Hz snapshot with 20 Hz input
is about 40 messages a second per tunnel guest. WebRTC guests cost the room
nothing per frame. Check current Durable Objects pricing for what that volume
bills at.

`stats()` on the host's transport counts it for real:
`{star: {sent, received}, lobby: {sent, received, bytes_sent}, dropped}`.
Log it at the end of a match to see what your game actually sends. If tunnel
volume matters, send tunnel guests fewer snapshots: `route_for(peer)` tells you
which wire each guest is on.

Latency is the other cost. A tunnel guest's frames travel through the room
in order, so one slow frame holds up the ones behind it. That's fine for
turn-based and slower games, and noticeable in fast ones.

### Trying routing in the editor

The local relay has no WebRTC, so in the editor every guest is routed to the
tunnel. That's the path to test, and it's the one a blocked player gets. A web
export on the platform exercises WebRTC routes. To see a mixed lobby there,
join one guest from a browser with WebRTC switched off (Firefox:
`media.peerconnection.enabled` set to `false` in `about:config`).

## What your game must do

1. **Use `CouchLobbySession`, or bind a `CouchConnection`** to your own
   session, as above, and drive your match from its states instead of from
   session stop reasons.

2. **Answer every `hello_received` with a complete snapshot.** This is what a
   reconnecting or restarted guest waits for. A partial or delta snapshot leaves
   that guest stuck or wrong. `CouchLobbySession` does this for you from its
   `snapshot_provider`.

   ```gdscript
   _session.hello_received.connect(func(_guest_id: String) -> void:
       _session.broadcast_snapshot(_world.to_snapshot()))
   ```

3. **Keep the world through `reconnecting` and `syncing`.** Both are followed
   by `live` or `ended`. Drop any predicted state and apply the snapshot when
   it comes. Only tear the match down on `ended`.

4. **Treat `transport_gap` as information, not as a command.** The session
   already acts on the reasons that matter. Log gaps if you want to compare
   connections, but don't stop or restart anything on one.

5. **Apply a guest's intents against the world as it is now.** A held intent
   arrives after the resync snapshot, up to `intent_hold_ms` late. One sent over
   the lobby tunnel can arrive up to the platform's 60 seconds late, because the
   room holds tunnel messages itself.
   Check it against the current world the way you check any intent ("is that
   tile still free?"), and drop it when it no longer makes sense.

6. **Don't draw your own reconnecting or away notices on the web.** The built-in
   overlay already stands back there. If you draw your own, check
   `connection.platform_ui` and do the same.

### Intents sent during a drop

Some messages are lost while a guest's link is down. The room holds the lobby
tunnel's messages, but a WebRTC link that died loses everything sent over it.
The host also ignores a reset guest's intents until that guest's resync hello.
So a guest's `CouchSession` holds the intents it can't send, for a short blip
only. An action from a long outage would land in a world that has moved on and
surprise everyone, so it is dropped instead.

- **What is held:** an intent from a guest with an input slot, when the
  transport refuses it (the link is down) or when the session is waiting for
  the snapshot after a link reset. `send_intent` returns `true`: the intent is
  accepted and will be sent.
- **When it's sent:** right after the next snapshot the guest accepts, oldest
  first, before anything sent later. A guest with something held queues new
  intents behind it, so nothing is reordered. The replay costs no sequence
  numbers, so the host sees no gap.
- **How long:** `CouchSessionPolicy.intent_hold_ms`, 3000 by default. An intent
  held longer is dropped as `expired` and never sent. Set it to `0` to turn
  holding off completely.
- **How many:** `CouchSessionPolicy.intent_hold_limit`, 256 by default. When
  the hold is full, `send_intent` returns `false` and that intent is lost.
- **When it's dropped:** `held_intents_dropped(count, reason)` fires and those
  intents are never sent. The reason is `expired` when they were held too long,
  the session's stop reason when the session stops,
  `host-restarted` when the host comes back with a new epoch (those intents
  were for a world the host no longer has), or `slot-lost` when the guest comes
  back without an input slot. Show the player that their last actions didn't go
  through if that matters in your game.
- **Inputs are not held.** `send_input` still returns `false` on a dead link.
  Input is state, and the next input replaces it, so send what the player is
  doing now, not what they did during the drop.
- **Not covered:** an intent the transport accepted just before it noticed the
  link was dead, and one sent in the moment between the host noticing a reset
  and the guest hearing about it. Both are lost, as before. Make an intent that
  must not be lost idempotent and re-send it until the world shows it applied.

```gdscript
var policy := CouchSessionPolicy.new()
policy.intent_hold_ms = 1000               # a fast game: only replay a 1 s blip
# policy.intent_hold_ms = 0                # or turn holding off
_session = CouchSession.new(CouchGames.lobby, _transport, policy)
_session.held_intents_dropped.connect(func(count: int, reason: String) -> void:
    _hud.toast("%d action(s) didn't reach the host (%s)" % [count, reason]))
```

`session.held_intent_count` tells you how many are waiting, for a HUD hint
while the player is reconnecting.

To try it: there's little to see in the editor. Every guest there is on the
tunnel, which doesn't refuse sends, and the resync window after a reconnect
lasts about one round trip. To see a dead WebRTC link,
play a web export on the platform and cut the guest's network for a few
seconds while it keeps sending. Every case is played headless by
`netcode/fixtures/run_intent_hold.gd`.

### Drop-in, drop-out

If both settings are on:

- **Use more than one input slot** (`max_input_players > 1`, see
  [Multiple input players](../README.md#multiple-input-players)). An arrival
  then takes a free slot without restarting the session (`player_joined`), and
  a departure frees it (`player_left`).
- **Set `drop_in = true` on `CouchLobbySession`** (or
  `CouchSessionPolicy.drop_in` on a session you wired yourself). A host whose
  last guest leaves then keeps its session, epoch and world: the leaver's slot
  is freed (`player_left`), the host stays `live` and waits, and the next
  arrival takes a free slot (`player_joined`) and gets the full snapshot on
  its hello. Without it, the session stops with `"roster-too-small"` and the
  next arrival starts a new epoch, though `CouchConnection` still keeps the
  host `live`. `drop_in` needs more than one input slot. With one, a pinned
  guest leaving still stops the session (`"authorized-peer-left"`).
- **The host's first session still needs a guest.** A host alone at start
  waits for the first arrival before its session starts.

- Handshakes is the one game with both settings on today.

## Trying it in the editor

The mock backend and the local relay can play out the away flow. Run these on
the host instance:

```gdscript
var guest_id := CouchGames.mock.add_guest("Tester")

# The guest drops: its row reads "disconnected" and keeps its slot.
CouchGames.mock.set_player_status(guest_id, "disconnected")

# The guest is back: either of these raises one resync.
CouchGames.mock.set_player_status(guest_id, "playing")
CouchGames.mock.simulate_event("couchgames:peer-reconnected",
    {"userId": guest_id, "role": "guest", "downtimeMs": 4000}, "")

# The guest was away too long, or left: the slot is freed.
CouchGames.mock.remove_player(guest_id)
```

Off the web the built-in overlay shows the result: about 10 seconds after
`set_player_status(guest_id, "disconnected")` the host's screen reads
"Tester's away", and it clears when the guest is back.

To test a restarted guest for real, run two instances (Debug > Run Multiple
Instances), then close and reopen the guest instance while the host keeps running.

## Reference

These tables are for games that read the session directly. With a
`CouchConnection`, the mapping below is already applied.

### Session stop reasons and the connection state they lead to

| Session stop | CouchConnection |
|---|---|
| `link-reset`, `host-restarted`, `steam-link-gap`, `role-changed` (guest) | `reconnecting` with that reason |
| `host-left` (guest) | Web: `reconnecting` (`host-away`). Elsewhere: `ended` (`host-left`) |
| `roster-too-small` (guest) | Web: `reconnecting`. Elsewhere: `ended` (`connection-lost`) |
| `roster-too-small`, `authorized-peer-left`, `reroute` (host) | Stays `live` |
| `stopped` (the driver's own stop) | `ended` (`left`) |
| `lobby-unavailable`, anything else | `ended` (`connection-lost`) |

The lobby's own states (Steam) count too: `reconnecting` is `reconnecting`
(`own-connection`), `failed` ends `connection-lost`, and `leaving` ends `left`.

### Why a session stopped (`session_stopped(reason)`)

| Reason | Meaning | What to do |
|---|---|---|
| `link-reset` | Guest only: the host asked for a resync after a reconnect or restart | Keep the world; a snapshot follows |
| `host-restarted` | Guest only: the host came back with a new epoch | Keep the scene; the new session's snapshot replaces the world |
| `steam-link-gap` | Guest only, Steam: the Steam link broke | As `link-reset` |
| `host-left` | Guest: the host is no longer in the roster | On the web while still running, the host is away (see above); elsewhere, end the match |
| `authorized-peer-left` | Host, one input slot: the guest who held it left | A new session starts if another guest can take it |
| `roster-too-small` | Fewer than two players are left | Drop-in: keep the world and wait; otherwise end the match |
| `role-changed` | This client's host/guest role changed | Rebuild from the new session |
| `lobby-unavailable` | The lobby went away | End the match |

### Held intents dropped (`held_intents_dropped(count, reason)`)

| Reason | Meaning |
|---|---|
| `expired` | Held longer than `intent_hold_ms` |
| A stop reason (`left`, `host-left`, `role-changed`, ...) | The guest's session stopped |
| `host-restarted` | The host came back with a new epoch |
| `slot-lost` | The guest came back without an input slot |

### Link gaps (`transport_gap(peer_id, reason)`)

| Reason | Raised by | Meaning |
|---|---|---|
| `peer-reconnected` | Lobby and WebRTC transports | The link to that peer was down and is back. On Couch, from the away flow's events or roster |
| `peer-rejoined` | Lobby and WebRTC transports | That peer left the roster and came back |
| `link-rebuild` | WebRTC transport | The host rebuilt the peer's WebRTC link |
| `steam:*` | Steam backend | A Steam link fact |
| `rebuild-exhausted` | WebRTC transport | The host gave up rebuilding that peer's link. On the routed transport it also queues a re-route (`reroute_pending`) |
| `wrong-wire`, `unrouted` | Routed transport | A frame arrived on a wire that isn't that peer's route, or from a peer with no route. Dropped, reported once per peer |

The session resyncs that guest on `peer-reconnected`, `peer-rejoined`,
`link-rebuild` and `steam:*`. Every other reason, including the last two rows,
is information only.
