# Steam acceptance fixture

From the SDK root:

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

Use two authorized accounts on separate machines. Host privately on one and
join by lobby ID or friend invitation on the other. Send the reliable event on
both sides and verify sender IDs. Start the existing lobby/session transport on
both clients; the host's `hello_received` sends a fixture snapshot. Award the
configured achievement separately on each account, checking the printed read
status and storage acknowledgment. Repeat after a link failure and host leave,
and from packaged Linux/Windows builds. Single-account Linux initialization and
private lobby creation/leave passed for app `5310050` on October 8, 2026; the
two-account and achievement matrix remains open. See
[SDK Steam documentation](../../docs/steam.md).

Deterministic fake-provider checks are separate:

```sh
python3 tests/steam/run.py --godot /path/to/Godot_v4.7-stable_linux.x86_64
```
