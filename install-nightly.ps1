#
# DO NOT EDIT — generated from templates/install.ps1.template by templates/generate.sh
# Junie CLI Installer for Windows
# Usage: irm https://junie.jetbrains.com/install.ps1 | iex
#
# To install a specific version:
#   $env:JUNIE_VERSION="656.1"; irm https://junie.jetbrains.com/install.ps1 | iex
#

$ErrorActionPreference = 'Stop'

$CHANNEL = "nightly"
$UPDATE_INFO_URL = "https://raw.githubusercontent.com/jetbrains-junie/junie/main/update-info-nightly.jsonl"
$INSTALL_TAG = "<install_tag>"
$GITHUB_RELEASES = "https://github.com/JetBrains/junie/releases"
$JUNIE_BIN = Join-Path $HOME ".local\bin"
$JUNIE_DATA = Join-Path $HOME ".local\share\junie"

# One-shot mode (set by the shim for `junie --<channel>`): install/refresh this
# channel's latest build but do NOT touch the existing shim, the `current`
# pointer, or PATH -- the default channel must stay intact. When set, the
# installed version is reported back via $env:JUNIE_ONESHOT_VERSION_FILE.
$ONESHOT = $env:JUNIE_ONESHOT

function Log($msg) { Write-Host "[Junie] $msg" }
function Log-Error($msg) { Write-Host "[Junie] ERROR: $msg" -ForegroundColor Red }

function Get-Sha256($file) {
  (Get-FileHash -Path $file -Algorithm SHA256).Hash.ToLower()
}

# Delete a file by its literal path via the .NET API. PowerShell's path provider
# (Remove-Item/Test-Path/Set-Location/...) mishandles 8.3 short paths whose short
# name is LONGER than the long name -- e.g. %TEMP% on dotted usernames such as
# "a.lastname" resolving to C:\Users\A####~1.LAS\... -- throwing a terminating
# PSArgumentException ("An object at the specified path ... does not exist") that
# -ErrorAction cannot suppress (PowerShell issue #17359). The .NET API resolves
# such paths correctly. [System.IO.File]::Delete is a no-op if the file is gone.
function Remove-TempFile($file) {
  try { [System.IO.File]::Delete($file) } catch { }
}

# Whether a version directory already contains the expected binary. Used in
# one-shot mode to skip a redundant re-download of an already-installed build.
function Test-OneshotTargetReady($dir) {
  Test-Path (Join-Path $dir "junie\junie.exe")
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

  $parsed = $lines | ForEach-Object { $_ | ConvertFrom-Json } |
    Sort-Object { [Version]$_.version } | Select-Object -Last 1

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

if ($INSTALL_TAG -and $INSTALL_TAG -ne "<install_tag>") {
  New-Item -ItemType Directory -Force -Path "$JUNIE_DATA\misc" | Out-Null
  [System.IO.File]::WriteAllText("$JUNIE_DATA\misc\install_tag", $INSTALL_TAG)
}

# Download and install binary
# Always re-download and overwrite the target version directory, regardless of
# whether it already exists. This avoids reusing a previously cached broken or
# partial install for the same version.
$TARGET_DIR = Join-Path "$JUNIE_DATA\versions" $VERSION

# In one-shot mode we still re-resolved "latest" above; only the download itself
# is skipped when that exact version is already installed and valid.
if ($ONESHOT -and (Test-OneshotTargetReady $TARGET_DIR)) {
  Log "Version $VERSION already installed; skipping download"
} else {
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
      Remove-TempFile $TMP_ZIP
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
    Remove-TempFile $TMP_ZIP
  }
}

