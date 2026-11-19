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

## What your game must do

1. **Answer every `hello_received` with a complete snapshot.** This is what a
   reconnecting or restarted guest waits for. A partial or delta snapshot leaves
   that guest stuck or wrong.

   ```gdscript
   _session.hello_received.connect(func(_guest_id: String) -> void:
       _session.broadcast_snapshot(_world.to_snapshot()))
   ```

2. **Don't tear down the world on a guest's `session_stopped("link-reset")`.**
   It's followed by `session_started` and a snapshot. Keep the scene, drop any
   predicted state, and apply the snapshot when it comes.

   ```gdscript
   func _on_session_stopped(reason: String) -> void:
       if reason == "link-reset":
           _world.discard_prediction()
           return            # session_started and a snapshot follow
       _world.stop()
   ```

3. **Treat `transport_gap` as information, not as a command.** The session
   already acts on the reasons that matter. Log gaps if you want to compare
   connections, but don't stop or restart anything on one.

4. **Don't show your own "reconnecting" or "host left" screen on the web.** The
   platform already covers the game while the host is away and shows the leave
   notices. Steam and local play have no platform UI, so show your own there.

5. **While the host is away, a guest's session stops with `"host-left"`.** The
   platform leaves an away host out of the roster, so the guest can't tell
   "away" from "left" by the roster alone. On the web a host who really left
   ends the room, and the platform unloads your game. So if your game is still
   running after `"host-left"` on the web, the host is away: keep the world, and
   the session starts again when the host is back.

   > Coming: `CouchConnection` will read this for you and report the host as
   > away instead.

### Drop-in, drop-out

If both settings are on:

- **Use more than one input slot** (`max_input_players > 1`, see
  [Multiple input players](../README.md#multiple-input-players)). An arrival
  then takes a free slot without restarting the session (`player_joined`), and
  a departure frees it (`player_left`).
- **The host must keep its world when it's left alone.** Today, a roster below
  two players stops the session with `"roster-too-small"`, and the next arrival
  starts a new one with a new epoch. Keep your world through that stop. On the
  next `hello_received`, send the newcomer the full snapshot as usual.

  > Coming: a `drop_in` setting on the session driver, so a host left alone
  > stays live and waiting instead of stopping.

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

To test a restarted guest for real, run two instances (Debug > Run Multiple
Instances), then close and reopen the guest instance while the host keeps running.

## Reference

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
