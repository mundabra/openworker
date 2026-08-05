#requires -Version 5.1
<#
.SYNOPSIS
  Build the Coworker Windows desktop app + NSIS (.exe) and MSI installers.

.DESCRIPTION
  The Windows counterpart to build_dmg.sh:
    1. PyInstaller-bundle the server into a standalone onedir folder (no venv at runtime).
    2. Stage it at binaries\sidecar\ for Tauri's `resources` slot.
    3. `tauri build --bundles nsis,msi` -> Coworker NSIS setup .exe + .msi (resources copied in).

  Prerequisites (see the toolchain notes in the PR/plan):
    - Rust (rustup) with the x86_64-pc-windows-msvc target + the MSVC C++ build tools (link.exe).
    - Node + npm (frontend build).
    - A Python venv at platform\.venv with this package installed editable, plus pyinstaller.
      `typer` is needed only at build time: PyInstaller walks the `mcp` package and `mcp.cli`
      calls sys.exit() at import if typer is absent, which aborts the freeze.
        py -m venv .venv ; .\.venv\Scripts\pip install -e ".[bedrock]" pyinstaller tzdata typer

  The result is UNSIGNED — first launch shows a SmartScreen warning ("More info" -> "Run anyway").
  Authenticode signing is a later step.

  Experimental (use-at-your-own-risk) connectors are EXCLUDED from this build by default —
  the spec strips coworker.connectors.experimental. Self-builders can opt in with:
    $env:COWORKER_EXPERIMENTAL = "1"; .\build_windows.ps1
#>
[CmdletBinding()]
param(
    # Which installer bundles to produce. Both by default.
    [string]$Bundles = "nsis,msi"
)
$ErrorActionPreference = "Stop"

$Here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$Platform = Split-Path -Parent $Here
$Gui      = Join-Path $Platform "surfaces\gui"
$Venv     = Join-Path $Platform ".venv"
$PyInst   = Join-Path $Venv "Scripts\pyinstaller.exe"

function Require-Cmd($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$name' not found on PATH. See the prerequisites in this script's header."
    }
}

Require-Cmd rustc
Require-Cmd npm
if (-not (Test-Path $PyInst)) {
    throw "PyInstaller not found at $PyInst. Create the venv and install deps (see header)."
}

# Host target triple, e.g. x86_64-pc-windows-msvc — Tauri's externalBin suffix.
$Triple = (& rustc -vV | Select-String '^host:').ToString().Split()[-1]
$Arch   = $Triple.Split('-')[0]

# A running openworker-server.exe (e.g. a prior sidecar/smoke test) locks the output exe and
# makes PyInstaller's overwrite fail with Access-is-denied. Stop any before bundling.
$running = Get-Process -Name "openworker-server" -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "==> stopping $($running.Count) running openworker-server process(es) holding the output exe"
    $running | Stop-Process -Force
    Start-Sleep -Seconds 1
}

Write-Host "==> [1/3] PyInstaller: bundling openworker-server ($Triple)" -ForegroundColor Cyan
& $PyInst --noconfirm --clean `
    --distpath (Join-Path $Here "dist") --workpath (Join-Path $Here "build") `
    (Join-Path $Here "openworker-server.spec")
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed (exit $LASTEXITCODE)" }

