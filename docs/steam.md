# Optional Steam backend

The SDK remains one addon and one `CouchGames` autoload. Steam is optional.
Game synchronization and achievement eligibility remain game code. No game
integration is included in this change.

## Dependency pin and compatibility evidence

Use **Godot 4.7 stable official, hash `5b4e0cb0f`**, the normal Godot export
templates, **GodotSteam 4.23 GDExtension**, and its **Steamworks 1.65** runtimes.
Supported release targets for this adapter are **Linux x86_64** and **Windows
x86_64**. Do not combine this GDExtension with a GodotSteam module engine.

The exact archive URL and SHA-256 are in
[`steam/dependency-lock.json`](../steam/dependency-lock.json). Install that archive
under `res://addons/godotsteam/`; keep its extension descriptor and bundled
`linux64/libsteam_api.so` / `win64/steam_api64.dll` dependency paths intact.
The addon itself vendors no native binaries. Pin the SDK commit containing this
implementation when consuming it; the prior baseline commit
`f90557e85ea05dee208aab16e70d1e49c2012725` does not contain Steam support.

Verified locally on October 5, 2026: installed Godot reports
`4.7.stable.official.5b4e0cb0f`; the checksum-pinned package loads on Linux x86_64
and exposes the expected methods and callback signatures. The SDK also parses
and passes its deterministic contracts with **no Steam extension installed**.
Windows loading, native packaged exports, Web packaged exports, live Steam
initialization, cross-machine messages, invitations, and achievement storage
are **unverified release gates**. No game App ID or authorized live test accounts
are available. Fake results must not be recorded as live acceptance.

Primary references used for the spike:

