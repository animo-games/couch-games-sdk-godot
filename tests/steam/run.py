#!/usr/bin/env python3
"""Run Steam contracts with no Steam or network dependency, in a disposable project."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--godot", required=True)
args = parser.parse_args()
sdk = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="couch-steam-contracts-") as folder:
    project = Path(folder)
    shutil.copytree(sdk, project / "addons/couch-games-sdk", ignore=shutil.ignore_patterns(".git", ".godot", "docs"))
    (project / "project.godot").write_text('''config_version=5
[application]
config/name="Steam SDK deterministic contracts"
config/use_custom_user_dir=true
config/custom_user_dir="%s/user"
[rendering]
renderer/rendering_method="gl_compatibility"
''' % project)
    for arguments in [["--editor", "--import", "--quit"], ["--script", "addons/couch-games-sdk/tests/steam/contracts.gd"]]:
        result = subprocess.run([args.godot, "--headless", "--path", str(project), *arguments], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        print(result.stdout, end="")
        if result.returncode or "SCRIPT ERROR" in result.stdout or "FAIL:" in result.stdout:
            raise SystemExit(result.returncode or 1)
