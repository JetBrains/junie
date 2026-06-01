#
# DO NOT EDIT — generated from templates/install.ps1.template by templates/generate.sh
# Junie CLI Installer for Windows
# Usage: irm https://junie.jetbrains.com/install.ps1 | iex
#
# To install a specific version:
#   $env:JUNIE_VERSION="656.1"; irm https://junie.jetbrains.com/install.ps1 | iex
#

$ErrorActionPreference = 'Stop'

$CHANNEL = "experimental"
$UPDATE_INFO_URL = "https://raw.githubusercontent.com/jetbrains-junie/junie/main/update-info-experimental.jsonl"
$GITHUB_RELEASES = "https://github.com/JetBrains/junie/releases"
$JUNIE_BIN = Join-Path $HOME ".local\bin"
$JUNIE_DATA = Join-Path $HOME ".local\share\junie"

function Log($msg) { Write-Host "[Junie] $msg" }
function Log-Error($msg) { Write-Host "[Junie] ERROR: $msg" -ForegroundColor Red }

function Get-Sha256($file) {
  (Get-FileHash -Path $file -Algorithm SHA256).Hash.ToLower()
}

# Detect architecture
$ARCH = $env:PROCESSOR_ARCHITECTURE
switch ($ARCH) {
  "AMD64"   {$ARCH_NAME = "amd64" }
  "ARM64"   {$ARCH_NAME = "aarch64" }
  default   { Log-Error "Unsupported architecture: $ARCH"; exit 1 }
}

$PLATFORM = "windows-$ARCH_NAME"

