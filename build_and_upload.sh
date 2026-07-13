#!/usr/bin/env bash
# Thin macOS/Linux launcher for build_and_upload.gd.
# All the real work (export, zip, upload) happens in the .gd so the logic stays
# identical across platforms and needs no external zip/curl/jq. This wrapper only
# locates the Godot binary and hands off; see build_and_upload.ps1 for Windows.
# Usage: ./addons/couch-games-sdk/build_and_upload.sh <game-slug>
set -euo pipefail

SLUG="${1:?usage: build_and_upload.sh <game-slug>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$DIR/../.." && pwd)"

# Source .env so a GODOT override (and COUCHGAMES_API_KEY) reach both this
# launcher and the child Godot process.
if [ -f "$PROJECT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$PROJECT/.env"
  set +a
fi

GODOT="${GODOT:-$HOME/.local/share/godot/app_userdata/Godots/versions/Godot_v4_7-stable_linux_x86_64/Godot_v4.7-stable_linux.x86_64}"

exec "$GODOT" --headless --path "$PROJECT" \
  --script "res://addons/couch-games-sdk/build_and_upload.gd" -- "$SLUG"
