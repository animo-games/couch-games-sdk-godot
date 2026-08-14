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