# Smoke test: does the frozen server actually START? PyInstaller happily produces a
# binary that dies on its first import — e.g. a bundled dependency dropping a module
# across a major version bump — and every artifact-level check still passes, because
# the artifact is fine; the program is not. PyInstaller does warn ("Failed to collect
# submodules … ImportError"), but that scrolls past in a wall of build noise, so this
# asserts on behaviour instead of asking anyone to read the log.
Write-Host "==> [1.5/3] smoke-testing the frozen server" -ForegroundColor Cyan
$SmokeExe   = Join-Path $Here "dist\openworker-server\openworker-server.exe"
$SmokeState = Join-Path ([IO.Path]::GetTempPath()) ("ocw-smoke-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $SmokeState | Out-Null
$SmokePort = 8799
$SmokeOut  = Join-Path $SmokeState "out.log"
$SmokeErr  = Join-Path $SmokeState "err.log"
# State dir via the process env: the child inherits it at spawn, and the variable is
# removed straight after so nothing later in this script (npm, tauri) sees it.
$env:COWORKER_STATE_DIR = $SmokeState
try {
    $Smoke = Start-Process -FilePath $SmokeExe `
        -ArgumentList "--host", "127.0.0.1", "--port", "$SmokePort" `
        -RedirectStandardOutput $SmokeOut -RedirectStandardError $SmokeErr `
        -NoNewWindow -PassThru
} finally {
    Remove-Item Env:\COWORKER_STATE_DIR -ErrorAction SilentlyContinue
}
$SmokeOk = $false
for ($Try = 0; $Try -lt 40; $Try++) {
    Start-Sleep -Seconds 1
    if ($Smoke.HasExited) { break }   # died — stop waiting, report below
    try {
        # /v1/health is the designated tokenless endpoint (app.py `tokenless_paths`) —
        # liveness without the sidecar token the Tauri shell would normally inject.
        Invoke-WebRequest -Uri "http://127.0.0.1:$SmokePort/v1/health" `
            -UseBasicParsing -TimeoutSec 2 | Out-Null
        $SmokeOk = $true
        break
    } catch { }
}
if (-not $Smoke.HasExited) { Stop-Process -Id $Smoke.Id -Force -ErrorAction SilentlyContinue }
if (-not $SmokeOk) {
    Write-Host "ERROR: the frozen server does not start — refusing to build an app with a dead backend." -ForegroundColor Red
    Write-Host "--- last 20 lines of its output ---"
    Get-Content $SmokeOut, $SmokeErr -ErrorAction SilentlyContinue | Select-Object -Last 20
    throw "frozen-server smoke test failed"
}
Remove-Item -Recurse -Force $SmokeState -ErrorAction SilentlyContinue
Write-Host "    server starts and answers /v1/health"

Write-Host "==> [2/3] staging sidecar resources" -ForegroundColor Cyan
# Onedir bundle (exe + _internal\) ships via Tauri `resources`, landing at <install>\sidecar\
# next to the app exe — onefile's per-launch self-extraction cost seconds of boot splash.
$BinDir = Join-Path $Gui "src-tauri\binaries"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
$Src = Join-Path $Here "dist\openworker-server"
$Dst = Join-Path $BinDir "sidecar"
if (Test-Path $Dst) { Remove-Item -Recurse -Force $Dst }
# Clear any stale onefile binary from pre-onedir builds.
Remove-Item -Force (Join-Path $BinDir "openworker-server-$Triple.exe") -ErrorAction SilentlyContinue
Copy-Item -Recurse -Force $Src $Dst
Write-Host "    -> $Dst"

Write-Host "==> [3/3] tauri build (--bundles $Bundles)" -ForegroundColor Cyan
# Auto-update artifacts (NSIS setup .exe + minisign .sig): produced only when the updater
# signing key env is present (CI secret TAURI_SIGNING_PRIVATE_KEY). Keyless builds skip
# the overlay so dev builds keep working; keyless RELEASES strand installs without
# auto-update.
$UpdaterArgs = @()
if ($env:TAURI_SIGNING_PRIVATE_KEY) {
    # Pass the overlay as a FILE: inline JSON loses its quotes through the
    # PowerShell -> npm.cmd -> cmd hop ("key must be a string", v0.1.3 run).
    $Overlay = Join-Path ([IO.Path]::GetTempPath()) "ocw-updater-overlay.json"
    Set-Content -Path $Overlay -Value '{"bundle":{"createUpdaterArtifacts":true}}' -Encoding ascii
    $UpdaterArgs = @("--config", $Overlay)
} else {
    Write-Host "    WARNING: no updater signing key - building WITHOUT auto-update artifacts (not releasable)." -ForegroundColor Yellow
}
Push-Location $Gui
try {
    & npm run tauri build -- --bundles $Bundles @UpdaterArgs
    if ($LASTEXITCODE -ne 0) { throw "tauri build failed (exit $LASTEXITCODE)" }
}
finally {
    Pop-Location
}

$BundleDir = Join-Path $Gui "src-tauri\target\release\bundle"
Write-Host ""
Write-Host "Done. Installers under: $BundleDir" -ForegroundColor Green
Get-ChildItem -Path $BundleDir -Recurse -Include *.exe, *.msi -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  $($_.FullName)" }
