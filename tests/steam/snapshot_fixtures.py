#!/usr/bin/env python3
"""Refresh the offline CI snapshot from the exact clean authoritative corpus pin."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile
from support import LOCK, SDK, fixture_digest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('checkout', type=Path)
args = parser.parse_args()
checkout = args.checkout.resolve()
commit = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
dirty = subprocess.check_output(['git', '-C', str(checkout), 'status', '--porcelain'], text=True).strip()
if dirty or commit != LOCK['fixtures']['commit'] or fixture_digest(checkout) != LOCK['fixtures']['content_sha256']:
    raise SystemExit('Checkout/content does not match the authoritative fixture pin; update the lock explicitly first')
paths = [checkout / 'manifest.json', *sorted((checkout / 'data').rglob('*.json')),
         *sorted((checkout / 'transport').rglob('*.json'))]
snapshot = SDK / 'tests/steam/corpus.zip'
with zipfile.ZipFile(snapshot, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in paths:
        entry = zipfile.ZipInfo(path.relative_to(checkout).as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
        entry.compress_type = zipfile.ZIP_DEFLATED
        entry.external_attr = 0o100644 << 16
        archive.writestr(entry, path.read_bytes())
lock_path = SDK / 'tests/steam/dependency-lock.json'
lock = json.loads(lock_path.read_text())
lock['fixtures']['snapshot'] = 'tests/steam/corpus.zip'
lock['fixtures']['sha256'] = hashlib.sha256(snapshot.read_bytes()).hexdigest()
lock_path.write_text(json.dumps(lock, indent=2) + '\n')
print(snapshot)
