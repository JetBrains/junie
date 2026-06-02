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

:: Persistent upgrade log (mirrors the POSIX shim). Lives under
:: %USERPROFILE%\.junie\logs -- separate from the data dir so a reinstall that
:: wipes ~/.local/share/junie does not lose update history. Always appended,
:: never truncated. Override the directory with JUNIE_LOG_DIR. A per-invocation
:: session id (LOG_SID) is stamped on every line so one launch can be followed.
set "UPGRADE_LOG_DIR=%USERPROFILE%\.junie\logs"
if defined JUNIE_LOG_DIR set "UPGRADE_LOG_DIR=%JUNIE_LOG_DIR%"
set "UPGRADE_LOG=%UPGRADE_LOG_DIR%\upgrade.log"
set "LOG_SID=%RANDOM%%RANDOM%"
if not exist "%UPGRADE_LOG_DIR%" mkdir "%UPGRADE_LOG_DIR%" 2>nul

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
    call :log_upgrade "sanitize: removing invalid update artifact pending-update.json"
    del /f /q "%PENDING_UPDATE%" 2>nul
  )
)
if exist "!PROCESSING!" (
  set "PROC_OK="
  for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "try { $c = Get-Content -Raw -LiteralPath '!PROCESSING!' -ErrorAction Stop; if ([string]::IsNullOrWhiteSpace($c)) { 'bad' } else { $j = $c ^| ConvertFrom-Json; if ($j.version -and $j.zipPath) { 'ok' } else { 'bad' } } } catch { 'bad' }"`) do set "PROC_OK=%%V"
  if /i not "!PROC_OK!"=="ok" (
    echo [Junie] Removing invalid update artifact: !PROCESSING! 1>&2
    call :log_upgrade "sanitize: removing invalid update artifact pending-update.json.processing"
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
call :log_upgrade "apply: claimed pending update for processing"

:: Parse the claimed manifest using PowerShell (reliable JSON parsing)
for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "(Get-Content '!CLAIMED_UPDATE!' | ConvertFrom-Json).version"`) do set "UPD_VERSION=%%V"
for /f "usebackq delims=" %%Z in (`powershell -NoProfile -Command "(Get-Content '!CLAIMED_UPDATE!' | ConvertFrom-Json).zipPath"`) do set "UPD_ZIP=%%Z"
for /f "usebackq delims=" %%S in (`powershell -NoProfile -Command "(Get-Content '!CLAIMED_UPDATE!' | ConvertFrom-Json).sha256"`) do set "UPD_SHA256=%%S"
call :log_upgrade "apply: manifest parsed version=!UPD_VERSION! zipPath=!UPD_ZIP! sha256=!UPD_SHA256!"

if not defined UPD_VERSION (
  echo [Junie] Invalid pending update manifest, skipping 1>&2
  call :log_upgrade "apply: invalid manifest (missing version); dropping manifest"
  del /f /q "!CLAIMED_UPDATE!" 2>nul
  goto :resolve_version
)
if not defined UPD_ZIP (
  echo [Junie] Invalid pending update manifest, skipping 1>&2
  call :log_upgrade "apply: invalid manifest (missing zipPath); dropping manifest"
  del /f /q "!CLAIMED_UPDATE!" 2>nul
  goto :resolve_version
)
if not exist "!UPD_ZIP!" (
  echo [Junie] Update file not found: !UPD_ZIP! 1>&2
  call :log_upgrade "apply: update archive not found at !UPD_ZIP!; dropping manifest"
  del /f /q "!CLAIMED_UPDATE!" 2>nul
  goto :resolve_version
)

:: Verify SHA-256 checksum
if defined UPD_SHA256 (
  call :log_upgrade "checksum: starting SHA-256 validation expected=!UPD_SHA256!"
  set "ACTUAL_SHA="
  for /f "usebackq delims=" %%H in (`powershell -NoProfile -Command "(Get-FileHash '!UPD_ZIP!' -Algorithm SHA256).Hash.ToLower()"`) do set "ACTUAL_SHA=%%H"
  if not defined ACTUAL_SHA (
    :: Get-FileHash produced no output -- the zip could not be read/hashed,
    :: almost always because it is still locked or being scanned by antivirus.
    :: This is a transient condition, NOT corruption: PRESERVE the manifest and
    :: zip and retry on the next launch. Deleting them here (as a plain mismatch
    :: would) makes the binary re-download and re-fail every startup -- an
    :: endless update loop that never recovers.
    echo [Junie] Could not read update zip ^(locked or AV scan?^); will retry next launch 1>&2
    call :log_upgrade "checksum: UNREADABLE -- Get-FileHash returned no output; preserving manifest and archive for retry"
    rename "!CLAIMED_UPDATE!" "pending-update.json" 2>nul
    goto :resolve_version
  )
  if /i not "!ACTUAL_SHA!"=="!UPD_SHA256!" (
    echo [Junie] Checksum mismatch, skipping update 1>&2
    echo [Junie] Expected: !UPD_SHA256! 1>&2
    echo [Junie] Got: !ACTUAL_SHA! 1>&2
    call :log_upgrade "checksum: FAIL expected=!UPD_SHA256! got=!ACTUAL_SHA! -- dropping manifest and archive"
    del /f /q "!CLAIMED_UPDATE!" 2>nul
    del /f /q "!UPD_ZIP!" 2>nul
    goto :resolve_version
  )
  call :log_upgrade "checksum: OK"
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
call :log_upgrade "extract: starting Expand-Archive src=!UPD_ZIP! dst=!UPD_STAGING!"
powershell -NoProfile -Command "Expand-Archive -Path '!UPD_ZIP!' -DestinationPath '!UPD_STAGING!' -Force" 2>nul
if errorlevel 1 (
  echo [Junie] Failed to extract update; preserving for retry 1>&2
  call :log_upgrade "extract: FAIL (Expand-Archive non-zero); preserving manifest and archive for retry"
  rmdir /s /q "!UPD_STAGING!" 2>nul
  rename "!CLAIMED_UPDATE!" "pending-update.json" 2>nul
  goto :resolve_version
)

:: Validate extracted binary
if not exist "!UPD_STAGING!\junie\junie.exe" (
  echo [Junie] Extracted payload missing junie\junie.exe; preserving for retry 1>&2
  call :log_upgrade "validate: FAIL (junie\junie.exe missing in payload); preserving manifest and archive for retry"
  rmdir /s /q "!UPD_STAGING!" 2>nul
  rename "!CLAIMED_UPDATE!" "pending-update.json" 2>nul
  goto :resolve_version
)

:: Atomic swap: move any existing version aside, then rename staging into place.
if exist "!UPD_TARGET!" rename "!UPD_TARGET!" "!UPD_OLD_NAME!" 2>nul
move "!UPD_STAGING!" "!UPD_TARGET!" >nul 2>nul
if errorlevel 1 (
  echo [Junie] Failed to install new version; preserving for retry 1>&2
  call :log_upgrade "swap: FAIL (could not move staging into place); rolled back and preserving manifest for retry"
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
call :log_upgrade "apply: SUCCESS updated to version !UPD_VERSION!"
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

:: Jump past the subroutines to end of file, preserving junie.exe's exit code.
goto :eof

:: === Subroutines ===

:log_upgrade
:: Append a timestamped, session-tagged line to the persistent upgrade log.
:: Best-effort: a failure to write (e.g. read-only profile) must never break
:: launching, so the error is swallowed. %~1 is the (already-expanded) message.
echo [%DATE% %TIME%] [sid=%LOG_SID%] %~1>> "%UPGRADE_LOG%" 2>nul
exit /b 0
