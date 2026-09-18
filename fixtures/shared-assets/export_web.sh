#!/usr/bin/env bash
set -euo pipefail

# Export the same linked fixture project used by the native runner.  The output
# directory is caller-owned so a platform/workerd integration host can serve it
# at more than one URL depth without copying the SDK into either project.
fixture_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
sdk_dir=$(cd "$fixture_dir/../.." && pwd)
output_dir=${1:-"$fixture_dir/build"}
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/couch-shared-assets-web-export.XXXXXX")
cleanup() { rm -rf "$temp_dir"; }
trap cleanup EXIT

mkdir -p "$temp_dir/addons" "$output_dir"
ln -s "$fixture_dir/project.godot" "$temp_dir/project.godot"
ln -s "$fixture_dir/fixture_main.tscn" "$temp_dir/fixture_main.tscn"
ln -s "$fixture_dir/fixture_main.gd" "$temp_dir/fixture_main.gd"
ln -s "$fixture_dir/export_presets.cfg" "$temp_dir/export_presets.cfg"
ln -s "$sdk_dir" "$temp_dir/addons/couch-games-sdk"

# The first editor pass creates the project-local global class cache required by
# the addon scripts. It never modifies the checkout or downloads dependencies.
"${GODOT:-godot}" --headless --path "$temp_dir" --editor --quit
"${GODOT:-godot}" --headless --path "$temp_dir" --export-release Web \
	"$output_dir/shared-assets-fixture.html"
echo "Exported shared-assets Web fixture to $output_dir"