function Fetch-LatestVersion {
  Log "Fetching latest version info..."
  $jsonl = Invoke-RestMethod -Uri $UPDATE_INFO_URL

  $lines = $jsonl -split "`n" | Where-Object { $_ -match "`"platform`":`"$PLATFORM`"" }
  if (-not $lines) {
    Log-Error "No release found for platform: $PLATFORM"
    exit 1
  }

  $entry = $lines | Select-Object -Last 1
  $parsed = $entry | ConvertFrom-Json

  $script:VERSION = $parsed.version
  $script:DOWNLOAD_URL = $parsed.downloadUrl
  $script:SHA256 = $parsed.sha256

  if (-not $script:VERSION -or -not $script:DOWNLOAD_URL) {
    Log-Error "Failed to parse version info"
    exit 1
  }
}

# Look up the SHA-256 checksum for a specific version+platform from the
# update-info JSONL so that explicit JUNIE_VERSION requests can still be
# integrity-checked. Returns the checksum if found, or an empty string otherwise.
# Best-effort: network/parse failures or a version that isn't listed simply
# result in an empty checksum (the caller decides how to proceed).
function Fetch-VersionSha256($wantVersion) {
  try {
    $jsonl = Invoke-RestMethod -Uri $UPDATE_INFO_URL
  } catch {
    return ""
  }

  $lines = $jsonl -split "`n" | Where-Object { $_ -match "`"platform`":`"$PLATFORM`"" }
  foreach ($line in $lines) {
    try {
      $parsed = $line | ConvertFrom-Json
    } catch {
      continue
    }
    if ($parsed.version -eq $wantVersion) {
      return $parsed.sha256
    }
  }
  return ""
}

# Determine version: use JUNIE_VERSION env var if set, otherwise fetch latest
if ($env:JUNIE_VERSION) {
  $VERSION = $env:JUNIE_VERSION
  $DOWNLOAD_URL = "$GITHUB_RELEASES/download/$VERSION/junie-$CHANNEL-$VERSION-$PLATFORM.zip"
  Log "Using specified version: $VERSION"
  # Even for an explicitly requested version, try to look up its published
  # checksum so the download is still integrity-checked. If the version isn't
  # listed in update-info we proceed without a checksum (best-effort).
  $SHA256 = Fetch-VersionSha256 $VERSION
  if ($SHA256) {
    Log "Found published checksum for version $VERSION"
  } else {
    Log "Warning: No checksum found for version $VERSION; proceeding without integrity verification"
  }
} else {
  Fetch-LatestVersion
}

Log "Installing Junie $VERSION for $PLATFORM..."

# Create directories
New-Item -ItemType Directory -Force -Path $JUNIE_BIN | Out-Null
New-Item -ItemType Directory -Force -Path "$JUNIE_DATA\versions" | Out-Null
New-Item -ItemType Directory -Force -Path "$JUNIE_DATA\updates" | Out-Null

# Download and install binary
# Always re-download and overwrite the target version directory, regardless of
# whether it already exists. This avoids reusing a previously cached broken or
# partial install for the same version.
$TARGET_DIR = Join-Path "$JUNIE_DATA\versions" $VERSION

$TMP_ZIP = Join-Path $env:TEMP "junie-$VERSION.zip"

Log "Downloading $DOWNLOAD_URL"
$oldProgress = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri $DOWNLOAD_URL -OutFile $TMP_ZIP -UseBasicParsing
$ProgressPreference = $oldProgress

# Verify checksum
if ($SHA256) {
  $actualSha256 = Get-Sha256 $TMP_ZIP
  if ($actualSha256 -ne $SHA256.ToLower()) {
    Log-Error "Checksum verification failed!"
    Log-Error "Expected: $SHA256"
    Log-Error "Got: $actualSha256"
    Remove-Item -Force $TMP_ZIP
    exit 1
  }
  Log "Checksum verified"
}

# Extract to a staging dir on the same filesystem as $TARGET_DIR, validate the
# resolved binary, then atomically rename into place. This mirrors the shim's
# robust extraction so an interrupted install never leaves a half-extracted tree.
$STAGING = Join-Path "$JUNIE_DATA\versions" (".$VERSION.tmp." + $PID)
if (Test-Path $STAGING) { Remove-Item -Recurse -Force $STAGING }
New-Item -ItemType Directory -Force -Path $STAGING | Out-Null

try {
  $oldProgress = $global:ProgressPreference
  $global:ProgressPreference = 'SilentlyContinue'
  Expand-Archive -Path $TMP_ZIP -DestinationPath $STAGING -Force
  $global:ProgressPreference = $oldProgress

  # Validate that the expected binary is present in the staging tree.
  $StagedExe = Join-Path $STAGING "junie\junie.exe"
  if (-not (Test-Path $StagedExe)) {
    Log-Error "No junie binary found in downloaded payload"
    exit 1
  }

  # Remove any existing (possibly broken) version directory before the rename.
  if (Test-Path $TARGET_DIR) { Remove-Item -Recurse -Force $TARGET_DIR }
  Move-Item -Path $STAGING -Destination $TARGET_DIR
} catch {
  if (Test-Path $STAGING) { Remove-Item -Recurse -Force $STAGING }
  throw
} finally {
  Remove-Item -Force $TMP_ZIP -ErrorAction SilentlyContinue
}

# Write current version pointer file (plain text, not symlink)
[System.IO.File]::WriteAllText("$JUNIE_DATA\current", $VERSION)

# Install shim batch file (embedded inline so it works when piped via irm ... | iex)
$SHIM_PATH = Join-Path $JUNIE_BIN "junie.bat"
$SHIM_CONTENT = @'
@echo off
setlocal enabledelayedexpansion

:: Junie CLI Shim for Windows
::
:: This script is the entry point for Junie CLI. It handles:
:: 1. Applying pending updates before launching
:: 2. Version selection via JUNIE_VERSION env or --use-version flag
:: 3. Executing the appropriate version binary
::
:: Installation locations:
::   Shim:     ~/.local/bin/junie.bat
::   Data:     ~/.local/share/junie/
::   Versions: ~/.local/share/junie/versions/<version>/junie/junie.exe
::   Updates:  ~/.local/share/junie/updates/

set "JUNIE_DATA=%USERPROFILE%\.local\share\junie"
if defined JUNIE_DATA_DIR set "JUNIE_DATA=%JUNIE_DATA_DIR%"
set "VERSIONS_DIR=%JUNIE_DATA%\versions"
set "UPDATES_DIR=%JUNIE_DATA%\updates"
set "CURRENT_FILE=%JUNIE_DATA%\current"
set "PENDING_UPDATE=%UPDATES_DIR%\pending-update.json"
set "PROCESSING=%UPDATES_DIR%\pending-update.json.processing"

::: === Defensive Sanitization ===
:::
::: JUNIE-2957 defense: drop pending-update.json / pending-update.json.processing
::: if they are empty or unparseable BEFORE the atomic-claim rename below. A
::: legitimate in-flight update writes the manifest fully and then renames it,
::: so a zero-byte file or one missing `version`/`zipPath` can only be junk --
::: a leftover from a prior crash or content planted by mistake. Without this,
::: a stale .processing blocks all future updates AND can be inherited by the
::: binary's own update path with CWD as a working-dir hint.
if exist "%PENDING_UPDATE%" (
  set "PEND_OK="
  for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "try { $c = Get-Content -Raw -LiteralPath '%PENDING_UPDATE%' -ErrorAction Stop; if ([string]::IsNullOrWhiteSpace($c)) { 'bad' } else { $j = $c ^| ConvertFrom-Json; if ($j.version -and $j.zipPath) { 'ok' } else { 'bad' } } } catch { 'bad' }"`) do set "PEND_OK=%%V"
  if /i not "!PEND_OK!"=="ok" (
    echo [Junie] Removing invalid update artifact: %PENDING_UPDATE% 1>&2
    del /f /q "%PENDING_UPDATE%" 2>nul
  )
)
if exist "!PROCESSING!" (
  set "PROC_OK="
  for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "try { $c = Get-Content -Raw -LiteralPath '!PROCESSING!' -ErrorAction Stop; if ([string]::IsNullOrWhiteSpace($c)) { 'bad' } else { $j = $c ^| ConvertFrom-Json; if ($j.version -and $j.zipPath) { 'ok' } else { 'bad' } } } catch { 'bad' }"`) do set "PROC_OK=%%V"
  if /i not "!PROC_OK!"=="ok" (
    echo [Junie] Removing invalid update artifact: !PROCESSING! 1>&2
    del /f /q "!PROCESSING!" 2>nul
  )
)

:: === Apply Pending Update ===
if not exist "%PENDING_UPDATE%" goto :resolve_version

:: Atomically claim the pending update by renaming it.
:: Only one instance can win the rename; others skip to resolve_version.
rename "%PENDING_UPDATE%" "pending-update.json.processing" 2>nul
if errorlevel 1 (
  echo [Junie] Another instance is applying the update, skipping 1>&2
  goto :resolve_version
)
set "CLAIMED_UPDATE=%UPDATES_DIR%\pending-update.json.processing"

:: Parse the claimed manifest using PowerShell (reliable JSON parsing)
for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "(Get-Content '!CLAIMED_UPDATE!' | ConvertFrom-Json).version"`) do set "UPD_VERSION=%%V"
for /f "usebackq delims=" %%Z in (`powershell -NoProfile -Command "(Get-Content '!CLAIMED_UPDATE!' | ConvertFrom-Json).zipPath"`) do set "UPD_ZIP=%%Z"
for /f "usebackq delims=" %%S in (`powershell -NoProfile -Command "(Get-Content '!CLAIMED_UPDATE!' | ConvertFrom-Json).sha256"`) do set "UPD_SHA256=%%S"

if not defined UPD_VERSION (
  echo [Junie] Invalid pending update manifest, skipping 1>&2
  del /f /q "!CLAIMED_UPDATE!" 2>nul
  goto :resolve_version
)
if not defined UPD_ZIP (
  echo [Junie] Invalid pending update manifest, skipping 1>&2
  del /f /q "!CLAIMED_UPDATE!" 2>nul
  goto :resolve_version
)
if not exist "!UPD_ZIP!" (
  echo [Junie] Update file not found: !UPD_ZIP! 1>&2
  del /f /q "!CLAIMED_UPDATE!" 2>nul
  goto :resolve_version
)

:: Verify SHA-256 checksum
if defined UPD_SHA256 (
  for /f "usebackq delims=" %%H in (`powershell -NoProfile -Command "(Get-FileHash '!UPD_ZIP!' -Algorithm SHA256).Hash.ToLower()"`) do set "ACTUAL_SHA=%%H"
  if /i not "!ACTUAL_SHA!"=="!UPD_SHA256!" (
    echo [Junie] Checksum mismatch, skipping update 1>&2
    echo [Junie] Expected: !UPD_SHA256! 1>&2
    echo [Junie] Got: !ACTUAL_SHA! 1>&2
    del /f /q "!CLAIMED_UPDATE!" 2>nul
    del /f /q "!UPD_ZIP!" 2>nul
    goto :resolve_version
  )
)

:: Extract to a staging dir on the same filesystem as %VERSIONS_DIR%, validate
:: the resolved binary, then atomically rename into place. On any failure we
:: rename the claimed manifest back to pending-update.json so the next launch
:: retries (keeping the zip), and continue with the previously installed version.
set "UPD_TARGET=%VERSIONS_DIR%\!UPD_VERSION!"
set "UPD_RND=!RANDOM!"
set "UPD_STAGING_NAME=.!UPD_VERSION!.tmp.!UPD_RND!"
set "UPD_OLD_NAME=.!UPD_VERSION!.old.!UPD_RND!"
set "UPD_STAGING=%VERSIONS_DIR%\!UPD_STAGING_NAME!"
set "UPD_OLD=%VERSIONS_DIR%\!UPD_OLD_NAME!"
if exist "!UPD_STAGING!" rmdir /s /q "!UPD_STAGING!" 2>nul
mkdir "!UPD_STAGING!" 2>nul

echo [Junie] Applying pending update to version !UPD_VERSION!... 1>&2
powershell -NoProfile -Command "Expand-Archive -Path '!UPD_ZIP!' -DestinationPath '!UPD_STAGING!' -Force" 2>nul
if errorlevel 1 (
  echo [Junie] Failed to extract update; preserving for retry 1>&2
  rmdir /s /q "!UPD_STAGING!" 2>nul
  rename "!CLAIMED_UPDATE!" "pending-update.json" 2>nul
  goto :resolve_version
)

:: Validate extracted binary
if not exist "!UPD_STAGING!\junie\junie.exe" (
  echo [Junie] Extracted payload missing junie\junie.exe; preserving for retry 1>&2
  rmdir /s /q "!UPD_STAGING!" 2>nul
  rename "!CLAIMED_UPDATE!" "pending-update.json" 2>nul
  goto :resolve_version
)

:: Atomic swap: move any existing version aside, then rename staging into place.
if exist "!UPD_TARGET!" rename "!UPD_TARGET!" "!UPD_OLD_NAME!" 2>nul
move "!UPD_STAGING!" "!UPD_TARGET!" >nul 2>nul
if errorlevel 1 (
  echo [Junie] Failed to install new version; preserving for retry 1>&2
  if exist "!UPD_OLD!" if not exist "!UPD_TARGET!" rename "!UPD_OLD!" "!UPD_VERSION!" 2>nul
  rmdir /s /q "!UPD_STAGING!" 2>nul
  rename "!CLAIMED_UPDATE!" "pending-update.json" 2>nul
  goto :resolve_version
)

:: Best-effort cleanup of the previous tree
if exist "!UPD_OLD!" rmdir /s /q "!UPD_OLD!" 2>nul

:: Update current pointer file (plain text, not symlink) after a successful swap.
>"%CURRENT_FILE%" (echo|set /p="!UPD_VERSION!")

:: Cleanup downloaded zip and manifest only after a successful swap
del /f /q "!UPD_ZIP!" 2>nul
del /f /q "!CLAIMED_UPDATE!" 2>nul
echo [Junie] Updated to version !UPD_VERSION! 1>&2

:: === Resolve Version ===
:resolve_version
set "RESOLVED_VERSION="

:: Priority 1: --use-version flag
for %%A in (%*) do (
  set "ARG=%%A"
  if "!ARG:~0,14!"=="--use-version=" (
    set "RESOLVED_VERSION=!ARG:~14!"
  )
)

:: Priority 2: JUNIE_VERSION environment variable
if not defined RESOLVED_VERSION (
  if defined JUNIE_VERSION set "RESOLVED_VERSION=%JUNIE_VERSION%"
)

:: Priority 3: current pointer file
if not defined RESOLVED_VERSION (
  if exist "%CURRENT_FILE%" (
    set /p RESOLVED_VERSION=<"%CURRENT_FILE%"
  )
)

if not defined RESOLVED_VERSION (
  echo [Junie] Error: No version found. Please reinstall Junie. 1>&2
  echo [Junie] Run: irm https://junie.jetbrains.com/install.ps1 ^| iex 1>&2
  exit /b 1
)

:: Verify version directory exists
if not exist "%VERSIONS_DIR%\%RESOLVED_VERSION%" (
  echo [Junie] Error: Version %RESOLVED_VERSION% not found in %VERSIONS_DIR% 1>&2
  exit /b 1
)

:: Locate binary
set "JUNIE_EXE=%VERSIONS_DIR%\%RESOLVED_VERSION%\junie\junie.exe"
if not exist "%JUNIE_EXE%" (
  echo [Junie] Error: Binary not found: %JUNIE_EXE% 1>&2
  exit /b 1
)

:: Set required environment variables
if not defined EJ_RUNNER_PWD set "EJ_RUNNER_PWD=%CD%"
set "JUNIE_DATA=%JUNIE_DATA%"

:: Filter out --use-version from args and launch
set "FILTERED_ARGS="
for %%A in (%*) do (
  set "ARG=%%A"
  if not "!ARG:~0,14!"=="--use-version=" (
    if defined FILTERED_ARGS (
      set "FILTERED_ARGS=!FILTERED_ARGS! %%A"
    ) else (
      set "FILTERED_ARGS=%%A"
    )
  )
)

endlocal & "%JUNIE_EXE%" %FILTERED_ARGS%
'@
[System.IO.File]::WriteAllText($SHIM_PATH, $SHIM_CONTENT)

Log "Installed successfully!"

# Add to User PATH permanently (persists across reboots)
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$JUNIE_BIN*") {
  $NewPath = if ($UserPath) { "$UserPath;$JUNIE_BIN" } else { $JUNIE_BIN }
  [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
  Log "Added $JUNIE_BIN to User PATH."
}

Write-Host ""
Write-Host "Please restart your shell to apply the changes to the PATH variable."
Write-Host "After that, you can run: junie --help"
