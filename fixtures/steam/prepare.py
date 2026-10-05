#!/usr/bin/env python3
"""Stage a disposable fixture. Never install native libraries in an SDK consumer."""
import argparse
import hashlib
from pathlib import Path
import shutil
import tempfile
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument("--godotsteam-zip", type=Path)
args = parser.parse_args()
sdk = Path(__file__).resolve().parents[2]
destination = Path(tempfile.mkdtemp(prefix="couch-steam-fixture-"))
shutil.copytree(sdk, destination / "addons/couch-games-sdk", ignore=shutil.ignore_patterns(".git", ".godot", "docs"))
if args.godotsteam_zip:
    import json
    lock = json.loads((sdk / "steam/dependency-lock.json").read_text())
    digest = hashlib.sha256(args.godotsteam_zip.read_bytes()).hexdigest()
    if digest != lock["sha256"]:
        raise SystemExit("GodotSteam archive checksum does not match dependency-lock.json")
    with zipfile.ZipFile(args.godotsteam_zip) as archive:
        for entry in archive.infolist():
            target = (destination / entry.filename).resolve()
            if not target.is_relative_to(destination):
                raise SystemExit("Unsafe archive path")
        archive.extractall(destination)
(destination / "project.godot").write_text('''config_version=5
[application]
config/name="Couch Steam Fixture"
run/main_scene="res://addons/couch-games-sdk/fixtures/steam/main.tscn"
config/features=PackedStringArray("4.7")
[steam]
initialization/processes/initialize_on_startup=false
initialization/processes/embed_callbacks=false
[rendering]
renderer/rendering_method="gl_compatibility"
''')
print(destination)
