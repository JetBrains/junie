#
# DO NOT EDIT — generated from templates/install.ps1.template by templates/generate.sh
# Junie CLI Installer for Windows
# Usage: irm https://junie.jetbrains.com/install.ps1 | iex
#
# To install a specific version:
#   $env:JUNIE_VERSION="656.1"; irm https://junie.jetbrains.com/install.ps1 | iex
#
# To also set up the local model after installing Junie:
#   $env:JUNIE_LOCAL_MODEL="1"; irm https://junie.jetbrains.com/install.ps1 | iex
#
# When the script is saved to a file, the same is requested with a flag:
#   .\install.ps1 --local-model
#

$ErrorActionPreference = 'Stop'

$CHANNEL = "nightly"
$UPDATE_INFO_URL = "https://raw.githubusercontent.com/jetbrains-junie/junie/main/update-info-nightly.jsonl"
$INSTALL_TAG = "<install_tag>"
$GITHUB_RELEASES = "https://github.com/JetBrains/junie/releases"
$JUNIE_BIN = Join-Path $HOME ".local\bin"
$JUNIE_DATA = Join-Path $HOME ".local\share\junie"
$LOCAL_MODEL_URL = "https://raw.githubusercontent.com/jetbrains-junie/junie/main/local/install.ps1"

# One-shot mode (set by the shim for `junie --<channel>`): install/refresh this
# channel's latest build but do NOT touch the existing shim, the `current`
# pointer, or PATH -- the default channel must stay intact. When set, the
# installed version is reported back via $env:JUNIE_ONESHOT_VERSION_FILE.
$ONESHOT = $env:JUNIE_ONESHOT

function Log($msg) { Write-Host "$msg" }
function Log-Error($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red }

function Show-Usage {
  Write-Host "Usage: install.ps1 [--local-model]"
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  --local-model   After installing Junie, run the local model setup"
  Write-Host "  --help, -h      Show this help"
  Write-Host ""
  Write-Host "A piped invocation (irm ... | iex) cannot pass arguments; request the"
  Write-Host "local model with the JUNIE_LOCAL_MODEL environment variable instead:"
  Write-Host '  $env:JUNIE_LOCAL_MODEL="1"; irm https://junie.jetbrains.com/install.ps1 | iex'
}

# `--local-model` requests the local model setup once Junie itself is in place.
# Arguments only reach us when this script is executed as a file (or as a script
# block); the usual `irm ... | iex` invocation has no way to pass them, so
# JUNIE_LOCAL_MODEL=1 is the equivalent switch for piped installs.
$LOCAL_MODEL = [bool]$env:JUNIE_LOCAL_MODEL

# Skip PowerShell wrapper args (everything up to and including the script path
# of a `powershell -File install.ps1 ...` invocation).
$rawArgs = @($MyInvocation.UnboundArguments)
$scriptName = if ($MyInvocation.MyCommand.Path) { [System.IO.Path]::GetFileName($MyInvocation.MyCommand.Path) } else { "" }
if ($scriptName) {
  for ($k = 0; $k -lt $rawArgs.Length; $k++) {
    if ($rawArgs[$k] -eq '-File' -and ($k + 1) -lt $rawArgs.Length -and [System.IO.Path]::GetFileName("$($rawArgs[$k + 1])") -eq $scriptName) {
      if (($k + 2) -lt $rawArgs.Length) {
        $rawArgs = @($rawArgs[($k + 2)..($rawArgs.Length - 1)])
      } else {
        $rawArgs = @()
      }
      break
    }
  }
}

foreach ($rawArg in @($rawArgs | Where-Object { "$_" -ne '' })) {
  switch ("$rawArg") {
    { $_ -in '--local-model', '-LocalModel', '-local-model' } { $LOCAL_MODEL = $true }
    { $_ -in '--help', '-h', '-help' } { Show-Usage; exit 0 }
    default {
      Log-Error "Unknown option: $rawArg"
      Show-Usage
      exit 1
    }
  }
}

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

