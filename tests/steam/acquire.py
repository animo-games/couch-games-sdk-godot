#!/usr/bin/env python3
"""Acquire checksum-pinned CI tools; does not install anything in a consumer."""
import argparse
import json
import os
from pathlib import Path
import platform
from support import LOCK, STEAM_LOCK, SDK, verify, fixture_digest, acquire, extract


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', required=True, type=Path)
    args = parser.parse_args()
    host = 'windows' if platform.system() == 'Windows' else 'linux'
    engine = acquire(LOCK[host], args.cache)
    destination = args.cache / ('engine-' + host)
    # Re-extract verified bytes so a stale/modified cached executable cannot
    # bypass archive verification. The cache is dedicated to this fixture.
    extract(engine, destination)
    name = 'Godot_v4.7-stable_win64_console.exe' if host == 'windows' else 'Godot_v4.7-stable_linux.x86_64'
    godot = (destination / name).resolve()
    godot.chmod(0o755)
    paths = {'godot': str(godot), 'templates': str(acquire(LOCK['templates'], args.cache).resolve()),
             'steam': str(acquire(STEAM_LOCK, args.cache).resolve()),
             'webrtc': str(acquire(LOCK['webrtc'], args.cache).resolve())}
    corpus = SDK / LOCK['fixtures']['snapshot']
    verify(corpus, LOCK['fixtures'])
    fixtures = args.cache / 'fixtures'
    extract(corpus, fixtures)
    if fixture_digest(fixtures) != LOCK['fixtures']['content_sha256']:
        raise RuntimeError('Extracted fixture snapshot does not match content pin')
    paths['fixtures'] = str(fixtures.resolve())
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            for key, value in paths.items(): stream.write(f'{key}={value}\n')
    print(json.dumps(paths, indent=2))


if __name__ == '__main__': main()
