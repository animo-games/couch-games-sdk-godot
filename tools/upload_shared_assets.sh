#!/usr/bin/env bash
# macOS/Linux launcher for upload_shared_assets.gd. The walk, protocol and
# upload all happen in the .gd, so the logic stays the same across platforms
# and needs no external curl/jq. This only locates the Godot binary and hands
# off; see upload_shared_assets.ps1 for the Windows equivalent.
# Usage: ./addons/couch-games-sdk/tools/upload_shared_assets.sh <game-slug> [dir] [--overwrite]
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: upload_shared_assets.sh <game-slug> [dir] [--overwrite]" >&2
  exit 2
fi
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$DIR/../../.." && pwd)"

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
  --script "res://addons/couch-games-sdk/tools/upload_shared_assets.gd" -- "$@"