# Run local/install.ps1, which downloads the inference engine and model weights,
# writes the Junie model config, and starts the engine. It has its own preflight
# checks and reports its own progress, so we only announce the handover and
# surface a retry hint on failure. It is run as a child process from a temp file
# (rather than dot-sourced) so its own argument parsing and exit codes behave
# exactly as they do for a direct invocation.
function Install-LocalModel {
  Write-Host ""
  Log "Junie is installed. Setting up the local model..."

  $localScript = Join-Path $env:TEMP "junie-local-install-$PID.ps1"
  $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
  $ok = $true

  try {
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $LOCAL_MODEL_URL -OutFile $localScript -UseBasicParsing
    $ProgressPreference = $oldProgress

    & $psExe -NoProfile -ExecutionPolicy Bypass -File $localScript
    if ($LASTEXITCODE -ne 0) { $ok = $false }
  } catch {
    Log-Error $_.Exception.Message
    $ok = $false
  } finally {
    Remove-TempFile $localScript
  }

  if (-not $ok) {
    # The local model is an optional extra on top of a finished Junie install,
    # and it is the part most likely to be refused -- on Windows it needs an
    # NVIDIA GPU with 24 GB of VRAM. Whatever went wrong here, Junie itself is
    # installed, so say so plainly instead of leaving the run looking failed.
    Write-Host ""
    Log-Error "The local model setup did not complete."
    Log "Junie itself is installed and ready to use -- run: junie"
    Log "To try the local model again: irm $LOCAL_MODEL_URL | iex"
    exit 1
  }
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
  $BUNDLED_SHIM = Join-Path $TARGET_DIR "shim\junie.bat"
  if (Test-Path $BUNDLED_SHIM) {
    Copy-Item -Path $BUNDLED_SHIM -Destination $SHIM_PATH -Force
  } else {
    $SHIM_CONTENT = @'
@echo off
setlocal enabledelayedexpansion
set "JUNIE_RESTART_DIR="
set "JUNIE_RESTART_FILE="
set "RESTART_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

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

if not defined JUNIE_DATA set "JUNIE_DATA=%USERPROFILE%\.local\share\junie"
if defined JUNIE_DATA_DIR set "JUNIE_DATA=%JUNIE_DATA_DIR%"
set "VERSIONS_DIR=%JUNIE_DATA%\versions"
set "UPDATES_DIR=%JUNIE_DATA%\updates"
set "CURRENT_FILE=%JUNIE_DATA%\current"
set "PENDING_UPDATE=%UPDATES_DIR%\pending-update.json"
set "PROCESSING=%UPDATES_DIR%\pending-update.json.processing"

:: === Channel Switching (one-shot) ===
::
:: `junie --channel=<name>`
:: fetches and launches the latest build of another channel for this run only.
:: It runs that channel's published installer in one-shot mode, which installs
:: the build WITHOUT touching the shim, the `current` pointer, or PATH. We then
:: launch that build directly, leaving the default channel completely intact.
:: Keep in sync with templates/channels.tsv in the JetBrains/junie repo, which
:: hosts the per-channel installers this shim calls.
set "KNOWN_CHANNELS=release eap nightly experimental"
set "REQUESTED_CHANNEL="

:: Legacy channel flags are no longer selectors. Warn while users migrate to
:: --channel=<name>; the binary accepts these hidden compatibility flags.
for %%A in (%*) do (
  set "ARG=%%~A"
  for %%C in (!KNOWN_CHANNELS!) do if "!ARG!"=="--%%C" echo [Junie] Warning: '!ARG!' is no longer supported; use '--channel=%%C' instead 1>&2
)

:: --channel=<name>: cmd's FOR (and %1) tokenizes on '=', splitting this form
:: into two tokens, so we cannot rely on the loop above. Parse it out of the
:: raw argument string (%*) instead. `%*:*--channel=%` drops everything up to
:: and including `--channel`, leaving `=<name> ...`; we then strip the `=` and
:: take the first whitespace-delimited token as the channel name.
set "ALL_ARGS=%*"
set "LAUNCH_ARGS=%*"
set "CH_AFTER=!ALL_ARGS:*--channel=!"
if not "!CH_AFTER!"=="!ALL_ARGS!" if "!CH_AFTER:~0,1!"=="=" (
  set "CH_AFTER=!CH_AFTER:~1!"
  for /f "tokens=1" %%V in ("!CH_AFTER!") do set "REQUESTED_CHANNEL=%%V"
)

:: === Informational Invocations (JUNIE-3065) ===
:: Quick, read-only commands the user does not expect to trigger an update:
:: --version, --help/-h, --gateway-status. For these we skip applying a staged
:: pending update so the currently installed version answers the command.
set "INFO_INVOCATION="
for %%A in (%*) do (
  set "ARG=%%~A"
  if "!ARG!"=="--version" set "INFO_INVOCATION=1"
  if "!ARG!"=="--help" set "INFO_INVOCATION=1"
  if "!ARG!"=="-h" set "INFO_INVOCATION=1"
  if "!ARG!"=="--gateway-status" set "INFO_INVOCATION=1"
)

:: === Update Routing ===
:: A plain `junie update` is forwarded to the binary, which runs its own update
:: command (it asks the update service which build fits this
:: channel/license/platform and stages it for the next launch).
::
:: The shim keeps only the cases the binary cannot serve, detected here as the
:: leading (first non-flag) positional token plus the raw argument string:
::   * `update --force` / `update -f` -- reinstall the latest build without
::     launching the binary (it may be broken);
::   * `update --channel=<name>` -- switch the persisted channel.
:: cmd tokenizes `--channel=<name>` into `--channel` and `<name>`, so the value
:: token must be skipped too (UC_DROP_NEXT) before it is mistaken for the verb.
set "UPDATE_CMD="
set "FORCE_UPDATE="
set "UC_DONE="
set "UC_DROP_NEXT="
for %%A in (%*) do (
  if not defined UC_DONE (
    set "ARG=%%~A"
    set "UC_SKIP="
    if defined UC_DROP_NEXT (
      set "UC_SKIP=1"
      set "UC_DROP_NEXT="
    )
    if "!ARG!"=="--channel" set "UC_DROP_NEXT=1"
    if "!ARG!"=="--use-version" set "UC_DROP_NEXT=1"
    if not defined UC_SKIP (
      if not "!ARG:~0,1!"=="-" (
        if /i "!ARG!"=="update" set "UPDATE_CMD=1"
        set "UC_DONE=1"
      )
    )
  )
)

if defined UPDATE_CMD (
  if defined REQUESTED_CHANNEL set "FORCE_UPDATE=1"
  for %%A in (%*) do (
    set "ARG=%%~A"
    if /i "!ARG!"=="--force" set "FORCE_UPDATE=1"
    if /i "!ARG!"=="-f" set "FORCE_UPDATE=1"
  )
)

:: Forced and channel-targeted updates are consumed by the shim (it exits after
:: running the installer) and never forwarded to the binary. A plain `update`
:: falls through to the normal launch path below.
if defined FORCE_UPDATE goto :manual_update

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

:: Validate channel against the known list.
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
powershell -NoProfile -Command "$env:PSModulePath=''; $env:JUNIE_ONESHOT='1'; $env:JUNIE_ONESHOT_VERSION_FILE='!ONESHOT_VFILE!'; $env:JUNIE_VERSION='!REQUESTED_BUILD!'; iex (irm '!INSTALLER_URL!')"
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
set "EJ_RUNNER_PWD=%CD%"

:: One-shot builds must not adopt or update the default channel.
set "JUNIE_SKIP_UPDATE_CHECK=1"
goto :launch

:: === Forced Update (`junie update --force`, `junie update -f`) ===
::
:: Downloads and *persistently* installs the latest build of the target channel
:: from the shell, without launching the binary or
:: its AutoUpdateService. It runs the channel's published installer in its normal
:: (non-one-shot) mode, so the installer updates versions\<v>, flips the `current`
:: pointer, and refreshes this shim on disk -- a real, persistent update.
::
:: Channel comes from the package named by `current` and is overridable only via
:: --channel=<name>, captured into REQUESTED_CHANNEL above.
:manual_update
set "INSTALL_BASE_URL=https://junie.jetbrains.com"
if defined JUNIE_INSTALL_BASE_URL set "INSTALL_BASE_URL=%JUNIE_INSTALL_BASE_URL%"

set "UPD_CHANNEL=release"
if defined REQUESTED_CHANNEL (
  set "UPD_CHANNEL=!REQUESTED_CHANNEL!"
) else (
  call :resolve_current_channel
)

:: Validate channel against the known list.
set "CH_OK="
for %%C in (!KNOWN_CHANNELS!) do if /i "%%C"=="!UPD_CHANNEL!" set "CH_OK=1"
if not defined CH_OK (
  echo [Junie] Error: Unknown channel '!UPD_CHANNEL!' ^(known: !KNOWN_CHANNELS!^) 1>&2
  exit /b 1
)

if /i "!UPD_CHANNEL!"=="release" (
  set "INSTALLER_URL=!INSTALL_BASE_URL!/install.ps1"
) else (
  set "INSTALLER_URL=!INSTALL_BASE_URL!/install-!UPD_CHANNEL!.ps1"
)

echo [Junie] Forcing a reinstall of the latest '!UPD_CHANNEL!' build... 1>&2
echo [Junie] Checking for the latest '!UPD_CHANNEL!' version... 1>&2
echo [Junie] Downloading and installing Junie ^(!UPD_CHANNEL!^)... 1>&2

:: Persistent install: NOT one-shot, so the installer updates versions\<v>,
:: flips the `current` pointer, and refreshes this shim on disk. Its own
:: `[Junie] ...` progress lines stream straight through to the user.
powershell -NoProfile -Command "$env:PSModulePath=''; $env:JUNIE_DATA='%JUNIE_DATA%'; iex (irm '!INSTALLER_URL!')" & if errorlevel 1 (echo [Junie] Error: Failed to update Junie ^('!UPD_CHANNEL!'^); current installation left untouched 1>&2 & exit /b 1) else (echo [Junie] Update complete. 1>&2 & exit /b 0)

:resolve_current_channel
set "CHANNEL_STATUS="
set "CHANNEL_VALUE="
for /f "usebackq tokens=1,2" %%S in (`powershell -NoProfile -Command "$env:PSModulePath=''; $ErrorActionPreference = 'Stop'; $known = @('release', 'eap', 'nightly', 'experimental'); try { if (-not (Test-Path -LiteralPath $env:CURRENT_FILE -PathType Leaf)) { 'missing'; exit }; $version = [IO.File]::ReadAllText($env:CURRENT_FILE); $version = ($version -split '[\r\n]', 2)[0]; if ([string]::IsNullOrWhiteSpace($version)) { 'invalid'; exit }; $root = [IO.Path]::GetFullPath($env:VERSIONS_DIR).TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)) + [IO.Path]::DirectorySeparatorChar; $versionDir = [IO.Path]::GetFullPath((Join-Path $root $version)); if (-not $versionDir.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { 'invalid'; exit }; $channelFile = Join-Path $versionDir 'channel'; if (-not (Test-Path -LiteralPath $channelFile)) { 'missing'; exit }; if (-not (Test-Path -LiteralPath $channelFile -PathType Leaf)) { 'invalid'; exit }; $bytes = [IO.File]::ReadAllBytes($channelFile); $utf8 = New-Object Text.UTF8Encoding($false); foreach ($channel in $known) { $expected = $utf8.GetBytes($channel + [char]10); if ([Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String($expected)) { 'valid ' + $channel; exit } }; 'invalid' } catch { 'unreadable' }" 2^>nul`) do (
  set "CHANNEL_STATUS=%%S"
  set "CHANNEL_VALUE=%%T"
)
if /i "!CHANNEL_STATUS!"=="valid" (
  set "UPD_CHANNEL=!CHANNEL_VALUE!"
  exit /b 0
)
if /i "!CHANNEL_STATUS!"=="missing" exit /b 0
if /i "!CHANNEL_STATUS!"=="invalid" (
  echo [Junie] Warning: Invalid channel metadata for the current package; using 'release' 1>&2
) else (
  echo [Junie] Warning: Could not read channel metadata for the current package; using 'release' 1>&2
)
set "UPD_CHANNEL=release"
exit /b 0

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
  for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "$env:PSModulePath=''; try { $c = Get-Content -Raw -LiteralPath '%PENDING_UPDATE%' -ErrorAction Stop; if ([string]::IsNullOrWhiteSpace($c)) { 'bad' } else { $j = $c | ConvertFrom-Json; if ($j.version -and $j.zipPath) { 'ok' } else { 'bad' } } } catch { 'bad' }"`) do set "PEND_OK=%%V"
  if /i not "!PEND_OK!"=="ok" (
    echo [Junie] Removing invalid update artifact: %PENDING_UPDATE% 1>&2
    del /f /q "%PENDING_UPDATE%" 2>nul
  )
)
if exist "!PROCESSING!" (
  set "PROC_OK="
  for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "$env:PSModulePath=''; try { $c = Get-Content -Raw -LiteralPath '!PROCESSING!' -ErrorAction Stop; if ([string]::IsNullOrWhiteSpace($c)) { 'bad' } else { $j = $c | ConvertFrom-Json; if ($j.version -and $j.zipPath) { 'ok' } else { 'bad' } } } catch { 'bad' }"`) do set "PROC_OK=%%V"
  if /i not "!PROC_OK!"=="ok" (
    echo [Junie] Removing invalid update artifact: !PROCESSING! 1>&2
    del /f /q "!PROCESSING!" 2>nul
  )
)

