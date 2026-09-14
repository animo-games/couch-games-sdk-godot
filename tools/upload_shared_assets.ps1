# Windows launcher for upload_shared_assets.gd. The walk, protocol and
# upload all happen in the .gd, so the logic stays the same across platforms
# and needs no external curl/jq. This only locates the Godot binary and hands
# off; see upload_shared_assets.sh for the macOS/Linux equivalent.
# Usage: .\addons\couch-games-sdk\tools\upload_shared_assets.ps1 <game-slug> [dir] [--overwrite]
param(
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]]$Args
)
$ErrorActionPreference = "Stop"

$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Project = (Resolve-Path (Join-Path $Dir "..\..\..")).Path

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
    --script "res://addons/couch-games-sdk/tools/upload_shared_assets.gd" -- @Args
exit $LASTEXITCODE
