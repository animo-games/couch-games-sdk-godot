#!/usr/bin/env bash
set -euo pipefail

# Make a disposable Godot project whose only addon entry is a symlink to this
# checkout.  No addon tree is copied into the fixture and nothing is downloaded.
fixture_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
sdk_dir=$(cd "$fixture_dir/../.." && pwd)
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/couch-shared-assets-fixture.XXXXXX")
cleanup() { rm -rf "$temp_dir"; }
trap cleanup EXIT

mkdir -p "$temp_dir/addons"
ln -s "$fixture_dir/project.godot" "$temp_dir/project.godot"
ln -s "$fixture_dir/fixture_main.tscn" "$temp_dir/fixture_main.tscn"
ln -s "$fixture_dir/fixture_main.gd" "$temp_dir/fixture_main.gd"
ln -s "$fixture_dir/runner.gd" "$temp_dir/runner.gd"
ln -s "$fixture_dir/fixture_http_backend.gd" "$temp_dir/fixture_http_backend.gd"
ln -s "$sdk_dir" "$temp_dir/addons/couch-games-sdk"

# Godot builds its global class cache per project. Generate it in the disposable
# project first so addon scripts that use class_name inheritance resolve exactly
# as they do in a game project, then run the headless fixture.
"${GODOT:-godot}" --headless --path "$temp_dir" --editor --quit
"${GODOT:-godot}" --headless --path "$temp_dir" --script res://runner.gd