- [Official pinned GDExtension release](https://codeberg.org/godotsteam/godotsteam/releases/tag/v4.23-gde)
- [Pinned source and bundled API documentation](https://codeberg.org/godotsteam/godotsteam/src/tag/v4.23)
- [Steam Networking Messages](https://partner.steamgames.com/doc/api/ISteamNetworkingMessages)
- [Steam networking type limits](https://partner.steamgames.com/doc/api/steamnetworkingtypes)
- [Steam lobby invitations and ownership](https://partner.steamgames.com/doc/api/ISteamMatchmaking)
- [Steam achievements and storage](https://partner.steamgames.com/doc/api/ISteamUserStats)

Signatures verified against both source and the loaded extension:

| Native API | Adapter behavior |
| --- | --- |
| `steamInitEx(app_id: int = 0, embed_callbacks: bool = false) -> Dictionary` | SDK owns initialization; status zero is success |
| `run_callbacks()` | Bridge pumps once per SDK frame, before session polling |
| `createLobby(lobby_type, max_members)` / `lobby_created(result, lobby_id)` | Only one native membership request outstanding |
| `joinLobby(lobby_id)` / `lobby_joined(lobby_id, permissions, locked, response)` | Entry result 1 succeeds, 4 means full |
| `join_requested(lobby_id, friend_id)` | Converted to shared `join_requested` |
| `receiveMessagesOnChannel(channel, max_messages) -> Array` | `identity` authenticates sender; `payload` supplies bytes; native messages are released by extension |
| `sendMessageToUser(steam_id, bytes, flags, channel) -> int` | Reliable flag 8, channel 73, result 1 means accepted |
| `network_messages_session_failed(reason, steam_id, state, debug_message)` | Closes link and emits `transport_gap` |
| `getAchievement(api_name) -> {ret, achieved}` | False `ret` is read/definition error, never locked |
| `setAchievement(api_name) -> bool` | Local state only |
| `storeStats() -> bool` / `user_stats_stored(game_id, result)` | One outstanding batch, result 1 acknowledges only its captured keys |

GodotSteam removed `RequestCurrentStats`; this adapter never calls it. Reads use
the modern cached local state API. A failed read is visible and does not create
an empty successful list. There is no second initialization or achievement pump.

Valve's reliable native message limit is 512 KiB. The SDK default is **384 KiB
for the entire serialized UTF-8 envelope**, including headers; this accommodates
the existing session codec's 256 KiB base64 body. Oversized messages fail visibly.
There is no SDK outbound queue or fragmentation; the bounded native provider
queue reports acceptance/rejection directly. Receive work is 64 messages per
frame by default (configurable 1–256). No transparent replay of stale actions.

## Setup and selection

Set `couch_games/backend` to `auto`, `couch`, `steam`, `local`, or `mock`.
The existing force-mock setting and `--couch-mock` take precedence. Auto selects
Couch's detected parent bridge, then the custom `steam` export feature, then
native debug local relay, then mock. Installing GodotSteam alone never selects
Steam in the editor. Explicit Steam failure remains failed Steam.

Disable both GodotSteam settings:

```ini
[steam]
initialization/processes/initialize_on_startup=false
initialization/processes/embed_callbacks=false
```

Set `couch_games/steam/app_id` to your actual application ID (zero allows Steam's
launch environment to supply it), and a stable `couch_games/steam/game_id`.
Set `protocol_version` and `content_version` whenever incompatible wire/game
content changes. Native Steam export presets need custom feature `steam` and
architecture `x86_64`. Use the matching ordinary Godot templates. The editor
plugin excludes `addons/godotsteam`, SDK `steam/`, and `steam_backend.gd` from
Web. Also set your Web preset's `exclude_filter` to
`addons/godotsteam/*,addons/couch-games-sdk/steam/*,addons/couch-games-sdk/backends/steam_backend.gd`
when exporting without the editor plugin; disable Web GDExtension support.
Explicit Steam selection on Web returns an unsupported-selection error without
loading the excluded adapter. Ship no `steam_appid.txt` in a production depot.

`await CouchGames.init()` resolves within `initialization_timeout_ms` (default
10 seconds), including concurrent callers. Read `backend_name`,
`initialization_state`, `initialization_error`, and
`initialization_state_changed(state)`. `supports(capability)` reports current
service availability. Membership is separate from capability. Steam supplies
lobbies, events, invitations, and local achievements, while WebRTC, experience
files, Couch saves, metadata, and shared assets report unavailable. The existing
WebRTC facade remains present and unavailable; its path probe is never installed
for Steam. Unsupported experience metadata is skipped. Responsive Couch/local metadata
still populates `experience_data` before init returns; a stuck read is limited to
a one-second optional grace period within the total init deadline.

## Achievements

Define `couch_games/achievements/catalog` as a Dictionary:

```gdscript
{"first_puzzle": "ACH_FIRST_PUZZLE", "level_complete": {"steam": "ACH_LEVEL_COMPLETE"}}
```

Empty strings or omitted `steam` entries default to the stable game key. The
catalog restricts facade calls; legacy Couch/mock top-level calls retain their
existing keys and response semantics.

```gdscript
await CouchGames.init()
var result := await CouchGames.achievements.unlock("first_puzzle")
# stored / already_unlocked are confirmed; pending retains a retryable award.
print(result.status, result.provider_acknowledged)
var state := await CouchGames.achievements.get_state("first_puzzle")
var list := await CouchGames.achievements.get_unlocked()
var flush := await CouchGames.achievements.flush()
print(flush.metadata.get("pending_keys", []))
```

`CouchAchievementResult` separates local state from provider acknowledgment.
Signals: `ready_changed`, `unlocked` (first local transition), `stored` (confirmed
keys), `failed`. Unlock and flush waits default to five seconds. Awards earned
together coalesce on the next backend frame. Retries back off from 1 to 60
seconds. A caller timeout does **not** free an outstanding native request;
Steam callbacks have no SDK batch identifier. No callback means pending until
callback, shutdown, or relaunch—never a speculative second store.

Pending journals hold at most 128 awards (64 KiB); full or unwritable journals
reject new awards visibly. They also record first local transitions so relaunch
retries do not emit another unlock signal. Pending journals live at `user://couch_games_steam/<appid>_<userid>.json`, with
atomic writes and account validation. Awards are recorded before setting or
storing. A pending journal survives a locally unlocked bit, restart, transient
failure, and caller timeout; only storage acknowledgment clears it. A changed
or unknown account cannot acknowledge another account's journal. Malformed
journals fail visibly. Journals do not migrate between providers.

Top-level `unlock_achievement` and `get_achievements` remain available. Steam's
legacy unlock succeeds only after acknowledged storage; pending/error detail is
in metadata. Lists keep `payload.achievements`. `persisted` remains save-only.
Mock controls `simulate_achievement_pending`,
`simulate_achievement_store_failure`, and `simulate_achievements_unavailable`
exercise the shared facade without Steam.

## Lobbies, events, sessions, and UI

`await lobby.host({"visibility": "private", "max_players": 2})`,
`await lobby.join(id)`, `lobby.leave()`, and
`await lobby.open_invite_overlay()` use shared response objects; error codes are
in `metadata.error_code`. States are idle/creating/joining/joined/leaving/failed.
One membership operation is allowed. Timeouts default to 10 seconds, with a
3-second metadata wait. Native uncorrelated requests remain reserved after a
caller timeout; a late successful abandoned membership is left before reuse.

Compatibility metadata contains game/wire/protocol/content versions, match
state, pinned original authority, session token, and creator-assigned slots.
The authority remains the creator even if Steam changes its owner. Original
host departure ends the lobby (`host-left`), rather than migrating authority.
Slots stay stable while participants are present; departure frees a slot. IDs
are decimal strings outside the bridge, with persona names and `ping = -1`.

`try_send_event` returns provider acceptance, not delivery; `send_event` remains
a void convenience API. Broadcast excludes self. User/role filters intersect.
JSON-compatible data is normalized across providers; incoming identity is never
read from payload. Outsiders, wrong tokens/lobbies/versions, invalid frames,
and oversized data are discarded. Session requests are accepted only for
validated current members. Link failures surface through `event_send_failed`
and/or `transport_gap` even with an unchanged roster.

`CouchSessionTransport.pick(lobby, webrtc)` selects the existing lobby transport
for Steam even if a WebRTC extension is installed. `CouchLobbyTransport` uses
optional send acceptance and provider gaps, retaining its duck-typed fallback.
Call backend arrivals before transport/session timers: SDK backend priority is
-100; game drivers call `transport.poll(now)` then `session.poll(now)`.
Steam provider gaps require a fresh existing session hello and snapshot. Guests
block gameplay sends until that baseline; host `hello_received` handlers must
send a complete snapshot. There is no second Steam authority or snapshot system.

Instantiate `ui/couch_lobby_panel.tscn`, set title, connect
`start_game_requested`, and set `match_active` from your game. The panel offers
Host/Join/Invite/Leave according to capabilities, shows roster and status, handles
both invitation entry paths, and asks before abandoning an active match. Couch
and local relay retain their existing entry workflows. The panel owns no game
rules. Listen to session state and leave events to dispose game sessions.

## Checks and live acceptance

Run deterministic contracts (no Steam dependency or account):

```sh
python3 tests/steam/run.py --godot /path/to/Godot_v4.7-stable_linux.x86_64
```

A separate minimal fixture can be staged with
`python3 fixtures/steam/prepare.py --godotsteam-zip /path/to/pinned.zip`.
It validates the archive checksum and prints a temporary project path. Launch
with `-- --app-id=<actual-id> --achievement=<published-api-name>`. Two authorized
accounts on separate machines must host/join, exchange reliable events, start
sessions on both sides, verify snapshots and link recovery, and observe confirmed
local storage callbacks. Repeat with exported Linux and Windows builds and a
clean Web build. A development App ID can only prove transport after metadata
filtering; it cannot accept this game's achievements.

Local fake tests cover selection, unavailable dependency, init concurrency and
late completion, lifecycle cancellation/timeout cleanup, targeting, JSON/sender
parity, message rejection, unchanged-roster link failure, real session
handshake/snapshot/recovery, store batching and delayed callbacks, restart,
offline/retry behavior, read failures, and account isolation. Existing shared
netcode and WebRTC fixtures remain independent regression gates. Packaged and
live acceptance remain open until real evidence is recorded.
