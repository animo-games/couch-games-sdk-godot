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
debug/      the mock debug overlay
editor/     EditorPlugin and the Web export present-path patch
tools/      build_and_upload and its per-platform launchers
export/     HTML shell for the Web export preset
```

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
| `couch_games/local/enabled` | `true` | Allow the loopback lobby in debug builds |
| `couch_games/local/port` | `8974` | Port the loopback lobby binds |
| `couch_games/deploy/slug` | `""` | Slug remembered by the Build & Upload dialog |

`--couch-mock` as a user arg forces the mock for a single run; `--couch-role=host`
or `--couch-role=guest` pins an instance's role in the loopback lobby.
