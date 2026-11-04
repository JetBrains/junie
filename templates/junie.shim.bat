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
set "KNOWN_CHANNELS={{CHANNELS}}"
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
