#!/usr/bin/env python3
"""Download pinned native tools and launch the standalone Steam SDK fixture."""
import argparse
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
SDK = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SDK / 'tests/steam'))
from support import LOCK, STEAM_LOCK, acquire, check_engine, environment, extract, run


def positive_id(value):
    if not value.isdecimal() or not 0 < int(value) <= 0xFFFFFFFF:
        raise argparse.ArgumentTypeError('App ID must be a positive 32-bit integer')
    return int(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app-id', required=True, type=positive_id)
    parser.add_argument('--cache', type=Path,
                        default=Path(tempfile.gettempdir()) / 'couch-steam-live-tools')
    parser.add_argument('--probe', action='store_true',
                        help='Run the headless single-account create/leave probe instead of the UI')
    parser.add_argument('--visibility', choices=('private', 'friends', 'public'), default='private',
                        help='Interactive host visibility; the headless probe always uses a private lobby')
    args = parser.parse_args()
    system = platform.system()
    if system not in ('Linux', 'Windows') or platform.machine().lower() not in ('x86_64', 'amd64'):
        parser.error('The pinned fixture supports Linux and Windows x86_64 only')
    host = 'windows' if system == 'Windows' else 'linux'
    cache = args.cache.resolve()
    print('Acquiring checksum-pinned Godot and GodotSteam (no export templates needed).', flush=True)
    archive = acquire(LOCK[host], cache)
    engine_dir = cache / ('live-engine-' + host)
    extract(archive, engine_dir)
    name = 'Godot_v4.7-stable_win64_console.exe' if host == 'windows' else 'Godot_v4.7-stable_linux.x86_64'
    godot = engine_dir / name
    godot.chmod(0o755)
    check_engine(godot)
    steam = acquire(STEAM_LOCK, cache)
    # prepare.py verifies the extension again, registers startup descriptors,
    # stages runtime sources only, and isolates this fixture's user data.
    project = Path(subprocess.check_output([
        sys.executable, '-B', str(SDK / 'fixtures/steam/prepare.py'),
        '--godotsteam-zip', str(steam),
    ], text=True, cwd=SDK).strip())
    run([godot, '--headless', '--path', project, '--editor', '--import', '--quit'],
        project, log=project / 'import.log')
    log = project / ('probe.log' if args.probe else 'interactive.log')
    print(json.dumps({'fixture': str(project), 'godot': str(godot),
                      'app_id': args.app_id, 'log': str(log)}, indent=2), flush=True)
    command = [godot, '--path', project]
    if args.probe:
        output = run([*command, '--headless', '--script',
                      'addons/couch-games-sdk/fixtures/steam/probe.gd', '--',
                      '--app-id=' + str(args.app_id)], project, 'STEAM_LIVE_PROBE:', log=log)
        result = json.loads(next(line.split('STEAM_LIVE_PROBE:', 1)[1]
                            for line in output.splitlines() if line.startswith('STEAM_LIVE_PROBE:')))
        if result['failures'] or result.get('actual_app_id') != str(args.app_id):
            raise RuntimeError('Live probe did not verify the requested Steam app')
        print(json.dumps(result, indent=2))
    else:
        print('Keep Steam signed in. Host visibility: ' + args.visibility + '.', flush=True)
        if args.visibility == 'private':
            print('Private lobbies require a Steam invitation. Use --visibility public for a join-by-ID test.', flush=True)
        else:
            print('Host on one computer; paste its lobby ID and Join on the other. Friends-only lobbies require friendship or an invitation.', flush=True)
        # Preserve a terminal for peer event/snapshot output. Normal UI exit is
        # not a passed live test; the UI and logs show each actual result.
        result = subprocess.run(list(map(str, [*command, '--log-file', log, '--',
            '--app-id=' + str(args.app_id), '--visibility=' + args.visibility])), cwd=project, env=environment(project))
        if result.returncode:
            raise SystemExit(result.returncode)
        if log.exists() and 'SCRIPT ERROR' in log.read_text(encoding='utf-8', errors='replace'):
            raise RuntimeError('The fixture reported a script error; see ' + str(log))


if __name__ == '__main__':
    main()
