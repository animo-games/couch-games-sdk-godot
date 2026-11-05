# Couch Games SDK for Godot

Godot 4 addon for games running on the Couch Games platform: saves, achievements,
metadata, session stats, a multiplayer lobby and WebRTC signaling.

**What each call does, and the rules around it, are in the
[developer guide](https://developer.couchgames.com/docs).** This README covers the Godot names, what only Godot
has (sessions, packs, the build and upload tools), and the local mock.

Install it at `addons/couch-games-sdk/` in your project, then enable
"Couch Games SDK" under Project > Project Settings > Plugins. The plugin
registers a `CouchGames` autoload, and everything goes through it:

```gdscript
await CouchGames.init()
await CouchGames.save_game({"level": 3}, 0.25)
CouchGames.lobby.send_event("ready", {"slot": 1})
var res := await CouchGames.webrtc.connect_signaling()
```

Outside the platform (editor runs, standalone builds) the same API is served by
a local mock, so game code needs no changes to stay testable. F10 opens the
mock's debug overlay for faking lobby players and events. Run several instances
at once (Debug > Run Multiple Instances) and they form a real lobby over a
loopback socket instead of a faked one.

## Layout

```
core/       the CouchGames autoload and the response wrapper
backends/   the abstract backend plus the web, mock and local-relay ones
lobby/      CouchGames.lobby and its player type
webrtc/     signaling, candidate-path probing, the preflight WebRTC probe
            (webrtc_probe.gd), the rollback adapter, and the provider-neutral
            mesh
netcode/    CouchSession and the transports it rides on (the lobby tunnel and
            the WebRTC star), plus their headless gates
experience/ CouchGames.experience, the uploaded files for the current drop
game/       CouchGames.game, the files that shipped inside your build
debug/      the mock debug overlay
editor/     EditorPlugin and the Web export present-path patch
tools/      build_and_upload and its per-platform launchers
export/     HTML shell for the Web export preset
```

## Saves

```gdscript
var res := await CouchGames.load_save_result()
if res.is_safe_to_start_fresh():
    _state = _new_game()          # confirmed: this player has no save
elif res.is_found():
    _state = _from_save(res.payload)
else:
    _state = _new_game()          # show them something, but do NOT save it
    _saving_enabled = false

var write := await CouchGames.save_game(_state, 0.25)
if not write.persisted:
    push_warning("Save did not land: %s" % write.error)
```

Two rules: **`load_save_result()` decides whether a player is new**, and
**`save_game()` is judged by `persisted`, not `success`**. The guide explains why:
[`loadSaveResult()`](https://developer.couchgames.com/docs#load-save-result),
[`loadLatestSave()`](https://developer.couchgames.com/docs#load-latest-save) and
[refused saves](https://developer.couchgames.com/docs#refused-saves).

| `load_save_result()` | Meaning | Safe to start fresh? |
| --- | --- | --- |
| `is_new_player()` (also `is_safe_to_start_fresh()`) | No save exists | **Yes**, the only one |
| `is_found()` | `payload` holds the save | No: merge into it |
| `is_unavailable()` | It couldn't be read; one may exist | No, and keep saving off |

It also returns `revision`, `metadata` and `host_authoritative` (true for a
player who joined someone else's session: merge into `payload` rather than
showing it). `load_latest_save()` reads the save handed to the session at
startup; use it only to re-read state you already have, since an empty payload
doesn't mean the player is new.

### `persisted`, not `success`

A refused save arrives as `{ success = true, persisted = false, conflict = true }`.
Branch on `persisted`; the SDK treats a missing `persisted` as "did not land".
If your retries are capped, ask for an honest failure:

```gdscript
var res := await CouchGames.save_game(state, 0.25, null, "error")
# a refusal now arrives as success = false, persisted = false, conflict = true
```

The SDK never sets this for you.

### Recovering from a refusal

Always the same:

```gdscript
if write.conflict:
    var res := await CouchGames.load_save_result()
    if res.is_found():
        await CouchGames.save_game(_merge_into(res.payload), progress, res.revision)
```

Don't require `current_revision`: it's absent when the refusal happened in the
browser.

### Trying it without the platform

The mock backend simulates the same guard, so every path above is reachable in
the editor:

```gdscript
CouchGames.mock.simulate_unread_save()        # next blind save is refused
CouchGames.mock.simulate_load_unavailable = true   # load_save_result reports "unavailable"
CouchGames.mock.simulate_host_authoritative = true # pretend this player joined
```

After `simulate_unread_save()`, calling `load_save_result()` lets the next save
through again, as on the platform.

## Experience archive API

`await CouchGames.list_experiences()` returns a `CouchGamesSDKResponse` with
openable challenges in `payload_array`, oldest first. The existing `payload`
field remains a Dictionary for compatibility. Call when the archive screen
opens, not every frame: each platform call is a server round trip. Listing
works before a session starts; the campaign-first lock returns an empty list.
The campaign itself is excluded.

```gdscript
var result := await CouchGames.list_experiences()
if result.success:
    if result.streak != null:
        show_streak(result.streak)
    for exp in result.payload_array:
        var day: String = exp.activatedAt.substr(0, 10) if exp.activatedAt != null else ""
        var nobody_done: bool = not exp.players.values().has("completed")
        print(exp.id, exp.number, exp.title, day, exp.live, exp.state, nobody_done)
else:
    push_warning(result.error)
```

The rows' fields, and what `players` and `streak` mean, are in the guide's
[`listExperiences()`](https://developer.couchgames.com/docs#list-experiences). Bridge numbers arrive as floats, so
check for null before converting to int. `result.streak` is null when the
answer carries none (a failed call).

`await CouchGames.gameplay_completed()` returns a `CouchGamesSDKResponse` too,
with the [streak](https://developer.couchgames.com/docs#gameplay-complete) counting this completion. Games that
ignore the result keep working. `get_experience_data()`'s payload carries
`number` (null when unnumbered): show it to the player, not `experienceIndex`.

`await CouchGames.open_experience(id)` switches to an id from the list. It
returns a `CouchGamesSDKResponse`; a refusal has `success: false` and the
platform's message in `error` ([the list](https://developer.couchgames.com/docs#open-experience)), with no event
afterward. On success the event has already been delivered. **Until the event
arrives or the call fails, make no other SDK calls.** Subscribe before calling,
and clear your board and load the new puzzle from the event handler:

```gdscript
func _ready() -> void:
    await CouchGames.init()
    CouchGames.lobby.event_received.connect(_on_lobby_event)

func _open_puzzle(experience_id: String) -> void:
    var result := await CouchGames.open_experience(experience_id)
    if not result.success:
        push_warning(result.error)

func _on_lobby_event(event: String, data: Variant, _sender_user_id: String) -> void:
    if event == CouchGames.EXPERIENCE_CHANGED_EVENT:
        # Clear the board and load this puzzle; SDK calls now use the new experience.
        print(data.experienceId, data.number, data.initiatedByMe)
```

`CouchGames.EXPERIENCE_CHANGED_EVENT` is `"couchgames:experience-changed"`.
It arrives through `lobby.event_received` even in solo games, with an empty
`sender_user_id`, and in a lobby it can arrive because another member switched
([the event](https://developer.couchgames.com/docs#reserved-event-couchgamesexperience-changed)).
`lobby.get_current_game()` is lobby-only, so read the new experience from the
event or `get_experience_data()`.

The autoload's `experience_data` property is a startup snapshot; use the
awaitable getter for fresh data. Existing pack mounts remain idempotent by
filename: `load_pack()`/`load_all_packs()` do not remount an already mounted
name after a switch. Use fresh file reads or distinct pack filenames when
loading the next puzzle.

Offline, `CouchGames.mock.experiences` is a configurable `Array[Dictionary]`
in the row format above, with two default challenges. Keep it oldest first;
an empty array simulates an empty archive. A row without `players` is answered
with one built from the mock roster: you read the row's `state`, every faked or
relay player `"none"`. `CouchGames.mock.streak` (int, default 0) is the streak
both `list_experiences()` and `gameplay_completed()` report; the mock doesn't
count completions, so set it yourself. Opening a listed id updates mock
experience data/date and emits the reserved event through the usual lobby
channel before returning success. Fake guests and local relay peers prevent
switching. The local backend inherits this behavior. This is a lightweight
archive simulation: files still come from the configured mock directory and
saves/metadata keep their existing shared mock storage; it does not simulate
the platform's full handover or campaign/session eligibility checks.

## Lobby events

`CouchGames.lobby` is the session: the roster of everyone in it, and a tunnel
for sending named events between them. It is push-driven — the platform pushes
roster changes and events, the SDK turns them into signals — so there is nothing
to poll, no socket to open and no room to join. Connect and you are in.

```gdscript
func _ready() -> void:
    await CouchGames.init()
    CouchGames.lobby.event_received.connect(_on_lobby_event)
    CouchGames.lobby.players_changed.connect(_on_players_changed)
    CouchGames.lobby.refresh_players()
```

`refresh_players()` is the one piece of bookkeeping. Signals only fire on
*change*, so a scene that connects after the roster already arrived would sit
empty until somebody next joined; calling it once after `init()` replays the
current roster through the same handler. `lobby.is_available` tells you whether
there is a session at all — false in a single-player context, always true under
the mock.

### Sending

```gdscript
CouchGames.lobby.send_event("player-ready", {"slot": 1})                    # everyone else
CouchGames.lobby.send_event("match-start", {"seed": 42}, {"role": "guest"}) # guests only
CouchGames.lobby.send_event("deal", hand, {"user_id": player.user_id})      # one player
```

Without a target the event reaches **every other client** in the session.
`{"user_id": ...}` and `{"role": "host"|"guest"}` narrow it, and the two AND
together when you pass both.

**You never receive your own event back,** so apply the local effect when you
send (the example below does this in `_mark_ready()`). Delivery rules and the
reconnect events are in the guide's
[Lobby API](https://developer.couchgames.com/docs#lobby-api-multiplayer-coordination).

`data` must be JSON-serializable — dictionaries, arrays, strings, numbers,
bools, null. `Vector2` and friends are not; pack them yourself. Payloads go
through a JSON round trip on the way, which means **numbers arrive as floats**:
write `int(data["slot"])`, never `data["slot"] as int` on a value you are about
to use as an index.

### Receiving

```gdscript
func _on_lobby_event(event: String, data: Variant, sender_user_id: String) -> void:
    match event:
        "player-ready":
            _mark_ready(sender_user_id)
        "match-start":
            _start_match(int(data.get("seed", 0)))
```

Event names are yours to choose, except platform-reserved `couchgames:*` events
(including `couchgames:experience-changed`) and `couch-net`, which belongs to
`CouchSession`, which frames its own netcode over the same tunnel. If you are
sending state at frame rate, use that instead of hand-rolling it on top of
`send_event` — see [Sessions](#sessions). The tunnel is a relay through the
platform, fine for lobby traffic and turn-based moves, not a rollback transport.

### The roster

`players_changed(players)` carries the full new roster after any membership,
status or slot change — ping churn deliberately doesn't fire it, so you can
connect a UI rebuild to it without throttling. `player_joined(player)` and
`player_left(player)` fire first, so a `players_changed` handler always sees the
final roster.

```gdscript
var everyone := CouchGames.lobby.get_players()   # Array[CouchLobbyPlayer]
var host     := CouchGames.lobby.get_host()
var guests   := CouchGames.lobby.get_guests()
var me       := CouchGames.lobby.get_me()        # null when no lobby is active
if CouchGames.lobby.is_host():
    ...
```

Each `CouchLobbyPlayer` has `user_id`, `username`, `role` (`"host"`/`"guest"`),
`is_host`, `status` (`"lobby"`, `"playing"`, `"browsing"`, `"disconnected"`),
`experience_id`, `controller_slot` (`-1` when unassigned) and `ping` (`-1` when
unknown).

### Example: a ready-up screen

Everyone marks themselves ready; the host notices the roster is unanimous and
broadcasts the start, seed included, so every client generates the same level.

```gdscript
extends Control

const READY_EVENT := "player-ready"
const START_EVENT := "match-start"

var _ready_ids := {}


func _ready() -> void:
    await CouchGames.init()
    %ReadyButton.pressed.connect(_on_ready_pressed)

    var lobby := CouchGames.lobby
    if not lobby.is_available():
        _start_match(randi())  # no session: nobody to wait for
        return
    lobby.event_received.connect(_on_lobby_event)
    lobby.players_changed.connect(_on_players_changed)
    lobby.player_left.connect(_on_player_left)
    lobby.refresh_players()


func _on_ready_pressed() -> void:
    # Our own event never comes back, so mark ourselves here.
    _mark_ready(CouchGames.lobby.get_me().user_id)
    CouchGames.lobby.send_event(READY_EVENT)


func _on_lobby_event(event: String, data: Variant, sender_user_id: String) -> void:
    match event:
        READY_EVENT:
            _mark_ready(sender_user_id)
        START_EVENT:
            _start_match(int(data.get("seed", 0)))


func _mark_ready(user_id: String) -> void:
    _ready_ids[user_id] = true
    _refresh_roster()
    # One authority decides when the match starts, and it is always the host.
    if CouchGames.lobby.is_host() and _everyone_ready():
        var match_seed := randi()
        CouchGames.lobby.send_event(START_EVENT, {"seed": match_seed})
        _start_match(match_seed)


func _everyone_ready() -> bool:
    var players := CouchGames.lobby.get_players()
    if players.is_empty():
        return false
    for player in players:
        if not _ready_ids.has(player.user_id):
            return false
    return true


func _on_player_left(player: CouchLobbyPlayer) -> void:
    # A player who leaves half-readied would otherwise hold the match forever.
    _ready_ids.erase(player.user_id)


func _on_players_changed(_players: Array) -> void:
    _refresh_roster()


func _refresh_roster() -> void:
    %RosterList.clear()
    for player in CouchGames.lobby.get_players():
        var mark := "✓" if _ready_ids.has(player.user_id) else "…"
        %RosterList.add_item("%s %s%s" % [mark, player.username,
            " (host)" if player.is_host else ""])


func _start_match(match_seed: int) -> void:
    seed(match_seed)
    get_tree().change_scene_to_file("res://match.tscn")
```

Two habits are worth copying out of that. The host is the only one who decides
the match starts, because every client running `_everyone_ready()` would
otherwise broadcast its own start the moment the last ready arrived. And the
ready set is keyed by `user_id` and pruned in `player_left`, because the roster
is the source of truth about who is present — the events only say what those
people did.

### Trying it without the platform

Off-platform the lobby is served by the mock, so all of the above runs in the
editor. F10 opens the debug overlay: add fake guests, send an event **as** one
of them with the same targeting filters the server applies, and watch the event
log, which shows each event's direction and who it was delivered to. For
automated tests the overlay's buttons are just calls you can make yourself:

```gdscript
var guest_id := CouchGames.mock.add_guest("Tester")
CouchGames.mock.simulate_event("player-ready", {}, guest_id)
CouchGames.mock.set_player_status(guest_id, "playing")
CouchGames.mock.remove_player(guest_id)
```

`CouchGames.mock` is null on the real platform, and
`couch_games/mock/latency_ms` puts a delay on delivery if you want to see what
your UI does while an event is in flight.

Fake guests only go so far, though — they have no game running behind them. Run
several real instances instead (Debug > Run Multiple Instances) and they form an
actual lobby over a loopback socket, events and all, with `--couch-role=host` or
`--couch-role=guest` pinning which is which. Only the host instance can change
the roster or simulate events; the others will warn if you try.

## Sessions

`CouchSession` is a host-authoritative session on top of the lobby: the host is
the only machine that advances the game, one guest is pinned as the player that
sends `input` and `intent`, everyone else spectates, and the host broadcasts
`snapshot`s. It owns the epoch, per-kind sequence tracking, the authorized-guest
pin and the hello handshake, and it rides on a `CouchTransport` — either the
**lobby tunnel** (`CouchLobbyTransport`, every envelope relayed through the
platform as a `couch-net` event) or the **WebRTC star** (`CouchStarTransport`,
each guest holding one datagram link to the host). Which one is a decision the
game makes **once, at boot**, and `CouchSessionTransport` is where it is made:

```gdscript
var _transport: Object
var _session: CouchSession


func _ready() -> void:
    await CouchGames.init()
    var picked: Dictionary = await CouchSessionTransport.pick(CouchGames.lobby, CouchGames.webrtc)
    if picked.transport == null:
        push_error("no session transport: " + picked.error)   # refused -- see below
        if picked.error.begins_with(CouchSessionTransport.ERROR_WEBRTC_BLOCKED):
            show_message(CouchWebRTCProbe.describe(picked.probe.reason))
        return
    _transport = picked.transport
    _session = CouchSession.new(CouchGames.lobby, _transport)
    _session.session_started.connect(_on_session_started)
    _session.session_stopped.connect(_on_session_stopped)
    _session.input_received.connect(_on_input)
    _session.snapshot_received.connect(_on_snapshot)
    CouchGames.lobby.players_changed.connect(func(_p): _session.evaluate(Time.get_ticks_msec()))
    _session.evaluate(Time.get_ticks_msec())


func _process(_delta: float) -> void:
    var now := Time.get_ticks_msec()
    _transport.poll(now)   # always first: this frame's arrivals, then the session's timers
    _session.poll(now)
```

`pick(lobby, webrtc, prefer, probe_timeout_ms)` returns `{transport, kind, error, probe}`. `prefer` is
one of `CouchSessionTransport.PREFER_AUTO` (the default), `PREFER_STAR` or
`PREFER_LOBBY`; `kind` reports what was built (`"star"`, `"lobby"`, or `"none"`
on a refusal). `resolve_kind(prefer)` answers the same question without
building anything.

**The choice is a function of the build, never of the moment.** `PREFER_AUTO`
picks the star when the build has a WebRTC implementation
(`CouchStarTransport.is_webrtc_available()` — install `webrtc_native` for
native exports; the browser supplies it on the web) and the tunnel otherwise,
so a project that never installs one gets the tunnel with no configuration.
Nothing that can differ between two players in one lobby — signaling being
reachable, a roster that has not settled, an ICE failure — ever changes the
kind: every player must land on the **same** wire, and two peers on different
ones both stay engaged, each sending frames the other has no link for, with no
error anywhere. Those conditions are **refusals** instead: `transport` is
null, `error` says why, and a `push_error` names it. Retry with the same
preference if you like; never fall back to the other kind. For the same
reason, ship every export of a game with the same addons — a web build and a
`webrtc_native`-less desktop build would resolve differently.

There is no switching mid-session. A different transport means a new session,
constructed the same way.

**Preflight probe.** Starting a star only joins signaling, so a player whose
browser or network blocks WebRTC so thoroughly that even TURN fails would get a
star whose links silently time out. After the star starts, `pick()` therefore
runs `CouchWebRTCProbe` against the ICE servers signaling returned: it opens a
throwaway peer connection and checks that this machine can gather a candidate
that reaches a STUN or TURN server. If not, `pick()` refuses with
`webrtc-blocked:<reason>` (`webrtc-unavailable`, `no-candidates` or `no-route`)
and the probe result in `picked.probe` (`ok`, `reason`, `host`, `srflx`,
`relay`, `servers`, `elapsed_ms`; `{}` when no probe ran).
`CouchWebRTCProbe.describe(picked.probe.reason)` is a sentence you can show the
player. Like every other refusal it is per-machine and never a fallback to the
tunnel. A pass means "not obviously blocked", not "will connect": it does not
test the remote peer. `relay` reports whether a TURN allocation succeeded, if
your game wants to be stricter. Pass `probe_timeout_ms <= 0` to skip the probe
(the default is `CouchWebRTCProbe.DEFAULT_TIMEOUT_MS`, 5 seconds, and it ends
early when it has what it needs).

Two things the star does that the tunnel does not, both proven by
`netcode/fixtures/run_star_session.gd`: `_transport.poll()` **must** run every
frame, before `_session.poll()` (the tunnel's `poll()` is a documented no-op so
the loop above is unconditional); and `CouchSession` does not treat a dropped
link as a departure — `evaluate()` on `players_changed` is what stops the
session when the pinned guest leaves, on either transport.

### Multiple input players

By default one guest sends input. To let more do so, pass a policy:

```gdscript
var policy := CouchSessionPolicy.new()
policy.max_input_players = 4   # guests with an input slot; the host is slot 0 and is not counted
_session = CouchSession.new(CouchGames.lobby, _transport, policy)
_session.player_joined.connect(_on_player_joined)   # (peer_id, slot), host side
_session.player_left.connect(_on_player_left)       # (peer_id, slot), host side
```

The first `max_input_players` guests (lowest `controller_slot`, then
`user_id`) get slots `1..N`, and the rest spectate at `-1`. A slotted guest
leaving no longer stops the session. The host emits `player_left`, and the freed
slot goes to the next waiting spectator or newcomer (lowest slot first), which
fires `player_joined`. That guest's own session emits
`local_slot_changed(old, new)`. After `session_started` the host emits
`player_joined` for every starting player, so a game can spawn and despawn
player entities from these two signals alone. Every change of the slot map is
re-broadcast in the host's hello, and `session.slots` returns a copy of it. A
host restart is still a new epoch, which every guest sees as `session_stopped`
then `session_started`. Proven by `netcode/fixtures/run_session_players.gd`.

## Experience files

Files uploaded to an experience are addressed by **basename**, never by URL
([guide](https://developer.couchgames.com/docs#experience-files)).

```gdscript
func _ready() -> void:
    await CouchGames.init()
    await CouchGames.experience.load_all_packs()
    var manifest := load("res://experience/manifest.tres")
```

`load_all_packs()` loads every `.pck`/`.zip` on the experience and returns the
names it loaded, so **you never have to agree a filename with whoever uploads
the experience**. What a pack is called stops mattering; everything structural
lives inside it, at `res://` paths you chose when you built it. Packs load in
upload order, which is the order that decides the winner if two carry the same
path.

`load_pack("level.pck")` does one by name if you'd rather be explicit. Either
way the bytes are written under `user://couch_experience/` and handed to
`ProjectSettings.load_resource_pack()`, so the pack's contents appear at their
own `res://` paths. Both are idempotent — loading the same name twice is a no-op
— and safe to call as late as you like.

For files you want to read rather than mount:

```gdscript
var bytes   := await CouchGames.experience.get_file("layout.bin")
var text    := await CouchGames.experience.get_file_text("notes.txt")
var config  := await CouchGames.experience.get_file_json("rules.json")
var names   := CouchGames.experience.list_files()
```

An `await` resolves whether the download finished before or after you asked.
On failure you get an empty result and a pushed error naming the cause.

Off-platform, the mock backend serves these from a directory in your project
(`couch_games/mock/experience_files_dir`, default `res://experience_files`), so
an experience can be built and played in the editor before it is ever uploaded.

## Build files

A build file is anything you drop next to your export before uploading. The
deploy step below zips **every** file under `res://build/web`, so a pack you put
at `res://build/web/packs/rooms.pck` ships with the build and is addressed as
`"packs/rooms.pck"` — a path relative to the build, never a URL.

```gdscript
func _ready() -> void:
    await CouchGames.init()
    await CouchGames.game.load_pack("packs/rooms.pck",
        func(got: int, total: int) -> void:
            bar.value = 0.0 if total <= 0 else float(got) / total)
```

This is the **pull** half of the pack story, and the difference from experience
files is the point. Experience files are pushed — the platform starts
downloading them before your game frame even mounts — so by the time you ask,
there is no download left to watch. A build pack is not fetched until you call
`load_pack()`, which is what makes the progress callback possible. You decide
when the download happens.

`on_progress` is optional and called as `f(downloaded_bytes, total_bytes)`.
`total_bytes` is `-1` until the size is known, so check it is positive before
dividing. It is a per-call callback rather than a signal so that two packs
loading at once report to their own listeners with nothing to filter.

Loading is idempotent, and two calls for the same pack while it is still in
flight share the one download. Use `is_pack_loaded("packs/rooms.pck")` to ask.
A download that goes 30 seconds without receiving a byte is abandoned and
`load_pack()` returns `false` — an idle timeout, not a total one, so a large
pack on a slow connection is left alone as long as it keeps arriving.
Anything else you shipped, you can fetch yourself: `CouchGames.game.build_root()`
gives you the directory to join a path onto.

There is deliberately no `load_all_packs()` here. `CouchGames.experience` has
one because somebody *else* uploads an experience and you cannot know the
filenames; a build pack ships with the code that loads it, so you already do.

Off-platform this reads from `couch_games/mock/build_files_dir` (default
`res://build/web`) with `FileAccess` instead of HTTP — the same directory that
gets zipped, so the file you load in the editor is the file that ships.

**Build the pack with the same Godot version you export the game with.** The
engine refuses a pack written in a newer pack format than it understands, and
all `load_pack()` can tell you is `'packs/rooms.pck' is not a loadable resource
pack`. The real cause is the engine error just above it in the log:
`Pack version unsupported: <n>`. Exporting the game with an older editor than
the one that produced the pack is the easy way to do this to yourself.

## Shared game assets

Shared assets are files published separately from a game build: audio, optional
packs, or large resources that can change without a new export. Address them by
a logical relative path, never by constructing a URL. At launch, the platform
selects one immutable manifest snapshot; each name resolves to a content-hashed
object in that snapshot. Existing launches therefore keep their mapping when a
new upload replaces or removes the logical name.

```gdscript
func _ready() -> void:
    await CouchGames.init()

    # This is a manifest-resolved immutable URL, not root + filename.
    var url := await CouchGames.game.get_shared_file_url("audio/theme.ogg")
    var bytes := await CouchGames.game.get_shared_file("audio/theme.ogg")

    if await CouchGames.game.load_shared_pack("packs/common.pck"):
        var room := load("res://shared/rooms/lobby.tscn")
```

`shared_root()` returns the explicit platform root for the current launch, or
an empty string when shared assets are unavailable. It is useful for display or
diagnostics, but a root plus a filename is not a download URL: use
`get_shared_file_url()` so the parent SDK applies its manifest mapping. Both
byte and URL calls are asynchronous. `get_shared_file()` accepts an optional
`on_progress(downloaded_bytes, total_bytes)` callback with the same 30-second
no-byte timeout as build-file downloads. Concurrent reads of the same immutable
file share one transfer; only the caller that starts it receives progress.

Paths follow the guide's [rules](https://developer.couchgames.com/docs#shared-game-assets); the SDK encodes
them. Empty shared files are valid for raw reads; `load_shared_pack()` rejects
empty and invalid pack bytes.

Shared packs stage below `user://couch_shared/` with the root identity, content
hash, and logical path. A mounted pack is process-global and idempotent;
`is_shared_pack_loaded(path)` is false until that path has been resolved in the
current launch. Staging paths prevent equal pack filenames from different games
or revisions aliasing each other. They do not isolate the `res://` paths inside
packs: choose distinct resource paths and load order deliberately when packs can
overlap.

A standalone Web export without a Couch Games page around it keeps the mock for
other calls, but has no shared assets, since it has no launch manifest.

For editor, native, and local-relay runs, the mock reads ordinary files from
`couch_games/mock/shared_files_dir` (default `res://shared_files`) and hashes
their bytes for the same immutable identity rules. No local manifest or hashed
copy is required. If those assets are intended to be remote-only, exclude the
directory from each export preset (for example, add `shared_files/**` to its
`exclude_filter`) so they do not ship inside the game build.

### Publishing shared assets

```
./addons/couch-games-sdk/tools/upload_shared_assets.sh  <game-slug> [dir] [--overwrite]    macOS/Linux
.\addons\couch-games-sdk\tools\upload_shared_assets.ps1 <game-slug> [dir] [--overwrite]    Windows
```

Or use Project > Tools > "Couch Games: Upload Shared Assets…", which runs the
same pipeline on a background thread. `dir` defaults to
`couch_games/mock/shared_files_dir` -- the same directory the mock reads in the
editor, so what you tested locally is what gets published -- and needs
`COUCHGAMES_API_KEY` in the environment or a `.env` at the project root, same
as the build upload.

`.import` sidecars and dot-prefixed files/directories (`.gdignore`,
`.DS_Store`, …) are skipped automatically. A logical path that already exists
on the platform is left untouched unless `--overwrite` is passed, in which
case its contents are replaced; either way, remote files that are absent
locally are never removed.

## Deploying a build

```
./addons/couch-games-sdk/tools/build_and_upload.sh  <game-slug>    macOS/Linux
.\addons\couch-games-sdk\tools\build_and_upload.ps1 <game-slug>    Windows
```

Or use Project > Tools > "Couch Games: Build & Upload Web…", which runs the same
pipeline on a background thread. Either way you need a "Web" export preset and
`COUCHGAMES_API_KEY` in the environment or in a `.env` at the project root;
`DEV_PORTAL_URL` overrides the portal it uploads to.

If the build you ship is a differently-named preset -- an engine/experience
split, a platform-only preset carrying the Couch HTML shell -- point
`couch_games/deploy/preset` at it. Nothing else selects the preset, so a project
that leaves this on the default deploys "Web" no matter which preset it exports
by hand, and the mismatch surfaces as a build that boots into nothing on the
platform.

## Project settings

The plugin registers these under Project Settings (Advanced), all optional:

| Setting | Default | Purpose |
| --- | --- | --- |
| `couch_games/mock/force_mock` | `false` | Use the mock even in a platform web export |
| `couch_games/mock/enable_debug_overlay` | `true` | Show the overlay when the mock is active |
| `couch_games/mock/overlay_toggle_key` | `F10` | Key that toggles the overlay |
| `couch_games/mock/shared_files_dir` | `res://shared_files` | Directory used for mock shared assets |
| `couch_games/mock/latency_ms` | `0` | Artificial delay on every awaited verb |
| `couch_games/mock/local_username` | `Player 1` | Name of the local player in the mock |
| `couch_games/mock/experience_name` | project name | Title reported by the mock |
| `couch_games/mock/experience_url` | `https://couch.games/mock` | URL reported by the mock |
| `couch_games/mock/experience_files_dir` | `res://experience_files` | Where the mock reads experience files from |
| `couch_games/mock/build_files_dir` | `res://build/web` | Where the mock reads build files from |
| `couch_games/local/enabled` | `true` | Allow the loopback lobby in debug builds |
| `couch_games/local/port` | `8974` | Port the loopback lobby binds |
| `couch_games/deploy/slug` | `""` | Slug remembered by the Build & Upload dialog |
| `couch_games/deploy/preset` | `"Web"` | Export preset that Build & Upload exports |

`--couch-mock` as a user arg forces the mock for a single run; `--couch-role=host`
or `--couch-role=guest` pins an instance's role in the loopback lobby.

## WebRTC connections

`CouchGames.webrtc` remains the low-level signaling API. Games that want an
engine `MultiplayerPeer` can use the additive high-level façade:

```gdscript
var connection := CouchWebRTCConnection.new(CouchGames.webrtc)
connection.name = "Transport" # identical RPC path on every peer
connection.udp_first = true    # optional; defaults false
add_child(connection)
connection.connection_ready.connect(func(): print("mesh ready"))
connection.start()
```

`WebRTCMultiplayerConnection` is the provider-neutral core. Its signaling
source is duck typed (`connect_room`, `send`, `close` plus peer/signal events),
so non-Couch providers can use it without inheriting an SDK class. It owns peer
discovery, deterministic net ids, SDP/ICE generation and acknowledgement,
strict identify validation, timeouts, and targeted recovery. Application
policy—such as when an input stall warrants recovery—stays outside it.

Only one `CouchWebRTCConnection` may own a `CouchWebRTC` instance at a time,
because the backend exposes one physical signaling socket. Low-level
`CouchGames.webrtc` users are otherwise unaffected.

`CouchWebRTCSignalingSource` replaces the consumer-specific adapter name.
`CouchRollbackSignalingAdapter` remains as a compatibility subclass for one
migration release.

## WebRTC signaling lifecycle

`CouchGames.webrtc` owns signaling for the SDK. Calls to
`connect_signaling()` are serialized because each backend exposes one physical
signaling socket. A newer connect supersedes an older pending request, while
`disconnect_signaling()` cancels the desired lifecycle; if a canceled backend
promise later succeeds, the SDK closes that stale socket before allowing a
replacement to start. Backends implementing the SDK contract must make
`webrtc_disconnect()` invalidate pending post-await work and emit
`webrtc_signaling_closed` when either a pending or live physical connection is
gone.

Unexpected socket closure reconnects automatically by default without touching
established WebRTC peer connections. `signaling_reconnecting` and
`signaling_reconnected` expose that lifecycle; an explicit disconnect stops the
loop. `request_ice_servers()` and successful automatic reconnects update
`CouchGames.webrtc.ice_servers` and emit `ice_servers_updated`. The bundled
`CouchWebRTCSignalingSource` forwards those values through the optional,
SDK-neutral `get_connection_config()` / `connection_config_updated` transport
capability so future peer rebuilds use current TURN credentials.
