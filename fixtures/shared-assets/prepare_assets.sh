#!/usr/bin/env bash
set -euo pipefail

# Make only the fixture source project in a temporary directory; the requested
# output contains the binary object, valid zero-byte object, and valid PCK that
# the workerd/R2 integration publishes through the real API helpers.
fixture_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
output_dir=${1:?usage: prepare_assets.sh /absolute/output/directory}
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/couch-shared-assets-builder.XXXXXX")
cleanup() { rm -rf "$temp_dir"; }
trap cleanup EXIT

ln -s "$fixture_dir/asset_project.godot" "$temp_dir/project.godot"
ln -s "$fixture_dir/prepare_assets.gd" "$temp_dir/prepare_assets.gd"
"${GODOT:-godot}" --headless --path "$temp_dir" --script res://prepare_assets.gd -- \
	"--output=$output_dir"
