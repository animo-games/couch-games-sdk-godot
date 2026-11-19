"""Shared deterministic staging, dependency verification and strict process checks."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

SDK = Path(__file__).resolve().parents[2]
LOCK = json.loads((SDK / 'tests/steam/dependency-lock.json').read_text())
STEAM_LOCK = json.loads((SDK / 'steam/dependency-lock.json').read_text())
RUNTIME_DIRS = ('achievements', 'backends', 'core', 'debug', 'experience', 'game',
                'lobby', 'netcode', 'steam', 'ui', 'webrtc', 'editor')


def verify(path, pin):
    algorithm = 'sha512' if 'sha512' in pin else 'sha256'
    digest = hashlib.new(algorithm)
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != pin[algorithm]:
        raise RuntimeError(f'Checksum mismatch: {path}')


def acquire(pin, cache):
    path = Path(cache) / pin['url'].rsplit('/', 1)[1]
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        partial = path.with_suffix(path.suffix + '.download')
        with urllib.request.urlopen(pin['url'], timeout=60) as response, partial.open('wb') as stream:
            shutil.copyfileobj(response, stream)
        verify(partial, pin)
        partial.replace(path)
    verify(path, pin)
    return path


def extract(archive, destination):
    destination = Path(destination).resolve()
    with zipfile.ZipFile(archive) as source:
        for entry in source.infolist():
            if not (destination / entry.filename).resolve().is_relative_to(destination):
                raise RuntimeError('Unsafe archive path')
        source.extractall(destination)


def stage_sdk(project):
    addon = Path(project) / 'addons/couch-games-sdk'
    for folder in RUNTIME_DIRS:
        shutil.copytree(SDK / folder, addon / folder,
                        ignore=shutil.ignore_patterns('__pycache__', '*.pyc', 'fixtures'))
    shutil.copy2(SDK / 'plugin.cfg', addon / 'plugin.cfg')
    return addon


def environment(project):
    env = os.environ.copy()
    # Keep system HOME intact; isolate Godot configuration/cache/data explicitly.
    for key, folder in [('XDG_CONFIG_HOME', 'config'), ('XDG_CACHE_HOME', 'cache'), ('XDG_DATA_HOME', 'data')]:
        env[key] = str(Path(project).parent / (Path(project).name + '-isolated') / folder)
    # Tests must not borrow an installed Steam application's identity.
    for key in ('SteamAppId', 'SteamGameId'):
        env.pop(key, None)
    return env


def run(command, project, marker=None, timeout=90, log=None):
    # A regular output file also keeps large fixture output from filling a pipe.
    with tempfile.TemporaryFile(mode='w+', encoding='utf-8') as capture:
        result = subprocess.run(list(map(str, command)), cwd=project, env=environment(project),
                                stdout=capture, stderr=subprocess.STDOUT, timeout=timeout)
        capture.seek(0)
        output = capture.read()
    if log:
        Path(log).parent.mkdir(parents=True, exist_ok=True)
        Path(log).write_text(output)
    bad = result.returncode or 'SCRIPT ERROR' in output or 'FAIL:' in output
    if marker and marker not in output:
        bad = True
    if bad:
        print(output)
        raise RuntimeError(f'Check failed ({result.returncode}): {command}; required marker: {marker}')
    print(f'PASS: {marker or command[-1]}')
    return output


def check_engine(godot):
    output = subprocess.check_output([str(godot), '--version'], text=True).strip()
    if output != STEAM_LOCK['godot']:
        raise RuntimeError(f'Expected {STEAM_LOCK["godot"]}, got {output}')


def fixture_digest(folder):
    folder = Path(folder)
    digest = hashlib.sha256()
    paths = [folder / 'manifest.json', *sorted((folder / 'data').rglob('*.json')),
             *sorted((folder / 'transport').rglob('*.json'))]
    for path in paths:
        digest.update(path.relative_to(folder).as_posix().encode() + b'\0')
        digest.update(path.read_bytes() + b'\0')
    return digest.hexdigest()


def register_extensions(project):
    # Load dependencies at engine startup. Godot 4.7 can abort on editor exit
    # when a newly discovered extension is hot-loaded during --import.
    project = Path(project)
    descriptors = sorted(project.glob('addons/**/*.gdextension'))
    cache = project / '.godot'
    cache.mkdir(exist_ok=True)
    (cache / 'extension_list.cfg').write_text(''.join('res://' + p.relative_to(project).as_posix() + '\n' for p in descriptors))
