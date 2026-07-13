# Thin Windows launcher for build_and_upload.gd.
# All the real work (export, zip, upload) happens in the .gd so the logic stays
# identical across platforms and needs no external zip/curl/jq. This wrapper only
# locates the Godot binary and hands off; see build_and_upload.sh for macOS/Linux.
# Usage: .\addons\couch-games-sdk\build_and_upload.ps1 <game-slug>
param([Parameter(Mandatory = $true)][string]$Slug)
$ErrorActionPreference = "Stop"

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Project = (Resolve-Path (Join-Path $Dir "..\..")).Path

# Load .env so a GODOT override (and COUCHGAMES_API_KEY) reach both this
# launcher and the child Godot process.
$EnvFile = Join-Path $Project ".env"
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | ForEach-Object {
        if ($_ -match '^\s*([^#=]+)=(.*)$') {
            $val = $matches[2].Trim().Trim('"').Trim("'")
            [Environment]::SetEnvironmentVariable($matches[1].Trim(), $val)
        }
    }
}

# GODOT can point at godot.exe; otherwise rely on it being on PATH.
$Godot = if ($env:GODOT) { $env:GODOT } else { "godot" }

& $Godot --headless --path $Project `
    --script "res://addons/couch-games-sdk/build_and_upload.gd" -- $Slug
exit $LASTEXITCODE
