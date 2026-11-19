#!/usr/bin/env python3
"""Steam-free contracts; --regressions also requires the pinned corpus and WebRTC."""
import argparse
from pathlib import Path
import shutil
import tempfile
from support import LOCK, SDK, check_engine, extract, fixture_digest, run, stage_sdk, verify, register_extensions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True, type=Path)
    parser.add_argument('--regressions', action='store_true')
    parser.add_argument('--fixtures', type=Path)
    parser.add_argument('--webrtc-zip', type=Path)
    parser.add_argument('--logs', type=Path)
    args = parser.parse_args()
    check_engine(args.godot)
    if args.regressions:
        if not args.fixtures or not args.webrtc_zip:
            parser.error('--regressions requires --fixtures and --webrtc-zip; checks are never skipped')
        if fixture_digest(args.fixtures) != LOCK['fixtures']['content_sha256']:
            raise RuntimeError('Fixture data differs from the pinned corpus')
        verify(args.webrtc_zip, LOCK['webrtc'])
    with tempfile.TemporaryDirectory(prefix='couch-steam-contracts-') as folder:
        project = Path(folder)
        addon = stage_sdk(project)
        # Test fixture sources are intentionally absent from exported artifacts.
        shutil.copytree(SDK / 'tests', addon / 'tests', ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copytree(SDK / 'netcode/fixtures', addon / 'netcode/fixtures')
        shutil.copytree(SDK / 'fixtures/steam', addon / 'fixtures/steam', ignore=shutil.ignore_patterns('package', '__pycache__'))
        (project / 'project.godot').write_text('''config_version=5
[application]
config/name="Steam SDK deterministic contracts"
config/use_custom_user_dir=true
config/custom_user_dir="%s/user"
[threading]
worker_pool/max_threads=4
[rendering]
renderer/rendering_method="gl_compatibility"
''' % project.as_posix())
        def execute(name, arguments, marker=None):
            log = args.logs / (name + '.log') if args.logs else None
            return run([args.godot, '--headless', '--path', project, *arguments], project, marker, log=log)
        execute('import-steam-free', ['--editor', '--import', '--quit'])
        execute('contracts', ['--script', 'addons/couch-games-sdk/tests/steam/contracts.gd'], '0 failures')
        if not args.regressions:
            return
        extract(args.webrtc_zip, project)
        register_extensions(project)
        execute('import-webrtc', ['--editor', '--import', '--quit'])
        checks = [
            ('netcode/fixtures/run_fixtures.gd', '117 passed, 0 failed, 0 awaiting port', ['--fixtures=' + str(args.fixtures.resolve() / 'data')]),
            ('netcode/fixtures/run_transport_fixtures.gd', '44 passed, 0 failed', ['--fixtures=' + str(args.fixtures.resolve() / 'transport/data')]),
            ('netcode/fixtures/run_session_players.gd', 'COUCH_SESSION_PLAYERS_OK:', []),
            ('netcode/fixtures/run_transport_faults.gd', 'total assertions: 0 failed', []),
            ('tests/session_transport_test.gd', 'SESSION_TRANSPORT_TEST_OK', []),
            ('tests/webrtc_signaling_reconnect_test.gd', 'WEBRTC_SIGNALING_RECONNECT_TEST: PASS', []),
            ('tests/webrtc_connection_handler_test.gd', 'WEBRTC_CONNECTION_HANDLER_TEST: PASS', []),
            ('tests/webrtc_probe_test.gd', 'WEBRTC_PROBE_TEST_OK', []),
            ('tests/local_lobby_smoke.gd', 'LOCAL_LOBBY_SMOKE: PASS', []),
        ]
        for script, marker, extra in checks:
            output = execute(Path(script).stem, ['--script', 'addons/couch-games-sdk/' + script, '--', *extra], marker)
            if 'unimplemented' in output.lower():
                import re
                if re.search(r'unimplemented\s+[1-9]', output.lower()):
                    raise RuntimeError('Required corpus contains unimplemented cases')


if __name__ == '__main__':
    main()
