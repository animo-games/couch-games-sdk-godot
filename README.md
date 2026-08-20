# Couch Games SDK for Godot

Godot 4 addon for games running on the Couch Games platform: saves, achievements,
metadata, session stats, a multiplayer lobby and WebRTC signaling.

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
webrtc/     CouchGames.webrtc, the candidate-path probe, the rollback adapter
experience/ CouchGames.experience, the uploaded files for the current drop
game/       CouchGames.game, the files that shipped inside your build
debug/      the mock debug overlay
editor/     EditorPlugin and the Web export present-path patch
tools/      build_and_upload and its per-platform launchers
export/     HTML shell for the Web export preset
```

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

**You never receive your own event back.** That is server semantics, not a
quirk of the SDK, and it is the one thing to design around: apply the local
effect at send time rather than waiting for the event to come home. The example
below does this in `_mark_ready()`.

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

Event names are yours to choose, with one reservation: `couch-net` belongs to
`CouchSession`, which frames its own netcode over the same tunnel. If you are
sending state at frame rate, use that instead of hand-rolling it on top of
`send_event` — the tunnel is a relay through the platform, fine for lobby
traffic and turn-based moves, not a rollback transport.

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

## Experience files

An experience is a dated content drop — a level pack, a room, a puzzle set —
uploaded on the platform against your game. Files are addressed by **basename**,
never by URL: the URL embeds an experience id that rotates, so anything keying
off it breaks the next day.

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

There is no event to catch and no readiness handshake to wait for: the platform
retains the bytes, so an `await` resolves whether the download finished before
or after you asked. On failure you get an empty result and a pushed error naming
the cause.

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

## Deploying a build

```
./addons/couch-games-sdk/tools/build_and_upload.sh  <game-slug>    macOS/Linux
.\addons\couch-games-sdk\tools\build_and_upload.ps1 <game-slug>    Windows
```

Or use Project > Tools > "Couch Games: Build & Upload Web…", which runs the same
pipeline on a background thread. Either way you need a "Web" export preset and
`COUCHGAMES_API_KEY` in the environment or in a `.env` at the project root;
`DEV_PORTAL_URL` overrides the portal it uploads to.

## Project settings

The plugin registers these under Project Settings (Advanced), all optional:

| Setting | Default | Purpose |
| --- | --- | --- |
| `couch_games/mock/force_mock` | `false` | Use the mock even in a platform web export |
| `couch_games/mock/enable_debug_overlay` | `true` | Show the overlay when the mock is active |
| `couch_games/mock/overlay_toggle_key` | `F10` | Key that toggles the overlay |
| `couch_games/mock/latency_ms` | `0` | Artificial delay on every awaited verb |
| `couch_games/mock/local_username` | `Player 1` | Name of the local player in the mock |
| `couch_games/mock/experience_name` | project name | Title reported by the mock |
| `couch_games/mock/experience_url` | `https://couch.games/mock` | URL reported by the mock |
| `couch_games/mock/experience_files_dir` | `res://experience_files` | Where the mock reads experience files from |
| `couch_games/mock/build_files_dir` | `res://build/web` | Where the mock reads build files from |
| `couch_games/local/enabled` | `true` | Allow the loopback lobby in debug builds |
| `couch_games/local/port` | `8974` | Port the loopback lobby binds |
| `couch_games/deploy/slug` | `""` | Slug remembered by the Build & Upload dialog |

`--couch-mock` as a user arg forces the mock for a single run; `--couch-role=host`
or `--couch-role=guest` pins an instance's role in the loopback lobby.
