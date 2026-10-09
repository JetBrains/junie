#
# Regression test: the PowerShell installers must accept `--local-model`, reject
# unknown flags, and hand over to the PowerShell local model installer -- while
# still reporting Junie itself as installed when that hand-over fails.
#
# Usage:
#   pwsh -NoProfile -File tests/install_local_model.ps1
#
# The failure path ends in `exit 1`, so each Install-LocalModel case runs in a
# child process (this same script re-invoked with -HarnessInstaller).
#

param(
  [string]$HarnessInstaller = '',
  [int]$StubExit = 0
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$installers = @(
  'install.ps1',
  'install-eap.ps1',
  'install-nightly.ps1',
  'install-experimental.ps1'
)

$stubUrl = 'https://example.test/local/install.ps1'
$psExe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }

# ------------------------------------------------------------------
# Harness mode: exercise Install-LocalModel with a stubbed download.
# ------------------------------------------------------------------
if ($HarnessInstaller) {
  $source = Get-Content -Raw -LiteralPath $HarnessInstaller
  $functionMatch = [regex]::Match($source, '(?ms)^function Install-LocalModel \{.*?^\}')
  if (-not $functionMatch.Success) {
    Write-Host 'HARNESS: Install-LocalModel function not found'
    exit 2
  }

  function Log($msg) { Write-Host "$msg" }
  function Log-Error($msg) { Write-Host "ERROR: $msg" }
  function Remove-TempFile($file) { try { [System.IO.File]::Delete($file) } catch { } }

  # Stand in for the network: write a stub "local installer" that announces
  # itself and exits with the requested status.
  function Invoke-WebRequest {
    param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)
    [System.IO.File]::WriteAllText($OutFile, "Write-Host 'STUB-LOCAL-INSTALLER url=$Uri'; exit $StubExit")
  }

  $LOCAL_MODEL_URL = $stubUrl
  Invoke-Expression $functionMatch.Value
  Install-LocalModel
  Write-Host 'HARNESS: returned without exiting'
  exit 0
}

# ------------------------------------------------------------------
# Test driver.
# ------------------------------------------------------------------
$passed = 0
$failed = 0

function Test-Case($name, $title, $condition, $detail) {
  if ($condition) {
    Write-Host "PASS [$name] $title"
    $script:passed++
  } else {
    Write-Host "FAIL [$name] $title -- $detail"
    $script:failed++
  }
}

foreach ($name in $installers) {
  $installer = Join-Path $repoRoot $name
  if (-not (Test-Path -LiteralPath $installer)) {
    Test-Case $name 'installer present' $false "not found at $installer"
    continue
  }

  # --help exits cleanly and documents the flag. Argument parsing happens
  # before any network access, so this never downloads anything.
  $output = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $installer --help 2>&1 | Out-String)
  $status = $LASTEXITCODE
  Test-Case $name '--help documents --local-model' `
    ($status -eq 0 -and $output -match '--local-model') "status $status : $output"

  # The piped install cannot pass arguments, so --help must point at the env var.
  Test-Case $name '--help documents JUNIE_LOCAL_MODEL' `
    ($output -match 'JUNIE_LOCAL_MODEL') "usage text: $output"

  # An unknown flag is rejected instead of silently ignored.
  $output = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $installer --local-models 2>&1 | Out-String)
  $status = $LASTEXITCODE
  Test-Case $name 'unknown flag rejected' `
    ($status -eq 1 -and $output -match 'Unknown option: --local-models') "status $status : $output"

  # Install-LocalModel downloads the local installer and runs it.
  $output = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -HarnessInstaller $installer -StubExit 0 2>&1 | Out-String)
  $status = $LASTEXITCODE
  Test-Case $name 'Install-LocalModel runs the local model installer' `
    ($status -eq 0 -and $output -match [regex]::Escape("STUB-LOCAL-INSTALLER url=$stubUrl")) "status $status : $output"

  # A failing local model setup must still tell the user that Junie is installed,
  # and hand them the command to retry the local model on its own.
  $output = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -HarnessInstaller $installer -StubExit 3 2>&1 | Out-String)
  $status = $LASTEXITCODE
  Test-Case $name 'failed local model setup reports Junie as installed, with a retry hint' `
    ($status -eq 1 -and
     $output -match 'Junie itself is installed and ready to use' -and
     $output -match [regex]::Escape($stubUrl)) "status $status : $output"
}

Write-Host '----'
Write-Host "PASS: $passed  FAIL: $failed"
if ($failed -ne 0) { exit 1 }
