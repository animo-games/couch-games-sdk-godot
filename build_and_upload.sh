#!/usr/bin/env bash
# Build the web export and push it to couchgames.com as a new dev version.
# Uploads straight to the dev portal API (POST /api/games/<slug>/versions,
# X-API-Key auth) — no platform-dev checkout needed. Requires zip + curl.
# Usage: ./addons/couch-games-sdk/build_and_upload.sh <game-slug>
# Assumes it lives at <project>/addons/couch-games-sdk/ inside a Godot
# project with a "Web" export preset. Reads COUCHGAMES_API_KEY (and optional
# GODOT / DEV_PORTAL_URL overrides) from a .env file at the project root,
# or from the environment.
set -euo pipefail

SLUG="${1:?usage: build_and_upload.sh <game-slug>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$DIR/../.." && pwd)"

if [ -f "$PROJECT/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$PROJECT/.env"
  set +a
fi

GODOT="${GODOT:-$HOME/.local/share/godot/app_userdata/Godots/versions/Godot_v4_7-stable_linux_x86_64/Godot_v4.7-stable_linux.x86_64}"
DEV_PORTAL_URL="${DEV_PORTAL_URL:-https://developer.couchgames.com}"

# NB: no apostrophes in this message — bash 5.3 parses quotes inside "${...:?...}"
# per POSIX, so a stray ' pairs with the trap line below and mangles the script.
: "${COUCHGAMES_API_KEY:?COUCHGAMES_API_KEY environment variable is required (create one via the API Keys page of the dev portal)}"

mkdir -p "$PROJECT/build/web"
# .gdignore keeps Godot from importing previous export output (icons etc.)
# back into the next build.
touch "$PROJECT/build/.gdignore"
"$GODOT" --headless --path "$PROJECT" --export-release "Web" "$PROJECT/build/web/index.html"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ZIP_PATH="$TMP_DIR/build.zip"

# Zip the *contents* of build/web so index.html etc. land at the zip root —
# the upload endpoint extracts each entry to games/<slug>/v<n>/<path> verbatim.
(cd "$PROJECT/build/web" && zip -r -X -q "$ZIP_PATH" .)

echo "Uploading $(du -h "$ZIP_PATH" | cut -f1) build to $DEV_PORTAL_URL ..."
RESPONSE="$(curl -sS -w '\n%{http_code}' \
  -X POST "$DEV_PORTAL_URL/api/games/$SLUG/versions" \
  -H "X-API-Key: $COUCHGAMES_API_KEY" \
  -F "gameFile=@$ZIP_PATH;type=application/zip")"
HTTP_CODE="${RESPONSE##*$'\n'}"
BODY="${RESPONSE%$'\n'*}"

if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
  echo "Upload failed (HTTP $HTTP_CODE):" >&2
  echo "$BODY" >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  if [ "$(echo "$BODY" | jq -r '.success // false')" != "true" ]; then
    echo "Upload failed (HTTP $HTTP_CODE):" >&2
    echo "$BODY" | jq . >&2
    exit 1
  fi
  echo "Uploaded version $(echo "$BODY" | jq -r .versionNumber) ($(echo "$BODY" | jq -r .filesUploaded) files) — now the isDeveloperActive build for \"$SLUG\"."
else
  echo "$BODY"
fi
echo "Play: https://couchgames.com/games/$SLUG"
