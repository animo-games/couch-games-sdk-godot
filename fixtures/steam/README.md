# Steam acceptance fixture

From the SDK root:

```sh
python fixtures/steam/run.py --app-id 5310050 --visibility public
```

Requires Python 3.11+ and Steam running on Linux or Windows x86_64. On Linux,
use `python3` if `python` is unavailable. The launcher downloads and verifies
only the pinned ordinary Godot engine and GodotSteam archive, imports an isolated
project, and opens the interactive fixture. It prints the project and log paths.
Keep the terminal open for event and snapshot output. Each computer needs a
different Steam account with access to the supplied app.

The fixture also shows initialization, send acceptance, received messages,
session state, and applied `BASELINE` results in its window. Steam accepting a
send does not confirm delivery; check the other client's receive output.
The achievement control stays disabled until a published API name is supplied
with `--achievement NAME`. This enables manual read/award testing; no achievement
is awarded merely by starting the launcher.

The example deliberately hosts a public two-slot SDK test lobby for joining by
ID. On one computer, click **Host**. Copy the lobby ID displayed beside `joined`
into the other computer's **Lobby ID** field and click **Join**. Send the
reliable fixture event from each side and check the other client's `EVENT`
output. Click **Start local session** on both sides and check the guest's
applied `BASELINE` output, which is separate from receiving a raw snapshot packet.
Closing the UI is not a passed acceptance result; record the observed messages,
snapshot and any errors. The game project does not participate in these tests.

The default remains `--visibility private`, which requires a Steam invitation;
an ID alone does not grant entry. Use **Invite** and accept the invitation from
the other signed-in account while its fixture is already running. Friends-only
mode is available with `--visibility friends`. These follow
[Steam's lobby visibility rules](https://partner.steamgames.com/doc/api/ISteamMatchmaking#ELobbyType).

For the headless single-account probe, add `--probe`. It exits nonzero on
initialization, membership or cleanup failures. The launcher keeps the App ID
as an explicit runtime argument; other apps can supply their own ID.

Manual staging remains available:

```sh
python3 fixtures/steam/prepare.py --godotsteam-zip /path/to/godotsteam-4.23-gdextension-plugin-4.4.zip
```

The script verifies the pinned archive checksum and stages a temporary project.
It never installs dependencies in a game. Use Godot 4.7 stable to import/run the
printed directory; pass `-- --app-id=<actual-id> --achievement=<published-name>`.
No App ID or definition is fabricated. Without Steam installed, the fixture
shows a failed Steam initialization instead of using mock.

Run the single-account native initialization/private-lobby/leave probe with:

```sh
godot --headless --path /printed/fixture --editor --import --quit
godot --headless --path /printed/fixture \
  --script addons/couch-games-sdk/fixtures/steam/probe.gd -- --app-id=<actual-id>
```

The probe requires actual Steam initialization for the supplied app, a logged-on
account, successful private lobby creation/entry, and clean leave/teardown.
It sends no invitations or peer messages and awards no achievements. Failures
exit nonzero; a fake or mock provider never counts as live acceptance. Staging
registers extension descriptors before engine startup and isolates fixture data.

Use two authorized accounts on separate machines. Host publicly for the
join-by-ID test, then repeat with a private lobby and a Steam friend invitation. Send the reliable event on
both sides and verify sender IDs. Start the existing lobby/session transport on
both clients; the host's `hello_received` sends a fixture snapshot. Award the
configured achievement separately on each account, checking the printed read
status and storage acknowledgment. Repeat after a link failure and host leave,
and from packaged Linux/Windows builds. Single-account Linux initialization and
private lobby creation/leave passed for app `5310050` on October 8, 2026. A
Linux/Windows public lobby, reliable events in both directions and an applied
session baseline also passed with two distinct accounts. Invitation, link recovery,
host-leave, achievement and packaged live acceptance remain open. See
[SDK Steam documentation](../../docs/steam.md).

Deterministic fake-provider checks are separate:

```sh
python3 tests/steam/run.py --godot /path/to/Godot_v4.7-stable_linux.x86_64
```
