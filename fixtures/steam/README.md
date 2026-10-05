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

Use two authorized accounts on separate machines. Host privately on one and
join by lobby ID or friend invitation on the other. Send the reliable event on
both sides and verify sender IDs. Start the existing lobby/session transport on
both clients; the host's `hello_received` sends a fixture snapshot. Award the
configured achievement separately on each account, checking the printed read
status and storage acknowledgment. Repeat after a link failure and host leave,
and from packaged Linux/Windows builds. This fixture is prepared but **live
acceptance has not been run**. See [SDK Steam documentation](../../docs/steam.md).

Deterministic fake-provider checks are separate:

```sh
python3 tests/steam/run.py --godot /path/to/Godot_v4.7-stable_linux.x86_64
```
