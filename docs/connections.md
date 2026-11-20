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
is dropped. Messages over your own WebRTC connection are not held.

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
- **A restarted guest is heard.** A guest whose game reloaded comes back with its
  message counters at 1. The resync makes the host accept them instead of
  rejecting them as duplicates.
- **One reconnect, one resync.** The SDK listens for the platform's reserved
  events `couchgames:peer-reconnected` and `couchgames:reconnected`, and for a
  roster row coming back from `"disconnected"`. One reconnect raises one
  `transport_gap(peer_id, "peer-reconnected")`, even when both report it.

## CouchConnection: one state for the whole connection

`CouchConnection` reads your session and the lobby and tells you, in one place,
what is happening to the connection and to each player. It never sends anything,
so it works over the lobby tunnel, WebRTC and Steam alike. Add one next to your
session and bind it:

```gdscript
var _connection := CouchConnection.new()


func _start_session() -> void:
    # ... create _session (a CouchSession or a CouchLobbySession) as usual ...
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

## What your game must do

1. **Bind a `CouchConnection`** to your session, as above, and drive your
   match from its states instead of from session stop reasons.

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

5. **Don't draw your own reconnecting or away notices on the web.** The built-in
   overlay already stands back there. If you draw your own, check
   `connection.platform_ui` and do the same.

### Drop-in, drop-out

If both settings are on:

- **Use more than one input slot** (`max_input_players > 1`, see
  [Multiple input players](../README.md#multiple-input-players)). An arrival
  then takes a free slot without restarting the session (`player_joined`), and
  a departure frees it (`player_left`).
- **The host keeps its world when it's left alone.** The session underneath
  still stops with `"roster-too-small"` and starts a new one with a new epoch
  when the next guest arrives, but `CouchConnection` keeps the host `live`
  throughout. On the next `hello_received`, send the newcomer the full snapshot
  as usual.

  > Coming: a `drop_in` setting on the session driver, so the session itself
  > stays up and waits instead of stopping.

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
| `roster-too-small`, `authorized-peer-left` (host) | Stays `live` |
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

### Link gaps the session acts on (`transport_gap(peer_id, reason)`)

| Reason | Raised by | Meaning |
|---|---|---|
| `peer-reconnected` | Lobby and WebRTC transports | The link to that peer was down and is back. On Couch, from the away flow's events or roster |
| `peer-rejoined` | Lobby and WebRTC transports | That peer left the roster and came back |
| `link-rebuild` | WebRTC transport | The host rebuilt the peer's WebRTC link |
| `steam:*` | Steam backend | A Steam link fact |

Every other reason is diagnostic only.