:: === Apply Pending Update ===
:: Informational invocations (--version/--help/-h/--gateway-status) skip applying
:: a staged pending update so the currently installed version answers the command
:: (JUNIE-3065). The pending update stays staged for the next normal run.
if defined INFO_INVOCATION goto :resolve_version
:apply_update
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
set "UPD_VERSION="
set "UPD_ZIP="
set "UPD_SHA256="
set "ACTUAL_SHA="
for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "$env:PSModulePath=''; (Get-Content '!CLAIMED_UPDATE!' | ConvertFrom-Json).version"`) do set "UPD_VERSION=%%V"
for /f "usebackq delims=" %%Z in (`powershell -NoProfile -Command "$env:PSModulePath=''; (Get-Content '!CLAIMED_UPDATE!' | ConvertFrom-Json).zipPath"`) do set "UPD_ZIP=%%Z"
for /f "usebackq delims=" %%S in (`powershell -NoProfile -Command "$env:PSModulePath=''; (Get-Content '!CLAIMED_UPDATE!' | ConvertFrom-Json).sha256"`) do set "UPD_SHA256=%%S"

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
  for /f "usebackq delims=" %%H in (`powershell -NoProfile -Command "$env:PSModulePath=''; (Get-FileHash '!UPD_ZIP!' -Algorithm SHA256).Hash.ToLower()"`) do set "ACTUAL_SHA=%%H"
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

echo [Junie] Applying staged update... 1>&2
echo [Junie] Extracting update... 1>&2
powershell -NoProfile -Command "$env:PSModulePath=''; Expand-Archive -Path '!UPD_ZIP!' -DestinationPath '!UPD_STAGING!' -Force" 2>nul
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
echo [Junie] Update complete: version !UPD_VERSION! 1>&2

:: === Resolve Version ===
:resolve_version
set "RESOLVED_VERSION="

:: Priority 1: --use-version flag
set "UV_REMAINING=!ALL_ARGS!"
:resolve_use_version
:: cmd does not substitute into an undefined variable: with no arguments at all
:: !UV_REMAINING:*--use-version=! expands to the literal `*--use-version=`, so the equality
:: guard below never fires and the scan cycles forever (JUNIE-4810).
if not defined UV_REMAINING goto :use_version_resolved
set "UV_AFTER=!UV_REMAINING:*--use-version=!"
if "!UV_AFTER!"=="!UV_REMAINING!" goto :use_version_resolved
set "UV_REMAINING=!UV_AFTER:~1!"
if not "!UV_AFTER:~0,1!"=="=" goto :resolve_use_version
if "!UV_REMAINING:~0,1!"==" " goto :resolve_use_version
for /f "tokens=1" %%V in ("!UV_REMAINING!") do set "RESOLVED_VERSION=%%V"
goto :resolve_use_version
:use_version_resolved

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
  set "JUNIE_EXIT_CODE=1"
  goto :finish
)

:: Verify version directory exists
if not exist "%VERSIONS_DIR%\%RESOLVED_VERSION%" (
  echo [Junie] Error: Version %RESOLVED_VERSION% not found in %VERSIONS_DIR% 1>&2
  set "JUNIE_EXIT_CODE=1"
  goto :finish
)

:: Locate binary
set "JUNIE_EXE=%VERSIONS_DIR%\%RESOLVED_VERSION%\junie\junie.exe"
if not exist "%JUNIE_EXE%" (
  echo [Junie] Error: Binary not found: %JUNIE_EXE% 1>&2
  set "JUNIE_EXIT_CODE=1"
  goto :finish
)

:: Set required environment variables
set "EJ_RUNNER_PWD=%CD%"
set "JUNIE_DATA=%JUNIE_DATA%"

:: Export this shim's own absolute path (%~f0) so the binary can refresh it in
:: place during auto-update (see ShimUpdater on the binary side).
set "JUNIE_SHIM_PATH=%~f0"

:launch
if not defined JUNIE_RESTART_DIR (
  call :prepare_restart
  if errorlevel 1 (
    echo [Junie] Error: Could not create a private restart directory 1>&2
    set "JUNIE_EXIT_CODE=1"
    goto :finish
  )
)
if exist "!JUNIE_RESTART_FILE!" del /f /q "!JUNIE_RESTART_FILE!" 2>nul
if exist "!JUNIE_RESTART_FILE!" (
  echo [Junie] Error: Could not clear restart request 1>&2
  set "JUNIE_EXIT_CODE=1"
  goto :finish
)
:: Keep this on one line because Junie can replace this batch file while running.
"%JUNIE_EXE%" !LAUNCH_ARGS! & set "JUNIE_EXIT_CODE=!ERRORLEVEL!" & goto :after_launch
:after_launch
if not "!JUNIE_EXIT_CODE!"=="100" goto :finish

set "RESTART_SESSION="
set "RESTART_PROJECT="
"%RESTART_POWERSHELL%" -NoProfile -NonInteractive -Command "$ErrorActionPreference='Stop'; $f=Get-Item -LiteralPath $env:JUNIE_RESTART_FILE; if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { exit 1 }; $lines=[IO.File]::ReadAllLines($f.FullName); if ($lines.Length -ne 2 -or [string]::IsNullOrWhiteSpace($lines[0]) -or [string]::IsNullOrWhiteSpace($lines[1])) { exit 1 }" 2>nul
if errorlevel 1 (
  echo [Junie] Error: Missing or invalid restart request 1>&2
  goto :finish
)
<"!JUNIE_RESTART_FILE!" (
  set /p "RESTART_SESSION="
  set /p "RESTART_PROJECT="
)
del /f /q "!JUNIE_RESTART_FILE!" 2>nul
if not defined RESTART_SESSION goto :finish
if not defined RESTART_PROJECT goto :finish
set "RESTART_ARGS="
call :filter_restart_args %*
set "LAUNCH_ARGS=!RESTART_ARGS! --session-id "!RESTART_SESSION!" --project "!RESTART_PROJECT!""
set "JUNIE_PROMPT="
echo [Junie] Restarting Junie... 1>&2

if defined REQUESTED_CHANNEL goto :launch
if exist "%PENDING_UPDATE%" goto :apply_update
goto :resolve_version

:finish
if defined JUNIE_RESTART_DIR rmdir /s /q "!JUNIE_RESTART_DIR!" 2>nul
endlocal & exit /b %JUNIE_EXIT_CODE%

:prepare_restart
set "RESTART_TOKEN="
for /f %%T in ('%RESTART_POWERSHELL% -NoProfile -NonInteractive -Command "[guid]::NewGuid().ToString('N')"') do set "RESTART_TOKEN=%%T"
if not defined RESTART_TOKEN exit /b 1
set "RESTART_DIRECTORY=%TEMP%\junie-restart.!RESTART_TOKEN!"
mkdir "!RESTART_DIRECTORY!" 2>nul
if errorlevel 1 exit /b 1
set "JUNIE_RESTART_DIR=!RESTART_DIRECTORY!"
"%RESTART_POWERSHELL%" -NoProfile -NonInteractive -Command "$ErrorActionPreference='Stop'; $user=[Security.Principal.WindowsIdentity]::GetCurrent().User; $acl=[Security.AccessControl.DirectorySecurity]::new(); $acl.SetOwner($user); $acl.SetAccessRuleProtection($true,$false); $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($user,'FullControl','ContainerInherit,ObjectInherit','None','Allow')); Set-Acl -LiteralPath $env:JUNIE_RESTART_DIR -AclObject $acl" 1>nul
if errorlevel 1 exit /b 1
set "JUNIE_RESTART_FILE=!JUNIE_RESTART_DIR!\request"
exit /b 0

:filter_restart_args
if "%~1"=="" exit /b
if "%~1"=="--session-id" goto :skip_restart_selection
if "%~1"=="--project" goto :skip_restart_selection
if "%~1"=="-p" goto :skip_restart_selection
if "%~1"=="--prompt" goto :skip_restart_selection
set "RESTART_ARG=%~1"
if "!RESTART_ARG:~0,13!"=="--session-id=" goto :skip_restart_argument
if "!RESTART_ARG:~0,10!"=="--project=" goto :skip_restart_argument
if "!RESTART_ARG:~0,9!"=="--prompt=" goto :skip_restart_argument
set "RESTART_ARGS=!RESTART_ARGS! %1"
:skip_restart_argument
shift
goto :filter_restart_args

:skip_restart_selection
shift
shift
goto :filter_restart_args
'@
    # The shim is a cmd.exe batch file: it MUST use Windows CRLF line endings.
    # This template is maintained with LF, so normalize before writing -- otherwise
    # `goto`/`call` label seeking breaks on LF-only files (e.g. the forward jump to
    # :after_channel_oneshot), causing "The system cannot find the batch label
    # specified" on launch.
    $SHIM_CONTENT = $SHIM_CONTENT -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($SHIM_PATH, $SHIM_CONTENT)
  }

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

if ($LOCAL_MODEL) {
  Install-LocalModel
}
