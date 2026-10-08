#!/usr/bin/env python3
"""Stage a disposable fixture. Never install native libraries in an SDK consumer."""
import argparse
from pathlib import Path
import shutil
import sys
import tempfile

sdk = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(sdk / 'tests/steam'))
from support import STEAM_LOCK, extract, register_extensions, stage_sdk, verify

parser = argparse.ArgumentParser()
parser.add_argument("--godotsteam-zip", type=Path)
args = parser.parse_args()
destination = Path(tempfile.mkdtemp(prefix="couch-steam-fixture-"))
addon = stage_sdk(destination)
fixture = addon / 'fixtures/steam'
fixture.mkdir(parents=True)
for name in ('main.gd', 'main.tscn', 'probe.gd'):
    shutil.copy2(sdk / 'fixtures/steam' / name, fixture / name)
if args.godotsteam_zip:
    verify(args.godotsteam_zip, STEAM_LOCK)
    extract(args.godotsteam_zip, destination)
    register_extensions(destination)
(destination / "project.godot").write_text('''config_version=5
[application]
config/name="Couch Steam Fixture"
run/main_scene="res://addons/couch-games-sdk/fixtures/steam/main.tscn"
config/features=PackedStringArray("4.7")
config/use_custom_user_dir=true
config/custom_user_dir="%s/user"
[steam]
initialization/processes/initialize_on_startup=false
initialization/processes/embed_callbacks=false
[rendering]
renderer/rendering_method="gl_compatibility"
''' % destination.as_posix())
print(destination)