if ($ONESHOT) {
  # One-shot: report the installed version back to the caller (the shim) and
  # leave the shim, the `current` pointer, and PATH untouched.
  if ($env:JUNIE_ONESHOT_VERSION_FILE) {
    [System.IO.File]::WriteAllText($env:JUNIE_ONESHOT_VERSION_FILE, $VERSION)
  }
  Log "Ready (version $VERSION)"
} else {
  # Write current version pointer file (plain text, not symlink)
  [System.IO.File]::WriteAllText("$JUNIE_DATA\current", $VERSION)

  # Install shim batch file (embedded inline so it works when piped via irm ... | iex)
  $SHIM_PATH = Join-Path $JUNIE_BIN "junie.bat"
  $SHIM_CONTENT = @'
@echo off
setlocal enabledelayedexpansion

:: JUNIE_MANAGED_SHIM
::
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

:: === Channel Switching (one-shot) ===
::
:: `junie --eap` (also --nightly / --release / --experimental, or --channel=<name>)
:: fetches and launches the latest build of another channel for this run only.
:: It runs that channel's published installer in one-shot mode, which installs
:: the build WITHOUT touching the shim, the `current` pointer, or PATH. We then
:: launch that build directly, leaving the default channel completely intact.
:: Channel list, injected from templates/channels.tsv by generate.sh.
set "KNOWN_CHANNELS=release eap nightly experimental"
set "REQUESTED_CHANNEL="

:: Bareword flags (--eap, --nightly, ...). These contain no '=', so cmd's FOR
:: tokenizer leaves them whole; match them data-driven from KNOWN_CHANNELS.
for %%A in (%*) do (
  set "ARG=%%A"
  for %%C in (!KNOWN_CHANNELS!) do if "!ARG!"=="--%%C" set "REQUESTED_CHANNEL=%%C"
)

:: --channel=<name>: cmd's FOR (and %1) tokenizes on '=', splitting this form
:: into two tokens, so we cannot rely on the loop above. Parse it out of the
:: raw argument string (%*) instead. `%*:*--channel=%` drops everything up to
:: and including `--channel`, leaving `=<name> ...`; we then strip the `=` and
:: take the first whitespace-delimited token as the channel name.
set "ALL_ARGS=%*"
set "CH_AFTER=!ALL_ARGS:*--channel=!"
if not "!CH_AFTER!"=="!ALL_ARGS!" if "!CH_AFTER:~0,1!"=="=" (
  set "CH_AFTER=!CH_AFTER:~1!"
  for /f "tokens=1" %%V in ("!CH_AFTER!") do set "REQUESTED_CHANNEL=%%V"
)

if defined REQUESTED_CHANNEL goto :channel_oneshot
goto :after_channel_oneshot

:channel_oneshot
set "INSTALL_BASE_URL=https://junie.jetbrains.com"
if defined JUNIE_INSTALL_BASE_URL set "INSTALL_BASE_URL=%JUNIE_INSTALL_BASE_URL%"

:: Optional pinned build via --use-version=<build>. Parsed from %* for the same
:: reason as --channel= (cmd tokenizes on '='). Empty => the channel's latest.
set "REQUESTED_BUILD="
set "UV_AFTER=!ALL_ARGS:*--use-version=!"
if not "!UV_AFTER!"=="!ALL_ARGS!" if "!UV_AFTER:~0,1!"=="=" (
  set "UV_AFTER=!UV_AFTER:~1!"
  for /f "tokens=1" %%V in ("!UV_AFTER!") do set "REQUESTED_BUILD=%%V"
)

:: Validate channel against the injected list.
set "CH_OK="
for %%C in (!KNOWN_CHANNELS!) do if /i "%%C"=="!REQUESTED_CHANNEL!" set "CH_OK=1"
if not defined CH_OK (
  echo [Junie] Error: Unknown channel '!REQUESTED_CHANNEL!' 1>&2
  exit /b 1
)

if /i "!REQUESTED_CHANNEL!"=="release" (
  set "INSTALLER_URL=!INSTALL_BASE_URL!/install.ps1"
) else (
  set "INSTALLER_URL=!INSTALL_BASE_URL!/install-!REQUESTED_CHANNEL!.ps1"
)

set "ONESHOT_VFILE=%TEMP%\junie-oneshot-!RANDOM!.txt"
if defined REQUESTED_BUILD (
  echo [Junie] Fetching '!REQUESTED_CHANNEL!' build !REQUESTED_BUILD!... 1>&2
) else (
  echo [Junie] Fetching latest '!REQUESTED_CHANNEL!' build... 1>&2
)
:: JUNIE_VERSION='' lets the installer pick the channel's latest build.
powershell -NoProfile -Command "$env:JUNIE_ONESHOT='1'; $env:JUNIE_ONESHOT_VERSION_FILE='!ONESHOT_VFILE!'; $env:JUNIE_VERSION='!REQUESTED_BUILD!'; iex (irm '!INSTALLER_URL!')"
if errorlevel 1 (
  echo [Junie] Error: Failed to install '!REQUESTED_CHANNEL!' build 1>&2
  del /f /q "!ONESHOT_VFILE!" 2>nul
  exit /b 1
)
if not exist "!ONESHOT_VFILE!" (
  echo [Junie] Error: Channel installer did not report a version 1>&2
  exit /b 1
)
set "CH_VERSION="
set /p CH_VERSION=<"!ONESHOT_VFILE!"
del /f /q "!ONESHOT_VFILE!" 2>nul
if not defined CH_VERSION (
  echo [Junie] Error: Channel installer did not report a version 1>&2
  exit /b 1
)
if not exist "%VERSIONS_DIR%\!CH_VERSION!" (
  echo [Junie] Error: Channel build !CH_VERSION! not found after install 1>&2
  exit /b 1
)
set "JUNIE_EXE=%VERSIONS_DIR%\!CH_VERSION!\junie\junie.exe"
if not exist "!JUNIE_EXE!" (
  echo [Junie] Error: Binary not found: !JUNIE_EXE! 1>&2
  exit /b 1
)
if not defined EJ_RUNNER_PWD set "EJ_RUNNER_PWD=%CD%"

:: Filter out channel flags from args and launch the requested build directly.
:: cmd splits `--channel=<name>` into the tokens `--channel` and `<name>`, so
:: when we drop `--channel` we also drop the token that follows it (DROP_NEXT).
set "FILTERED_ARGS="
set "DROP_NEXT="
for %%A in (%*) do (
  set "ARG=%%A"
  set "SKIP="
  if defined DROP_NEXT (
    set "SKIP=1"
    set "DROP_NEXT="
  )
  if "!ARG!"=="--channel" (
    set "SKIP=1"
    set "DROP_NEXT=1"
  )
  if "!ARG!"=="--use-version" (
    set "SKIP=1"
    set "DROP_NEXT=1"
  )
  for %%C in (!KNOWN_CHANNELS!) do if "!ARG!"=="--%%C" set "SKIP=1"
  if not defined SKIP (
    if defined FILTERED_ARGS (
      set "FILTERED_ARGS=!FILTERED_ARGS! %%A"
    ) else (
      set "FILTERED_ARGS=%%A"
    )
  )
)
:: One-shot launch: pass EJ_RUNNER_PWD and JUNIE_DATA across endlocal, but NOT
:: JUNIE_SHIM_PATH -- a temporary channel build must never adopt or self-update
:: the default shim. Also force JUNIE_SKIP_UPDATE_CHECK=1 so this temporary build
:: never checks for, downloads, or stages an update that would clobber the user's
:: persisted default channel (the binary honors it via SystemOptionsGroup).
endlocal & set "EJ_RUNNER_PWD=%EJ_RUNNER_PWD%" & set "JUNIE_DATA=%JUNIE_DATA%" & set "JUNIE_SKIP_UPDATE_CHECK=1" & "%JUNIE_EXE%" %FILTERED_ARGS%
goto :eof

:after_channel_oneshot

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
  for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "try { $c = Get-Content -Raw -LiteralPath '%PENDING_UPDATE%' -ErrorAction Stop; if ([string]::IsNullOrWhiteSpace($c)) { 'bad' } else { $j = $c | ConvertFrom-Json; if ($j.version -and $j.zipPath) { 'ok' } else { 'bad' } } } catch { 'bad' }"`) do set "PEND_OK=%%V"
  if /i not "!PEND_OK!"=="ok" (
    echo [Junie] Removing invalid update artifact: %PENDING_UPDATE% 1>&2
    del /f /q "%PENDING_UPDATE%" 2>nul
  )
)
if exist "!PROCESSING!" (
  set "PROC_OK="
  for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "try { $c = Get-Content -Raw -LiteralPath '!PROCESSING!' -ErrorAction Stop; if ([string]::IsNullOrWhiteSpace($c)) { 'bad' } else { $j = $c | ConvertFrom-Json; if ($j.version -and $j.zipPath) { 'ok' } else { 'bad' } } } catch { 'bad' }"`) do set "PROC_OK=%%V"
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

:: Restore environment but pass important variables to the exe.
:: Export this shim's own absolute path (%~f0) so the binary can refresh it in
:: place during auto-update (see ShimUpdater on the binary side).
endlocal & set "EJ_RUNNER_PWD=%EJ_RUNNER_PWD%" & set "JUNIE_DATA=%JUNIE_DATA%" & set "JUNIE_SHIM_PATH=%~f0" & "%JUNIE_EXE%" %FILTERED_ARGS%
'@
  # The shim is a cmd.exe batch file: it MUST use Windows CRLF line endings.
  # This template is maintained with LF, so normalize before writing -- otherwise
  # `goto`/`call` label seeking breaks on LF-only files (e.g. the forward jump to
  # :after_channel_oneshot), causing "The system cannot find the batch label
  # specified" on launch.
  $SHIM_CONTENT = $SHIM_CONTENT -replace "`r?`n", "`r`n"
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
}
